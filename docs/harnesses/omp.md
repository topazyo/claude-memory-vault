# Oh My Pi (omp)

Oh My Pi (CLI `omp`, npm package `@oh-my-pi/pi-coding-agent`) is a terminal coding agent forked
from Pi. It reads `AGENTS.md` on its own, and the vault's skills from both `.claude/skills/` and
`.agents/skills/`. It asks for no approval before a tool call and has **no project trust gate at
all**, so the template ships an extension, **off until you load it**, that refuses the secret
paths, lints written notes and records compactions.

Everything here was checked against omp 18.18.9, in its source at commit `50da2d3` of
<https://github.com/can1357/oh-my-pi>, read on 2026-11-12. omp changes quickly. The onboarding
checks exist so you prove the wiring on your own machine.

## What ships

| File | What it does |
| --- | --- |
| `.claude/adapters/omp/vault.js` | The extension, kept outside `.omp/extensions/` so omp does not load it by itself. Once loaded it refuses a file-tool call whose path names `.env` or `.env.*`, or passes through or ends at a part named `secrets` at any depth; runs `vault-lint.sh` after each successful `write`, `edit` and applied `ast_edit` and adds what it reports to the tool's result; runs `postcompact-wrap-up.sh` on each compaction, as `manual` or `auto` |
| `.claude/skills/*/SKILL.md`, `.agents/skills/*/SKILL.md` | The five skills. omp reads both folders and keeps one copy of a skill whose two copies are byte-identical, the `.claude/skills/` one. The suite keeps the two folders identical, so each skill is listed once |

At the vault root omp loads `AGENTS.md` and not `CLAUDE.md`. It keeps one instruction file per
folder, and `AGENTS.md` comes first there. `CLAUDE.md` is Claude Code's bridge to `AGENTS.md`, so
the instructions load once. omp also walks up from the vault past its git root to just below your
home folder and loads an `AGENTS.md` or `CLAUDE.md` it finds on the way. One in a folder above the
vault steers every omp session in it, so keep none there, or read it first.

**Why the extension is opt-in.** omp runs every extension in `.omp/extensions/` and every hook in
`.omp/hooks/pre/` and `.omp/hooks/post/` of the folder it starts in, and it reads the vault's
`.claude/` as a source of its own: `.claude/hooks/pre/` and `post/`, `.claude/tools/`,
`.claude/SYSTEM.md`, commands and skills. It asks nothing first. Its extension API answers that every
project is trusted (`isProjectTrusted()` "always returns true", `src/extensibility/extensions/types.ts`).
A file the template shipped in any of those places would run on every clone of every vault. So the
template ships nothing there (CI fails a tracked file under `.omp/`), and this extension ships
where omp does not look, for you to load once you have read it. `CONTRIBUTING.md`, *Adding a
harness*, makes that the rule for every harness without a trust gate.

**Before you start omp in a vault you did not make**, look in `.omp/`, `.claude/hooks/pre/`,
`.claude/hooks/post/`, `.claude/tools/` and `.claude/extensions/`, and in any `AGENTS.md` above it.
In a vault made from this template none of those folders exist.

## Enforced, and guidance

omp's `bash` tool is on by default, and so is its `eval` tool wherever a JavaScript or Python
backend is available, which runs code that can open any file. Both run without asking, so nothing
below is a boundary against a model set on reading a secret. The extension keeps the file tools
from reading one by accident, as Claude Code's own read deny does.

