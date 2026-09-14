---
name: obsidian-save
description: Save the current session's context into a medium-term project log. Use at the end of a working block or when finishing a debugging session.
disable-model-invocation: true
allowed-tools: Bash(git status *) Read Bash(ls *) Bash(echo *) Bash(pwd)
shell: bash
---

## Current session context

Run `git status` and `pwd` first, and use their output to ground the log in what actually
changed. If you have no shell in this harness, say so in the log rather than describing the
working tree from memory.

## Instructions

1. Summarize the current task, the decisions that were made, and any gotchas discovered.
2. Write a concise entry suitable for a medium-term project log at:
   `20-projects/_logs/<project>-<YYYY-MM-DD>.md`
   Follow `20-projects/_logs/templates/medium-term-project-log.md`.
3. Reference the relevant short-term daily notes by wikilink: `[[YYYY-MM-DD]]` from `10-daily/`.
4. Set the frontmatter:
   - `tier: medium`
   - `status: active`
   - `type: project-log`
5. Fill the **Promotion candidates (for long-term)** section honestly. It is the input the
   `preserve` skill and the promotion agent read. An empty section is a valid answer; an
   invented one poisons the long tier.

Produce the final log entry in Markdown, ready to save into the vault.
