# Agent onboarding

A library of copy-paste prompts for operating this vault with an agent.

The vault is designed to be run *by* an agent, not just read by one. Every prompt below is written
to be pasted verbatim into Claude Code (or any agent that reads `AGENTS.md` and `CLAUDE.md`) with
the vault as the working directory.

Each section states what the prompt does and **what good looks like**, so you can tell a real
result from a confident-sounding one. That distinction is the whole point of this vault: an agent
that reports success is not evidence of success.

> **New here?** Read [`concepts.md`](concepts.md) first for the tier model, or
> [`setup.md`](setup.md) if the vault is not installed yet. `AGENTS.md` in the repository root is
> the short version an agent reads on arrival.

---

## 1. First run — verify the install

Use this before trusting anything else. It establishes that the tooling actually works on your
machine, rather than that it is merely present.

```
You are working in a claude-memory-vault: an Obsidian vault that serves as your long-term memory.

Please verify the install and report back:

1. Read AGENTS.md, then CLAUDE.md, then the four files in .claude/rules/.
2. Run: bash .claude/scripts/run-tests.sh
3. Run: bash .claude/scripts/vault-check.sh
4. Report, as a table: which checks passed, which failed, and which optional dependencies
   (jq, perl) are present or missing on this machine.

Important when reading the vault-check output: "0 violations across 0 files" is NOT a pass — it
means nothing was scanned. Tell me the file count explicitly, and flag it if the count is zero.

Do not fix anything yet. Just report.
```

**What good looks like:** `run-tests.sh` reports all assertions passing, and `vault-check.sh`
reports `0 violation(s) across 9 file(s)` — nine being the five `EXAMPLE-` notes plus the three
MOC index notes and the wiki index. A non-zero file count is the part that matters; it is your
evidence the checker looked at anything at all.

If `jq` is missing, that is expected on a stock Mac and on Git for Windows. The lint hook says so
out loud and keeps working.

---

## 2. Make the vault yours

```
This vault is a fresh template. Please personalise it:

1. Open 30-knowledge/moc/ARCH-INDEX.md and replace the "Declare your domain" placeholder with a
   two-sentence statement of what this vault is about. Ask me what the domain is if it is not
   obvious from the repo you can see — do not invent one.
2. Update the first line of CLAUDE.md to describe this vault specifically.
3. Delete the fictional example notes: find . -name 'EXAMPLE-*.md' -delete
4. Re-run bash .claude/scripts/vault-check.sh and report the new file count.

After deleting the examples the file count will drop. Tell me the new number so we both know the
checker is still scanning something.
```

**What good looks like:** the agent asks rather than inventing a domain, and reports the new file
count instead of just saying "done". After deleting the examples you will have four notes left
(the three MOC files and the wiki index).

---

## 3. Onboard a codebase into the vault

The highest-value prompt here. This is what turns the vault from an empty structure into your
actual project memory. There is also a skill for it — `/onboard-project` — which follows the same
checklist.

```
Onboard the repository at <PATH-TO-REPO> into this vault. Follow
.claude/skills/onboard-project/SKILL.md.

Checklist — report against every line, with PASS / FAILED / NOT VERIFIED:

1. Project slug chosen (stable, lowercase, no spaces). State it.
2. Row added to 30-knowledge/moc/PROJECT-INDEX.md with the repo path and today's date.
3. Subsection for the project added under "Project logs & notes" in that same file.
4. Directory 90-auto-memory/<slug>/ created.
5. First medium-term log written to 20-projects/_logs/<slug>-<YYYY-MM-DD>.md from
   20-projects/_logs/templates/medium-term-project-log.md, with a real summary of what the
   repository is and does.
6. The repo's own CLAUDE.md references whichever vault standards it should load.
7. bash .claude/scripts/vault-check.sh run, and the new note passes.

Rules:
- Report anything you could not verify as NOT VERIFIED. Do not mark a step done on assumption.
- A PROJECT-INDEX row claiming a project is onboarded when only half the wiring exists is worse
  than no row at all, because the next pass will trust it.
- If you cannot read the target repository, stop and say so rather than writing a log about a
  repository you did not open.
```

**What good looks like:** a checklist with explicit statuses, including at least one honest
"NOT VERIFIED" if something was out of reach. An agent that returns seven PASSes without having
read the repo is the failure mode this checklist exists to catch.

---

## 4. Capture a working session

Run at the end of a block of work, while the context is still live.

```
/obsidian-save
```

Or, for a structured summary you can paste elsewhere as well:

```
/wrap-up
```

Then:

```
Write that summary into 20-projects/_logs/ as a proper medium-term log, following the template.

Fill the "Promotion candidates (for long-term)" section honestly — it is the input the /preserve
skill and the promotion agent read later. An empty section is a perfectly good answer. An invented
one poisons the long tier, which is the tier that steers every future session.

Also fill "What this session could not determine". If there genuinely were no gaps, write "none".
```

**What good looks like:** a log whose promotion-candidates section is short or empty, and whose
"could not determine" section is specific ("did not check whether this affects the v2 endpoint")
rather than absent.

