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
  - AGENTS.md
  - .claude/rules/security.md
  - .claude/rules/untrusted-captures.md
  - .claude/rules/vault-notes.md
  - .claude/rules/verification.md
git-commit-verify: false
auto-commits: false
suggest-shell-commands: false
detect-urls: false
```

Unlike the interactive config, this one turns the commit gate's hook off and stops Aider
committing: the runner commits a pass's notes itself, and the gate's `.claude/githooks/pre-commit`
runs `vault-check.sh`, which loads the vault's library, all files a pass can change. With the gate
on, a pass that changed one of them would get a shell at its next commit
(`docs/harnesses/README.md`, "No vault hook in a scheduled pass"). A config inside the vault would
be a file the pass could change too, which is why it lives outside. Aider also reads settings from
a `.env` file in the repository by default, which a pass could write as well (reasoned; `.env` is
not in the sources below): in the container, mount an empty file read-only over the vault's `.env`,
creating an empty one first if there is none, or point Aider at an empty file outside the vault as
`aider --help` documents for your version.

```bash
#!/usr/bin/env bash
# aider-vault-agent.sh <prompt-file>
set -u
exec aider --config /absolute/path/outside/the/vault/aider-scheduled.conf.yml \
  --message-file "$1" --yes-always
```

Aider has no lint hook, so apply the README's check to the commit gate alone, on a scratch copy of
the vault with the gate enabled and git able to commit there: replace `.claude/githooks/pre-commit`
with the canary. As the positive control, run the wrapper on `probe.dream-pass.md` with a config
that has `git-commit-verify: true` and `auto-commits: true`: `hook-canary` must appear. Then, with
the scheduled config, change a tracked note in the copy without committing it (Aider may commit
files that were already changed when it started, with `auto-commits` off; the sources below do not
say), and run the wrapper on both probe prompts: PASS if each run wrote the probe,
`hook-canary` does not exist, and `git log` shows no new commit. The config now lives outside the
vault, and how Aider resolves a relative `read:` path there is not in the sources either, so write
those paths as absolute paths to the vault's files, or confirm in a scheduled run that the rules
were read.

Run it in a container that blocks the network and mounts only the vault writable before setting
`VAULT_ALLOW_UNENFORCED_TOOLS=1`.

## Sources (checked 2026-09-13)

- YAML config (locations, `read`, `git-commit-verify`, `auto-commits`, `gitignore`, `lint-cmd`, `suggest-shell-commands`, `detect-urls`, `message-file`, `yes-always`, `--config`): <https://aider.chat/docs/config/aider_conf.html>
- Conventions files (`read:`): <https://aider.chat/docs/usage/conventions.html>
