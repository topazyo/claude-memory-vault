---
title: Vault Index
tier: long
type: moc
tags: [tier/long, type/moc, dashboard]
status: stable
created: "2026-01-01"
last_reviewed: "2026-01-01"
---

# Vault Index

The conformance and freshness dashboard for this vault. Referenced as `[[VAULT-INDEX]]`.

**Requires the [Dataview](https://blacksmithgu.github.io/obsidian-dataview/) community plugin.**
Until Dataview is installed and enabled, every block below renders as a plain code fence rather
than a table. That is the expected first-run state, not a fault.

All queries exclude `templates/` folders, because a template's placeholder frontmatter is not a
conformance violation.

> A note on reading these tables: an empty table means "nothing matched". In a brand-new vault
> that is true of almost all of them, and it tells you nothing about whether the query works. As
> soon as you have real notes, an unexpectedly empty table is worth a second look — it may mean
> the query's folder no longer exists (see `docs/customizing.md` on renaming tiers).

## Active short-term notes

```dataview
table tier, status, project
from "10-daily" and !"10-daily/templates"
where tier = "short" and status = "active"
sort created desc
```

## Medium-term logs needing review

```dataview
table tier, status, project, last_reviewed
from "20-projects/_logs" and !"20-projects/_logs/templates"
where tier = "medium" and status = "active" and !contains(file.name, "compaction-")
sort last_reviewed asc
```

## Long-term standards due for review

```dataview
table tier, status, project, last_reviewed
from "31-standards" and !"31-standards/templates"
where tier = "long"
sort last_reviewed asc
```

## Dead-end notes (no outbound links)

<!-- "Dead end" here = pages with no OUTGOING links. For pages nothing links TO
     (no backlinks), swap file.outlinks -> file.inlinks; that variant is the
     "Orphan notes" query further down. -->

```dataview
table title, file.link
from "30-knowledge" or "31-standards" or "40-llm-wiki/wiki" or "20-projects"
where tier = "long" and length(file.outlinks) = 0 and !contains(file.folder, "templates")
```

## Conformance & freshness

The verification hardening layer — see `.claude/rules/verification.md` for the rules these
queries enforce. The optional keys `confidence` and `last_verified` are additive: Dataview
ignores keys that nothing queries, so adding them breaks nothing.

### Schema violations (missing tier or type)

<!-- `tier` and `type` are the two mandatory keys. The PostToolUse lint hook warns
     about them at write time; this query catches whatever was written before the
     hook was installed, or by a tool that bypassed it. -->

```dataview
table tier, type, file.folder
from "01-inbox" or "10-daily" or "20-projects" or "30-knowledge" or "31-standards" or "40-llm-wiki"
where (!tier or !type) and !contains(file.folder, "templates")
sort file.folder asc
```

### Impossible freshness stamps

<!-- A last_verified earlier than created is a defect in the STAMP, not a sign of
     staleness, and it is worth catching regardless of the note's age. -->

```dataview
table created, last_verified, tier
from "31-standards" or "30-knowledge" or "40-llm-wiki/wiki"
where last_verified and created and last_verified < created and !contains(file.folder, "templates")
```

### Long-term notes due for re-verification (>90 days or unreviewed)

```dataview
table last_reviewed, last_verified, confidence
from "31-standards" or "30-knowledge" or "40-llm-wiki/wiki"
where tier = "long" and !contains(file.folder, "templates")
  and status != "superseded"
  and (!last_reviewed or last_reviewed < date(today) - dur(90 days))
sort last_reviewed asc
```

### Superseded notes

<!-- Knowledge is marked, never deleted. These notes are retired but still
     readable, which is what lets the vault answer "what did we believe before,
     and what changed our minds". -->

```dataview
table superseded_by, last_reviewed, tier
from "20-projects" or "30-knowledge" or "31-standards" or "40-llm-wiki/wiki"
where status = "superseded" and !contains(file.folder, "templates")
```

### Orphan notes (nothing links to them)

```dataview
table file.folder, tier, type
from "01-inbox" or "10-daily" or "20-projects" or "30-knowledge" or "31-standards" or "40-llm-wiki/wiki"
where length(file.inlinks) = 0 and !contains(file.folder, "templates")
  and !contains(file.name, "compaction-")
sort file.folder asc
```

### Low-confidence / unverified notes

```dataview
table confidence, last_verified, tier
from "20-projects" or "30-knowledge" or "31-standards" or "40-llm-wiki/wiki"
where confidence = "low" and !contains(file.folder, "templates")
sort last_verified asc
```

### Promotion-loop freshness

Days since the newest `last_reviewed` in the long tier: warn above 7, escalate above 14.

Both thresholds are an assumption matched to a weekly promotion cadence, not a measured limit —
so treat the number as "which side of the threshold am I on", not as a verified deadline. If you
run the dream-agent, it states the same figure in its journal's "Scan coverage" section, and the
two should agree.

```dataview
table last_reviewed, (date(today) - date(last_reviewed)).days AS "Days since"
from "31-standards" or "40-llm-wiki/wiki"
where tier = "long" and last_reviewed and !contains(file.folder, "templates")
sort last_reviewed desc
limit 5
```

### Contradictions pending resolution

<!-- `contradicts` marks a live disagreement between two notes that BOTH still
     stand. It is NOT `superseded_by`, which retires a note — see
     .claude/rules/vault-notes.md. Nothing here resolves itself; an entry clears
     only when a human adjudicates it. -->

```dataview
table contradicts, status, last_reviewed
from "20-projects" or "30-knowledge" or "31-standards" or "40-llm-wiki/wiki"
where contradicts and !contains(file.folder, "templates")
sort last_reviewed asc
```

### Declared edges

<!-- These four keys are already typed edges; this block only reads what notes
     declare. Values are inconsistently shaped in practice — YAML lists, quoted
     single strings, and empty [] all occur — so the table renders them as-is
     rather than normalising. Nothing new is stored. -->

```dataview
table related_logs, source_notes, related_notes, superseded_by
from "20-projects" or "30-knowledge" or "31-standards" or "40-llm-wiki/wiki"
where (related_logs or source_notes or related_notes or superseded_by) and !contains(file.folder, "templates")
```

## See also

- [[ARCH-INDEX]] — the central map of content
- [[PROJECT-INDEX]] — the register of projects wired to this vault
