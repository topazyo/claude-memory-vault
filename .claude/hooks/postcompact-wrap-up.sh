#!/usr/bin/env bash
# PostCompact hook: persist one idempotent, size-capped stub per session into
# 20-projects/_logs/ so a compaction's material is recoverable even when no
# summary was generated (Claude Code issue #34556: compactions can persist
# nothing external). Also logs an advisory line, as before. Never blocks,
# always exits 0.

VAULT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
LOG_DIR="$VAULT/.claude/logs"
LOGS_DIR="$VAULT/20-projects/_logs"
mkdir -p "$LOG_DIR" 2>/dev/null
mkdir -p "$LOGS_DIR" 2>/dev/null

# Hook input (JSON) arrives on stdin: session_id, trigger (manual|auto), transcript_path, ...
input="$(cat 2>/dev/null || true)"
ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
today="$(date '+%Y-%m-%d' 2>/dev/null || echo unknown)"

trigger="?"
session_id=""
transcript_path=""
# VAULT_FORCE_NO_JQ=1 takes the no-jq branch even when jq is installed, so the
# fallback can be tested on a machine that has jq.
if [ -z "${VAULT_FORCE_NO_JQ:-}" ] && command -v jq >/dev/null 2>&1; then
  trigger="$(printf '%s' "$input" | jq -r '.trigger // "?"' 2>/dev/null || echo '?')"
  session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
  transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
else
  # No jq - the default on macOS and in Git for Windows. Without this branch the
  # session id stayed empty and the fallback below keyed the stub on the wall
  # clock, so every compaction wrote a NEW file: the "one idempotent stub per
  # session, capped at 50 entries" contract silently became "one file per
  # compaction, never capped". Pull the three string fields with sed and undo
  # JSON string escaping, the same way vault-lint.sh does.
  json_field() {
    printf '%s' "$input" \
      | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
      | head -n 1 \
      | sed -e 's/\\\\/\\/g' -e 's/\\\//\//g' -e 's/\\"/"/g'
  }
  trigger="$(json_field trigger)"; [ -z "$trigger" ] && trigger="?"
  session_id="$(json_field session_id)"
  transcript_path="$(json_field transcript_path)"
  printf '%s  PostCompact: DEGRADED - jq not found, fields parsed with sed. Install jq for reliable parsing.\n' \
    "$ts" >> "$LOG_DIR/hook-events.log" 2>/dev/null
fi

printf '%s  PostCompact (trigger=%s). Consider /wrap-up or /obsidian-save to capture this block into 20-projects/_logs/.\n' \
  "$ts" "$trigger" >> "$LOG_DIR/hook-events.log" 2>/dev/null

# Degrade loudly, not silently: an unreadable session_id must still produce a
# visibly-wrong-but-present stub, never a dropped write. Key it on the DATE, not
# the time: a per-second key would give every compaction its own file and defeat
# the one-stub-per-session cap. Grouping one day's unidentified compactions into
# a single capped stub is the honest degraded form of that contract.
if [ -z "$session_id" ]; then
  session_id="unknown-$today"
  printf '%s  PostCompact: DEGRADED - no session_id in hook input; grouping into %s.\n' \
    "$ts" "compaction-$session_id.md" >> "$LOG_DIR/hook-events.log" 2>/dev/null
fi
[ -z "$transcript_path" ] && transcript_path="?"

# Sanitize before the value ever reaches a filesystem path. A '/' or '..' in a
# hook-supplied session_id would otherwise build a path outside 20-projects/_logs/,
# fail the write, and surface only as a confusing later error. printf, never echo,
# into tr: echo's trailing newline would be translated into a trailing '_' in every
# filename. The trailing '-' in the tr set is literal - do not reorder it. This keeps
# the degrade-loudly contract: a malformed id still produces a visibly-wrong-but-
# present stub inside 20-projects/_logs/, plus a visible non-fatal signal, and exit 0.
raw_session_id="$session_id"
session_id=$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_')
session_id=$(printf '%s' "$session_id" | sed 's/^\.*//')
[ -z "$session_id" ] && session_id="sanitized-$today"
[ "$session_id" != "$raw_session_id" ] && printf '%s  PostCompact: session_id sanitized (%s -> %s) before filename interpolation.\n' \
  "$ts" "$raw_session_id" "$session_id" >> "$LOG_DIR/hook-events.log" 2>/dev/null

STUB="$LOGS_DIR/compaction-${session_id}.md"
MAX_ENTRIES=50

if [ ! -f "$STUB" ]; then
  cat > "$STUB" <<EOF
---
title: "Compaction stub — session ${session_id}"
tier: medium
tags: [tier/medium, type/project-log, compaction]
status: active
type: project-log
project: ""
created: "${today}"
last_reviewed: "${today}"
session_id: "${session_id}"
source_notes: []
---

# Compaction stub

Auto-written by the PostCompact hook so this session's material is
recoverable even when no summary was generated
([Claude Code #34556](https://github.com/anthropics/claude-code/issues/34556)).
Not a substitute for \`/wrap-up\` or \`/obsidian-save\` — capture the actual
work into a proper project log when you can. Excluded from dream-agent
occurrence counting (see \`.claude/agents/dream-agent.md\`).

## Compactions

EOF
fi

ENTRY_COUNT=$(awk '/^- /{n++} END{print n+0}' "$STUB" 2>/dev/null)
# A missing or failing awk leaves this empty, which makes the -lt test below emit
# "integer expression expected" on stderr. Smallest fix that removes the noise
# without touching the counting logic.
[ -z "$ENTRY_COUNT" ] && ENTRY_COUNT=0
if [ "$ENTRY_COUNT" -lt "$MAX_ENTRIES" ]; then
  printf -- '- %s  trigger=%s  transcript=%s\n' "$ts" "$trigger" "$transcript_path" >> "$STUB" 2>/dev/null
elif ! grep -q 'CAP REACHED' "$STUB" 2>/dev/null; then
  printf -- '- %s  CAP REACHED (%s entries) — further compactions in this session are not appended\n' "$ts" "$MAX_ENTRIES" >> "$STUB" 2>/dev/null
fi

exit 0
