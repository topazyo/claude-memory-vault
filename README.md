# claude-memory-vault

**Coding agents forget everything between sessions.** The usual fix is to keep appending to
`CLAUDE.md` or `AGENTS.md` until it becomes a two-thousand-line wall of text that nobody reviews,
nothing validates, and the model reads in full on every turn. This repository is the structured
alternative: an [Obsidian](https://obsidian.md) markdown vault where project memory has **tiers**,
an explicit **promotion path** between them, and a **conformance contract** that a script can
check. Cheap observations land in a daily note. Anything that survives a session gets written to
a project log. Only what has been verified and re-used gets promoted into a long-term standard —
and only long-term standards are expected to steer future sessions. Everything is plain Markdown
with YAML frontmatter, so it is greppable, diffable, reviewable in a pull request, and readable by
a human ten months from now.

This is a **template**. It ships zero personal notes — only the structure, the automation, the
conformance checker, and five fictional `EXAMPLE-` notes that tell one small story across the
tiers. You clone it, open it in Obsidian, point your coding agent at it, and start accumulating
your own knowledge.

**It works with any harness.** The contract, the checker, the rules and the skills are plain
Markdown and bash, and `AGENTS.md` is the entry point every agent reads. Claude Code gets the
most automation, because the template ships hooks, subagents and a Read deny for it in `.claude/`.
The template also ships working config for Codex CLI, Gemini CLI, Cursor, GitHub Copilot, OpenCode,
Windsurf / Devin Desktop and Aider, plus a setup snippet for Hermes Agent. Each gets hooks or a
plugin for the lint where the harness supports one, and every harness gets an opt-in git
pre-commit gate. [`docs/harnesses/`](docs/harnesses/README.md) has a guide for each, with a prompt
that has the agent onboard the vault and prove the wiring works, and the
[harness support table](AGENTS.md#8-harness-support) lists exactly what each harness enforces. The
repository name and the `.claude/` folder are historical: Claude Code requires that location, and
nothing in the folder except `settings.json` and one audit hook is Claude-only.

**Start here:** follow the [Quickstart](#quickstart) — clone, open in Obsidian, install Dataview,
then run the two verification commands. [`docs/setup.md`](docs/setup.md) has the long version,
and coding agents should read [`AGENTS.md`](AGENTS.md) first.

**Contents:** [Why build this](#why-build-this-instead-of-using-an-existing-memory-system) ·
[What you get](#what-you-get) · [Layout](#repository-layout) ·
[How memory moves](#how-memory-moves) · [Quickstart](#quickstart) ·
[Frontmatter contract](#the-frontmatter-contract) · [Design principles](#design-principles) ·
[Requirements](#requirements--platform-notes) · [Customizing](#customizing) ·
[Documentation](#documentation)

---

## Why build this instead of using an existing memory system?

I didn't set out to build a memory system. I set out to *adopt* one.

There are plenty to choose from, including Garry Tan's [GBrain](https://github.com/garrytan/gbrain),
[COG](https://github.com/huytieu/COG-second-brain), mem0, Letta, Graphiti, Basic Memory, claude-mem,
and dozens of Obsidian "second brain" frameworks for Claude Code. So before writing any of this I ran
two research passes in July and August 2026:

- **A framework survey.** Nine Claude Code and Obsidian repositories analysed in depth, with ten
  more logged as lower relevance. An independent verification pass checked every finding before it
  counted, and it caught one research agent inventing a security flaw that did not exist.
- **A landscape study.** 77 candidates across memory engines, published postmortems and design
  doctrine, compared on eleven axes, with a deep dive into GBrain from a pinned clone.

No candidate could be adopted without giving up something I needed. Almost every one had an idea
worth taking.

**What I needed, all at once:**

- plain markdown in git as the only store, with no services or API keys
- automation that proposes changes instead of rewriting notes, with any unattended write fenced and
  revertible
- refuted beliefs kept as linked, superseded notes rather than deleted
- a small long-term tier that has to be earned
- native Windows support
- checkers that prove they scanned something

**Why each kind of tool fell short:**

| Kind of tool | Examples | Why it didn't fit |
| --- | --- | --- |
| Memory engines and services | mem0, Letta, Graphiti/Zep, Supermemory, cognee, LangMem, A-MEM, MemoryOS | Built to remember *users* at scale. They need a database or vector store, and usually let an LLM extract and rewrite memory unsupervised. mem0's own issue tracker records a production audit that found 97.8% of stored memories were junk |
| Markdown and Obsidian frameworks | GBrain, COG, eugeniughelbur/obsidian-second-brain, Basic Memory, obsidian-mind, claudesidian, claude-obsidian | The closest competition, and the source of most borrowed ideas. Each brings its own layout and workflow, and many let agents reorganize or rewrite notes. GBrain adds a database and a daemon and, as read in August 2026, did not run natively on Windows. COG is a complete agentic operating system rather than a memory discipline |
| Memory built into agents and IDEs | claude-mem, Cline Memory Bank, Cursor Memories, the official MCP memory server | Optimized for zero effort. Capture is automatic, but the store is either loaded in full every time or append-only and hard to correct. claude-mem complements this vault well |
| Retrieval layers | Smart Connections, Khoj | They help you find notes but don't govern what gets written. Useful complements, not alternatives |

The most telling result was a convergence: **five independent frameworks were each reaching for the
same missing discipline, namely freshness, verification and write safety.** None of the tools in the
comparison separated *re-read* from *re-tested*, recorded a deliberately withheld freshness stamp, or
kept a refuted belief as a first-class linked note. That discipline is what this repository is built
around.

This vault is also weaker in some places:

- It has no semantic search.
- Nothing prunes the store.
- Capture only happens when someone chooses to save.

If those matter more to you than trust and auditability, one of the tools above is the better choice.
They aren't mutually exclusive either: this vault is plain markdown, so an indexer, a capture tool or
a retrieval plugin can sit on top of it.

**The full reasoning** is in [`docs/why.md`](docs/why.md). It has a per-project table for each
category, the documented failures that shaped the design, what this repo borrowed and from whom, a
list of weaknesses, and a decision rule for picking the right tool.

---

## What you get

- **Three memory tiers** with distinct lifetimes: `short` (daily notes, inbox captures),
  `medium` (per-project session logs), `long` (standards and concept entities).
- **Five skills**: three that move knowledge between tiers — `/obsidian-save`, `/resume`,
  `/preserve` — plus `/wrap-up`, which drafts an end-of-session summary without writing it, and
  `/onboard-project`, which wires a new codebase into the vault.
- **Two scheduled agents**: a *dream agent* that consolidates and proposes, and a *promotion
  agent* that does the weekly medium → long pass, each with a shipped `.sh`/`.cmd` runner that
  kills a hung pass, fails a pass that writes outside its allowed folders, and fails loudly when a
  pass produces no artifact.
- **A retention runner**: moves dream journals and compaction stubs that git proves a machine
  wrote, and nobody has touched since, out of the medium tier and into `99-archive/`, as one
  `git mv` and one revertible commit per run. It writes no content of its own, and `--dry-run`
  shows you its judgement before it moves anything.
- **Three hooks**: an advisory frontmatter + invisible-character lint, a post-compaction stub
  writer so a compacted session leaves a trace, and an audit log of which instruction files loaded
  at session start. Claude Code runs all three after the matching event. The lint also takes file
  paths as arguments, so any harness, editor or script can call it.
- **A conformance checker** (`vault-check.sh`) that checks five frontmatter invariants and exits
  non-zero on violation, or when it scanned nothing. CI (`.github/workflows/ci.yml`) runs it on
  Linux, macOS and Windows, plus a job using macOS's system bash 3.2. An **opt-in git pre-commit
  gate** (`.claude/githooks/pre-commit`) runs it before every commit, whatever harness wrote the
  note. Alongside it, a **control test suite** (`run-tests.sh`) feeds the hooks and runners
  known-bad inputs that must be flagged and known-good inputs that must stay silent, so a passing
  run is evidence the checks ran.
- **Four rules files**: three path-scoped (the frontmatter contract when an agent edits a note, the
  verification discipline, and a prompt-injection boundary for captured content) plus one global
  safety file that always loads.
- **Dataview dashboards** and a tier-coloured graph view configuration.

---

## Repository layout

```
claude-memory-vault/
├── AGENTS.md                        # instructions for every harness: tiers, contract, rules, commands
├── CLAUDE.md                        # Claude Code bridge: imports AGENTS.md, lists the Claude adapter
├── CONTRIBUTING.md
├── .agents/skills/                  # byte-identical copies of the five skills, for harnesses that read only here
├── .codex/                          # Codex CLI: config.toml (hooks on) and hooks.json
├── .gemini/settings.json            # Gemini CLI: loads AGENTS.md, lint and compaction hooks
├── .geminiignore                    # Gemini CLI: keeps .env and secrets/ out of search
├── .cursor/hooks.json               # Cursor: lint and compaction hooks
├── .cursorignore                    # Cursor: blocks agent access to .env and secrets/
├── opencode.json                    # OpenCode: loads .claude/rules/*.md
├── .windsurf/hooks.json             # Windsurf / Devin Desktop: lint and secrets read guard
├── .aider.conf.yml                  # Aider: loads AGENTS.md and the rules; keeps git hooks running
├── .github/
│   ├── hooks/vault.json             # GitHub Copilot: lint hook
│   ├── workflows/ci.yml             # checks on Linux, macOS, Windows, bash 3.2, plus repo hygiene
│   └── ISSUE_TEMPLATE/bug_report.yml
├── .claude/                         # shared tooling; only settings.json and one hook are Claude-only
│   ├── settings.json                # Claude Code: registers the three hooks; denies reads of .env and secrets/
│   ├── githooks/pre-commit          # opt-in commit gate for any harness: runs vault-check.sh
│   ├── adapters/opencode/vault.js   # OpenCode plugin, opt-in: copy to .opencode/plugins/ to enable
│   ├── agents/
│   │   ├── dream-agent.md           # scheduled consolidation; READ-AND-PROPOSE ONLY, one output file
│   │   └── promotion-agent.md       # weekly medium → long promotion, no shell, the runner commits its notes
│   ├── hooks/
│   │   ├── vault-lint.sh            # advisory lint; hook JSON on stdin or file paths as arguments; exits 0
│   │   ├── postcompact-wrap-up.sh   # one idempotent, size-capped compaction stub per session
│   │   ├── read-guard.sh            # pre-read hook: blocks .env, .env.*, secrets/ (Windsurf)
│   │   └── instructions-loaded-log.sh # Claude Code only: audit log of instruction files loaded at start
│   ├── rules/
│   │   ├── vault-notes.md           # frontmatter contract, wikilinks, Dataview, filing (path-scoped)
│   │   ├── verification.md          # freshness, citation, earned-stamp discipline (path-scoped)
│   │   ├── untrusted-captures.md    # prompt-injection boundary for captures (path-scoped)
│   │   └── security.md              # global safety rules; no paths:, always loads
│   ├── scripts/
│   │   ├── vault-check.sh           # report-only invariant checker (C1–C5); 1 = a note is wrong, 2 = it could not run
│   │   ├── run-tests.sh             # control suite for the hooks; positive AND negative controls
│   │   ├── dream-pass.sh / .cmd     # scheduled runner (cron/launchd; .cmd wraps it for Task Scheduler)
│   │   ├── promotion-pass.sh / .cmd # ditto, for the weekly promotion pass
│   │   ├── vault-retention.sh / .cmd # moves aged machine-written logs to 99-archive/, no agent
│   │   └── lib/runner-common.sh     # watchdog, write fence and harness selection shared by the runners
│   └── skills/
│       ├── obsidian-save/SKILL.md   # session → medium-term log
│       ├── wrap-up/SKILL.md         # structured end-of-session summary
│       ├── resume/SKILL.md          # rehydrate from recent logs at session start
│       ├── preserve/SKILL.md        # medium → long promotion
│       └── onboard-project/SKILL.md # wire a codebase into the vault
├── .obsidian/                       # enabled-plugin list and the tier-coloured graph config
├── 01-inbox/                        # raw captures — treated as untrusted content
├── 10-daily/
│   ├── EXAMPLE-2026-01-15.md
│   └── templates/short-term-daily.md
├── 20-projects/_logs/
│   ├── EXAMPLE-example-api-2026-01-15.md
│   └── templates/medium-term-project-log.md
├── 30-knowledge/moc/                # ARCH-INDEX.md, VAULT-INDEX.md, PROJECT-INDEX.md
├── 31-standards/
│   ├── EXAMPLE-retries-must-carry-an-idempotency-key.md
│   ├── EXAMPLE-retry-on-any-5xx.md  # status: superseded — demonstrates mark-never-delete
│   └── templates/long-term-standard.md
├── 40-llm-wiki/
│   ├── raw/                         # ingested source material — also untrusted
│   └── wiki/
│       ├── EXAMPLE-idempotency-key.md
│       └── templates/llm-wiki-entity.md
├── 90-auto-memory/                  # a harness's own auto-memory (e.g. Claude Code's), machine-managed
├── 99-archive/                      # retired notes; prefer archiving over deleting. The retention runner writes here too
└── docs/                            # setup, concepts, reference, customizing, agent-onboarding
    └── harnesses/                   # one guide per harness, each with an onboarding prompt
```

The five `EXAMPLE-` notes live in their real tier folders on purpose, so the dashboards and the
graph colours have something to render on first open. They are one fictional story: an
`example-api` service double-charging customers because its retries carried no idempotency key.
When you have seen enough of it, `find . -name 'EXAMPLE-*.md' -delete`.

---

## How memory moves

Promotion is **deliberate, not automatic**. Nothing is copied upward because a heuristic thought
it looked important; something moves up because you (or a run you reviewed) decided it earned the
move. The friction is intentional, because the long tier only steers future sessions well if it
stays small.

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │  SHORT   10-daily/   01-inbox/                                       │
  │  cheap · disposable · high volume · no verification expected         │
  └───────────────┬──────────────────────────────────────────────────────┘
                  │  /obsidian-save        (end of a working session)
                  │  /wrap-up              (structured summary of the session)
                  ▼
  ┌──────────────────────────────────────────────────────────────────────┐
  │  MEDIUM  20-projects/_logs/                                          │
  │  one log per project session · each ends with a                      │
  │  "Promotion candidates (for long-term)" section ──┐                  │
  └───────────────┬───────────────────────────────────┼──────────────────┘
                  │  /preserve  (human-driven)        │ dream-agent reads these
                  │  promotion-agent (weekly)         │ and PROPOSES, never writes
                  ▼                                   │ into an existing note
  ┌──────────────────────────────────────────────────────────────────────┐
  │  LONG    31-standards/   40-llm-wiki/wiki/                           │
  │  small · verified · cited · dated · this is what actually steers     │
  │  future sessions                                                     │
  └──────────────────────────────────────────────────────────────────────┘

  /resume  reads recent medium-tier logs at session start and rehydrates context.
```

| Hop | Driven by | What it does |
| --- | --- | --- |
| session → short | you, during the day | Daily note in `10-daily/`, raw drops in `01-inbox/` |
| session → medium | `/obsidian-save` | Writes the dated project log, with a promotion-candidates section |
| session summary | `/wrap-up` | Produces the structured end-of-session summary a log — or a human — then consumes. It does not write the log itself |
| medium → long | `/preserve` | You nominate one candidate; it becomes a standard or a wiki entity |
| medium → long | `promotion-agent` (weekly) | Same hop, unattended. The runner checks its notes and commits them, or puts them back |
| consolidation | `dream-agent` (scheduled) | Reads broadly, writes exactly **one** dated journal file of proposals |
| compaction → medium | `postcompact-wrap-up.sh` hook | Drops a stub log so a compacted session's material is recoverable |
| medium → session | `/resume` | Reads the recent logs back into a fresh session |
| medium → archive | `vault-retention.sh` (scheduled) | The only hop that takes something *out* of a tier. Moves aged journals and stubs git proves a machine wrote into `99-archive/`, one commit per run |

---

## Quickstart

**Prerequisites:** `bash` (Git Bash on Windows), `git`, Obsidian, a coding-agent harness (Claude
Code gets the most automation), and (strongly recommended) `jq`. See [Requirements](#requirements--platform-notes) before you start; `jq` is
*not* bundled with Git for Windows.

1. **Clone the template.** Click **Use this template** (or fork) on GitHub first, then:

   ```bash
   git clone https://github.com/<you>/claude-memory-vault.git <your-vault>
   cd <your-vault>
   ```

   If you are starting your own history, `rm -rf .git && git init`, then commit immediately
   (`git add -A && git commit -m "initial vault"`). The runners commit each pass's notes on top of
   your history, and a promotion pass whose notes fail the check is put back to the last commit
   before it. The vault is meant to be a repository you commit to, so that "what did we believe
   last quarter" is answerable from `git log`.

2. **Open the folder as an Obsidian vault.** *Open folder as vault* → pick `<your-vault>`.
   Obsidian will pick up the bundled `.obsidian/` configuration, including the tier-coloured
   graph.

3. **Install the Dataview plugin — this is required.** Obsidian opens an unfamiliar vault in
   **Restricted Mode**, where community plugins are disabled and there is no *Browse* button at
   all, so start there: Settings → Community plugins → *Turn off Restricted Mode* → Browse →
   *Dataview* → Install → Enable. Every dashboard in `30-knowledge/moc/` is a Dataview query and
   will render as an unstyled code block until you do this. The bundled
   `.obsidian/community-plugins.json` is only the list of plugin ids to *enable*. Obsidian does
   not download anything from it, so a plugin you have not installed stays absent, with no
   error. The graph plugins listed there are **optional**; the vault works fine without them.

4. **Point your harness at the vault.** Start a session with `<your-vault>` as the working
   directory.
   - **Claude Code:** `CLAUDE.md` loads automatically and imports `AGENTS.md`, and
     `.claude/settings.json` registers the three hooks. `.claude/rules/security.md` loads every
     session; the other three rules files are path-scoped and load only when you touch matching
     paths.
   - **Any other harness:** open its guide in [`docs/harnesses/`](docs/harnesses/README.md). It
     lists the one-time setup (usually trusting the project), and a prompt you paste so the agent
     onboards the vault and proves the hooks fire. Whatever the harness, enable the commit gate,
     the one mechanical check that works without harness hooks:

     ```bash
     git config core.hooksPath .claude/githooks
     ```

     That setting replaces `.git/hooks`, so copy any hook you already rely on (git-lfs installs
     several) into `.claude/githooks/` first.

5. **Verify the automation runs.** Two commands, both from the vault root:

   ```bash
   bash .claude/scripts/run-tests.sh     # control suite for the hooks
   bash .claude/scripts/vault-check.sh   # frontmatter invariants C1–C5
   ```

   `run-tests.sh` includes positive controls, cases that are *supposed* to be flagged. If one of
   those stops firing, the suite tells you, because a checker that flags nothing and a checker
   that scanned nothing look identical from the outside. Note what it does **not** cover: it
   builds synthetic fixtures in a temp directory and runs the hooks against those, so it stays
   green even if you have renamed a tier folder out from under the vault. `vault-check.sh` is the
   only thing that reads your real notes, and it is report-only: it never edits a note, it prints
   violations and exits 1 if it found any. On a fresh clone the correct output is
   `0 violation(s) across 9 file(s) checked`. If you see *0 files checked*, that is a vacuous
   result, not a pass, and it means nothing was scanned.

6. **Write your first note.** Copy a template from the matching `templates/` folder, fill the
   frontmatter, save. The `vault-lint.sh` hook will comment if `tier:` or `type:` is missing,
   but only when a harness that runs it writes the file (Claude Code does out of the box). A note
   you type directly in Obsidian, or a file you drop into `01-inbox/` by hand, is never linted, so
   run `bash .claude/scripts/vault-check.sh` after a manual authoring session, or let the commit
   gate run it for you.

7. **(Optional) Schedule the agents.** Use the shipped runners (`dream-pass.sh`/`.cmd` and
   `promotion-pass.sh`/`.cmd`) rather than a hand-rolled cron line. They kill a hung pass, fail a
   pass that wrote outside its allowed folders, and assert that a pass which exits 0 produced an
   artifact, so a silent no-op cannot pass as a green run. They run Claude Code by default. With
   another harness, set `VAULT_AGENT=command` and point `VAULT_AGENT_CMD` at a wrapper you write.
   The runner refuses that mode (exit 3) until you sandbox the wrapper and set
   `VAULT_ALLOW_UNENFORCED_TOOLS=1`, because no wrapper can enforce the agents' tool allowlists.
   `vault-retention.sh`/`.cmd` schedules the same way and is the odd one out here, because it runs
   no agent at all. None of `VAULT_AGENT`, `VAULT_AGENT_CMD` or `VAULT_ALLOW_UNENFORCED_TOOLS`
   applies to it, and there is no retention agent to sandbox.
   Read [`docs/setup.md`](docs/setup.md) first. The Windows traps below are real, and they fail
   silently.

---

## The frontmatter contract

Every note carries YAML frontmatter. `tier` and `type` are the two keys the machinery
reads: the lint hook flags their absence on write, and `vault-check.sh` fails the vault without
them. The rest are contract, enforced by review and by you.

| Key | Status | Meaning |
| --- | --- | --- |
| `title` | contract | Human-readable title; may differ from the filename |
| `tier` | **machine-checked (C2)** | `short`, `medium`, or `long` — declares the note's expected lifetime |
| `type` | **machine-checked (C3)** | `daily`, `project-log`, `standard`, `wiki-entity`, `moc`, `reference` |
| `tags` | contract | Flat tag list; the Dataview dashboards group on these |
| `status` | contract | `active`, `stable`, `superseded` |
| `created` | contract | ISO date the note was first written; never edited afterwards |
| `last_reviewed` | contract | ISO date a human last *read* the note and still agreed with it |
| `project` | contract | Project slug the note belongs to; ties medium-tier logs together |
| `related_logs` / `related_notes` / `source_notes` | contract | Wikilinks that stitch a note back to what produced it |
| `confidence` | optional | `high` / `medium` / `low` — how much weight a later session should give it |
| `last_verified` | optional, dates checked (C4/C5) | ISO date the claim was actually **re-probed**, not merely re-read |
| `contradicts` | optional | Wikilink(s) to notes that disagree with this one. Both still stand |
| `superseded_by` | optional | Wikilink to the note that replaced this one. Set with `status: superseded` |

The checker implements exactly five invariants, and nothing beyond them: **C1** the file opens
with a bare `---` fence; **C2** frontmatter has a `tier:` key; **C3** it has a `type:` key; **C4**
if both `created:` and `last_verified:` exist, `last_verified >= created`; **C5** `last_verified`
is never in the future. C4 also flags a `created` that is not a `YYYY-MM-DD` date, and C5 a
`last_verified` that is not. C4 and C5 exist because a bad date is the quietest way to poison a
freshness signal. There is deliberately **no** check that a long-tier note carries
`last_verified` at all. That judgement stays with you. The scan covers the six content tiers
(`01-inbox`, `10-daily`, `20-projects`, `30-knowledge`, `31-standards`, `40-llm-wiki`), skipping
`*/templates/*` and the compaction stubs; `90-auto-memory/` is machine-managed and out of scope.

---

## Design principles

These are the arguments the structure is built on. They are also the parts most worth stealing if
you build something else.

### 1. Mark superseded, never delete

When knowledge is replaced, the old note gets `status: superseded` and a `superseded_by:` link.
It does not get deleted. A memory store whose value is auditable provenance cannot answer
*"what did we believe last quarter, and what changed our minds?"* if it throws the old belief
away. Deletion also destroys the most useful debugging artifact you have, which is the shape of a
mistake you already made once. Obsolete material goes to `99-archive/`, still linkable, still greppable,
out of the way. `31-standards/EXAMPLE-retry-on-any-5xx.md` ships superseded, so
you can see the shape before you need it.

### 2. Contradictions are recorded, not auto-resolved

A `contradicts:` edge in frontmatter says two notes disagree, and **both remain active**. Nothing
resolves the conflict except a human deciding which one is wrong, or discovering that they are
scoped differently and both are right. A system that auto-resolves contradictions silently
deletes one side of a disagreement, usually the newer and less-linked side, which is the side
carrying the new information. Surfacing the conflict is cheap; picking
the wrong winner is not.

### 3. A success signal is not evidence

Exit codes, HTTP 200s, "0 findings", and a green test run are *reports about* a state change, not
the state change. An API can return 200 and ignore the field you set. A scanner can print zero
findings because it matched nothing or because it scanned nothing, and those two outcomes are
indistinguishable from the outside. That is why `vault-check.sh` prints the file count next to
the violation count. So every absence claim here is paired with a **positive control**, a known-bad
input the checker must flag. `run-tests.sh` is built that way on purpose. If the positive
controls stop firing, the instrument has silently broken, and the suite says so. Its negative
controls are the mirror image: known-good notes that must produce silence.

### 4. Earned vs. unearned freshness stamps

`last_verified` moves **only** when you re-probed the claim by re-running the command, re-reading
the upstream doc, or re-checking the API. If you re-read the note and still believe it, you move
`last_reviewed`. The distinction matters more than it looks, because an unearned `last_verified`
stamp suppresses its own detection. Every later staleness pass sees a recent date, skips the note,
and the stale claim becomes permanently invisible. That is worse than having no stamp at all,
because now there is false confidence attached.

### 5. Propose, don't execute

The scheduled dream agent reads broadly across all three tiers and writes exactly one thing: a
dated journal file of proposals. It never edits an existing note, never promotes anything, never
deletes. That constraint is what makes running it unattended safe. The worst outcome of a
bad run is one bad file you ignore, not a vault quietly rewritten overnight by a model nobody was
watching. The runner backs that constraint mechanically: it fails the run if any other file
changed. When the changed file could run code or steer later sessions (an Obsidian plugin, a hook,
an instruction file, memory, git's config), failing is not enough, because the file would still be
there next time something opens the vault. So the runner restores it, keeps what the pass wrote in
a quarantine outside the vault, and sets a tripwire that stops every later run until you have
looked. The promotion agent, which *does* write into the long tier, has no shell. Its runner fails
the run if it wrote anywhere but the long tier or a promotion report. Otherwise the runner checks
every note the pass changed and commits exactly those with a `Vault-Pass: promotion` trailer, so
each unattended write is one revertible commit. A pass whose notes fail the check has them put
back, except a note someone changed or committed while it ran, which the log lists. The fence
catches a write in the wrong place. Only git history can undo a bad write in the right one, which
is why `git` is a hard requirement.

### 6. Degrade loudly

Every optional dependency is guarded, and a check that cannot run **says so** instead of
reporting clean. The lint hook needs `jq` to parse hook input (without it, it falls back to a
`sed` path-parse and warns), and `perl` (preferred) or `grep -P` to scan for zero-width and
bidirectional-override codepoints. That is the "Rules File Backdoor" class, where invisible
characters hide instructions inside a file that looks innocuous in every editor. The scan covers
the content tiers plus the files that steer the model: `.claude/rules/`, `.claude/agents/`,
`.claude/skills/`, and any `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` or
`.github/copilot-instructions.md`. If neither scanner is available, the hook reports that the scan
**did not run** rather than passing the file. It still exits 0, and it could not do otherwise: a
post-write hook fires *after* the write has landed on disk, so no exit code from it could ever
block one. The lint is advisory by construction, not by choice. The pre-commit gate is the place
where a violation can actually stop something.

---

## Requirements & platform notes

| Dependency | Status | Notes |
| --- | --- | --- |
| `bash` | required | Git Bash on Windows; every hook, checker and runner is bash |
| `git` | required | For the clone, for `git log` as the audit trail, and because the runners' commits are what make an unattended pass's writes revertible |
| Obsidian | required | Any recent version; open the repo root as a vault |
| Obsidian **Dataview** | **required** | Every dashboard is a Dataview query; without it they render as code blocks |
| `jq` | strongly recommended | Parses hook input. **Not bundled with Git for Windows**, so install it separately. Without it the lint hook falls back to a `sed` path-parse and warns loudly |
| `perl` | recommended | Runs the invisible-character scan. Present on macOS, on most Linux distributions, and in Git for Windows |
| `grep -P` | fallback only | A GNU extension, available on Linux but **absent from macOS BSD grep**. That is why the hook prefers `perl` |
| Graph plugins | optional | The graph ids in `community-plugins.json` are configured but not needed |
| A coding-agent harness | required | Any harness that reads `AGENTS.md`. Claude Code runs the hooks, skills and subagents automatically; see [harness support](AGENTS.md#8-harness-support) for what other harnesses get |

### Template placeholders — read this before you file a bug

The four shipped templates use `{{date:...}}` and `{{time:...}}`, which Obsidian's **core**
Templates plugin does support. They **also** use `{{selection}}`, `{{project}}` and `{{concept}}`,
which core Templates does **not** support. With only the core plugin enabled, those three
placeholders render **literally**, so you will see `{{project}}` sitting in your new note. You
have two options: install the community **Templater** plugin, which resolves them, or fill them in
by hand. Nothing in the vault breaks either way; the frontmatter checker sees a literal string where
it expected a value.

You also have to point the Templates plugin at a template folder yourself. This vault deliberately
ships **no** `.obsidian/templates.json`: the core plugin supports exactly one template folder,
while this layout co-locates a `templates/` folder inside each tier, so any single value shipped
here would point at a folder you did not want. Set it in Settings → Templates, or use Templater,
which handles per-folder templates. `.obsidian/daily-notes.json` *is* shipped and correct as-is.
It points at `10-daily/` and `10-daily/templates/short-term-daily.md`.

### Windows scheduling traps

If you schedule the agents with Task Scheduler, these three will bite, and all three fail in the
direction that looks healthy:

- In `cmd`, `echo Result %ERRORLEVEL%>> "log"` makes the parser read the trailing digit as a file
  handle, so the exit code silently vanishes from your log. Capture it first and write
  `(echo Result %RC%)>> "log"`.
- `claude --agent <name>` with **no** `-p` starts an *interactive* session. (The agent is
  selected with the `--agent` **flag**, not by typing a slash command.) Under a scheduler with no
  TTY it produces nothing while reporting success. Always pass `-p`. The shipped runners already
  do; the `.cmd` files run the `.sh` runners through Git Bash. The same trap applies to any other
  harness: the wrapper behind `VAULT_AGENT_CMD` must run its CLI in non-interactive mode.
- Task health is `LastTaskResult` **plus a log file on disk**, never `State`. A task can sit at
  `Ready` for weeks while every run dies on startup.

---

## Customizing

Start with [`docs/customizing.md`](docs/customizing.md). One warning belongs here because it is
the template's biggest customization cost:

> **Renaming a tier folder is a multi-file edit, not a rename.** The folder names
> (`01-inbox/`, `10-daily/`, `20-projects/_logs/`, `31-standards/`, `40-llm-wiki/`, …) are
> hardcoded independently across the repo. The *minimum* set is `AGENTS.md`,
> `.claude/hooks/vault-lint.sh`, `.claude/scripts/vault-check.sh` (its `TIERS=` line),
> `.claude/hooks/postcompact-wrap-up.sh`, both files in `.claude/agents/`, all four
> `.claude/rules/*.md`, all five skills, `30-knowledge/moc/VAULT-INDEX.md` (every Dataview query
> names folders), `dream-pass.sh`, `promotion-pass.sh` and `vault-retention.sh`, the fixtures in `.claude/scripts/run-tests.sh`,
> `.obsidian/daily-notes.json`, and `.gitignore`. Treat that list as a floor, not an inventory:
> grep for the old name across the whole repo and fix every hit. A missed one turns into a hook
> that silently stops matching, which looks like a hook that found nothing wrong. And
> `run-tests.sh` will not catch it, because it tests against its own temp-directory fixtures
> rather than your folder layout.

The numeric prefixes exist to keep the tiers in reading order in Obsidian's file explorer. If you
do not care about that ordering, changing them is the least valuable customization available and
the most expensive.

---

## Documentation

| Document | What it covers |
| --- | --- |
| [`docs/why.md`](docs/why.md) | Why this exists instead of an existing memory system: requirements, the researched landscape by category, what was borrowed, known weaknesses, and when to choose something else |
| [`docs/setup.md`](docs/setup.md) | Longer-form setup walkthrough, graph and template configuration, scheduling on cron, launchd, and Task Scheduler, and removing it all again |
| [`docs/concepts.md`](docs/concepts.md) | The tier model, the promotion path, and why each boundary sits where it does |
| [`docs/reference.md`](docs/reference.md) | Full reference: frontmatter keys, the C1–C5 invariants, the hooks, the skills, and the agents |
| [`docs/customizing.md`](docs/customizing.md) | Renaming tiers, adding a tier, changing the frontmatter contract |
| [`docs/harnesses/`](docs/harnesses/README.md) | One guide per coding-agent harness: the shipped config, what it enforces, one-time setup, and an onboarding prompt with checks |
| [`docs/agent-onboarding.md`](docs/agent-onboarding.md) | Copy-paste prompts for running the vault with an agent: install check, onboarding a codebase, capture, promotion, consolidation |
| [`AGENTS.md`](AGENTS.md) | What a coding agent should read first, the rules it must not break, and how it verifies its own work |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | How to propose a change to the template itself |

The five `EXAMPLE-` notes are the fastest way to see the contract in practice — read them in
place, in the tier folders listed above.

---

## License

MIT — see [`LICENSE`](LICENSE). The template is yours to fork, rename, and reshape. The notes you
put in it are yours alone; nothing here ships or transmits vault contents anywhere.
