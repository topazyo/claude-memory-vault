# Setup

This guide takes you from a fresh clone to a working vault: Obsidian open, your coding-agent
harness wired in (Claude Code in § 6, any other harness in § 6a), and (the part that matters) a
verified install, where you have proof the checkers ran rather than a reassuring silence.

The whole thing takes about fifteen minutes. Steps 1–3, 6 and 7b are required. Steps 4, 5 and 8
are optional and can be skipped without breaking anything, and so is the control suite in § 7a,
which runs for about 10 minutes on Linux, 12 to 17 on macOS and about an hour on Windows.

---

## 1. Prerequisites

| Tool | What it is for | Required? | Check it is present |
| --- | --- | --- | --- |
| **Obsidian** | Reads the vault, renders the Dataview dashboards, draws the graph | Required to *use* the vault as a human; an agent alone does not need it | Launch it; Help → About shows the version |
| **A coding-agent harness** | Writes and promotes notes. Claude Code runs the hooks, skills and subagents automatically; any other harness that reads `AGENTS.md` follows the same contract (§ 6a) | Required | e.g. `claude --version` |
| **bash** | Every hook and script is a bash script. macOS and Linux have it; on Windows it comes with Git for Windows | Required | `bash --version` |
| **git** | Cloning the template, and the commits the runners make of each pass's notes, which are what make an unattended pass's writes revertible | Required | `git --version` |
| **jq** | Parses the JSON a harness pipes into the lint hook | Strongly recommended | `command -v jq` |
| **perl** | Runs the invisible-character (zero-width / bidi) scan in the lint hook | Strongly recommended | `command -v perl` |
| **cmp**, **iconv** | A claude-mode dream or promotion pass reads its memory override file back with `cmp`, and checks a vault or settings-file path with a byte outside printable ASCII with `iconv`. Without `cmp` every claude-mode pass refuses to start; without `iconv`, only one whose vault or settings-file path holds a byte outside printable ASCII | `cmp` required for scheduled passes in claude mode, `iconv` for a path outside printable ASCII. Git for Windows and macOS ship both; on Linux they come with diffutils and the C library's tools on most distributions | `command -v cmp iconv` |

### About jq on Windows

**Git for Windows does not bundle `jq`.** This surprises people, because Git Bash ships a fairly
complete little userland otherwise.

Without `jq`, `vault-lint.sh` falls back to a `sed` parse of the hook's JSON payload to find the
file path. The fallback works for ordinary paths, but it is a single regex against a JSON blob and
it will mis-parse paths containing quotes or escapes. The hook does not hide this. Every degraded
run writes a `DEGRADED:` line to `.claude/logs/vault-lint.log` and prints a warning to stderr.

Install it if you can:

```bash
winget install jqlang.jq        # Windows
brew install jq                 # macOS
sudo apt install jq             # Debian / Ubuntu
```

### About perl and `grep -P`

The lint hook scans written notes for zero-width and bidirectional-control codepoints, the
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

With those lines active, your notes stay on disk and out of every pull request, including notes in
subfolders. The last line re-includes the `templates/` folders, so the templates still travel with
the repo. Confirm with `git status --ignored` before your first push.

This is a one-way door in practice: once note content has been pushed to a public repo,
a pull-request diff of it is stored by GitHub under refs nobody can rewrite. Decide before your
first push, not after.

---

## 3. Open it as an Obsidian vault, and install Dataview

1. Open Obsidian → **Open folder as vault** → select `<your-vault>`.
2. Obsidian will read the checked-in `.obsidian/` config: the tier-coloured graph, and
   the list of community plugins the vault expects.
3. Go to **Settings → Community plugins**, turn off Restricted Mode if prompted, and install
   **Dataview**. Then **enable** it. Installing is not enabling, and this catches people.

   Restricted Mode exists for a reason: community plugins run code with the same access to your
   files as Obsidian itself. Install only the plugins you have decided to trust. Dataview is the
   one this vault needs.

**Dataview is required.** Every dashboard in `30-knowledge/moc/VAULT-INDEX.md` and
`30-knowledge/moc/PROJECT-INDEX.md` is a Dataview query. Until the plugin is enabled, those notes
render as empty code blocks or as raw query text. They are not broken; they are unpowered.

Restart Obsidian (or use **Reload app without saving**) after enabling, then open `VAULT-INDEX.md`
and confirm you see tables rather than code fences.

---

## 4. Optional: the graph plugins

`.obsidian/community-plugins.json` also lists three optional graph plugins:
`folders2graph`, `three-d-graph-view`, and `extended-graph`. They change how the vault's link
graph is drawn: folder nodes, a 3-D view, and extended styling respectively. Nothing in the
system depends on them; skip them if you want a lean install.

What *is* worth keeping either way is `.obsidian/graph.json`, which defines four colour groups
keyed on tags that the templates seed:

| Group query | Meaning |
| --- | --- |
| `tag:#tier/short` | Daily notes and inbox captures — the cheap, high-volume tier |
| `tag:#tier/medium` | Project session logs — the promotion pipeline's input |
| `tag:#tier/long` | Standards, index notes and other long-term material — the small, verified tier |
| `tag:#llm/wiki` | Wiki entities and the wiki index, which carry both `tier/long` and `llm/wiki` |

The practical effect is that the core graph view shows you your tier distribution at a glance. A
graph that is overwhelmingly short-tier colour means capture is happening but promotion is not.
That is the failure mode this system exists to make visible.

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
folder, while this layout deliberately co-locates a `templates/` folder inside each tier. So
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

The only requirement is that **the vault is the project directory**. Start Claude Code from
`<your-vault>`:

```bash
cd <your-vault>
claude
```

### What the hooks do

Two are registered in the shipped `.claude/settings.json`. The third is opt-in and the section
after this one turns it on.

| Hook | Fires on | What it does | Can it block you? |
| --- | --- | --- | --- |
| `vault-lint.sh` | `PostToolUse`, matcher `Write` or `Edit` | Checks the just-written note for the mandatory `tier:` and `type:` frontmatter, and scans it for zero-width / bidi codepoints. The character scan is widened to the files that steer an agent, such as `.claude/rules/`, the skills and any `AGENTS.md` or `CLAUDE.md` (the full list is in [`reference.md`](reference.md) §3.1), which are exactly what a rules-file backdoor targets. Logs to `.claude/logs/vault-lint.log`. | No — advisory, **always exits 0** |
| `postcompact-wrap-up.sh` | `PostCompact` | Writes one idempotent, size-capped stub per session into `20-projects/_logs/compaction-<session>.md`, so the material in a compacted context is still recoverable afterwards. Caps at 50 entries, and sanitizes the session id before building a path. | No |
| `instructions-loaded-log.sh` | `InstructionsLoaded`, session start only | Appends which instruction files loaded, to `.claude/logs/instructions-loaded.log`. This is how you answer "was that rule actually in context?" instead of guessing. **Opt-in: the shipped `settings.json` does not register it.** | No |

