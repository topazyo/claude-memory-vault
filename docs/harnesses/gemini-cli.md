# Gemini CLI

Gemini CLI reads `GEMINI.md` by default. The shipped project settings point it at `AGENTS.md`
instead, and add hooks for the lint and the compaction stub.

> Gemini CLI's documentation says that on 2026-06-18 unpaid-tier and Google One users were moved to
> Antigravity CLI. This guide covers Gemini CLI only. If you use Antigravity CLI, treat it as an
> unverified harness and run the onboarding checks before relying on anything here.

## What ships

| File | What it does |
| --- | --- |
| `.gemini/settings.json` | `context.fileName: ["AGENTS.md"]`; an `AfterTool` hook on `write_file` and `replace` runs `vault-lint.sh`; a `PreCompress` hook runs `postcompact-wrap-up.sh` |
| `.geminiignore` | Lists `.env`, `.env.*`, `secrets/` |
| `.agents/skills/*/SKILL.md` | The five skills, in the folder Gemini CLI reads for workspace skills |

The hook commands use `$GEMINI_PROJECT_DIR`, which Gemini CLI sets for every hook. It also sets
`CLAUDE_PROJECT_DIR` as an alias, and the scripts use that to find the vault.

## Enforced, and guidance

- **Enforced:** the lint after `write_file` and `replace`, and the compaction stub. Hooks are on
  unless someone set `hooksConfig.enabled` to false.
- **Partial:** `.geminiignore` keeps the secret paths out of Gemini CLI's file search. The
  documentation does not describe it as a block on reading a named file, so treat reads of those
  paths as guidance.
- **Not linted:** a file written by a shell command. The commit gate catches it.

## Setup

1. Start `gemini` from the vault root, and trust the folder when asked. Gemini CLI fingerprints
   project hooks and warns before running a new or changed one, so approve the two vault hooks
   the first time. The warning coming back after a `git pull` means a hook command changed, and
   is worth reading before you approve again.
2. On Windows, make sure `bash` on your `PATH` is Git Bash, not WSL's `System32\bash.exe`.

## Onboarding prompt

```text
Onboard this vault for Gemini CLI. Work from the vault root.

1. Follow docs/harnesses/README.md, section "Common onboarding checklist", steps O1 to O6.
   Write the O4 probe with write_file.
2. Then run the checks in docs/harnesses/gemini-cli.md, section "Harness-specific checks".
3. Report every step as PASS, FAILED or NOT VERIFIED, with the evidence for each PASS.

Do not repair anything you find broken, and do not change settings outside this repository
without asking me.
```

## Harness-specific checks

- **H1. AGENTS.md is the context file.** O1 is the evidence. If O1 FAILED, check whether a user
  or system settings file overrides `context.fileName`, and report what you find.
- **H2. Hook failure causes.** If O4 FAILED, the usual causes: `hooksConfig.enabled` is false in
  another settings layer; `bash` is missing or is WSL's; the probe was written by a shell command
  rather than `write_file`. Name the one you can confirm.
- **H3. Skills visible.** List your available skills. PASS if all five vault skills appear.
- **H4. Compaction stub.** NOT VERIFIED unless the session compresses. If it does, a
  `20-projects/_logs/compaction-<session>.md` file gains an entry.

## Scheduled passes

```bash
#!/usr/bin/env bash
# gemini-vault-agent.sh <prompt-file>: keep it outside the vault and every folder a pass can
# write, because the runner starts it outside every sandbox
set -u
exec gemini --approval-mode auto_edit -p "$(cat "$1")"
```

`auto_edit` approves file edits and asks for anything else. A scheduled run cannot answer, so shell
commands are not approved. That suits both passes, because neither needs a shell. The runner records
the history the promotion agent reads and commits its notes. Gemini CLI's sandbox (`tools.sandbox`)
blocks network access by default (`tools.sandboxNetworkAccess: false`). Enable it for scheduled
runs, with only the vault writable, before you set `VAULT_ALLOW_UNENFORCED_TOOLS=1` (step 5 of the
README's check confirms part of that, with probes of the home folders of the account the runner runs
as and of `~/.gemini/`, and a sandbox that leaves the vault's `.git` or `.claude/` writable will not
pass it, nor will one whose profile or documentation opens to a pass's writes any file or folder
under those home folders outside the vault and the copy, or does not say which it opens; reasoned).

