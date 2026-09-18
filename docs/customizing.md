# Customizing the vault

This template is meant to be adapted. Some changes are free; one change — renaming a tier
folder — touches more than a dozen files and will silently half-break the vault if you miss one.
This page sorts the customizations by how much they cost you, and gives a verification step for
the expensive ones.

The rule that matters throughout: **after any structural change, re-run the checks and confirm
they actually inspected something.** A checker that reports "0 problems" because it scanned zero
files looks exactly like a healthy vault.

---

## 1. Start here: what is safe to change immediately

These are local, reversible, and touch nothing the hooks or scripts depend on.

**Add your own notes.** Write into `10-daily/`, `01-inbox/`, `20-projects/_logs/`,
`31-standards/`, `40-llm-wiki/wiki/`. If the frontmatter carries `tier` and `type`, the lint
hook's frontmatter check passes. It also flags invisible zero-width and bidi characters (which is
how a note pasted from the web draws a warning despite correct frontmatter), and it only inspects
files under the six content-tier folders. Silence on a note written anywhere else means it was
never checked, not that it passed. And because the hook fires only on writes by a harness that
runs it (Claude Code, out of the box), a note you type directly in Obsidian is never linted at
all; `vault-check.sh` is what sees those.

**Describe your vault in `AGENTS.md`.** Near the top of `AGENTS.md` is a placeholder comment for
what the vault is *for*. Replace it with your own description, which every harness then reads.
Leave the tier-folder table, the promotion rules, and the `@`-import of
`30-knowledge/moc/ARCH-INDEX.md` in `CLAUDE.md` alone unless you are doing section 2 below.

**Delete the example notes.** Five notes prefixed `EXAMPLE-` ship inside their real tier folders —
deliberately, so the dashboards and graph colours populate on first run rather than showing you an
empty vault. They tell one fictional story (an "example-api" service double-charging customers
because its retries carried no idempotency key), and one of them,
`31-standards/EXAMPLE-retry-on-any-5xx.md`, is marked `status: superseded` to demonstrate
mark-never-delete. Nothing imports them. Remove them all once you have your own notes, or the
fiction shows up in your dashboards and in your agent's search results:

```bash
find . -name 'EXAMPLE-*.md' -delete
```

**Adjust the graph colours.** The tier colouring lives in `.obsidian/`, applied through the graph
plugins. Change the colours from Obsidian's graph settings UI; it writes the config back for you.
None of the shipped scripts read those colours.

**Trim the Obsidian plugin set.** Dataview is required, because every dashboard in the vault is a
Dataview query, and removing it turns them into inert code blocks. The three graph plugins
(`folders2graph`, `three-d-graph-view`, `extended-graph`) are optional; disable any of them
without consequence. `.obsidian/community-plugins.json` is only the list of *enabled*
plugin ids. Obsidian does not download anything from it, and you install each plugin yourself.
Obsidian also opens an unfamiliar vault in **Restricted Mode**, where community plugins are
disabled and there is no Browse button until you turn Restricted Mode off.

**Fill in the template placeholders by hand.** The note templates use `{{date:...}}` and
`{{time:...}}`, which Obsidian's **core** Templates plugin expands, but also `{{selection}}`,
`{{project}}` and `{{concept}}`, which it does **not**. Under core Templates those three render
literally and you overwrite them by hand. If that annoys you, install Templater
and rewrite them in Templater syntax, or delete the placeholders from the templates and
type the values in. There is deliberately no `.obsidian/templates.json` in the repo: the core
plugin accepts exactly one template folder, while this layout co-locates a `templates/` folder
inside each tier, so any shipped value would point somewhere wrong. Set the Templates folder
yourself, or use Templater.

---

## 2. Renaming or adding a tier folder

This is the honest one, and the template's single biggest customization cost.

The tier folder names (`01-inbox`, `10-daily`, `20-projects/_logs`, `30-knowledge`,
`31-standards`, `40-llm-wiki`, `90-auto-memory`, `99-archive`) are **independently hardcoded
across many files**. There is no single constant to edit. Rename a folder, update only some of
them, and you get the worst failure mode available: everything still runs, exits 0, and checks
nothing.

So do not work from a list — generate one. From the vault root:

```bash
grep -rIl -E '01-inbox|10-daily|20-projects|30-knowledge|31-standards|40-llm-wiki|90-auto-memory|99-archive' --exclude-dir=.git .
```

### The high-risk subset

This is the **minimum** — the files where a miss fails silently rather than loudly. The grep above
is the authoritative list.

| File | What is hardcoded, and what to change |
|---|---|
| `AGENTS.md` | The tier table, the promotion rules, and every prose path reference. Change every folder name mentioned. |
| `CLAUDE.md` | The `@`-import path of `30-knowledge/moc/ARCH-INDEX.md`. |
| `.claude/hooks/vault-lint.sh` | The path match that decides which written files get linted. Update the folder prefixes it tests against. |
| `.claude/scripts/vault-check.sh` | Its `TIERS=` line — the directories it walks for the C1–C5 frontmatter invariants. Update the scan roots. |
| `.claude/hooks/postcompact-wrap-up.sh` | The output directory for the compaction stub (`20-projects/_logs/` by default). Update the write target. |
| `.claude/agents/dream-agent.md` | The read set (which folders it consolidates from) and the single write target for its dated journal. Update both. |
| `.claude/agents/promotion-agent.md` | Its source tier and its promotion target. |
| `.claude/rules/vault-notes.md` | The rule's `paths:` frontmatter scope — all six content tiers — plus the filing instructions in the body. |
| `.claude/rules/verification.md` | The rule's `paths:` frontmatter scope: the same six content-tier globs as `vault-notes.md`, not just the long tier. Update every entry. |
| `.claude/rules/untrusted-captures.md` | The rule's `paths:` frontmatter scope — `01-inbox/**/*.md` and `40-llm-wiki/raw/**/*.md` only. This one is a **security boundary**: if the scope no longer matches the folder holding captured content, the prompt-injection rule stops loading for exactly the notes that need it. |
| `.claude/rules/security.md` | Names folders in its body. (It has no `paths:` frontmatter — it is global and always loads.) |
| `30-knowledge/moc/VAULT-INDEX.md` | Every Dataview dashboard names its folders in a `from` clause. Miss this and each dashboard quietly returns an empty table. |
| The five skills in `.claude/skills/` | `obsidian-save`, `wrap-up`, `resume`, `preserve` and `onboard-project` all name tier folders in their filing and reading instructions. |
| `.claude/scripts/dream-pass.sh`, `promotion-pass.sh` | The write fences and artifact assertions name `20-projects/_logs/`, `31-standards/` and `40-llm-wiki/wiki/`. Miss these and every run exits 2 (VIOLATION) or 1 (NO-ARTIFACT). The `.cmd` wrappers name no tier folder. |
| `.claude/scripts/run-tests.sh` | Its synthetic fixture paths. These are *not* your vault, but leaving them stale means the suite stops testing the paths you actually use. |
| `.obsidian/daily-notes.json` | The daily-note folder and template path (vault-root-relative). Obsidian will happily create daily notes in a folder that no longer matches your tier layout. |
| `.gitignore` | The commented note-exclusion block in section 8 below. |

Adding a **new** tier folder touches the same files. At minimum, register it in `AGENTS.md` (so
every agent knows it exists), `vault-check.sh` (so it gets checked), and `vault-lint.sh` (so writes
into it get linted).

### Verify the rename

Do not trust the absence of errors. Run both checkers, but know what each one can and cannot see:

```bash
bash .claude/scripts/run-tests.sh      # hook and runner logic: positive AND negative controls
bash .claude/scripts/vault-check.sh    # frontmatter invariants over your real notes; 1 = a note is wrong, 2 = it could not run
```

**`run-tests.sh` cannot verify a rename.** It builds synthetic fixtures in a temp directory with
the *original* folder names and runs the hooks against those, so it never looks at your vault's
layout and stays green after a botched rename. Treat it as "the hook logic still works", nothing
more. (Its controls are worth understanding while you are here: a **positive** control is a
known-bad fixture the checker *must* flag, and if positive controls stop firing, the instrument has
silently broken. A **negative** control is a known-good fixture that must produce silence.)

That leaves two probes that do see your vault:

