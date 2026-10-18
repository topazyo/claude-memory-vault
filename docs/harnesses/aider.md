# Aider

Aider has no hook system, so the lint cannot run after its writes. What the template ships for
Aider loads the instructions and rules into every session, and makes sure Aider's automatic
commits pass through the commit gate.

## What ships

| File | What it does |
| --- | --- |
| `.aider.conf.yml` | `read:` loads `AGENTS.md` and the four rules files as read-only context; `git-commit-verify: true`; `gitignore: false` |

Aider commits with `--no-verify` by default (`git-commit-verify: false`), which skips git hooks.
Without the shipped setting, the commit gate would never see a note Aider wrote. `.gitignore`
carries an exception so this file stays tracked despite the `.aider*` pattern.

## Enforced, and guidance

- **Enforced:** once the commit gate is enabled, every Aider auto-commit runs `vault-check.sh`,
  and a violating note stops the commit.
- **No lint after a write:** Aider's `lint-cmd` acts only on a linter that exits non-zero, and
  `vault-lint.sh` always exits 0.
- **Guidance:** reads of `.env` and `secrets/`, and everything else in the rules.

## Setup

1. Start `aider` from the vault root, so it finds `.aider.conf.yml` at the root of the git
   repository.
2. Enable the commit gate: `git config core.hooksPath .claude/githooks`. For Aider this is the one
   mechanical check, not an option.

## Onboarding prompt

```text
Onboard this vault for Aider. Work from the vault root.

1. Follow docs/harnesses/README.md, section "Common onboarding checklist", steps O1, O2, O3, O5
   and O6. Skip O4: Aider has no lint hook.
2. Then run the checks in docs/harnesses/aider.md, section "Harness-specific checks".
3. Report every step as PASS, FAILED or NOT VERIFIED, with the evidence for each PASS.

Do not repair anything you find broken, and do not change settings outside this repository
without asking me.
```

## Harness-specific checks

- **H1. Config loaded.** Confirm `AGENTS.md` and the four `.claude/rules/` files are in the chat as
  read-only files. O1 and O2 are the evidence.
- **H2. The gate stops a bad auto-commit.** Only after O5 PASSED: create
  `01-inbox/harness-probe.md` containing the single line `probe` and no frontmatter, and let Aider
  auto-commit it. PASS if the commit is refused with `pre-commit: vault-check exited 1`. If the
  commit goes through, `git-commit-verify` is not in effect: FAILED. Either way, remove the probe
  afterwards (with `git rm` if it was committed) and report what you removed.

## Scheduled passes

Not recommended. Aider edits files you add to its chat and suggests shell commands, and
`--yes-always` would approve those suggestions unattended. If you run it anyway, use a separate
config so interactive sessions keep their defaults:

```yaml
# aider-scheduled.conf.yml: keep it outside the vault, read-only, and pass its absolute path with
# --config, which loads only this file
read:
  - /absolute/path/to/the/vault/AGENTS.md
  - /absolute/path/to/the/vault/.claude/rules/security.md
  - /absolute/path/to/the/vault/.claude/rules/untrusted-captures.md
  - /absolute/path/to/the/vault/.claude/rules/vault-notes.md
  - /absolute/path/to/the/vault/.claude/rules/verification.md
git: false
auto-lint: false
git-commit-verify: false
auto-commits: false
suggest-shell-commands: false
detect-urls: false
```