- **Enforced without the extension:** nothing. omp runs every tool without asking.
- **Enforced once the extension is loaded:**
  - A call is refused when a path it names, read the way omp reads it, names `.env` or `.env.*`,
    or passes through or ends at a part named `secrets` at any depth, in any letter case. The
    tools and fields it reads are `read` and `write` (`path`), `edit` (`path`, and the file names
    in its patch text: apply_patch's `*** Add`, `Update`, `Delete File:` and `*** Move to:` lines,
    the hashline `[PATH#TAG]` headers and `MV` targets, the legacy `¶` headers, and patch-mode
    renames), `grep` and its other name `search`, `glob`, `find`, `ast_grep` and `ast_edit`
    (`path` or `paths`), `lsp` (`file`), `debug` (`program`, `file`, `cwd`) and `security_scan`
    (`include_paths`, `knowledge_base_paths`, `output_root`). Each part of a `;` list is tested,
    and so is a line selector's path (`secrets/api.key:1-5`).
  - Paths are read as omp reads them: a leading `:` or `@`, a hashline header around the path,
    `~`, `file://` URLs, the `\\?\` prefix, Windows drive and Git Bash forms, trailing dots and
    spaces, NTFS stream names and symbolic links, with the same code as the Pi extension, which
    the suite holds identical. Where omp could read a string more than one way, each way is
    tested. An omp URL such as `local://` is tested by its text.
  - **omp opens a file it was not asked for** when a `read` names a path that does not exist: it
    searches the folder it was started in for any file whose path ends that way, and opens the one
    match. So `read api.key` could open `secrets/api.key`. For a missing path the extension makes
    the same search, and refuses the read when a secret is among the matches, or when the folder
    holds more than 20000 entries.
  - A `grep`, `search`, `ast_grep` or `ast_edit` whose path is a glob is tested as the Pi
    extension tests a grep glob, so `*` and `**/.e*` are refused and `**/*.md` is let through. A
    `glob`, which lists names and reads no file, is refused only when its text names `.env` or
    `secret` or it starts inside `secrets/`, so `**/*` is let through. A `grep` with
    `gitignore: false` is refused, because the `.gitignore` the template ships is what keeps
    `.env` and `secrets/` out of an omp grep, which always searches hidden files.
  - A required path that is missing, or a path that is not text, is refused rather than let
    through unchecked, and so is a call the guard could not decide.
  - After each successful `write`, `edit` and applied `ast_edit` the lint runs on every file the
    result names, including where an edit moved one, and what it reports is added to the end of the
    tool's result, cut at 4000 characters. Every written path goes to the lint, which decides its
    own scope, so a steering file's hidden characters are reported too. Compactions are recorded,
    as `auto` when omp compacted on its own and `manual` after `/compact`. Both scripts run with
    `CLAUDE_PROJECT_DIR` naming the vault; each is sent SIGTERM at 15 s, then SIGKILL.
- **Not covered:**
  - `bash` and `eval` can read a secret, and a file written from either is not linted. Turn
    `eval` off in omp's settings if you do not use it.
  - A file you mention with `@` in your own prompt is read into the session with no tool call.
  - A `grep` with no path searches what `.gitignore` does not exclude. The template's `.gitignore`
    lists `.env`, `.env.*` and `secrets/`, so keep those lines.
  - omp's subagents keep the extension when omp restricts them, but an isolated subagent may run
    without it.
  - The other paths in `.claude/rules/security.md`, such as `**/credentials*` and `~/.ssh/`, are
    guidance only, as in every harness.

## Setup

