---
title: "example-api – Session Log – 2026-01-15"
tier: medium
tags: [tier/medium, type/project-log, example]
status: active
type: project-log
project: "example-api"
created: "2026-01-15"
last_reviewed: "2026-01-15"
source_notes:
  - "[[EXAMPLE-2026-01-15]]"
---

> **This is a fictional example note.** Delete every example with:
> `find . -name 'EXAMPLE-*.md' -delete`

# Summary of sessions

Investigated three reports of duplicate charges. Traced them to client-side retries during a
window of elevated latency at the payment provider: the original request succeeded server-side,
our client timed out waiting for the response, and the retry created a second charge.

Confirmed the provider supports an `Idempotency-Key` header and that we have never sent one.
Shipped a fix that derives the key from the order ID plus the attempt's business operation, so
the key is stable across retries of the *same* logical operation and different across genuinely
new ones.

# Key decisions

- Send `Idempotency-Key` on every mutating provider call.
- Derive the key from the business operation, **not** from a fresh UUID per attempt. A per-attempt
  UUID would be different on the retry, which is exactly the bug.
- Retain keys provider-side for 24h, which is longer than our maximum retry window.

# Promotion candidates (for long-term)

- **A timeout is not evidence that work did not happen.** It is evidence that we stopped waiting.
  This generalises well beyond payments — it applies to any retry over a network boundary, and
  we have now been bitten by it once. Candidate for `31-standards/`.
- **`Idempotency-Key` as a concept** deserves its own wiki entity, since it will be referenced
  from several standards.

# What this session could not determine

- Whether any duplicate charges occurred *before* the reported window. We only checked the three
  reported orders and the six-minute latency spike around them. A full historical sweep was not
  run, so the true blast radius is unknown.

# Links

- [[EXAMPLE-2026-01-15]] — the daily note this came from
- [[EXAMPLE-retries-must-carry-an-idempotency-key]] — the standard this was promoted into
- [[ARCH-INDEX]]
