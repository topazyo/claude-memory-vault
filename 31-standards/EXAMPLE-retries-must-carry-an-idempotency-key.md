---
title: "Retries must carry an idempotency key"
tier: long
tags: [tier/long, type/standard, example]
status: stable
type: standard
project: "example-api"
created: "2026-01-18"
last_reviewed: "2026-01-18"
confidence: high
last_verified: "2026-01-18"
related_logs:
  - "[[EXAMPLE-example-api-2026-01-15]]"
---

> **This is a fictional example note.** It demonstrates what a promoted long-tier standard looks
> like: a general lesson, a stated rationale, named consequences, and a citation back to the
> evidence that produced it. Delete every example with:
> `find . -name 'EXAMPLE-*.md' -delete`

# Decision

Every retry of a mutating request across a network boundary must carry an idempotency key that is
**stable across retries of the same logical operation** and distinct across different operations.

Derive the key from the business operation — an order ID, a transfer ID — never from a fresh UUID
generated per attempt.

# Rationale

A timeout tells you that you stopped waiting. It tells you nothing about whether the work
happened. The request may have succeeded, failed, or still be in flight at the moment the client
gave up, and from the client's side those three are indistinguishable.

This is the general form of a specific failure: retrying is safe only when the receiver can
recognise the retry as the *same* request. Absent that, a retry is simply a second request, and
"retry on timeout" quietly becomes "do it twice on timeout".

The per-attempt-UUID mistake is worth naming explicitly because it *looks* like the fix. A fresh
key on every attempt satisfies the letter of "send an idempotency key" while defeating its entire
purpose — the retry presents a different key and is processed as new work.

# Consequences

- All mutating provider calls change signature to accept an operation-derived key.
- Key retention must exceed the maximum retry window, or a late retry lands after expiry and is
  treated as new. Verify the retention period rather than assuming the default is enough.
- Operations that genuinely *should* run twice need distinct keys. "Charge this order" and
  "charge this order again after a refund" are different operations, not a repeat of one.

# Sources / Verification

- [Source: [[EXAMPLE-example-api-2026-01-15]] | 2026-01-15 | confidence: high]
- Single-incident evidence. The mechanism is general and well understood, but this standard was
  promoted on the strength of one production incident, not a survey. Stated plainly so a later
  reader can weigh it — see `.claude/rules/verification.md` on marking what was not established.

# References

- [[EXAMPLE-example-api-2026-01-15]] — the medium-term log this was promoted from
- [[EXAMPLE-idempotency-key]] — the concept entity
- [[EXAMPLE-retry-on-any-5xx]] — the earlier standard this one superseded
- [[ARCH-INDEX]]
