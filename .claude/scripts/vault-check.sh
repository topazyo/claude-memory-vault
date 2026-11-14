#!/usr/bin/env bash
# .claude/scripts/vault-check.sh
# Frontmatter invariant checker for the content tiers. Unlike the PostToolUse
# hook .claude/hooks/vault-lint.sh — which is advisory and ALWAYS exits 0 — this
# script exits 1 when any note violates an invariant, so it can gate a pass.
#
# REPORT ONLY. It never writes to a note, never stamps, never repairs. Repair is
# a human act; an automated fix here would be the "resolution by writing" failure
# the freshness standard warns about (.claude/rules/verification.md).
#
# Checks:
#   C1  first line is a bare `---` fence
#   C2  frontmatter contains a `tier:` key
#   C3  frontmatter contains a `type:` key
#   C4  if both `created:` and `last_verified:` exist, last_verified >= created
#       (a non-empty `created:` that is not a YYYY-MM-DD date is also a C4 violation)
#   C5  if `last_verified:` exists, it is not later than today
#       (a non-empty `last_verified:` that is not a YYYY-MM-DD date is also a C5 violation)
#
# Exit:   0  at least one note scanned and no violations
#         1  the vault has a problem. A note violates an invariant.
#         2  this checker could not run, so it is saying nothing about the
#            vault. No notes were scanned at all, or there are no content-tier
#            folders under the root, or a named note is not a readable file, or
#            (since 1.7.0) a link in a content tier, or a named note, dangles or
#            resolves to something the scan does not read where it is, so what
#            it holds was not read.
#         64 the command line was wrong.
#         78 a scheduled pass set the tripwire, so nothing was checked and a
#            human has to look first. The three runners use 78 for the same
#            thing, so one number means one thing across all four.
#
# Advisory (since 1.7.0): WARNING lines after the count line for a tier value
# that is not short, medium or long or not the folder's tier, a type outside
# the allowed set, a long-tier note with no wikilink, and a tier, type,
# created or last_verified key a YAML reader would read differently. They
# change neither the count nor the exit code; a later release makes them
# violations.
#
# These used to be a single 1, which meant a caller could not tell "the vault
# has a problem" from "the checker could not run", and those want opposite
# responses. A violation is a fact about the notes that a person should fix. A
# 2 is a fact about the invocation, most often a wrong root or a wrong working
# directory, and a vault that has not been looked at. "0 violations across 0
# files" is still a vacuous result rather than a pass, and it now says which
# kind of not-a-pass it is.
#
# Every caller was read before this changed. The commit gate reports whatever
# code it got and refuses, and the runners test for success with `if !` or with
# `&&`. Nothing matched on the number 1, so no caller changes meaning.
#
# Usage:  bash .claude/scripts/vault-check.sh   # do not pipe: a pipe would report
#                                               # the pager's status, not ours
#         bash .claude/scripts/vault-check.sh [--] <note>...
#             checks only the named notes, relative to the vault root or
#             absolute, wherever they are. The runners use this to check exactly
#             the files a pass is about to commit.

# A cd that finds its folder through CDPATH prints the folder, and every cd
# below is inside a command substitution or feeds find's output, so an
# exported CDPATH would put a path into either.
unset CDPATH
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
TODAY="$(date +%F)"

# A scheduled pass sets this tripwire when it changed a steering or execution
# surface (see "Containment" in lib/runner-common.sh), when it was stopped and a
# process may still be running, when it died before containment, or when the
# runner's own folder for it changed while it ran. Until a human has read it
# and deleted it, a clean report here would read as "the vault is fine", and the
# commit gate would let the aftermath be committed. So refuse, loudly.
# -L as well as -e: a dangling symlink planted at the path is not -e, and must
# not read as "no tripwire". The runners keep a second copy in their state
# directory outside the vault, so a deleted in-vault copy does not clear it.
TW_VAULT="$ROOT/.claude/logs/runner-tripwire"
TW_STATE=""
RUNNER_LIB="$(dirname "$0")/lib/runner-common.sh"
state_dir=""
if [ -f "$RUNNER_LIB" ]; then
  state_dir="$( . "$RUNNER_LIB" && vault_state_dir "$ROOT")"
