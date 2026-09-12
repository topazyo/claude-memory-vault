---
name: resume
description: Resume work by summarizing the most recent medium-term logs. Use at session start.
disable-model-invocation: true
allowed-tools: Bash(cat *) Bash(ls *)
shell: bash
---

## Resume Context

1. Read the most recent 3 log files from `20-projects/_logs/`, ignoring `templates/` and any
   `compaction-*.md` stubs.
2. If a session-memory search tool is available (any MCP server that indexes past sessions), use it to
   retrieve recent observations about the same project. If it is unavailable, say so in the
   briefing rather than producing a briefing that silently rests on files alone.
3. Summarize:
   - What was being worked on
   - Recent decisions and which standards were applied
   - Outstanding tasks and open questions

Output a briefing suitable for pasting into today's daily note in `10-daily/`.
