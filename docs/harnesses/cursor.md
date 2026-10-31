# Cursor

Cursor reads `AGENTS.md` on its own. The template ships project hooks for the lint and the
compaction stub, and an ignore file for the secret paths.

## What ships

| File | What it does |
| --- | --- |
| `.cursor/hooks.json` | `afterFileEdit` runs `vault-lint.sh`; `preCompact` runs `postcompact-wrap-up.sh` |
| `.cursorignore` | Blocks Agent, Tab and @-mention access to `.env`, `.env.*`, `secrets/` |
| `.agents/skills/` and `.claude/skills/` | Cursor reads both. The copies are identical, so a skill may be listed twice |

Project hooks run from the project root, which is why the commands use relative paths. Cursor's
`preCompact` input carries no session id, so the stub is keyed on `conversation_id`.

## Enforced, and guidance

- **Enforced:** the lint after each agent file edit, the compaction stub, and `.cursorignore` for
  Agent, Tab and @-mentions.
- **Not covered:** `.cursorignore` does not apply to Cursor's terminal or MCP tools, so a shell
  command can still read a secret. That part is guidance.

## Setup

1. Open the vault folder as the workspace and trust it. Project hooks run only in trusted
   workspaces.
2. On Windows, make sure `bash` resolves to Git Bash, not WSL's `System32\bash.exe`.

## Onboarding prompt

```text
Onboard this vault for Cursor. Work from the vault root.

1. Follow docs/harnesses/README.md, section "Common onboarding checklist", steps O1 to O6.
   Write the O4 probe with your file edit tool.
2. Then run the checks in docs/harnesses/cursor.md, section "Harness-specific checks".
3. Report every step as PASS, FAILED or NOT VERIFIED, with the evidence for each PASS.

Do not repair anything you find broken, and do not change settings outside this repository
without asking me.
```

## Harness-specific checks

- **H1. Hook failure causes.** If O4 FAILED: the workspace is not trusted; `bash` is missing or is
  WSL's; the probe was written from the terminal rather than by the edit tool. Name the one you can
  confirm.
- **H2. Skills visible.** List your skills. PASS if all five vault skills appear. A duplicate
  entry is expected, not a failure.
- **H3. Compaction stub.** NOT VERIFIED unless the conversation compacts. If it does, a
  `20-projects/_logs/compaction-<conversation-id>.md` file gains an entry.

## Scheduled passes

```bash
#!/usr/bin/env bash
# cursor-vault-agent.sh <prompt-file>
set -u
exec agent -p --force "$(cat "$1")"
```

`-p` runs Cursor's CLI without a session, and `--force` lets it change files without confirmation.
Neither flag limits shell or network access, so run the wrapper inside a container or VM that blocks
the network and, for both passes, has no shell available to the agent, and mounts only the vault
writable. The vault's `.cursor/hooks.json` runs `bash` on `.claude/hooks/vault-lint.sh` after every
edit, and Cursor can load Claude Code hooks too, so a pass that rewrote that script would get a
shell through its next edit (reasoned). This guide names no Cursor setting that turns project hooks
off, so in the container mount `.cursor/` read-only from a copy whose `hooks.json` has no hooks,
`.claude/` read-only from the vault's own folder, with its `settings.json`, and any
`settings.local.json`, mounted over it from copies without their hooks, so a pass can add no hook
file either (run the check again whenever a `settings.local.json` appears or changes), the vault's
`.git` read-only, and an empty file from outside the vault read-only over its `.env` (if the vault
has no `.env`, create an empty one there first, as the README says), with each name these mounts
cover a folder or file in the vault, not a link, and, where a file, with a single name (the README's
step 5 says which), load none of your home configuration, and mount, read-only
and from outside the vault, files holding no hooks (a hook-free copy or an empty hook list, since an
empty file may not parse) over `~/.cursor/hooks.json` and `~/.claude/settings.json` in the
container's home, the user-level hook files Cursor's third-party hooks reference lists, with each of
them, and each folder above it in that home, a file or folder in the container, not a link (the
README's step 5 says which): that reference says "Cursor watches config files and reloads them
automatically", so a hook file a pass wrote there could load within the same run (whether the CLI
watches is not documented: reasoned), as could one at the vault's `.cursor/` or `.claude/` where
that name is a link (the README's step 5 fails that layout). Start a new container for each run,
whose own filesystem is discarded at exit, as the README's container rule says, so that a pass's
other writes under `~/.cursor/` or `~/.claude/` in the container cannot reach the next run
(reasoned; within the same run they stay open, the folders that hold the two files included, as the
README says), and follow the rest of `docs/harnesses/README.md`, "No vault hook in a scheduled
pass", including its check. Only then set `VAULT_ALLOW_UNENFORCED_TOOLS=1`.

## Known limits

- The terminal and MCP tools bypass `.cursorignore`.
- A file written from the terminal is not linted. The commit gate catches it.

## Sources (checked 2026-09-13)

- Rules and AGENTS.md: <https://cursor.com/docs/context/rules>
- Hooks (project `hooks.json`, working directory, `afterFileEdit`, `preCompact`, common input, exit codes): <https://cursor.com/docs/agent/hooks>
- Third-party hooks ("Cursor supports loading hooks from third-party tools like Claude Code"; checked 2026-10-18): <https://cursor.com/docs/agent/third-party-hooks>
- Third-party hooks reference (the Claude Code files Cursor loads hooks from, `.claude/settings.local.json` among them, read 2026-10-19; `~/.cursor/hooks.json`, `~/.claude/settings.json` and "Cursor watches config files and reloads them automatically", read 2026-10-23): <https://cursor.com/docs/reference/third-party-hooks>
- Ignore file: <https://cursor.com/docs/context/ignore-files>
- Headless CLI (`-p`, `--force`): <https://cursor.com/docs/cli/headless>
- Skills (skill directories): <https://cursor.com/docs/context/skills>