fi
if [ -n "$state_dir" ]; then
  TW_STATE="$state_dir/runner-tripwire"
else
  printf 'vault-check: WARNING - could not work out the runners'"'"' state directory from %s, so the tripwire copy kept there was not checked.\n' "$RUNNER_LIB" >&2
fi
tw_present() {
  [ -n "$1" ] && { [ -e "$1" ] || [ -L "$1" ]; }
}
if tw_present "$TW_STATE" || tw_present "$TW_VAULT"; then
  # The copy is named by the runners' rule (tripwire_check). The state directory
  # copy when it is a file, because a pass cannot write it. Otherwise the vault's
  # copy when there is one, which a pass can write, so its instructions are not
  # vouched for. Otherwise the state path.
  printf 'vault-check: TRIPWIRE - a scheduled pass changed a steering or execution surface, was interrupted before containment, or may have left a process running.\n' >&2
  printf 'vault-check: docs/setup.md, section "A tripwire is set", has the steps in order.\n' >&2
  if [ -n "$TW_STATE" ] && [ -f "$TW_STATE" ] && [ ! -L "$TW_STATE" ]; then
    printf 'vault-check: read %s and do what it says, then delete it and its copy. Nothing was checked.\n' "$TW_STATE" >&2
  elif tw_present "$TW_VAULT" && [ -n "$TW_STATE" ]; then
    printf 'vault-check: read %s, then delete it and its copy. No copy in %s is a file, and a pass can write the copy in the vault, so a pass may have written this one. Check its reason against the runner logs before you do anything it says. Nothing was checked.\n' "$TW_VAULT" "$state_dir" >&2
  elif tw_present "$TW_VAULT"; then
    printf 'vault-check: read %s, then delete it and its copy. The copy in the runners'"'"' state directory could not be checked, and a pass can write the copy in the vault, so a pass may have written this one. Check its reason against the runner logs before you do anything it says. Nothing was checked.\n' "$TW_VAULT" >&2
  else
    printf 'vault-check: %s is not a file, so it holds no tripwire text. Remove it, then read the runner logs for why the tripwire was set. Nothing was checked.\n' "$TW_STATE" >&2
  fi
  # 78, the same number the three runners use for a tripwire, so a caller
  # reading an exit code does not have to know which of the four it called.
  exit 78
fi

# Content tiers only. 90-auto-memory/ is machine-managed under Claude Code's own
# schema and is deliberately out of scope (see the freshness standard § 2).
TIERS="01-inbox 10-daily 20-projects 30-knowledge 31-standards 40-llm-wiki"

case "${1:-}" in
  --) shift ;;
  -*)
    printf 'vault-check: unknown option %s. Name notes after --, for example vault-check.sh -- 10-daily/2026-01-15.md\n' "$1" >&2
    # 64 for a wrong command line, the number the retention runner already uses
    # for the same thing. A caller that cannot spell the arguments has learned
    # nothing about the vault.
    exit 64
    ;;
esac
NAMED=("$@")

# A bash ARRAY, not a space-joined string. The string form depends on word
# splitting at the `find` call, so any vault whose path contains a space -
# "C:/Users/Some One/...", "My Documents", or macOS iCloud's
# "~/Library/Mobile Documents/..." - silently scans the wrong paths or nothing
# at all, and still prints a reassuring "0 violations".
DIRS=()
for d in $TIERS; do
  [ -d "$ROOT/$d" ] && DIRS+=("$ROOT/$d")
done
if [ "${#NAMED[@]}" -eq 0 ] && [ "${#DIRS[@]}" -eq 0 ]; then
  printf 'vault-check: no content-tier folders found under %s\n' "$ROOT"
  # 2, because this says nothing about the notes. The usual cause is a wrong
  # root or a wrong working directory, not a vault with a problem in it.
  exit 2
fi

