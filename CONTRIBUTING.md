# Contributing

Thanks for considering a contribution.

This repository is a **framework**, not a notebook. It ships the structure, tooling, and
conventions for a tiered memory vault — deliberately with no real notes in it. Keeping that
boundary clean is the main thing to know before you open a pull request.

## Do not commit your notes

The single most likely accident here is publishing your own knowledge base.

If you use this repo as your actual vault, **keep your copy private**. `.gitignore` contains a
commented-out block that excludes note content from every tier; uncomment it in your fork before
you start writing, and your notes stay local while the framework stays trackable.

Be aware of the asymmetry if something does slip out: a history rewrite still cannot remove the
diff from a pull request, because GitHub stores those under `refs/pull/*` where nobody can rewrite
them, and forks and clones keep their own copies. Making a repository private is faster and more
complete than any rewrite. Check `git status` before `git add -A`.

Fictional example notes are welcome. Real ones are not — including real project names, employer
names, hostnames, and absolute paths containing a username.

## Before you open a pull request

Run both checkers:

```bash
bash .claude/scripts/run-tests.sh     # control suite for the hooks
bash .claude/scripts/vault-check.sh   # frontmatter invariants
```

Both must pass. For `vault-check.sh`, read the file count as well as the violation count:
`0 violations across 0 files` means it scanned nothing, which is a broken invocation, not a pass.

CI (`.github/workflows/ci.yml`) runs both on ubuntu-latest, macos-latest and windows-latest, plus a
separate job that runs them under macOS's system `/bin/bash` 3.2. It deliberately does **not**
install `jq`, because `jq` is absent by default on macOS and in Git for Windows and the hooks are
written to degrade loudly without it, and installing it in CI would hide the case most users hit.

## Changing a shell script

The hooks run on macOS, Linux, and Windows via Git Bash, and the differences bite in ways that
are invisible on the machine you are testing on:

- **`grep -P` is a GNU extension.** BSD grep on macOS does not have it. A `grep -P ... 2>/dev/null`
  returns empty there, which reads as "found nothing" rather than "could not run". Prefer `perl`,
  and guard both.
- **`jq` is not bundled with Git for Windows.** Guard it with `command -v` and degrade loudly.
- **Quote your paths.** A vault can live under `C:/Users/Some One/` or macOS iCloud's
  `~/Library/Mobile Documents/`. Use bash arrays for directory lists, not space-joined strings.
- **Count with `awk`, not `grep -c`.** `grep -c` prints `0` *and* exits 1 on no-match, so
  `n=$(grep -c x f || echo 0)` yields `"0\n0"` and breaks numeric comparisons.

If you add a check, **add a positive control for it** in `run-tests.sh`. A check that cannot fail
is not a check, and a test suite that only ever asserts "clean" cannot tell a working instrument
from a broken one. The suite pairs known-bad inputs that must be flagged with known-good inputs
that must stay silent; please give a new check at least one of each.

`VAULT_FORCE_NO_JQ=1` makes the hooks take their no-jq fallback even where `jq` is installed — the
path most macOS and Git for Windows users actually run. The suite already uses it for its no-jq
tests; if your change touches a `jq` code path, add a test there that sets it.

Line endings are governed by `.gitattributes`: `*.sh` is `eol=lf`, `*.cmd` is `eol=crlf`. A CR in
a shebang gives `bad interpreter` on Linux. Windows has no executable bit, so a
script committed from Windows lands as `100644`; fix it in the index with
`git update-index --chmod=+x <file>` and verify with `git ls-files -s`.

## Adding or removing a file

Two artifacts have to keep up, and CI fails when they do not.

**`.claude/manifest-rules` decides what happens to every tracked file in somebody else's vault.**
It has no catch-all rule on purpose, so a file matching none of them fails generation by name. Add
a rule for whatever you add. The classes are `owned` (template machinery this project maintains),
`seed` (shipped once, then the reader's — examples, scaffolds, Obsidian config) and `excluded`
(belongs to this project rather than to a vault, such as the workflows and this file). The first
matching rule wins, so specific rules go above general ones.

**`.claude/template-manifest` is generated from those rules, and goes stale the moment you edit a
shipped file.** Regenerate it in the same commit:

```bash
VAULT_TEMPLATE_MAINTAINER=1 bash .claude/scripts/vault-update.sh --generate
bash .claude/scripts/vault-update.sh --verify-manifest
```

The environment variable is not ceremony. Run in somebody's vault, `--generate` takes that vault's
notes in as template entries and restamps every hash from the current files, after which every
file reads as untouched and the record of what they had changed is gone.

Expect a conflict in the hash lines when two pull requests touch the same file. Regenerate after
merging rather than resolving the hashes by hand — a hand-edited hash is a claim nobody checked.

## Cutting a release

1. Set `VERSION`.
2. Add a `CHANGELOG.md` entry with an **Adopting this** note. Every entry needs one, and the
   control suite fails a release without it. Say "nothing to do" in as many words when that is the
   answer, because a note nobody wrote and a release that needs nothing look identical otherwise.
3. Regenerate the manifest, so its `version` header matches `VERSION`.
4. Tag and publish a GitHub release. That release is the notification channel — downstream vaults
   find out by watching it, and nothing in this repository makes a network call.

## Changing the documentation

Docs live in `docs/` and should stay accurate rather than aspirational. If a step needs manual
setup, say so. If a feature is advisory rather than enforced, say that too — the lint hook always
exits 0 by design, and claiming otherwise would be the kind of overselling this project's own
standards argue against.

## Changing the frontmatter contract

Adding an optional key is non-breaking; Dataview ignores keys nothing queries. Removing or
renaming `tier` or `type` breaks the lint hook, `vault-check.sh`, and most dashboards at once, so
those changes need a matching update across `.claude/rules/`, both checkers, and
`30-knowledge/moc/VAULT-INDEX.md`. See `docs/customizing.md` for the full list of files that
hardcode tier names.

## Reporting a problem

Please include your platform, your bash version, whether `jq` and `perl` are present, and the
output of `bash .claude/scripts/run-tests.sh`. That last one usually identifies the issue on its
own.
