# Setup

This guide takes you from a fresh clone to a working vault: Obsidian open, Claude Code wired to
the hooks, and — the part that actually matters — a verified install, where you have proof the
checkers ran rather than a reassuring silence.

The whole thing takes about fifteen minutes. Steps 1–3 and 6–7 are required. Steps 4, 5 and 8 are
optional and can be skipped without breaking anything.

---

## 1. Prerequisites

| Tool | What it is for | Required? | Check it is present |
| --- | --- | --- | --- |
| **Obsidian** | Reads the vault, renders the Dataview dashboards, draws the graph | Required to *use* the vault as a human; Claude Code alone does not need it | Launch it; Help → About shows the version |
| **Claude Code** | Runs the hooks, skills and agents that write and promote notes | Required | `claude --version` |
| **bash** | Every hook and script is a bash script. macOS and Linux have it; on Windows it comes with Git for Windows | Required | `bash --version` |
| **git** | Cloning the template, and the promotion-agent's only write-safety guard is the git snapshot it takes before writing | Required | `git --version` |
| **jq** | Parses the JSON that Claude Code pipes into the lint hook | Strongly recommended | `command -v jq` |
| **perl** | Runs the invisible-character (zero-width / bidi) scan in the lint hook | Strongly recommended | `command -v perl` |

### About jq on Windows

**Git for Windows does not bundle `jq`.** This surprises people, because Git Bash ships a fairly
complete little userland otherwise.

Without `jq`, `vault-lint.sh` falls back to a `sed` parse of the hook's JSON payload to find the
file path. The fallback works for ordinary paths, but it is a single regex against a JSON blob and
it will mis-parse paths containing quotes or escapes. The hook does not hide this — every degraded
run writes a `DEGRADED:` line to `.claude/logs/vault-lint.log` and prints a warning to stderr.

Install it if you can:

```bash
winget install jqlang.jq        # Windows
brew install jq                 # macOS
sudo apt install jq             # Debian / Ubuntu
```

### About perl and `grep -P`

The lint hook scans written notes for zero-width and bidirectional-control codepoints — the
"Rules File Backdoor" class of attack, where a steering file carries instructions that no human
reviewer can see on screen.

That scan prefers `perl`, and falls back to `grep -P`. The order is deliberate. `grep -P` is a
**GNU extension that BSD grep on macOS does not have**, and a `grep -oP ... 2>/dev/null` there
returns empty — which is character-for-character identical to "this file is clean". `perl` is
present by default on macOS and inside Git for Windows, so it is the reliable path.

If neither exists, the hook says so in its warning text: `INVISIBLE-CHAR SCAN DID NOT RUN`. It
never implies a clean result it did not earn.

---

## 2. Get the repository

Either clone it:

```bash
git clone https://github.com/<owner>/claude-memory-vault.git <your-vault>
cd <your-vault>
```

...or press **Use this template** on the GitHub page, which gives you a repo with no shared
history. The template route is better if you plan to keep your own notes in it.

### Make your copy private if you will store notes in it

This repo ships as a framework with no personal notes in it, and it is meant to stay that way
upstream. The moment you start taking daily notes in `10-daily/` or project logs in
`20-projects/_logs/`, your copy contains your working life. **Set it to private.**

If instead you are forking to contribute back, open `.gitignore` and uncomment the block under
`-- Your notes --`:

```gitignore
# 01-inbox/*.md
# 10-daily/*.md
# 20-projects/_logs/*.md
# 30-knowledge/research/*.md
# 31-standards/*.md
# 40-llm-wiki/raw/*.md
# 40-llm-wiki/wiki/*.md
# 90-auto-memory/**
# 99-archive/**
```

With those lines active, your notes stay on disk and out of every pull request. The `templates/`
subfolders are not matched by those globs, so the templates still travel with the repo.

Note that this is a one-way door in practice: once note content has been pushed to a public repo,
a pull-request diff of it is stored by GitHub under refs nobody can rewrite. Decide before your
first push, not after.

---

