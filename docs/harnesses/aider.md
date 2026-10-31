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
documentation; not measured for this release: the check below shows whether Aider commits, and, if
step 2's git-configuration canary fired, whether it runs git). The runner commits the pass's notes
itself. With git on, Aider's git calls would run what the vault's git configuration and hooks name,
and a pass can write both (reasoned): the commit gate's `.claude/githooks/pre-commit`, for one, runs
`vault-check.sh`, which loads the vault's library, all files a pass can change
(`docs/harnesses/README.md`, "No vault hook in a scheduled pass"; the rest is the class
`docs/setup.md` names in its `UNVERIFIED` troubleshooting row).
`git-commit-verify: false` and `auto-commits: false` matter only with git on; they stay, but do
not rely on them alone, because Aider's other git behaviour, `dirty-commits` among it ("commits
when repo is found dirty (default: True)"), would still run git in the vault. `auto-lint: false`
turns off the lint Aider runs by itself after a change ("Enable/disable automatic linting after
changes (default: True)"). A config inside the vault would be a file the pass could change too,
which is why it lives outside, and its `read:` paths are absolute paths to the vault's files,
because how Aider resolves a relative one there is not in the sources (reasoned). Aider also loads
options from a `.env` file in the home directory, the git root and the current directory (its dotenv
page), and a pass could write one: in the container, mount an empty file from outside the vault
read-only over the vault's `.env`, and start a new container for each run, as the README's container
rule says, because in a container kept between runs a `.env` a pass wrote in its home would load at
the next run (reasoned). The mount is what keeps this config's switches in force for later runs (the
README's step 5 fails a `.env` that is a link, or a file with more than one name), because
the runner's steering filter does not name a root `.env`, and whether a `.env` or `--config` wins is
not in the sources (reasoned). If the vault has no `.env`, create an empty one there yourself before
the first scheduled run, so that the mount has a target: `.claude/rules/security.md` forbids an
agent to create a `.env`, so that step is the owner's.

```bash
#!/usr/bin/env bash
# aider-vault-agent.sh <prompt-file>: keep it, like its config, outside the vault and every folder
# a pass can write, because the --config path below is what the switch rests on
set -u
exec aider --config /absolute/path/outside/the/vault/aider-scheduled.conf.yml \
  --message-file "$1" --yes-always
```

Aider has no lint hook, so apply the README's check to the git Aider would run, on a scratch copy of
the vault that is a clone with its own git folder, with the gate enabled there and git able to
commit. Run it in the container the schedule uses, with only the vault's path swapped for the
copy's, but without its read-only `.git` mount, so that the check tests `git: false` alone:

1. First, before any other write into the copy, run the README's step 1 identity control: an empty
   `copy-marker` put in the copy's root and in its `.git/`, `.claude/`, `.claude/hooks/` and
   `.claude/githooks/`, seen in each, and found nowhere that step looks in the vault, by a search
   that honours no ignore file (which rests on the tool: reasoned), reports no folder it could not
   read and is seen to find each known file that step names, as that step says, with its controls (a
   marker found, or a search that does not find those files or that reports a folder it could not
   read, leaves the check NOT VERIFIED, with the remedies that step gives), with only the one in the
   copy's `.git/` kept. Then see, as the README's step 1 says, with its control, that the copy's
   root and its `.git`, `.claude/`, `.claude/hooks/` and `.claude/githooks/` are each a folder, not
   a file or a link; that they each resolve to a folder outside the vault and outside every folder
   the vault's own `.git`, `.claude/`, `.claude/hooks/` and `.claude/githooks/` resolve to or name
   (with any shared folder that one names); and that every script in the copy's `.claude/hooks/` and
   `.claude/githooks/`, and the file this step then writes in the copy's `.git`, is a file with a
   single name (a link count of 1, read with the control the README's step 1 gives it), not a link
   (else the check is NOT VERIFIED: where the test did not show its control link, or the count
   reading its count of 2, use one that does and read again; otherwise remove the marker in the
   copy's `.git/`, give the copy folders of its own outside the vault (a fresh clone, not a link; an
   earlier copy removed as the README's step 1 says), and start this step again). That comparison
   runs before the README's spelling controls, so on Windows it can read one folder spelled two ways
   as two; the marker search does not depend on spelling. Then, before you start the container,
   whose `.claude/` mount is read-only, replace `.claude/githooks/pre-commit` in the copy with the
   README's canary, and add a second canary in the copy's own git configuration, of the class
   `docs/setup.md` names in its `UNVERIFIED` troubleshooting row: point the copy's `core.fsmonitor`,
   the setting that row names, at a copy of the canary script in the copy's `.claude/hooks/`, by its
   absolute path as the container sees it. Run `git status` in the copy by hand, inside the
   container: `hook-canary` must appear at the copy's root, naming the second canary (look for it as
   the README's step 1 says: one found where the marker is looked for is FAILED: clean up and give
   the copy folders of its own, as the README's step 1 says; otherwise the check is NOT VERIFIED
   until it appears at the copy's root: give the copy folders of its own outside the vault, a fresh
   clone and not a link, with an earlier copy removed as the README's step 1 says, and start this
   step again). Delete it.
2. Positive control for the switch: change a tracked note in the copy without committing it, and run
   a copy of the wrapper that names a copy of the scheduled config with `git: true` on
   `probe.dream-pass.md` (the scheduled config itself stays read-only and unchanged). Look for
   `hook-canary`, at the copy's root and as in step 1, before you run any git command in the copy,
   because your own `git status` there fires the second canary. `hook-canary` must name the second
   canary, or `git log` must show a new commit; note which of the two fired. If neither, the check
   is NOT VERIFIED, never PASS, and `VAULT_ALLOW_UNENFORCED_TOOLS=1` waits until it fires (the
   README's step 3).
3. Control for the commit gate: delete the probe with `rm`, not git, and then `hook-canary`, and run
   that copy of the wrapper again with `git: true`, `git-commit-verify: true` and
   `auto-commits: true` in the copied config: `hook-canary` must appear at the copy's root and name
   `pre-commit` (look for it as in step 1: one found where the marker is looked for is FAILED). Here
   and below, delete probes with `rm` and `hook-canary` last, after any git command of yours: your
   own git commands in the copy fire the second canary, and would leave a false FAILED.
4. Delete the probe and then `hook-canary`, as in step 3, change a tracked note again (so that, were
   git on, Aider would find the repository dirty), and run the wrapper with the scheduled config on
   each probe prompt in turn, deleting the probe with `rm` between them.
5. Look for `hook-canary` first, as in step 2 (one found where step 1 looks for the marker is
   FAILED). PASS only if step 1's identity control found no marker where it looks, by a search that
   honours no ignore file (which rests on the tool: reasoned), reports no folder it could not read
   and is seen to find the known files, as the README's step 1 says, its three conditions held, the
   controls in steps 1 to 3 fired, each run in step 4 wrote the probe, `hook-canary` does not exist,
   `git log` shows no commit after step 3's, and step 5 of the README's check, run in the schedule's
   container with all its mounts, gave what the README's step 6 asks of it. If `hook-canary` exists,
   or `git log` shows a commit after step 3's, the check is FAILED, and
   `VAULT_ALLOW_UNENFORCED_TOOLS` stays unset. A control that did not fire leaves the check NOT
   VERIFIED, never PASS (the README's step 3). The README's step 5, when FAILED or NOT VERIFIED,
   makes this check so too (its NOT VERIFIED: find out why, and run it again). FAILED takes
   precedence, as in the README's step 6. If step 2's control fired by the commit alone, a PASS
   shows only that Aider made no commit in step 4. Then what keeps any git Aider ran from reaching
   anything a pass wrote, of the class `docs/setup.md` names in its `UNVERIFIED` troubleshooting
   row, is the read-only `.git` and `.claude/` mounts below, which step 5 of the README's check
   confirms.

Remove the second canary from the copy's git configuration afterwards. If the scheduled runs do not
show the rules in the chat, check the absolute `read:` paths.

Run the schedule in a container that blocks the network and mounts only the vault writable, with the
vault's `.claude/` (its settings files mounted over it from copies without their hooks) and `.git`
read-only and the empty file read-only over its `.env`, as the README's container rule says, each of
those names a folder or file in the vault, not a link, and, where a file, with a single name (its
step 5 says which); the read-only `.git` costs a pass nothing with `git: false` (reasoned). Before
setting `VAULT_ALLOW_UNENFORCED_TOOLS=1`, confirm in that container, with all its mounts, that
writes into the scratch copy's `.git` and `.claude/` are refused, by step 5 of the README's check:
the check above runs without the `.git` mount, so only that step shows the `.git` and `.claude/`
mounts hold.

## Sources (checked 2026-09-13; the YAML config, options, git and `.env` pages read 2026-10-18)

- YAML config (locations, `read`, `git-commit-verify`, `auto-commits`, `gitignore`, `lint-cmd`, `suggest-shell-commands`, `detect-urls`, `message-file`, `yes-always`, `--config`; the `git` and `auto-lint` entries, read 2026-10-18): <https://aider.chat/docs/config/aider_conf.html>
- Options (`git`, `auto-lint`, `dirty-commits`, `auto-commits`, `git-commit-verify`), read 2026-10-18: <https://aider.chat/docs/config/options.html>
- Git integration (`--no-git`), read 2026-10-18: <https://aider.chat/docs/git.html>
- `.env` (where Aider looks for it), read 2026-10-18: <https://aider.chat/docs/config/dotenv.html>
- Conventions files (`read:`): <https://aider.chat/docs/usage/conventions.html>
