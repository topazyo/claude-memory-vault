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
# Exit:   0 = at least one note scanned and no violations
#         1 = any violation, OR no notes scanned at all. "0 violations across
#             0 files" is a vacuous result, not a pass, so it fails like one.
#             A named note that is not a file also fails.
#
# Usage:  bash .claude/scripts/vault-check.sh   # do not pipe: a pipe would report
#                                               # the pager's status, not ours
#         bash .claude/scripts/vault-check.sh [--] <note>...
#             checks only the named notes, relative to the vault root or
#             absolute, wherever they are. The runners use this to check exactly
#             the files a pass is about to commit.

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
TODAY="$(date +%F)"

# A scheduled pass sets this tripwire when it changed a steering or execution
# surface (see "Containment" in lib/runner-common.sh). Until a human has read it
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
  if [ -n "$TW_STATE" ] && [ -f "$TW_STATE" ] && [ ! -L "$TW_STATE" ]; then
    printf 'vault-check: read %s and do what it says, then delete it and its copy. Nothing was checked.\n' "$TW_STATE" >&2
  elif tw_present "$TW_VAULT"; then
    printf 'vault-check: read %s, then delete it and its copy. No copy in the state directory is a file, and a pass can write the copy in the vault, so a pass may have written this one. Check its reason against the runner logs before you do anything it says. Nothing was checked.\n' "$TW_VAULT" >&2
  else
    printf 'vault-check: read %s and do what it says, then delete it and its copy. Nothing was checked.\n' "$TW_STATE" >&2
  fi
  exit 1
fi

# Content tiers only. 90-auto-memory/ is machine-managed under Claude Code's own
# schema and is deliberately out of scope (see the freshness standard § 2).
TIERS="01-inbox 10-daily 20-projects 30-knowledge 31-standards 40-llm-wiki"

case "${1:-}" in
  --) shift ;;
  -*)
    printf 'vault-check: unknown option %s. Name notes after --, for example vault-check.sh -- 10-daily/2026-01-15.md\n' "$1" >&2
    exit 1
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
  exit 1
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
# surrounding quote pair. \047 is the apostrophe — written escaped so this awk
# program stays inside single quotes.
value_of() {
  printf '%s\n' "$2" | awk -v k="^$1:" '
    $0 ~ k {
      sub(/^[^:]*:[ \t]*/, "")
      gsub(/\r/, "")
      sub(/[ \t\r]+$/, "")
      if (length($0) >= 2) {
        a = substr($0, 1, 1); b = substr($0, length($0), 1)
        if (a == b && (a == "\"" || a == "\047")) $0 = substr($0, 2, length($0) - 2)
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

report() {
  printf '%s — %s — %s\n' "$1" "$2" "$3"
  violations=$((violations + 1))
}

check_note() {
  local file="$1" rel fm created verified created_ok verified_ok
  files=$((files + 1))
  rel="${file#"$ROOT"/}"

  if [ "$(awk 'NR==1{if ($0 ~ /^---[ \t\r]*$/) print 1; else print 0} END{if (NR==0) print 0}' "$file")" != "1" ]; then
    report "$rel" "C1" "first line is not a bare --- fence"
    # Without an opening fence there is no frontmatter to inspect; C2-C5 would
    # otherwise read the note body and report nonsense.
    return
  fi

  fm="$(fm_of "$file")"

  [ "$(count_key tier "$fm")" -eq 0 ] && report "$rel" "C2" "frontmatter has no 'tier:' key"
  [ "$(count_key type "$fm")" -eq 0 ] && report "$rel" "C3" "frontmatter has no 'type:' key"

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
    case "$file" in /*|[A-Za-z]:[\\/]*) ;; *) file="$ROOT/$file" ;; esac
    if [ -f "$file" ] && [ -r "$file" ]; then
      check_note "$file"
    else
      printf 'vault-check: %s is not a readable file, so it was not checked.\n' "$file" >&2
      missing=$((missing + 1))
    fi
  done
else
  # -print0 / read -d '': several vault notes have spaces in their filenames.
  while IFS= read -r -d '' file; do
    check_note "$file"
  done < <(find "${DIRS[@]}" \( -path '*/templates/*' -o -name 'compaction-*.md' \) -prune -o -type f -name '*.md' -print0)
fi

printf 'vault-check: %s violation(s) across %s file(s) checked (as of %s).\n' \
  "$violations" "$files" "$TODAY"

# A scan that examined nothing proves nothing. Fail it, so a caller that only
# reads the exit code - a CI step, a pre-commit hook, an agent - cannot mistake
# a path or folder-name problem for a clean vault.
if [ "$files" -eq 0 ]; then
  printf 'vault-check: VACUOUS - no notes were scanned, so this is not a pass. Check CLAUDE_PROJECT_DIR and the TIERS list.\n' >&2
  exit 1
fi

[ "$violations" -gt 0 ] && exit 1
[ "$missing" -gt 0 ] && exit 1
exit 0