Approval covers tool calls, not hooks: the vault's `.gemini/settings.json` runs `bash` on
`.claude/hooks/vault-lint.sh` after every `write_file` and `replace`, so a pass that rewrote that
script would get a shell through its next write (reasoned). Turn hooks off for scheduled runs with
`hooksConfig.enabled: false` in a settings file outside the vault, in a folder the sandbox does not
let a pass write (step 5 of the README's check confirms both, by the file's resolved path and by a
refused write; where it does not, use the container), that outranks the project's (H2 names that key
as what stops the lint), or run the wrapper in a container as `docs/harnesses/README.md`, "No vault
hook in a scheduled pass", describes, and run that section's check, which shows that the vault's
hook scripts do not run and that writes into `.git` and `.claude/` are refused, before setting
`VAULT_ALLOW_UNENFORCED_TOOLS=1`. Whether the sandbox leaves the vault's `.git` writable to a pass,
or, with the commit gate on, its `.claude/`, or the folders that hold that settings file and the
wrapper, or the home folders of the account the runner runs as and of the harness's, where they
differ (for each account, the one the schedule's environment, or for Gemini CLI also the wrapper,
names as its home, and the account's own), or `~/.gemini/` under each home folder of the account
Gemini CLI runs as, is still to check: step 5 of that check confirms it, first by the resolved paths
of the settings file, the wrapper, those home folders and every file of the class `docs/setup.md`
names in its `UNVERIFIED` troubleshooting row that the runner or Gemini CLI reads at the per-user
level (one inside the vault or the copy, by any of its names, is FAILED: move it out or remove the
name inside (for a folder of the vault mounted elsewhere, remove that mount), or for a home folder
move the vault or the copy, and run the check again), each file with a link count of 1 or each of
its names found outside both, and no folder of the vault mounted elsewhere on the host, after a path
inside the copy and one inside the vault have each read as inside when resolved the same way
(otherwise that step is not verified), then by the user Gemini CLI runs as, which must not be the
superuser (not root; on Windows, not run elevated; FAILED: run Gemini CLI as another user; one you
cannot tell: not verified), then by a probe through the wrapper that has each of Gemini CLI's own
tools for creating files write a control file of its own in `01-inbox/`, one file under each of the
copy's `.git/` and `.claude/`, and one new file in the settings file's folder, in the wrapper's
folder, in each of those home folders and, where it is not the settings file's folder, in
`~/.gemini/`, judged by Gemini CLI's own record of its tool calls and by the disk. Each probe
samples only a new file in its folder, so where the sandbox's profile or documentation opens to a
pass's writes any file or folder under those home folders outside the vault and the copy, or does
not say which it opens, that step is not verified; files of that class that lie outside the vault
and those home folders, at the per-user level or the system level, are not sampled at all, and rest
on the sandbox's documentation and the account's own permissions (reasoned; carried to a later
release). If any of those other writes goes through (remove it with `rm`: that is FAILED), or that
step is not verified, use the container. This guide has not checked which settings layers outrank
the project's for that key, and a pass could write `"hooksConfig": {"enabled": true}` into the
vault's own `.gemini/settings.json`. So, on the switch route, add exactly that to the scratch copy's
`.gemini/settings.json` before the check's step 4: the hooks must stay off even then. If they do
not, use the container, with `.gemini/`, `.claude/` and `.git` read-only, and an empty file from
outside the vault read-only over the vault's `.env` (if the vault has none, create an empty one
there first), as the README says.

## Known limits

- `.geminiignore` is a search filter, not a read deny.
- Hook stdout must be empty or JSON. The vault scripts print nothing to stdout, so do not add
  `echo` lines to them.

## Sources (checked 2026-09-13)

- Context file name (`context.fileName`): <https://geminicli.com/docs/cli/gemini-md/>
- Configuration reference (`hooksConfig`, `tools.sandbox`, `--approval-mode`, `.geminiignore`): <https://geminicli.com/docs/reference/configuration/>
- Hooks (configuration schema, `AfterTool`, `PreCompress`, input fields, environment variables, JSON rule): <https://geminicli.com/docs/hooks/> and <https://geminicli.com/docs/hooks/reference/>
- Headless mode (`-p` / `--prompt`): <https://geminicli.com/docs/cli/headless/>
- Skills (`.agents/skills/` alias): <https://geminicli.com/docs/cli/skills/>
