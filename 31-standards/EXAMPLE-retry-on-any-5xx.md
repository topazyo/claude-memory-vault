---
title: "Retry on any 5xx"
tier: long
tags: [tier/long, type/standard, example]
status: superseded
type: standard
project: "example-api"
created: "2025-09-02"
last_reviewed: "2026-01-18"
confidence: low
last_verified: "2026-01-18"
superseded_by: "[[EXAMPLE-retries-must-carry-an-idempotency-key]]"
related_logs:
  - "[[EXAMPLE-example-api-2026-01-15]]"
---

> **This is a fictional example note.** It exists to demonstrate the vault's most distinctive
> habit: knowledge that turns out to be wrong is **marked, not deleted**. Delete every example
> with: `find . -name 'EXAMPLE-*.md' -delete`

# Status: superseded

Superseded on 2026-01-18 by [[EXAMPLE-retries-must-carry-an-idempotency-key]].

This note is kept deliberately. It records what we believed for four months, and deleting it
would destroy the only evidence of *why* the replacement exists. The re-verification query in
[[VAULT-INDEX]] excludes `status: superseded`, so this note no longer surfaces as a staleness
candidate — it is retired, not merely old.

**What was wrong with it:** the rule below treats a 5xx or a timeout as evidence that the work
did not happen. It is not. A timeout means the client stopped waiting, and the request may well
have succeeded. Retrying under that assumption double-charged three customers.

# Decision

*(retained as originally written)*

Retry any request that returns a 5xx status or times out, up to three attempts with exponential
backoff.

# Rationale

*(retained as originally written)*

5xx responses and timeouts indicate transient server-side trouble. Retrying recovers from brief
outages without bothering the user, and three attempts with backoff has been sufficient in
practice.

# Consequences

*(retained as originally written)*

- Transient provider blips become invisible to callers.
- Tail latency rises modestly for the affected requests.

# References

- [[EXAMPLE-retries-must-carry-an-idempotency-key]] — the standard that replaced this one
- [[EXAMPLE-example-api-2026-01-15]] — the incident log that refuted it
- [[ARCH-INDEX]]
