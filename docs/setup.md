# Setup

This guide takes you from a fresh clone to a working vault: Obsidian open, your coding-agent
harness wired in (Claude Code in § 6, any other harness in § 6a), and (the part that matters) a
verified install, where you have proof the checkers ran rather than a reassuring silence.

The whole thing takes about fifteen minutes. Steps 1–3 and 6–7 are required. Steps 4, 5 and 8 are
optional and can be skipped without breaking anything.

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

### What the three hooks do

| Hook | Fires on | What it does | Can it block you? |
| --- | --- | --- | --- |
| `vault-lint.sh` | `PostToolUse`, matcher `Write` or `Edit` | Checks the just-written note for the mandatory `tier:` and `type:` frontmatter, and scans it for zero-width / bidi codepoints. The character scan is widened to `.claude/rules/`, `.claude/agents/`, `.claude/skills/`, and any `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` or `.github/copilot-instructions.md`, which are exactly what a rules-file backdoor targets. Logs to `.claude/logs/vault-lint.log`. | No — advisory, **always exits 0** |
| `postcompact-wrap-up.sh` | `PostCompact` | Writes one idempotent, size-capped stub per session into `20-projects/_logs/compaction-<session>.md`, so the material in a compacted context is still recoverable afterwards. Caps at 50 entries, and sanitizes the session id before building a path. | No |
| `instructions-loaded-log.sh` | `InstructionsLoaded`, session start only | Appends which instruction files loaded, to `.claude/logs/instructions-loaded.log`. This is how you answer "was that rule actually in context?" instead of guessing. | No |

All three write only into `.claude/logs/` (gitignored) or into `20-projects/_logs/`. None of them
edits an existing note.

The five skills in `.claude/skills/` — `obsidian-save`, `wrap-up`, `resume`, `preserve` and
`onboard-project` — are picked up automatically from the project directory; there is no
registration step.

`.claude/settings.json` also carries `permissions.deny` rules for `Read(./.env)`, `Read(./.env.*)`
and `Read(./secrets/**)`. They apply immediately, without a trust prompt.

---

## 6a. Wiring any other harness

**Start with your harness's guide in [`docs/harnesses/`](harnesses/README.md).** The template ships
config for Codex CLI, Gemini CLI, Cursor, GitHub Copilot, OpenCode, Windsurf / Devin Desktop and
Aider, and a snippet for Hermes Agent. Each guide gives the one-time setup and an onboarding prompt
whose checks prove the hooks fire. The steps below are the harness-independent version, for a
harness without a guide.

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

This section is the point of the whole guide. Run both commands and read the output carefully.

### 7a. The control suite

```bash
bash .claude/scripts/run-tests.sh
```

Expect a list of `PASS` lines, an informational dependency block, and a final
`=== N passed, 0 failed ===`. Exit code 0.

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
`30-knowledge`, `31-standards`, `40-llm-wiki`), skipping `templates/` and `compaction-*.md`:

| ID | Invariant |
| --- | --- |
| C1 | First line is a bare `---` fence |
| C2 | Frontmatter has a `tier:` key |
| C3 | Frontmatter has a `type:` key |
| C4 | If both exist, `last_verified` is not earlier than `created`; `created` is a `YYYY-MM-DD` date |
| C5 | `last_verified` is not in the future, and is a `YYYY-MM-DD` date |

It is **report-only**: it never writes, stamps, or repairs, and it exits 1 when any note violates
an invariant so you can gate a pass on it. Repair is a human act.

The final line looks like this:

```
vault-check: 0 violation(s) across 9 file(s) checked (as of 2026-01-01).
```

### The one output you must not misread

> **`0 violation(s) across 0 file(s)` is NOT a pass.** It means the checker scanned nothing, so the
> script also prints `VACUOUS` to stderr and exits 1.

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

## 8. Optional: scheduling the dream and promotion agents

Two agents are defined in `.claude/agents/`. Scheduling them is optional. The vault
works fine driven only by `/obsidian-save` and `/preserve` during ordinary sessions.