## 3. Open it as an Obsidian vault, and install Dataview

1. Open Obsidian → **Open folder as vault** → select `<your-vault>`.
2. Obsidian will read the checked-in `.obsidian/` config: appearance, the tier-coloured graph, and
   the list of community plugins the vault expects.
3. Go to **Settings → Community plugins**, turn off Restricted Mode if prompted, and install
   **Dataview**. Then **enable** it — installing is not enabling, and this catches people.

**Dataview is required.** Every dashboard in `30-knowledge/moc/VAULT-INDEX.md` and
`30-knowledge/moc/PROJECT-INDEX.md` is a Dataview query. Until the plugin is enabled, those notes
render as empty code blocks or as raw query text. They are not broken; they are unpowered.

Restart Obsidian (or use **Reload app without saving**) after enabling, then open `VAULT-INDEX.md`
and confirm you see tables rather than code fences.

---

## 4. Optional: the graph plugins

`.obsidian/community-plugins.json` also lists three optional graph plugins:
`folders2graph`, `three-d-graph-view`, and `extended-graph`. They change how the vault's link
graph is drawn — folder nodes, a 3-D view, and extended styling respectively. Nothing in the
system depends on them; skip them if you want a lean install.

What *is* worth keeping either way is `.obsidian/graph.json`, which defines three colour groups
keyed on tier tags:

| Group query | Meaning |
| --- | --- |
| `tag:#tier/short` | Daily notes and inbox captures — the cheap, high-volume tier |
| `tag:#tier/medium` | Project session logs — the promotion pipeline's input |
| `tag:#llm/wiki tag:#tier/long` | Wiki entities and long-term material — the small, verified tier |

The practical effect is that the core graph view shows you your tier distribution at a glance. A
graph that is overwhelmingly short-tier colour means capture is happening but promotion is not —
which is the failure mode this whole system exists to make visible.

---

## 5. Optional: templates, and an honest caveat

Each tier folder carries its own template:

```
10-daily/templates/short-term-daily.md
20-projects/_logs/templates/medium-term-project-log.md
31-standards/templates/long-term-standard.md
40-llm-wiki/wiki/templates/llm-wiki-entity.md
```

To use them, enable the **core** Templates plugin (Settings → Core plugins → Templates) and point
its **Template folder location** at one of those folders. Core Templates accepts exactly one
folder, while this layout deliberately co-locates a `templates/` folder inside each tier — so
pick the tier you create by hand most often, usually `31-standards/templates`, and insert the
others by copying the file.

For that reason the repo ships **no** `.obsidian/templates.json`: any single value would point
at a folder that does not exist in this layout, and a wrong default is worse than none. Set it
yourself on first run.

Daily Notes is wired separately and correctly out of the box: `.obsidian/daily-notes.json`
points at folder `10-daily` with template `10-daily/templates/short-term-daily.md`. Obsidian
resolves template paths from the **vault root**, not from the notes folder, which is why the
tier prefix is part of the path.

### The placeholder caveat — read this before you file a bug

The templates use two different kinds of placeholder, and core Templates only understands one of
them.

| Placeholder | Core Templates | Result |
| --- | --- | --- |
| `{{date:YYYY-MM-DD}}` | Supported | Expands on insert |
| `{{time:HH:mm}}` | Supported | Expands on insert |
| `{{selection}}` | **Not supported** | Renders literally |
| `{{project}}` | **Not supported** | Renders literally |
| `{{concept}}` | **Not supported** | Renders literally |
| `{{file_name}}` | **Not supported** | Renders literally |

So with core Templates alone, a freshly inserted project log will contain the literal text
`{{project}}` where the project name should be. That is expected, not a bug. Two ways to live
with it:

- **Fill them by hand.** They are one-word substitutions and there are at most a few per note.
- **Install Templater** (community plugin), which supports prompts and dynamic values, and adapt
  the placeholders to its syntax. This is a customization you own; the shipped templates use the
  core syntax so that the vault works with zero community plugins beyond Dataview.

---