# Frontmatter extraction matches .claude/hooks/vault-lint.sh line for line, so the
# two checkers can never disagree about where a note's frontmatter ends.
#
# The awk regexes below spell whitespace as [ \t\r] rather than [[:space:]].
# macOS ships the "one true awk" as /usr/bin/awk, and the version shipped through
# macOS 13 does not implement POSIX bracket expressions - it would read
# [[:space:]] as the literal characters : a c e p s, so a frontmatter fence would
# never match and EVERY note would be reported as missing tier and type. The
# explicit list is understood identically by BWK awk, mawk and gawk. Keep \r in
# the set or notes checked out with CRLF endings stop matching.
fm_of() {
  awk 'NR==1&&/^---[ \t\r]*$/{f=1;next} f&&/^---[ \t\r]*$/{exit} f{print}' "$1"
}

# Count occurrences with awk, never `grep -c`: grep -c prints 0 AND exits 1 on
# no-match, so `n=$(grep -c k f || echo 0)` yields "0\n0" and breaks the test.
count_key() {
  printf '%s\n' "$2" | awk -v k="^$1:" '$0 ~ k {n++} END {print n+0}'
}

# First value for a key, stripped of a trailing CR, trailing spaces, and one
# surrounding quote pair. The apostrophe is built with sprintf rather than
# written as \047, because it cannot be written literally inside this single
# quoted program and the awk macOS ships does not read an octal escape in a
# string the way gawk and mawk do. That difference has already cost this
# repository two silent wrong answers, both of which took a CI run to see.
value_of() {
  printf '%s\n' "$2" | awk -v k="^$1:" '
    BEGIN { q = sprintf("%c", 39) }
    $0 ~ k {
      sub(/^[^:]*:[ \t]*/, "")
      gsub(/\r/, "")
      sub(/[ \t\r]+$/, "")
      if (length($0) >= 2) {
        a = substr($0, 1, 1); b = substr($0, length($0), 1)
        if (a == b && (a == "\"" || a == q)) $0 = substr($0, 2, length($0) - 2)
      }
      print; exit
    }'
}

# True when the value is shaped like an ISO calendar date. The C4/C5 comparisons
# below are string comparisons, which are only date comparisons when both sides
# are YYYY-MM-DD. Without this guard a value like "Jan 5" or "2026-1-5" is
# compared as text, and a malformed stamp silently switches both checks off.
is_iso_date() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

violations=0
files=0
warnings=0
WARN_LINES=""

report() {
  printf '%s — %s — %s\n' "$1" "$2" "$3"
  violations=$((violations + 1))
}

# warn <rel> <text> - an advisory finding (1.7.0). Kept, and printed after the
# count line, so the count line and the exit code stay what callers parse; a
# later release makes these violations.
warn() {
  WARN_LINES+="vault-check: WARNING: $1 — $2
"
  warnings=$((warnings + 1))
}

