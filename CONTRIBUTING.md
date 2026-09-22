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

**If your change touches a file this template ships, or changes which files it ships, it owes a
release**, which means setting `VERSION` and writing a changelog entry in the same pull request.
The second half of that is easy to miss, because a commit that only moves a path between `owned`,
`seed` and `excluded` edits nothing shipped and still changes exactly what a release exists to
announce. All of this is worth knowing now rather than when CI tells you, and *Cutting a release*
below says what to do and why the rule exists.

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
It has no catch-all rule on purpose, so a file matching none of them fails generation by name.

Most additions need no rule at all, because they already fall under a glob — a new page under
`docs/` is covered by `owned docs/*`. Add a rule only when nothing above would catch your file, or
when something above would catch it *wrongly*. The classes are `owned` (template machinery this
project maintains), `seed` (shipped once, then the reader's — examples, scaffolds, Obsidian config)
and `excluded` (belongs to this project rather than to a vault, such as the workflows and this file).

**Match order beats the class blocks.** The file is grouped by class so it can be read, but the
matcher takes the first line that matches. A rule that has to beat a broader one goes physically
above it, even when that means leaving its own block. The four per-tier `templates/` rules sit above
the tier `seed` rules for exactly that reason.

One more thing if you add a file the template is meant to keep maintaining. The
`may_be_machinery()` function, in the awk program inside `read_manifest` in `vault-update.sh`,
carries the list of places a template is allowed to ship machinery, so that nothing a manifest says
can widen it, and that list and the rules have to agree. Under a content tier the allowance is five
exact strings, and outside one it is `MACHINERY_ROOTS` and `MACHINERY_FILES` near the top of the
same script. The `tmpl-exempt-set-matches-the-tree` control fails when a path the rules ship as
`owned` is one that list would narrow away, which would mean the template shipped a file its own
tool never offers to anybody.

**`.claude/template-manifest` is generated from those rules, and goes stale the moment you edit a
shipped file.** Regenerate it in the same commit:

```bash
VAULT_TEMPLATE_MAINTAINER=1 bash .claude/scripts/vault-update.sh --generate
bash .claude/scripts/vault-update.sh --verify-manifest
```

The environment variable is not ceremony. Inside somebody's vault, `--generate` takes that vault's
notes in as template entries and restamps every hash from the current files, after which every file
reads as untouched and the record of what they had changed is gone.

Expect a conflict in the hash lines when two pull requests touch the same file. Regenerate after
merging rather than resolving the hashes by hand — a hand-edited hash is a claim nobody checked.

The CI step that verifies the manifest is guarded to this repository, because "Use this template"
copies the whole workflow into somebody's vault where their tree and the manifest diverge on their
first note. So it runs on your **pull request**, where the base repository is this one, and it does
**not** run on pushes to your own fork. Watching it skip there does not mean it is unenforced.

## Cutting a release

**Every merge that changes a file this template ships is a release.** That is a policy rather than
a side effect of one, and CI enforces it, so it is worth knowing before you open a pull request
that touches a shipped file.

**And so is every merge that changes WHICH files it ships**, even when no file's bytes move.
Moving a path between `owned`, `seed` and `excluded` in `.claude/manifest-rules` changes what every
vault is told this template ships, and the only files it edits are that rules file and the manifest
generated from it, both of which are themselves excluded. So a reclassification looks like a commit
that touches nothing shipped while being exactly the kind of change a vault has to hear about.
(*Told*, rather than *offered*, because the two are not the same for every direction —
[`docs/updating.md` §5](docs/updating.md) explains that a path in both manifests takes its class
from the reader's own record, so an `owned`↔`seed` move reaches them only once their baseline is
renewed, while a move to or from `excluded` changes what they are offered straight away.) `release-check.sh` compares the classes as well as the content
for that reason and refuses with `SHIPPED-RECLASSIFIED`. The direction that matters most is a path
leaving the set, because once the next release is cut for any reason the new tag does not name it
either, and from then on every change to it is invisible to the comparison.

The reason is that a release is the only way anybody downstream finds out. `vault-update.sh` tells
a vault what moved by comparing manifests, and `docs/updating.md` tells the reader to hear about a
newer copy by watching this repository's releases. A merge that edited a shipped file, left
`VERSION` alone and was never tagged produced a template whose newest content no vault could
discover, while the manifest still verified and CI still went green. Version 1.0.0 was itself
merged first and tagged afterwards by hand, because somebody remembered.

**The tag is the source of truth.** `VERSION`, the manifest header and the newest changelog entry
are three claims about a release that any single commit can rewrite together. The tag is the only
one that becomes immutable once pushed and the only one a vault can fetch. So `tmpl-version-agrees`
checks that the three claims agree with each other, and `.github/release-check.sh` checks that what
they agree on has actually been published.

**The tag is spelled with digits and dots and no `v`,** so `1.1.0` rather than `v1.1.0`.
`CHANGELOG.md` heads its entries that way and the clone example in `docs/updating.md` names a tag
that way, so a prefix would have to move in the tag, the changelog and that example together. A
tag that looks like a prefixed version is therefore refused by name rather than skipped, and so is
a `VERSION` holding anything but digits and dots — a suffix like `1.2.0-rc1` would otherwise be
tagged once and then be invisible to every run after it.

The work splits in two, and it is worth saying which half is yours. **Anybody opening a pull
request does the four steps below.** Publishing the release afterwards needs push access to this
repository and an authenticated `gh`, so it is the maintainer's, and an outside contributor who
tries it will be denied for a permission they were never meant to have.

In a pull request that changes a shipped file, or that changes which files are shipped:

1. **Set `VERSION` to a number above the newest tag.** `git tag -l --sort=-v:refname | head -n 1`
   names the newest one. Sort it that way rather than reading the list, because plain text order
   puts `1.10.0` before `1.9.0`.
2. **Add a `CHANGELOG.md` entry with an Adopting this note.** Two strings are matched literally,
   so copy the shape of the entry above rather than inventing one:
   ```markdown
   ## 1.3.0 — 2026-11-01

   ### Adopting this

   Nothing to do.
   ```
   The heading must be `## <version>` with the version as its second word, because that is what
   `release-check.sh --tag` reads to find the entry and what it compares against `VERSION`. A
   bracketed form like `## [1.3.0] - 2026-11-01` reads as the version `[1.3.0]` and is refused. The
   note must be a `### Adopting this` heading, because `tmpl-changelog-adopting` matches that line
   and nothing else — bold text or a different heading level is invisible to it.

   **It must also be the newest entry in the file**, since that is the one both checks read. An
   `## Unreleased` section above the releases counts as the newest and will be read instead.

   Say "nothing to do" in as many words when that is the answer, because a note nobody wrote and a
   release that needs nothing look identical otherwise. The note is the only part of a release that
   can carry a meaning rather than bytes, so it has to cover every shipped file the branch touches
   — including `AGENTS.md` and anything under `docs/`, which are shipped and which a vault owner
   will be offered.
3. **Regenerate the manifest, last.** This has to be the final edit to a shipped file in the
   branch, because anything changed after it leaves the manifest stale and fails the CI step that
   verifies it.
   ```bash
   VAULT_TEMPLATE_MAINTAINER=1 bash .claude/scripts/vault-update.sh --generate
   ```
   The environment variable is explained under *Adding or removing a file* above, and without it
   this refuses with exit 64.
4. **Run `bash .claude/scripts/run-tests.sh`.** `tmpl-version-agrees` fails a release whose three
   statements of the version disagree, and `tmpl-changelog-adopting` fails one whose newest entry
   carries no adopting note. Neither fires unless somebody runs the suite.

After it merges, `main` carries a version that names no tag, and the repository hygiene job goes
red saying so. Clearing that red takes the four steps below and then a re-run of that job.

**Do this from the main checkout, with `main` pulled, and from the repository root.** `--tag` tags
whatever `HEAD` is, and it neither knows nor asks which branch that is. Run it from the feature
branch, or from a `main` you have not pulled since the merge, and it writes the tag on the wrong
commit — and a pushed tag is the one artefact here that cannot be quietly corrected. This is easy
to get wrong because the person doing it is the likeliest to be sitting in a linked worktree on the
branch that just merged. Walk over to the main checkout rather than running `git checkout main`
where you are, because git refuses a branch another worktree already holds and exits 128 saying so,
and the two obvious ways around that refusal both end in a tag on the wrong commit.

```bash
git checkout main && git pull
bash .github/release-check.sh --tag
git push origin <the version>
gh release create <the version> --title <the version> --notes-file <the file it named>
```

The second writes the annotated tag with the changelog entry as its message, and prints the last
two filled in. Those last two are the only steps the script refuses to run for you, because they
are the ones that publish something nobody can take back, so it prints them filled in rather than
running them. **The push is what clears the red**, because the job checks
out with tags and only sees the ones that have been pushed, so re-running it after the tag exists
only locally leaves it exactly as red. Re-run the job after the push, because tagging does not
re-trigger the workflow.

You can run the check itself at any time. It works from any directory inside the repository,
though the path below is written from the root:

```bash
bash .github/release-check.sh
```

It exits 0 when the release keeps up with what this tree ships, 1 when a release is owed or the
tree claims a version it is not, 2 when it could not answer, and 64 when the command line was
wrong. It could not answer when there is no git, no readable `VERSION`, a `VERSION` spelled a way
it cannot read, no readable manifest, no tags in the checkout, a tag whose tree holds no manifest,
a shipped set git does not recognise, a comparison git could not make, or a tag git would not
write. **The 2 matters:** a shallow clone has no tags and looks exactly like a project that has
never released one, and those two want opposite responses. The CI step gives each of them its own
annotation for that reason, because the usual answer to a red release check is to weaken it.

Two of those causes used to leave on 1, and they are the third and the last. A `VERSION` holding
something that is not a version, and a `git tag` the tool refused to write, are both the check
failing to get an answer rather than the check finding that a release is owed, and both said so in
their own words while leaving by the other door. They moved in 1.2.0. No vault read either code,
because this script is classed `excluded` and is never copied into one, and the reader that does
read them is the CI step above — which from 1.2.0 gives both of them its could-not-answer
annotation rather than its release-owed one, which is the point of the change.

The script's header publishes every refusal tag it can print, so output can be grepped against a
document rather than against a memory of one. Four of those names also appear in
`vault-update.sh` and do not mean the same thing there, and the header says which.

**The CI step is guarded by repository and is not path filtered.** A path filtered step shows as
skipped on a pull request that touches nothing matching the filter, and a reviewer reading the
checks list cannot tell a skip from a pass. This one runs on every pull request and every push to
`main` here, including pull requests from forks, because `github.repository` is still this
repository for those.

It skips everywhere else, and that includes **pushes to your own fork** as well as a repository
made with "Use this template". This is the same wrinkle the manifest step has above, and it has the
same answer: watching it skip on your fork does not mean it is unenforced, and it will run on the
pull request.

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
