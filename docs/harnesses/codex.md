# OpenAI Codex CLI

Codex reads `AGENTS.md` on its own, and the template ships a project config that runs the lint
after edits and the compaction stub. Codex loads that config only once you trust the project.

## What ships

| File | What it does |
| --- | --- |
| `.codex/config.toml` | Turns on lifecycle hooks (`[features] hooks = true`) |
| `.codex/hooks.json` | `PostToolUse` on `apply_patch` runs `vault-lint.sh`; `PostCompact` runs `postcompact-wrap-up.sh` |
| `.agents/skills/*/SKILL.md` | The five skills, where Codex looks for repository skills |

Codex edits files through `apply_patch`, and its hook receives the patch text rather than a file
path (`tool_input.command`). `vault-lint.sh` reads every `*** Add File:`, `*** Update File:` and
`*** Move to:` header in that text and lints each named file, resolving a relative path against
the session's `cwd` and then the vault root. Those header names follow Codex's patch format as
used in its tooling; Codex's hook documentation does not spell them out, so O4 is the check that
they still match.

## Enforced, and guidance

- **Enforced:** the lint after each `apply_patch` edit, and the compaction stub, in a trusted
  project.
- **Not linted:** a file written by a shell command (`cat > note.md`). The commit gate catches it
  at commit time.
- **Guidance:** reads of `.env` and `secrets/`. Codex reads files through its shell, which no
  vault hook sees, so `.claude/rules/security.md` is the only control.

## Setup

1. Start Codex from the vault root. The hook commands locate the vault with
   `git rev-parse --show-toplevel`, so they need the session to be inside the repository.
2. When Codex asks whether to trust the project, trust it. Without trust it ignores
   `.codex/config.toml` and `.codex/hooks.json`, and nothing is linted.
3. On Windows, make sure `bash` on your `PATH` is Git Bash. `C:\Windows\System32\bash.exe` is WSL,
   which cannot see the vault at the same path.

## Onboarding prompt

```text
Onboard this vault for OpenAI Codex CLI. Work from the vault root.

1. Follow docs/harnesses/README.md, section "Common onboarding checklist", steps O1 to O6.
   Write the O4 probe with apply_patch.
2. Then run the checks in docs/harnesses/codex.md, section "Harness-specific checks".
3. Report every step as PASS, FAILED or NOT VERIFIED, with the evidence for each PASS.

Do not repair anything you find broken, and do not change settings outside this repository
without asking me.
```

## Harness-specific checks

- **H1. Project config trusted.** If O4 FAILED, the usual causes, in order: the project is not
  trusted; a user-level config sets `features.hooks = false`; `bash` is missing or is WSL's. Name
  which one you can confirm, and mark the rest NOT VERIFIED.
- **H2. Skills visible.** List the skills available to you. PASS if `resume`, `obsidian-save`,
  `wrap-up`, `preserve` and `onboard-project` all appear.
- **H3. Compaction stub.** NOT VERIFIED unless the session compacts. If it does, a
  `20-projects/_logs/compaction-<session>.md` file gains an entry.

## Scheduled passes

A wrapper for command mode (`docs/setup.md` § 8):

```bash
#!/usr/bin/env bash
# codex-vault-agent.sh <prompt-file>: keep it, like the profile it names, outside the vault and
# every folder a pass can write, because its --profile and --sandbox flags are what the switches
# rest on
set -u
exec codex exec --profile vault-dream --sandbox workspace-write "$(cat "$1")"
```