| Agent | Cadence | What it writes |
| --- | --- | --- |
| `dream-agent` | Nightly, if you want it | **One** dated dream-journal file. Nothing else, ever. |
| `promotion-agent` | Weekly | **Creates and edits notes** in `31-standards/` and `40-llm-wiki/wiki/` |

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
pass actually produced something. Exit codes are `0` OK, `1` no artifact, `2` write outside the
fence, `3` refused (see below), `64` unknown `VAULT_AGENT`, `124` timeout, `127` no `claude` or
wrapper; `docs/reference.md` § 4.3 has the full table.

```cron
# dream pass, nightly at 02:30
30 2 * * *  /path/to/your-vault/.claude/scripts/dream-pass.sh
# promotion pass, Sundays at 03:30
30 3 * * 0  /path/to/your-vault/.claude/scripts/promotion-pass.sh
```

If `claude` is not on the PATH cron gives you (it usually is not, since cron runs no login
profile), set `CLAUDE_BIN` to the full path in the crontab. The watchdog limits are environment
variables too: `DREAM_PASS_TIMEOUT` (default 3600 seconds) and `PROMOTION_PASS_TIMEOUT` (default
5400). Set them the same way, as `NAME=value` lines above the entries, if a pass legitimately needs
longer.

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

A Windows batch wrapper receives the same forward-slash relative path, which cmd built-ins such
as `type` read as a switch. Expand it to an absolute path first, with `%~f1`.

Do not use `CLAUDE_BIN` to run another harness. It must name the Claude Code binary: pointing it
at a different CLI keeps claude mode, which skips the refusal below while enforcing nothing.

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
- can write only inside the vault.

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
  the `mkdir -p` above.
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
same code as on macOS and Linux. It looks for Git Bash in the standard Git for Windows locations
and never searches `PATH`, because `C:\Windows\System32\bash.exe` is WSL; set `BASH_EXE` if yours
is elsewhere. `CLAUDE_BIN` and the timeout variables pass through from the task's environment.

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

Make the task's limit longer than everything the runner can spend before it exits on its own:
the wait for the run lock (`RUN_LOCK_WAIT`, default 30 minutes), the pass's own timeout, the
watchdog's grace period, and two git steps of `RUNNER_GIT_TIMEOUT` (default 2 minutes each), each
with its own grace period, to commit the pass's notes, plus a margin. Then the runner always kills a hung pass first, logs
`TIMEOUT` with exit 124, and releases its lock. A limit shorter than that lets Task Scheduler end
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

**Trap 3 — judging health by `State`.** Task health is `LastTaskResult` **plus a log file on
disk**, never `State`. A task can sit at `Ready` for weeks while every run dies on startup.
If `.claude/logs/dream-agent.log` has no new lines, the task is not working, whatever the UI says.

### Removing it

Scheduling is the only part of the vault that lives outside the folder, so remove it first.

```bash
# Linux: delete the two runner lines
crontab -e

# macOS: unload both jobs, then delete their plists
launchctl bootout gui/$(id -u)/com.claude-memory-vault.dream-pass
launchctl bootout gui/$(id -u)/com.claude-memory-vault.promotion-pass
rm ~/Library/LaunchAgents/com.claude-memory-vault.dream-pass.plist \
   ~/Library/LaunchAgents/com.claude-memory-vault.promotion-pass.plist
```

```bat
schtasks /delete /tn "Vault-DreamAgent" /f
schtasks /delete /tn "Vault-PromotionAgent" /f
```

