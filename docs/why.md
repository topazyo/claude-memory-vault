# Why build this instead of adopting an existing memory system

"Agent memory" is a crowded space: hosted memory engines, knowledge-graph libraries, memory built
into coding agents, and dozens of Obsidian "second brain" frameworks for Claude Code. Before writing
this template I researched that landscape with the goal of *not* building anything — find the best
existing implementation, adopt it, move on.

This document records why that did not happen, what I took from those projects anyway, and — just
as important — when you should use one of them instead of this repository.

Every claim about another project carries the month it was read. These projects move fast; if a
date is more than a few months old, re-check the claim before relying on it.

---

## Contents

1. [What I needed](#1-what-i-needed)
2. [How the landscape was researched](#2-how-the-landscape-was-researched)
3. [The landscape, by category](#3-the-landscape-by-category)
   - [Memory engines and services](#31-memory-engines-and-services)
   - [Markdown-native memory and second-brain frameworks](#32-markdown-native-memory-and-second-brain-frameworks)
   - [Memory built into agents and IDEs](#33-memory-built-into-agents-and-ides)
   - [Retrieval layers over a vault](#34-retrieval-layers-over-a-vault)
4. [What the landscape taught](#4-what-the-landscape-taught)
5. [What this repository borrowed](#5-what-this-repository-borrowed)
6. [Where this repository is weaker](#6-where-this-repository-is-weaker)
7. [Choosing: a decision rule](#7-choosing-a-decision-rule)

---

## 1. What I needed

The requirements came from how I actually work, not from a feature wishlist. They are listed in
roughly the order in which they eliminated candidates.

1. **No services, no keys, no second store.** Markdown in git is the only source of truth. No
   database that can drift from the files, no embedding model whose version change forces a
   destructive rebuild, no API key required for the system to function at all.
2. **Automation that proposes rather than rewrites.** An unattended agent may *suggest* changes to
   what I know. It may not extract, merge, reorganize or overwrite my notes on its own. Where an
   agent does write, the write must be fenced to known folders and revertible with one git command.
3. **Provenance that survives being wrong.** A refuted belief is marked superseded and kept, linked
   to what replaced it. Two notes that disagree both stay visible until a human decides. Freshness
   stamps distinguish "I re-read this" from "I re-tested this".
4. **A small, earned long tier.** The notes that steer future sessions should be few, verified and
   dated. Capture can be cheap and noisy; promotion must be deliberate.
5. **Native Windows.** My Claude Code runtime is Windows. WSL2 is installed for Linux tooling, but
   anything that needs a Unix daemon, a Unix socket or a Linux-only build is a second machine to
   operate, not a tool.
6. **Checks that prove they ran.** A checker that reports "0 violations" must also report how much
   it scanned, and its tests must include known-bad inputs that are *supposed* to fail.
7. **Something another person can clone and audit.** A template small enough to read every hook and
   agent prompt before letting it run unattended, with no personal paths baked in.

None of these is exotic. What turned out to be rare is having all of them at once.

---

## 2. How the landscape was researched

Two passes, about a month apart.

**July 2026 — framework fit survey.** A research workflow took nine open-source Claude Code and
Obsidian "second brain" repositories to full analysis and logged ten more as lower relevance. Every
per-repository finding went through an independent verification pass before it could influence a
score. That pass earned its keep: one research agent had invented an alarming security finding about
a candidate — an automatic external publishing pipeline — that did not exist anywhere in the
repository, and another candidate's headline mechanism could not be confirmed from source, so only
its principle was carried forward.

**August 2026 — landscape and deep dives.** A broader pass gathered 77 candidate rows across
three angles — memory engines, published postmortems and issue threads, and design doctrine — and
compared the relevant ones on eleven axes: storage substrate, retrieval, write authority, context
cost, consolidation and forgetting, trust and freshness, multi-project scale, failure modes,
security, onboarding, and measurement. It closed with a steelman, the strongest case *against* this
design, summarized in [section 6](#6-where-this-repository-is-weaker). GBrain was then analysed from
a disposable clone at a pinned version.

**A note on sourcing.** Part of the August discovery phase ran without direct page access, so some
characterizations rest on search summaries rather than on the projects' own pages. A later
re-verification round read the most important sources directly and corrected several claims —
including two licences and a number that a summary had got wrong. In the tables below, entries
marked † were characterized from secondary sources and were not re-read first-hand. Star counts are
omitted throughout: the research found them unreliable in this category.

The conclusion of both passes was the same. No candidate could be adopted without giving up at
least one requirement above — but many had ideas worth taking, and several of them are credited in
[section 5](#5-what-this-repository-borrowed).

---

## 3. The landscape, by category

### 3.1 Memory engines and services

Libraries and services that extract memories from conversations, store them in a vector, graph or
relational store, and retrieve them for the model.

| Project | Distinctive idea | Why it was not adopted here |
| --- | --- | --- |
| **mem0** | Hybrid vector/graph/key-value store; ADD, UPDATE, DELETE and NOOP as extraction outcomes; expiry dates on writes | An LLM extraction pipeline writes memory with no human in the loop, which is the failure its own issue tracker documents best (see [section 4](#4-what-the-landscape-taught)) |
| **Graphiti / Zep** | Bi-temporal knowledge graph: superseded facts are *invalidated, not deleted*, so the graph knows what it used to believe and when it stopped | The most principled answer to contradiction — but a graph database plus multiple LLM and embedding calls per episode. Zep's self-hostable Community Edition was deprecated in April 2025 |
| **Letta (MemGPT)** | Memory blocks with hard character limits, so every write is an eviction decision; sleep-time consolidation outside the working session; git-backed Context Repositories | A full agent runtime with Postgres and pgvector. Its own argument for git-backed markdown is one of the strongest endorsements of this vault's substrate |
| **Supermemory** | Temporary facts expire after their date passes; contradictions are resolved automatically | Resolution *executes* rather than being proposed — the opposite default from requirement 2 |
| **cognee** † | Relational, vector and graph stores with an extract-cognify-load pipeline and a refinement pass | Three stores to operate, all written by LLM extraction |
| **Memobase** † | User profiles filled by an LLM from a size-or-idle buffer | Postgres and Redis; profile slots overwrite rather than supersede |
| **LangMem** † | Procedural memory: the agent rewrites its own prompt | Self-modifying instructions are the steering surface this vault is most careful about |
| **A-MEM** † | "Memory evolution": a new memory can rewrite the descriptions of older ones | Silent revision of existing notes destroys provenance |
| **MemoryOS** † | Three-tier hierarchical store with a visit-frequency "heat" score driving promotion | The closest idea to this vault's tiers — but promotion by popularity, not by verification |
| **memoripy** † | Explicit decay and reinforcement of memories | Local JSON plus embeddings; forgetting by access pattern rather than by evidence |

**Why the whole category was out.** These systems are built for applications that remember *users*
across conversations, at scale, automatically. They need at least one service and usually an
embedding model, and in almost all of them an LLM decides what gets written. That is a reasonable
design for a consumer assistant. It is the wrong one for a small body of engineering knowledge whose
value depends on each entry being checkable and each change being attributable.

### 3.2 Markdown-native memory and second-brain frameworks

Projects that agree with this vault's core thesis — plain files are the source of truth — and build
a system on top of it. This is where the real competition is, and where most of the borrowed ideas
came from.

| Project | Distinctive idea | Why it was not adopted here |
| --- | --- | --- |
| **[GBrain](https://github.com/garrytan/gbrain)** | The markdown repo is the system of record and the database a rebuildable cache — enforced by a CI check. Hybrid keyword, vector and graph retrieval with reranking; cited synthesis that lists what it *doesn't* know; a large MCP tool surface and multi-user mode | As read in August 2026: Bun runtime with macOS and Linux builds only, Ubuntu-only CI, no Task Scheduler path, and a Unix-socket lock. It also needs a database and a daemon, and its background cycle includes LLM phases that write into your notes |
| **[COG](https://github.com/huytieu/COG-second-brain)** | Cognition + Obsidian + Git: a self-evolving agentic operating system with worker agents, read-only verifiers, a verification-first stance (sources, freshness window, confidence), integrations and support for many coding agents | A whole operating system rather than a memory discipline: adopting it means adopting its layout and workflow. Its agents organize content for you, and its freshness is a time window rather than a re-tested/re-read split |
| **eugeniughelbur/obsidian-second-brain** | Closest by architecture. A lesson state machine (active, stale, superseded, promotion candidate) promoting lessons seen three or more times; a vault health audit; an index staleness budget; semantic search optional, local and off by default | An AI-first vault whose agents rewrite notes, with a recall hook that overlapped tooling I already run. Its lesson lifecycle is the nearest thing to this vault's goal, already shipped |
| **Basic Memory** + **basic-memory-skills** | Markdown files with a SQLite index, edited by human and model alike; skills for between-session reflection, lifecycle and "defrag" | The defrag pass rewrites the corpus for clarity, which trades provenance for tidiness. AGPL-3.0. Its skills repo states a principle this vault shares: memory forms better between sessions than during them |
| **breferrari/obsidian-mind** | Deterministic TypeScript hooks own the vault structure and validate writes; hybrid retrieval | Adds a TypeScript toolchain and its own structure; the write-validation idea was reimplemented here as a bash lint hook |
| **heyitsnoah/claudesidian** | Clone-as-vault PARA layout with a "thinking mode"; grep-only retrieval | Clone-as-vault means its layout *is* your vault. Its grep-first stance matches this one |
| **ballred/obsidian-claude-pkm** | A goal-cascade accountability system with sandboxed writes and link checking | A productivity system first and a memory system second |
| **AgriciDaniel/claude-obsidian** | A three-layer "compound vault" on Karpathy's LLM-wiki pattern, with a rolling hot cache and local BM25 | The hot cache duplicates session capture I already have, which would create a second source of truth. The LLM-wiki layer here follows the same pattern more narrowly |
| **itechmeat/open-second-brain** | Local-first deterministic memory with a "dream" consolidation kernel and snapshot rollback, exposed over MCP | Adds an MCP server; the snapshot mechanism could not be verified from source, so only the principle was taken |
| **lucasrosati/claude-code-memory-setup** | A documented recipe: Zettelkasten notes plus an AST-derived code graph | A recipe rather than a system, and the code-graph step depends on an unaudited third-party package |
| **coleam00/second-brain-skills** | A skill pack for content production | Not a knowledge vault, and published without a licence, so nothing could be reused |

**Why no framework was adopted.** Every framework in the July survey would have added its own
top-level structure and broken the fixed `tier`/`type` frontmatter schema that this vault's
dashboards and checker depend on — and every core capability they offer (an LLM wiki, persistent
memory, scheduled consolidation, tiering) already existed in the vault being evaluated. The more
telling result was a convergence: **five independent frameworks were each reaching for the same
missing discipline — freshness, verification and write safety.** That gap, not another engine, is
what this repository is built around.

### 3.3 Memory built into agents and IDEs

| Project | Approach | Why it was not adopted here |
| --- | --- | --- |
| **claude-mem** | Hooks capture every session automatically into SQLite with full-text and vector search, injected at session start | It cannot forget to capture — and captures indiscriminately. It complements this vault rather than replacing it; the two run side by side well |
| **Cline Memory Bank** | Markdown files in the repository, which the agent is instructed to read in full at the start of every task | Full load on every task is the context cost this vault's tiers exist to avoid |
| **Cursor Memories** † | An automatic, opaque store inside the IDE | Users reported moving back to plain rules files because memories could not be removed or updated, by them or by the model |
| **Official MCP memory server** † | A single JSON knowledge graph written through tool calls | Substring search, no ranking, no decay, no contradiction handling; issue reports of corruption under concurrent writes |
| **mcp-knowledge-graph** † | A JSONL knowledge graph per project | Keyword lookup and accretion only |

**Why this category was out.** Built-in memory optimizes for zero effort, which is the right goal
for capture and the wrong one for trust. An opaque or append-only store gives you no way to see why
the agent believes something, no way to correct it in place, and no record that it was ever wrong.

### 3.4 Retrieval layers over a vault

| Project | Approach | Relationship to this vault |
| --- | --- | --- |
| **Smart Connections** † | On-device, block-level embeddings inside Obsidian | A read-side tool; compatible with this vault, not an alternative to it |
| **Khoj** † | Postgres and pgvector with cross-encoder reranking | A read-side tool with a server to operate |

These solve a problem this vault genuinely has — semantic search — without touching the write path.
They are complements, not competitors. None was adopted because, at the size of a personal
engineering vault, the binding problem is whether a note is still true, not whether it can be found.

---

## 4. What the landscape taught

Most of this vault's design choices are reactions to documented failures elsewhere. Each example
below was checked against its primary source during the August 2026 research.

**Unsupervised extraction compounds its own errors.** An audit published as mem0 issue #4573
examined 10,134 production memory entries after 32 days and classified 97.8% as junk — including 808
entries asserting "User prefers Vim", 191 of them exact copies, in a system where no one used Vim.
The issue names the mechanism: recalled memories are re-extracted as if they were new, so a
hallucination stored once is amplified indefinitely. This is why no extraction pipeline writes to
this vault's tiers.

**A success response is not a successful write.** mem0 issue #4985 records an embedding-provider
switch leaving the vector column at its old dimension, so writes silently failed while the API
returned HTTP 200 with a memory id. That is why this vault's checker prints how many files it
scanned, and why its scheduled runners fail any pass that exits 0 without producing its artifact.

**Contradictions need a first-class representation.** mem0 issue #5867 records an add-only
extractor storing "favorite player is Ronaldo" and "now Messi" as coexisting memories. Graphiti's
bi-temporal invalidation is the principled answer; this vault's `superseded_by` and `contradicts`
keys are the plain-text one.

**Derived indexes do not survive schema change.** The research could not find a single memory
system that migrates an embedding or extracted-fact schema without a destructive rebuild. Markdown
in git has no such migration.

**Hosted options get withdrawn.** Zep's self-hostable Community Edition was deprecated in April
2025, with open-source effort moving to Graphiti. Adopters lost self-hosting.

**The originators of agent memory converged on files in git.** Letta published an argument for
git-backed memory repositories over its own MemGPT-style memory tools: the agent gets its full
terminal, versioning with rationale comes free, and concurrent edits become a merge problem rather
than a race.

**Grep is a defensible retriever inside a coding agent.** *Is Grep All You Need?* (arXiv:2605.15184,
May 2026) compared grep with vector retrieval across several agent harnesses including Claude Code,
and found grep ahead on average as noise was added — while also finding that the harness moved
scores as much as the retrieval method did.

**Unregulated growth is a named failure mode.** *Is Agent Memory a Database?* (arXiv:2605.26252,
May 2026) lists unregulated growth, missing semantic revision, capacity-driven forgetting and
read-only retrieval as recurring failures, and frames correctness as "a property of the state
trajectory, not of individual records." A vault of individually true notes can still be wrong as a
whole — which is exactly what a stale-but-accurate standard is.

**The category rarely writes its lessons down.** The research found no first-party postmortem or
lessons-learned document in mem0, Letta, Graphiti, cognee or claude-mem; the lessons live in issue
threads. (GBrain, which publishes incident write-ups, is a welcome exception.)

**What was missing everywhere.** Nothing in the comparison set separated "last re-read" from "last
re-tested", recorded a deliberately withheld freshness stamp, or kept a refuted belief as a
first-class linked note. Those gaps are the original part of this repository, and the part most
worth taking even if you use something else.

---

## 5. What this repository borrowed

Declining to adopt a project is not the same as ignoring it. These mechanisms came out of the
research, reimplemented as conventions or small scripts rather than copied:

| Mechanism in this vault | Idea came from | Shape here |
| --- | --- | --- |
| Freshness stamps and confidence levels | COG, eugeniughelbur/obsidian-second-brain, breferrari/obsidian-mind | Split into `last_reviewed` and `last_verified`, plus `confidence` |
| Superseded as a state, not a deletion | eugeniughelbur's lesson states; Graphiti's invalidate-not-delete | `status: superseded` with `superseded_by`, and `99-archive/` instead of delete |
| Frontmatter and link conformance | breferrari/obsidian-mind write validation; ballred/obsidian-claude-pkm link checks | An advisory lint hook plus Dataview conformance dashboards |
| Trust sweeps and post-condition re-reads | COG's memory-hygiene sweeps and post-condition checks | Folded into the promotion agent, which re-reads what it wrote |
| Snapshot before an automated write | itechmeat/open-second-brain (principle only) | A git commit before the promotion agent writes |
| Consolidation between sessions, not during them | Letta's sleep-time compute; basic-memory-skills | A scheduled dream pass, separate from the working session |
| A checker that fails the build | GBrain's CI-enforced system-of-record check | `vault-check.sh`, run in CI on three operating systems |
| Conflicts surfaced, never silently resolved | GBrain's synthesis rule; the mem0 contradiction issue as the counter-example | `contradicts:` frontmatter — both notes stay active |
| Frontmatter links as typed edges | GBrain's frontmatter-declared links | `superseded_by`, `related_notes` and `source_notes`, queried by Dataview |
| Everything the loop needs ships in the repo | GBrain's self-contained skill packs | Skills, hooks, agents and runners under `.claude/`, with relative paths |

Deliberately *not* borrowed: vector retrieval and reranking, LLM extraction into the tiers,
automatic contradiction resolution, corpus-rewriting "defrag" passes, runtime-mutable schemas, MCP
servers and HTTP endpoints, and any agent that rewrites existing notes on a schedule.

---

## 6. Where this repository is weaker

The August research closed with a steelman against this design. The criticisms that survived are
real, and you should weigh them before choosing this template:

- **No semantic index.** A fresh agent that does not already know a note's vocabulary cannot find
  it. That is a vocabulary problem rather than a volume problem, so staying small does not fix it.
  GBrain, Basic Memory, obsidian-second-brain's optional layer and the retrieval tools in section
  3.4 all address it; this vault does not.
- **Capture depends on someone choosing to capture.** The tier-transition skills are invoked
  deliberately, so memory nobody saves is silently lost. Hook-driven tools such as claude-mem cannot
  forget to fire.
- **Nothing prunes.** No mechanism expires a stale standard or enforces a size budget. Letta's
  per-block limits make every write an eviction decision; markdown has no back-pressure at all.
- **Contradiction history depends on discipline.** Graphiti can answer "what did I believe, and when
  did I stop?" structurally. This vault answers it only when someone set `superseded_by` or
  `contradicts`.
- **Consolidation is careful rather than automatic.** Supermemory and mem0 resolve and forget on
  their own, with the risks section 4 describes. This vault's consolidation only proposes, so it only helps if the
  scheduled passes run and someone acts on their proposals.
- **No shared, multi-user mode.** One git repository is shared across projects and agents, not
  across people with separate permissions.

---

## 7. Choosing: a decision rule

| If you… | Consider |
| --- | --- |
| are building an application that must remember its *users* across conversations, at scale | **mem0**, **Letta**, **Supermemory** |
| need an auditable knowledge graph with temporal invalidation | **Graphiti** |
| run Claude Code on macOS or Linux and want strong retrieval, cited synthesis or multi-user access over a large corpus | **GBrain** |
| want a complete agentic personal operating system across many coding agents, with integrations | **COG** |
| want a markdown memory whose agents actively maintain lessons and search for you | **eugeniughelbur/obsidian-second-brain** or **Basic Memory** |
| want capture to happen automatically with no discipline required | **claude-mem**, alongside or instead of this vault |
| want semantic search over notes you already have | **Smart Connections** or **Khoj** |
| use Claude Code (including natively on Windows), want no services or keys, and care most that the few notes steering your agent are verified, dated and revertible | **this template** |

For GBrain specifically, the research reached a concrete threshold: it becomes the better choice
when your Claude Code runtime is Linux, macOS or WSL2, your curated content passes roughly five
hundred notes, *and* more than one person needs write access to the same memory.

These choices are not mutually exclusive. The vault is plain markdown: an indexer can read it, an
automatic capture tool can feed its inbox, and a retrieval plugin can search it. The part this
repository insists on is the promotion gate between cheap capture and trusted memory — and that gate
works the same regardless of what sits on either side of it.

---

See also: [`concepts.md`](concepts.md) for the reasoning behind each tier boundary, and the
[README](../README.md) for setup.
