# Pi

Pi, the terminal coding agent from Earendil Works (CLI `pi`), reads `AGENTS.md` on its own and
loads the vault's skills from `.agents/skills/` once you trust the vault. It asks for no approval
before a tool call, so the template ships an extension, **off until you load it**, that refuses
the secret paths, lints written notes and records compactions.

Pi was created as `pi-mono` by Mario Zechner and moved to Earendil Works in May 2026. Its npm
package is now `@earendil-works/pi-coding-agent`, and `@mariozechner/pi-coding-agent` is the old,
deprecated name. It is unrelated to Inflection AI's Pi assistant.

## What ships

| File | What it does |
| --- | --- |
| `.claude/adapters/pi/vault.js` | The extension, kept outside `.pi/extensions/` so Pi does not load it by itself. Once loaded it refuses a `read`, `write`, `edit`, `grep`, `find` or `ls` call whose path, or whose grep `glob`, names `.env`, `.env.*` or anything under `secrets/`; runs `vault-lint.sh` after each successful `write` and `edit`; runs `postcompact-wrap-up.sh` on `session_compact` |
| `.agents/skills/*/SKILL.md` | The five skills. Pi reads them once the project is trusted. It never reads `.claude/skills/`, so each skill is listed once |

At the vault root Pi reads `AGENTS.md` and not `CLAUDE.md`, because in each folder it loads only
the first of `AGENTS.override.md`, `AGENTS.md` and `CLAUDE.md` that exists. Nothing is lost:
`CLAUDE.md` is Claude Code's bridge to `AGENTS.md`.

**Why the extension is opt-in.** Pi runs everything in `.pi/extensions/` once a project is
trusted, and it treats a trust decision saved for a folder as covering every folder below it. A
vault cloned into a folder you had already trusted would therefore run a shipped extension without
asking, including a clone of someone else's vault. That is the risk the OpenCode plugin is opt-in
for, so this extension ships where Pi does not look, and you load it once you have read it.

## Enforced, and guidance

- **Enforced without the extension:** nothing. Pi loads `AGENTS.md` and, once the project is
  trusted, the skills, but it runs every tool without asking, and nothing stops a read of `.env`.
- **Enforced once the extension is loaded:** a file-tool call whose path names a secret is
  refused, in any letter case. The extension reads the path the way Pi's own tools will open it:
  a leading `@`, `~`, `file://` URLs, Windows drive and Git Bash forms, trailing dots and spaces,
  and NTFS stream names. It also follows symbolic links, so `@.env`, `.ENV.` and a note that links
  to `.env` are refused too. The lint runs after each successful `write` and `edit`, and
  compactions are recorded.
- **Not covered:** the `bash` tool, and `powershell` where you enable it, can still read a secret,
  and a file written from either is not linted. A `grep` over a parent folder is not refused for
  the files it passes through. Pi's grep searches hidden files, so what keeps `.env` out of it is
  ripgrep skipping what `.gitignore` lists, which it does only in a git repository. The template's
  `.gitignore` lists `.env`, `.env.*` and `secrets/`, but in a vault that is not a git repository
  such a grep reads `.env` as well. The rule is the control for all of these, and the commit gate
  catches the unlinted write.

## Setup

1. Install Pi from <https://pi.dev>.
2. **Before you trust the vault, look in `.pi/`.** In a vault made from this template it does not
   exist. Trusting a folder lets Pi run `.pi/extensions/`, install the packages `.pi/settings.json`
   declares and replace its system prompt from `.pi/SYSTEM.md`, and the decision covers every
   folder below it.
3. Start `pi` from the vault root and trust the project when it asks, or run `/trust`. Without
   trust Pi does not load `.agents/skills/`.
4. Read `.claude/adapters/pi/vault.js`. It is under 300 lines and runs two bash scripts from
   `.claude/hooks/`. Then load it in **one** of two ways. Using both loads it twice, and every
   compaction is recorded twice.
   - For one session: `pi -e .claude/adapters/pi/vault.js`. Pi loads an extension named with
     `-e` whether or not the project is trusted.
   - For every session in this clone, from the vault root:

     ```bash
     mkdir -p .pi/extensions
     cp .claude/adapters/pi/vault.js .pi/extensions/vault.js
     ```

     Pi then loads it whenever the project is trusted. Commit the copy if you want every clone of
     your vault to run it, and leave it uncommitted to keep it on this machine. The control suite
     fails when the copy differs from the adapter.
5. The lint and the compaction stub are bash scripts. On Windows the extension runs them with the
   bash Pi's own bash tool would pick: `shellPath` in `~/.pi/agent/settings.json`, then Git under
   Program Files, then `bash.exe` on `PATH`. It passes over WSL's `bash.exe` in `System32`,
   because the scripts are written for Git Bash.

The extension finds the vault from where its own file is, so starting `pi` in a subfolder still
lints against this vault, and starting it in some other tree never runs that tree's scripts.

## Onboarding prompt

