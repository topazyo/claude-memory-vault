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
| `.claude/adapters/pi/vault.js` | The extension, kept outside `.pi/extensions/` so Pi does not load it by itself. Once loaded it refuses a `read`, `write`, `edit`, `grep`, `find` or `ls` call whose path names `.env` or `.env.*`, or passes through or ends at a part named `secrets` at any depth, and a `grep` whose glob names one of them; runs `vault-lint.sh` after each successful `write` and `edit` and adds what it reports to the tool's result; runs `postcompact-wrap-up.sh` on `session_compact` |
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

Pi's `bash` tool is on by default and runs without asking, so nothing below is a boundary against
a model set on reading a secret. The extension keeps the file tools from reading one by accident,
as Claude Code's own read deny does.

- **Enforced without the extension:** nothing. Pi loads `AGENTS.md` and, once the project is
  trusted, the skills, but it runs every tool without asking, and nothing stops a read of `.env`.
- **Enforced once the extension is loaded:**
  - A file-tool call is refused when its path names `.env` or `.env.*`, or passes through or ends
    at a part named `secrets` at any depth, in any letter case. Inside the vault only the part
    below the vault is tested, and outside it the whole path. The extension reads the path the way
    Pi's own tools will open it: a leading `@`, `~`, `file://` URLs, Windows drive and Git Bash
    forms, trailing dots and spaces, and NTFS stream names. It follows symbolic links too,
    including one whose target does not exist yet, so `@.env`, `.ENV.` and a note that links to
    `.env` are refused. A `grep`, `find` or `ls` with no path is tested against the folder Pi was started
    in, which it searches. A `read`, `write` or `edit` with no path is refused rather than let
    through unchecked.
  - A `grep` glob is refused when its text holds `.env` or `secret` in any letter case, such as
    `.env.production` or `secrets/*.txt`; when its last part matches `.env`, `.env.local` or
    `secrets`, such as `*`, `.[e]nv`, `.e{n}v` or `20-projects/.[e]nv`; when its last part spells
    a name starting `.env.` with `?`, `[...]` or `{...}` standing in for letters of `.env`, such as
    `.[e]nv.production`; and when a folder part other than `*` or `**` matches `secrets`, such as
    `31-standards/s?crets/*.md`. Letters and sets are compared without regard to case. The parts
    are split at each `/` outside a `[...]` set and at an escaped `\/`, and because ripgrep lets
    a set match a `/`, a set that could (one holding `/`, a negated set that does not exclude `/`,
    or a range across `/`) is tried both as a letter and as a `/`: `s[e/]crets/x.md` and
    `s?crets[!a]x.md` are refused. ripgrep reads a backslash as an escape on every platform, so
    `.\env` is `.env`; on Windows the glob is tested with its backslashes read as `/` too. A set is
    read as ripgrep reads it, so `[a-b-z]` runs from `a` to `z`, and like ripgrep the guard drops
    a glob's trailing white space unless a backslash escapes its last space. ripgrep lets a glob
    that matches a file override `.gitignore`, which is why the glob is checked at all.
    A glob that reaches a `.env.*` name other than `.env.local` only through a `*` standing in for
    some or all of `.env`, such as `*.production` or `.e*.production` for `.env.production`, is let
    through, and so is `*.md`, although it would also match a file called `.env.md`; `*` and
    `*.local` are refused, because they match `.env` and `.env.local` themselves.
  - After each successful `write` and `edit` the lint runs, and what it reports on stderr, a
    missing `tier:` or a hidden character or a scan that could not run, is added to the end of the
    tool's result, cut at 4000 characters with a line saying so. Pi's `tool_result` handlers may
    return new content for the result, and O4 checks that the model saw it. Compactions are
    recorded. Both scripts run with `CLAUDE_PROJECT_DIR` naming the vault, whatever the shell Pi
    started from had set; each is sent SIGTERM at 15 s, then SIGKILL, and answered by 16 s.
- **Not covered:**
  - The `bash` tool, and `powershell` where you enable it, can still read a secret, and a file
    written from either is not linted.
  - A `grep` with no glob searches what ripgrep does not skip. Pi's grep searches hidden files, so
    what keeps `.env` and `secrets/` out of it is ripgrep skipping what `.gitignore` lists, which it
    does only in a git repository. The template's `.gitignore` lists `.env`, `.env.*` and
    `secrets/`, but in a vault that is not a git repository such a grep reads them as well.
  - A glob that is let through overrides `.gitignore` for every file it matches, in a git
    repository too, so `*.production` reads `.env.production` and `*.md` reads a file called
    `.env.md` in every folder ripgrep searches.
  - Pi runs its `find` so that it honours `.gitignore` in a vault that is not a git repository
    too, so a `find` lists secret names only where `.gitignore` does not list them, and never their
    contents. An `ls` of a folder lists the names in it.
  - The other paths in `.claude/rules/security.md`, such as `**/credentials*` and `~/.ssh/`, are
    guidance only, as in every harness.
  - The rule is the control for all of these. The commit gate runs `vault-check.sh`, so it catches
    a note written from the shell without `tier:` or `type:`, but not a hidden character or a
    steering file: run `bash .claude/hooks/vault-lint.sh <file>` on those.