## 6. Wiring Claude Code

There is nothing to install. `.claude/settings.json` already registers three hooks, each invoked
as `${CLAUDE_PROJECT_DIR}/.claude/hooks/...` with `"shell": "bash"`. Because the paths are
relative to the project directory and the shell is named explicitly, the same config works on
macOS, Linux, and on Windows through Git Bash.

The only requirement is that **the vault is the project directory** — start Claude Code from
`<your-vault>`:

```bash
cd <your-vault>
claude
```

### What the three hooks do

| Hook | Fires on | What it does | Can it block you? |
| --- | --- | --- | --- |
| `vault-lint.sh` | `PostToolUse`, matcher `Write` or `Edit` | Checks the just-written note for the mandatory `tier:` and `type:` frontmatter, and scans it for zero-width / bidi codepoints. The character scan is widened to `.claude/rules/` and `.claude/agents/`, which are exactly what a rules-file backdoor targets. Logs to `.claude/logs/vault-lint.log`. | No — advisory, **always exits 0** |
| `postcompact-wrap-up.sh` | `PostCompact` | Writes one idempotent, size-capped stub per session into `20-projects/_logs/compaction-<session>.md`, so the material in a compacted context is still recoverable afterwards. Caps at 50 entries, and sanitizes the session id before building a path. | No |
| `instructions-loaded-log.sh` | `InstructionsLoaded`, session start only | Appends which instruction files loaded, to `.claude/logs/instructions-loaded.log`. This is how you answer "was that rule actually in context?" instead of guessing. | No |

All three write only into `.claude/logs/` (gitignored) or into `20-projects/_logs/`. None of them
edits an existing note.

The skills in `.claude/skills/` — `obsidian-save`, `wrap-up`, `resume`, `preserve` — are picked up
automatically from the project directory; there is no registration step.

---

## 7. Verify the install

This section is the point of the whole guide. Run both commands and read the output carefully.

### 7a. The control suite

```bash
bash .claude/scripts/run-tests.sh
```

Expect a list of `PASS` lines, an informational dependency block, and a final
`=== N passed, 0 failed ===`. Exit code 0.

This suite is not decorative. Every check in it has **both a positive and a negative control**: it
feeds the lint hook a file containing a known U+200B and a known U+202E and asserts the hook
*catches* them, before trusting any "clean" result from it. It also builds its fixtures inside a
directory whose name contains a space, because a path like `/Users/Some One/...` is precisely what
breaks word-splitting bugs while still printing a reassuring "0 violations".

The dependency block at the end tells you, in plain language, whether `jq` and `perl` were found.
If it says `MISSING perl and grep -P`, your invisible-character scan cannot run — go back to
step 1.

### 7b. The frontmatter checker

```bash
bash .claude/scripts/vault-check.sh
```

Do **not** pipe this into `less`, `head`, or `tail` if you plan to read `$?` — a pipeline reports
the last command's status, not the checker's.

It validates five invariants across the content tiers (`01-inbox`, `10-daily`, `20-projects`,
`30-knowledge`, `31-standards`, `40-llm-wiki`), skipping `templates/` and `compaction-*.md`:

| ID | Invariant |
| --- | --- |
| C1 | First line is a bare `---` fence |
| C2 | Frontmatter has a `tier:` key |
| C3 | Frontmatter has a `type:` key |
| C4 | If both exist, `last_verified` is not earlier than `created` |
| C5 | `last_verified` is not in the future |

It is **report-only**: it never writes, stamps, or repairs, and it exits 1 when any note violates
an invariant so you can gate a pass on it. Repair is a human act.

The final line looks like this:

```
vault-check: 0 violation(s) across 12 file(s) checked (as of 2026-01-01).
```

### The one output you must not misread

> **`0 violation(s) across 0 file(s)` is NOT a pass.** It means the checker scanned nothing.

