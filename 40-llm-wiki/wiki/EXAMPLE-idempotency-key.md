---
title: "Idempotency key"
tier: long
tags: [tier/long, llm/wiki, example]
status: stable
type: wiki-entity
created: "2026-01-18"
last_reviewed: "2026-01-18"
confidence: high
last_verified: "2026-01-18"
---

> **This is a fictional example note.** It demonstrates the concept-wiki tier: one page per
> concept, distilled from raw captures, linked from the standards that depend on it. Delete every
> example with: `find . -name 'EXAMPLE-*.md' -delete`

# Summary

A client-supplied token that lets a server recognise two requests as the *same* request, so the
second one returns the first one's result instead of performing the work again.

# Explanation

The problem an idempotency key solves is not on the server. It is that a client which stops
waiting cannot tell the difference between "this did not happen" and "this happened and I did not
hear about it". Retrying is safe in the first case and harmful in the second, and the client has
no way to distinguish them.

An idempotency key moves that decision to the side that actually knows. The client asserts "this
is the same operation I asked about before", and the server — which does know whether it ran —
either performs the work or replays the earlier outcome.

Two properties make a key correct:

- **Stable across retries of one logical operation.** A key generated fresh per attempt is
  different on the retry, so the server sees new work. This defeats the entire mechanism while
  appearing to implement it, which is what makes it a common and expensive mistake.
- **Distinct across genuinely different operations.** Charging an order and re-charging it after a
  refund are different operations. Reusing a key across them suppresses work that should happen.

Retention matters too. Keys are stored for a finite window; if that window is shorter than the
maximum retry window, a late retry arrives after expiry and is processed as new.

# Relationships

- [[EXAMPLE-retries-must-carry-an-idempotency-key]] — the standard that requires this
- [[ARCH-INDEX]]

# Contradictions / Open Questions

- Whether keys should be scoped per-endpoint or globally per-operation is unresolved here. Both
  work; they fail differently under endpoint refactors, and no incident has forced the question.

# Sources / Verification

- [Source: [[EXAMPLE-example-api-2026-01-15]] | 2026-01-15 | confidence: high]
