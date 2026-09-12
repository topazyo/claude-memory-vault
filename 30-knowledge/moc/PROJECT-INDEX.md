---
title: Project Onboarding Tracker
tier: long
type: moc
tags: [tier/long, type/moc]
status: stable
created: "2026-01-01"
last_reviewed: "2026-01-01"
related_notes:
  - "[[ARCH-INDEX]]"
  - "[[VAULT-INDEX]]"
---

# Projects wired to this vault

The register of every codebase whose memory lives here. Unlike [[VAULT-INDEX]], this is a
hand-maintained table, not a Dataview query — there is no frontmatter key that can tell you a
repo was onboarded, only a human who did it.

> **This is a scaffold.** The row below is a fictional example showing the intended shape.
> Delete it and add your own.

| Project        | Repo path                    | Onboarded | Onboarded date | Notes                                                        |
| -------------- | ---------------------------- | --------- | -------------- | ------------------------------------------------------------ |
| example-api    | `~/code/example-api`         | [x]       | 2026-01-15     | Fictional example row — delete this. Node/TypeScript service. |

## Project logs & notes

Every medium-term log in `20-projects/_logs/` should be listed here, grouped by its `project:`
frontmatter key.

This section exists because of a specific failure mode: a log nobody links to is an orphan, and
the orphan query in [[VAULT-INDEX]] will flag it. Rebuilding this list by hand from each log's
`project:` key — rather than by eye — is the only way to be sure it is complete. Checking by set
difference catches the ones you would otherwise skim past.

### example-api

- *(no logs yet)*

## Onboarding a new project

Wiring a new codebase into this vault means, roughly:

1. Decide the project's short name. It becomes the `project:` frontmatter value everywhere, so
   pick something stable and lowercase.
2. Point the project's own `CLAUDE.md` at whichever vault standards it should load.
3. Create its auto-memory directory under `90-auto-memory/<project>/` if you use one.
4. Add a row to the table above, and a subsection under **Project logs & notes**.
5. Write the first log into `20-projects/_logs/` so the project has a memory from day one.

Keep the table honest about what you actually verified. A row that claims a project is onboarded
when only half the wiring exists is worse than no row, because the next pass will trust it.

## See also

- [[ARCH-INDEX]] — the central map of content
- [[VAULT-INDEX]] — conformance and freshness dashboards