Zero findings from an instrument that examined zero inputs is indistinguishable from zero findings
from an instrument that examined everything — which is exactly why the file count is printed at
all. `vault-check.sh` resolves the vault from its **own location** (`$(dirname "$0")/../..`) unless
`CLAUDE_PROJECT_DIR` overrides it, so calling it by an absolute path from anywhere works fine. A
zero file count therefore usually means `CLAUDE_PROJECT_DIR` points somewhere else, or the
content tiers genuinely hold nothing but templates, or a tier folder was renamed without
updating the `TIERS=` line in the script.

On a fresh clone the five `EXAMPLE-*.md` notes already live in their tiers, so the expected
output is `0 violation(s) across 8 file(s) checked`. That non-zero count **is** your positive
control for the checker. Once you delete the examples with `find . -name 'EXAMPLE-*.md' -delete`,
create a throwaway note by hand before re-running, or the count drops back toward zero and the
result becomes vacuous again.

---

## 8. Optional: scheduling the dream and promotion agents

Two agents are defined in `.claude/agents/`. Scheduling them is entirely optional — the vault
works fine driven only by `/obsidian-save` and `/preserve` during ordinary sessions.

| Agent | Cadence | What it writes |
| --- | --- | --- |
| `dream-agent` | Nightly, if you want it | **One** dated dream-journal file. Nothing else, ever. |
| `promotion-agent` | Weekly | **Creates and edits notes** in `31-standards/` and `40-llm-wiki/wiki/` |

The dream-agent is safe to run unattended precisely because it proposes rather than executes: its
only write is a new file at a predictable path, so a pass that misreads something cannot corrupt
anything. **The promotion-agent is different — it writes into your long-term tier.** It takes a
git snapshot before writing so a bad pass is reversible, but read
`.claude/agents/promotion-agent.md` in full before you put it on a timer, and run it manually a
few times first.

### Unix — cron

Use the shipped runners. They resolve the vault from their own location, guard for a `claude`
binary that a scheduler's minimal PATH cannot see, log to `.claude/logs/`, and — the part that
matters — assert that the pass actually produced something.

```cron
# dream pass, nightly at 02:30
30 2 * * *  /path/to/your-vault/.claude/scripts/dream-pass.sh
# promotion pass, Sundays at 03:30
30 3 * * 0  /path/to/your-vault/.claude/scripts/promotion-pass.sh
```

If `claude` is not on the PATH cron gives you — and it usually is not, since cron runs no login
profile — export `CLAUDE_BIN` with the full path in the crontab.

**Why not call `claude` directly from cron?** Two reasons. The agent is selected with the
`--agent <name>` *flag*, not by putting a slash command in the prompt, so a hand-rolled line is
easy to get subtly wrong. And a direct call has no artifact assertion: the runners exit 1 when a
pass exits 0 having written nothing, which is the only thing that distinguishes "ran and had
nothing to do" from "did not run at all". Without it, a broken schedule looks green indefinitely.

On macOS, a `launchd` job with `StartCalendarInterval` is more reliable than cron for machines
that sleep: launchd runs a missed job at wake, cron simply skips it.

### Windows — Task Scheduler, and two traps that will cost you a week

Schedule the shipped `.cmd` runners, not `claude` directly:

```bat
schtasks /create /tn "Vault-DreamAgent" /tr "\"C:\path\to\your-vault\.claude\scripts\dream-pass.cmd\"" /sc daily /st 23:00
schtasks /create /tn "Vault-PromotionAgent" /tr "\"C:\path\to\your-vault\.claude\scripts\promotion-pass.cmd\"" /sc weekly /d SAT /st 20:00
```

Those two files already encode the traps below. They are documented here anyway, because if you
ever write your own wrapper you will meet all three.

**Trap 1 — the vanishing exit code.** In `cmd`, this line does not do what it looks like:

```bat
echo done %ERRORLEVEL%>> "run.log"
```

`cmd` parses the digit immediately before `>>` as a *file handle*, so the redirection binds to
that digit and the exit code never reaches the log. Capture it into a variable first, and
parenthesize the echo:

