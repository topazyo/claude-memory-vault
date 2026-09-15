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
# gemini-vault-agent.sh <prompt-file>
set -u
exec gemini --approval-mode auto_edit -p "$(cat "$1")"
```

`auto_edit` approves file edits and asks for anything else. A scheduled run cannot answer, so
shell commands are not approved. That suits both passes, because neither needs a shell. The
runner records the history the promotion agent reads and commits its notes. Gemini CLI's sandbox (`tools.sandbox`) blocks network access by
default (`tools.sandboxNetworkAccess: false`). Enable it for scheduled runs before you set
`VAULT_ALLOW_UNENFORCED_TOOLS=1`.

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
