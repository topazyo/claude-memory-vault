# Pi

Pi, the terminal coding agent from Earendil Works (CLI `pi`), reads `AGENTS.md` on its own and
loads the vault's skills from `.agents/skills/` once you trust the vault. It asks for no approval
before a tool call, so the template ships an extension, **off until you load it**, that refuses
the secret paths, lints written notes and records compactions.

Pi began as Mario Zechner's `pi-mono` and is now developed by Earendil Works. Its npm package is
`@earendil-works/pi-coding-agent`, and `@mariozechner/pi-coding-agent` is the old, deprecated
name. It is unrelated to Inflection AI's Pi assistant.

## What ships

| File | What it does |
| --- | --- |
| `.claude/adapters/pi/vault.js` | The extension, kept outside `.pi/extensions/` so Pi does not load it by itself. Once loaded it refuses a `read`, `write`, `edit`, `grep`, `find` or `ls` call whose path names `.env`, `.env.*` or anything under `secrets/`, and a `grep` whose glob could match one of them; runs `vault-lint.sh` after each successful `write` and `edit` and adds what it reports to the tool's result; runs `postcompact-wrap-up.sh` on `session_compact` |
| `.agents/skills/*/SKILL.md` | The five skills. Pi reads them once the project is trusted. It never reads `.claude/skills/`, so each skill is listed once |

At the vault root Pi reads `AGENTS.md` and not `CLAUDE.md`, because in each folder it loads only
the first of `AGENTS.override.md`, `AGENTS.md` and `CLAUDE.md` that exists. Little is lost:
`CLAUDE.md` is Claude Code's bridge to `AGENTS.md`, and the `ARCH-INDEX.md` it preloads is the
map `AGENTS.md` §2 has every agent read anyway.

**Why the extension is opt-in.** Pi runs everything in `.pi/extensions/` once a project is
trusted, and it treats a trust decision saved for a folder as covering every folder below it. A
vault cloned into a folder you had already trusted would therefore run a shipped extension without
asking, including a clone of someone else's vault. That is the risk the OpenCode plugin is opt-in
for, so this extension ships where Pi does not look, and you load it once you have read it.

## Enforced, and guidance

- **Enforced without the extension:** nothing. Pi loads `AGENTS.md` and, once the project is
  trusted, the skills, but it runs every tool without asking, and nothing stops a read of `.env`.
- **Enforced once the extension is loaded:**
  - A file-tool call whose path names a secret is refused, in any letter case. The extension reads
    the path the way Pi's own tools will open it: a leading `@`, `~`, `file://` URLs, Windows drive
    and Git Bash forms, trailing dots and spaces, and NTFS stream names. It also follows symbolic
    links, including one whose target does not exist yet, so `@.env`, `.ENV.` and a note that
    links to `.env` are refused too. A `read`, `write` or `edit` with no path is refused rather
    than let through unchecked.
  - A `grep` whose glob could match `.env`, `.env.*` or `secrets/` is refused, such as `.env*`,
    `*` or `{.env,x}`, because ripgrep lets a glob that matches a file override `.gitignore`. A
    glob that can match none of them, such as `*.md`, is let through.
  - After each successful `write` and `edit` the lint runs, and what it reports, a missing
    `tier:` or a hidden character or a scan that could not run, is added to the tool's result, so
    the model sees it. Compactions are recorded. Both scripts run with `CLAUDE_PROJECT_DIR` naming
    the vault, whatever the shell Pi started from had set.
- **Not covered:**
  - The `bash` tool, and `powershell` where you enable it, can still read a secret, and a file
    written from either is not linted.
  - A `grep` over a parent folder with no glob, or with a glob that cannot match a secret, searches
    what ripgrep does not skip. Pi's grep searches hidden files, so what keeps `.env` and
    `secrets/` out of it is ripgrep skipping what `.gitignore` lists, which it does only in a git
    repository. The template's `.gitignore` lists `.env`, `.env.*` and `secrets/`, but in a vault
    that is not a git repository such a grep reads `.env` as well. A `find` from a parent folder
    can list the names of secret files the same way, though not their contents.
  - The rule is the control for all of these, and the commit gate catches the unlinted write.

## Setup

1. Install Pi from <https://pi.dev>.
2. **Before you trust the vault, look in `.pi/`.** In a vault made from this template it does not
   exist. Trusting a folder lets Pi run `.pi/extensions/`, install the packages `.pi/settings.json`
   declares and replace its system prompt from `.pi/SYSTEM.md`, and the decision covers every
   folder below it.
3. Start `pi` from the vault root and trust the project when it asks, or run `/trust`. Without
   trust Pi does not load `.agents/skills/`.
4. Read `.claude/adapters/pi/vault.js`, which runs two bash scripts from `.claude/hooks/`. Then
   load it in **one** of two ways. Using both loads it twice, and every compaction is recorded
   twice.
   - For one session: `pi -e .claude/adapters/pi/vault.js`. Pi loads an extension named with
     `-e` whether or not the project is trusted.
   - For every session in this clone, from the vault root:

     ```bash
     mkdir -p .pi/extensions
     cp .claude/adapters/pi/vault.js .pi/extensions/vault.js
     ```

     Pi then loads it whenever the project is trusted, and skips it without a word when it is not.
     Commit the copy if you want every clone of your vault to run it, and leave it uncommitted to
     keep it on this machine. The control suite fails when the copy differs from the adapter.
5. The lint and the compaction stub are bash scripts. On Windows the extension runs them with the
   bash Pi's own bash tool would pick: `shellPath` in `~/.pi/agent/settings.json`, then Git under
   Program Files, then `bash.exe` in a folder on `PATH`. It passes over WSL's `bash.exe` in
   `System32`, because the scripts are written for Git Bash.

