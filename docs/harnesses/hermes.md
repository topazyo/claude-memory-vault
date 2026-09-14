# Hermes Agent

Hermes Agent, from Nous Research, reads `AGENTS.md` on its own and loads repository skills from
`.agents/skills/` once you trust the repository. Its shell hooks live only in your user
configuration, `~/.hermes/config.yaml`, so the template cannot ship a hook file for it. This guide
gives the snippet, and the onboarding prompt has the agent propose it for your approval.

## What ships

| File | What it does |
| --- | --- |
| `.agents/skills/*/SKILL.md` | The five skills, in Hermes's cross-tool project skills folder |
| `vault-lint.sh --ack-json` | The lint prints `{}` on stdout, because Hermes reads a hook's stdout back as JSON |

## Enforced, and guidance

- **Enforced, once you add the snippet:** the lint after `write_file` and `patch`. Hermes asks you
  to approve each new hook command the first time it sees it.
- **No compaction stub:** no compaction event was found among Hermes's hook events.
- **Guidance:** reads of `.env` and `secrets/`. Hermes's write guards cover `write_file` and
  `patch` only, and its documentation says they are not a hard boundary, because the terminal tool
  runs as the same OS user.

## Setup

1. From the vault root, run `hermes skills trust`. Without it Hermes finds the project skills but
   does not load them.
2. Add this to `~/.hermes/config.yaml`, with the absolute path to your vault:

   ```yaml
   hooks:
     post_tool_call:
       - matcher: "write_file|patch"
         command: "bash /path/to/your-vault/.claude/hooks/vault-lint.sh --ack-json"
         timeout: 15
   ```

3. Start a session in the vault and approve the hook when Hermes asks.

The snippet is per machine, because it names an absolute path, and it applies to every Hermes
session. In other projects the lint acts only on files whose paths look like vault content folders
or steering files (such as an `AGENTS.md`), and it records those in this vault's
`.claude/logs/vault-lint.log`.

## Onboarding prompt

```text
Onboard this vault for Hermes Agent. Work from the vault root.

1. Follow docs/harnesses/README.md, section "Common onboarding checklist", steps O1 to O6.
   If the hook from docs/harnesses/hermes.md is not in ~/.hermes/config.yaml yet, do not add it
   yourself: show me the snippet with this vault's absolute path filled in, and mark O4 NOT
   VERIFIED until I have added it and restarted the session. Write the O4 probe with write_file.
2. Then run the checks in docs/harnesses/hermes.md, section "Harness-specific checks".
3. Report every step as PASS, FAILED or NOT VERIFIED, with the evidence for each PASS.

Do not repair anything you find broken, and do not change settings outside this repository
without asking me.
```

## Harness-specific checks

- **H1. Project skills trusted.** List your skills. PASS if all five vault skills appear tagged
  `[project]`. If Hermes reports project skills found but not loaded, the repository is not
  trusted.
- **H2. Hook failure causes.** If O4 FAILED: the snippet is missing or names the wrong path; the
  hook was never approved; `bash` is missing. Name the one you can confirm.

## Scheduled passes

```bash
#!/usr/bin/env bash
# hermes-vault-agent.sh <prompt-file>
set -u
exec hermes chat -q "$(cat "$1")"
```

`hermes chat -q` answers one query and exits. Because Hermes's own guards are not a hard boundary,
run the wrapper in a container that blocks the network. For the dream pass, also remove the
terminal tool, for example through `agent.disabled_toolsets` (check `hermes tools` for the toolset
that provides it). Only then set `VAULT_ALLOW_UNENFORCED_TOOLS=1`.

## Known limits

- The hook lives in user configuration, so every clone and every machine needs the snippet.
- No compaction stub.

## Sources (checked 2026-09-13)

- Context files (`AGENTS.md`, `.hermes.md`, `CLAUDE.md`): <https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/context-files.md>
- Skills (project skills, `hermes skills trust`): <https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/skills.md>
- Event hooks (shell hooks in `config.yaml`, events, JSON wire protocol, consent): <https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/hooks.md>
- Configuration (`agent.disabled_toolsets`, approvals): <https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/configuration.md>
- Security (write guards not a hard boundary): <https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/security.md>
- CLI (`hermes chat -q`): <https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/cli-commands.md>