Unlike the interactive config, this one stops Aider using git. Aider's YAML config page lists
`git` among "*all* the valid configuration entries" ("Enable/disable looking for a git repo
(default: True)"), and its git page says `--no-git` "will completely stop aider from using git on
your files", so a pass's Aider should neither commit nor run git in the vault (Aider's
documentation; not measured for this release, and the check below is what shows it). The runner
commits the pass's notes itself. With git on, Aider's git calls would run what the vault's git
configuration and hooks name, and a pass can write both (reasoned): the commit gate's
`.claude/githooks/pre-commit`, for one, runs `vault-check.sh`, which loads the vault's library, all
files a pass can change (`docs/harnesses/README.md`, "No vault hook in a scheduled pass"; the rest
is the class `docs/setup.md` names in its `UNVERIFIED` troubleshooting row).
`git-commit-verify: false` and `auto-commits: false` matter only with git on; they stay, but do
not rely on them alone, because Aider's other git behaviour, `dirty-commits` among it ("commits
when repo is found dirty (default: True)"), would still run git in the vault. `auto-lint: false`
turns off the lint Aider runs by itself after a change ("Enable/disable automatic linting after
changes (default: True)"). A config inside the vault would be a file the pass could change too,
which is why it lives outside, and its `read:` paths are absolute paths to the vault's files,
because how Aider resolves a relative one there is not in the sources (reasoned). Aider also loads
options from a `.env` file in the git root and in the current directory (its dotenv page), and a
pass could write one: in the container, mount an empty file read-only over the vault's `.env`. The
mount is what keeps this config's switches in force for later runs, because the runner's steering
filter does not name a root `.env`, and whether a `.env` or `--config` wins is not in the sources
(reasoned). If the vault has none, create the empty file yourself before the first scheduled run:
`.claude/rules/security.md` forbids an agent to create a `.env`, so that step is the owner's.

```bash
#!/usr/bin/env bash
# aider-vault-agent.sh <prompt-file>
set -u
exec aider --config /absolute/path/outside/the/vault/aider-scheduled.conf.yml \
  --message-file "$1" --yes-always
```

Aider has no lint hook, so apply the README's check to the git Aider would run, on a scratch copy of
the vault that is a clone with its own git folder, with the gate enabled there and git able to
commit. Run it in the container the schedule uses, but without its read-only `.git` mount, so that
the check tests `git: false` alone:

1. Replace `.claude/githooks/pre-commit` with the README's canary. Add a second canary in the
   copy's own git configuration, of the class `docs/setup.md` names in its `UNVERIFIED`
   troubleshooting row: point the copy's `core.fsmonitor`, the setting that row names, at a copy of
   the canary script in the copy's `.claude/hooks/`, by its absolute path as the container sees it.
   Run `git status` in the copy by hand, inside the container: `hook-canary` must appear, naming
   the second canary. Delete it.
2. Positive control for the switch: change a tracked note in the copy without committing it, and
   run the wrapper on `probe.dream-pass.md` with the scheduled config but `git: true`. Look for
   `hook-canary` before you run any git command in the copy, because your own `git status` there
   fires the second canary. `hook-canary` must name the second canary, or `git log` must show a new
   commit. If neither, the check is NOT VERIFIED, never PASS, and `VAULT_ALLOW_UNENFORCED_TOOLS=1`
   waits until it fires (the README's step 3).
3. Control for the commit gate: delete `hook-canary` and the probe, and run the wrapper again with
   `git: true`, `git-commit-verify: true` and `auto-commits: true`: `hook-canary` must name
   `pre-commit`.
4. Delete `hook-canary` and the probe, change a tracked note again (so that, were git on, Aider
   would find the repository dirty), and run the wrapper with the scheduled config on each probe
   prompt in turn, deleting the probe between them.
5. Look for `hook-canary` first, as in step 2. PASS only if the controls in steps 1 to 3 fired, each
   run in step 4 wrote the probe, `hook-canary` does not exist, and `git log` shows no commit after
   step 3's. A control that did not fire leaves the check NOT VERIFIED, never PASS (the README's
   step 3).

Remove the second canary from the copy's git configuration afterwards. If the scheduled runs do not
show the rules in the chat, check the absolute `read:` paths.

Run the schedule in a container that blocks the network and mounts only the vault writable, with
the vault's `.claude/` and `.git` read-only as well, as the README's container rule says, which
costs a pass nothing with `git: false` (reasoned), before setting `VAULT_ALLOW_UNENFORCED_TOOLS=1`.

## Sources (checked 2026-09-13; the YAML config, options, git and `.env` pages read 2026-10-18)

- YAML config (locations, `read`, `git-commit-verify`, `auto-commits`, `gitignore`, `lint-cmd`, `suggest-shell-commands`, `detect-urls`, `message-file`, `yes-always`, `--config`; the `git` and `auto-lint` entries, read 2026-10-18): <https://aider.chat/docs/config/aider_conf.html>
- Options (`git`, `auto-lint`, `dirty-commits`, `auto-commits`, `git-commit-verify`), read 2026-10-18: <https://aider.chat/docs/config/options.html>
- Git integration (`--no-git`), read 2026-10-18: <https://aider.chat/docs/git.html>
- `.env` (where Aider looks for it), read 2026-10-18: <https://aider.chat/docs/config/dotenv.html>
- Conventions files (`read:`): <https://aider.chat/docs/usage/conventions.html>
