---
name: preserve
description: Distill medium-term logs into long-term standards and wiki entities. The medium-to-long promotion step.
disable-model-invocation: true
allowed-tools: Read Bash(ls *) Bash(echo *)
shell: bash
---

## Preserve

1. Scan `20-projects/_logs/` for sections titled **Promotion candidates (for long-term)**.
2. For each candidate decision, cross-check any available corrections queue or session-memory
   tool for related corrections.
3. Propose long-term notes:
   - Standards → `31-standards/` (`tier: long`, `type: standard`)
   - Conceptual pages → `40-llm-wiki/wiki/` (`type: wiki-entity`)
4. Include backlinks to the medium-term logs and wiki entities the note came from, and to
   [[ARCH-INDEX]].

## The promotion bar

Not every candidate should be promoted. Promote when the lesson is **general** (it will apply
again outside the situation that produced it) and **verified** (you can point at what
established it). Everything else stays in the medium tier and is reported as still-pending,
**with the reason** — an unexplained non-promotion is indistinguishable from an oversight.

Output proposed notes as Markdown, clearly separated, ready to save. Propose; do not overwrite
existing notes.