# folder_tier <rel> - sets FOLDER_TIER to the tier the folder a note sits in
# calls for, from the table in AGENTS.md section 3, or to nothing where that
# table names none. A variable, not printed, so no subshell is spent per note.
folder_tier() {
  case "$1" in
    01-inbox/*|10-daily/*|40-llm-wiki/raw/*) FOLDER_TIER=short ;;
    20-projects/*) FOLDER_TIER=medium ;;
    30-knowledge/*|31-standards/*|40-llm-wiki/wiki/*) FOLDER_TIER=long ;;
    *) FOLDER_TIER="" ;;
  esac
}

# yaml_scalar <value> - sets SCALAR to a value as value_of returned it, less an
# inline comment (whitespace, then #) and the quotes around what is left, so
# `tier: long   # short | medium | long`, which docs/customizing.md shows,
# reads as long. Only the advisory checks use it.
yaml_scalar() {
  local v="$1" q rest
  case "$v" in
    \"*|\'*)
      # Quoted, with a comment after the closing quote (value_of strips a
      # quote pair only when the value ends in it): the text up to that quote.
      q="${v:0:1}" rest="${v:1}"
      case "$rest" in *"$q"*) v="${rest%%"$q"*}" ;; esac
      ;;
    *)
      v="${v%%[[:space:]]#*}"
      v="${v%"${v##*[![:space:]]}"}"
      ;;
  esac
  SCALAR="$v"
}

# key_spellings <frontmatter> - one line per key this checker reads (tier,
# type, created, last_verified) that a YAML reader would also find under a
# spelling the checks above do not read ("tier":, 'tier':, tier :), or that
# appears more than once, where this checker reads the first and a YAML
# reader the last. A future last_verified written either way passed C5.
key_spellings() {
  printf '%s\n' "$1" | LC_ALL=C awk '
    BEGIN { q = sprintf("%c", 39); split("tier type created last_verified", keys, " ") }
    { sub(/\r$/, "") }
    {
      for (i = 1; i <= 4; i++) {
        k = keys[i]
        if (index($0, k ":") == 1) { plain[k]++; continue }
        s = $0
        if (substr(s, 1, 1) == "\"" || substr(s, 1, 1) == q) {
          c = substr(s, 1, 1)
          if (substr(s, 2, length(k) + 1) == k c) {
            r = substr(s, length(k) + 3)
            sub(/^[ \t]*/, "", r)
            if (substr(r, 1, 1) == ":") odd[k] = odd[k] ? odd[k] : c k c ":"
          }
          continue
        }
        if (index(s, k) == 1) {
          r = substr(s, length(k) + 1)
          if (r ~ /^[ \t]+:/) odd[k] = odd[k] ? odd[k] : k " :"
        }
      }
    }
    END {
      for (i = 1; i <= 4; i++) {
        k = keys[i]
        if (k in odd) printf "the key %s is also written as %s, which these checks do not read\n", k, odd[k]
        if (plain[k] > 1) printf "the key %s appears %d times; these checks read the first, a YAML reader the last\n", k, plain[k]
      }
    }'
}

# The vault root as the file system has it, for telling where a link really
# points. Empty when it cannot be resolved, which link_target_ok reads as
# "cannot tell" and refuses.
ROOT_P="$(cd -P "$ROOT" 2>/dev/null && pwd -P)"

# link_target_ok <absolute path> - true when the path, a link or a path through
# one, resolves to something the full scan reads where it really is: a folder
# under one of this vault's content-tier folders and not in a templates folder
# there, or a .md file such a folder holds that is not a compaction stub in
# 20-projects/_logs. Sets LINK_WHY to the reason when it does not. Identity is
# tested with -ef against each tier folder, walking up from the resolved
# folder, so two spellings of one folder (a Windows short name, a different
# letter case) still match.
link_target_ok() {
  local p="$1" n=0 t d prev base="" sub="" isdir=0
  LINK_WHY=""
  if [ ! -e "$p" ]; then
    LINK_WHY="does not resolve"
    return 1
  fi
  if [ -d "$p" ]; then
    isdir=1
    d="$(cd -P "$p" 2>/dev/null && pwd -P)"
  else
    # Follow the chain of links to the last name, then resolve its folder. A
    # link readlink cannot read is refused rather than taken at its own name.
    while [ -L "$p" ]; do
      if [ "$n" -ge 40 ] || ! t="$(readlink "$p" 2>/dev/null)" || [ -z "$t" ]; then
        LINK_WHY="could not be resolved"
        return 1
      fi
      case "$t" in
        /*) p="$t" ;;
        *) p="${p%/*}/$t" ;;
      esac
      n=$((n + 1))
    done
    base="${p##*/}"
    d="$(cd -P "${p%/*}" 2>/dev/null && pwd -P)"
  fi
  if [ -z "$d" ] || [ -z "$ROOT_P" ]; then
    LINK_WHY="could not be resolved"
    return 1
  fi
  prev=""
  while [ -n "$d" ] && [ "$d" != "$prev" ]; do
    for t in $TIERS; do
      if [ -d "$ROOT_P/$t" ] && [ ! -L "$ROOT_P/$t" ] && [ "$d" -ef "$ROOT_P/$t" ]; then
        # Under a tier. What the scan prunes there it never reads, so a link
        # to it is a note, or folder of notes, nobody checks.
        case "/$sub" in
          */templates/*) LINK_WHY="points into a templates folder, which the scan does not read"; return 1 ;;
        esac
        if [ "$isdir" -eq 0 ]; then
          case "$base" in
            *.md) ;;
            *) LINK_WHY="points to $base, which is not a .md note"; return 1 ;;
          esac
          if [ "$t/$sub" = "20-projects/_logs/" ]; then
            case "$base" in
              compaction-*.md) LINK_WHY="points to a compaction stub, which the scan does not read"; return 1 ;;
            esac
          fi
        fi
        return 0
      fi
    done
    [ "$d" -ef "$ROOT_P" ] && break
    prev="$d"
    sub="${d##*/}/$sub"
    d="${d%/*}"
  done
  LINK_WHY="points outside the vault's content-tier folders"
  return 1
}

