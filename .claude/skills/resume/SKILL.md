---
name: resume
description: Resume work by summarizing the most recent medium-term logs. Use at session start.
disable-model-invocation: true
allowed-tools: Read Bash(ls *)
shell: bash
---

## Resume Context

0. Run `ls -ld .claude .claude/logs` first. Stop, instead of a briefing, unless it prints a line
   for `.claude` and every line it prints starts with `drw`. A line that starts with `l` is a link,
   `-` a file and `dr-` a folder that cannot be written, and in each case the runners write their
   tripwire only to their state directory (`docs/reference.md` §4.3 says where), so one may be set
   that this skill cannot see. A missing `.claude/logs` is fine: the runners make it. Say why you
   stopped and that nothing else in this skill ran, and leave the state directory to the owner. Do
   not run `vault-check.sh` or another of the vault's scripts to find out, because they load the
   vault's own library, which a pass may have changed and the runner may not have put back.
   Then check for `.claude/logs/runner-tripwire`. If it exists, stop and show its contents instead
   of a briefing: a scheduled pass changed a steering or execution surface, or ended before what it
   wrote could be checked. Say that nothing else in this skill ran, and that the owner clears it by
   doing what it says and then deleting it and its copy in the state directory. Do not delete it
   yourself.
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
