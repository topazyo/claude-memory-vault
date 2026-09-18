#!/usr/bin/env bash
# .claude/scripts/vault-retention.sh
#
# Scheduled runner that archives old dream journals and compaction stubs.
# For cron or launchd, or Task Scheduler through vault-retention.cmd.
#
# It moves a file from 20-projects/_logs/ to 99-archive/20-projects/_logs/ only
# when git shows a machine wrote it and nobody changed it since:
#
#   a dream journal   dream-YYYY-MM-DD.md or dream-YYYY-MM-DD-<suffix>.md, added
#                     by exactly one commit that carries the dream runner's
#                     Vault-Pass and Vault-Pass-Blob trailers for it, never
#                     changed after, older than RETENTION_DAYS by its file name,
#                     and not among the journals of the newest eight dates
#   a compaction stub compaction-<session>.md, every committed version exactly
#                     the hook's template plus entry lines, each version a
#                     prefix of the next, its last entry older than
#                     RETENTION_DAYS
#
# Journals committed before any runner trailer existed are LEGACY. They are
# listed once in a report in the state directory and move only when the owner
# runs --adopt-legacy with that report. Every refusal still applies to them.
#
# All moves are one git mv and one commit with the trailers
#   Vault-Pass: retention
#   Vault-Retention-Run: <nonce>
#   Vault-Retention-Move: <source> -> <destination>
# A failed move or commit is put back while HEAD is unchanged. A commit that
# may have landed is never put back. When the outcome cannot be settled, a
# recovery file in the state directory says what is where, and later runs
# refuse until it checks out.
#
# Usage:
#   vault-retention.sh                         move what is eligible
#   vault-retention.sh --dry-run               judge and log, move and write nothing
#   vault-retention.sh --adopt-legacy <report> move the legacy journals the report lists
#
# Environment:
#   RETENTION_DAYS       days before a journal or stub may move (default 60)
#   RETENTION_MAX_MOVES  the most files one run moves (default 50, at most 50)
#   VAULT_STATE_DIR      per-vault state outside the vault (see dream-pass.sh)
#   RUN_LOCK_WAIT        seconds to wait for another runner's lock (default 1800)
#   RUN_LOCK_POLL        seconds between checks while waiting (default 30)
#   RUNNER_GIT_TIMEOUT   seconds each watched git step may take (default 120)
#
# Exit codes:
#   0    moved and committed, nothing to move, or no 20-projects/_logs folder
#   1    setup failure, git cannot read the vault, the vault is not the top of
#        its own repository, a shallow clone, grafts, or a sparse checkout
#   2    REPORT-REFUSED: the report was not written by this runner, or changed
#   3    PARTIAL: the move failed and the vault was put back to HEAD
#   4    COMMIT-FAILED: the commit failed with HEAD unchanged and was put back
#   6    PATH-BLOCKED: 20-projects, 20-projects/_logs or an archive folder is a
#        link, a junction or not a folder, or a folder differs only in case
#   64   usage error, or a report file that cannot be read
#   70   TRIPWIRE-ERROR, as for the other runners
#   71   RECOVERY-NEEDED: a put-back failed, or what a commit did is unknown.
#        The recovery file in the state directory says what is where
#   75   LOCKED: another runner's lock, git's index.lock, a git operation in
#        progress, a detached HEAD, or unmerged index entries
#   78   TRIPWIRE, or a recovery file from an earlier run that does not check out

set -u

RUNNER=vault-retention
SNAP_DIR=""
LOG=""
STATE=""
ROOT=""
HOOKS=""
# 1 from the moment the recovery file is written until the outcome is settled.
MOVING=0
HEAD_BEFORE=""
# Named apart from the library's RUN_NONCE on purpose. That one is the string
# the Windows stop sweep looks for on a command line, and giving it this run's
# identifier would point the sweep at whatever else happened to carry it.
RETENTION_NONCE=""
# Archive folders this run made, deepest last, so a put-back can remove them.
MADE_DIRS=""

LOGS_REL="20-projects/_logs"
ARCH_REL="99-archive/20-projects/_logs"

say() {  # say <text> - one timestamped line in the log
  printf '[%s] %s\n' "$(ts)" "$1" >> "$LOG"
}

on_exit() {
  [ -n "$SNAP_DIR" ] && rm -rf "$SNAP_DIR"
  run_lock_release
}

# On INT, TERM or HUP: stop a watched git command, then settle what the moves
# did. A second signal while that runs is ignored, so the put-back is not cut in
# two.
on_signal() {
  trap '' INT TERM HUP
  if [ -n "${RUN_PID:-}" ] && [ -n "$SNAP_DIR" ] && [ -d "$SNAP_DIR" ]; then
    stop_tree "$RUN_PID" 2 "$SNAP_DIR/signal-stop" "" 1
    if grep -qE '^(alive|unknown)' "$SNAP_DIR/signal-stop" 2>/dev/null; then
      RUN_KILL_FAILED=1
      RUN_KILL_REPORT="$(cat "$SNAP_DIR/signal-stop")"
    fi
  fi
  if [ "$MOVING" -eq 1 ]; then
    say "INTERRUPTED by a signal while moving."
    settle_outcome "$1"
  fi
  exit "$1"
}

# rgit <git args...>
# Git on the vault as every runner calls it (safe_git), with log.follow off and
# paths printed as their raw bytes, so history reads as it was committed.
# core.quotePath=false matters: with quoting on, a path holding a byte above
# 127 comes back as an escaped C string, and it would never equal the same path
# written plainly in a commit trailer, so a journal would be refused for a
# mismatch that is only a difference of spelling.
rgit() {
  safe_git "$HOOKS" -C "$ROOT" -c log.follow=false -c core.quotePath=false "$@"
}

# watched_git <stdout-file> <stdin-file> <git args...>
# The same git under the watchdog, for the steps that can be slow or run other
# programs. Standard output goes to the file, standard error to $SNAP_DIR/git.err.
# Returns 0 when git exited 0 in time.
watched_git() {
  local o="$1" i="$2"
  shift 2
  : > "$SNAP_DIR/git.err"
  run_with_watchdog "$GIT_TIMEOUT" "$SNAP_DIR/git.err" \
    env GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1 $LITERAL_PATHS RETENTION_GIT_OUT="$o" RETENTION_GIT_IN="$i" \
    bash -c 'exec git "$@" < "$RETENTION_GIT_IN" > "$RETENTION_GIT_OUT"' vault-retention-git \
    -C "$ROOT" -c core.hooksPath="$HOOKS" -c core.fsmonitor=false -c log.showSignature=false \
    -c log.follow=false -c core.quotePath=false "$@"
  RUN_PID=""
  [ "$RUN_TIMED_OUT" -eq 0 ] && [ "$RUN_RC" -eq 0 ]
}

