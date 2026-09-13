---
paths:
  - "01-inbox/**/*.md"
  - "10-daily/**/*.md"
  - "20-projects/**/*.md"
  - "30-knowledge/**/*.md"
  - "31-standards/**/*.md"
  - "40-llm-wiki/**/*.md"
---

# Vault Note Conventions

When creating or editing notes in these folders:

## Frontmatter (YAML)

- Every note starts with YAML frontmatter; keep keys consistent so Dataview queries work.
- Core keys: `title`, `tier`, `tags`, `status`, `type`, `created`, `last_reviewed`, `project`,
  `related_logs`.
- `tier`: `short` (daily) | `medium` (project logs) | `long` (standards).
- `type`: `daily` | `project-log` | `standard` | `wiki-entity` | `moc` | `reference`.
  Use `reference` for durable reference material that is *not* an enforced standard.
- `status`: `active` | `stable` | `superseded`.

### `superseded` — mark, never delete

Knowledge that has been replaced or refuted is **marked, never deleted**, so the record of what
was once believed survives. Pair `status: superseded` with `superseded_by: "[[replacement-note]]"`
where a replacement exists, or a one-line inline note of what refuted it where none does.

A `superseded` note stops appearing as a staleness candidate — the re-verification query in
[[VAULT-INDEX]] excludes it, and a `### Superseded notes` query surfaces the set on its own.

Deletion is the wrong primitive in a vault whose value is auditable provenance. A system that
silently drops superseded memories cannot answer "what did we believe last quarter, and why did
we change our minds" — and that question is most of the reason to keep a memory at all.

### `contradicts` — a live disagreement, unadjudicated

`contradicts: "[[other-note]]"` means this note **disagrees with** the linked one and **both still
stand**, pending a resolution nobody has made yet.

Do not conflate it with `superseded_by`. That key says *this* note has been replaced and should
stop surfacing as a staleness candidate, so it closes a lifecycle. `contradicts` closes nothing —
it changes no note's `status`, suppresses no note from any freshness query, and asserts only that
a disagreement is live. A refuted claim may therefore sit next to a fresh `last_verified` stamp
without either being quietly overwritten.

Surfaced by the `### Contradictions pending resolution` query in [[VAULT-INDEX]]. **Resolution is
a human act**, for the same reason deletion is: automatic contradiction-resolution silently drops
memories that are still needed, and it does so invisibly.

### Optional additive keys

`confidence` (`high`|`medium`|`low`), `last_verified` (ISO date), and `contradicts` (wikilink).
All non-breaking — Dataview ignores keys nothing queries. See `.claude/rules/verification.md`.

- Mirror the matching template in that folder's `templates/` subfolder.

## Links

- Use Obsidian wikilinks `[[Note Title]]` for internal references, not raw paths or Markdown links.
- Daily notes are named `YYYY-MM-DD.md`, with the template's `title: "YYYY-MM-DD – HH:mm"`.
  Wikilinks resolve by filename, so reference them as `[[YYYY-MM-DD]]`.
- Standards and index notes link back to [[ARCH-INDEX]].
- Every note links out to at least one peer or index. **A note with no links is a defect** — see
  the dead-end and orphan queries in [[VAULT-INDEX]].

## Dataview

- Dataview is active; keep frontmatter machine-readable (ISO dates `YYYY-MM-DD`, list values as
  YAML lists) so queries don't break.

## Filing

- New captures go to `01-inbox/`; promote to the correct tier when processed.
- Don't create top-level folders; use the existing numbered structure.
