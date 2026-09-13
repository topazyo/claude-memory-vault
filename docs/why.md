# Why build this instead of adopting GBrain, COG, or another memory system

"Agent memory in markdown" is a crowded space. Before writing this template I ran two research
passes over what already exists, with the goal of *not* building anything: find the best existing
implementation, adopt it, move on. This document records why that did not happen, what I took
from those projects anyway, and — just as important — when you should use one of them instead of
this repository.

Every factual claim about another project below carries the date it was read. These projects move
fast; if a date is more than a few months old, re-check the claim before relying on it.

---

## Contents

1. [What I needed](#1-what-i-needed)
2. [How the alternatives were evaluated](#2-how-the-alternatives-were-evaluated)
3. [GBrain](#3-gbrain)
4. [COG](#4-cog)
5. [The wider landscape, and what it taught](#5-the-wider-landscape-and-what-it-taught)
6. [What this repository borrowed](#6-what-this-repository-borrowed)
7. [Where this repository is weaker](#7-where-this-repository-is-weaker)
8. [Choosing: a decision rule](#8-choosing-a-decision-rule)

---

## 1. What I needed

The requirements came from how I actually work, not from a feature wishlist. They are listed in
order of how quickly each one eliminated candidates.

1. **Native Windows.** My primary runtime is Claude Code on Windows. WSL2 is installed for Linux
   tooling, but it is not where Claude Code runs. Anything that needs a Unix daemon, a Unix socket,
   or a Linux-only build is a second machine to operate, not a tool.
2. **No services, no keys, no second store.** Markdown in git is the only source of truth. No
   database that can drift from the files, no embedding model whose version change forces a
   destructive rebuild, no API key required for the system to function at all.
3. **Automation that proposes rather than rewrites.** An unattended agent may *suggest* changes to
   what I know. It may not reorganize, merge, or overwrite my notes overnight. Where an agent does
   write, the write must be fenced to known folders and revertible with one git command.
4. **A small, earned long tier.** The notes that steer future sessions should be few, verified,
   and dated. Capture can be cheap and noisy; promotion must be deliberate.
5. **Provenance that survives being wrong.** A refuted belief is marked superseded and kept, with a
   link to what replaced it. Two notes that disagree both stay visible until a human decides.
   Freshness stamps distinguish "I re-read this" from "I re-tested this".
6. **Checks that prove they ran.** A conformance checker that reports "0 violations" must also
   report how many files it scanned, and its test suite must include known-bad inputs that are
   *supposed* to fail.
7. **Something another person can clone.** A template, not a personal system with my home
   directory baked into its hooks.

None of these is exotic. What turned out to be rare is having all of them at once.

---

## 2. How the alternatives were evaluated

Two passes, about a month apart.

**July 2026 — fit survey.** A research workflow took nine open-source "second brain" repositories
for Claude Code and Obsidian to full analysis (and logged ten more as lower relevance). Every
per-repository finding went through an independent verification pass before it could influence a
score. That pass earned its keep: one research agent had invented an alarming security finding
about a candidate — an automatic external publishing pipeline — that did not exist anywhere in the
repository. Another candidate's headline mechanism could not be confirmed from source, so only its
underlying principle was carried forward.

**August 2026 — landscape and a GBrain deep dive.** A broader pass gathered 77 candidate rows
across memory engines, published postmortems, and design doctrine, then compared them on eleven
axes: storage substrate, retrieval, write authority, context cost, consolidation and forgetting,
trust and freshness, multi-project scale, failure modes, security, onboarding, and measurement. It
closed with a steelman — the strongest case *against* this design — which is summarized honestly in
[section 7](#7-where-this-repository-is-weaker). GBrain was then analysed from a disposable clone at
a pinned version.

The conclusion of both passes was the same: no candidate could be adopted without giving up at
least one of the requirements above, but several had ideas worth taking.

---

## 3. GBrain

*[garrytan/gbrain](https://github.com/garrytan/gbrain). Analysed at `v0.46.28.0`, commit dated
2026-08-21; README re-read 2026-09-13.*

### What it is

GBrain is the most serious engineering effort in this space, and it deserves to be described that
way. Its pitch is "give the agent you already use a memory you control." Under the pitch:

- **The same storage thesis as this vault, enforced harder.** Its architecture docs state that the
  git repository of markdown and frontmatter is the system of record and the Postgres/PGLite
  database is a *derived cache* that is rebuilt, never backed up. A CI script fails the build on any
  direct write to a derived table outside the reconcile layer. That is stricter than anything this
  vault holds itself to.
- **Real hybrid retrieval.** A Postgres full-text arm, a pgvector arm, an image arm and a
  typed-edge arm, fused by Reciprocal Rank Fusion, re-scored with graph signals, then optionally
  passed through a cross-encoder reranker that fails open.
- **Synthesis that admits ignorance.** Its `think` command returns prose with citations, a
  *structured* citation array (because, in its own prompt's words, you should never trust the model
  to keep prose citations stable), and a `gaps` array listing what it has no data on. Its prompt
  also requires contradicting sources to be surfaced side by side rather than silently resolved.
- **A large agent surface.** Over a hundred MCP tools tiered into fail-closed surfaces, a skill
  library of about sixty-five, and multi-user support through Postgres and OAuth 2.1.
- **Unusual honesty.** It publishes incident write-ups, including a dream-cycle run that cost 53×
  its estimate and surfaced nothing.

### Why I did not adopt it

**The runtime, first and decisively.** As read in August 2026, GBrain runs on Bun and its release
builds target `darwin-arm64` and `linux-x64`; every CI job runs on Ubuntu; its background-service
installer targets macOS, systemd, containers and cron, with no Windows Task Scheduler path; and its
serve/sync lock uses a Unix domain socket. On a Windows-native Claude Code setup that means WSL2 —
and "use both" would put the retrieval engine on one side of a filesystem boundary and the vault it
indexes on the other. *If you are on macOS or Linux, this objection does not apply to you. Check
whether it still applies on Windows before relying on it.*

**Operational weight.** A database, a daemon, an optional embedding key and an optional reranker
key are all reasonable costs for what GBrain delivers. They are the costs requirement 2 exists to
avoid. At the size of a personal engineering vault — tens to low hundreds of curated notes — the
binding problem is precision and trust, not retrieval horsepower.

**Where writes come from.** GBrain's dream cycle includes LLM extraction phases that write into the
content markdown. That is a legitimate design choice, and GBrain fences what it writes. It is still
the opposite default from requirement 3.

**Blast radius.** As read, GBrain's open-source guardrails registry ships empty and observe-only —
a registered guardrail cannot block or rewrite behaviour — so its injection defences are specific
sanitizers plus prompt hygiene. Combined with an HTTP and OAuth mode, that is a larger trust
boundary than a folder of files. This is not a criticism of GBrain's security culture, which is
more mature than most; it is a statement about surface area.

### What it would take to change my mind

Adopting GBrain becomes the right call when **all three** of these are true: Claude Code's primary
runtime moves to Linux, macOS, or WSL2; the curated content passes roughly five hundred notes; and
more than one person needs write access to the same memory. Short of all three, adoption buys
retrieval I do not need at an operational cost I have chosen not to pay.

---

## 4. COG

*[huytieu/COG-second-brain](https://github.com/huytieu/COG-second-brain). Surveyed July 2026;
README re-read 2026-09-13.*

### What it is

COG — "Cognition + Obsidian + Git" — is the closest philosophical neighbour to this repository.
Plain markdown, git for history, no database, no vendor lock-in. It describes itself as
self-evolving: an agent-driven personal operating system that captures braindumps, organizes
content, builds frameworks, and keeps running work in check. As read in September 2026 it has:

- a skill library of more than thirty, delegating to six worker agents, with four read-only
  verifiers that observe artifacts rather than trusting a worker's own summary;
- an explicit **verification-first** stance: sources required, a seven-day freshness window,
  confidence levels on analysis, memory-hygiene sweeps that re-check stored facts against the live
  environment, and post-condition checks on mutating skills;
- support for Claude Code, Cursor, Gemini CLI, Codex, Kiro and others from the same folder;
- integrations with GitHub, Linear, Slack and PostHog, and iCloud sync to mobile devices.

It also credits Garry Tan's work — GBrain's knowledge patterns among it — as an inspiration.

### Why I did not adopt it

Not because it is wrong. COG and this vault agree on more than they disagree, and COG was one of
the strongest donors of ideas in the July survey. The reasons are about shape:

**It is a whole operating system; I wanted a memory discipline.** COG's value comes from its
breadth — capture flows, a CRM-style people layer, integrations, cross-harness support, goal
tracking. Adopting it means adopting its folder layout and its workflow as the organizing
principle. The July evaluation found that every full-system candidate, COG included, would add
top-level structure and break the fixed `tier`/`type` frontmatter schema that this vault's
dashboards and checker rely on.

**"Self-evolving" and "proposes only" are different defaults.** COG's agents organize content and
keep cross-references up to date automatically, which is what makes it pleasant to live in. This
vault chooses the opposite trade: the scheduled consolidator writes exactly one journal file of
proposals, and its runner fails the pass if any other file changed. Requirement 3 is a deliberate
cost, not an oversight.

**Different notions of freshness.** COG uses a time window. This vault separates *reviewed* from
*verified* (`last_reviewed` versus `last_verified`) because a time-based freshness check is blind
to a claim that was refuted yesterday but stamped last week — a failure my own research found in
practice. Neither approach is universally better; they answer different questions.

**Scope for a template.** I wanted something small enough that a reader can audit every hook and
agent prompt in one sitting before letting it run unattended. A larger system carries more steering
surface — skills, rules, and agent instructions that the model reads as commands — and each of
those is something you must trust.

If you want a batteries-included agentic PKM that works across many coding agents, COG is the
better starting point, and you should use it.

---

## 5. The wider landscape, and what it taught

Most of the design choices in this vault are reactions to documented failures elsewhere. The
examples below were recorded during the August 2026 research pass; each was checked against its
primary source where one was available.

**Letting an extraction pipeline write memory unsupervised compounds its own errors.** An audit
published as mem0 issue #4573 examined 10,134 production memory entries after 32 days and
classified 97.8% as junk, including 808 entries asserting "User prefers Vim" in a system where no
one used Vim. The issue names the mechanism: recalled memories are re-extracted as if they were new,
so a hallucination stored once is amplified indefinitely. This is why no LLM extraction pipeline
writes to this vault's tiers.

**A success response is not a successful write.** mem0 issue #4985 records writes failing silently
while the API returned HTTP 200 with a memory id. That, and similar cases, is why this vault's
checker prints the scanned-file count, and why its runners assert that a pass which exits 0
actually produced its artifact.

**Derived indexes do not survive schema change.** The research could not find a single memory
system that migrates an embedding or extracted-fact schema without a destructive rebuild; issue
threads across several projects record vectors lost on a model or dimension change. Markdown in git
has no such migration.

**Hosted options get withdrawn.** Zep deprecated its self-hostable Community Edition in April 2025
and moved open-source effort to Graphiti. Adopters lost self-hosting.

**Even the originators of agent memory converged on files in git.** Letta — the MemGPT lineage —
published an argument for git-backed memory repositories over bespoke memory tools: the agent gets
its full terminal, versioning with rationale comes free, and concurrent edits become a merge problem
rather than a race.

**Grep is a defensible retriever inside a coding agent.** *Is Grep All You Need?* (arXiv:2605.15184,
May 2026) compared grep with vector retrieval across several agent harnesses including Claude Code,
and found grep ahead on average as noise was added — while also finding that the harness itself
moved scores as much as the retrieval method did.

**Unregulated growth is a named failure mode.** *Is Agent Memory a Database?* (arXiv:2605.26252,
May 2026) lists unregulated growth, missing semantic revision, capacity-driven forgetting and
read-only retrieval as recurring failures, and frames correctness as "a property of the state
trajectory, not of individual records." A vault of individually true notes can still be wrong as a
whole — which is what a stale-but-accurate standard is.

Where the research found something *missing* across the field, it was this: nothing in the
comparison set separated "last re-read" from "last re-tested", recorded a deliberately withheld
freshness stamp, or kept a refuted belief as a first-class linked note. Those gaps are the part of
this repository that is original, and they are the part most worth taking even if you use
something else.

---

## 6. What this repository borrowed

Declining to adopt a project is not the same as ignoring it. These mechanisms came from the
research, reimplemented as conventions or small scripts rather than copied:

| Mechanism in this vault | Borrowed from | Shape here |
| --- | --- | --- |
| `vault-check.sh` exits non-zero on violations | GBrain's CI-enforced system-of-record check | Five frontmatter invariants, report-only, run in CI on three operating systems |
| `contradicts:` frontmatter, both notes stay active | GBrain's "surface both, never silently pick one" synthesis rule | One optional key and a dashboard query, no graph store |
| Frontmatter links read as typed edges | GBrain's frontmatter-declared links | `superseded_by`, `related_notes`, `source_notes` queried by Dataview |
| Skills, hooks and agents ship in-repo with relative paths | GBrain's self-contained skill packs | Everything the promotion loop needs lives under `.claude/` |
| Freshness stamps and confidence levels | COG, eugeniughelbur/obsidian-second-brain, breferrari/obsidian-mind | Split into `last_reviewed` and `last_verified`, with `confidence` |
| Trust sweeps and post-condition re-reads | COG's memory-hygiene sweeps and post-condition checks | Folded into the promotion agent; it re-reads what it wrote |
| Snapshot before an automated write | itechmeat/open-second-brain (principle only; mechanism unverified) | A git commit before the promotion agent writes |
| Frontmatter and link conformance | breferrari/obsidian-mind write validation, ballred/obsidian-claude-pkm link checks | The advisory lint hook plus Dataview conformance dashboards |

Deliberately *not* borrowed: hybrid vector retrieval and reranking, runtime-mutable schemas (a
second source of truth for `tier` and `type`), MCP servers, HTTP endpoints, and any agent that
rewrites existing notes on a schedule.

---

## 7. Where this repository is weaker

The August research closed with a steelman against this design. The criticisms that survived are
real, and you should weigh them before choosing this template:

- **No semantic index.** A fresh agent that does not already know a note's vocabulary cannot find
  it. That is a vocabulary problem, not a volume problem, so staying small does not fix it. GBrain
  and several others solve it; this vault does not.
- **Capture depends on someone choosing to capture.** The tier-transition skills are invoked
  deliberately, so memory that nobody saves is silently lost. Hook-driven tools such as
  [claude-mem](https://github.com/thedotmack/claude-mem) cannot forget to fire — they capture
  indiscriminately instead. The two approaches combine well.
- **Nothing prunes.** No mechanism expires a stale standard or enforces a size budget. Systems with
  hard per-block limits make every write an eviction decision; markdown has no back-pressure.
- **Contradiction history depends on discipline.** A temporal knowledge graph such as Graphiti can
  answer "what did I believe, and when did I stop?" structurally. This vault answers it only when
  someone set `superseded_by` or `contradicts`.
- **A careful loop only helps if it runs.** In my own vault the scheduled promotion pass once
  exited 0 for weeks while doing nothing, because a scheduler launched the agent without `-p` and
  the interactive session hit end-of-file immediately. That incident is why the shipped runners
  kill hung passes, fence writes, and fail any pass that produces no artifact — and why a green
  scheduled task is not, on its own, evidence that anything happened.

---

## 8. Choosing: a decision rule

| If you… | Use |
| --- | --- |
| run Claude Code on macOS or Linux, want strong retrieval and cited synthesis over a large corpus, or need multi-user access | **GBrain** |
| want a complete agentic personal operating system that works across many coding agents, with integrations and mobile sync | **COG** |
| want capture to happen automatically with no discipline required | **claude-mem**, alongside or instead of this vault |
| want a long-lived, auditable knowledge graph with temporal invalidation for an application | **Graphiti** |
| use Claude Code (especially on Windows), want no services or keys, and care most that the few notes steering your agent are verified, dated, and revertible | **this template** |

These are not mutually exclusive. The vault is plain markdown; an indexer such as GBrain can read
it, and an automatic capture tool can feed its inbox. The part this repository insists on is the
promotion gate between cheap capture and trusted memory — and that gate works the same regardless
of what sits on either side of it.

---

See also: [`concepts.md`](concepts.md) for the reasoning behind each tier boundary, and the
[README](../README.md) for setup.