All of them write only into `.claude/logs/` (gitignored) or into `20-projects/_logs/`. None of them
edits an existing note. None of them runs inside a claude-mode dream or promotion pass, which the
runner starts with every hook but managed ones turned off (measured for the vault's and plugins'
hooks; for the account's own user-level hooks, reasoned).

### Turning the instruction-load audit on

The logger is not registered by default. It fires once per instruction file at session start, and
each firing is a process, so a vault that never reads the log pays for it at the start of every
session. Nothing else depends on it, and turning it on later costs nothing that was lost.

Turn it on in `.claude/settings.local.json`, which is gitignored, so the choice stays yours and no
pull request carries it:

```json
{
  "hooks": {
    "InstructionsLoaded": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PROJECT_DIR}/.claude/hooks/instructions-loaded-log.sh\"",
            "shell": "bash",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

Start a new session and read `.claude/logs/instructions-loaded.log`. One line per instruction file
means it is working. The script itself is unchanged and still ships in `.claude/hooks/`, so this is
the only step.

The five skills in `.claude/skills/` — `obsidian-save`, `wrap-up`, `resume`, `preserve` and
`onboard-project` — are picked up automatically from the project directory; there is no
registration step.

`.claude/settings.json` also carries `permissions.deny` rules for `Read(./.env)`, `Read(./.env.*)`
and `Read(./secrets/**)`. They apply immediately, without a trust prompt.

---

## 6a. Wiring any other harness

**Start with your harness's guide in [`docs/harnesses/`](harnesses/README.md).** The template ships
config for Codex CLI, Gemini CLI, Cursor, GitHub Copilot, OpenCode, Windsurf / Devin Desktop and
Aider, plus opt-in extensions for Pi and Oh My Pi and a snippet for Hermes Agent. Each guide gives the
one-time setup and an onboarding prompt whose checks prove the hooks fire. The steps below are the
harness-independent version, for a harness without a guide.

Everything the vault asks of an agent is in `AGENTS.md`, and every checker is a bash script that
does not care which harness wrote the note. What a non-Claude harness does not get for free is the
automation: nothing loads the rules for it, nothing runs the lint after it writes, and nothing
enforces a Read deny. Wire in what your harness supports, then rely on the commit gate for the
rest. [`AGENTS.md` § 8](../AGENTS.md#8-harness-support) is the side-by-side table.

1. **Load `AGENTS.md`.** Start the harness with `<your-vault>` as its working directory. Many
   harnesses read a root `AGENTS.md` on their own. If yours reads a different file by default,
   point its context-file setting at `AGENTS.md`, or put a one-line pointer to `AGENTS.md` in the
   file it does read. Check the harness's own documentation for the setting name; it varies
   between tools and between versions. Confirm it worked by asking the agent what the four
   non-negotiable rules are before it writes anything.

2. **Rules.** `AGENTS.md` instructs the agent to read all four `.claude/rules/*.md` files before
   its first write. Nothing loads them automatically outside Claude Code, so this instruction is
   the control. If your harness has its own always-loaded rules mechanism, pointing it at
   `.claude/rules/security.md` and `.claude/rules/untrusted-captures.md` is worthwhile.

3. **The commit gate.** This is the one mechanical check that works in every harness, and with no
   harness at all:

   ```bash
   git config core.hooksPath .claude/githooks
   ```

   Every commit then runs `vault-check.sh` and is refused if any note violates C1–C5. Two cautions:
   `core.hooksPath` replaces `.git/hooks`, so copy any hook you already depend on (git-lfs installs
   several) into `.claude/githooks/` first; and the gate reads the working tree, so an unstaged bad
   note blocks a commit too.

4. **The lint, if your harness has a post-write hook.** `vault-lint.sh` takes file paths as
   arguments and never reads stdin when it has them, so it can be called from any hook, editor
   task or script:

   ```bash
   bash .claude/hooks/vault-lint.sh path/to/note.md [more.md ...]
   ```

   If the harness pipes JSON instead, the hook reads a `file_path` (or `path`) field, either
   nested under `tool_input` or at the top level. It always exits 0 and logs to
   `.claude/logs/vault-lint.log`.

5. **Skills.** The five skills are Markdown procedures. Where your harness supports the Agent
   Skills `SKILL.md` format, point it at `.claude/skills/`; otherwise ask the agent to open
   `.claude/skills/<name>/SKILL.md` and follow it. Frontmatter keys such as `allowed-tools` are
   Claude Code's and can be ignored elsewhere.

6. **Secrets.** The Read deny in `.claude/settings.json` is enforced by Claude Code alone. If your
   harness has an ignore or deny list, add `.env`, `.env.*` and `secrets/**` to it. If it has
   none, `.claude/rules/security.md` is guidance only, and you should know that.

Scheduling the dream and promotion passes under another harness is covered in § 8, under
*Running the passes with another harness*.

---

## 7. Verify the install

This section is the point of the whole guide. Run § 7b, and § 7a when you have the time it takes,
and read the output carefully.

### 7a. The control suite

```bash
bash .claude/scripts/run-tests.sh
```

Expect a list of `PASS` lines, an informational dependency block, and a final
`=== N passed, 0 failed ===`. Exit code 0. It takes about 10 minutes on Linux, 12 to 17 on macOS
and about an hour on Windows, measured on GitHub's runners, and prints each result as it lands, so
a long run is not a hang.

This suite is not decorative. It pairs **known-bad inputs that must be flagged** with **known-good
inputs that must stay silent**: it feeds the lint hook a file containing a known U+200B and a known
U+202E and asserts the hook *catches* them, before trusting any "clean" result from it. It also
runs the hooks' no-jq fallback and both scheduled runners against a fake `claude`, and builds its
fixtures inside a directory whose name contains a space, because a path like `/Users/Some One/...`
is what breaks word-splitting bugs while still printing a reassuring "0 violations".

The dependency block at the end tells you, in plain language, whether `jq` and `perl` were found.
If it says `MISSING perl and grep -P`, your invisible-character scan cannot run. Go back to
step 1.

### 7b. The frontmatter checker

```bash
bash .claude/scripts/vault-check.sh
```

Do **not** pipe this into `less`, `head`, or `tail` if you plan to read `$?` — a pipeline reports
the last command's status, not the checker's.

It validates five invariants across the content tiers (`01-inbox`, `10-daily`, `20-projects`,
`30-knowledge`, `31-standards`, `40-llm-wiki`), skipping a `templates/` folder inside a tier and
the `compaction-*.md` stubs directly in `20-projects/_logs/` (`docs/reference.md` §4.1 has the
scope and how links are treated):

| ID | Invariant |
| --- | --- |
| C1 | First line is a bare `---` fence |
| C2 | Frontmatter has a `tier:` key |
| C3 | Frontmatter has a `type:` key |
| C4 | If both exist, `last_verified` is not earlier than `created`; `created` is a `YYYY-MM-DD` date |
| C5 | `last_verified` is not in the future, and is a `YYYY-MM-DD` date |

It is **report-only**: it never writes, stamps, or repairs, and it exits 1 when any note violates
an invariant so you can gate a pass on it. Repair is a human act.

A full scan looks like this:

```
vault-check: 0 violation(s) across 9 file(s) checked (as of 2026-01-01).
vault-check: 99-archive/ holds 0 note(s) on disk.
vault-check: No retention pass is in this repository's history.
vault-check: This vault records template version X.Y.Z. Run bash .claude/scripts/vault-update.sh --status for what has changed since, and see docs/updating.md for where to fetch a newer release.
```

The count is the line to read. The three after it report rather than judge, and none of them
changes the exit code. Two of them say what the retention pass has taken out of the live tiers, so
an archived vault can be told apart from one that lost notes. The last names the template version
this vault was created from. See `docs/reference.md` § 4.3.1 and
[`updating.md`](updating.md).

### The one output you must not misread

> **`0 violation(s) across 0 file(s)` is NOT a pass.** It means the checker scanned nothing, so the
> script also prints `VACUOUS` to stderr and exits 2. That code means this checker could not run,
> and it is deliberately not the 1 that means a note is wrong.

Zero findings from an instrument that examined zero inputs is indistinguishable from zero findings
from an instrument that examined everything. That is why the file count is printed at all. `vault-check.sh` resolves the vault from its **own location** (`$(dirname "$0")/../..`) unless
`CLAUDE_PROJECT_DIR` overrides it, so calling it by an absolute path from anywhere works fine. A
zero file count therefore usually means `CLAUDE_PROJECT_DIR` points somewhere else, or the
content tiers genuinely hold nothing but templates, or a tier folder was renamed without
updating the `TIERS=` line in the script.

On a fresh clone the five `EXAMPLE-*.md` notes already live in their tiers, so the expected
output is `0 violation(s) across 9 file(s) checked`. That non-zero count **is** your positive
control for the checker. Once you delete the examples with `find . -name 'EXAMPLE-*.md' -delete`,
create a throwaway note by hand before re-running, or the count drops back toward zero and the
result becomes vacuous again.

---

## 8. Optional: scheduling the dream and promotion agents and the retention pass

Two agents are defined in `.claude/agents/`, and there is a third scheduled pass that is not an
agent. Scheduling any of them is optional. The vault works fine driven only by `/obsidian-save`
and `/preserve` during ordinary sessions.

| Pass | Cadence | What it writes |
| --- | --- | --- |
| `dream-agent` | Nightly, if you want it | **One** dated dream-journal file. Nothing else, ever. |
| `promotion-agent` | Weekly | **Creates notes** in `31-standards/` and `40-llm-wiki/wiki/`, never changes one already there, and proposes such changes in a `20-projects/_logs/promotion-*.md` report |
| `vault-retention.sh` | Weekly, after the other two | **Writes no content.** Moves aged dream journals and compaction stubs from `20-projects/_logs/` into `99-archive/20-projects/_logs/` |

The retention pass is the safest of the three to leave unattended, and for a different reason from
the other two. It writes nothing at all. It only moves files git can prove a machine wrote and
nobody has edited since, it never renames one or touches its frontmatter, and each run is a single
commit you can revert. Run it with `--dry-run` first to read its judgement before it moves
anything.

The dream-agent is safe to run unattended because it proposes rather than executes: its
only write is a new file at a predictable path, so a pass that misreads something cannot corrupt
anything, and its runner fails the pass if any other file changed. **The promotion-agent is
different, because it writes into your long-term tier.** It has no shell. Its runner commits the
notes of a clean pass and puts back the notes of a pass that fails the check, so a bad pass is
reversible, and it fails a pass that writes outside `31-standards/`,
`40-llm-wiki/wiki/` or a `20-projects/_logs/promotion-*.md` report. Still, read
`.claude/agents/promotion-agent.md` in full before you put it on a timer, and run it manually a
few times first.

### Linux — cron

Use the shipped runners. They resolve the vault from their own location, guard for a `claude`
binary that a scheduler's minimal PATH cannot see, log to `.claude/logs/`, kill a pass that hangs,
fail a pass that writes outside its allowed folders, and (the part that matters) assert that the
pass actually produced something. Exit codes are `0` OK, `1` no artifact, `2` a write outside the
fence or another refusal (`docs/reference.md` § 4.3), `3` refused (see below), `64` unknown `VAULT_AGENT`, `124` timeout, `125` stalled, `127` no
`claude` or wrapper. `docs/reference.md` § 4.3 has the full table.

`vault-retention.sh` uses some of the same numbers for different things, so read its codes against
its own table in `docs/reference.md` § 4.3.1 rather than the list above. It has no `124` or `125`,
because it runs no agent.

```cron
# dream pass, nightly at 02:30
30 2 * * *  /path/to/your-vault/.claude/scripts/dream-pass.sh
# promotion pass, Sundays at 03:30
30 3 * * 0  /path/to/your-vault/.claude/scripts/promotion-pass.sh
# retention pass, Sundays at 04:30, after the promotion pass
30 4 * * 0  /path/to/your-vault/.claude/scripts/vault-retention.sh
```

The retention line has no redirect on purpose. The retention runner prints what it logged as it ends
(`docs/reference.md` § 4.3.1), so on a machine where cron can send mail it mails you its judgement
every week, and a run that could not start mails its reason rather than nothing (§ 4.3.1 has the
exceptions). That mail carries note names, paths and refusal reasons from your vault, git's own
error text, any commit-message text git reports, and the value of any setting it warns about. If your cron mail leaves the machine and
you do not want that, end the line with `>/dev/null` and read `.claude/logs/vault-retention.log`
instead. § 4.3.1 says where else the output may go, and why never into that log.

Give the retention pass a slot after the other two rather than beside them. All three take the same
run lock, so an overlap costs one of them a wait of up to `RUN_LOCK_WAIT` and then exit 75.

If `claude` is not on the PATH cron gives you (it usually is not, since cron runs no login
profile), set `CLAUDE_BIN` to the full path in the crontab. The watchdog limits are environment
variables too: `DREAM_PASS_TIMEOUT` (default 3600 seconds) and `PROMOTION_PASS_TIMEOUT` (default
5400). Set them the same way, as `NAME=value` lines above the entries, if a pass legitimately needs
longer. `RETENTION_DAYS` (default 60) and `RETENTION_MAX_MOVES` (default 50, and 50 is also the
most it will accept) belong in the same place when the retention pass's own defaults do not suit
the vault. A claude-mode pass whose output stops for the stall threshold is stopped sooner, with exit
125. The threshold is 10 minutes until three passes that ended OK are measured, then 1.5 times the
longest silence those passes usually have, and never below 10 minutes. Each run logs it.
`RUNNER_STALL_SECONDS` sets it outright, and turns stall detection on for a command-mode wrapper
too. `RUNNER_STALL_FLOOR` changes the 10-minute floor.

**Why not call `claude` directly from cron?** Two reasons. The agent is selected with the
`--agent <name>` *flag*, not by putting a slash command in the prompt, so a hand-rolled line is
easy to get subtly wrong. And a direct call has no artifact assertion: the runners exit 1 when a
pass exits 0 having written nothing, which is the only thing that distinguishes "ran and had
nothing to do" from "did not run at all". Without it, a broken schedule looks green indefinitely.

### Running the passes with another harness

The runners start Claude Code by default (`VAULT_AGENT=claude`). To use any other harness, write a
small wrapper script and select command mode:

```bash
VAULT_AGENT=command
VAULT_AGENT_CMD=/path/to/your-vault-agent-wrapper.sh
VAULT_ALLOW_UNENFORCED_TOOLS=1   # only after the sandbox below exists
```

The runner calls the wrapper from the vault root with **one argument**: the relative path of a
prompt file (`.claude/logs/dream-pass.prompt.md` or `.claude/logs/promotion-pass.prompt.md`). The
file holds the agent's instructions, taken from `.claude/agents/<name>.md` without its frontmatter,
followed by this run's task. The wrapper's job is to run your harness non-interactively on that
prompt and exit. Start the harness with `exec`, as the skeleton does: the watchdog signals the
wrapper's own process, so a harness left running as a child would survive a timeout and keep
writing after the fence has been checked. A skeleton, with the harness line left for you to fill
from its documentation:

```bash
#!/usr/bin/env bash
# your-vault-agent-wrapper.sh <prompt-file>
set -u
prompt_file="$1"
# Replace with your harness's one-shot, non-interactive invocation. It must not wait for input
# (stdin is /dev/null), and it must run inside the sandbox described below.
exec your-harness-cli <its-non-interactive-flag> "$(cat "$prompt_file")"
```

Keep the wrapper, the container definition and every file they name (a profile, a config, a settings
copy) outside the vault and outside every folder a pass can write: the runner starts what
`VAULT_AGENT_CMD` names (the wrapper, or the command that starts its container) outside every
sandbox, and several guides' switches live in those files.

A Windows batch wrapper receives the same forward-slash relative path, which cmd built-ins such
as `type` read as a switch. Expand it to an absolute path first, with `%~f1`.

Do not use `CLAUDE_BIN` to run another harness. It must name the Claude Code binary: pointing it
at a different CLI keeps claude mode, which skips the refusal below while enforcing nothing. Nor
wrap Claude Code itself in command mode: such a wrapper gets no memory override and no
`CLAUDE_CODE_DISABLE_AUTO_MEMORY`, so Claude Code keeps granting its memory folder, outside the vault
by default, as in 1.4.0, and no hook switch, so the hooks in the account's settings, in enabled
plugins and in the vault's own settings stay on, where claude mode turns them off (the account's
own reasoned, the others measured).

**Why command mode refuses to run until you opt in.** Under Claude Code, each agent's `tools:`
list is enforced. Neither agent has a shell or web tools, and the runner commits the promotion
agent's notes for it. A wrapper cannot enforce that list, and the runner's snapshot fence only sees files that
change inside the vault. It cannot see a shell command, network traffic, or a write outside the
vault. So until `VAULT_ALLOW_UNENFORCED_TOOLS=1` is set, a command-mode run is refused with exit
`3` and a `REFUSED` line in the log, and the agent never starts. Set the variable only after you
have configured your harness's own sandbox or approval settings so that the **dream pass** and
the **promotion pass** alike:

- cannot run shell commands, `git` included
- cannot reach the network
- can write only inside the vault
- run no hook, and can write nothing that turns one on. Each hook the vault ships runs a script
  inside the vault, so a pass that changed the script would get a shell through the next hook,
  whatever its shell tool says (reasoned). `docs/harnesses/README.md`, "No vault hook in a
  scheduled pass", says how to turn them off, gives a check that the vault's hook scripts do not
  run, and says what the rest rests on.
- where the harness itself can run git during a pass, which you should assume of every harness,
  cannot write the vault's `.git`, or, with the commit gate on, its `.claude/`, which hold the class
  the `UNVERIFIED` troubleshooting row below names (reasoned). `docs/harnesses/README.md`, "No vault
  hook in a scheduled pass", says which recipes mount both read-only, and how to confirm (for both
  folders either way, since the gate can be turned on later) that they refuse a pass's writes.

Once opted in, every run still logs a `WARNING` line saying the allowlist is not enforced by the
runner. The write fence, the watchdog and the artifact assertion work exactly as they do under
Claude Code. One consequence of the fence: a harness that keeps its own session or state files
inside the working directory fails every run with exit `2`, naming those files. Configure the
harness to keep that state elsewhere. Do not widen the fence to make it pass.

### macOS — launchd (use this, not cron)

On macOS prefer `launchd`. It runs a missed job when the machine wakes, whereas cron skips
it. On modern macOS, cron also cannot read a vault in `~/Documents`, `~/Desktop` or
iCloud Drive unless you grant **Full Disk Access** to `/usr/sbin/cron` in System Settings →
Privacy & Security. A cron job that silently reads nothing is the failure this project
argues against, so use launchd.

Put both files in `~/Library/LaunchAgents/`. Replace `/Users/YOU/Vaults/my-vault` with your
vault's **absolute** path. launchd does not expand `~`, and a job whose paths contain a tilde
never runs.

`~/Library/LaunchAgents/com.claude-memory-vault.dream-pass.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude-memory-vault.dream-pass</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/YOU/Vaults/my-vault/.claude/scripts/dream-pass.sh</string>
  </array>

  <key>WorkingDirectory</key>
  <string>/Users/YOU/Vaults/my-vault</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/Users/YOU/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>CLAUDE_BIN</key>
    <string>/Users/YOU/.local/bin/claude</string>
    <key>HOME</key>
    <string>/Users/YOU</string>
  </dict>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>2</integer>
    <key>Minute</key><integer>30</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>/Users/YOU/Vaults/my-vault/.claude/logs/dream-pass.launchd.out</string>
  <key>StandardErrorPath</key>
  <string>/Users/YOU/Vaults/my-vault/.claude/logs/dream-pass.launchd.err</string>

  <key>RunAtLoad</key>
  <false/>
  <key>ProcessType</key>
  <string>Standard</string>
</dict>
</plist>
```

The promotion runner's plist is identical except for these keys (weekly on Sunday rather than
nightly):

```xml
  <key>Label</key>
  <string>com.claude-memory-vault.promotion-pass</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/YOU/Vaults/my-vault/.claude/scripts/promotion-pass.sh</string>
  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key><integer>0</integer>
    <key>Hour</key><integer>3</integer>
    <key>Minute</key><integer>30</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>/Users/YOU/Vaults/my-vault/.claude/logs/promotion-pass.launchd.out</string>
  <key>StandardErrorPath</key>
  <string>/Users/YOU/Vaults/my-vault/.claude/logs/promotion-pass.launchd.err</string>
```

The retention runner's plist differs in the same few keys, and it needs no `CLAUDE_BIN` because it
starts no agent:

```xml
  <key>Label</key>
  <string>com.claude-memory-vault.vault-retention</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/YOU/Vaults/my-vault/.claude/scripts/vault-retention.sh</string>
  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key><integer>0</integer>
    <key>Hour</key><integer>4</integer>
    <key>Minute</key><integer>30</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>/Users/YOU/Vaults/my-vault/.claude/logs/vault-retention.launchd.out</string>
  <key>StandardErrorPath</key>
  <string>/Users/YOU/Vaults/my-vault/.claude/logs/vault-retention.launchd.err</string>
```

What the retention runner prints as it ends goes to `vault-retention.launchd.out`, one block per
run, in the form `docs/reference.md` § 4.3.1 describes. The blocks carry no date, so the log is
where to see when each ran.

`Weekday` 0 is Sunday; omit the key entirely for a daily job.

Load them:

```bash
mkdir -p ~/Library/LaunchAgents "/Users/YOU/Vaults/my-vault/.claude/logs"
chmod 644 ~/Library/LaunchAgents/com.claude-memory-vault.dream-pass.plist
plutil -lint ~/Library/LaunchAgents/com.claude-memory-vault.dream-pass.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude-memory-vault.dream-pass.plist
launchctl enable  gui/$(id -u)/com.claude-memory-vault.dream-pass
```

Three things that will otherwise cost you an evening:

- **launchd creates the log file, not its directory.** `StandardOutPath` and `StandardErrorPath`
  are opened before your script runs, so the `.claude/logs/` directory must already exist, hence
  the `mkdir -p` above. The runners leave these six `.launchd.out` and `.launchd.err` names out
  of their write fence. A file of any other name that appears in `.claude/logs/` during a pass
  is contained as a planted file, so keep these names if you rename the jobs.
- **The plist must be mode 0644 and owned by you**, or `bootstrap` fails with
  `Path had bad ownership/permissions`.
- **A launchd job gets a minimal PATH and no login shell**, so a bare `claude` will usually not be
  found. That is what the `CLAUDE_BIN` entry above is for. Find the right value with
  `command -v claude` in a normal Terminal window and paste the absolute path in. The watchdog
  limits `DREAM_PASS_TIMEOUT` and `PROMOTION_PASS_TIMEOUT` (seconds) go in the same
  `EnvironmentVariables` dictionary if a pass needs longer than the defaults.

Run it once by hand, while logged in, before trusting the schedule:

```bash
launchctl kickstart -p gui/$(id -u)/com.claude-memory-vault.dream-pass
```

Then check `.claude/logs/dream-agent.log` for a timestamped line. As on Windows, the presence of a
log line is the evidence. A job that launchd lists as loaded has not necessarily ever run.


### Windows — Task Scheduler, and three traps that will cost you a week

Schedule the shipped `.cmd` files, not `claude` directly. Each is a thin wrapper that runs the
matching `.sh` runner through Git Bash, so the watchdog, write fence and artifact assertion are the
same code as on macOS and Linux. Some steps are Windows-only: a stopped pass's processes are looked
up through PowerShell, and Git Bash's `cygpath` converts paths between Git Bash and Windows forms.
The memory override converts its paths under a UTF-8 locale and checks them, so its settings file
names a vault under a non-ASCII folder correctly, and it refuses a vault on a `//` network path:
for one reached as `//localhost/c$/...` (this host's own administrative share) or
`//wsl.localhost/...`, Claude Code 2.1.289 and 2.1.292 did not honour the file (measured; other
versions, and a share on another server, unmeasured) (the
`.cmd` files cannot start such a vault at all: `cmd.exe` refuses a `//` current folder). The state
directory's path and other path checks are still converted under the runners' `C` locale, so an
account whose name is not ASCII needs `VAULT_STATE_DIR` (see Troubleshooting). Each `.cmd` looks for
Git Bash in the standard Git for Windows locations and never searches `PATH`, because
`C:\Windows\System32\bash.exe` is WSL; set `BASH_EXE` if yours is elsewhere. `CLAUDE_BIN` and the
timeout variables pass through from the task's environment.

```bat
schtasks /create /tn "Vault-DreamAgent" /tr "\"C:\path\to\your-vault\.claude\scripts\dream-pass.cmd\"" /sc daily /st 23:00
schtasks /create /tn "Vault-PromotionAgent" /tr "\"C:\path\to\your-vault\.claude\scripts\promotion-pass.cmd\"" /sc weekly /d SAT /st 20:00
schtasks /create /tn "Vault-Retention" /tr "\"C:\path\to\your-vault\.claude\scripts\vault-retention.cmd\"" /sc weekly /d SUN /st 04:00
```

Arguments pass through the retention wrapper, so a task that runs
`vault-retention.cmd --dry-run` is a good way to watch its judgement for a few weeks before you
let it move anything. Task Scheduler discards what the runner prints, so read that judgement in
`.claude/logs/vault-retention.log`.

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

Make the task's limit longer than everything the runner can spend before it exits on its own:
the wait for the run lock (`RUN_LOCK_WAIT`, default 30 minutes), the pass's own timeout, the
watchdog's grace period, about a minute to stop the pass's process tree and check that it is gone,
and two git steps of `RUNNER_GIT_TIMEOUT` (default 2 minutes each), each with its own grace period,
to commit the pass's notes, plus a margin. Then the runner always kills a hung pass first, logs
`TIMEOUT` with exit 124 or `STALLED` with exit 125, and releases its lock, unless the stop reports
`KILL_FAILED` (see Troubleshooting). A limit shorter than that lets Task Scheduler end
the runner mid-pass with no cleanup, which leaves its lock and in-flight marker behind. The next run
then reclaims the lock after it goes stale and sets the tripwire. Change the existing task object
rather than building new settings (`New-ScheduledTaskSettingsSet` resets every setting you do not
name), then read the definition back, because a success from `Set-ScheduledTask` is not evidence
the change landed:

```powershell
$task = Get-ScheduledTask -TaskName 'Vault-DreamAgent'
$task.Settings.ExecutionTimeLimit = 'PT2H'   # lock wait 30 min + DREAM_PASS_TIMEOUT 60 min + margin
Set-ScheduledTask -InputObject $task | Out-Null
(Get-ScheduledTask -TaskName 'Vault-DreamAgent').Settings |
  Select-Object ExecutionTimeLimit, MultipleInstances
```

Repeat for `Vault-PromotionAgent` with a limit above the lock wait plus `PROMOTION_PASS_TIMEOUT`
(default 90 minutes), for example `PT2H30M`.

`Vault-Retention` has no `*_PASS_TIMEOUT`, because it runs no agent, so its limit is derived from
its git steps instead. A run that goes well spends the wait for the run lock (`RUN_LOCK_WAIT`,
default 30 minutes) and then a handful of watched git steps at `RUNNER_GIT_TIMEOUT` each (default
2 minutes) — the history walk, two batched lookups, one `git mv` for the whole move set, and the
commit. The expensive case is a move that fails and has to be put back, which walks the files back
one at a time, up to `RETENTION_MAX_MOVES` steps of `RUNNER_GIT_TIMEOUT`. At the defaults that
worst case is 30 + 12 + 100 minutes, so `PT2H30M` covers it with margin. Lowering
`RETENTION_MAX_MOVES` lowers the worst case directly, and is the right move on a vault where you
would rather archive in small batches anyway. A limit shorter than the run leaves the lock behind,
and, when it stops the run while files are moving, the `retention-inflight` recovery file too. The
next run then refuses with exit 78 until the vault matches what that file describes.

**Trap 3 — judging health by `State`.** Task health is `LastTaskResult` **plus a log file on
disk**, never `State`. A task can sit at `Ready` for weeks while every run dies on startup.
If `.claude/logs/dream-agent.log` has no new lines, the task is not working, whatever the UI says.

### Removing it

Scheduling is the only part of the vault that lives outside the folder, so remove it first.

```bash
# Linux: delete the three runner lines
crontab -e

# macOS: unload the jobs, then delete their plists
launchctl bootout gui/$(id -u)/com.claude-memory-vault.dream-pass
launchctl bootout gui/$(id -u)/com.claude-memory-vault.promotion-pass
launchctl bootout gui/$(id -u)/com.claude-memory-vault.vault-retention
rm ~/Library/LaunchAgents/com.claude-memory-vault.dream-pass.plist \
   ~/Library/LaunchAgents/com.claude-memory-vault.promotion-pass.plist \
   ~/Library/LaunchAgents/com.claude-memory-vault.vault-retention.plist
```

```bat
schtasks /delete /tn "Vault-DreamAgent" /f
schtasks /delete /tn "Vault-PromotionAgent" /f
schtasks /delete /tn "Vault-Retention" /f
```

To stop any harness using the vault's hooks, skills, agents and rules, delete the `.claude/`
folder, and run `git config --unset core.hooksPath` if you enabled the commit gate. That also
removes `.claude/logs/`. Your notes are plain Markdown and are untouched.

---

## A tripwire is set

A scheduled pass sets the **tripwire** when it changed a steering or execution surface, was stopped
before its changes were checked, or may have left a process running. While it is set, the dream,
promotion and retention runners and `vault-check.sh` all exit **78** and do nothing else, until
you have done the steps below. Nothing clears it on its own. The background is in
[`reference.md` §4.3](reference.md).

Not this section: a retention run whose 78 comes with a log line that says `TRIPWIRE:` and names
`retention-inflight` in the state directory. That is the retention runner's own recovery record,
not a tripwire; follow "When a move goes wrong" in [`reference.md` §4.3.1](reference.md).

1. **Leave the vault alone until step 6.** Do not open it in Obsidian or in an agent session, and
   run no `git` command and no script from it, `vault-check.sh` included. When the pass was not
   contained, `.git/config`, `.git/hooks`, `.obsidian/` and the vault's own scripts may still hold
   what it wrote. Read files with `ls` and `cat` only, from a shell that does not start git in its
   prompt, and keep the folder out of any editor with git integration.

2. **Find both copies of the tripwire.** One is in the vault, the other in the runners' state
   directory outside it. From the vault root:

   ```bash
   ls -ld .claude .claude/logs .claude/logs/runner-tripwire
   # macOS and Linux, the default state directory (one folder per vault):
   ls -ld "${XDG_STATE_HOME:-$HOME/.local/state}"/claude-memory-vault/*/runner-tripwire
   # Windows, in Git Bash:
   ls -ld "$LOCALAPPDATA"/claude-memory-vault/*/runner-tripwire
   # the fallback under the temp folder (both cases below):
   ls -ld "${TMPDIR:-/tmp}"/claude-memory-vault-state-*/runner-tripwire
   ```

   These expand in your shell. If the scheduler gives the runners a different `XDG_STATE_HOME`,
   `VAULT_STATE_DIR`, `TMPDIR` or home folder, use the scheduler's values, or you will look in the
   wrong place and step 7 will leave the copy the runners read.

   If you set `VAULT_STATE_DIR` for the runners, the copy is `runner-tripwire` in that folder
   instead. Two cases use `claude-memory-vault-state-<id>` in `$TMPDIR` or `/tmp`: a refused
   `VAULT_STATE_DIR` (the log has a `WARNING: VAULT_STATE_DIR ... Using ... instead.` line naming
   the folder), and a task with no home folder set, which is not logged. With several vaults there
   is one folder per vault, named by a checksum of the vault's path, and the runner log in step 4
   names the one that belongs to this vault.

3. **Decide which copy to read, and read only that one.** Trust the **state directory's** copy when
   `ls -ld` shows it as a regular file (the line starts with `-`) with a link count of 1, because a
   pass cannot write there. Read it with `cat`. When the state directory holds no such copy, a pass
   may have written the vault's copy, and the vault's logs too, because the fence lets a pass write
   both. Read the vault's copy only under the same rule (a regular file with a link count of 1),
   but follow nothing in it: treat the tripwire as the "Nothing was moved or restored" shape in
   step 6, whatever the vault's copy and the vault's log say. A `runner-inflight` in the state
   directory means the same thing. A copy that `ls` shows as anything but a regular file (a link
   `l`, a folder `d`) holds no tripwire text: do not `cat` it, because a link can point at a file
   you would not want printed. If `.claude` or `.claude/logs`
   is listed as anything but a folder (`d`), the runners wrote no vault copy, and only the state
   directory's copy and the state directory's logs count.

4. **Check the tripwire against the runner log.** The log is `.claude/logs/dream-agent.log`,
   `promotion-agent.log` or `vault-retention.log`, or, when the tripwire or the log says the vault's
   log could not be used, `dream-pass.uncontained.log`, `promotion-pass.uncontained.log` or
   `vault-retention.uncontained.log` in the state directory. `ls -ld` it before you read it, as in
   step 3, because a link in its place is one of the things a pass can leave. The lines of the run
   that set the tripwire, above any later `TRIPWIRE: refusing to run` lines that each run since has
   added, give the same reason: `VIOLATION` with the paths that were contained,
   `INTERRUPTED before containment. Tripwire set.`, `UNVERIFIED:`, or `KILL_FAILED`. A log in the
   vault is evidence only alongside a state-directory copy, because a pass can write it: where the
   state directory's copy and a log in the vault disagree, the state directory's copy wins.

5. **If it says a process may still be running** (a `KILL_FAILED` stop), find the process the log
   lists and end it before anything else. On Windows it is a `claude` or `bash` whose command line
   holds the session id the log names. Until it has ended, anything you review can still change.

6. **Review the vault in the way the tripwire's shape asks.** Shapes can combine, so do every
   bullet that applies.
   - **It lists paths and a quarantine** (a contained pass). The runner moved what the pass wrote to
     those paths into the quarantine folder the tripwire names, in the state directory, and put the
     pre-pass files back. Read what is in the quarantine to see what the pass tried, and keep the
     folder. Two things were not put back: any path under `.git-common/` (a linked worktree's shared
     git folder, outside the vault) and anything in a `CONTAINMENT-ERROR` block. If the tripwire has
     either, check those by hand, as the next bullet does, before any git command. Then, where the
     vault is a git repository, check HEAD with `git --no-pager reflog`, because the runner never
     rewrites a commit back.
   - **It says "Nothing was moved or restored, because containment did not run"**, or the log has
     an `UNVERIFIED:` line. Nothing was put back, so check the steering surfaces before any git
     command: copy `inflight-backup.tar` out of the state directory first, because the next pass
     replaces it, unpack the copy into an empty folder with `tar -xf`, compare that folder with the
     vault using `diff -r` (add `--no-dereference` where your `diff` has it) and put back what
     differs. The backup holds only the steering surfaces, so `diff -r` also lists every note and
     other file as `Only in` the vault; those lines are expected. When the tripwire says no backup
     was made, check `.git/config`, `.git/hooks`, `.obsidian/` and `.claude/` by hand. Where `.git`
     is a file (a linked worktree), the git folder it names is outside the vault and the backup, so
     check its config and hooks by hand too. List every `.git` with `find . -name .git` and check
     the config and hooks of any you did not make. List every link under `.claude` with
     `find .claude -type l`, and remove any you did not make once you have checked what it names.
     Then, in a git vault,
     `git -c core.fsmonitor=false --no-pager status --ignore-submodules=all` shows the rest. The
     `78` row of the dream and promotion runners' exit table in
     [`reference.md` §4.3](reference.md) gives each of these in full.
   - **It says a process of the stopped pass may still be running** (`KILL_FAILED`). If it says
     "what it writes after containment is unchecked", containment ran and that process could have
     written after it; if it says only "what it writes is unchecked", containment did not run. In
     both cases, once step 5 has ended it, do the bullet above in full against the pre-pass backup,
     `inflight-backup.tar`, kept in the state directory for this review.
   - **The vault is not a git repository.** Do the comparison with the backup and skip every git
     command; there is no history to check.

7. **Delete exactly these, and nothing else:** both copies of `runner-tripwire`, the one in
   `.claude/logs/` and the one in the state directory. After a `KILL_FAILED` stop that marked the
   run lock, also delete the `run.lock` folder the log names in the state directory, or every
   later run exits 75. If the tripwire says the lock could not be marked, delete no lock folder: it
   may belong to a pass that is running. Keep the quarantine folder, the copy of
   `inflight-backup.tar` you made in step 6 (the next pass replaces the original) and the logs:
   they are the record of what happened, and no runner needs them gone. Leave `runner-inflight`
   alone if you find one; a runner turns it into a new tripwire, which means the review is not
   finished.

8. **Confirm it is cleared.** Now that the vault has been reviewed, run
   `bash .claude/scripts/vault-check.sh` with the scheduler's `VAULT_STATE_DIR`, if it sets one,
   since that is where it looks for the state directory's copy. It must not exit 78; it exits 0,
   1 with the notes it names, or 2 when it could not run. Then start a pass by hand rather than
   waiting for the schedule. Two leftovers can still stop it: a claude-mode pass exits 1 while
   `90-auto-memory/.pass-agent/` holds anything but `.DS_Store` (read what is there as data, then
   empty it), and a pass exits 75 on a git `index.lock` the stopped pass left (remove it once no
   git process is running, as the log's `WARNING:` line says).

---

## Troubleshooting

Start with **First failures** on a new setup: it holds the ten things a first install and a
first scheduled run most often meet. Otherwise look the exit code up in **By exit code**. The
`Exit` column is the first code the symptom names, so a row naming two codes sits under the first;
`—` marks a symptom with no exit code, a warning or nothing at all, and those rows come last.
Refusals that only an unusual setup reaches (a link, a non-ASCII or relative path, a `cygpath` that
cannot convert, a shared `TMPDIR`, a missing `tar`) are in
[`reference.md` § 10.1](reference.md#101-rare-runner-refusals).

### First failures

| Exit | Symptom | Likely cause | Fix |
| --- | --- | --- | --- |
| — | Hooks never fire; `.claude/logs/` stays empty or absent | Claude Code was started outside the vault, so `${CLAUDE_PROJECT_DIR}` points elsewhere | `cd <your-vault>` and start Claude Code there; confirm the three hooks are listed under `/hooks` |
| — | Hooks still silent, on Windows | No bash on `PATH` for the `"shell": "bash"` invocation | Install Git for Windows and confirm `bash --version` works in the shell you launch Claude Code from |
| — | `vault-lint: jq not found; path parsing is degraded` | `jq` is missing — expected on a stock Git for Windows | Install jq (step 1). The hook keeps working, less reliably, until you do |
| — | `INVISIBLE-CHAR SCAN DID NOT RUN (no perl, no grep -P)` | Neither scanner is available on this machine | Install perl. Do **not** treat earlier "clean" lint lines from that machine as evidence — they were unscanned |
| — | Dataview tables in `VAULT-INDEX.md` show as code blocks or raw text | Dataview installed but not enabled, or not installed at all | Settings → Community plugins → enable **Dataview**, then reload Obsidian |
| — | A new note renders `{{project}}` / `{{concept}}` / `{{selection}}` literally | Core Templates does not support those placeholders | Fill them by hand, or install Templater and adapt the syntax (step 5) |
| 2 | `vault-check: 0 violation(s) across 0 file(s)` plus `VACUOUS`, exit 2 | The checker scanned nothing — **this is not a pass**. The 2 says the checker could not run, as against the 1 that says a note is wrong | Check `CLAUDE_PROJECT_DIR`, and that the `TIERS=` line in the script still names folders that exist. Add a note and re-run until the file count is non-zero |
| 1 | Commits refused with `pre-commit: vault-check exited 1` | The commit gate found a note that violates C1–C5, anywhere in the working tree, including notes you have not staged and files git does not track. Most often they were written by a harness that runs no lint after a write, such as one whose adapter is not loaded, so nothing flagged them until a commit | Fix the notes it lists one at a time (AGENTS.md §9: never stamp keys across many notes to clear the report): give each the `tier:` and `type:` of its folder (AGENTS.md §3) and its own `created` date, and never copy a sibling's `last_verified` or `confidence`, which would say the note was checked when it was not. Or move one out of the content-tier folders until you can. The gate never repairs anything |
| 3 | Dream or promotion runner exits 3 and the log says `REFUSED` | `VAULT_AGENT=command` without `VAULT_ALLOW_UNENFORCED_TOOLS=1` | Sandbox the wrapper first (§ 8, *Running the passes with another harness*), then set the variable. The refusal is the intended behaviour |
| — | Scheduled agent "succeeded" but nothing changed | On Windows, the exit code was swallowed by `%ERRORLEVEL%>>`; or the run did nothing because `-p` was missing | Use the shipped runners (step 8), and judge health by the log file rather than by `State` |

### By exit code

| Exit | Symptom | Likely cause | Fix |
| --- | --- | --- | --- |
| 1 | Dream or promotion runner exits 1 and the log says `the memory override folder already held a file, or could not be listed` | `90-auto-memory/.pass-agent/` holds something other than a plain `.DS_Store` file, often a folder a contained pass left there, or the account cannot list it. A claude-mode pass keeps Claude Code's memory in that folder, and whatever it holds could be read into the pass as memory | What is there was written by an unattended agent, so treat it as data: read it before you keep any of it, keep it outside every memory folder, and empty the folder; `AGENTS.md` lets an agent do this one edit under `90-auto-memory/` only when you ask, and only once the tripwire is cleared. When a contained pass left it, the tripwire stops every pass first, so this line appears only once you have cleared the tripwire |
| 1 | Dream or promotion runner exits 1 on Windows and the log says `the state directory ... could not be created, or cannot be entered`, for an account whose name is not ASCII | The default state directory is under `%LOCALAPPDATA%`, and the runners convert that path under `C`, which turns a name such as `Łukasz` into a different folder beside your profile that Windows does not let the account create | Make a new folder yourself with an ASCII path outside the vault, directly under `C:\`, such as `C:\vault-state`, and make it private to your account: a new folder under `C:\` lets every signed-in account change its files, and the runner trusts the tripwire, in-flight marker and backup it keeps there. If it already exists, check its owner with `dir /q C:\` or `(Get-Acl C:\vault-state).Owner` and do not use one another account owns. In Command Prompt run `icacls C:\vault-state /inheritance:r /grant:r "%USERDOMAIN%\%USERNAME%:(OI)(CI)F"` (in PowerShell, `"${env:USERDOMAIN}\${env:USERNAME}:(OI)(CI)F"`) as the account the scheduled task runs as, or write that account's name in their place, then check that `icacls C:\vault-state` lists only that account and that `dir /a /q C:\vault-state` shows it empty, since other accounts could make folders in it until `icacls` ran. Another drive's root may give other accounts more (`icacls D:\` shows `Everyone:(OI)(CI)(F)` on some machines): a root where any account but yours, SYSTEM and Administrators has `(F)` or `(DC)` lets that account rename your folder and put its own in its place, and `(WDAC)` or `(WO)` lets it give itself those rights, and a folder deeper down is only as safe as the folders above it. Then set `VAULT_STATE_DIR` to `C:\vault-state\my-vault` the same way for every runner and for `vault-check.sh`. The vault may stay under your profile |
| 1 | Dream or promotion runner exits 1 and the log says `looks like a Windows program, but this runner is not running under Git Bash` or `is not a file the runner can check` | The runner was started outside Git Bash, in WSL for instance, with no `cygpath` on `PATH`, and its Claude Code is Windows' `claude.exe`: the file `CLAUDE_BIN` names, or the `claude` found on `PATH`, ends in `.exe` or, read through any link, starts with a Windows program's `MZ` header. The line names the path the runner found, which may be a link to that file. It would pass Linux paths that a Windows program reads as other folders. The second line means the name is not a file at all, such as an exported shell function, or is a file the runner's account cannot read (an execute-only install), so it cannot be checked | Run the `.cmd` runner on Windows, or install Claude Code inside WSL and point `CLAUDE_BIN` at that. For the second line, give the runner's account read access to the binary, or point `CLAUDE_BIN` at a readable one |
| 1 | Dream or promotion runner exits 1, the log says `dream-agent exited with code 1` (or `promotion-agent`), and the run log says `Settings file not found` or `Cannot use settings file` | Claude Code could not open the settings file the runner passed with `--settings` | Claude Code's message names the path it could not open; check that it exists and is a file. The runner checks that the path names the file it wrote before it starts Claude Code, so report it with the run log |
| 1 | A dream, promotion or retention runner exits 1 after only some of `.claude/scripts/` was updated: the run log says `no record of the runner's folder for the pass was taken before the agent started` or `no memory override was written for this pass`, the runner's own log says `lib/runner-common.sh has no ..., so this runner and the library come from different releases` (from 1.7.5), or `.claude/logs/` says nothing about why | `lib/runner-common.sh`, `dream-pass.sh`, `promotion-pass.sh` and `vault-retention.sh` come from different releases. From 1.7.5 each runner first checks that the library has the functions it calls and, when one is missing, logs that line, naming the function, in `.claude/logs/dream-agent.log`, `promotion-agent.log` or `vault-retention.log` and exits 1 before any lock or state. With the 1.4.2 library and 1.4.1's dream or promotion runner, every pass, in either mode, exits 1 before its agent starts, with no tripwire and the first line in the run log (`.claude/logs/dream-agent.run.log` or `promotion-agent.run.log`); in claude mode the memory override is written first. 1.4.1's retention runner runs with the 1.4.2 library, and gets neither its refusals nor its `TMPDIR` rule. With 1.4.1's library and a 1.4.2 runner, every runner exits 1 before its agent with `git_env_warning: command not found` and `vault_root_spelling_ok: command not found`, which go to the runner's stderr, not to the log (all measured on Linux, for each runner and mode, with 1.4.1's files). With the 1.4.1 library and a 1.4.0 dream or promotion runner, every claude-mode pass is refused just before Claude Code would start, with the second line in the run log, and with 1.4.0's library and a 1.4.1 runner each runner exits 1 with `temp_dir_spelling_ok: command not found` on its stderr (both measured on Linux; older libraries are unmeasured) | Take all four files from the same release. No agent ran, so there is nothing to review |
| 1 | Runner exits 1 and the log says git could not read the vault's repository | The vault has a `.git` that git refuses or cannot open, most often "detected dubious ownership" when the scheduler runs under another account. On Windows, when git's message says `cannot change to` the vault with `Invalid argument`, the vault's folder name holds a `"` or a tab that Git Bash made, and the pass was started from a Git Bash prompt, which spells the name with that character | Run `git status` in the vault as the account the scheduler uses. Fix the ownership, or add the vault with `git config --global --add safe.directory <path>` for that account; a `safe.directory` a parent git passed down with `-c` (in `GIT_CONFIG_PARAMETERS`), or one set through `GIT_CONFIG_COUNT`, no longer reaches a pass, though one a `git` wrapper on `PATH` adds to every call does (see the row for `WARNING: the environment set ...`). For the `"` or tab, start the pass from the `.cmd` wrapper, or rename the folder |
| 1 | Retention runner exits 1 and the log names a shallow clone, grafts or a sparse checkout | Its whole judgement rests on complete history, and none of those can provide it | Run the pass in a full clone of the vault. `git fetch --unshallow` fixes a shallow one. Do not work around it, because an incomplete history is exactly what makes a human-edited journal look machine-written |
| 1 | Dream, promotion or retention runner exits 1 and the log says `the sha256sum found on PATH, ..., is in the vault or leads there through a link` (or `shasum`, `cksum`), `is a link the runner could not follow to its end`, or `no cksum was found on PATH` | From 1.7.5 each runner finds `sha256sum`, `shasum` and `cksum` once, before the pass, and refuses when `PATH` finds one inside the vault, by its own path or through a link, because a pass could then rewrite the tool the runner records the vault with. It also refuses when no `cksum` is found at all | Take the vault's folder off `PATH` for the runners (the crontab's `PATH=` line, the launchd job's `EnvironmentVariables`, the task's environment), or install `cksum` where it is missing, then rerun. No agent ran, so there is nothing to review |
| 1 | Dream or promotion runner exits 1 and the log says `could not list the files the vault's instruction files import` | From 1.7.5 what the vault's instruction files import with `@` is a steering surface the runner holds through the pass, and it could not list those files, so it will not run without containment | Check that the vault's `CLAUDE.md` and `AGENTS.md` are readable files and that `awk` runs for the scheduler's account, then rerun. No agent ran, so there is nothing to review |
| 2 | `vault-check: no content-tier folders found under ...`, exit 2 | Wrong working directory, or the tier folders were renamed | Run from the vault root, or finish the rename everywhere (see below) |
| 2 | `vault-check: ... is not a readable file`, exit 2 | A note named after `--` is missing or unreadable, or (since 1.7.2, with `N note(s) could not be read` after the count line) a note the full scan listed could not be opened, so that note was not checked | Fix the path, or the note's permissions. Nothing here says any note is wrong |
| 2 | `vault-check: <path> is a link that ...`, and `N link(s) refused` after the count line, exit 2 (since 1.7.0) | A link in a content tier, or a note named after `--` in one, dangles or resolves to something the scan does not read where it is: outside the content-tier folders (a tier folder linked or joined to a synced folder outside the vault included), into a templates folder, to a compaction stub, or to a file that is no `.md` note. What it holds was not checked, and the commit gate refuses for the same reason | Point the link at a folder or note inside a content tier, or move what it names into the vault and remove the link. Remove a link by its bare name, never with a trailing `/`, which can empty the folder it points at. [`reference.md` §4.1](reference.md#41-vault-checksh--frontmatter-invariants-c1c5) has the rule |
| 2 | Dream or promotion runner exits 2 and the log says `VIOLATION` | A file outside the pass's allowed folders changed during the run — the agent, or another writer such as a sync client. For `VIOLATION: long-tier notes that were there before the pass started changed during it`, see that line's own row | Read the paths listed under the `VIOLATION` line in `.claude/logs/`, and revert with git anything you did not expect. If the log also names notes under `Long-tier notes that were there before the pass changed during it`, nothing put those back or copied them to the quarantine, and the runner cannot tell the pass's change from yours or a sync client's: read each with `git diff <commit> -- <path>` first, where `<commit>` is the commit from before the pass that the line names, and run `git restore --source=<commit> -- <path>` only on one whose whole change is the pass's |
| 2 | Promotion runner exits 2 and the log says `VIOLATION: long-tier notes that were there before the pass started changed during it` | The pass edited, stamped or retired a standard or wiki entity that was there before it, which it may only propose, or you or a sync client edited one while it ran. A line marked `(its name differs only in case from a note that was there)` is either a new note named like an existing one but for case, which on Windows and macOS is that note, so the candidate waits for a pass that names it differently, or an existing note whose name on disk differs only in case from the name git holds it under (a case-only rename, such as one made in Obsidian) that the pass or someone changed | Nothing was committed by the runner, and the pass's notes were put back and listed under `REVERTED`. A changed note's bytes are copied to the quarantine the log names, where an edit you made during the pass can be recovered, unless the log lists the note as committed while the pass ran, changed after it ended, or in no commit under its name, when it was left as it is. Read a note in no commit under its name with `git diff` (`git status` shows it under its committed name) and restore what the pass wrote before anything commits it. A sync client that committed during the pass may have committed the change itself: read that commit with `git show` and revert it if the change is the pass's, and pause auto-commit around the scheduled pass. If the agent did it, check that a customized `promotion-agent.md` no longer tells it to stamp, supersede or edit an existing note |
| 2 | Runner exits 2, the log says `contained`, and `.claude/logs/runner-tripwire` exists | The pass changed a steering or execution surface (an Obsidian plugin, something under `.claude/`, a harness config, an instruction file at any depth, memory, or git's config or hooks), or HEAD was rewound. The runner restored those files and moved what the pass wrote into the quarantine outside the vault | Read the tripwire, which names each path, anything it could not contain, and the quarantine directory. Inspect the quarantined files, and check `git reflog` if HEAD is listed. Then delete the tripwire and its copy in the state directory. If only a code-running plugin's `data.json` is listed (Dataview, Templater and the others named in `docs/reference.md` § 4.3) and you changed its settings during the pass, here or on another device through Obsidian Sync, that is the likely cause. If HEAD is listed and you rebased, pulled with rebase or switched branches during the pass, that is the likely cause. Containment puts back steering surfaces only, so a long-tier note the pass changed is named in the log as in the dream or promotion runner's exit 2 `VIOLATION` row |
| 2 | Runner exits 2 and the log says the pass changed files that already had uncommitted changes | You, a sync client or another tool had uncommitted edits in a journal or long-tier note, and the pass wrote to the same file. A `TIMEOUT` or `NO-ARTIFACT` line may come first, because this exit wins over 124 and 1 | The runner committed and recorded nothing, and the promotion runner put back the pass's other notes. Open the file (for a new, untracked one `git diff` shows nothing), keep what you want, commit it yourself, and the next pass runs normally |
| 2 | Retention runner exits 2 and the log says `REPORT-REFUSED` | The file given to `--adopt-legacy` is not a report this runner wrote, or its list of paths has been changed since it was written. Nothing moved | Use the report path the runner logged, in the state directory. Never hand-edit a report to add a path. Run the pass with no arguments to have it write a fresh report, read that one, and adopt it |
| 3 | Retention runner exits 3 and the log says `PARTIAL`, or that an archive folder could not be made or is a link | For `PARTIAL`, a `git mv` failed while HEAD was still unchanged, so every file was put back where it was and nothing was committed. For the other two, nothing had moved yet | The log names what failed, usually a file that another program had open or a permission problem. Fix it and run again. The vault is already back at HEAD, so nothing is half moved. For a folder, make `99-archive/20-projects/_logs` a real folder the account can create files in, then run again |
| 4 | Dream or promotion runner exits 4 and the log says `COMMIT-FAILED` | Staging or committing the pass's notes failed or ran past `RUNNER_GIT_TIMEOUT`, for example a signing key that needs a passphrase, no git identity, or a busy `index.lock` | The log shows git's output. Fix the cause and rerun, and the next run of the same pass checks the notes the failed one left and commits them, or puts them back when they fail the check, as long as nobody has edited them. If the log says the files could not be taken back out of the index, run `git reset -- <file>` first. Delete an `index.lock` the log names once no git command is running |
| 4 | Runner exits 4, or 129, 130 or 143 after a signal, the log says `KILL_FAILED`, and every later run exits 75 | A commit step, or the stop a signal started, left a process running or could not check. A signal before containment also sets the tripwire, in a shape that says nothing was moved or restored because containment did not run, and the log says `INTERRUPTED`. After containment only the run lock is marked | End the process the log lists, as the exit 124 or 125 `KILL_FAILED` row says. After an `INTERRUPTED` line, do what the tripwire says before any git command: check the steering surfaces without git, as in the `UNVERIFIED` row. Then check `git status` for a half-made commit (after an `INTERRUPTED` line, as `git -c core.fsmonitor=false --no-pager status --ignore-submodules=all`, as the tripwire says), and delete the `run.lock` folder the log names, and the tripwire too if one is set |
| 5 | Dream runner exits 5 and the log says `CHECK-FAILED` | The journal the pass wrote fails `vault-check.sh` (C1–C5), so it was not committed | Read the check output under that line. Then fix the journal by hand and commit it yourself, or delete it. Later runs leave the rejected journal alone and commit their own, except a run the same day that writes to that same journal, which exits 2 until you commit or delete it |
| 5 | Promotion runner exits 5 and the log says `CHECK-FAILED` and `REVERTED`, or exits 2 with `REVERTED` | A note the pass wrote or changed fails `vault-check.sh` (C1–C5), or the pass deleted a note, so none of its notes were committed. Each was copied to the quarantine in the state directory and put back as it was in the commit before the pass, and a new note was moved there | Read the check output and the `REVERTED` list. A note listed as changed after the pass ended, as committed while the pass ran, or as in no commit because git ignores it, was left as it is, so review it by hand. An edit you made to a note while the pass ran is in the quarantine copy. The candidates stay in the project logs for the next pass |
| 6 | Retention runner exits 6 and the log says `PATH-BLOCKED` | `20-projects`, `20-projects/_logs` or one of the `99-archive/...` folders is a symlink, an NTFS junction, a plain file, or another entry exists whose name differs only in case. Checked before anything is judged, so nothing moved | Make the path named in the log a real folder in the vault, or remove the case-variant entry. The runner refuses rather than following a link because a link is how an archived note would be written somewhere you cannot see |
| 64 | Runner exits 64 | `VAULT_AGENT` is set to something other than `claude` or `command` | Fix the value; unset it to use Claude Code |
| 64 | `vault-check: unknown option ...`, exit 64 | The command line was wrong | Notes go after `--`, as in `vault-check.sh -- 10-daily/2026-01-15.md` |
| 70 | Runner exits 70, or exits 129, 130 or 143 after a signal, and the log says `TRIPWIRE-ERROR` | Containment was needed, or the runner's own folder for the pass was changed while it ran, but no tripwire could be written, for example a full disk, or an earlier pass's marker could not be turned into a tripwire. The in-flight marker is kept | Free the space, then run the pass by hand. It refuses with 78 and writes the tripwire, which you then review; for a changed folder, after a signal, or for a dead pass's marker, the line says "Treat the vault as unverified, and run no git command in it before the steering surfaces have been checked.", so review as in the `UNVERIFIED` row |
| 71 | Retention runner exits 71 and the log says `RECOVERY-NEEDED`, and later runs exit 78 | A put-back failed, or a commit was made and what it did could not be determined. The runner never puts back a commit that may have landed | Read `retention-inflight` in the state directory. It names HEAD before the run and every file with where it should be. Put each file where the record says, with `git mv` if it is in the index, then run the pass again. It clears the record itself once the vault matches either the before or the after state |
| 75 | Runner exits 75 and the log says `LOCKED` | Another pass held the run lock, or git's `index.lock` stayed, for the whole `RUN_LOCK_WAIT`, or the `index.lock` is more than 10 minutes old | For a held lock, nothing if the schedules overlap by design, otherwise move one schedule. A lock left by a killed runner is reclaimed on its own once that runner's longest run has passed. The log names the holder, and the lock is `run.lock` in the state directory. A lock whose holder cannot be checked, because its owner file cannot be read or, on Windows, PowerShell cannot look the process up, is never reclaimed, so once no pass is running, delete `run.lock` yourself. For `index.lock`, make sure no git command is running, then delete the file |
| 75 | Runner exits 75 and the log says a git operation is in progress, or HEAD is detached | A merge, rebase, cherry-pick, revert or bisect was left unfinished, or a commit is checked out instead of a branch. A pass commits, so it will not start then | Finish or abort the operation (`git merge --abort`, `git rebase --abort` and so on), or check out your branch, then let the next run start |
| 78 | `vault-check: TRIPWIRE ...`, exit 78 | A scheduled pass changed a steering or execution surface, so nothing was checked | Follow [A tripwire is set](#a-tripwire-is-set): read the right copy, review, then delete both copies. The runners use 78 for the same thing |
| 78 | Runner exits 78 and the log says `TRIPWIRE`, or `vault-check.sh` says `TRIPWIRE` | A tripwire is still in place, or a previous pass ended before containment ran (the scheduler ended the task, or the machine stopped) and this run turned its marker into a tripwire, which then says "Nothing was moved or restored, because containment did not run." A tripwire whose reason, or a section added at its end, says a process may still be running comes from a `KILL_FAILED` stop. With an `UNVERIFIED:` line in the log, the agent ran and the runner's own folder for the pass was changed while it ran (see the `UNVERIFIED` row). When the vault's log, `.claude` or `.claude/logs` is a symbolic link, `.claude/logs` is not a folder, or the log is there and not a file, the refusal is in `dream-pass.uncontained.log`, `promotion-pass.uncontained.log` or `vault-retention.uncontained.log` in the state directory instead, with a `WARNING:` there; the retention runner's printed lines carry the `WARNING:` when it could keep its own copy of them, and otherwise name that log. A run checks for this as soon as its state directory is known, before its run lock, whenever the tripwire or the passes' in-flight marker (`runner-inflight`) is there, and again once it holds the lock, because the pass holding the lock could make the link while the run waited. A line logged before the first check, in every runner (a setting's warning, the state-directory error, the `WARNING:` naming the git variables the runner cleared, or the `ERROR:` refusing the vault's spelling), still goes to the vault's log path, and for the dream and promotion runners, and a retention run that could keep no copy of its lines or was stopped while waiting, so does a line logged while waiting for the lock, unless the first check already moved the log | Read the tripwire the log names and do what it says. When the log says a pass may have written it, because no copy in the state directory is a file, compare its reason with the runner log before you follow anything in it. When the log says the path is not a file, remove it and read the runner log for why the tripwire was set. For a changed surface, review as the `contained` row says. For a tripwire that says containment did not run, check the steering surfaces without git before any git command, as the `UNVERIFIED` row says. For a `KILL_FAILED` stop, see the `KILL_FAILED` rows, because its run lock also has to go. Then delete both copies of the tripwire. [A tripwire is set](#a-tripwire-is-set) has these steps in order |
| 78 | Dream or promotion runner exits 78 and the log says `UNVERIFIED: the runner's own folder for the pass, ..., was changed while the pass ran` | The runner's own folder for the pass, under `TMPDIR` or `/tmp`, which holds its snapshot of the vault, its backup of the steering surfaces and git's hooks folder, was not as the runner recorded it before the agent started, or could not be recorded again when the agent returned: the agent, or another process able to write that folder, changed it. Nothing in it could be trusted, so nothing was moved or restored, the tripwire is set in a shape that says so, and the in-flight marker is cleared. `.git/config`, `.git/hooks` and `.obsidian/` may still hold what the pass planted: a `core.fsmonitor` command runs at the first `git status`, hooks run at git calls, and Obsidian loads plugins (reasoned). When the agent was also stopped, a `TIMEOUT` or `STALLED` line stands beside it. The run output is kept in the state directory as `<runner>.interrupted.run`, unless `run` is missing, is not a regular file or is in a folder that is a link, when the log says `WARNING: the run output, ..., is missing, is not a regular file or is in a folder that is a link, so it was not kept.` When the vault's log, `.claude` or `.claude/logs` is a symbolic link, `.claude/logs` is not a folder, or the log is there and not a file, the rest of the run's lines are in `<runner>.uncontained.log` in the state directory, with a `WARNING:` there, and the tripwire says so | Until the vault is reviewed, do not open it in Obsidian or an agent session, and run no git command in it before the steering surfaces have been checked, git that starts on its own included: a shell prompt that shows git state, or an editor with git integration. First copy the pre-pass backup the line names, `inflight-backup.tar` in the state directory, because the next pass replaces it. Compare the steering surfaces with it, those three among them, without git: unpack the copy into an empty folder with `tar -xf`, compare that folder with the vault with `diff -r` (with `--no-dereference` where your `diff` has it, so a link is compared rather than followed), and put back what differs. When the line says no pre-pass backup was made, check them by hand. Where `.git` is a file (a linked worktree), the git folder it names is outside the vault and outside the backup, so check its config and hooks by hand as well. A `.git` deeper in the vault is a steering surface too, and `diff -r` shows a new one only as a new folder above it: list every `.git` with `find . -name .git`, and check the config and hooks of any you did not make. A link in `.claude/logs`, or `.claude` itself as a link, is in neither the backup nor git: list them with `find .claude -type l`, and remove any you did not make once you have checked what it names. Then review the rest of the vault; where it is a git repository, start with `git -c core.fsmonitor=false --no-pager status --ignore-submodules=all`, which starts no fsmonitor command or pager and stays out of repositories nested in it. The folder the line names is kept for the review. Last, delete both copies of the tripwire, as for any other ([A tripwire is set](#a-tripwire-is-set) has the steps in order) |
| 79 | Dream or promotion runner exits 79 and the log says `AGENT-STATUS` | The agent or your `VAULT_AGENT_CMD` wrapper itself left with a code the runner uses for something else (the code is in the `exited with code` line above it), so the runner left with 79 rather than claim a tripwire, a lock or a timeout that did not happen. Nothing was committed | Read the run log for why the agent or wrapper failed. A wrapper that passes on another program's status passes its codes on too; have it leave with 1 for its own failures. With 126 or 127, also check that the wrapper could start at all: the runner reads its `#!` line and keeps the shell's 126 or 127 (see those rows) when the interpreter, or the command after `#!/usr/bin/env`, is missing, but not for every shape, such as `#!/usr/bin/env cmd arg` on Linux or a line ending in a carriage return (`docs/reference.md`, exit `79`). A binary built for another machine passes that check and gives 126 (exec format error), which reads as the agent's own and so leaves as 79; the run log keeps the shell's message |
| 124 | Runner exits 124 and the log says `TIMEOUT` | The pass exceeded `DREAM_PASS_TIMEOUT` / `PROMOTION_PASS_TIMEOUT` and was killed. Had the runner's own folder for the pass also changed while it ran, the exit would be 78, with the `UNVERIFIED:` line beside this one (see the `UNVERIFIED` row), or 70 when no tripwire could be written, with a `TRIPWIRE-ERROR:` line in its place and the in-flight marker kept (see the 70 row) | Check the `.run.log` for where it stalled; raise the limit only if the pass was making progress |
| 124 | Runner exits 124 or 125 (or 78, with an `UNVERIFIED:` line, when the runner's own folder for the pass also changed while it ran, or 70, with a `TRIPWIRE-ERROR:` line in its place, when no tripwire could then be written), the log says `KILL_FAILED`, the tripwire is set where one could be written, and every later run exits 75 | A process of the stopped pass was still running after the stop, its output kept growing, or the check gave no answer (the log says `unknown`, for example when `ps` or PowerShell could not run or PowerShell took over a minute). The runner kept its run lock so another pass cannot race it, set the tripwire because that process may have written after containment, and kept the pre-pass backup in the state directory. The tripwire says when the lock could not be marked or no backup was made | Find the process the log lists (on Windows, a `claude` or `bash` whose command line holds the session id the log names) and end it. For `unknown`, make `ps` or `powershell.exe` runnable for the task's account. Review the vault as the tripwire says, against the backup it names and `git status` (after a 78 with an `UNVERIFIED:` line, or a 70, as in the `UNVERIFIED` row, comparing with the backup before any git command; the `TRIPWIRE-ERROR:` line says only "Treat the vault as unverified, and run no git command in it before the steering surfaces have been checked."), then delete both copies of the tripwire, and the `run.lock` folder the log names when the lock was marked ([A tripwire is set](#a-tripwire-is-set) has the steps in order) |
| 125 | Runner exits 125 and the log says `STALLED` | A pass wrote nothing to its output for the stall threshold the log names, and was stopped with everything it started. That is a claude-mode pass, or a command-mode one with `RUNNER_STALL_SECONDS` set. Had the runner's own folder for the pass also changed while it ran, the exit would be 78, with the `UNVERIFIED:` line beside this one, or 70 when no tripwire could be written, with a `TRIPWIRE-ERROR:` line in its place and the in-flight marker kept | Read the end of the `.run.log`. A pass waiting on a slow tool or a rate limit is not stalled, so raise `RUNNER_STALL_SECONDS` or `RUNNER_STALL_FLOOR` if that is what you see. The notes it left are checked by the next run |
| 126 | Dream or promotion runner exits 126 | The `claude` binary or your `VAULT_AGENT_CMD` wrapper cannot start: the interpreter its `#!` line names is missing (bash 5.3 and 3.2 give 126 for that; 5.2 gives 127) or is not executable. Since 1.7.5 a 126 the agent itself leaves with becomes 79 instead, so 126 always means this | Run the wrapper once by hand from the vault root to see the shell's message, then fix the `#!` line or install its interpreter. The run log keeps the same message. No pass ran |
| 127 | Dream or promotion runner exits 127 and the log says `claude binary not found`, or the wrapper could not be started | `claude` is not on the scheduler's `PATH` (cron and launchd run no login profile), `CLAUDE_BIN` names nothing, or the `VAULT_AGENT_CMD` wrapper is missing, is not executable, is a folder, or cannot start for a `#!` line `docs/reference.md` (exit `79`) names | Set `CLAUDE_BIN` to the absolute path `command -v claude` prints in a normal terminal, or fix the wrapper's path, exec bit or `#!` line. No pass ran |
| — | `run-tests.sh` fails only on a path containing spaces | A word-splitting regression in a local edit | Revert the edit; the suite builds fixtures under a directory named with a space specifically to catch this |
| — | Dream or promotion runner logs `WARNING: no sha256sum or shasum was found, so the runner checks its folder for the pass with cksum` | Neither `sha256sum` nor `shasum` is on the runner's `PATH`, so the record of its folder for the pass, taken before the agent starts and checked when it returns, uses `cksum`, a CRC that anyone able to write the folder can make a file match | Put `sha256sum` or `shasum` on the `PATH` the scheduled task gets. The pass still runs |
| — | A runner logs `WARNING: the environment set ..., which change the repository, index, objects or configuration git uses, and the runner cleared them` | The environment the runner was started in exported some of git's variables for one repository, such as `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` or `GIT_CONFIG_COUNT`, which the line names. The runners clear them as their library loads: with `GIT_DIR` naming another repository, a 1.4.1 pass committed there (measured on Linux). So settings a parent git passed down with `-c` (in `GIT_CONFIG_PARAMETERS`), and those set through `GIT_CONFIG_COUNT`, `safe.directory` among them, no longer reach the pass (a `git` wrapper on `PATH` that adds `-c` to every call is not affected), and a vault git reached only through `GIT_DIR`, with no `.git` entry of its own, now reads as no repository: dream and promotion passes run without committing, and the retention runner refuses (reasoned) | Remove the variables from the task's environment, and put a setting such as `safe.directory` in the account's global git configuration. For a vault whose git directory lies elsewhere, a `.git` file in the vault naming it (`gitdir: <path>`, with no part ending in a dot) would let git find it (reasoned) |
| — | The log says the output of the pass is kept in the state directory | The pass was stopped by a signal before its output reached the `.run.log` in the vault, where writing is safe only after containment, a stop left a process that may still be running (`KILL_FAILED`), or a `WARNING` just before says the run log could not be written, for example because a folder or an unreadable file is in its place | Read `<runner>.interrupted.run` in the state directory the log names to see where the pass was. For a `WARNING`, fix what it names at the run-log path. A `WARNING` that names what is at that path (a folder, a link, or a path the output could not be renamed to) gives the new name the output was kept under instead. Read that file, then remove what is in the way. A `WARNING` that the output may be inside what took the path means something replaced it during the run, so look inside it. A `WARNING` that the output is lost means this run's output is gone. It says whether what is still at that path is an earlier run's output or something else, which you remove |
| — | A journal never becomes eligible and the log says it was committed without a dream trailer | A sync plugin committed the journal before the runner could, so it carries no `Vault-Pass: dream` trailer and there is no way to prove a machine wrote it | Turn off the plugin's auto-commit, or schedule it after the dream pass. Existing journals in that state have to be archived by hand. Obsidian Git's "auto commit-and-sync" interval is the usual cause, and setting it longer than the passes take is enough |

### One more, because it is the template's biggest customization cost

**Renaming a tier folder is a multi-file edit, not a rename.** The folder names are independently
hardcoded in many files. The one complete list of them, and the full procedure, is the table in
[`customizing.md`, section 2](customizing.md#2-renaming-or-adding-a-tier-folder).

Miss one and the failure is quiet in the worst direction: the lint hook stops recognising the
folder as a content tier and skips it, and `vault-check.sh` drops it from the scan list, so both
report clean about a tier neither one looked at. If you rename, grep for the old name across the
whole repo afterwards and re-run step 7, watching the **file count**, not the violation count.