## Setup

1. Install Pi from <https://pi.dev>.
2. **Before you trust the vault, look in `.pi/`.** In a vault made from this template it does not
   exist. Trusting a folder lets Pi run `.pi/extensions/`, install the packages `.pi/settings.json`
   declares and replace its system prompt from `.pi/SYSTEM.md`, and the decision covers every
   folder below it.
3. Start `pi` from the vault root and trust the project when it asks, or run `/trust`. Without
   trust Pi does not load `.agents/skills/`.
4. Read `.claude/adapters/pi/vault.js`, which runs two bash scripts from `.claude/hooks/`. Then
   load it in **one** of two ways. Using both loads it twice, so every write is linted twice and
   every compaction recorded twice.
   - For one session: `pi -e .claude/adapters/pi/vault.js`. Pi loads an extension named with
     `-e` whether or not the project is trusted.
   - For every session in this clone, from the vault root:

     ```bash
     mkdir -p .pi/extensions
     cp .claude/adapters/pi/vault.js .pi/extensions/vault.js
     ```

     Pi then loads it whenever the project is trusted, and not when it is not.
     Commit the copy if you want every clone of your vault to run it, and leave it uncommitted to
     keep it on this machine. The control suite fails when the copy differs from the adapter.
5. The lint and the compaction stub are bash scripts. On Windows the extension runs them with the
   bash Pi's own bash tool would pick: `shellPath` in Pi's global `settings.json` (in
   `$PI_CODING_AGENT_DIR` when that is set, otherwise `~/.pi/agent/`), then Git under Program
   Files, then `bash.exe` in a folder on `PATH`. It passes over WSL's `bash.exe` in `System32`,
   because the scripts are written for Git Bash.

The extension finds the vault from where its own file is, so starting `pi` in a subfolder still
lints against this vault, and starting it in some other tree never runs that tree's scripts. A
file written in that other tree is still passed to this vault's lint, which checks it only when
its path looks like a content folder or a steering file, and records it in this vault's
`.claude/logs/vault-lint.log`. When Pi does not tell the extension where its file is, it runs no
script at all, and says so at the first write or compaction.

## Onboarding prompt

```text
Onboard this vault for Pi. Work from the vault root.

1. Follow docs/harnesses/README.md, section "Common onboarding checklist", steps O1 to O6.
   Before O4, ask me whether I loaded the vault extension (docs/harnesses/pi.md, setup step 4).
   If I did not, do not load or copy it yourself: point me to that setup step, and mark O4, H2
   and H4 NOT VERIFIED. If I did, run every step. Write the O4 probe with the write tool. O4 is
   PASS only if the log has the entry and your write tool's result also ended with
   "vault-lint (advisory):" text, which you quote; the log entry without that text is FAILED
   (see H3).
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
- **H3. Hook failure causes.** If O4 or H2 FAILED, name the one cause you can confirm:
  - The write or read was refused with `the secrets guard found no path in this call` or `the
    secrets guard failed on this call`. Pi's tool input has changed shape, or the guard could not
    decide the call (both in Known limits). You can see this one yourself.
  - The lint log has the O4 entry but your write tool's result carried no `vault-lint
    (advisory):` text. Pi did not apply the extension's change to the result.
  - The rest show on the human's screen, not to you, so ask the human what Pi showed. The
    extension did not load: check Pi's startup output for an error naming `vault.js`. The copy is
    in `.pi/extensions/` but the project is not trusted, so Pi did not load it (H1 fails too).
    Bash could not run the scripts: the extension shows one warning naming the script and what
    went wrong. The extension is not inside this vault: it says so at the first write or
    compaction.
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
- **No extension loads, this vault's included, so nothing refuses a read of `.env` or `secrets/`
  during a pass.** Keep them out of the container: leave every `.env` and `.env.*` out of what you
  mount, at any depth, and mount an empty folder over every `secrets/` folder. Adding
  `-e .claude/adapters/pi/vault.js` would load the guard, since Pi loads an extension named with
  `-e` even with `--no-extensions`, but it would also lint every write and could record a
  compaction into `20-projects/_logs/` during the pass.
- Pi still loads its global `~/.pi/agent/AGENTS.md` and any `AGENTS.override.md`, `AGENTS.md` or
  `CLAUDE.md` in the folders above the vault. Those steer the pass, and the fence cannot see them.
  `--no-context-files` would drop them, but it drops the vault's own `AGENTS.md` as well, so the
  container is the better place to leave them out.
- Leave `RUNNER_STALL_SECONDS` unset for this wrapper. `--print` may write nothing until it has
  finished, and with it unset a command-mode pass is never stopped for silence.

Pi cannot confine `write` and `edit` to a folder. So run the wrapper in a container that mounts
only the vault, without its secrets and with none of your home configuration, and whose only
network route is your model provider. Pi's grep and find need ripgrep and fd, and Pi downloads
them into `~/.pi/agent/bin` when it cannot find them, so put both in the image. Run the wrapper
once against a scratch copy of the vault and diff the tree before you schedule it. Only then set
`VAULT_ALLOW_UNENFORCED_TOOLS=1`.

## Known limits

- The extension is written against Pi's extension API as of v0.87.1, with the source read at
  commit `8930b9e`: the `tool_call`, `tool_result` and `session_compact` events and the `path` and
  `glob` fields of the file tools. If a later Pi renames the path field, the guard refuses every
  `read`, `write` and `edit` and names this guide, so the O4 probe is refused too, while a
  `grep`, `find` or `ls` is tested against the folder Pi was started in rather than the one it
  searches. If it renames the `glob` field, a grep's glob is not checked at all, and nothing says
  so.
- The guard refuses a call it cannot decide, saying `the secrets guard failed on this call` with
  the reason: a path Pi could not open either, such as a `file://` URL with an encoded slash; a
  loop of symbolic links, or a chain too long to follow; and a `grep` glob longer than 256
  characters, of more than 32 brace alternatives, with more than four `[...]` sets that could
  match a `/`, or with a `{` that never closes. A `grep` glob that is not text is refused as a
  changed tool input.