To stop any harness using the vault's hooks, skills, agents and rules, delete the `.claude/`
folder, and run `git config --unset core.hooksPath` if you enabled the commit gate. That also
removes `.claude/logs/`. Your notes are plain Markdown and are untouched.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Hooks never fire; `.claude/logs/` stays empty or absent | Claude Code was started outside the vault, so `${CLAUDE_PROJECT_DIR}` points elsewhere | `cd <your-vault>` and start Claude Code there; confirm the three hooks are listed under `/hooks` |
| Hooks still silent, on Windows | No bash on `PATH` for the `"shell": "bash"` invocation | Install Git for Windows and confirm `bash --version` works in the shell you launch Claude Code from |
| Runner exits 3 and the log says `REFUSED` | `VAULT_AGENT=command` without `VAULT_ALLOW_UNENFORCED_TOOLS=1` | Sandbox the wrapper first (§ 8, *Running the passes with another harness*), then set the variable. The refusal is the intended behaviour |
| Runner exits 64 | `VAULT_AGENT` is set to something other than `claude` or `command` | Fix the value; unset it to use Claude Code |
| Commits refused with `pre-commit: vault-check exited 1` | The commit gate found a note that violates C1–C5, anywhere in the working tree | Fix the notes it lists. The gate never repairs anything |
| `vault-lint: jq not found; path parsing is degraded` | `jq` is missing — expected on a stock Git for Windows | Install jq (step 1). The hook keeps working, less reliably, until you do |
| `INVISIBLE-CHAR SCAN DID NOT RUN (no perl, no grep -P)` | Neither scanner is available on this machine | Install perl. Do **not** treat earlier "clean" lint lines from that machine as evidence — they were unscanned |
| Dataview tables in `VAULT-INDEX.md` show as code blocks or raw text | Dataview installed but not enabled, or not installed at all | Settings → Community plugins → enable **Dataview**, then reload Obsidian |
| A new note renders `{{project}}` / `{{concept}}` / `{{selection}}` literally | Core Templates does not support those placeholders | Fill them by hand, or install Templater and adapt the syntax (step 5) |
| `vault-check: 0 violation(s) across 0 file(s)` plus `VACUOUS`, exit 1 | The checker scanned nothing — **this is not a pass** | Check `CLAUDE_PROJECT_DIR`, and that the `TIERS=` line in the script still names folders that exist. Add a note and re-run until the file count is non-zero |
| `vault-check: no content-tier folders found under ...` | Wrong working directory, or the tier folders were renamed | Run from the vault root, or finish the rename everywhere (see below) |
| `run-tests.sh` fails only on a path containing spaces | A word-splitting regression in a local edit | Revert the edit; the suite builds fixtures under a directory named with a space specifically to catch this |
| Scheduled agent "succeeded" but nothing changed | On Windows, the exit code was swallowed by `%ERRORLEVEL%>>`; or the run did nothing because `-p` was missing | Use the shipped runners (step 8), and judge health by the log file rather than by `State` |
| Runner exits 2 and the log says `VIOLATION` | A file outside the pass's allowed folders changed during the run — the agent, or another writer such as a sync client | Read the paths listed under the `VIOLATION` line in `.claude/logs/`, and revert with git anything you did not expect |
| Runner exits 2, the log says `contained`, and `.claude/logs/runner-tripwire` exists | The pass changed a steering or execution surface (an Obsidian plugin, something under `.claude/`, a harness config, an instruction file at any depth, memory, or git's config or hooks), or HEAD was rewound. The runner restored those files and moved what the pass wrote into the quarantine outside the vault | Read the tripwire, which names each path, anything it could not contain, and the quarantine directory. Inspect the quarantined files, and check `git reflog` if HEAD is listed. Then delete the tripwire and its copy in the state directory. If only a code-running plugin's `data.json` is listed (Dataview, Templater and the others named in `docs/reference.md` § 4.3) and you changed its settings during the pass, here or on another device through Obsidian Sync, that is the likely cause. If HEAD is listed and you rebased, pulled with rebase or switched branches during the pass, that is the likely cause |
| Runner exits 78 and the log says `TRIPWIRE`, or `vault-check.sh` says `TRIPWIRE` | A tripwire is still in place, or a previous pass ended before containment ran (the scheduler ended the task, or the machine stopped) and this run turned its marker into a tripwire | As above: review, then delete both copies of the tripwire |
| Runner exits 75 and the log says `LOCKED` | Another pass held the run lock, or git's `index.lock` stayed, for the whole `RUN_LOCK_WAIT`, or the `index.lock` is more than 10 minutes old | For a held lock, nothing if the schedules overlap by design, otherwise move one schedule. A lock left by a killed runner is reclaimed on its own once that runner's longest run has passed. The log names the holder, and the lock is `run.lock` in the state directory. A lock whose holder cannot be checked, because its owner file cannot be read or, on Windows, PowerShell cannot look the process up, is never reclaimed, so once no pass is running, delete `run.lock` yourself. For `index.lock`, make sure no git command is running, then delete the file |
| Runner exits 75 and the log says a git operation is in progress, or HEAD is detached | A merge, rebase, cherry-pick, revert or bisect was left unfinished, or a commit is checked out instead of a branch. A pass commits, so it will not start then | Finish or abort the operation (`git merge --abort`, `git rebase --abort` and so on), or check out your branch, then let the next run start |
| Runner exits 2 and the log says the pass changed files that already had uncommitted changes | You, a sync client or another tool had uncommitted edits in a journal or long-tier note, and the pass wrote to the same file | The runner committed nothing, and the promotion runner put back the pass's other notes. Open the file (for a new, untracked one `git diff` shows nothing), keep what you want, commit it yourself, and the next pass runs normally |
| Runner exits 1 and the log says git could not read the vault's repository | The vault has a `.git` that git refuses or cannot open, most often "detected dubious ownership" when the scheduler runs under another account | Run `git status` in the vault as the account the scheduler uses. Fix the ownership, or add the vault with `git config --global --add safe.directory <path>` for that account |
| Dream runner exits 5 and the log says `CHECK-FAILED` | The journal the pass wrote fails `vault-check.sh` (C1–C5), so it was not committed | Read the check output under that line. Then fix the journal by hand and commit it yourself, or delete it. Later runs leave the rejected journal alone and commit their own |
| Promotion runner exits 5 and the log says `CHECK-FAILED` and `REVERTED`, or exits 2 with `REVERTED` | A note the pass wrote or changed fails `vault-check.sh` (C1–C5), or the pass deleted a note, so none of its notes were committed. Each was copied to the quarantine in the state directory and put back as it was in the commit before the pass, and a new note was moved there | Read the check output and the `REVERTED` list. A note listed as changed after the pass ended, as committed while the pass ran, or as in no commit because git ignores it, was left as it is, so review it by hand. An edit you made to a note while the pass ran is in the quarantine copy. The candidates stay in the project logs for the next pass |
| Runner exits 4 and the log says `COMMIT-FAILED` | Staging or committing the pass's notes failed or ran past `RUNNER_GIT_TIMEOUT`, for example a signing key that needs a passphrase, no git identity, or a busy `index.lock` | The log shows git's output. Fix the cause and rerun, and the next run of the same pass checks the notes the failed one left and commits them, or puts them back when they fail the check, as long as nobody has edited them. If the log says the files could not be taken back out of the index, run `git reset -- <file>` first. Delete an `index.lock` the log names once no git command is running |
| Runner exits 70, or exits 130 or 143 after a signal, and the log says `TRIPWIRE-ERROR` | Containment was needed but no tripwire could be written, for example a full disk | Free the space, then run the pass by hand. It refuses with 78 and writes the tripwire, which you then review |
| Runner exits 124 and the log says `TIMEOUT` | The pass exceeded `DREAM_PASS_TIMEOUT` / `PROMOTION_PASS_TIMEOUT` and was killed | Check the `.run.log` for where it stalled; raise the limit only if the pass was making progress |

### One more, because it is the template's biggest customization cost

**Renaming a tier folder is a multi-file edit, not a rename.** The folder names are independently
hardcoded in at least these files (`docs/customizing.md` § 2 has the full procedure):

- `CLAUDE.md`
- `.claude/hooks/vault-lint.sh`
- `.claude/hooks/postcompact-wrap-up.sh`
- `.claude/scripts/vault-check.sh`
- `.claude/agents/dream-agent.md`
- `.claude/rules/vault-notes.md`, `.claude/rules/verification.md`,
  `.claude/rules/untrusted-captures.md`
- `.obsidian/daily-notes.json`

Miss one and the failure is quiet in the worst direction: the lint hook stops recognising the
folder as a content tier and skips it, and `vault-check.sh` drops it from the scan list, so both
report clean about a tier neither one looked at. If you rename, grep for the old name across the
whole repo afterwards and re-run step 7, watching the **file count**, not the violation count.
