# OpenCode

OpenCode reads `AGENTS.md` on its own. The template ships a config that loads the vault's rules
automatically, and a plugin, **off until you enable it**, that lints written notes, records
compactions, and denies reads of the secret paths.

## What ships

| File | What it does |
| --- | --- |
| `opencode.json` | `"instructions": [".claude/rules/*.md"]` loads all four rules files into every session |
| `.claude/adapters/opencode/vault.js` | The plugin, kept outside `.opencode/plugins/` so it does not load. Once enabled it denies `read` on `.env`, `.env.*` and anything under `secrets/`; runs `vault-lint.sh` after `write`, `edit` and `apply_patch`; runs `postcompact-wrap-up.sh` on `session.compacted` |
| `.agents/skills/` and `.claude/skills/` | OpenCode reads both. The copies are identical, and whether OpenCode lists a same-named skill once or twice was not documented |

**Why the plugin is opt-in.** OpenCode loads every file in `.opencode/plugins/` at startup and runs
it, with no trust prompt. A plugin shipped there would run code from any clone of a vault the
moment someone opened it, including a clone of someone else's vault. The other harnesses in these
guides ask before running project hooks; OpenCode's documentation describes no such step. So the
plugin ships where OpenCode does not look, and you copy it in once you have read it.

OpenCode already denies reading `*.env` files by default. The plugin adds `.env.*` and `secrets/`,
the rest of the set `.claude/rules/security.md` names.

## Enforced, and guidance

- **Enforced without the plugin:** the rules are loaded, and OpenCode's default deny covers
  `*.env`.
- **Enforced once the plugin is enabled:** the lint runs after the three edit tools, compactions
  are recorded, and the read tool refuses `.env.*` and `secrets/` too, in any letter case.
- **Not covered:** the `bash` tool can still `cat` a secret, and a file written from `bash` is not
  linted. The rule is the control for the first, and the commit gate catches the second.

## Setup

1. Read `.claude/adapters/opencode/vault.js`. It is about sixty lines and runs two bash scripts
   from `.claude/hooks/`.
2. Enable it by copying it where OpenCode loads plugins, from the vault root:

   ```bash
   mkdir -p .opencode/plugins
   cp .claude/adapters/opencode/vault.js .opencode/plugins/vault.js
   ```

   Commit the copy if you want every clone of your vault to run it. Leave it uncommitted to keep
   it on this machine only.
3. Start `opencode` from the vault root. The plugin locates the vault from OpenCode's worktree.
   `bash` must be on the `PATH` OpenCode runs with, and on Windows it must be Git Bash.
3. Optional: set `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` so OpenCode lists each skill once, from
   `.agents/skills/`.

## Onboarding prompt

```text
Onboard this vault for OpenCode. Work from the vault root.

1. Follow docs/harnesses/README.md, section "Common onboarding checklist", steps O1 to O6.
   Write the O4 probe with the write tool. If .opencode/plugins/vault.js does not exist, do not
   copy it there yourself: tell me the plugin is not enabled, point me to the setup section of
   docs/harnesses/opencode.md, and mark O4 and H2 NOT VERIFIED.
2. Then run the checks in docs/harnesses/opencode.md, section "Harness-specific checks".
3. Report every step as PASS, FAILED or NOT VERIFIED, with the evidence for each PASS.

Do not repair anything you find broken, and do not change settings outside this repository
without asking me.
```

## Harness-specific checks

- **H1. Rules loaded by config.** Without opening `.claude/rules/`, quote one line from
  `untrusted-captures.md`. PASS if you can, because `opencode.json` put it in your context.
- **H2. Read guard.** Use the read tool on `secrets/harness-probe.txt`. The file does not need to
  exist. PASS if the call fails with `vault: reading .env, .env.* and secrets/ is denied`. A "file
  not found" error means the plugin did not run: FAILED.
- **H3. Hook failure causes.** If O4 or H2 FAILED: the plugin did not load (check OpenCode's
  startup output for an error naming `vault.js`); `bash` is missing or is WSL's. Name the one you
  can confirm.
- **H4. Compaction stub.** NOT VERIFIED unless the session compacts. If it does, a
  `20-projects/_logs/compaction-<session>.md` file gains an entry. If the event carries no session
  id, the stub is keyed on the date and `.claude/logs/hook-events.log` says so.

## Scheduled passes