# named_tier_rel <absolute path> - true when the path lies in one of this
# vault's content-tier folders, by identity rather than by spelling, so
# ./31-standards/x.md, a doubled slash or the other Windows spelling of the
# root count as well. Sets NAMED_REL to the path from the vault root.
named_tier_rel() {
  local f="${1//\\//}" d sub="" t prev=""
  d="${f%/*}"
  NAMED_REL=""
  while [ -n "$d" ] && [ "$d" != "$prev" ]; do
    for t in $TIERS; do
      if [ -e "$ROOT/$t" ] && [ "$d" -ef "$ROOT/$t" ]; then
        NAMED_REL="$t/$sub${f##*/}"
        return 0
      fi
    done
    [ "$d" -ef "$ROOT" ] && return 1
    prev="$d"
    sub="${d##*/}/$sub"
    d="${d%/*}"
  done
  return 1
}

# Links a scan refused, each one a note or folder of notes that was not read.
refused=0
refuse_link() {  # refuse_link <rel> <why>
  printf 'vault-check: %s is a link that %s, so what it holds was not checked.\n' "$1" "$2" >&2
  refused=$((refused + 1))
}

check_note() {
  local file="$1" rel="${2:-}" fm created verified created_ok verified_ok tierv typev line n_tier n_type
  files=$((files + 1))
  [ -n "$rel" ] || rel="${file#"$ROOT"/}"

  if [ "$(awk 'NR==1{if ($0 ~ /^---[ \t\r]*$/) print 1; else print 0} END{if (NR==0) print 0}' "$file")" != "1" ]; then
    report "$rel" "C1" "first line is not a bare --- fence"
    # Without an opening fence there is no frontmatter to inspect; C2-C5 would
    # otherwise read the note body and report nonsense.
    return
  fi

  fm="$(fm_of "$file")"

  n_tier="$(count_key tier "$fm")"
  n_type="$(count_key type "$fm")"
  [ "$n_tier" -eq 0 ] && report "$rel" "C2" "frontmatter has no 'tier:' key"
  [ "$n_type" -eq 0 ] && report "$rel" "C3" "frontmatter has no 'type:' key"

  # What the two keys say, not only that they are there (D3, 1.7.0). Advisory
  # for one release, because an existing vault may newly fail, and a WARNING
  # changes neither the count line nor the exit code.
  folder_tier "$rel"
  if [ "$n_tier" -gt 0 ]; then
    yaml_scalar "$(value_of tier "$fm")"
    tierv="$SCALAR"
    case "$tierv" in
      short|medium|long)
        if [ -n "$FOLDER_TIER" ] && [ "$tierv" != "$FOLDER_TIER" ]; then
          warn "$rel" "tier is $tierv, but the folder it is in holds $FOLDER_TIER-tier notes"
        fi
        ;;
      *) warn "$rel" "tier '$tierv' is not short, medium or long" ;;
    esac
  fi
  if [ "$n_type" -gt 0 ]; then
    yaml_scalar "$(value_of type "$fm")"
    typev="$SCALAR"
    case "$typev" in
      reference|daily|project-log|moc|standard|wiki-entity) ;;
      *) warn "$rel" "type '$typev' is not one of reference, daily, project-log, moc, standard, wiki-entity" ;;
    esac
  fi
  if [ "$FOLDER_TIER" = long ] && ! LC_ALL=C grep -q '\[\[' "$file"; then
    warn "$rel" "a long-tier note with no [[wikilink]] to a peer or an index"
  fi
  # Split by parameter expansion: a here-document can make bash write a
  # temporary file, and this checker writes nothing.
  line="$(key_spellings "$fm")"
  while [ -n "$line" ]; do
    warn "$rel" "${line%%$'\n'*}"
    case "$line" in
      *$'\n'*) line="${line#*$'\n'}" ;;
      *) line="" ;;
    esac
  done

  created="$(value_of created "$fm")"
  verified="$(value_of last_verified "$fm")"

  # An empty value is treated as absent. A bare `last_verified:` compares as ""
  # against created, and "" sorts before every date, which would invent a C4
  # violation for a key that carries no claim at all. Templates ship
  # `last_verified: ""` for exactly this reason: no stamp until a real re-probe.
  created_ok=0
  verified_ok=0
  if [ -n "$created" ]; then
    if is_iso_date "$created"; then created_ok=1
    else report "$rel" "C4" "created '$created' is not a YYYY-MM-DD date"; fi
  fi
  if [ -n "$verified" ]; then
    if is_iso_date "$verified"; then verified_ok=1
    else report "$rel" "C5" "last_verified '$verified' is not a YYYY-MM-DD date"; fi
  fi

  # ISO YYYY-MM-DD sorts lexicographically, so string comparison is the date
  # comparison — no date parsing, no locale dependency. TODAY is the local date,
  # so a stamp made in a timezone ahead of this machine's can read as one day in
  # the future for a few hours; that is a reason to look, not a defect.
  if [ "$created_ok" -eq 1 ] && [ "$verified_ok" -eq 1 ] && [ "$verified" \< "$created" ]; then
    report "$rel" "C4" "last_verified $verified is earlier than created $created"
  fi

  if [ "$verified_ok" -eq 1 ] && [ "$verified" \> "$TODAY" ]; then
    report "$rel" "C5" "last_verified $verified is later than today $TODAY"
  fi
}

