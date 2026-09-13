---
title: Architecture Index
tier: long
type: moc
tags: [tier/long, type/moc]
status: stable
created: "2026-01-01"
last_reviewed: "2026-01-01"
related_notes:
  - "[[VAULT-INDEX]]"
  - "[[PROJECT-INDEX]]"
---

# Architecture Index

The central map of content for this vault, referenced everywhere as `[[ARCH-INDEX]]`.

Every long-tier note links back here. That convention is what keeps the long tier navigable
rather than a flat pile of files, and it is why "a note with no links is a defect" is a rule
rather than a preference (see `.claude/rules/vault-notes.md`).

> **This is a scaffold.** It ships nearly empty on purpose. Replace the placeholder sections
> below with your own as you accumulate notes. The headings are a suggested shape, not a
> requirement.

## Declare your domain

Write one or two sentences here saying what this vault is *about*. It is worth doing early.

A vault without a declared domain drifts: notes get filed because they were interesting rather
than because they belong, and a year later nobody can say what the collection is for. Declaring
the domain also makes one specific question answerable: "is this note in scope?" That is the
question that decides whether something gets promoted or archived.

Example: *"This vault's domain is operating our payments platform — its services, runbooks,
incident lessons, and the standards we hold them to."*

## Long-term standards

Link your `31-standards/` notes here as you write them, with a one-line description each. The
description matters more than the link: it is what lets you decide whether to open a note without
opening it.

## Knowledge folders

Group the durable reference material under `30-knowledge/` here. Notes that are reference rather
than enforced standard should carry `type: reference`, which distinguishes "this is useful
background" from "this is how we do things".

- `30-knowledge/research/` — *(describe what you keep here)*

## Concept wiki

Entities under `40-llm-wiki/wiki/` — one page per concept, distilled from the raw captures in
`40-llm-wiki/raw/`.

- [[LLM-wiki-index]] — the index of wiki entities

## See also

- [[VAULT-INDEX]] — conformance and freshness dashboards
- [[PROJECT-INDEX]] — the register of projects wired to this vault
- Project logs — `20-projects/_logs/`
- Archive — `99-archive/` — retired notes, kept rather than deleted