```bash
#!/usr/bin/env bash
# opencode-vault-agent.sh <prompt-file>: keep it, like the container definition, outside the
# vault and every folder a pass can write (docs/harnesses/README.md)
set -u
case "$1" in
  *dream-pass*)     agent=vault-dream ;;
  *promotion-pass*) agent=vault-promotion ;;
  *) echo "opencode-vault-agent: expected a dream-pass or promotion-pass prompt file, got '$1'" >&2; exit 64 ;;
esac
exec opencode run --dir . --agent "$agent" "$(cat "$1")"
```

`opencode run` is non-interactive. Its `--auto` flag approves every permission not explicitly
denied, so if you add it, first deny what each pass must not have. OpenCode agents take per-agent
`permission` settings: an agent for each pass with `bash` and `webfetch` denied, named `vault-dream`
and `vault-promotion` as the wrapper selects them with `--agent` (define both), keeps both passes'
own tools off the shell and the web. A permission covers only the tools it names, so ask each agent
which tools it has and deny any other that can run a command or reach the web, `task` among them,
which starts subagents that may have tools of their own (reasoned: this guide has not listed them).
Network access through other routes is not covered by permissions, so still run the wrapper in a
container that blocks the network and mounts only the vault writable before setting
`VAULT_ALLOW_UNENFORCED_TOOLS=1`. If OpenCode finds no agent by the name it is given, it may fall
back to its default agent, which has `bash`, so first check, in the container, that
`opencode run --dir . --agent vault-dream "Run the shell command ls."` is refused and prints no
fallback warning, and the same for `vault-promotion`.

Keep plugins out of scheduled runs. The vault's plugin, once enabled, runs `bash` on
`.claude/hooks/vault-lint.sh` after every write, so a pass that rewrote that script would get a
shell through its next write (reasoned), and OpenCode runs any file in `.opencode/plugins/` with no
trust prompt, so a pass could also add one. OpenCode also takes the singular `.opencode/plugin/`
("Singular names … are also supported"), npm plugins through `opencode.json`'s `plugin` option, and
custom tools from `.opencode/tools/`, which "can invoke scripts written in any language". Whether or
not you enabled the plugin, mount `.opencode/` read-only in the container from a copy with no
plugins and no tools, `opencode.json` read-only from a copy with no `plugin` option, the vault's
`.claude/` and `.git` read-only, and an empty file from outside the vault read-only over its `.env`
(create `.opencode/`, empty, in the vault before the first scheduled run if it is not there, and an
empty `.env` if there is none, as the README says: a mount at a missing path would create it during
a pass, and the runner would see a new path, reasoned), load none of your home configuration (its
global plugins included), start a new container for each run, whose own filesystem is discarded at
exit, as the README's container rule says, so that a global plugin a pass wrote in the container's
home cannot load at the next run (reasoned), and run the check in `docs/harnesses/README.md`, "No
vault hook in a scheduled pass", which shows that the vault's hook scripts do not run and that
writes into `.git` and `.claude/` are refused. OpenCode also "supports both JSON and JSONC", and its
config page does not say whether a project `opencode.jsonc` is read; if it is, a pass could add one
beside `opencode.json` that neither this mount nor the runner's steering filter names (reasoned;
carried to a later release).

## Known limits

- The plugin reads tool arguments as OpenCode's documentation shows them (`args.filePath`). The
  name of `apply_patch`'s patch argument was not documented, and the plugin assumes `patchText`.
  If it differs, patch edits go unlinted and the commit gate still catches them.
- `bash` tool reads and writes bypass the plugin.

## Sources (checked 2026-09-13; config, plugins and custom tools read again 2026-10-18)

- Rules, AGENTS.md and Claude Code compatibility: <https://opencode.ai/docs/rules/>
- Config (`instructions`; singular folder names and JSONC, read 2026-10-18): <https://opencode.ai/docs/config/>
- Permissions (keys, default `.env` deny): <https://opencode.ai/docs/permissions/> and <https://opencode.ai/docs/agents/>
- Plugins (`.opencode/plugins/`, `tool.execute.before`, `$`, `session.compacted`; the `plugin` option and load order, read 2026-10-18): <https://opencode.ai/docs/plugins/>
- Custom tools (`.opencode/tools/`), read 2026-10-18: <https://opencode.ai/docs/custom-tools/>
- Skills (discovery paths): <https://opencode.ai/docs/skills/>
- CLI (`opencode run`, `--auto`, `--dir`, `--agent`): <https://opencode.ai/docs/cli/>