> **1. Compare `vault-check.sh`'s file count against the count from before the rename.** It should
> be unchanged. The script builds its scan set by testing each tier folder for existence and
> skipping the missing ones, so renaming *one* folder leaves the other five contributing files and
> the total stays comfortably non-zero, and only reaches zero when every tier is gone. A shrinking
> count is the signal; "0 violations across 0 files" is a vacuous result, not a pass. Against the
> shipped example notes, correct output is `0 violation(s) across 9 file(s) checked`.

> **2. Write a deliberately broken note (missing `tier:`) into the renamed folder and confirm the
> lint hook comments on it.** This is the primary evidence, because it is the only check that
> exercises the renamed path end to end. If the hook stays quiet, `vault-lint.sh` is not seeing the
> new path. Write it through a harness that runs the hook (Claude Code fires it on `Write`/`Edit`),
> or call `bash .claude/hooks/vault-lint.sh <the-broken-note>` yourself, which runs the same path
> match. Creating the file in Obsidian alone proves nothing, because nothing lints it.

The shipped CI (`.github/workflows/ci.yml`) runs both checkers, but only against this template's
own example notes and fixtures, and no pre-commit hook ships. If you want a rename in your vault to
be caught automatically, that wiring is yours to add.

---

## 3. Changing the frontmatter contract

The shipped contract, as defined in `.claude/rules/vault-notes.md`:

```yaml
tier: long                    # short | medium | long   — REQUIRED
type: standard                # daily | project-log | standard | wiki-entity | moc | reference — REQUIRED
status: stable                # active | stable | superseded
title: "..."
project: "..."
created: "2026-01-15"
last_reviewed: "2026-01-15"
last_verified: "2026-01-15"   # long tier: moves only on an actual re-probe
confidence: high              # high | medium | low
tags: [tier/long]
```

Three more optional keys are defined: `contradicts` and `superseded_by` (each a wikilink), and the
`last_verified` date above. Those enums are the whole vocabulary. There is no `draft` or
`archived` status, and the types are `project-log` and `wiki-entity`, not `log` and `entity`.

**Adding a key is non-breaking.** Dataview ignores keys that nothing queries, the lint hook only
asserts that `tier` and `type` are present, and `vault-check.sh` only enforces its own five
invariants (a leading `---` fence, a `tier:` key, a `type:` key, `last_verified >= created` when
both exist, and `last_verified` not in the future, with both dates in `YYYY-MM-DD` form). Add
whatever you like.

**Removing or renaming `tier` or `type` is breaking.** Both are load-bearing in three places at
once: `vault-lint.sh` (mandatory-key check), `vault-check.sh` (the C1–C5 invariants), and
essentially every dashboard query in the vault. If you need different names, treat it
as a section-2-scale change and use the same verification discipline.

### Worked example: add an optional key

Say you want to track which notes carry an unresolved disagreement. The shipped `contradicts` key
does exactly this, so extend it. Add to the long-term template:

```yaml
contradicts: []            # wikilinks to notes this one disagrees with
```

Populate it on a note:

```yaml
contradicts: ["[[retry-policy-exponential]]"]
```

Then add a dashboard that surfaces them. Nothing resolves a contradiction automatically. The
point of recording the edge is that **both notes still stand** until a human decides:

````markdown
```dataview
TABLE contradicts AS "Disagrees with", status, last_reviewed
FROM "31-standards" OR "40-llm-wiki/wiki"
WHERE contradicts AND length(contradicts) > 0
  AND !contains(file.folder, "templates")
SORT last_reviewed ASC
```
````

Notes that never set `contradicts` do not appear. That is the whole cost of adding a key.

---

## 4. Writing your own Dataview query

A Dataview query is a fenced `dataview` block inside any note. The shipped frontmatter gives you
plenty to query against.

One habit first: **any query over a tier folder should exclude `*/templates/*`**, the way every
shipped dashboard in `VAULT-INDEX.md` does. `31-standards/templates/long-term-standard.md` carries
`tier: long` and unexpanded `{{date:...}}` placeholders, so without the exclusion your first
hand-written query returns the template as a permanently stale standard.

Stale long-term knowledge — standards whose verification stamp has aged past 180 days:

```dataview
TABLE status, confidence, last_verified AS "Verified"
FROM "31-standards"
WHERE tier = "long"
  AND status != "superseded"
  AND !contains(file.folder, "templates")
  AND (!last_verified OR date(last_verified) < date(today) - dur(180 days))
SORT last_verified ASC
```

Open promotion candidates by project — the medium tier waiting on a `/preserve` pass:

```dataview
TABLE rows.file.link AS "Logs", length(rows) AS "Count"
FROM "20-projects/_logs"
WHERE tier = "medium" AND status = "active"
  AND !contains(file.folder, "templates")
GROUP BY project
SORT length(rows) DESC
```

Three things to keep in mind. After `GROUP BY`, only the group key and the `rows` array are in
scope. A bare `created` or `last_reviewed` resolves to null, giving you a table of empty columns
that renders rather than errors, so reach for `rows.<field>` as above. Dates must be wrapped in
`date(...)` to compare; a bare string comparison sorts lexically and gives you plausible-looking
nonsense. And a `WHERE` over a key nothing sets returns an empty table, which reads exactly like
"nothing is stale" — check any new query against a note you know should match before you trust an
empty result.

---

## 5. Turning hooks off, or changing what the lint does

For Claude Code, three hooks are registered in `.claude/settings.json`: `PostToolUse` with matcher `Write|Edit`
(vault-lint), `PostCompact` with matcher `*` (compaction stub), and `InstructionsLoaded` with
matcher `*` (audit log). Each is registered with `"shell": "bash"`, which is what makes them run
on Windows through Git Bash. All three log to `.claude/logs/`, which is gitignored.

**To disable one**, remove its entry from `.claude/settings.json`. Edit that file by hand. It
governs the permission and hook surface, and assistants are routinely blocked from writing to it.
Hook registrations are read at session start, so restart Claude Code and then confirm from
`.claude/logs/` that the hook no longer fires; editing mid-session and watching it still run is
not evidence the edit failed. Deleting the script without removing the registration leaves Claude
Code invoking a missing file on every matching event. If you wired a script into another harness,
or enabled the commit gate, turn it off there too: that harness's own hook configuration, and
`git config --unset core.hooksPath`.