missing=0
if [ "${#NAMED[@]}" -gt 0 ]; then
  for file in "${NAMED[@]}"; do
    # The drive letter is spelled out rather than written as a range. A range
    # follows the locale's collating order, where a letter carrying an accent
    # sorts beside the letter it is built from and so falls inside A-Z, which
    # would read a relative name beginning with such a letter and a colon as an
    # absolute path on one platform and not on another.
    case "$file" in /*|[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz]:[\\/]*) ;; *) file="$ROOT/$file" ;; esac
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
      printf 'vault-check: %s is not a readable file, so it was not checked.\n' "$file" >&2
      missing=$((missing + 1))
      continue
    fi
    # A note named inside a content tier is held to the full scan's rule for
    # links (since 1.7.0): it is read only when it really lies where the scan
    # reads it, so the two modes agree about the same note. Inside a tier is
    # decided by identity, not spelling, so ./31-standards/x.md or the other
    # Windows spelling of the root count too, and the path from the root is
    # what the advisory checks read. A note named anywhere else is checked as
    # it always was.
    if named_tier_rel "$file"; then
      if ! link_target_ok "$file"; then
        printf 'vault-check: %s %s, so it was not checked.\n' "$file" "$LINK_WHY" >&2
        refused=$((refused + 1))
        continue
      fi
      check_note "$file" "$NAMED_REL"
    else
      check_note "$file"
    fi
  done
else
  # Paths relative to the root, never absolute: the prune patterns are matched
  # against the whole path, so before 1.7.0 a vault under any folder named
  # templates matched '*/templates/*' at its root and scanned nothing, and a
  # compaction-*.md note in any tier was pruned as if it were a stub. The
  # templates prune now applies inside a tier and the stub prune in
  # 20-projects/_logs only.
  #
  # find does not follow links (no -L, no -H), so it never reads a note twice
  # or walks out of the vault. Every link it meets that could be a note or a
  # folder of notes is then checked on its own: one whose real target is
  # something this walk reads where it is (link_target_ok) is fine, and one
  # that dangles or points anywhere else (a synced folder outside the vault, a
  # template, a file that is no .md note) is refused, and the run exits 2. A
  # link to a file under another name than *.md, an image say, is no note and
  # is left alone, and so is a dangling one whose name has an extension other
  # than .md. Before 1.7.0 a linked tier folder or note was skipped without a
  # word.
  #
  # The stub prune matches only directly in 20-projects/_logs: find's * crosses
  # a /, so the pattern alone would also prune a folder named compaction-*.
  TIER_NAMES=()
  for d in $TIERS; do
    { [ -d "$ROOT/$d" ] || [ -L "$ROOT/$d" ]; } && TIER_NAMES+=("$d")
  done
  # -print0 / read -d '': several vault notes have spaces in their filenames.
  while IFS= read -r -d '' file; do
    check_note "$ROOT/$file" "$file"
  done < <(cd "$ROOT" && find "${TIER_NAMES[@]}" \( -path '*/templates/*' -o \( -path '20-projects/_logs/compaction-*.md' ! -path '20-projects/_logs/*/*' \) \) -prune -o -type f -name '*.md' -print0)
  while IFS= read -r -d '' file; do
    case "$file" in
      *.md) ;;
      *)
        if [ -d "$ROOT/$file" ]; then
          :
        elif [ -e "$ROOT/$file" ]; then
          continue
        else
          case "${file##*/}" in *.*) continue ;; esac
        fi
        ;;
    esac
    link_target_ok "$ROOT/$file" || refuse_link "$file" "$LINK_WHY"
  done < <(cd "$ROOT" && find "${TIER_NAMES[@]}" \( -path '*/templates/*' -o \( -path '20-projects/_logs/compaction-*.md' ! -path '20-projects/_logs/*/*' \) \) -prune -o -type l -print0)
