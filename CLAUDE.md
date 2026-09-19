# Project Instructions

This repository is an **Obsidian knowledge vault** (Markdown PKM), not a code project, and it works
with any coding-agent harness. The instructions every harness follows live in `AGENTS.md`. Claude
Code loads them through the import below, so there is one copy of the rules, not one per harness.

@AGENTS.md

## Claude Code adapter

What Claude Code adds on top of `AGENTS.md`. Everything here is configured under `.claude/`, and
nothing in `AGENTS.md` depends on it.

- **Rules load on their own.** Claude Code reads `.claude/rules/*.md` and applies each one to the
  folders its `paths:` frontmatter names. Other harnesses read the same files because `AGENTS.md`
  tells them to.
- **Hooks** are registered in `.claude/settings.json`: `vault-lint.sh` runs after every Write or
  Edit and `postcompact-wrap-up.sh` writes a stub after a compaction.
  `instructions-loaded-log.sh` records which instruction files loaded at session start. It ships
  but is **not registered**, because it starts a process for every instruction file of every
  session and most sessions never read its log. `docs/setup.md` has the snippet that turns it on.
- **A Read deny** covers `.env`, `.env.*` and `secrets/**` at the vault root.
- **Skills** are slash commands: `/resume`, `/obsidian-save`, `/wrap-up`, `/preserve`,
  `/onboard-project`.
- **Subagents.** `dream-agent` and `promotion-agent` carry `tools:` allowlists that Claude Code
  enforces. The scheduled runners use them by default (`VAULT_AGENT=claude`).

## Knowledge base

Central index / map of content:

@30-knowledge/moc/ARCH-INDEX.md

<!-- Add further standards as @-import lines as you write them, e.g.
     @31-standards/<your-standard>.md
     Keep this list short: everything imported here is loaded into every session.
     List the same notes under "Standards every session reads" in AGENTS.md, so other harnesses
     read them too. -->