- `bash` and `powershell` reads and writes bypass the extension.
- A `grep` glob that reaches a `.env.*` name other than `.env.local` only through a `*` standing
  in for some or all of `.env` is let through, in a git repository too, and so is a `grep` with no
  glob in a vault that is not a git repository, which reads `.env` and `secrets/`.
- A write to one of Pi's own execution surfaces, such as `.pi/extensions/` or `.pi/settings.json`,
  is neither refused nor linted, and takes effect the next time Pi loads it. The scheduled passes
  contain such a write, and an interactive session does not.
- Another extension loaded after this one can still change a call's path after the guard has
  checked it.
- If Pi has installed project packages into `.pi/npm`, the scheduled passes archive that folder
  with the other steering files before every run, which can make each run slower.
- Loaded from outside a vault, for example from `~/.pi/agent/extensions/`, the extension still
  guards the secret paths, measured from the vault Pi was started in, but it lints nothing, and
  says so at the first write or compaction.

## Sources (checked 2026-09-25, Pi v0.87.1)

- Context files, `AGENTS.override.md`, trust: <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/configuration.md> and <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/security.md>
- Skills (`.agents/skills/`, trust): <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/skills.md>
- Extensions (`.pi/extensions/`, `-e`, events, `tool_result` handlers composing): <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/extensions.md>
- Settings (built-in tools and the default set, `shellPath`): <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/settings.md>
- Slash commands (`/trust`, `/compact`): <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/slash-commands.md>
- Compaction: <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/compaction.md>
- CLI (`--print`, `--tools`, `--no-approve`, `--no-extensions`, `--no-skills`, `--no-context-files`, `--offline`, `--no-session`): <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/cli.md>
- Windows shell: <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/windows.md>
- Containers: <https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/containerization.md>
- ripgrep's `--glob` overriding ignore files: the `-g/--glob` entry of `rg --help`, which says the glob "always overrides any other ignore logic"
- ripgrep's glob syntax, read in the source on 2026-09-26: `crates/ignore/src/gitignore.rs` in <https://github.com/BurntSushi/ripgrep> builds every glob with `literal_separator(true)` and `backslash_escape(true)`, and `crates/globset/src/glob.rs` keeps only `?` and `*` off a `/`, not a `[...]` set (its test `matchslash4`)
- What the documentation leaves to the source, read at commit `8930b9e`, one commit after v0.87.1: event, result and context shapes in `packages/coding-agent/src/core/extensions/types.ts` and `runner.ts`; tool inputs in `src/core/tools/{read,write,edit,grep,find,ls}.ts`; path handling in `src/core/tools/path-utils.ts` and `src/utils/paths.ts`; the Windows shell in `src/utils/shell.ts`; context files in `src/core/resource-loader.ts`; skills and packages in `src/core/package-manager.ts`; trust in `src/core/project-trust.ts` and `src/core/trust-manager.ts`