# date_day <YYYY-MM-DD>
# Sets DATE_DAY to the number of days from a fixed epoch, and returns 1 when the
# string is not a real calendar date. Written in shell arithmetic rather than
# handed to date or awk, because the runner asks this of every candidate on
# every run, and one process per question is the kind of cost that decides
# whether a scheduled pass finishes inside its Windows time limit.
#
# 10# on each field is load bearing. Shell arithmetic reads a leading zero as
# octal, so 08 and 09 are errors that would abort the runner under set -u.
DATE_DAY=0
date_day() {
  local s="$1" y m d last yy era yoe doy doe
  case "$s" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  y=$((10#${s:0:4}))
  m=$((10#${s:5:2}))
  d=$((10#${s:8:2}))
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] || return 1
  case "$m" in
    1|3|5|7|8|10|12) last=31 ;;
    4|6|9|11) last=30 ;;
    *)
      if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then
        last=29
      else
        last=28
      fi
      ;;
  esac
  [ "$d" -ge 1 ] && [ "$d" -le "$last" ] || return 1
  # Howard Hinnant's days-from-civil, with March as the first month of the year
  # so that the leap day falls at the end of a cycle and needs no special case.
  yy=$y
  [ "$m" -le 2 ] && yy=$((yy - 1))
  era=$(( (yy >= 0 ? yy : yy - 399) / 400 ))
  yoe=$(( yy - era * 400 ))
  doy=$(( (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1 ))
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  DATE_DAY=$(( era * 146097 + doe ))
  return 0
}

# index_lock_wait
# Waits up to 30 seconds for git's index.lock to go, because a sync plugin or an
# editor can hold it for a moment. Returns 1 when it is still there.
index_lock_wait() {
  local idx="" i=0
  idx="$(git_index_lock_path "$ROOT")"
  [ -n "$idx" ] || return 0
  while [ -e "$idx" ] && [ "$i" -lt 30 ]; do
    sleep 1
    i=$((i + 1))
  done
  [ ! -e "$idx" ]
}

# real_dir_ok <relative path>
# True when a real folder is at exactly that path in the vault, so no link or
# junction leads the move somewhere else.
real_dir_ok() {
  local p="$ROOT/$1" real=""
  [ -d "$p" ] && [ ! -L "$p" ] || return 1
  real="$(cd "$p" 2>/dev/null && pwd -P)" || return 1
  [ "$(path_key "$real")" = "$(path_key "$ROOT_REAL/$1")" ]
}

# case_variant <parent relative path or empty> <name>
# True when the parent holds another entry, on disk or in HEAD, whose name
# differs from <name> only in ASCII case.
case_variant() {
  local dir="$ROOT" tree=""
  if [ -n "$1" ]; then
    dir="$ROOT/$1"
    tree="$(rgit ls-tree --name-only HEAD -- "$1/" 2>/dev/null)"
  else
    tree="$(rgit ls-tree --name-only HEAD 2>/dev/null)"
  fi
  { ls -A "$dir" 2>/dev/null; printf '%s\n' "$tree"; } \
    | LC_ALL=C awk -v n="$2" -v p="$1/" '
        { k = $0; if (index(k, p) == 1) k = substr(k, length(p) + 1)
          if (k != n && tolower(k) == tolower(n)) f = 1 }
        END { exit f ? 0 : 1 }'
}

# folder_checks
# Returns 0 to go on, 6 after logging a blocked path, and 10 when there is no
# 20-projects/_logs folder to evaluate.
folder_checks() {
  local rel="" parent="" name=""
  for rel in 20-projects "$LOGS_REL" 99-archive 99-archive/20-projects "$ARCH_REL"; do
    parent="${rel%/*}"
    [ "$parent" = "$rel" ] && parent=""
    name="${rel##*/}"
    if case_variant "$parent" "$name"; then
      say "PATH-BLOCKED: ${parent:-the vault root} holds a folder whose name differs from $name only in case. Rename or merge it, then run again."
      return 6
    fi
    if [ -e "$ROOT/$rel" ] || [ -L "$ROOT/$rel" ]; then
      if ! real_dir_ok "$rel"; then
        say "PATH-BLOCKED: $rel is a link, a junction or not a folder, so nothing is moved through it. Replace it with a real folder, then run again."
        return 6
      fi
    else
      case "$rel" in
        20-projects|"$LOGS_REL")
          say "There is no $LOGS_REL folder, so there is nothing to evaluate."
          return 10 ;;
      esac
    fi
  done
  return 0
}

# retention_preflight
# Returns 1 for a history the runner cannot trust to be whole, and 75 for
# unmerged index entries, after logging.
retention_preflight() {
  local gd="" common="" top=""
  # A vault sitting inside someone else's repository would have its journals
  # judged by a history that is not its own, and the moves would land in that
  # repository's commit.
  top="$(rgit rev-parse --show-toplevel 2>/dev/null)"
  if [ -z "$top" ] || [ "$(path_key "$top")" != "$(path_key "$ROOT_REAL")" ]; then
    say "ERROR: the vault is not the top of its own git repository, so the history that shows who wrote each journal belongs to something else. Refusing to run."
    return 1
  fi
  if [ "$(rgit rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    say "ERROR: the vault is a shallow clone, so the history that shows who wrote each journal is incomplete. Refusing to run."
    return 1
  fi
  gd="$(rgit rev-parse --absolute-git-dir 2>/dev/null)"
  common="$(cd "$ROOT" && cd "$(rgit rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd)"
  if [ -e "$gd/info/grafts" ] || { [ -n "$common" ] && [ -e "$common/info/grafts" ]; }; then
    say "ERROR: the repository has info/grafts, which rewrite history. Refusing to run."
    return 1
  fi
  if [ "$(rgit config --bool core.sparseCheckout 2>/dev/null)" = true ]; then
    say "ERROR: the vault uses a sparse checkout, where moves into 99-archive/ can fail. Refusing to run."
    return 1
  fi
  if [ -n "$(rgit ls-files -u 2>/dev/null)" ]; then
    say "LOCKED: the index holds unmerged entries. Resolve them, then run again."
    return 75
  fi
  return 0
}

# ---------------------------------------------------------------- candidates --
#
# One slot per entry of 20-projects/_logs that could move, held in parallel
# indexed arrays. Indexed rather than one map per fact because a CI job runs
# bash 3.2, which has no associative arrays.
C_N=0
KEPT_NEW=0
KEPT_EIGHT=0
QUIET_UNTRACKED=0
QUIET_TAKEN=0
REFUSED_EARLY=0
MOVED_N=0
TODAY=""
TODAY_DAY=0
# The oldest commit in the history of 20-projects/_logs that carries any
# Vault-Pass trailer. Everything before it predates the runners.
FIRST_VP=""

# add_candidate <name>
add_candidate() {
  C_NAME[$C_N]="$1"
  case "$1" in
    dream-*) C_KIND[$C_N]=journal ;;
    *) C_KIND[$C_N]=stub ;;
  esac
  C_VERDICT[$C_N]=""
  C_REASON[$C_N]=""
  C_DATE[$C_N]=""
  C_DAY[$C_N]=0
  C_BLOB[$C_N]=""
  C_N=$((C_N + 1))
}

# refuse <index> <reason>
# The first reason wins, so the order the checks run in is the order of the
# reasons a person reads in the log.
refuse() {
  [ -z "${C_VERDICT[$1]}" ] || return 0
  C_VERDICT[$1]=REFUSED
  C_REASON[$1]="$2"
  return 0
}

# quiet <index> <counter name>
# For the two groups that are common, expected and uninteresting one at a time.
# They are counted and summarised rather than given a line each.
quiet() {
  [ -z "${C_VERDICT[$1]}" ] || return 0
  C_VERDICT[$1]=QUIET
  case "$2" in
    untracked) QUIET_UNTRACKED=$((QUIET_UNTRACKED + 1)) ;;
    taken) QUIET_TAKEN=$((QUIET_TAKEN + 1)) ;;
  esac
  return 0
}

# enumerate_candidates
# Every entry of 20-projects/_logs named like a journal or a stub, whatever its
# type. Types are not filtered here on purpose, so a symlink is refused with a
# reason rather than quietly passed over.
enumerate_candidates() {
  local p n
  : > "$SNAP_DIR/names"
  LC_ALL=C find "$ROOT/$LOGS_REL/" -maxdepth 1 -mindepth 1 -print0 > "$SNAP_DIR/find.out" 2>/dev/null
  while IFS= read -r -d '' p; do
    n="${p##*/}"
    case "$n" in
      dream-*|compaction-*) ;;
      *) continue ;;
    esac
    # A name holding a control character can be neither a journal name nor a
    # stub name, and no line-based list could carry it through to the rest of
    # the run, so it is judged here and left out.
    case "$n" in
      *[[:cntrl:]]*)
        say "REFUSED: $LOGS_REL/$n (the name holds a control character, so it is neither a journal name nor a stub name)"
        REFUSED_EARLY=$((REFUSED_EARLY + 1))
        continue
        ;;
    esac
    printf '%s\n' "$n" >> "$SNAP_DIR/names"
  done < "$SNAP_DIR/find.out"
  LC_ALL=C sort "$SNAP_DIR/names" > "$SNAP_DIR/names.sorted" 2>/dev/null
  while IFS= read -r n; do
    [ -n "$n" ] && add_candidate "$n"
  done < "$SNAP_DIR/names.sorted"
  return 0
}

# journal_name_ok <name>
# True for dream-YYYY-MM-DD.md, or the same with a suffix of one to sixteen
# lower case letters and digits. Sets JN_DATE and JN_DAY. The date has to be a
# real one, so dream-2026-02-30.md is not a journal name at all rather than a
# journal with a strange date.
JN_DATE=""
JN_DAY=0
journal_name_ok() {
  local n="$1" rest sfx
  case "$n" in
    dream-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) ;;
    *) return 1 ;;
  esac
  JN_DATE="${n:6:10}"
  rest="${n:16}"
  case "$rest" in
    .md) ;;
    -*.md)
      sfx="${rest%.md}"
      sfx="${sfx#-}"
      case "$sfx" in
        ''|*[!a-z0-9]*) return 1 ;;
      esac
      [ "${#sfx}" -le 16 ] || return 1
      ;;
    *) return 1 ;;
  esac
  date_day "$JN_DATE" || return 1
  JN_DAY="$DATE_DAY"
  return 0
}

# stub_name_ok <name>
# True for compaction-<id>.md with an id of letters, digits, dot, underscore and
# hyphen that does not start with a dot, which is what the compaction hook
# sanitises a session id down to. Sets SN_ID.
SN_ID=""
stub_name_ok() {
  local n="$1" id
  case "$n" in
    compaction-*.md) ;;
    *) return 1 ;;
  esac
  id="${n#compaction-}"
  id="${id%.md}"
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  SN_ID="$id"
  return 0
}

# ------------------------------------------------------------ frontmatter --

# frontmatter_reason <path>
# Prints why the note may not be archived, or nothing when it may. A journal the
# dream pass wrote is medium tier, and a tier that has been changed by hand, or
# an unresolved contradiction recorded against it, means somebody is still
# working with it.
frontmatter_reason() {
  awk '
    NR == 1 && /^---[ \t\r]*$/ { f = 1; next }
    f && /^---[ \t\r]*$/ { closed = 1; exit }
    f {
      line = $0
      gsub(/\r/, "", line)
      if (line ~ /^[ \t]*contradicts:/ || line ~ /^[ \t]*superseded_by:/) flagged = 1
      if (line ~ /^tier:/) {
        tiers++
        v = line
        sub(/^tier:[ \t]*/, "", v)
        sub(/[ \t]+#.*$/, "", v)
        sub(/[ \t]+$/, "", v)
        if (length(v) >= 2) {
          a = substr(v, 1, 1)
          b = substr(v, length(v), 1)
          if (a == b && (a == "\"" || a == "\047")) v = substr(v, 2, length(v) - 2)
        }
        value = tolower(v)
      }
    }
    END {
      if (!f || !closed) { print "no frontmatter, so nothing says this is a medium tier note"; exit }
      if (flagged) { print "contradicts or superseded_by is set, so it is still being argued over"; exit }
      if (tiers != 1 || value != "medium") { print "tier is not medium, so it is not a note this pass may retire"; exit }
    }' "$1" 2>/dev/null
}

# ------------------------------------------------------------- git history --

# read_history
# One walk of everything that ever touched 20-projects/_logs, parsed once into
# three tables. Record separator 036 between commits and 037 between the message
# and the file list, because a commit message may hold anything else, including
# blank lines and the word that starts a file list.
#
# Returns 1 when a record does not have exactly one 037, which means a message
# held one and the parse cannot be trusted. Refusing beats guessing, because
# every later judgement rests on this table.
read_history() {
  : > "$SNAP_DIR/commits"
  : > "$SNAP_DIR/touch"
  : > "$SNAP_DIR/trailers"
  if ! watched_git "$SNAP_DIR/walk" /dev/null \
      log --full-history --no-renames --parents --encoding=UTF-8 --date=short \
      --format='%x1e%cd %H %P%n%B%x1f' --name-status -- "$LOGS_REL/"; then
    if [ "${RUN_TIMED_OUT:-0}" -eq 1 ]; then
      say "LOCKED: reading the history of $LOGS_REL did not finish within ${GIT_TIMEOUT}s and was stopped, so nothing was judged."
      return 75
    fi
    say "ERROR: the history of $LOGS_REL could not be read. Refusing to run."
    sed 4>/dev/null 1q /dev/null 2>/dev/null
    while IFS= read -r line; do say "    git: $line"; done < "$SNAP_DIR/git.err"
    return 1
  fi
  LC_ALL=C awk -v commits="$SNAP_DIR/commits" -v touch="$SNAP_DIR/touch" -v trailers="$SNAP_DIR/trailers" '
    BEGIN { RS = "\036"; err = 0; seq = 0 }
    {
      if ($0 == "") next
      if (split($0, part, "\037") != 2) { err = 1; exit }
      head = part[1]
      names = part[2]
      p = index(head, "\n")
      if (p == 0) { err = 1; exit }
      nid = split(substr(head, 1, p - 1), idv, " ")
      body = substr(head, p + 1)
      # The committer date comes first, so the parents can be any number of
      # trailing fields without the parse having to count them.
      cdate = idv[1]
      sha = idv[2]
      seq++
      dreamn = 0
      anyvp = 0
      retn = 0
      nb = split(body, bl, "\n")
      for (i = 1; i <= nb; i++) {
        line = bl[i]
        sub(/\r$/, "", line)
        if (line == "Vault-Pass: dream") dreamn++
        if (line == "Vault-Pass: retention") retn++
        if (index(line, "Vault-Pass: ") == 1) anyvp++
        if (index(line, "Vault-Pass-Blob: ") == 1) {
          rest = substr(line, 18)
          sp = index(rest, " ")
          if (sp > 1) printf "%s\t%s\t%s\n", sha, substr(rest, 1, sp - 1), substr(rest, sp + 1) >> trailers
        }
      }
      parents = ""
      for (i = 3; i <= nid; i++) parents = parents (parents == "" ? "" : " ") idv[i]
      # The identity line is the date, the commit and then one field per parent,
      # so two parents make four fields. Counting from the wrong field here is
      # silent: no commit is ever taken for a merge, and every merge check
      # passes because it runs over an empty list.
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", seq, sha, (nid > 3 ? 1 : 0), dreamn, anyvp, retn, cdate, parents >> commits
      nn = split(names, nl, "\n")
      for (i = 1; i <= nn; i++) {
        line = nl[i]
        if (line == "") continue
        t = index(line, "\t")
        if (t == 0) { err = 2; exit }
        st = substr(line, 1, t - 1)
        if (st !~ /^[A-Z][0-9]*$/) { err = 2; exit }
        printf "%s\t%s\t%s\t%s\n", seq, sha, st, substr(line, t + 1) >> touch
      }
    }
    END { if (err) exit 1 }' "$SNAP_DIR/walk" || {
      say "ERROR: the history of $LOGS_REL could not be read unambiguously, because a commit message or a file name holds one of the characters that separate the records. Refusing to run."
      return 1
    }
  # The oldest commit carrying any Vault-Pass trailer. The walk is newest first,
  # so the last such line is the oldest one.
  FIRST_VP="$(LC_ALL=C awk -F '\t' '$5 > 0 { s = $2 } END { if (s != "") print s }' "$SNAP_DIR/commits")"
  return 0
}