```text
Onboard this vault for Pi. Work from the vault root.

1. First run check H2 in docs/harnesses/pi.md, section "Harness-specific checks". If the read is
   not refused, the vault extension is not loaded: do not load or copy it yourself. Tell me, point
   me to the setup section of docs/harnesses/pi.md, and mark O4, H2 and H4 NOT VERIFIED.
2. Follow docs/harnesses/README.md, section "Common onboarding checklist", steps O1 to O6.
   Write the O4 probe with the write tool.
3. Then run the other checks in docs/harnesses/pi.md, section "Harness-specific checks".
4. Report every step as PASS, FAILED or NOT VERIFIED, with the evidence for each PASS.

Do not repair anything you find broken, and do not change settings outside this repository
without asking me.
```

## Harness-specific checks

- **H1. Skills loaded.** List your skills. PASS if all five vault skills appear. If none do, the
  project is not trusted (setup step 3).
- **H2. Secrets guard.** Use the read tool on `secrets/harness-probe.txt`. The file does not need
  to exist. PASS if the call is refused with
  `vault: .env, .env.* and secrets/ are off limits (.claude/rules/security.md)`. A "file not
  found" error means the extension did not run: FAILED.
- **H3. Hook failure causes.** If O4 or H2 FAILED: the extension did not load (Pi reports a load
  error naming `vault.js` at startup); bash could not run the scripts (the extension shows one
  warning naming the script and what went wrong); the extension is not inside this vault. Name the
  one you can confirm.
- **H4. Compaction stub.** NOT VERIFIED unless the session compacts. You can ask the human to run
  `/compact`. Afterwards a `20-projects/_logs/compaction-<session>.md` file gains an entry.

## Scheduled passes

```bash
#!/usr/bin/env bash
# pi-vault-agent.sh <prompt-file>
set -u
case "${1:-}" in
  *dream-pass*)     tools=read,grep,find,ls,write ;;
  *promotion-pass*) tools=read,grep,find,ls,write,edit ;;
  *) echo "pi-vault-agent: expected a dream-pass or promotion-pass prompt file, got '${1:-}'" >&2; exit 64 ;;
esac
exec pi --print --no-session --no-approve --no-extensions --offline --tools "$tools" "$(cat "$1")"
```

- `--print` answers the prompt and exits. `--no-session` keeps the session in memory, and Pi keeps
  its other state under `~/.pi/agent/`, so nothing is written into the vault for the fence to trip
  on.
- `--tools` is Pi's own allowlist, and it covers tools an extension adds as well as the built-in
  ones. Leaving `bash` out of it takes the shell away, and Pi has no built-in web tool.
- `--no-approve` refuses project trust for this run, whatever you saved, so nothing under `.pi/`
  and no project `.agents/skills/` loads. The prompt file already carries the agent's
  instructions. `--no-extensions` keeps your personal extensions out as well, and `--offline`
  stops Pi's own automatic network requests.
- Pi still loads its global `~/.pi/agent/AGENTS.md`, your `~/.agents/skills/`, and any
  `AGENTS.md` or `CLAUDE.md` in the folders above the vault. Those steer the pass, and the fence
  cannot see them.

Pi cannot confine `write` and `edit` to a folder. So run the wrapper in a container that mounts
only the vault, with none of your home configuration, and whose only network route is your model
provider. Pi's grep and find need ripgrep and fd, and Pi downloads them into `~/.pi/agent/bin` when
it cannot find them, so put both in the image. Run the wrapper once against a scratch copy of the
vault and diff the tree before you schedule it. Only then set `VAULT_ALLOW_UNENFORCED_TOOLS=1`.

## Known limits

- The extension is written against Pi's extension API as of v0.87.1: the `tool_call`,
  `tool_result` and `session_compact` events and the `path` field of the file tools. If a later
  Pi renames that field, the guard refuses every `read`, `write` and `edit` and says why, rather
  than letting them through unchecked, and O4 shows the lint has stopped.
- `bash` and `powershell` reads and writes bypass the extension.
- A `grep` over a parent folder is not refused for what it passes through.
- Loaded from outside a vault, for example from `~/.pi/agent/extensions/`, the extension still
  guards the secret paths but lints nothing, and says so once.

## Sources (checked 2026-09-25, Pi v0.87.1)

- Context files, `AGENTS.override.md`, trust: <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/configuration.md> and <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/security.md>
- Skills (`.agents/skills/`, trust): <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/skills.md>
- Extensions (`.pi/extensions/`, `-e`, events): <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md>
- Compaction: <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/compaction.md>
- CLI (`--print`, `--tools`, `--no-approve`, `--no-extensions`, `--offline`, `--no-session`): <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md>
- Windows shell: <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/windows.md>
- Containers: <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/containerization.md>
- What the documentation leaves to the source, read at the same date: event and context shapes in `packages/coding-agent/src/core/extensions/types.ts` and `runner.ts`; tool inputs in `src/core/tools/{read,write,edit,grep,find,ls}.ts`; path handling in `src/core/tools/path-utils.ts` and `src/utils/paths.ts`; the Windows shell in `src/utils/shell.ts`; context files in `src/core/resource-loader.ts`; skills and packages in `src/core/package-manager.ts`; trust in `src/core/project-trust.ts` and `src/core/trust-manager.ts`
