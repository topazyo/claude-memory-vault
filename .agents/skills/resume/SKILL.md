---
name: resume
description: Resume work by summarizing the most recent medium-term logs. Use at session start.
disable-model-invocation: true
allowed-tools: Read Bash(ls *)
shell: bash
---

## Resume Context

0. Check for `.claude/logs/runner-tripwire`. If it exists, stop and show its contents instead of a
   briefing: a scheduled pass changed a steering or execution surface, and the files it names were
   quarantined. Say that nothing else in this skill ran, and that the owner clears it by reading the
   quarantined files and deleting the tripwire. Do not delete it yourself.
   Then run `ls -ld .claude .claude/logs`. If either line starts with `l`, that folder is a link,
   and while it is one the runners write their tripwire only to their state directory
   (`docs/reference.md` §4.3 says where), so one may be set that this check cannot see. Stop the
   same way: say that, and that nothing else in this skill ran, and leave the state directory to the
   owner. Do not run `vault-check.sh` to find out, because it loads the vault's own scripts, which a
   pass may have changed and the runner may not have put back.
1. Read the most recent 3 log files from `20-projects/_logs/`, ignoring `templates/`, any
   `compaction-*.md` stubs, and the `dream-*.md` journals and `promotion-*.md` reports the scheduled
   passes write. Those hold a pass's proposals and results, not a record of work, and a dream
   journal lands in this folder every night, so counting them would build the briefing from the
   passes' own output instead of from what was done.
2. If a session-memory search tool is available (any MCP server that indexes past sessions), use it to
   retrieve recent observations about the same project. If it is unavailable, say so in the
   briefing rather than producing a briefing that silently rests on files alone.
3. Summarize:
   - What was being worked on
   - Recent decisions and which standards were applied
   - Outstanding tasks and open questions

Output a briefing suitable for pasting into today's daily note in `10-daily/`.
