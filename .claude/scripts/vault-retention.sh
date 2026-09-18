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
RUN_NONCE=""
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
# Git on the vault as every runner calls it (safe_git), with replace refs off,
# log.follow off and paths quoted, so history reads as it was committed.
rgit() {
  safe_git "$HOOKS" -C "$ROOT" -c log.follow=false -c core.quotePath=true "$@"
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
    -c log.follow=false -c core.quotePath=true "$@"
  RUN_PID=""
  [ "$RUN_TIMED_OUT" -eq 0 ] && [ "$RUN_RC" -eq 0 ]
}

# Date arithmetic for awk, on day numbers, with no date parsing and no regex
# intervals, which older awks do not read. valid() is true only for a real
# calendar date written YYYY-MM-DD.
DATE_AWK='
function dfc(y, m, d,   era, yoe, doy, doe) {
  y -= (m <= 2); era = int(y / 400); yoe = y - era * 400
  doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe
}
function cfd(z,   era, doe, yoe, y, doy, mp, d, m) {
  era = int(z / 146097); doe = z - era * 146097
  yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
  y = yoe + era * 400; doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
  mp = int((5 * doy + 2) / 153); d = doy - int((153 * mp + 2) / 5) + 1
  m = mp < 10 ? mp + 3 : mp - 9
  return sprintf("%04d-%02d-%02d", y + (m <= 2), m, d)
}
function valid(s,   y, m, d) {
  if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return 0
  y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
  if (m < 1 || m > 12 || d < 1) return 0
  return cfd(dfc(y, m, d)) == s
}
function day(s) { return dfc(substr(s, 1, 4) + 0, substr(s, 6, 2) + 0, substr(s, 9, 2) + 0) }
'

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
  local gd="" common=""
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

#@PART3
