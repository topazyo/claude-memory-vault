#!/usr/bin/env bash
# InstructionsLoaded hook: audit log of instruction files loaded at SESSION START only.
# Audit-only — cannot block, never fails the session.

VAULT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
LOG_DIR="$VAULT/.claude/logs"
# Only when it is missing. This hook runs once per instruction file at session
# start, so a process spent here is spent several times over.
[ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null

input="$(cat 2>/dev/null || true)"
ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"

# Only log session_start loads (belt-and-suspenders alongside the settings matcher).
#
# ONE jq call for all three fields, not one call each. jq was started three
# times per loaded file, and with several instruction files that is most of
# what this hook costs. The three values come back one per line and are read
# without starting anything further.
reason="?"
HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then
  HAVE_JQ=1
  { IFS= read -r reason; IFS= read -r mt; IFS= read -r fp; } <<EOF
$(printf '%s' "$input" | jq -r '(.load_reason // ""), (.memory_type // "?"), (.file_path // "?")' 2>/dev/null)
EOF
  : "${mt:=?}"
  : "${fp:=?}"
else
  case "$input" in
    *'"load_reason": "session_start"'*|*'"load_reason":"session_start"'*) reason="session_start" ;;
    *) reason="other" ;;
  esac
fi

[ "$reason" = "session_start" ] || exit 0

if [ "$HAVE_JQ" = 1 ]; then
  printf '%s  InstructionsLoaded[session_start]  type=%s  file=%s\n' "$ts" "$mt" "$fp" >> "$LOG_DIR/instructions-loaded.log" 2>/dev/null
else
  printf '%s  InstructionsLoaded[session_start]  %s\n' "$ts" "$input" >> "$LOG_DIR/instructions-loaded.log" 2>/dev/null
fi

exit 0