fi

printf 'vault-check: %s violation(s) across %s file(s) checked (as of %s).\n' \
  "$violations" "$files" "$TODAY"

# A link refused above is a note, or folder of notes, the count does not
# cover, so it is said on stdout beside the count as well as on stderr, for a
# caller that reads only the first.
if [ "$refused" -gt 0 ]; then
  printf 'vault-check: %s link(s) refused, so what they hold was not checked; stderr names them, and the exit code is 2 unless a note violates an invariant.\n' "$refused"
fi

# The advisory findings, after the count line and apart from it, so a caller
# that reads the count line's numbers, or the exit code, sees what it always
# saw. Nothing is printed for a vault with none.
if [ "$warnings" -gt 0 ]; then
  printf '%s' "$WARN_LINES"
  printf 'vault-check: %s warning(s). They change neither the count above nor the exit code in this release; a later release makes them violations, so fix each note by hand.\n' "$warnings"
fi

# A scan that examined nothing proves nothing. Fail it, so a caller that only
# reads the exit code - a CI step, a pre-commit hook, an agent - cannot mistake
# a path or folder-name problem for a clean vault.
if [ "$files" -eq 0 ]; then
  printf 'vault-check: VACUOUS - no notes were scanned, so this is not a pass. Check CLAUDE_PROJECT_DIR and the TIERS list.\n' >&2
  exit 2
fi

