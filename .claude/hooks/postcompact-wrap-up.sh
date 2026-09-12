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
if command -v jq >/dev/null 2>&1; then
  trigger="$(printf '%s' "$input" | jq -r '.trigger // "?"' 2>/dev/null || echo '?')"
  session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
  transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
fi

printf '%s  PostCompact (trigger=%s). Consider /wrap-up or /obsidian-save to capture this block into 20-projects/_logs/.\n' \
  "$ts" "$trigger" >> "$LOG_DIR/hook-events.log" 2>/dev/null

# Degrade loudly, not silently: a missing jq or unset session_id must still
# produce a visibly-wrong-but-present stub, never a dropped write.
[ -z "$session_id" ] && session_id="unknown-$(date '+%Y%m%d%H%M%S' 2>/dev/null || echo unknown)"
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
[ -z "$session_id" ] && session_id="sanitized-$(date '+%Y%m%d%H%M%S' 2>/dev/null || echo unknown)"
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
