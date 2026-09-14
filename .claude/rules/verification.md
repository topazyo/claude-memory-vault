---
paths:
  - "01-inbox/**/*.md"
  - "10-daily/**/*.md"
  - "20-projects/**/*.md"
  - "30-knowledge/**/*.md"
  - "31-standards/**/*.md"
  - "40-llm-wiki/**/*.md"
---

# Verification & Freshness Rules

Applies when authoring or editing notes in the content tiers.
Full rationale: `docs/concepts.md`.

## Freshness

- Every fact is timeless, dated ("as of `YYYY-MM-DD`"), or a pointer to its source.
- Do not hardcode volatile values (counts, versions, prices) into notes, rules, or standards —
  link to the authoritative source instead. A hardcoded count is wrong the day after you write it
  and gives no signal that it has gone stale.

## Verification

- One canonical note per fact (single source of truth); other notes link, not restate.
- Mark anything not directly verified as `TBC` / `inferred` / `unverified`.
- For non-trivial claims use the signature citation:
  `[Source: [[note-or-url]] | YYYY-MM-DD | confidence: high|medium|low]`.

## Earned vs. unearned stamps

**An append that does not re-probe the underlying claim moves `last_reviewed`, not
`last_verified`.**

This is the single easiest rule to break and the most expensive one to break. Bumping
`last_verified` without a fresh probe creates an *unearned stamp*: a note that looks freshly
checked to every later pass, human or agent, while carrying a claim nobody has actually tested.
Later passes then read the stamp as evidence and skip the note — so one unearned stamp
suppresses its own detection indefinitely.

If you touched a note without re-checking what it asserts, move `last_reviewed` and leave
`last_verified` alone.

## Conformance

- Keep the mandatory `tier` / `type` frontmatter. Dataview queries break without it, the lint
  hook warns wherever it is wired, and `vault-check.sh` fails.
- Optional additive keys allowed: `confidence: high|medium|low`, `last_verified: YYYY-MM-DD`.
- Every note links out to at least one peer or index (standards and index notes link back to
  [[ARCH-INDEX]]); a note with no links is a defect.

## Automated writes (agents)

- Snapshot (git) and diff before automated writes; abort on unexpected drift.
- Spawned workers return status and path only, never pasted content. This bounds hallucination:
  a worker that reports "wrote 31-standards/foo.md" can be checked against the filesystem, while
  a worker that reports a paragraph of prose cannot.
- Re-read a proposed note to confirm frontmatter conformance before treating it as done.
- **Repair is a human act.** An agent reports a violation; it does not silently fix one. An
  automated repair that rewrites a note to satisfy a checker is resolution-by-writing — it clears
  the alarm without establishing the fact.