# ------------------------------------------------------------ object blobs --

# blob_ask <rev> <path>
# Adds one question to the batch of object lookups.
blob_ask() {
  printf '%s:%s\n' "$1" "$2" >> "$SNAP_DIR/batch.in"
}

# blob_run
# Asks all of them at once. Writes <question><TAB><blob or -> so the answers can
# be looked up by name afterwards. cat-file answers in the order it was asked,
# which is what pairs the two files.
blob_run() {
  [ -s "$SNAP_DIR/batch.in" ] || { : > "$SNAP_DIR/blobs"; return 0; }
  if ! watched_git "$SNAP_DIR/batch.out" "$SNAP_DIR/batch.in" cat-file --batch-check; then
    if [ "${RUN_TIMED_OUT:-0}" -eq 1 ]; then
      say "LOCKED: reading the stored content of the candidates did not finish within ${GIT_TIMEOUT}s and was stopped, so nothing was judged."
      return 75
    fi
    say "ERROR: the stored content of the candidates could not be read. Refusing to run."
    return 1
  fi
  LC_ALL=C awk -v q="$SNAP_DIR/batch.in" '
    BEGIN {
      n = 0
      while ((getline line < q) > 0) { n++; ask[n] = line }
      close(q)
      i = 0
    }
    {
      i++
      if (i > n) next
      v = "-"
      if ($NF != "missing") { split($0, f, " "); if (f[2] == "blob") v = f[1] }
      printf "%s\t%s\n", ask[i], v
    }' "$SNAP_DIR/batch.out" > "$SNAP_DIR/blobs"
  return 0
}

# blob_of <rev> <path>
# The blob recorded for one question, or - when the path is not there.
blob_of() {
  LC_ALL=C awk -F '\t' -v k="$1:$2" '$1 == k { print $2; found = 1; exit } END { if (!found) print "-" }' "$SNAP_DIR/blobs"
}

# --------------------------------------------------------- journal history --

# journal_facts
# One pass that turns the three history tables into one line per journal
# candidate, so the shell asks awk once rather than once per candidate.
# Columns: path, commits that are not merges, the oldest such commit and how it
# touched the path, the newest such commit, whether any of them is a retention
# commit, whether any of them carries a Vault-Pass trailer, and how many carry
# the dream one.
journal_facts() {
  LC_ALL=C awk -F '\t' -v cf="$SNAP_DIR/commits" -v tf="$SNAP_DIR/touch" '
    BEGIN {
      while ((getline l < cf) > 0) {
        split(l, c, "\t")
        DREAM[c[2]] = c[4]; VP[c[2]] = c[5]; RET[c[2]] = c[6]; CD[c[2]] = c[7]
      }
      close(cf)
      while ((getline l < tf) > 0) {
        split(l, t, "\t")
        s = t[1] + 0; sha = t[2]; st = t[3]; p = t[4]
        N[p]++
        if (!(p in OLD) || s > OLDS[p]) { OLD[p] = sha; OLDS[p] = s; OLDST[p] = st }
        if (!(p in NEW) || s < NEWS[p]) { NEW[p] = sha; NEWS[p] = s }
        if (RET[sha] > 0) HASRET[p] = 1
        if (VP[sha] > 0) HASVP[p] = 1
      }
      close(tf)
    }
    {
      p = $0
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", p, (p in N ? N[p] : 0), \
        (p in OLD ? OLD[p] : "-"), (p in OLDST ? OLDST[p] : "-"), \
        (p in NEW ? NEW[p] : "-"), (p in HASRET ? 1 : 0), (p in HASVP ? 1 : 0), \
        (p in OLD ? DREAM[OLD[p]] : 0), (p in OLD ? CD[OLD[p]] : "-")
    }' "$SNAP_DIR/jpaths" > "$SNAP_DIR/jfacts"
  return 0
}

# fact <path> <column>
fact() {
  LC_ALL=C awk -F '\t' -v p="$1" -v c="$2" '$1 == p { print $c; exit }' "$SNAP_DIR/jfacts"
}

# trailer_check <commit> <path> <blob>
# True when the commit says, in its own trailers, exactly what it did. It must
# carry one Vault-Pass-Blob line for this path, naming this blob, and the set of
# paths on its Vault-Pass-Blob lines must be the set of paths it changed. The
# second half is what a squash or an amend cannot fake, because the trailers it
# inherits describe a commit that no longer exists.
trailer_check() {
  LC_ALL=C awk -F '\t' -v sha="$1" -v path="$2" -v blob="$3" \
    -v tf="$SNAP_DIR/trailers" -v chf="$SNAP_DIR/changed" '
    BEGIN {
      mine = 0
      while ((getline l < tf) > 0) {
        split(l, t, "\t")
        if (t[1] != sha) continue
        T[t[3]]++
        nt++
        if (t[3] == path) { mine++; got = t[2] }
      }
      close(tf)
      while ((getline l < chf) > 0) {
        split(l, c, "\t")
        if (c[1] != sha) continue
        C[c[2]]++
        nc++
      }
      close(chf)
      if (mine != 1 || got != blob) exit 1
      if (nt != nc) exit 1
      for (k in T) if (!(k in C)) exit 1
      for (k in C) if (!(k in T)) exit 1
      exit 0
    }'
}

# merge_ok <path>
# True when no merge in the history decided the content of the path by itself.
# A merge may carry a blob one of its parents already had, or leave the path out
# when no parent had it. Anything else is a person resolving a conflict, and the
# result is not what the dream pass wrote.
merge_ok() {
  local path="$1" seq sha ismerge parents mb pb ok par _d _v _r _c
  while IFS=$'\t' read -r seq sha ismerge _d _v _r _c parents; do
    [ "$ismerge" = 1 ] || continue
    mb="$(blob_of "$sha" "$path")"
    ok=0
    for par in $parents; do
      pb="$(blob_of "$par" "$path")"
      [ "$pb" = "$mb" ] && ok=1
    done
    [ "$ok" -eq 1 ] || return 1
  done < "$SNAP_DIR/commits"
  return 0
}

# ------------------------------------------------------------------- stubs --

# stub_entry_ok <line>
# True for one entry line exactly as the compaction hook appends it, which is a
# hyphen, a timestamp, two spaces, trigger=, two spaces and transcript=. The
# trigger may not hold a space and the transcript may not hold two in a row,
# because two spaces are what separates the fields and a value holding them
# would make the line mean two different things.
ENTRY_DATE=""
stub_entry_ok() {
  local l="$1" rest trg val
  case "$l" in
    "- "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]"  trigger="*) ;;
    *) return 1 ;;
  esac
  rest="${l:21}"
  rest="${rest#  trigger=}"
  case "$rest" in
    *"  transcript="*) ;;
    *) return 1 ;;
  esac
  trg="${rest%%  transcript=*}"
  val="${rest#*  transcript=}"
  case "$trg" in *" "*) return 1 ;; esac
  case "$val" in *"  "*) return 1 ;; esac
  date_day "${l:2:10}" || return 1
  ENTRY_DATE="${l:2:10}"
  return 0
}

# The cap line the hook writes once, when a session reaches its fiftieth
# compaction. The fifty here mirrors MAX_ENTRIES in the hook, and the control
# that builds this fixture with the real hook is what proves the two agree.
STUB_MAX_ENTRIES=50
stub_cap_ok() {
  local l="$1"
  case "$l" in
    "- "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]"  CAP REACHED ($STUB_MAX_ENTRIES entries) — further compactions in this session are not appended") return 0 ;;
  esac
  return 1
}