```bat
set RC=%ERRORLEVEL%
(echo %DATE% %TIME% rc=%RC%)>> "run.log"
exit /b %RC%
```

Without that trailing `exit /b %RC%`, the task's reported result is whatever the *last* command
returned — and a trailing `echo` always succeeds, cheerfully reporting success over a failed run.

**Trap 2 — the silent no-op.** `claude --agent X` with **no `-p`** starts an *interactive*
session. Under Task Scheduler there is no TTY and stdin is `NUL`, so it either reads EOF and
exits 0 within seconds having done nothing, or blocks on input that never arrives. Both look
like success to the scheduler, and the first is the more common and more misleading. Always
pass `-p`. Set `ExecutionTimeLimit` as well: with
`MultipleInstances=IgnoreNew`, a single hung run suppresses every later run for the whole limit,
so a missing timeout turns one hang into permanent silence.

**Checking health.** Task health is `LastTaskResult` **plus a log file on disk** — never `State`.
A task can sit at `Ready` for weeks while every single run dies on startup. If the log has no new
lines, the task is not working, whatever the UI says.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Hooks never fire; `.claude/logs/` stays empty or absent | Claude Code was started outside the vault, so `${CLAUDE_PROJECT_DIR}` points elsewhere | `cd <your-vault>` and start Claude Code there; confirm the three hooks are listed under `/hooks` |
| Hooks still silent, on Windows | No bash on `PATH` for the `"shell": "bash"` invocation | Install Git for Windows and confirm `bash --version` works in the shell you launch Claude Code from |
| `vault-lint: jq not found; path parsing is degraded` | `jq` is missing — expected on a stock Git for Windows | Install jq (step 1). The hook keeps working, less reliably, until you do |
| `INVISIBLE-CHAR SCAN DID NOT RUN (no perl, no grep -P)` | Neither scanner is available on this machine | Install perl. Do **not** treat earlier "clean" lint lines from that machine as evidence — they were unscanned |
| Dataview tables in `VAULT-INDEX.md` show as code blocks or raw text | Dataview installed but not enabled, or not installed at all | Settings → Community plugins → enable **Dataview**, then reload Obsidian |
| A new note renders `{{project}}` / `{{concept}}` / `{{file_name}}` literally | Core Templates does not support those placeholders | Fill them by hand, or install Templater and adapt the syntax (step 5) |
| `vault-check: 0 violation(s) across 0 file(s)` | The checker scanned nothing — **this is not a pass** | Check `CLAUDE_PROJECT_DIR`, and that the `TIERS=` line in the script still names folders that exist. Add a note and re-run until the file count is non-zero |
| `vault-check: no content-tier folders found under ...` | Wrong working directory, or the tier folders were renamed | Run from the vault root, or finish the rename everywhere (see below) |
| `run-tests.sh` fails only on a path containing spaces | A word-splitting regression in a local edit | Revert the edit; the suite builds fixtures under a directory named with a space specifically to catch this |
| Scheduled agent "succeeded" but nothing changed | On Windows, the exit code was swallowed by `%ERRORLEVEL%>>`; or the run hung because `-p` was missing | Apply both fixes in step 8, and judge health by the log file rather than by `State` |

### One more, because it is the template's biggest customization cost

**Renaming a tier folder is a multi-file edit, not a rename.** The folder names are independently
hardcoded in:

- `CLAUDE.md`
- `.claude/hooks/vault-lint.sh`
- `.claude/hooks/postcompact-wrap-up.sh`
- `.claude/scripts/vault-check.sh`
- `.claude/agents/dream-agent.md`
- `.claude/rules/vault-notes.md`, `.claude/rules/verification.md`,
  `.claude/rules/untrusted-captures.md`
- `.obsidian/daily-notes.json`

Miss one and the failure is quiet in the worst direction: the lint hook stops recognising the
folder as a content tier and skips it, and `vault-check.sh` drops it from the scan list — so both
report clean about a tier neither one looked at. If you rename, grep for the old name across the
whole repo afterwards and re-run step 7, watching the **file count**, not the violation count.
