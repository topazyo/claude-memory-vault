# claude-memory-vault

**Claude Code forgets everything between sessions.** The usual fix is to keep appending to
`CLAUDE.md` until it becomes a two-thousand-line wall of text that nobody reviews, nothing
validates, and the model reads in full on every single turn. This repository is the structured
alternative: an [Obsidian](https://obsidian.md) markdown vault where project memory has **tiers**,
an explicit **promotion path** between them, and a **conformance contract** that a script can
check. Cheap observations land in a daily note. Anything that survives a session gets written to
a project log. Only what has been verified and re-used gets promoted into a long-term standard —
and only long-term standards are expected to steer future sessions. Everything is plain Markdown
with YAML frontmatter, so it is greppable, diffable, reviewable in a pull request, and readable by
a human ten months from now.

This is a **template**. It ships zero personal notes — only the structure, the automation, the
conformance checker, and five fictional `EXAMPLE-` notes that tell one small story across the
tiers. You clone it, open it in Obsidian, point Claude Code at it, and start accumulating your own
knowledge.

---

## What you get

- **Three memory tiers** with distinct lifetimes: `short` (daily notes, inbox captures),
  `medium` (per-project session logs), `long` (standards and concept entities).
- **Four skills** that move knowledge between tiers: `/obsidian-save`, `/wrap-up`, `/resume`,
  `/preserve`.
- **Two scheduled agents**: a *dream agent* that consolidates and proposes, and a *promotion
  agent* that does the weekly medium → long pass — each with a shipped `.sh`/`.cmd` runner that
  fails loudly when a pass produces no artifact.
- **Three hooks**: an advisory frontmatter + invisible-character lint on every Claude Code write,
  a post-compaction stub writer so a compacted session leaves a trace, and an audit log of which
  instruction files loaded at session start.
- **A conformance checker** (`vault-check.sh`) that checks five frontmatter invariants and exits
  non-zero on violation, so you can wire it into a pre-commit hook or CI — the template does not
  wire it for you — plus a **control test suite** (`run-tests.sh`, 18 assertions) with both
  positive and negative controls, so a passing run is evidence the checks actually ran.
- **Four rules files**: three path-scoped (the frontmatter contract when Claude edits a note, the
  verification discipline, and a prompt-injection boundary for captured content) plus one global
  safety file that always loads.
- **Dataview dashboards** and a tier-coloured graph view configuration.

---

## Repository layout

```
claude-memory-vault/
├── CLAUDE.md                        # root project instructions Claude reads every session
├── CONTRIBUTING.md
├── .claude/
│   ├── settings.json                # registers the three hooks (shell: bash → Git Bash on Windows)
│   ├── agents/
│   │   ├── dream-agent.md           # scheduled consolidation; READ-AND-PROPOSE ONLY, one output file
│   │   └── promotion-agent.md       # weekly medium → long promotion; git-snapshots before writing
│   ├── hooks/
│   │   ├── vault-lint.sh            # PostToolUse advisory lint; always exits 0
│   │   ├── postcompact-wrap-up.sh   # one idempotent, size-capped compaction stub per session
│   │   └── instructions-loaded-log.sh # audit log of instruction files loaded at session start
│   ├── rules/
│   │   ├── vault-notes.md           # frontmatter contract, wikilinks, Dataview, filing (path-scoped)
│   │   ├── verification.md          # freshness, citation, earned-stamp discipline (path-scoped)
│   │   ├── untrusted-captures.md    # prompt-injection boundary for captures (path-scoped)
│   │   └── security.md              # global safety rules; no paths:, always loads
│   ├── scripts/
│   │   ├── vault-check.sh           # report-only invariant checker (C1–C5); exit 1 on violation
│   │   ├── run-tests.sh             # control suite for the hooks; positive AND negative controls
│   │   ├── dream-pass.sh / .cmd     # scheduled runner (cron/launchd + Windows Task Scheduler)
│   │   └── promotion-pass.sh / .cmd # ditto, for the weekly promotion pass
│   └── skills/
│       ├── obsidian-save/SKILL.md   # session → medium-term log
│       ├── wrap-up/SKILL.md         # structured end-of-session summary
│       ├── resume/SKILL.md          # rehydrate from recent logs at session start
│       └── preserve/SKILL.md        # medium → long promotion
├── .obsidian/                       # plugin + appearance config, tier-coloured graph
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
├── 90-auto-memory/                  # Claude Code's own auto-memory directory, machine-managed
├── 99-archive/                      # retired notes; prefer archiving over deleting
└── docs/                            # concepts.md, setup.md, customizing.md, reference.md
```

The five `EXAMPLE-` notes live in their real tier folders on purpose, so the dashboards and the
graph colours have something to render on first open. They are one fictional story: an
`example-api` service double-charging customers because its retries carried no idempotency key.
When you have seen enough of it, `find . -name 'EXAMPLE-*.md' -delete`.

---

## How memory moves

Promotion is **deliberate, not automatic**. Nothing is copied upward because a heuristic thought
it looked important; something moves up because you (or a run you reviewed) decided it earned the
move. That friction is the point — the long tier only steers future sessions well if it stays
small.

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
| medium → long | `promotion-agent` (weekly) | Same hop, unattended; takes a git snapshot before writing |
| consolidation | `dream-agent` (scheduled) | Reads broadly, writes exactly **one** dated journal file of proposals |
| compaction → medium | `postcompact-wrap-up.sh` hook | Drops a stub log so a compacted session's material is recoverable |
| medium → session | `/resume` | Reads the recent logs back into a fresh session |

---

## Quickstart

**Prerequisites:** `bash` (Git Bash on Windows), `git`, Obsidian, Claude Code, and — strongly
recommended — `jq`. See [Requirements](#requirements--platform-notes) before you start; `jq` is
*not* bundled with Git for Windows.

1. **Clone the template.** Click **Use this template** (or fork) on GitHub first, then:

   ```bash
   git clone https://github.com/<you>/claude-memory-vault.git <your-vault>
   cd <your-vault>
   ```

   If you are starting your own history, `rm -rf .git && git init`, then commit immediately
   (`git add -A && git commit -m "initial vault"`). A repository with zero commits gives the
   promotion agent's git snapshot nothing to revert to. The vault is meant to be a repository you
   commit to, so that "what did we believe last quarter" is answerable from `git log`.

2. **Open the folder as an Obsidian vault.** *Open folder as vault* → pick `<your-vault>`.
   Obsidian will pick up the bundled `.obsidian/` configuration, including the tier-coloured
   graph.

3. **Install the Dataview plugin — this is required.** Obsidian opens an unfamiliar vault in
   **Restricted Mode**, where community plugins are disabled and there is no *Browse* button at
   all, so start there: Settings → Community plugins → *Turn off Restricted Mode* → Browse →
   *Dataview* → Install → Enable. Every dashboard in `30-knowledge/moc/` is a Dataview query and
   will render as an unstyled code block until you do this. The bundled
   `.obsidian/community-plugins.json` is only the list of plugin ids to *enable* — Obsidian does
   not download anything from it, so a plugin you have not installed simply stays absent, with no
   error. The graph plugins listed there are **optional**; the vault works fine without them.

4. **Point Claude Code at the vault.** Start a session with `<your-vault>` as the working
   directory. `CLAUDE.md` loads automatically and `.claude/settings.json` registers the three
   hooks. `.claude/rules/security.md` loads every session; the other three rules files are
   path-scoped and load only when you touch matching paths.

5. **Verify the automation actually runs.** Two commands, both from the vault root:

   ```bash
   bash .claude/scripts/run-tests.sh     # control suite for the hooks
   bash .claude/scripts/vault-check.sh   # frontmatter invariants C1–C5
   ```

   `run-tests.sh` includes positive controls — cases that are *supposed* to be flagged. If one of
   those stops firing, the suite tells you, because a checker that flags nothing and a checker
   that scanned nothing look identical from the outside. Note what it does **not** cover: it
   builds synthetic fixtures in a temp directory and runs the hooks against those, so it stays
   green even if you have renamed a tier folder out from under the vault. `vault-check.sh` is the
   only thing that reads your real notes, and it is report-only: it never edits a note, it prints
   violations and exits 1 if it found any. On a fresh clone the correct output is
   `0 violation(s) across 8 file(s) checked` — if you see *0 files checked*, that is a vacuous
   result, not a pass, and it means nothing was scanned.

6. **Write your first note.** Copy a template from the matching `templates/` folder, fill the
   frontmatter, save. The `vault-lint.sh` hook will comment if `tier:` or `type:` is missing —
   but only when **Claude Code** writes the file. A note you type directly in Obsidian, or a file
   you drop into `01-inbox/` by hand, is never linted, so run
   `bash .claude/scripts/vault-check.sh` after a manual authoring session.

7. **(Optional) Schedule the agents.** Use the shipped runners — `dream-pass.sh`/`.cmd` and
   `promotion-pass.sh`/`.cmd` — rather than a hand-rolled cron line: they assert that a pass which
   exits 0 actually produced an artifact, and exit 1 when it did not, so a silent no-op cannot
   masquerade as a green run. Read [`docs/setup.md`](docs/setup.md) first — the Windows traps
   below are real and they fail silently.

---

## The frontmatter contract

Every note carries YAML frontmatter. `tier` and `type` are the two keys the machinery actually
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
is never in the future. C4 and C5 exist because a bad date is the quietest way to poison a
freshness signal. There is deliberately **no** check that a long-tier note carries
`last_verified` at all — that judgement stays with you. The scan covers the six content tiers
(`01-inbox`, `10-daily`, `20-projects`, `30-knowledge`, `31-standards`, `40-llm-wiki`), skipping
`*/templates/*` and the compaction stubs; `90-auto-memory/` is machine-managed and out of scope.

---

## Design principles

These are the arguments the structure is built on. They are also the parts most worth stealing if
you build something else.

### 1. Mark superseded, never delete

When knowledge is replaced, the old note gets `status: superseded` and a `superseded_by:` link —
it does not get deleted. A memory store whose whole value proposition is auditable provenance
cannot answer *"what did we believe last quarter, and what changed our minds?"* if it throws the
old belief away. Deletion also destroys the most useful debugging artifact you have: the shape of
a mistake you already made once. Obsolete material goes to `99-archive/`, still linkable, still
greppable, just out of the way. `31-standards/EXAMPLE-retry-on-any-5xx.md` ships superseded, so
you can see the shape before you need it.

### 2. Contradictions are recorded, not auto-resolved

A `contradicts:` edge in frontmatter says two notes disagree — and **both remain active**. Nothing
resolves the conflict except a human deciding which one is wrong, or discovering that they are
scoped differently and both are right. Systems that auto-resolve contradictions are really
systems that silently delete one side of a disagreement, usually the newer and less-linked side,
which is exactly the side carrying the new information. Surfacing the conflict is cheap; picking
the wrong winner is not.

### 3. A success signal is not evidence

Exit codes, HTTP 200s, "0 findings", and a green test run are *reports about* a state change, not
the state change. An API can return 200 and ignore the field you set. A scanner can print zero
findings because it matched nothing or because it scanned nothing, and those two outcomes are
indistinguishable from the outside — which is why `vault-check.sh` prints the file count next to
the violation count. So every absence claim here is paired with a **positive control**: a known-bad
input the checker must flag. `run-tests.sh` is built that way on purpose — if the positive
controls stop firing, the instrument has silently broken, and the suite says so. Its negative
controls are the mirror image: known-good notes that must produce silence.

### 4. Earned vs. unearned freshness stamps

`last_verified` moves **only** when you re-probed the claim — re-ran the command, re-read the
upstream doc, re-checked the API. If you merely re-read the note and still believe it, you move
`last_reviewed`. The distinction matters more than it looks: an unearned `last_verified` stamp
suppresses its own detection. Every later staleness pass sees a recent date, skips the note, and
the stale claim becomes permanently invisible — worse than having no stamp at all, because now
there is false confidence attached.

### 5. Propose, don't execute

The scheduled dream agent reads broadly across all three tiers and writes exactly one thing: a
dated journal file of proposals. It never edits an existing note, never promotes anything, never
deletes. That single constraint is what makes running it unattended safe — the worst outcome of a
bad run is one bad file you ignore, not a vault quietly rewritten overnight by a model nobody was
watching. The promotion agent, which *does* write into the long tier, takes a git snapshot first
so every unattended write is revertible with one command. That snapshot is the only write-safety
guard it has, which is why `git` is a hard requirement rather than a convenience.

### 6. Degrade loudly

Every optional dependency is guarded, and a check that cannot run **says so** instead of
reporting clean. The lint hook needs `jq` to parse hook input — without it, it falls back to a
`sed` path-parse and warns — and `perl` (preferred) or `grep -P` to scan for zero-width and
bidirectional-override codepoints, the "Rules File Backdoor" class, where invisible characters
hide instructions inside a file that looks innocuous in every editor. That scan covers the content
tiers plus `.claude/rules/` and `.claude/agents/`, the files that steer the model. If neither
scanner is available, the hook reports that the scan **did not run** rather than passing the file.
It still exits 0 — and it could not do otherwise: `PostToolUse` fires *after* the write has landed
on disk, so no exit code from it could ever block one. The lint is advisory by construction, not
by choice.

---

## Requirements & platform notes

| Dependency | Status | Notes |
| --- | --- | --- |
| `bash` | required | Git Bash on Windows; hooks are registered with `"shell": "bash"` |
| `git` | required | For the clone, for `git log` as the audit trail, and because the promotion agent's only write-safety guard is a git snapshot |
| Obsidian | required | Any recent version; open the repo root as a vault |
| Obsidian **Dataview** | **required** | Every dashboard is a Dataview query; without it they render as code blocks |
| `jq` | strongly recommended | Parses hook input. **Not bundled with Git for Windows** — install it separately. Without it the lint hook falls back to a `sed` path-parse and warns loudly |
| `perl` | recommended | Runs the invisible-character scan. Present on macOS, on most Linux distributions, and in Git for Windows |
| `grep -P` | fallback only | A GNU extension — available on Linux, **absent from macOS BSD grep**. The hook prefers `perl` for exactly this reason |
| Graph plugins | optional | The graph ids in `community-plugins.json` are configured but not needed |
| Claude Code | required | For the hooks, skills, and agents; the vault is readable without it |

### Template placeholders — read this before you file a bug

The four shipped templates use `{{date:...}}` and `{{time:...}}`, which Obsidian's **core**
Templates plugin does support. They **also** use `{{selection}}`, `{{project}}`, `{{concept}}` and
`{{file_name}}`, which core Templates does **not** support. With only the core plugin enabled,
those four placeholders render **literally** — you will see `{{project}}` sitting in your new
note. Two honest options: install the community **Templater** plugin, which resolves them, or fill
them in by hand. Nothing in the vault breaks either way; the frontmatter checker will simply see a
literal string where it expected a value.

You also have to point the Templates plugin at a template folder yourself. This vault deliberately
ships **no** `.obsidian/templates.json`: the core plugin supports exactly one template folder,
while this layout co-locates a `templates/` folder inside each tier, so any single value shipped
here would point at a folder you did not want. Set it in Settings → Templates, or use Templater,
which handles per-folder templates. `.obsidian/daily-notes.json` *is* shipped and correct as-is —
it points at `10-daily/` and `10-daily/templates/short-term-daily.md`.

### Windows scheduling traps

If you schedule the agents with Task Scheduler, these three will bite, and all three fail in the
direction that looks healthy:

- In `cmd`, `echo Result %ERRORLEVEL%>> "log"` makes the parser read the trailing digit as a file
  handle, so the exit code silently vanishes from your log. Capture it first and write
  `(echo Result %RC%)>> "log"`.
- `claude --agent <name>` with **no** `-p` starts an *interactive* session — and note that the
  agent is selected with the `--agent` **flag**, not by typing a slash command. Under a scheduler
  with no TTY it produces nothing while reporting success. Always pass `-p`. The shipped `.cmd`
  runners already do.
- Task health is `LastTaskResult` **plus a log file on disk** — never `State`. A task can sit at
  `Ready` for weeks while every single run dies on startup.

---

## Customizing

Start with [`docs/customizing.md`](docs/customizing.md). One warning belongs here because it is
the template's single biggest customization cost:

> **Renaming a tier folder is a multi-file edit, not a rename.** The folder names
> (`01-inbox/`, `10-daily/`, `20-projects/_logs/`, `31-standards/`, `40-llm-wiki/`, …) are
> hardcoded independently across the repo. The *minimum* set is `CLAUDE.md`,
> `.claude/hooks/vault-lint.sh`, `.claude/scripts/vault-check.sh` (its `TIERS=` line),
> `.claude/hooks/postcompact-wrap-up.sh`, both files in `.claude/agents/`, all four
> `.claude/rules/*.md`, all four skills, `30-knowledge/moc/VAULT-INDEX.md` (every Dataview query
> names folders), the four pass scripts, the fixtures in `.claude/scripts/run-tests.sh`,
> `.obsidian/daily-notes.json`, and `.gitignore`. Treat that list as a floor, not an inventory:
> grep for the old name across the whole repo and fix every hit. A missed one turns into a hook
> that silently stops matching, which looks exactly like a hook that found nothing wrong — and
> `run-tests.sh` will not catch it, because it tests against its own temp-directory fixtures
> rather than your folder layout.

The numeric prefixes exist to keep the tiers in reading order in Obsidian's file explorer. If you
do not care about that ordering, changing them is the least valuable customization available and
the most expensive.

---

## Documentation

| Document | What it covers |
| --- | --- |
| [`docs/setup.md`](docs/setup.md) | Longer-form setup walkthrough, your first week in the vault, and scheduling on cron, launchd, and Task Scheduler |
| [`docs/concepts.md`](docs/concepts.md) | The tier model, the promotion path, and why each boundary sits where it does |
| [`docs/reference.md`](docs/reference.md) | Full reference: frontmatter keys, the C1–C5 invariants, the hooks, the skills, and the agents |
| [`docs/customizing.md`](docs/customizing.md) | Renaming tiers, adding a tier, changing the frontmatter contract |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | How to propose a change to the template itself |

The five `EXAMPLE-` notes are the fastest way to see the contract in practice — read them in
place, in the tier folders listed above.

---

## License

MIT — see [`LICENSE`](LICENSE). The template is yours to fork, rename, and reshape. The notes you
put in it are yours alone; nothing here ships or transmits vault contents anywhere.