# stub_template_ok <file> <session id>
# True when the file is the stub the compaction hook writes for that session and
# nothing else, followed by its entries. Sets STUB_LAST_DAY and STUB_LAST_DATE
# from the newest entry, which is when the session was last active.
#
# The template is spelled out here rather than read from the hook, because the
# whole point is to recognise the bytes a machine wrote. The control that feeds
# this function output from the real hook is what keeps the two in step.
STUB_LAST_DATE=""
STUB_LAST_DAY=0
stub_template_ok() {
  local f="$1" id="$2" line n=0 created="" reviewed="" entries=0 capped=0 want
  STUB_LAST_DATE=""
  STUB_LAST_DAY=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    n=$((n + 1))
    if [ "$n" -le 24 ]; then
      case "$n" in
        1|12) want="---" ;;
        2) want="title: \"Compaction stub — session $id\"" ;;
        3) want="tier: medium" ;;
        4) want="tags: [tier/medium, type/project-log, compaction]" ;;
        5) want="status: active" ;;
        6) want="type: project-log" ;;
        7) want="project: \"\"" ;;
        8|9)
          case "$line" in
            created:\ \"*\"|last_reviewed:\ \"*\")
              want="$line"
              if [ "$n" -eq 8 ]; then
                created="${line#created: \"}"
                created="${created%\"}"
              else
                reviewed="${line#last_reviewed: \"}"
                reviewed="${reviewed%\"}"
              fi
              ;;
            *) return 1 ;;
          esac
          ;;
        10) want="session_id: \"$id\"" ;;
        11) want="source_notes: []" ;;
        13|15|22|24) want="" ;;
        14) want="# Compaction stub" ;;
        16) want="Auto-written by the PostCompact hook so this session's material is" ;;
        17) want="recoverable even when no summary was generated" ;;
        18) want="([Claude Code #34556](https://github.com/anthropics/claude-code/issues/34556))." ;;
        19) want="Not a substitute for \`/wrap-up\` or \`/obsidian-save\` — capture the actual" ;;
        20) want="work into a proper project log when you can. Excluded from dream-agent" ;;
        21) want="occurrence counting (see \`.claude/agents/dream-agent.md\`)." ;;
        23) want="## Compactions" ;;
      esac
      [ "$line" = "$want" ] || return 1
      continue
    fi
    # Past the template every line is an entry, and the cap line may only be the
    # last of them.
    [ "$capped" -eq 0 ] || return 1
    if stub_entry_ok "$line"; then
      entries=$((entries + 1))
      STUB_LAST_DATE="$ENTRY_DATE"
      STUB_LAST_DAY="$DATE_DAY"
    elif stub_cap_ok "$line"; then
      capped=1
    else
      return 1
    fi
  done < "$f"
  [ "$n" -gt 24 ] || return 1
  [ "$entries" -ge 1 ] && [ "$entries" -le "$STUB_MAX_ENTRIES" ] || return 1
  [ -n "$created" ] && [ "$created" = "$reviewed" ] || return 1
  date_day "$created" || return 1
  # The hook asks the clock twice, once for the note date and once for the first
  # entry, so a stub written just before midnight may be dated the day before.
  local cday="$DATE_DAY" fday
  date_day "$STUB_FIRST_DATE" || return 1
  fday="$DATE_DAY"
  [ "$cday" -eq "$fday" ] || [ "$cday" -eq $((fday - 1)) ] || return 1
  return 0
}

# stub_first_date <file>
# The date of the first entry, which stub_template_ok compares the note date
# against.
STUB_FIRST_DATE=""
stub_first_date() {
  local line
  STUB_FIRST_DATE=""
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      "- "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" "*)
        STUB_FIRST_DATE="${line:2:10}"
        return 0
        ;;
    esac
  done < "$1"
  return 1
}

# stub_versions <path>
# Every version of the stub that was ever committed, oldest first, written one
# per file so the bytes can be compared without going through a parser.
# Prints how many there are.
stub_versions() {
  local path="$1" n=0 sha
  rm -f "$SNAP_DIR"/ver.* 2>/dev/null
  while IFS= read -r sha; do
    n=$((n + 1))
    rgit cat-file blob "$sha:$path" > "$SNAP_DIR/ver.$n" 2>/dev/null || return 1
  done < <(LC_ALL=C awk -F '\t' -v p="$path" '$4 == p { print $1 "\t" $2 }' "$SNAP_DIR/touch" \
             | LC_ALL=C sort -rn | cut -f2)
  printf '%s\n' "$n"
  return 0
}

# ends_with_newline <file>
ends_with_newline() {
  [ -s "$1" ] || return 1
  [ "$(tail -c 1 "$1" | od -An -c 2>/dev/null | tr -d ' ')" = "\\n" ]
}

# is_line_prefix <earlier file> <later file>
# True when every line of the earlier file is the start of the later one, in
# order. Both files end in a newline, which is checked first, so a whole-line
# prefix and a byte prefix are the same thing here.
is_line_prefix() {
  LC_ALL=C awk -v a="$1" '
    BEGIN { n = 0; while ((getline l < a) > 0) { n++; A[n] = l } close(a) }
    { if (FNR <= n && $0 != A[FNR]) exit 1 }
    END { if (FNR < n) exit 1 }' "$2"
}

# ----------------------------------------------------------- classification --

# classify_journals
# Runs the checks in the order their reasons should be read in. Everything that
# needs git is asked once, in batches, before any of this.
classify_journals() {
  local i=0 name path reason nmv add addst new hasret hasvp dreamn headblob addblob
  while [ "$i" -lt "$C_N" ]; do
    if [ "${C_KIND[$i]}" != journal ] || [ -n "${C_VERDICT[$i]}" ]; then
      i=$((i + 1))
      continue
    fi
    name="${C_NAME[$i]}"
    path="$LOGS_REL/$name"
    reason="$(frontmatter_reason "$ROOT/$path")"
    if [ -n "$reason" ]; then
      refuse "$i" "$reason"
      i=$((i + 1))
      continue
    fi
    if [ "${C_DAY[$i]}" -gt "$TODAY_DAY" ]; then
      refuse "$i" "date in the future, so it is not a journal of a pass that has run"
      i=$((i + 1))
      continue
    fi
    nmv="$(fact "$path" 2)"
    add="$(fact "$path" 3)"
    addst="$(fact "$path" 4)"
    new="$(fact "$path" 5)"
    hasret="$(fact "$path" 6)"
    hasvp="$(fact "$path" 7)"
    dreamn="$(fact "$path" 8)"
    if [ "$hasret" = 1 ]; then
      refuse "$i" "restored after an earlier retention move, so moving it again would undo whatever brought it back"
      i=$((i + 1))
      continue
    fi
    if ! merge_ok "$path"; then
      refuse "$i" "a merge changed it, so its content was decided by whoever resolved that merge"
      i=$((i + 1))
      continue
    fi
    if [ "$nmv" != 1 ] || [ "$addst" != A ]; then
      refuse "$i" "changed after the dream pass wrote it, so it is no longer only what a machine produced"
      i=$((i + 1))
      continue
    fi
    headblob="${C_BLOB[$i]}"
    addblob="$(blob_of "$add" "$path")"
    if [ "$hasvp" = 0 ]; then
      # Nothing in its history claims to be a pass. Either it predates the
      # runners, or something else committed it.
      if [ -z "$FIRST_VP" ] || rgit merge-base --is-ancestor "$new" "$FIRST_VP" >/dev/null 2>&1; then
        C_VERDICT[$i]=LEGACY
      else
        refuse "$i" "committed without a dream trailer, for example by a sync plugin that reached it before the runner did"
      fi
      i=$((i + 1))
      continue
    fi
    if [ "$dreamn" != 1 ] || [ "$addblob" = - ] || ! trailer_check "$add" "$path" "$addblob"; then
      refuse "$i" "trailers do not match the commit, so the commit was rewritten after the pass made it"
      i=$((i + 1))
      continue
    fi
    if [ "$headblob" = - ] || [ "$headblob" != "$addblob" ]; then
      refuse "$i" "changed after the dream pass wrote it, so it is no longer only what a machine produced"
      i=$((i + 1))
      continue
    fi
    # A name may be one day ahead of the commit that added it, because a pass
    # that starts before midnight and commits after it dates the journal by the
    # day it began. More than that means the name was chosen, not computed.
    if date_day "$(fact "$path" 9)" && [ "${C_DAY[$i]}" -gt "$((DATE_DAY + 1))" ]; then
      refuse "$i" "date in the future, so it is not a journal of a pass that has run"
      i=$((i + 1))
      continue
    fi
    C_VERDICT[$i]=ELIGIBLE
    i=$((i + 1))
  done
  return 0
}

# classify_stubs
classify_stubs() {
  local i=0 name path nv v prev reason
  while [ "$i" -lt "$C_N" ]; do
    if [ "${C_KIND[$i]}" != stub ] || [ -n "${C_VERDICT[$i]}" ]; then
      i=$((i + 1))
      continue
    fi
    name="${C_NAME[$i]}"
    path="$LOGS_REL/$name"
    stub_name_ok "$name" || { refuse "$i" "not a stub name"; i=$((i + 1)); continue; }
    nv="$(stub_versions "$path")" || { refuse "$i" "one of its committed versions could not be read"; i=$((i + 1)); continue; }
    if [ "${nv:-0}" -lt 1 ]; then
      refuse "$i" "no commit in the history of $LOGS_REL adds it"
      i=$((i + 1))
      continue
    fi
    # Every version has to end in a newline and extend the one before it. A stub
    # the hook wrote only ever grows by whole lines at the end, so anything else
    # is a person editing, and the reason says so before the template is even
    # looked at.
    reason=""
    v=1
    while [ "$v" -le "$nv" ]; do
      ends_with_newline "$SNAP_DIR/ver.$v" || { reason="stub rewritten, because one committed version does not end in a newline"; break; }
      if [ "$v" -gt 1 ]; then
        prev=$((v - 1))
        is_line_prefix "$SNAP_DIR/ver.$prev" "$SNAP_DIR/ver.$v" \
          || { reason="stub rewritten, because a committed version is not the one before it with more entries added"; break; }
      fi
      v=$((v + 1))
    done
    if [ -n "$reason" ]; then
      refuse "$i" "$reason"
      i=$((i + 1))
      continue
    fi
    v=1
    while [ "$v" -le "$nv" ]; do
      if ! stub_first_date "$SNAP_DIR/ver.$v" || ! stub_template_ok "$SNAP_DIR/ver.$v" "$SN_ID"; then
        reason="not the hook's stub, so somebody has written in it"
        break
      fi
      v=$((v + 1))
    done
    if [ -n "$reason" ]; then
      refuse "$i" "$reason"
      i=$((i + 1))
      continue
    fi
    # The newest version is the one HEAD holds, and its last entry is when the
    # session was last active.
    if [ "$(rgit hash-object -- "$SNAP_DIR/ver.$nv" 2>/dev/null)" != "${C_BLOB[$i]}" ]; then
      refuse "$i" "stub rewritten, because the newest committed version is not what HEAD holds"
      i=$((i + 1))
      continue
    fi
    C_DATE[$i]="$STUB_LAST_DATE"
    C_DAY[$i]="$STUB_LAST_DAY"
    C_VERDICT[$i]=ELIGIBLE
    i=$((i + 1))
  done
  return 0
}

