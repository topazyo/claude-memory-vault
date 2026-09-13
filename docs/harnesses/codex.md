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
# codex-vault-agent.sh <prompt-file>
set -u
case "$1" in
  *dream-pass*) exec codex exec --profile vault-dream --sandbox workspace-write "$(cat "$1")" ;;
  *)            exec codex exec --sandbox workspace-write "$(cat "$1")" ;;
esac
```

`codex exec` defaults to a read-only sandbox, and `--sandbox workspace-write` lets it write the
vault. The dream pass must also have no shell. Codex's shell tool is the `features.shell_tool`
setting, so create a profile file `$CODEX_HOME/vault-dream.config.toml` containing:

```toml
[features]
shell_tool = false
```

Before you set `VAULT_ALLOW_UNENFORCED_TOOLS=1`, confirm two things: that
`codex exec --profile vault-dream "List the tools you can use."` offers no shell tool, and that
network access is off in your Codex sandbox settings.

## Known limits

- Hooks and the project config load only in a trusted project.
- A Windows `bash` that resolves to WSL breaks every hook command silently. O4 is how you find out.

## Sources (checked 2026-09-13)

- AGENTS.md discovery: <https://developers.openai.com/codex/guides/agents-md>
- Configuration reference (`.codex/config.toml`, `features.hooks`, `features.shell_tool`, profiles): <https://developers.openai.com/codex/config-reference>
- Hooks (locations, `PostToolUse` on `apply_patch`, `PostCompact`, input fields): <https://developers.openai.com/codex/hooks>
- Non-interactive mode (`codex exec`, `--sandbox`): <https://developers.openai.com/codex/noninteractive>
- Skills (`.agents/skills`): <https://developers.openai.com/codex/skills>
