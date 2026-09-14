# GitHub Copilot

Covers Copilot in VS Code, Copilot CLI and the Copilot cloud agent. All three read `AGENTS.md`,
and all three load hooks from `.github/hooks/`.

## What ships

| File | What it does |
| --- | --- |
| `.github/hooks/vault.json` | `PostToolUse` on `Edit|Write` runs `vault-lint.sh` |
| `.agents/skills/` and `.claude/skills/` | Copilot reads both. The copies are identical, so a skill may be listed twice |

The hook uses the PascalCase event name `PostToolUse`, which selects Copilot's VS Code-compatible
payload (`tool_input`), and the lint reads that shape. Copilot's documentation describes
Claude-style `Edit|Write` matching for PascalCase `PreToolUse`. If your version does not apply the
matcher to `PostToolUse`, the lint also runs after non-edit tools, finds no file path, and logs a
`DEGRADED` line. That is noise, not a failure. The command is in
the `bash` field, the only one the cloud agent honors, and it locates the vault with
`git rev-parse --show-toplevel`.

**In VS Code the lint may run twice.** VS Code also loads hooks from `.claude/settings.json` and
rules from `.claude/rules/` by default. Two log lines per write are harmless. Whether VS Code sets
the `CLAUDE_PROJECT_DIR` variable those Claude-format commands use was not documented; if it does
not, that copy fails to find the script and `.github/hooks/vault.json` is the one that lints. If
you want a single lint, turn off the `.claude/settings.json` entry in the `chat.hookFilesLocations`
setting.

## Enforced, and guidance

- **Enforced:** the lint after agent edits. In VS Code, `.claude/rules/` is also loaded
  automatically.
- **No compaction stub:** no compaction hook was found in Copilot's documentation.
- **Guidance:** reads of `.env` and `secrets/`. Nothing shipped blocks them.

## Setup

1. **VS Code:** open the vault folder and check that `chat.useAgentsMdFile` is enabled.
2. **Copilot CLI:** start `copilot` in the vault root and trust the folder when asked.
3. On Windows, make sure `bash` resolves to Git Bash. If the hook does not fire, add a
   `powershell` entry to `.github/hooks/vault.json` that calls Git Bash's `bash.exe` by full path.

## Onboarding prompt

```text
Onboard this vault for GitHub Copilot. Work from the vault root, and tell me which surface you
are running in (VS Code, Copilot CLI or cloud agent).

1. Follow docs/harnesses/README.md, section "Common onboarding checklist", steps O1 to O6.
   Write the O4 probe with your file edit or create tool.
2. Then run the checks in docs/harnesses/copilot.md, section "Harness-specific checks".
3. Report every step as PASS, FAILED or NOT VERIFIED, with the evidence for each PASS.

Do not repair anything you find broken, and do not change settings outside this repository
without asking me.
```

## Harness-specific checks

- **H1. Hook failure causes.** If O4 FAILED: the folder is not trusted (CLI); hooks are disabled
  in your settings; `bash` is missing or is WSL's (Windows). Name the one you can confirm.
- **H2. Duplicate lint (VS Code).** Count the `vault-lint.log` lines for the O4 probe. Report one
  or two. Both are PASS.
- **H3. Skills visible.** List your skills. PASS if all five vault skills appear.

## Scheduled passes

```bash
#!/usr/bin/env bash
# copilot-vault-agent.sh <prompt-file>
set -u
exec copilot -p "$(cat "$1")"
```

`-p` runs Copilot CLI in programmatic mode. Add the tool-approval options your installed version
documents (`copilot --help`), because a programmatic run cannot answer approval prompts. Those options
are not a sandbox, so run the wrapper in a container that blocks the network and, for the dream
pass, gives the agent no shell. Only then set `VAULT_ALLOW_UNENFORCED_TOOLS=1`.

## Known limits

- No compaction stub.
- The cloud agent runs hooks in its own Linux sandbox, and its writes reach the vault only through
  a pull request. If you kept `.github/workflows/ci.yml`, that pull request runs `vault-check.sh`.

## Sources (checked 2026-09-13)

- Repository instructions and AGENTS.md: <https://docs.github.com/en/copilot/how-tos/configure-custom-instructions/add-repository-instructions>
- Hooks (file format, `bash`/`powershell`, payload formats, matchers): <https://docs.github.com/en/copilot/how-tos/use-copilot-agents/coding-agent/use-hooks> and <https://docs.github.com/en/copilot/reference/hooks-configuration>
- Copilot CLI (`-p`, trusted directories, AGENTS.md): <https://docs.github.com/en/copilot/how-tos/use-copilot-agents/use-copilot-cli>
- Agent skills (skill directories): <https://docs.github.com/en/copilot/concepts/agents/about-agent-skills>
- VS Code instructions (`chat.useAgentsMdFile`, `.claude/rules`): <https://code.visualstudio.com/docs/copilot/customization/custom-instructions>
- VS Code hooks (`.github/hooks`, `.claude/settings.json`, `chat.hookFilesLocations`): <https://code.visualstudio.com/docs/copilot/customization/hooks>