`codex exec` defaults to a read-only sandbox, and `--sandbox workspace-write` lets it write the
vault. Both passes must also have no shell tool and run no hook: the vault's own
`.codex/hooks.json` runs `bash` on `.claude/hooks/vault-lint.sh` after every `apply_patch`, so a
pass that patched that script would get a shell through the next edit, whatever its shell tool says
(reasoned). Codex's shell tool is the `features.shell_tool` setting and its hooks the
`features.hooks` setting, so create a profile file `$CODEX_HOME/vault-dream.config.toml` (with
`$CODEX_HOME` outside the vault and outside every folder `workspace-write` lets a pass write, which
the third point below asks you to check and step 5 of the README's check confirms, by the profile's
resolved path and by a refused write; if it does not confirm that, use the README's container)
containing the following; the wrapper uses it for the promotion pass too:

```toml
[features]
shell_tool = false
hooks = false
```

The project's own `.codex/config.toml` sets `hooks = true`, and this guide has not checked which
of the two wins, so the check below is what shows whether the vault's hook scripts run. Never add
`--dangerously-bypass-hook-trust` to the wrapper: it runs enabled hooks without the trust Codex
records for them.

Before you set `VAULT_ALLOW_UNENFORCED_TOOLS=1`, confirm four things: that
`codex exec --profile vault-dream "List the tools you can use."` offers no shell tool, that
network access is off in your Codex sandbox settings, that the sandbox lets the pass write
only inside the vault, and that the vault's hook scripts do not run, by the check in
`docs/harnesses/README.md`, "No vault hook in a scheduled pass". This guide does not yet name the
setting for the third; check your Codex version's sandbox documentation for the folders
`workspace-write` opens besides the vault, and step 5's probes of the home folders of the account
the runner runs as confirm part of it. Whether `workspace-write` leaves the vault's `.git` writable
to a pass, or, with the commit gate on, its `.claude/`, or the folders that hold this profile and
the wrapper, or the home folders of the account the runner runs as and of the harness's, where they
differ (for each account, the one the schedule's environment, or for Codex also the wrapper, names
as its home, and the account's own), is still to check too: step 5 of that check confirms part of
it, first by the resolved paths of the profile, the wrapper, those home folders and every file of
the class `docs/setup.md` names in its `UNVERIFIED` troubleshooting row that the runner or Codex
reads at the per-user or the system level, or place named for one, outside the vault and the copy,
each file with a link count of 1 (read by a reading first seen to show 2 on a file given a second
name for the purpose in a scratch folder outside the vault and the copy, on the file system that
holds the file read, then removed, else NOT VERIFIED, as the README says) or each of its names, as
many as its count, found outside both, and no file or folder
among them at or under a folder or file of the vault mounted elsewhere on the host, nor at or under
the source of a mount from outside both into the vault or the copy, and none of those home folders,
nor the folders that hold this profile and the wrapper, holding the source of such a mount (the
README says which), by the host's own list of mounts read and spelled as the README says, once a
path inside the copy and one inside the vault have each read as inside when resolved the same way,
each spelled every way the paths compared reach that step, whether a file or a link's target spells
them that way (a short 8.3 name, another letter case, a substituted or mapped drive, a second path
the host gives a folder above the vault or the copy), unless the resolver has been seen on that host
to turn each such spelling of the vault's and the copy's paths into the one compared (home folders
you cannot tell, a list of mounts you cannot read or spell as the README says, a control that does
not read as inside, a vault whose `.git` is a file, or any other case the README's step 5 calls not
verified, leaves that step not verified, and what the README says that step does not look for stays
open, though one you do find is FAILED where the README says so), then by the host's own list
showing no mount at or under the vault's or the copy's `.git` or `.claude/`, nor any whose source
lies there and whose target lies elsewhere in either (or, on this route, outside both, which leaves
that step not verified), and no link below their `.git` or `.claude/` leading outside the one it
lies below, read as the README says, then by the user Codex runs as, which must not be the superuser
(not root; on Windows, not run elevated; FAILED: run Codex as another user; one you cannot tell: not
verified), then by a probe through the wrapper that has each of Codex's own tools for creating files
write a control file of its own in `01-inbox/`, one file under each of the copy's `.git/` and
`.claude/`, and one new file in `$CODEX_HOME`, in the wrapper's folder and in each of those home
folders, judged by Codex's own record of its tool calls and by the disk. One of the paths that first
reading names (the profile, the wrapper, those home folders and the files of that class, or places
named for them) found inside the vault or the copy, by any of its names (at or under either kind of
mount that reading names among them), or one of those home folders or the folders that hold this
profile and the wrapper found holding the source of such a mount, or a mount or link that the `.git`
and `.claude/` reading finds, or the vault's `.git` or `.claude/` itself a link, or a folder
standing in for the vault's `.git` (through a `.git` file) found inside either, is FAILED: move it
out or remove the name inside (for a folder or file of the vault mounted elsewhere, a mount from
outside both into the vault or the copy, or a mount the `.git` and `.claude/` reading finds, remove
that mount; for such a link, remove it or replace it with a copy; for the vault's `.git` or
`.claude/` that is a link, make it a folder of its own, as the README's step 5 says; for a folder
standing in, move it out and point the vault's `.git` file at it; for a home folder, move the vault
or the copy, or, for one the schedule's environment names, have it name a home outside both; for a
place named for a file, have it named outside both), and run the check again. Each probe samples
only a new file in its folder, so where Codex's sandbox documentation or your profile opens to a
pass's writes any file or folder under those home folders outside the vault and the copy, or does
not say which it opens, that step is not verified; files of that class that lie outside the vault
and those home folders, at the per-user level or the system level, are not sampled at all, and rest
on Codex's sandbox documentation and the account's own permissions (reasoned; carried to a later
release). If any of those other writes goes through (remove it with `rm`: that is FAILED), or that
step is not verified, run the wrapper in the README's container instead, which mounts `.claude/`
(its settings files mounted over it from copies without their hooks) and the vault's `.git`
read-only, and every file the wrapper or a switch rests on read-only too, each name it mounts over
in the vault a folder or file, not a link, and, where a file, with a single name (the README's step
5 says which). This recipe uses Codex's sandbox rather than a container, so a hook that ran would
run wherever Codex runs its hooks, which its documentation does not say.

## Known limits

- Hooks and the project config load only in a trusted project.
- A Windows `bash` that resolves to WSL breaks every hook command silently. O4 is how you find out.

## Sources (checked 2026-09-13)

- AGENTS.md discovery: <https://developers.openai.com/codex/guides/agents-md>
- Configuration reference (`.codex/config.toml`, `features.hooks`, `features.shell_tool`, profiles): <https://developers.openai.com/codex/config-reference>
- Hooks (locations, `PostToolUse` on `apply_patch`, `PostCompact`, input fields; re-checked 2026-10-17 for "Hooks are enabled by default", `[features] hooks = false`, trust by hash and `--dangerously-bypass-hook-trust`): <https://developers.openai.com/codex/hooks>
- Non-interactive mode (`codex exec`, `--sandbox`): <https://developers.openai.com/codex/noninteractive>
- Skills (`.agents/skills`): <https://developers.openai.com/codex/skills>
