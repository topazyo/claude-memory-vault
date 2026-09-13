---
name: onboard-project
description: Onboard a repo or codebase into this vault — choose its project slug, create its auto-memory directory, write its first medium-term log, add its PROJECT-INDEX row and log subsection, and point the repo's own CLAUDE.md at the vault standards it should load. Use when asked to onboard a project, wire a codebase into the vault, or register a new repo's memory.
---

## Onboarding a codebase into the vault

Wiring is mechanical; the honesty at the end is the part that matters. Work through the steps in
order — later steps reference the slug and paths the earlier ones fix.

1. **Confirm the repo.** Ask for the repository path if it was not given. Read its `README` and
   root `CLAUDE.md` (if any) before writing anything, so the first log describes the real project
   rather than a guess.

2. **Choose the project slug.** Lowercase, hyphenated, stable: `acme-api`, never `Acme API`.
   It becomes the `project:` frontmatter value in every log and the grouping key in every
   dashboard, and Dataview grouping is case- and spelling-sensitive. Check
   `30-knowledge/moc/PROJECT-INDEX.md` first — if a near-match slug already exists, reuse it
   rather than creating a second spelling of the same project.

3. **Create the auto-memory directory.** `90-auto-memory/<slug>/`. It is machine-managed under
   Claude Code's own schema and is deliberately out of scope for `vault-check.sh` and for the
   frontmatter contract, so do not add tiered frontmatter to anything you put there. Durable
   knowledge belongs in the long tier, never here.

4. **Write the first medium-term log.** Copy
   `20-projects/_logs/templates/medium-term-project-log.md` to
   `20-projects/_logs/<slug>-<YYYY-MM-DD>.md` and fill it in. Set `tier: medium`,
   `type: project-log`, `status: active`, `project: "<slug>"`, and today's date in `created:`
   and `last_reviewed:`. Leave **Promotion candidates** empty if there are none — an invented
   candidate poisons the long tier.

5. **Add the PROJECT-INDEX row.** One row in the table: project, repo path, onboarded checkbox,
   onboarded date, and a one-line note on what the codebase is. Write the repo path the way the
   owner will read it (`~/code/<slug>`), not as an absolute path containing a username.

6. **Add the log subsection.** Under **Project logs & notes** in the same file, add a `###
   <slug>` heading and link the log from step 4. A log nobody links to is an orphan, and the
   orphan query in `VAULT-INDEX.md` will flag it.

7. **Point the project's CLAUDE.md at the vault.** Add `@`-import lines in the repo's own
   `CLAUDE.md` for the standards that repo should load — at minimum the map of content, plus any
   `31-standards/` note that governs its work. Use a relative path from the repo to the vault,
   for example `@../claude-memory-vault/30-knowledge/moc/ARCH-INDEX.md`. Keep the list short:
   every imported file is loaded into every session in that repo. If the vault does not sit
   beside the repo on disk, say so and ask rather than guessing the relative depth.

8. **Verify by re-reading, not by remembering.** Do not trust the writes; re-open each file:
   - Re-read the new log and confirm the first line is a bare `---`, and that `tier:`, `type:`,
     `project:`, and both dates are present and correctly spelled.
   - Re-read `PROJECT-INDEX.md` and confirm the row renders as a table row (pipes intact) and
     the slug matches the log's `project:` value character for character.
   - Re-read the repo's `CLAUDE.md` and confirm each `@`-import path resolves to a file that
     exists. An import that points nowhere fails silently.
   - Run `bash .claude/scripts/vault-check.sh` from the vault root. It reports and never
     repairs. `0 violations across 0 files` means it scanned nothing — that is a broken
     invocation, not a pass.

9. **Report what you could not verify.** Name every step you skipped, guessed, or could not
   confirm — a repo path you were told rather than checked, a `vault-check.sh` run that would not
   execute, an `@`-import you could not resolve. `none` is a valid answer; silence is not. If any
   step is unverified, leave the onboarded checkbox unticked and say why in the row's Notes
   column. A row claiming a project is onboarded when only half the wiring exists is worse than
   no row, because the next pass trusts it and stops looking.