**`vault-lint.sh` always exits 0, by design.** It writes advice — missing `tier`/`type`
frontmatter, and any zero-width or bidirectional-override codepoints it finds (the "Rules File
Backdoor" class, where invisible characters hide instructions inside a note). The character scan
is widened to `.claude/rules/`, `.claude/agents/`, `.claude/skills/`, and any `AGENTS.md`,
`CLAUDE.md`, `GEMINI.md` or `.github/copilot-instructions.md` — the steering files that attack
targets.

You could make it exit non-zero on a violation, but be clear about what that does and does not
buy you:

- **It cannot block the write.** `PostToolUse` fires *after* the tool has completed. The file is
  already on disk by the time the hook runs, so no exit code can prevent or roll back anything.
  A non-zero exit surfaces the hook's output to the agent as an error, which usually prompts a
  follow-up correction pass. That is a nudge, not enforcement. (`PreToolUse` is the hook point that
  can deny an action, and it is not registered here.)
- **It never sees notes you write yourself.** Anything typed in Obsidian or dropped into
  `01-inbox/` by hand bypasses the hook entirely, whatever its exit code.
- **The hook guards its dependencies, and you would be raising the volume on those guards.** `jq`
  is recommended but is **not** bundled with Git for Windows (without it the hook falls back to a
  sed path-parse and warns loudly), and `perl` drives the invisible-character scan (`grep -P` is
  a GNU extension, absent from macOS BSD grep, which is why perl is preferred and the
  `grep -P` path is only a fallback). With neither available the hook says the scan did not run
  rather than reporting clean. Turn warnings into errors and you get error-shaped noise from a
  check that never ran.
- **The whole point of the short tier is high-volume, disposable capture.** Gating it behind a
  frontmatter contract pushes people to write outside the vault instead.

Advisory is the shipped default because a memory system you stop feeding is worse than one with
some untidy notes. Whatever you change, keep the dependency guards loud: a check that cannot run
must say so, never report clean.

---

## 6. Adding your own skill or agent

**Skills** live in `.claude/skills/<skill-name>/SKILL.md`. The frontmatter shape:

```yaml
---
name: my-skill
description: One sentence on when to use this. The agent reads this to decide whether to invoke it.
---
```

> **A skill without a `name:` frontmatter key silently never registers.** It raises no error or warning
> and does not appear as an available skill. If a skill you just wrote is never offered,
> check `name:` first. Everything below the frontmatter is plain Markdown instructions.

The five shipped skills are the shape to copy: `obsidian-save` (session → a dated medium-term
log), `wrap-up` (a structured end-of-session summary that a log or a human then consumes. It does
not itself write the log), `resume` (rehydrate from recent logs at session start), `preserve`
(medium → long promotion), and `onboard-project` (wire a codebase into the vault). Three of them
carry `disable-model-invocation: true`, so they run only when you ask for them by name;
`wrap-up` and `onboard-project` do not, and the agent may reach for them on its own. Prefer `Read`
in `allowed-tools` over a `Bash(cat *)` grant: the `permissions.deny` read rules cover the `Read`
tool, not a shell `cat`. Those three keys are Claude Code's. Write the body so it still works as a
plain checklist, because that is how any other harness will use it.

**Agents** live in `.claude/agents/<agent-name>.md`, with `name` and `description` in
frontmatter. If you write an agent meant to run **unattended** on a schedule, copy the constraint
that makes `dream-agent` safe: its only write is one dated journal file, and it never mutates an
existing note. Propose, don't execute. An unattended agent with edit rights over your long-term
tier can quietly rewrite the knowledge you rely on, and you find out weeks later. (`promotion-agent`
does write into the long tier, with no shell. Its runner fails any run that wrote outside the long
tier or a promotion report, checks every note the pass changed, and commits exactly those or puts
them all back. That commit is what makes a bad write revertible, and why git is a hard dependency.)

For scheduling, use the shipped runners rather than a hand-rolled cron line: `dream-pass.sh` /
`.cmd` and `promotion-pass.sh` / `.cmd` in `.claude/scripts/`. They kill a hung pass (exit 124)
or one whose stream stops (exit 125), with everything it started,
fail a pass that wrote outside its allowed folders (exit 2), contain a change to a steering or
execution surface (restore, quarantine, tripwire), and carry an **artifact assertion** (if the
pass exits 0 having produced no artifact, the runner exits 1), so a silent no-op cannot
masquerade as a green run. Roll your own and you lose all four; `docs/reference.md` § 4.3 has the
details. If you add a harness whose configuration lives somewhere new, add that path to
`steering_filter` in `.claude/scripts/lib/runner-common.sh`, or a pass could change it without
being contained. The fence, the pre-pass backup and containment all read that one filter. If you
install an Obsidian plugin that runs code or commands named in its settings, add its id (the
`id` in its `manifest.json`) to `CODE_PLUGINS` in the same file, so its `data.json` is fenced too.
The runners start Claude Code by default; to run a new agent under another harness, give
it the same write-only-what-you-must shape and use `VAULT_AGENT=command`, which refuses to run
until you confirm a sandbox (`docs/setup.md` § 8). Three traps worth repeating if you write your
own `.cmd` wrapper anyway:

- `echo ... %ERRORLEVEL%>> "log"` makes cmd parse the trailing digit as a **file handle**, so the
  exit code silently vanishes. Capture it into a variable first and write `(echo ... %RC%)>> "log"`.
- Selecting an agent is the `--agent <name>` **flag**, and `-p` is **required**. `claude --agent X`
  with no `-p` starts an *interactive* session; under Task Scheduler, with no TTY, it produces
  nothing while reporting success.
- Task health is `LastTaskResult` plus a log on disk — **never `State`**. A task sits `Ready` for
  weeks while every run dies on startup.

---

## 7. Multi-repo use: one vault, several codebases

The vault is built for this. It needs three habits rather than any new machinery.

**Use the `project:` frontmatter key consistently.** Pick one slug per codebase and never vary it
(`acme-api`, not `acme-api` in one note and `Acme API` in the next). Every cross-project dashboard
groups on this field, and Dataview's grouping is case- and spelling-sensitive.

**Give each project a subfolder under `20-projects/_logs/<project-slug>/`** for session logs. Flat
per-project files work at two projects and stop working at six. The `.gitignore` block in section 8
already uses `**/*.md`, so nested logs are covered once you uncomment it.
`90-auto-memory/` also grows per-project subdirectories when a harness keeps its auto-memory there
(Claude Code's does, once pointed at it), but those are maintained by the harness, not by hand: nothing in there is linted or checked
(`vault-check.sh` excludes the folder deliberately), so durable knowledge belongs in the long tier,
never there.

**Keep `PROJECT-INDEX.md` as the register.** It is the one place listing which codebases this
vault covers, where each one's logs live, and what its slug is. A project is onboarded when it
appears there — not when its first log file lands. `VAULT-INDEX.md` stays the structural map of
the vault itself; `ARCH-INDEX.md` stays the map of long-term knowledge.

Each codebase then points its own agent instruction file at the vault. In a `CLAUDE.md` that is
an `@`-import, the same mechanism the vault's root `CLAUDE.md` uses to pull in `AGENTS.md` and
`30-knowledge/moc/ARCH-INDEX.md`. From a repo that sits beside the vault on disk:

```markdown
@../claude-memory-vault/30-knowledge/moc/ARCH-INDEX.md
```

`AGENTS.md` has no import syntax, so in a repo that uses it, add a short section telling the agent
to read the same relative paths before it starts work. A repo with both files needs the pointer in
both.

Use a **relative** path. An absolute one bakes your home directory, and your username, into a
file you may later publish. One honest limit: an import shares the *text* of the long tier, not
the machinery. The hooks, skills and agents load only when the vault itself is the project
directory (see `docs/setup.md` § 6), so a session started from the codebase reads your standards
but is not linted by them. Sharing the long tier is still the whole point: a standard learned on
one project steers sessions on all of them.

---

## 8. Keeping your notes private while tracking the framework

Your notes are the valuable, sensitive part. The framework is the public part. Separate them
deliberately, because the failure is one-directional and permanent: a note pushed to a public
repo survives in forks, clones, and — if it ever appeared in a pull request — in refs nobody can
rewrite.

**Recommended split:**

1. **Use this repo as a template** (GitHub's "Use this template") or fork it, and make **your
   copy private**. Everything you write is private from the first commit, and there is no public
   surface to leak onto.
2. Add the upstream template as a second remote so you can pull framework improvements:

   ```bash
   git remote add template https://github.com/<owner>/claude-memory-vault.git
   git fetch template
   git merge template/main        # review the diff; your notes are untouched
   ```

   That works as written **after a fork**, which shares history with upstream. "Use this template"
   does not. It creates a repo with one fresh initial commit and no common ancestor, so the merge
   fails with `fatal: refusing to merge unrelated histories`. For that path, the *first* sync needs
   `git merge --allow-unrelated-histories template/main` (expect conflicts on files you have
   already edited); every later merge is normal.

3. Keep framework changes in their own commits, separate from note commits. That is what makes
   contributing a fix back upstream a cherry-pick rather than an excavation.

**If you want to contribute changes back from the same working copy**, uncomment the note
exclusion block already present in `.gitignore`:

```gitignore
# 01-inbox/**/*.md
# 10-daily/**/*.md
# 20-projects/_logs/**/*.md
# 30-knowledge/research/**/*.md
# 31-standards/**/*.md
# 40-llm-wiki/raw/**/*.md
# 40-llm-wiki/wiki/**/*.md
# 90-auto-memory/**
# 99-archive/**
# !**/templates/*.md
```

The `**/*.md` forms exclude notes at any depth, so logs nested by project (section 7), daily notes
nested by year, or wiki entities nested by topic are all covered. The last line re-includes the
`templates/` folders, so framework edits to the templates still show up in a diff. Index notes in
`30-knowledge/moc/` are not excluded; if yours carry private content, add that folder too.

Then confirm it, rather than trusting the block: run `git status --ignored` and look for your own
notes in the ignored list before your first push.

Two cautions. `git add -A` in a vault you have been writing into is how notes reach a public
remote — read `git status` before you stage. And treat commit messages as published surface too:
a message survives in history, and correcting a pushed one needs a force-push.
