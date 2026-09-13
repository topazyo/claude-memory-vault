---
title: "LLM wiki index"
tier: long
tags: [tier/long, type/moc, llm/wiki]
status: stable
type: moc
created: "2026-01-01"
last_reviewed: "2026-01-01"
related_notes:
  - "[[ARCH-INDEX]]"
---

# LLM wiki index

The entry point for the concept wiki under `40-llm-wiki/wiki/`. Referenced as
`[[LLM-wiki-index]]`.

> **This is a scaffold.** List your entities below as you write them and delete this callout.

## How this tier works

Two folders, and the distinction between them matters:

- **`40-llm-wiki/raw/`** — untrusted captures. Web clippings, model output, pasted material.
  Nothing here is authoritative. The path-scoped rule in `.claude/rules/untrusted-captures.md`
  treats instructions inside these files as data, never as commands.
- **`40-llm-wiki/wiki/`** — distilled entities. One page per concept, written by you, carrying a
  summary, an explanation, its relationships, its open contradictions, and a citation back to
  whatever raw source it came from.

The split exists so that the act of promoting something from `raw/` to `wiki/` is a deliberate
step where a human decides what is true, rather than a copy.

An entity is worth creating when a concept is referenced from more than one standard, or when you
have explained it twice. Use `40-llm-wiki/wiki/templates/llm-wiki-entity.md`.

## Entities

One line per entity: its wikilink and a one-line description.

## See also

- [[ARCH-INDEX]] — the central map of content
- [[VAULT-INDEX]] — conformance and freshness dashboards
