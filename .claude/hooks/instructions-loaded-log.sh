#!/usr/bin/env bash
# InstructionsLoaded hook: audit log of instruction files loaded at SESSION START only.
# Audit-only — cannot block, never fails the session.

VAULT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
LOG_DIR="$VAULT/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null

input="$(cat 2>/dev/null || true)"
ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"

# Only log session_start loads (belt-and-suspenders alongside the settings matcher).
reason="?"
if command -v jq >/dev/null 2>&1; then
  reason="$(printf '%s' "$input" | jq -r '.load_reason // ""' 2>/dev/null || echo '')"
else
  case "$input" in
    *'"load_reason": "session_start"'*|*'"load_reason":"session_start"'*) reason="session_start" ;;
    *) reason="other" ;;
  esac
fi

[ "$reason" = "session_start" ] || exit 0

if command -v jq >/dev/null 2>&1; then
  fp="$(printf '%s' "$input" | jq -r '.file_path // "?"' 2>/dev/null || echo '?')"
  mt="$(printf '%s' "$input" | jq -r '.memory_type // "?"' 2>/dev/null || echo '?')"
  printf '%s  InstructionsLoaded[session_start]  type=%s  file=%s\n' "$ts" "$mt" "$fp" >> "$LOG_DIR/instructions-loaded.log" 2>/dev/null
else
  printf '%s  InstructionsLoaded[session_start]  %s\n' "$ts" "$input" >> "$LOG_DIR/instructions-loaded.log" 2>/dev/null
fi

exit 0