# keep_rule
# Age first, then the newest eight dates. The keep rule reads only candidates
# that nothing else has refused, so a journal with a date in the future or a
# name nobody recognises cannot push a real one out of the window.
keep_rule() {
  local i=0 dates=""
  # The window is worked out before either rule is applied. Taking it after the
  # age rule had run would leave only the old journals in the pool, and the
  # newest eight of those is all of them, so nothing would ever move.
  # Journals only, because a compaction stub is not something a later pass reads
  # back, so it does not hold a date open.
  : > "$SNAP_DIR/keepdates"
  while [ "$i" -lt "$C_N" ]; do
    case "${C_VERDICT[$i]}" in
      ELIGIBLE|LEGACY)
        [ "${C_KIND[$i]}" = journal ] && printf '%s\n' "${C_DATE[$i]}" >> "$SNAP_DIR/keepdates"
        ;;
    esac
    i=$((i + 1))
  done
  dates=" $(LC_ALL=C sort -ru "$SNAP_DIR/keepdates" 2>/dev/null | head -n 8 | tr '\n' ' ')"
  i=0
  while [ "$i" -lt "$C_N" ]; do
    case "${C_VERDICT[$i]}" in
      ELIGIBLE|LEGACY)
        if [ "$((TODAY_DAY - ${C_DAY[$i]}))" -le "$RETENTION_DAYS" ]; then
          C_VERDICT[$i]=KEPT
          KEPT_NEW=$((KEPT_NEW + 1))
        elif [ "${C_KIND[$i]}" = journal ]; then
          case "$dates" in
            *" ${C_DATE[$i]} "*)
              C_VERDICT[$i]=KEPT
              KEPT_EIGHT=$((KEPT_EIGHT + 1))
              ;;
          esac
        fi
        ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# destination_rule
# A candidate whose name is already taken in the archive stays. For a journal
# that is a collision worth a line each time, because the two files are
# different notes with one name. For a stub it means the session came back to
# life after an earlier run archived it, which is ordinary.
destination_rule() {
  local i=0 name
  while [ "$i" -lt "$C_N" ]; do
    case "${C_VERDICT[$i]}" in
      ELIGIBLE|LEGACY)
        name="${C_NAME[$i]}"
        if [ -e "$ROOT/$ARCH_REL/$name" ] || [ -L "$ROOT/$ARCH_REL/$name" ] \
           || [ "$(blob_of HEAD "$ARCH_REL/$name")" != - ]; then
          # Set here rather than through refuse and quiet, because both of those
          # keep the first reason and by this point the verdict is already
          # ELIGIBLE. Going through them would do nothing at all, and the file
          # would go into the move set with its name already taken.
          if [ "${C_KIND[$i]}" = journal ]; then
            C_VERDICT[$i]=REFUSED
            C_REASON[$i]="destination exists, so moving it would write over a different note of the same name"
          else
            C_VERDICT[$i]=QUIET
            QUIET_TAKEN=$((QUIET_TAKEN + 1))
          fi
        fi
        ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# log_verdicts
# One line for each candidate a person may want to act on, and a count for the
# groups that are ordinary.
log_verdicts() {
  local i=0 p e=0 l=0 k=0 r=0
  while [ "$i" -lt "$C_N" ]; do
    p="$LOGS_REL/${C_NAME[$i]}"
    case "${C_VERDICT[$i]}" in
      ELIGIBLE) e=$((e + 1)); say "ELIGIBLE: $p" ;;
      LEGACY)   l=$((l + 1)); say "LEGACY: $p (committed before any runner wrote trailers, so it moves only with --adopt-legacy)" ;;
      KEPT)     k=$((k + 1)) ;;
      *)        r=$((r + 1)); [ "${C_VERDICT[$i]}" = REFUSED ] && say "REFUSED: $p (${C_REASON[$i]})" ;;
    esac
    i=$((i + 1))
  done
  r=$((r + REFUSED_EARLY))
  [ "$KEPT_NEW" -gt 0 ] && say "  $KEPT_NEW candidate(s) kept because they are newer than $RETENTION_DAYS days."
  [ "$KEPT_EIGHT" -gt 0 ] && say "  $KEPT_EIGHT journal(s) kept by the newest eight dates, so a later pass still has recent ones to read."
  [ "$QUIET_UNTRACKED" -gt 0 ] && say "  $QUIET_UNTRACKED compaction stub(s) not tracked by git."
  [ "$QUIET_TAKEN" -gt 0 ] && say "  $QUIET_TAKEN compaction stub(s) whose name is already in the archive, so the session resumed after archiving."
  say "evaluated $((C_N + REFUSED_EARLY)) candidate(s): $e eligible, $l legacy, $k kept, $r refused, $MOVED_N moved"
  return 0
}
# ------------------------------------------------------------- index state --

# in_set <value> <set>
# Membership without a process per question. The set is newline separated with
# a newline at each end, and no candidate name may hold a newline, because
# enumerate_candidates refuses those before anything else sees them.
in_set() {
  case "$2" in
    *"
$1
"*) return 0 ;;
  esac
  return 1
}

# pre_checks
# Everything that can be judged without reading history. Name, type, and what
# the index says about the file.
pre_checks() {
  local i=0 name path tag p rec tracked flagged dirty
  : > "$SNAP_DIR/tracked"
  : > "$SNAP_DIR/flagged"
  : > "$SNAP_DIR/dirty"
  # One call for every tracked path in the folder and the flags on it. A lower
  # case tag is assume-unchanged and S is skip-worktree. Either one tells git to
  # stop looking at the file, which is exactly the state in which a move would
  # quietly lose somebody's work.
  rgit ls-files -v -z -- "$LOGS_REL" > "$SNAP_DIR/lsfiles" 2>/dev/null
  while IFS= read -r -d '' rec; do
    tag="${rec%% *}"
    p="${rec#* }"
    printf '%s\n' "$p" >> "$SNAP_DIR/tracked"
    case "$tag" in
      [a-z]|S) printf '%s\n' "$p" >> "$SNAP_DIR/flagged" ;;
    esac
  done < "$SNAP_DIR/lsfiles"
  # Dirtiness comes from status, not from diff-index. diff-index believes the
  # stat information the index recorded, and a vault that has been copied,
  # restored from a backup or handed over by a sync client has stat information
  # that no longer matches while every byte is identical. Asked that way, every
  # journal in the vault looks edited and nothing is ever archived.
  # --no-optional-locks keeps this a question rather than a write, so the runner
  # does not take the index lock to find out.
  rgit --no-optional-locks status --porcelain -z --untracked-files=all -- "$LOGS_REL" \
    > "$SNAP_DIR/status" 2>/dev/null
  while IFS= read -r -d '' rec; do
    [ -n "$rec" ] || continue
    tag="${rec:0:2}"
    p="${rec:3}"
    case "$tag" in
      '??') continue ;;
      R*|C*)
        # A rename or a copy is reported as the new path and then the old one in
        # a record of its own. Both of them have changed.
        printf '%s\n' "$p" >> "$SNAP_DIR/dirty"
        if IFS= read -r -d '' rec; then
          [ -n "$rec" ] && printf '%s\n' "$rec" >> "$SNAP_DIR/dirty"
        fi
        continue
        ;;
    esac
    printf '%s\n' "$p" >> "$SNAP_DIR/dirty"
  done < "$SNAP_DIR/status"
  tracked="
$(cat "$SNAP_DIR/tracked" 2>/dev/null)
"
  flagged="
$(cat "$SNAP_DIR/flagged" 2>/dev/null)
"
  dirty="
$(cat "$SNAP_DIR/dirty" 2>/dev/null)
"
  while [ "$i" -lt "$C_N" ]; do
    name="${C_NAME[$i]}"
    path="$LOGS_REL/$name"
    if [ "${C_KIND[$i]}" = journal ]; then
      if journal_name_ok "$name"; then
        C_DATE[$i]="$JN_DATE"
        C_DAY[$i]="$JN_DAY"
      else
        refuse "$i" "not a journal name, so no pass of this runner produced it"
        i=$((i + 1))
        continue
      fi
    fi
    if [ -L "$ROOT/$path" ] || [ ! -f "$ROOT/$path" ]; then
      refuse "$i" "not a regular file, so what a move would carry is not the note itself"
      i=$((i + 1))
      continue
    fi
    if ! in_set "$path" "$tracked"; then
      if [ "${C_KIND[$i]}" = stub ]; then
        quiet "$i" untracked
      else
        refuse "$i" "not tracked by git, so nothing records who wrote it"
      fi
      i=$((i + 1))
      continue
    fi
    if in_set "$path" "$flagged"; then
      refuse "$i" "index flag skip-worktree or assume-unchanged is set on it, so git is not watching it"
      i=$((i + 1))
      continue
    fi
    if in_set "$path" "$dirty"; then
      refuse "$i" "uncommitted changes, so what is on disk is not what was committed"
      i=$((i + 1))
      continue
    fi
    i=$((i + 1))
  done
  return 0
}

# ask_batches
# Every object question this run has, asked in as few git calls as the answers
# allow. The order matters, because the adding commit of each journal is only
# known after the history tables are joined.
ask_batches() {
  local i=0 path rc=0 sha parents par
  : > "$SNAP_DIR/jpaths"
  i=0
  while [ "$i" -lt "$C_N" ]; do
    [ "${C_KIND[$i]}" = journal ] && [ -z "${C_VERDICT[$i]}" ] \
      && printf '%s\n' "$LOGS_REL/${C_NAME[$i]}" >> "$SNAP_DIR/jpaths"
    i=$((i + 1))
  done
  journal_facts

  : > "$SNAP_DIR/batch.in"
  i=0
  while [ "$i" -lt "$C_N" ]; do
    if [ -z "${C_VERDICT[$i]}" ] || [ "${C_VERDICT[$i]}" = QUIET ]; then
      blob_ask HEAD "$LOGS_REL/${C_NAME[$i]}"
      blob_ask HEAD "$ARCH_REL/${C_NAME[$i]}"
    fi
    i=$((i + 1))
  done
  # The adding commit of each journal, and every merge the path passed through.
  LC_ALL=C awk -F '\t' '$3 != "-" { print $1 "\t" $3 }' "$SNAP_DIR/jfacts" > "$SNAP_DIR/adds"
  while IFS=$'\t' read -r path sha; do
    [ -n "$path" ] && blob_ask "$sha" "$path"
  done < "$SNAP_DIR/adds"
  LC_ALL=C awk -F '\t' '$3 == 1 { print $2 "\t" $8 }' "$SNAP_DIR/commits" > "$SNAP_DIR/merges"
  if [ -s "$SNAP_DIR/merges" ]; then
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      while IFS=$'\t' read -r sha parents; do
        blob_ask "$sha" "$path"
        for par in $parents; do blob_ask "$par" "$path"; done
      done < "$SNAP_DIR/merges"
    done < "$SNAP_DIR/jpaths"
  fi
  blob_run
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  # What each adding commit changed, in all folders, so a commit cannot claim in
  # its trailers to have written only the journal while it also wrote elsewhere.
  : > "$SNAP_DIR/changed"
  LC_ALL=C awk -F '\t' '{ print $2 }' "$SNAP_DIR/adds" | LC_ALL=C sort -u > "$SNAP_DIR/addshas"
  if [ -s "$SNAP_DIR/addshas" ]; then
    if ! watched_git "$SNAP_DIR/difftree" "$SNAP_DIR/addshas" \
        diff-tree -r --no-renames --name-only --root --stdin; then
      if [ "${RUN_TIMED_OUT:-0}" -eq 1 ]; then
        say "LOCKED: listing what each commit changed did not finish within ${GIT_TIMEOUT}s and was stopped, so nothing was judged."
        return 75
      fi
      say "ERROR: what each commit changed could not be listed. Refusing to run."
      return 1
    fi
    LC_ALL=C awk -v kf="$SNAP_DIR/addshas" '
      BEGIN { while ((getline l < kf) > 0) K[l] = 1; close(kf); cur = "" }
      { if ($0 in K) { cur = $0; next }
        if (cur != "" && $0 != "") printf "%s\t%s\n", cur, $0 }' \
      "$SNAP_DIR/difftree" > "$SNAP_DIR/changed"
  fi

  # The blob HEAD holds for each candidate, kept beside it for the checks that
  # follow and for the legacy report.
  i=0
  while [ "$i" -lt "$C_N" ]; do
    if [ -z "${C_VERDICT[$i]}" ] || [ "${C_VERDICT[$i]}" = QUIET ]; then
      C_BLOB[$i]="$(blob_of HEAD "$LOGS_REL/${C_NAME[$i]}")"
    fi
    i=$((i + 1))
  done
  return 0
}

