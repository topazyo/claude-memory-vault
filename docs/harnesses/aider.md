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
# aider-scheduled.conf.yml (pass it with --config, which loads only this file)
read:
  - AGENTS.md
  - .claude/rules/security.md
  - .claude/rules/untrusted-captures.md
  - .claude/rules/vault-notes.md
  - .claude/rules/verification.md
git-commit-verify: true
suggest-shell-commands: false
detect-urls: false
```

```bash
#!/usr/bin/env bash
# aider-vault-agent.sh <prompt-file>
set -u
exec aider --config aider-scheduled.conf.yml --message-file "$1" --yes-always
```

Run it in a container that blocks the network before setting `VAULT_ALLOW_UNENFORCED_TOOLS=1`.

## Sources (checked 2026-09-13)

- YAML config (locations, `read`, `git-commit-verify`, `auto-commits`, `gitignore`, `lint-cmd`, `suggest-shell-commands`, `detect-urls`, `message-file`, `yes-always`, `--config`): <https://aider.chat/docs/config/aider_conf.html>
- Conventions files (`read:`): <https://aider.chat/docs/usage/conventions.html>