---

## 5. Rehydrate at the start of a session

```
/resume
```

Or spelled out:

```
Read the three most recent logs in 20-projects/_logs/, ignoring templates/ and any
compaction-*.md stubs. Summarise: what was being worked on, which decisions were made, which
standards were applied, and what is still open.

If a session-memory search tool is available, use it too — and if it is not, say so in the
briefing rather than producing a summary that quietly rests on files alone.
```

**What good looks like:** the briefing names its sources, and says plainly when a tool was
unavailable instead of silently narrowing its evidence.

---

## 6. Promote medium-term work into a standard

```
/preserve
```

Or spelled out:

```
Scan 20-projects/_logs/ for "Promotion candidates (for long-term)" sections. For each candidate,
decide whether it meets the promotion bar:

  - GENERAL: the lesson will apply again outside the situation that produced it, and
  - VERIFIED: you can point at what established it.

Promote the ones that clear both into 31-standards/ (as type: standard) or 40-llm-wiki/wiki/
(as type: wiki-entity), using the matching template.

For the ones that do not clear the bar, leave them where they are and tell me WHY. An unexplained
non-promotion is indistinguishable from an oversight.

A vivid one-off is not a standard. When in doubt, leave it in the medium tier.
```

**What good looks like:** more candidates declined than promoted, each with a stated reason. The
long tier should grow slowly; that is a feature.

---

## 7. Periodic consolidation (the dream pass)

Run this manually a few times before you consider scheduling it.

```
Run a consolidation pass over this vault following .claude/agents/dream-agent.md exactly.

You are READ-AND-PROPOSE ONLY. Your single write is one dated journal at
20-projects/_logs/dream-<today>.md. Do not modify, stamp, or delete any existing note.

The journal must contain a "What this pass could not determine" section. A missing section is
itself a defect — an unstated gap is indistinguishable from completeness, and a journal that reads
as complete gets acted on as complete. "none" is a permitted value if there genuinely were none.

State how many files you enumerated for the stamp-sanity check. An unstated count is what makes an
incomplete scan invisible.
```

**What good looks like:** exactly one new file; a trust-sweep section sorted by defect type rather
than by date; and a populated "could not determine" section. If the pass modified any existing
note, it violated its own contract — revert it.

---

## 8. Retire a note, or record a disagreement

These two look similar and are not. Confusing them is the most common error in this system.

**Something is now known to be wrong, and you have a replacement** — supersede it:

```
The note [[OLD-NOTE]] has been superseded by what we learned in <describe>.

Mark it, do not delete it:
- set status: superseded
- add superseded_by: "[[NEW-NOTE]]"
- add a short section at the top saying what was wrong with it and what refuted it
- leave the original body intact, marked as retained-as-written

Then write the replacement note. Deleting the old one would destroy the only record of what we
believed and why we changed our minds, which is most of the reason to keep a memory at all.
```

**Two notes disagree and you do not yet know which is right** — record the contradiction:

```
[[NOTE-A]] and [[NOTE-B]] disagree about <topic>, and both still stand.

Add contradicts: "[[NOTE-B]]" to NOTE-A's frontmatter. Do NOT change either note's status, do NOT
pick a winner, and do NOT edit either body to resolve the disagreement.

This records a live, unadjudicated disagreement so it surfaces in the "Contradictions pending
resolution" dashboard in [[VAULT-INDEX]]. Resolving it is a human act.
```

**What good looks like:** the agent uses `superseded_by` only when there is a genuine replacement,
and reaches for `contradicts` when the question is still open. `superseded_by` closes a lifecycle;
`contradicts` closes nothing.

---

## 9. Prompting agents for this vault

A few habits that make the difference between a vault you can trust and one you cannot:

- **Ask for evidence, not assertions.** "Report the file count" beats "confirm it worked". A
  number can be wrong in a way you can see; "done" cannot.
- **Require a statement of what was not checked.** Every prompt above asks for this. An agent that
  never reports a gap is not a thorough agent — it is an agent that is not tracking its gaps.
- **Never let an agent bulk-edit frontmatter to silence a checker.** That is resolution-by-writing:
  it clears the alarm without establishing the fact. If `vault-check.sh` reports a violation, fix
  the underlying note, one at a time, for a stated reason.
- **Treat a zero-shaped result with suspicion.** "0 violations", "no findings", "nothing to
  promote" are all indistinguishable from an instrument that did not run. Ask what was scanned.
- **Do not let an agent promote its own output.** The dream pass proposes; a human or a separate
  pass disposes. An agent that consolidates its own prior conclusions converges on its own errors.

---

## See also

- [`AGENTS.md`](../AGENTS.md) — the short orientation an agent reads on arrival
- [`concepts.md`](concepts.md) — why the system is shaped this way
- [`reference.md`](reference.md) — the precise component reference
- [`setup.md`](setup.md) — installation and scheduling
- [`customizing.md`](customizing.md) — adapting the template without breaking it