# ------------------------------------------------------------------ legacy --

# legacy_report
# Journals from before any runner wrote trailers are listed once, with the blob
# HEAD holds, and move only when the owner comes back with that list. The list
# is bound to its content rather than to where it sits, so a copy of the report
# is as good as the original and an edited one is refused.
legacy_report() {
  local i=0 hash known report n=0
  : > "$SNAP_DIR/legacy.body"
  while [ "$i" -lt "$C_N" ]; do
    if [ "${C_VERDICT[$i]}" = LEGACY ]; then
      printf '%s\t%s\n' "$LOGS_REL/${C_NAME[$i]}" "${C_BLOB[$i]}" >> "$SNAP_DIR/legacy.body"
      n=$((n + 1))
    fi
    i=$((i + 1))
  done
  [ "$n" -gt 0 ] || return 0
  LC_ALL=C sort "$SNAP_DIR/legacy.body" > "$SNAP_DIR/legacy.sorted"
  mv -f "$SNAP_DIR/legacy.sorted" "$SNAP_DIR/legacy.body"
  # The file is named rather than fed on standard input, because safe_git hands
  # every command /dev/null there and the hash would be the hash of nothing,
  # which is the same for every report ever written.
  hash="$(rgit hash-object -- "$SNAP_DIR/legacy.body" 2>/dev/null)"
  if [ -z "$hash" ]; then
    say "WARNING: the legacy list could not be hashed, so no report was written this run."
    return 0
  fi
  known=""
  [ -f "$STATE/retention-legacy.hashes" ] && known="$(LC_ALL=C awk -v h="$hash" '
    $1 == h { sub(/^[^ ]* /, ""); print; exit }' "$STATE/retention-legacy.hashes")"
  if [ -n "$known" ]; then
    say "LEGACY: $n journal(s) from before the runner trailers are already listed in $known. Run vault-retention.sh --adopt-legacy \"$known\" to move them."
    return 0
  fi
  report="$STATE/retention-legacy-$TODAY-${hash:0:8}.txt"
  {
    printf '# Journals in %s that were committed before any runner wrote trailers.\n' "$ROOT"
    printf '# Written by vault-retention.sh on %s. Lines below are the path and the blob git holds.\n' "$TODAY"
    printf '# Review them, then move them with\n'
    printf '#   vault-retention.sh --adopt-legacy "%s"\n' "$report"
    cat "$SNAP_DIR/legacy.body"
  } > "$SNAP_DIR/legacy.report"
  if ! write_file_atomic "$report" "$SNAP_DIR/legacy.report"; then
    say "WARNING: the legacy report could not be written to $report, so nothing was recorded this run."
    return 0
  fi
  printf '%s %s\n' "$hash" "$report" >> "$STATE/retention-legacy.hashes"
  say "LEGACY: $n journal(s) from before the runner trailers are listed in $report. Review them, then run vault-retention.sh --adopt-legacy \"$report\" to move them."
  return 0
}

# adopt_legacy <report>
# Returns 64 for a report that cannot be read, 2 for one this runner never wrote
# or that has been changed since, and 0 when the list has been taken up.
adopt_legacy() {
  local report="$1" hash i path blob idx found
  if [ ! -f "$report" ] || [ ! -r "$report" ]; then
    say "USAGE: the report $report is not a readable file."
    return 64
  fi
  LC_ALL=C sed -e 's/\r$//' "$report" 2>/dev/null | LC_ALL=C awk '!/^#/' > "$SNAP_DIR/adopt.body"
  if ! LC_ALL=C sort -c "$SNAP_DIR/adopt.body" 2>/dev/null; then
    say "REPORT-REFUSED: the list in $report is not in the order this runner writes it, so it has been changed since."
    return 2
  fi
  hash="$(rgit hash-object -- "$SNAP_DIR/adopt.body" 2>/dev/null)"
  found=""
  [ -n "$hash" ] && [ -f "$STATE/retention-legacy.hashes" ] \
    && found="$(LC_ALL=C awk -v h="$hash" '$1 == h { print "yes"; exit }' "$STATE/retention-legacy.hashes")"
  if [ -z "$found" ]; then
    say "REPORT-REFUSED: $report is not a list this runner wrote, or it has been changed since. Run vault-retention.sh with no arguments to get a current one."
    return 2
  fi
  while IFS=$'\t' read -r path blob; do
    [ -n "$path" ] || continue
    idx=-1
    i=0
    while [ "$i" -lt "$C_N" ]; do
      [ "$LOGS_REL/${C_NAME[$i]}" = "$path" ] && idx=$i && break
      i=$((i + 1))
    done
    if [ "$idx" -lt 0 ]; then
      say "REFUSED: $path (listed in the report but no longer in $LOGS_REL)"
      REFUSED_EARLY=$((REFUSED_EARLY + 1))
      continue
    fi
    if [ "${C_VERDICT[$idx]}" = LEGACY ]; then
      if [ "${C_BLOB[$idx]}" = "$blob" ]; then
        C_ADOPT[$idx]=1
      else
        C_VERDICT[$idx]=REFUSED
        C_REASON[$idx]="changed since the report was written, so it is no longer the journal the owner reviewed"
      fi
    fi
  done < "$SNAP_DIR/adopt.body"
  return 0
}

# --------------------------------------------------------------- the moves --

# build_move_set
# Oldest first, so a cap always takes the ones that have waited longest.
build_move_set() {
  local i=0 n rest
  : > "$SNAP_DIR/moveset.raw"
  while [ "$i" -lt "$C_N" ]; do
    if [ "$ADOPT_MODE" -eq 1 ]; then
      [ "${C_ADOPT[$i]}" = 1 ] && printf '%s\t%s\t%s\n' "${C_DATE[$i]}" "${C_NAME[$i]}" "$i" >> "$SNAP_DIR/moveset.raw"
    else
      [ "${C_VERDICT[$i]}" = ELIGIBLE ] && printf '%s\t%s\t%s\n' "${C_DATE[$i]}" "${C_NAME[$i]}" "$i" >> "$SNAP_DIR/moveset.raw"
    fi
    i=$((i + 1))
  done
  # Two candidates whose names differ only in case would be one file in the
  # archive on a file system that does not tell them apart, and the second move
  # would write over the first. Neither goes.
  LC_ALL=C awk -F '\t' '
    { n = tolower($2); c[n]++; line[NR] = $0; key[NR] = n }
    END { for (i = 1; i <= NR; i++) if (c[key[i]] > 1) print line[i] }' \
    "$SNAP_DIR/moveset.raw" > "$SNAP_DIR/moveset.clash"
  if [ -s "$SNAP_DIR/moveset.clash" ]; then
    while IFS=$'\t' read -r _d n i; do
      C_VERDICT[$i]=REFUSED
      C_REASON[$i]="another candidate of this run differs from it only in case, so one archive name would have to hold both"
    done < "$SNAP_DIR/moveset.clash"
    LC_ALL=C awk -F '\t' '
      { n = tolower($2); c[n]++; line[NR] = $0; key[NR] = n }
      END { for (i = 1; i <= NR; i++) if (c[key[i]] == 1) print line[i] }' \
      "$SNAP_DIR/moveset.raw" > "$SNAP_DIR/moveset.kept"
    mv -f "$SNAP_DIR/moveset.kept" "$SNAP_DIR/moveset.raw"
  fi
  LC_ALL=C sort "$SNAP_DIR/moveset.raw" > "$SNAP_DIR/moveset.all"
  n="$(LC_ALL=C awk 'END { print NR + 0 }' "$SNAP_DIR/moveset.all")"
  if [ "$n" -gt "$MAX_MOVES" ]; then
    rest=$((n - MAX_MOVES))
    say "The cap is $MAX_MOVES move(s) a run, so $rest more wait for a later run."
    head -n "$MAX_MOVES" "$SNAP_DIR/moveset.all" > "$SNAP_DIR/moveset"
  else
    cp "$SNAP_DIR/moveset.all" "$SNAP_DIR/moveset"
  fi
  return 0
}