# What the retention pass has taken out of the live tiers. 99-archive is not a
# content tier and nothing above scans it, so without this line a note that has
# been archived simply disappears from every count this script prints, and there
# is no way to tell an archived vault from one that lost notes. Reported on a
# full scan only, because a scan of named notes is answering a different
# question. It changes no count and no exit code.
if [ "${#NAMED[@]}" -eq 0 ]; then
  archived=0
  if [ -d "$ROOT/99-archive" ]; then
    archived="$(find "$ROOT/99-archive" -type f -name '*.md' 2>/dev/null | awk 'END { print NR + 0 }')"
  fi
  printf 'vault-check: 99-archive/ holds %s note(s) on disk.\n' "$archived"
  # Replace refs off and hooks and fsmonitor out of the way, for the same reason
  # the runners do it. The vault has to be the top of its own repository, or the
  # history being read belongs to something else.
  pass_line=""
  if ! command -v git >/dev/null 2>&1; then
    pass_line="The last retention pass is unknown (git is not installed)."
  elif ! git_top="$(GIT_TERMINAL_PROMPT=0 git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$git_top" ]; then
    pass_line="The last retention pass is unknown (this vault is not in a git repository)."
  elif [ "$(cd "$git_top" 2>/dev/null && pwd -P)" != "$(cd "$ROOT" 2>/dev/null && pwd -P)" ]; then
    pass_line="The last retention pass is unknown (this vault is not the top of its own repository)."
  elif [ "$(GIT_TERMINAL_PROMPT=0 git -C "$ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    pass_line="The last retention pass is unknown (this is a shallow clone, so the history is incomplete)."
  else
    # grep.patternType is pinned because --grep honours it from the user config,
    # and the anchors in the pattern are load bearing. Somebody carrying
    # grep.patternType=fixed in their own git config would otherwise be told
    # that no retention pass is in the history straight after a pass ran, which
    # is a wrong answer in the reassuring direction.
    last_pass="$(GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1 git -C "$ROOT" \
      -c core.fsmonitor=false -c log.showSignature=false -c grep.patternType=basic \
      log -1 --grep='^Vault-Pass: retention$' --format='%h%x09%cs' 2>/dev/null)"
    if [ -z "$last_pass" ]; then
      pass_line="No retention pass is in this repository's history."
    else
      moved="$(GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1 git -C "$ROOT" \
        -c core.fsmonitor=false -c log.showSignature=false -c grep.patternType=basic \
        log -1 --grep='^Vault-Pass: retention$' --format=%B 2>/dev/null \
        | awk '/^Vault-Retention-Move: / { n++ } END { print n + 0 }')"
      pass_line="The last retention pass ($(printf '%s' "$last_pass" | cut -f1) on $(printf '%s' "$last_pass" | cut -f2)) moved $moved note(s)."
    fi
  fi
  printf 'vault-check: %s\n' "$pass_line"

  # Which template version this vault records, in the same shape as the two
  # lines above: it reports, it does not judge, and it changes no count and no
  # exit code. Deliberately it does NOT hash anything. Reading every template
  # file would put dozens of file reads into the command people run most often,
  # and would give this script a second job. `vault-update.sh --status` answers
  # the drift question, and this line says where to ask it.
  tmpl_line="No template provenance marker, so which template version this vault came from is unknown."
  tmpl_manifest="$ROOT/.claude/template-manifest"
  if [ -f "$tmpl_manifest" ] && [ -r "$tmpl_manifest" ]; then
    # Filtered to digits and dots, not merely read. This line goes into the
    # command people run most often and its wording is quoted in three
    # documents, and a field with no whitespace in it can still carry escape
    # bytes. An unfiltered version could therefore repaint or erase the report
    # around it. Anything else falls through to the line that says the manifest
    # names no version, which is true of a version this cannot print.
    tmpl_version="$(LC_ALL=C awk '
      { sub(/\r$/, "") }
      $1 == "version" {
        if ($2 ~ /^[0-9][0-9.]*$/ && index($2, "..") == 0 && substr($2, length($2)) != ".") print $2
        exit
      }' "$tmpl_manifest")"
    if [ -n "$tmpl_version" ]; then
      # Spelled as a command that runs. Every other command in this repository
      # is written with its path, and three documents quote this line verbatim,
      # so a bare script name would appear four times as something that gives
      # "command not found" when it is pasted.
      tmpl_line="This vault records template version $tmpl_version. Run bash .claude/scripts/vault-update.sh --status for what has changed since."
    else
      tmpl_line="$ROOT/.claude/template-manifest names no version, so which template version this vault came from is unknown."
    fi
  fi
  printf 'vault-check: %s\n' "$tmpl_line"
fi

[ "$violations" -gt 0 ] && exit 1
# A named note that could not be read is the checker failing to run over that
# note, not the note being wrong, so it is a 2 and not a 1. The distinction
# matters most to the runners, which name exactly the files a pass is about to
# commit. A 1 tells them a note they wrote is bad. A 2 tells them a path is
# wrong, and those want different answers from whoever reads the log. A link
# the full scan refused is the same kind of answer: notes it did not read.
[ "$missing" -gt 0 ] && exit 2
[ "$refused" -gt 0 ] && exit 2
exit 0
