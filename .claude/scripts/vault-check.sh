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
#   C5  if `last_verified:` exists, it is not later than today
#
# Usage:  bash .claude/scripts/vault-check.sh   # do not pipe: a pipe would report
#                                               # the pager's status, not ours

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
TODAY="$(date +%F)"

# Content tiers only. 90-auto-memory/ is machine-managed under Claude Code's own
# schema and is deliberately out of scope (see the freshness standard § 2).
TIERS="01-inbox 10-daily 20-projects 30-knowledge 31-standards 40-llm-wiki"

# A bash ARRAY, not a space-joined string. The string form depends on word
# splitting at the `find` call, so any vault whose path contains a space -
# "C:/Users/Some One/...", "My Documents", or macOS iCloud's
# "~/Library/Mobile Documents/..." - silently scans the wrong paths or nothing
# at all, and still prints a reassuring "0 violations".
DIRS=()
for d in $TIERS; do
  [ -d "$ROOT/$d" ] && DIRS+=("$ROOT/$d")
done
if [ "${#DIRS[@]}" -eq 0 ]; then
  printf 'vault-check: no content-tier folders found under %s\n' "$ROOT"
  exit 1
fi

# Frontmatter extraction matches .claude/hooks/vault-lint.sh line for line, so the
# two checkers can never disagree about where a note's frontmatter ends.
fm_of() {
  awk 'NR==1&&/^---[[:space:]]*$/{f=1;next} f&&/^---[[:space:]]*$/{exit} f{print}' "$1"
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
      sub(/^[^:]*:[[:space:]]*/, "")
      gsub(/\r/, "")
      sub(/[[:space:]]+$/, "")
      if (length($0) >= 2) {
        a = substr($0, 1, 1); b = substr($0, length($0), 1)
        if (a == b && (a == "\"" || a == "\047")) $0 = substr($0, 2, length($0) - 2)
      }
      print; exit
    }'
}

violations=0
files=0

report() {
  printf '%s — %s — %s\n' "$1" "$2" "$3"
  violations=$((violations + 1))
}

# -print0 / read -d '': several vault notes have spaces in their filenames.
while IFS= read -r -d '' file; do
  files=$((files + 1))
  rel="${file#"$ROOT"/}"

  if [ "$(awk 'NR==1{if ($0 ~ /^---[[:space:]]*$/) print 1; else print 0} END{if (NR==0) print 0}' "$file")" != "1" ]; then
    report "$rel" "C1" "first line is not a bare --- fence"
    # Without an opening fence there is no frontmatter to inspect; C2-C5 would
    # otherwise read the note body and report nonsense.
    continue
  fi

  fm="$(fm_of "$file")"

  [ "$(count_key tier "$fm")" -eq 0 ] && report "$rel" "C2" "frontmatter has no 'tier:' key"
  [ "$(count_key type "$fm")" -eq 0 ] && report "$rel" "C3" "frontmatter has no 'type:' key"

  created="$(value_of created "$fm")"
  verified="$(value_of last_verified "$fm")"

  # An empty value is treated as absent. A bare `last_verified:` compares as ""
  # against created, and "" sorts before every date, which would invent a C4
  # violation for a key that carries no claim at all.
  if [ -n "$created" ] && [ -n "$verified" ]; then
    # ISO YYYY-MM-DD sorts lexicographically, so string comparison is the date
    # comparison — no date parsing, no locale dependency.
    if [ "$verified" \< "$created" ]; then
      report "$rel" "C4" "last_verified $verified is earlier than created $created"
    fi
  fi

  if [ -n "$verified" ] && [ "$verified" \> "$TODAY" ]; then
    report "$rel" "C5" "last_verified $verified is later than today $TODAY"
  fi
done < <(find "${DIRS[@]}" \( -path '*/templates/*' -o -name 'compaction-*.md' \) -prune -o -type f -name '*.md' -print0)

printf 'vault-check: %s violation(s) across %s file(s) checked (as of %s).\n' \
  "$violations" "$files" "$TODAY"

[ "$violations" -gt 0 ] && exit 1
exit 0
