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

`-p` runs Cursor's CLI without a session, and `--force` lets it change files without
confirmation. Neither flag limits shell or network access, so run the wrapper inside a container
or VM that blocks the network and, for the dream pass, has no shell available to the agent. Only
then set `VAULT_ALLOW_UNENFORCED_TOOLS=1`.

## Known limits

- The terminal and MCP tools bypass `.cursorignore`.
- A file written from the terminal is not linted. The commit gate catches it.

## Sources (checked 2026-09-13)

- Rules and AGENTS.md: <https://cursor.com/docs/context/rules>
- Hooks (project `hooks.json`, working directory, `afterFileEdit`, `preCompact`, common input, exit codes): <https://cursor.com/docs/agent/hooks>
- Ignore file: <https://cursor.com/docs/context/ignore-files>
- Headless CLI (`-p`, `--force`): <https://cursor.com/docs/cli/headless>
- Skills (skill directories): <https://cursor.com/docs/context/skills>