1. Install omp (<https://github.com/can1357/oh-my-pi>, "Install"). It needs Bun 1.4.4 or later
   when installed as a package.
2. Look in the places listed under *Before you start omp* above, since omp loads them without
   asking.
3. Read `.claude/adapters/omp/vault.js`, which runs two bash scripts from `.claude/hooks/`. Then
   load it in **one** of two ways. Using both loads it twice.
   - For one session: `omp -e .claude/adapters/omp/vault.js`.
   - For every session in this clone, from the vault root:

     ```bash
     mkdir -p .omp/extensions
     cp .claude/adapters/omp/vault.js .omp/extensions/vault.js
     ```

     omp loads it at every start, since it has no trust gate. Commit the copy only if you want
     every clone of your vault to run it, which omp will do without asking anyone who clones it;
     leave it uncommitted to keep it on this machine. The control suite fails when the copy differs
     from the adapter.
4. The scripts need bash. On Windows the extension runs Git Bash from Program Files, then a
   `bash.exe` on `PATH`, passing over WSL's `bash.exe` in `System32`.

The extension finds the vault from where its own file is, so starting `omp` in a subfolder still
lints against this vault, and starting it in some other tree never runs that tree's scripts.

## Onboarding prompt

```text
Onboard this vault for Oh My Pi. Work from the vault root.

1. Follow docs/harnesses/README.md, section "Common onboarding checklist", steps O1 to O6.
   Before O4, ask me whether I loaded the vault extension (docs/harnesses/omp.md, setup step 3).
   If I did not, do not load or copy it yourself: point me to that setup step, and mark O4, H2
   and H4 NOT VERIFIED. If I did, run every step. Write the O4 probe with the write tool. O4 is
   PASS only if the log has the entry and your write tool's result also ended with
   "vault-lint (advisory):" text, which you quote.
2. Then run the checks in docs/harnesses/omp.md, section "Harness-specific checks".
3. Report every step as PASS, FAILED or NOT VERIFIED, with the evidence for each PASS.

Do not repair anything you find broken, and do not change settings outside this repository
without asking me.
```

## Harness-specific checks

- **H1. Skills loaded once.** List your skills. PASS if each of the five vault skills appears
  exactly once. Two copies of one means its `.claude/skills/` and `.agents/skills/` copies differ.
- **H2. Secrets guard.** Use the read tool on `secrets/harness-probe.txt`. The file does not need
  to exist. PASS if the call is refused with
  `vault: .env, .env.* and secrets/ are off limits (.claude/rules/security.md)`. A "not found"
  error means the extension did not run: FAILED.
- **H3. Instructions loaded once.** Say which instruction files you were given. PASS if the vault's
  `AGENTS.md` is among them and its text is not there twice. Name any `AGENTS.md` or `CLAUDE.md`
  from a folder above the vault: each is FAILED for this check until the human has read it.
- **H4. Compaction stub.** NOT VERIFIED unless the session compacts. Ask the human to run
  `/compact`. Afterwards a `20-projects/_logs/compaction-<session>.md` file gains an entry with
  trigger `manual`.

## Scheduled passes

```bash
#!/usr/bin/env bash
# omp-vault-agent.sh <prompt-file>: keep it outside the vault and every folder a pass can write,
# because its flags below are the switches this recipe rests on
set -u
case "${1:-}" in
  *dream-pass*)     tools=read,grep,glob,write ;;
  *promotion-pass*) tools=read,grep,glob,write,edit ;;
  *) echo "omp-vault-agent: expected a dream-pass or promotion-pass prompt file, got '${1:-}'" >&2; exit 64 ;;
esac
prompt=$(cat -- "$1") || exit 66
exec omp --print --no-session --no-extensions --no-skills --no-rules --no-lsp --tools "$tools" "$prompt"
```

- `--tools` is omp's allowlist. Leaving `bash` and `eval` out of it takes the shell and the code
  runner away, and it is also what keeps the custom tools omp finds in `.omp/tools/` and
  `.claude/tools/` from loading: omp scans for them only when no allowlist is given.
- `--no-extensions` keeps every discovered extension and hook from loading, `.omp/hooks/`,
  `.omp/extensions/` and `.claude/hooks/pre/` and `post/` included. `--no-skills` and `--no-rules`
  keep skills and rules out; the prompt file already carries the agent's instructions.
  `--no-session` keeps the session in memory.
- **No extension loads, this vault's included, so nothing refuses a read of `.env` or `secrets/`
  during a pass.** Keep them out of the container as the Pi guide says: an empty file mounted
  read-only over every `.env` and `.env.*`, and an empty folder over every `secrets/`.
- omp has no switch for MCP servers or for its own network requests. Run it in a container whose
  only network route is your model provider, with none of your home configuration, so no MCP
  server and no personal extension or setting comes with it.
- **Keep omp's project settings out of the vault.** omp writes `.omp/config.yml` when you set a
  project model role, and renames a project `.omp/` settings file it cannot parse when it starts.
  Either, during a pass, is contained by the runner and sets the tripwire. A copy of the extension
  in `.omp/extensions/` is fine, since `--no-extensions` keeps it from loading. omp keeps its
  sessions, logs and memory under `~/.omp/` in the container's home instead.
- omp still loads `AGENTS.md` files from the folders above the vault, and `--no-context-files`
  would drop the vault's own as well, so leave the folders above the vault's mount empty.

Run the wrapper in a container that mounts only the vault, without its secrets, with its `.claude/`
(its settings files mounted over it from copies without their hooks) and `.git` read-only
(`docs/harnesses/README.md`), and start a new container for each run. Run it once against a scratch
copy of the vault and diff the tree, and run the check in `docs/harnesses/README.md`, "No vault hook
in a scheduled pass", with `-e .claude/adapters/omp/vault.js` in place of `--no-extensions` as its
positive control. Only then set `VAULT_ALLOW_UNENFORCED_TOOLS=1`.

## Auto memory

omp's memory is off by default (`memory.backend: off`). Its `local` backend keeps memories under
omp's agent folder, `~/.omp/agent/memories/<project>/`, which moves only with the whole agent folder
(`PI_CODING_AGENT_DIR`). The `mnemopi` backend's database moves on its own (`mnemopi.dbPath`), and
`hindsight` is a remote service. None of them writes the Markdown notes `90-auto-memory/` expects,
so leave that folder out for omp, as `/onboard-project` step 3 says for any harness whose memory
cannot be moved into the vault. (`docs/memory.md` in omp's repository at `50da2d3`.)

## Known limits

- The extension is written against omp 18.18.9. If a later omp renames a path field, the guard
  refuses every `read`, `write` and `edit` as having no path, which names this guide; a renamed
  field of another tool is not checked at all, and nothing says so.
- `bash`, `eval` and a prompt's `@` mentions bypass the extension.
- A write to one of omp's own execution surfaces, such as `.omp/extensions/` or `.claude/tools/`,
  is neither refused nor linted, and takes effect the next time omp starts. The scheduled passes
  contain such a write, and an interactive session does not.
- Another extension loaded after this one can still change a call's input after the guard checked
  it. A refusal from this one cannot be overridden, because omp stops at the first.
- The guard refuses a call it cannot decide, saying `the secrets guard failed on this call` with
  the reason, as the Pi extension does, and also a missing `read` path in a folder of more than
  20000 entries.
- Loaded from outside a vault, the extension still guards the secret paths, measured from the vault
  omp was started in, but it lints nothing, and says so at the first write or compaction.

## Sources (checked 2026-11-12, omp 18.18.9, commit `50da2d3`)

- Install, CLI flags (`-e`, `--no-extensions`, `--no-skills`, `--no-rules`, `--no-context-files`, `--tools`, `--no-session`, `--print`, `--profile`): `omp --help` of 18.18.9, and `docs/cli-reference.md` in the repository
- Extensions and hooks, loading from `.omp/` and `-e`: `docs/extension-loading.md`, `docs/hooks.md`; `src/extensibility/extensions/loader.ts`
- No trust gate: `src/extensibility/extensions/types.ts` (`isProjectTrusted`)
- What omp reads from `.claude/` and `.agents/`, skills deduplication, `AGENTS.md` ahead of `CLAUDE.md`, the walk up from the vault: `src/discovery/claude.ts`, `agents.ts`, `claude-md.ts`, `helpers.ts`; `src/extensibility/skills.ts`; `src/capability/context-file.ts`
- Event, result and context shapes: `src/extensibility/shared-events.ts`, `src/extensibility/extensions/types.ts` and `runner.ts`; derived edit paths in `src/extensibility/tool-event-input.ts`
- Tool inputs: `src/tools/{read,write,grep,glob,ast-grep,ast-edit,debug}.ts`, `src/edit/schemas.ts`, `src/jfind/index.ts`, `src/lsp/types.ts`; default tools in `src/tools/index.ts`
- Path handling and the missing-path search: `src/tools/path-utils.ts` (`expandPath`, `resolveReadPath`), `src/tools/read.ts`
- Compaction events: `src/session/session-maintenance.ts`
- Writes into the project's `.omp/`: `src/config/settings.ts`
- Memory: `docs/memory.md`