# load_moves
# Fills SRCS, DSTS and MBLOBS from the move set.
load_moves() {
  local d n i
  SRCS=()
  DSTS=()
  MBLOBS=()
  while IFS=$'\t' read -r d n i; do
    [ -n "$n" ] || continue
    SRCS[${#SRCS[@]}]="$LOGS_REL/$n"
    DSTS[${#DSTS[@]}]="$ARCH_REL/$n"
    MBLOBS[${#MBLOBS[@]}]="${C_BLOB[$i]}"
  done < "$SNAP_DIR/moveset"
  return 0
}

# write_recovery <state word>
# The record a later run reads when this one could not say what it did. Written
# by rename before the first move, so there is never a move with no record.
write_recovery() {
  local k=0
  {
    printf 'state %s\n' "$1"
    printf 'head %s\n' "$HEAD_BEFORE"
    printf 'nonce %s\n' "$RETENTION_NONCE"
    while [ "$k" -lt "${#SRCS[@]}" ]; do
      printf 'move %s\t%s\t%s\n' "${SRCS[$k]}" "${DSTS[$k]}" "${MBLOBS[$k]}"
      k=$((k + 1))
    done
  } > "$SNAP_DIR/recovery"
  write_file_atomic "$STATE/retention-inflight" "$SNAP_DIR/recovery"
}

# make_dirs
# The archive folders, one level at a time and never with -p, so a folder that
# appears between two checks is noticed rather than made part of the path.
make_dirs() {
  local rel
  for rel in 99-archive 99-archive/20-projects "$ARCH_REL"; do
    if [ ! -e "$ROOT/$rel" ] && [ ! -L "$ROOT/$rel" ]; then
      if ! mkdir "$ROOT/$rel" 2>/dev/null; then
        say "ERROR: the folder $rel could not be made, so nothing was moved."
        return 1
      fi
      MADE_DIRS="$rel
$MADE_DIRS"
    fi
    if ! real_dir_ok "$rel"; then
      say "PATH-BLOCKED: $rel is a link, a junction or not a folder, so nothing is moved through it."
      return 1
    fi
  done
  return 0
}

# drop_made_dirs
# Undoes make_dirs, deepest first, and only while each is still empty.
drop_made_dirs() {
  local rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    rmdir "$ROOT/$rel" 2>/dev/null
  done <<EOF
$MADE_DIRS
EOF
  MADE_DIRS=""
  return 0
}

# index_of_moves
# One call that says, for every source and destination of this run, what the
# index holds. Written as <path><TAB><blob>.
index_of_moves() {
  : > "$SNAP_DIR/idx"
  rgit ls-files -s -z -- "${SRCS[@]}" "${DSTS[@]}" 2>/dev/null \
    | tr '\0' '\n' \
    | LC_ALL=C awk '{ t = index($0, "\t"); if (t > 0) { split(substr($0, 1, t - 1), f, " "); printf "%s\t%s\n", substr($0, t + 1), f[2] } }' \
    > "$SNAP_DIR/idx"
  return 0
}

# idx_blob <path>
idx_blob() {
  LC_ALL=C awk -F '\t' -v p="$1" '$1 == p { print $2; f = 1; exit } END { if (!f) print "-" }' "$SNAP_DIR/idx"
}

# do_moves
# One git mv for the whole set. Returns 0 when every file is where it should be,
# 3 when nothing moved in the end, and 71 when the way back could not be walked.
do_moves() {
  make_dirs || return 3
  index_lock_wait
  if watched_git "$SNAP_DIR/mv.out" /dev/null mv -- "${SRCS[@]}" "$ARCH_REL/"; then
    printf 'done\n' >> "$STATE/retention-inflight" 2>/dev/null
    return 0
  fi
  # git will not touch the index while another process holds its lock, and a
  # sync client or an editor takes it for a moment all the time. That is worth
  # one wait and one more try before anything is undone.
  if [ -n "$(git_index_lock_path "$ROOT")" ] && [ -e "$(git_index_lock_path "$ROOT")" ]; then
    say "The index was locked by another git process, so the move waits for it."
    index_lock_wait
    if watched_git "$SNAP_DIR/mv.out" /dev/null mv -- "${SRCS[@]}" "$ARCH_REL/"; then
      printf 'done\n' >> "$STATE/retention-inflight" 2>/dev/null
      return 0
    fi
  fi
  say "PARTIAL: the move failed, so the vault is being put back to what HEAD holds."
  while IFS= read -r line; do say "    git: $line"; done < "$SNAP_DIR/git.err"
  put_back && return 3
  return 71
}

# put_back
# Reconciles from what is actually on disk and in the index rather than from how
# far the run is thought to have got, because the two disagree exactly when this
# is needed. True when every source is back at HEAD and no destination is left.
put_back() {
  local k=0 src dst ok=1
  index_lock_wait
  index_of_moves
  while [ "$k" -lt "${#SRCS[@]}" ]; do
    src="${SRCS[$k]}"
    dst="${DSTS[$k]}"
    if [ "$(idx_blob "$dst")" != - ]; then
      watched_git "$SNAP_DIR/mv.out" /dev/null mv -f -- "$dst" "$src" || ok=0
    elif [ -e "$ROOT/$dst" ] && [ ! -e "$ROOT/$src" ]; then
      mv -f "$ROOT/$dst" "$ROOT/$src" 2>/dev/null || ok=0
    fi
    k=$((k + 1))
  done
  drop_made_dirs
  index_of_moves
  k=0
  while [ "$k" -lt "${#SRCS[@]}" ]; do
    [ "$(idx_blob "${SRCS[$k]}")" = "${MBLOBS[$k]}" ] || ok=0
    [ "$(idx_blob "${DSTS[$k]}")" = - ] || ok=0
    [ -e "$ROOT/${DSTS[$k]}" ] && ok=0
    k=$((k + 1))
  done
  if [ "$ok" -eq 1 ]; then
    rm -f "$STATE/retention-inflight" 2>/dev/null
    MOVING=0
    say "The vault is back at HEAD and nothing was moved."
    return 0
  fi
  write_recovery putback-failed
  say "RECOVERY-NEEDED: the vault could not be put back. $STATE/retention-inflight says where each file should be. Put them back, then run again."
  return 1
}

# verify_moves
# The index has to agree with what was judged, or the thing that was moved is
# not the thing that was read.
verify_moves() {
  local k=0 ok=1
  index_of_moves
  while [ "$k" -lt "${#SRCS[@]}" ]; do
    [ "$(idx_blob "${DSTS[$k]}")" = "${MBLOBS[$k]}" ] || ok=0
    [ "$(idx_blob "${SRCS[$k]}")" = - ] || ok=0
    k=$((k + 1))
  done
  rgit diff --quiet -- "${DSTS[@]}" 2>/dev/null || ok=0
  [ "$ok" -eq 1 ] && return 0
  say "PARTIAL: after the move the index does not hold what was judged, so the vault is being put back."
  return 1
}

# head_holds_moves
# True when HEAD holds every destination with the blob that was judged and no
# source at all. Asked fresh rather than from the batch taken before the move.
head_holds_moves() {
  local k=0 ok=1
  : > "$SNAP_DIR/after.in"
  while [ "$k" -lt "${#SRCS[@]}" ]; do
    printf 'HEAD:%s\n' "${DSTS[$k]}" >> "$SNAP_DIR/after.in"
    printf 'HEAD:%s\n' "${SRCS[$k]}" >> "$SNAP_DIR/after.in"
    k=$((k + 1))
  done
  # watched_git rather than rgit, because rgit goes through safe_git, which
  # gives every command /dev/null for standard input. A batch question asked
  # that way is no question at all, and every answer comes back missing.
  watched_git "$SNAP_DIR/after.out" "$SNAP_DIR/after.in" cat-file --batch-check || return 1
  LC_ALL=C awk -v q="$SNAP_DIR/after.in" '
    BEGIN { n = 0; while ((getline l < q) > 0) { n++; ask[n] = l } close(q); i = 0 }
    { i++
      if (i > n) next
      v = "-"
      if ($NF != "missing") { split($0, f, " "); if (f[2] == "blob") v = f[1] }
      printf "%s\t%s\n", ask[i], v }' "$SNAP_DIR/after.out" > "$SNAP_DIR/after"
  k=0
  while [ "$k" -lt "${#SRCS[@]}" ]; do
    [ "$(LC_ALL=C awk -F '\t' -v p="HEAD:${DSTS[$k]}" '$1 == p { print $2; exit }' "$SNAP_DIR/after")" = "${MBLOBS[$k]}" ] || ok=0
    [ "$(LC_ALL=C awk -F '\t' -v p="HEAD:${SRCS[$k]}" '$1 == p { print $2; exit }' "$SNAP_DIR/after")" = - ] || ok=0
    k=$((k + 1))
  done
  [ "$ok" -eq 1 ]
}

# do_commit
do_commit() {
  local k=0
  {
    printf 'retention pass: moved %s file(s) to 99-archive/\n\n' "${#SRCS[@]}"
    printf 'Vault-Pass: retention\n'
    printf 'Vault-Retention-Run: %s\n' "$RETENTION_NONCE"
    while [ "$k" -lt "${#SRCS[@]}" ]; do
      printf 'Vault-Retention-Move: %s -> %s\n' "${SRCS[$k]}" "${DSTS[$k]}"
      k=$((k + 1))
    done
  } > "$SNAP_DIR/commit-msg"
  index_lock_wait
  watched_git "$SNAP_DIR/commit.out" /dev/null -c gc.auto=0 -c maintenance.auto=false \
    commit -q --only --cleanup=verbatim -F "$SNAP_DIR/commit-msg" -- "${SRCS[@]}" "${DSTS[@]}"
  return 0
}

# settle_outcome [<signal note>]
# What this run actually did, judged from the repository rather than from the
# exit code of the last command. Also what a signal and a later run use, so
# there is one answer to the question and not three.
settle_outcome() {
  local head_now parent msg
  if [ "${RUN_KILL_FAILED:-0}" -eq 1 ]; then
    mark_kill_failed "$LOG" "${RUN_KILL_REPORT:-}"
    write_recovery kill-failed
    say "RECOVERY-NEEDED: a git command of this run was stopped and may still be running, so what it did is not known and nothing is put back. $STATE/retention-inflight says what was being moved."
    MOVING=0
    return 71
  fi
  head_now="$(rgit rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)"
  if [ -z "$head_now" ]; then
    write_recovery head-unreadable
    say "RECOVERY-NEEDED: HEAD could not be read after the move, so what this run did is not known. $STATE/retention-inflight says what was being moved."
    MOVING=0
    return 71
  fi
  if [ "$head_now" = "$HEAD_BEFORE" ]; then
    say "COMMIT-FAILED: nothing was committed, so the vault is being put back to what HEAD holds."
    if put_back; then
      MOVING=0
      return 4
    fi
    MOVING=0
    return 71
  fi
  parent="$(rgit rev-parse -q --verify "$head_now^1" 2>/dev/null)"
  msg="$(rgit log -1 --format=%B "$head_now" 2>/dev/null)"
  if [ "$parent" = "$HEAD_BEFORE" ] && printf '%s\n' "$msg" | LC_ALL=C grep -qxF "Vault-Retention-Run: $RETENTION_NONCE"; then
    if head_holds_moves; then
      rm -f "$STATE/retention-inflight" 2>/dev/null
      MOVING=0
      MOVED_N="${#SRCS[@]}"
      say "OK: $MOVED_N file(s) moved to $ARCH_REL and committed as $head_now."
      return 0
    fi
    write_recovery commit-mismatch
    say "RECOVERY-NEEDED: the commit was made but HEAD does not hold what was judged, so it is left alone. $STATE/retention-inflight says what was being moved."
    MOVING=0
    return 71
  fi
  # Something else committed while this run was working. A commit that may hold
  # the moves is never put back, because undoing it would undo whatever else it
  # carried.
  if rgit merge-base --is-ancestor "$HEAD_BEFORE" "$head_now" >/dev/null 2>&1 && head_holds_moves; then
    rm -f "$STATE/retention-inflight" 2>/dev/null
    MOVING=0
    MOVED_N="${#SRCS[@]}"
    say "NOTE: another tool committed the moves before this run could, so they are left as they are. HEAD is $head_now."
    return 0
  fi
  write_recovery head-moved
  say "RECOVERY-NEEDED: HEAD moved to $head_now while this run was working and it does not hold the moves, so nothing is put back. $STATE/retention-inflight says what was being moved."
  MOVING=0
  return 71
}

# recovery_check
# A record an earlier run left. It clears itself when the repository shows the
# question is settled, either because the commit landed or because everything is
# back where it started. Anything else stops the run, because a second set of
# moves on top of an unknown first one is how a vault loses a note.
recovery_check() {
  local f="$STATE/retention-inflight" key rest rhead rnonce headnow landed=1 undone=1 n=0
  [ -e "$f" ] || return 0
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    say "TRIPWIRE: $f is not a readable file, so what an earlier run was doing cannot be established. Look at it, then remove it."
    return 78
  fi
  rhead=""
  rnonce=""
  SRCS=()
  DSTS=()
  MBLOBS=()
  while IFS=' ' read -r key rest; do
    case "$key" in
      head) rhead="$rest" ;;
      nonce) rnonce="$rest" ;;
      move)
        n=$((n + 1))
        SRCS[${#SRCS[@]}]="$(printf '%s' "$rest" | cut -f1)"
        DSTS[${#DSTS[@]}]="$(printf '%s' "$rest" | cut -f2)"
        MBLOBS[${#MBLOBS[@]}]="$(printf '%s' "$rest" | cut -f3)"
        ;;
    esac
  done < "$f"
  headnow="$(rgit rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)"
  if [ "$n" -eq 0 ] || [ -z "$rhead" ] || [ -z "$headnow" ]; then
    say "TRIPWIRE: $f does not say what an earlier run was moving, so it cannot be cleared here. Look at it, then remove it."
    return 78
  fi
  # The commit landed, and HEAD holds every destination and no source.
  if [ -n "$rnonce" ] \
     && rgit log -1 --format=%B "$headnow" 2>/dev/null | LC_ALL=C grep -qxF "Vault-Retention-Run: $rnonce" \
     && head_holds_moves; then
    rm -f "$f" 2>/dev/null
    say "An earlier run left a record of moves that did land, in $headnow. The record is cleared and this run goes on."
    return 0
  fi
  # Or nothing moved, everything is back at HEAD, and HEAD is where it was.
  index_of_moves
  if [ "$headnow" = "$rhead" ]; then
    local k=0
    while [ "$k" -lt "${#SRCS[@]}" ]; do
      [ "$(idx_blob "${SRCS[$k]}")" = "${MBLOBS[$k]}" ] || undone=0
      [ "$(idx_blob "${DSTS[$k]}")" = - ] || undone=0
      [ -e "$ROOT/${DSTS[$k]}" ] && undone=0
      k=$((k + 1))
    done
  else
    undone=0
  fi
  if [ "$undone" -eq 1 ]; then
    rm -f "$f" 2>/dev/null
    say "An earlier run left a record of moves that did not happen, and the vault is back where it started. The record is cleared and this run goes on."
    return 0
  fi
  landed=0
  say "TRIPWIRE: an earlier run could not say what its moves did, and the vault does not yet show either outcome. Nothing is moved until this is settled."
  say "  the record is $f, and HEAD was $rhead when it was written"
  local k=0
  while [ "$k" -lt "${#SRCS[@]}" ]; do
    say "  $(printf '%s' "${SRCS[$k]}") work tree $([ -e "$ROOT/${SRCS[$k]}" ] && echo present || echo absent), index $(idx_blob "${SRCS[$k]}")"
    say "  $(printf '%s' "${DSTS[$k]}") work tree $([ -e "$ROOT/${DSTS[$k]}" ] && echo present || echo absent), index $(idx_blob "${DSTS[$k]}")"
    k=$((k + 1))
  done
  say "  put every file back where the record says it belongs, or finish the move by hand, then remove $f"
  return 78
}

# ------------------------------------------------------------------- main --

usage() {
  say "USAGE: vault-retention.sh [--dry-run | --adopt-legacy <report>]"
  return 0
}

main() {
  local rc=0 lock_rc=0 state_rc=0 folder_rc=0
  ADOPT_MODE=0
  DRY_RUN=0
  ADOPT_REPORT=""
  SRCS=()
  DSTS=()
  MBLOBS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --adopt-legacy)
        ADOPT_MODE=1
        shift
        ADOPT_REPORT="${1:-}"
        [ -n "$ADOPT_REPORT" ] || { printf 'vault-retention.sh: --adopt-legacy needs the report to adopt\n' >&2; return 64; }
        ;;
      *)
        printf 'vault-retention.sh: unknown option %s\n' "$1" >&2
        return 64
        ;;
    esac
    shift
  done

  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  cd "$ROOT" || return 1
  # shellcheck source=lib/runner-common.sh
  . "$ROOT/.claude/scripts/lib/runner-common.sh"
  ROOT_REAL="$(pwd -P)"

  LOG_DIR="$ROOT/.claude/logs"
  mkdir -p "$LOG_DIR" 2>/dev/null
  LOG="$LOG_DIR/vault-retention.log"
  # Anything that reaches arithmetic is checked first, because the shell reads a
  # variable in arithmetic as an expression and a planted one would run.
  RETENTION_DAYS="$(uint_setting RETENTION_DAYS 60 1 "$LOG" days)"
  MAX_MOVES="$(uint_setting RETENTION_MAX_MOVES 50 1 "$LOG" moves)"
  if [ "$MAX_MOVES" -gt 50 ]; then
    say "WARNING: RETENTION_MAX_MOVES $MAX_MOVES is more than the 50 files one run may move. Using 50."
    MAX_MOVES=50
  fi
  GIT_TIMEOUT="$(uint_setting RUNNER_GIT_TIMEOUT 120 1 "$LOG")"
  WATCHDOG_GRACE="$(uint_setting WATCHDOG_GRACE 15 0 "$LOG")"
  WATCHDOG_POLL="$(uint_setting WATCHDOG_POLL 5 1 "$LOG")"
  STATE="$(vault_state_dir "$ROOT" 2>>"$LOG")"
  STATE_REAL="$(state_dir_ready "$STATE" "$ROOT")"
  state_rc=$?
  if [ "$state_rc" -ne 0 ]; then
    printf '[%s] ERROR: the state directory %s %s. Refusing to run.\n' "$(ts)" "$STATE" "$(state_dir_problem "$state_rc")" >> "$LOG"
    return 1
  fi
  STATE="$STATE_REAL"

  trap on_exit EXIT
  trap 'on_signal 130' INT
  trap 'on_signal 143' TERM
  trap 'on_signal 129' HUP
  run_lock_acquire "$STATE" "$ROOT" "$RUNNER" "$LOG" "$((GIT_TIMEOUT * 4 + WATCHDOG_GRACE + 900))"
  lock_rc=$?
  [ "$lock_rc" -eq 0 ] || return "$lock_rc"

  tripwire_check "$ROOT" "$STATE" "$RUNNER" "$LOG"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  SNAP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t vaultretention)" || {
    SNAP_DIR=""
    printf '[%s] ERROR: could not create a temporary directory\n' "$(ts)" >> "$LOG"
    return 1
  }
  mkdir -p "$SNAP_DIR/nohooks"
  HOOKS="$SNAP_DIR/nohooks"

  git_preflight "$ROOT" "$HOOKS" "$LOG"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if [ "${VAULT_GIT:-0}" -ne 1 ]; then
    say "ERROR: ${VAULT_GIT_NOTE:-the vault is not a git repository}, so there is no history to say who wrote each journal. Refusing to run."
    return 1
  fi
  retention_preflight
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  recovery_check
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  folder_checks
  folder_rc=$?
  case "$folder_rc" in
    0) ;;
    10) return 0 ;;
    *) return "$folder_rc" ;;
  esac

  TODAY="$(date +%Y-%m-%d 2>/dev/null)"
  if ! date_day "$TODAY"; then
    say "ERROR: today's date could not be read, so no age could be worked out. Refusing to run."
    return 1
  fi
  TODAY_DAY="$DATE_DAY"
  HEAD_BEFORE="$(rgit rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)"
  if [ -z "$HEAD_BEFORE" ]; then
    say "ERROR: HEAD names no commit, so there is no history to judge against. Refusing to run."
    return 1
  fi

  enumerate_candidates
  if [ "$C_N" -eq 0 ]; then
    log_verdicts
    say "OK: there is nothing in $LOGS_REL to evaluate."
    return 0
  fi
  local i=0
  while [ "$i" -lt "$C_N" ]; do
    C_ADOPT[$i]=0
    i=$((i + 1))
  done

  pre_checks
  read_history
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  ask_batches
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  classify_journals
  classify_stubs
  destination_rule
  keep_rule

  if [ "$ADOPT_MODE" -eq 1 ]; then
    adopt_legacy "$ADOPT_REPORT"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      log_verdicts
      return "$rc"
    fi
  elif [ "$DRY_RUN" -eq 0 ]; then
    legacy_report
  fi

  build_move_set
  load_moves

  if [ "$DRY_RUN" -eq 1 ]; then
    log_verdicts
    say "OK: this was a dry run, so nothing was moved and nothing was written."
    return 0
  fi
  if [ "${#SRCS[@]}" -eq 0 ]; then
    log_verdicts
    say "OK: nothing is ready to move."
    return 0
  fi

  RETENTION_NONCE="$(new_uuid)"
  write_recovery moving || {
    say "ERROR: the record of what is about to move could not be written to $STATE, so nothing was moved."
    log_verdicts
    return 1
  }
  MOVING=1

  do_moves
  rc=$?
  if [ "$rc" -ne 0 ]; then
    MOVING=0
    log_verdicts
    return "$rc"
  fi
  if ! verify_moves; then
    if put_back; then
      MOVING=0
      log_verdicts
      return 3
    fi
    MOVING=0
    log_verdicts
    return 71
  fi
  if ! real_dir_ok "$LOGS_REL" || ! real_dir_ok "$ARCH_REL"; then
    write_recovery folders-changed
    say "RECOVERY-NEEDED: a folder on the path changed while this run was moving, so nothing further is done. $STATE/retention-inflight says what was moved."
    MOVING=0
    log_verdicts
    return 71
  fi

  do_commit
  settle_outcome
  rc=$?
  log_verdicts
  return "$rc"
}

main "$@"
exit $?