The extension finds the vault from where its own file is, so starting `pi` in a subfolder still
lints against this vault, and starting it in some other tree never runs that tree's scripts. When
Pi does not tell the extension where its file is, it runs no script at all and says so once.

## Onboarding prompt

```text
Onboard this vault for Pi. Work from the vault root.

1. Follow docs/harnesses/README.md, section "Common onboarding checklist", steps O1 to O6.
   Before O4, ask me whether I loaded the vault extension (docs/harnesses/pi.md, setup step 4).
   If I did not, do not load or copy it yourself: point me to that setup step, and mark O4, H2
   and H4 NOT VERIFIED. If I did, run every step. Write the O4 probe with the write tool.
2. Then run the checks in docs/harnesses/pi.md, section "Harness-specific checks".
3. Report every step as PASS, FAILED or NOT VERIFIED, with the evidence for each PASS.

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
- **H3. Hook failure causes.** If O4 or H2 FAILED, the extension's own messages go to the human's
  screen rather than to you, so ask the human what Pi showed. The causes: the extension did not
  load (Pi reports a load error naming `vault.js` at startup); the copy is in `.pi/extensions/`
  but the project is not trusted, so Pi skipped it without an error (H1 fails too); bash could not
  run the scripts (the extension shows one warning naming the script and what went wrong); the
  extension is not inside this vault. Name the one you can confirm.
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
prompt=$(cat -- "$1") || exit 66
exec pi --print --no-session --no-approve --no-extensions --no-skills --offline --tools "$tools" "$prompt"
```

- `--print` answers the prompt and exits. `--no-session` keeps the session in memory, and Pi keeps
  its other state under `~/.pi/agent/`, so nothing is written into the vault for the fence to trip
  on.
- `--tools` is Pi's own allowlist, and it covers tools an extension adds as well as the built-in
  ones. Leaving `bash` out of it takes the shell away, and Pi has no built-in web tool.
- `--no-approve` refuses project trust for this run, whatever you saved, so nothing under `.pi/`
  and no project `.agents/skills/` loads, and Pi installs no project package. The prompt file
  already carries the agent's instructions. `--no-extensions` and `--no-skills` keep your personal
  extensions and skills out as well, and `--offline` stops Pi's own automatic network requests.
- Pi still loads its global `~/.pi/agent/AGENTS.md` and any `AGENTS.md` or `CLAUDE.md` in the
  folders above the vault. Those steer the pass, and the fence cannot see them.
- `--print` writes nothing until it has finished, so leave `RUNNER_STALL_SECONDS` unset for this
  wrapper, or a long pass is stopped for silence.

Pi cannot confine `write` and `edit` to a folder. So run the wrapper in a container that mounts
only the vault, with none of your home configuration, and whose only network route is your model
provider. Pi's grep and find need ripgrep and fd, and Pi downloads them into `~/.pi/agent/bin` when
it cannot find them, so put both in the image. Run the wrapper once against a scratch copy of the
vault and diff the tree before you schedule it. Only then set `VAULT_ALLOW_UNENFORCED_TOOLS=1`.

## Known limits

- The extension is written against Pi's extension API as of v0.87.1: the `tool_call`,
  `tool_result` and `session_compact` events and the `path` field of the file tools. If a later Pi
  renames that field, the guard refuses every `read`, `write` and `edit` and names this guide, so
  the O4 probe is refused too, while a `grep`, `find` or `ls` would pass unchecked.
- `bash` and `powershell` reads and writes bypass the extension.
- A `grep` over a parent folder is not refused for the files it passes through, and in a vault
  that is not a git repository it reads `.env`.
- A write to one of Pi's own execution surfaces, such as `.pi/extensions/` or `.pi/settings.json`,
  is neither refused nor linted, and takes effect the next time Pi loads it. The scheduled passes
  contain such a write, and an interactive session does not.
- Another extension loaded after this one can still change a call's path after the guard has
  checked it.
- If Pi has installed project packages into `.pi/npm`, the scheduled passes archive that folder
  with the other steering files before every run, which can make each run slower.
- Loaded from outside a vault, for example from `~/.pi/agent/extensions/`, the extension still
  guards the secret paths, measured from the vault Pi was started in, but it lints nothing, and
  says so once.

## Sources (checked 2026-09-25, Pi v0.87.1)

- Context files, `AGENTS.override.md`, trust: <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/configuration.md> and <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/security.md>
- Skills (`.agents/skills/`, trust): <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/skills.md>
- Extensions (`.pi/extensions/`, `-e`, events): <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/extensions.md>
- Settings (built-in tools and the default set, `shellPath`): <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/settings.md>
- Slash commands (`/trust`, `/compact`): <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/slash-commands.md>
- Compaction: <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/compaction.md>
- CLI (`--print`, `--tools`, `--no-approve`, `--no-extensions`, `--no-skills`, `--offline`, `--no-session`): <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/cli.md>
- Windows shell: <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/windows.md>
- Containers: <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/containerization.md>
- What the documentation leaves to the source, read at `main` one commit after v0.87.1: event and context shapes in `packages/coding-agent/src/core/extensions/types.ts` and `runner.ts`; tool inputs in `src/core/tools/{read,write,edit,grep,find,ls}.ts`; path handling in `src/core/tools/path-utils.ts` and `src/utils/paths.ts`; the Windows shell in `src/utils/shell.ts`; context files in `src/core/resource-loader.ts`; skills and packages in `src/core/package-manager.ts`; trust in `src/core/project-trust.ts` and `src/core/trust-manager.ts`
