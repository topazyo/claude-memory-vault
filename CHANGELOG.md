# Changelog

What has changed in this template, and what a vault made from it has to do about each change.

Every entry carries an **Adopting this** note. That note is the only part of a release that can
carry a *semantic* change, because `vault-update.sh` moves bytes and cannot know that the `TIERS=`
line you customized inside `vault-check.sh` (see [`docs/customizing.md` §2](docs/customizing.md))
now needs a seventh entry. When a release needs nothing from you, the note says so in as many words,
because "nothing to do" and "nobody wrote the note" look identical otherwise.

**Apply the notes in release order.** A vault three releases behind applies three notes, oldest
first. A note may undo something an earlier note asked for, and reading them out of order gives a
result neither of them intended.

How to see where you stand, and what moved:

```bash
bash .claude/scripts/vault-update.sh --status
# then fetch a newer copy yourself, and compare against it
git clone https://github.com/<owner>/claude-memory-vault.git ../template-new
bash .claude/scripts/vault-update.sh --check --from ../template-new
```

[`docs/updating.md`](docs/updating.md) explains both, and says what they do not protect against.

---

## 1.1.0 — 2026-09-22

Mostly a release about releases. 1.0.0 shipped a mechanism that tells a vault what moved upstream
and relies on a release being cut whenever something does, and nothing enforced that. 1.0.0 was
itself merged first and tagged afterwards by hand.

### Added

- `.claude/scripts/vault-update.sh --check` now prints the SHA-256 of each file in the safe-to-take
  list, says in that list's heading what the digest is, and says in the copy plan's own preamble
  that the plan describes the source folder as it was when the check read it. Nothing re-reads that
  folder between then and whenever you paste, and that gap is you reading rather than a race inside
  the script, so it cannot be closed in code. The digest is what lets you settle it in one command
  instead. It is the digest of the bytes, which is not the one the manifest records, and
  `docs/updating.md` says why.
- `VAULT_FORCE_NO_DIFF=1`, which makes `--diff` take its no-diff-tool refusal on a machine that has
  one. It is the same kind of seam as `VAULT_FORCE_NO_SHA` beside it, and it exists so that refusal
  can have a control.

### Changed

- The source symlink refusal tests **every component of a path** rather than only its last one. A
  source could otherwise ship one symbolic link named `docs` and walk every entry beneath it past a
  check whose whole purpose was to stop that, while verifying against its own manifest perfectly.
- The truncated lists in the source checks say how many entries there were, the way every other
  list in that script already did.
- `AGENTS.md` carries a new rule, and it is the only change in this release that tells an agent to
  do something differently. It says not to change a file the template ships without setting
  `VERSION`, which is a rule for people contributing to the template and not for your vault. It is
  written to say so, and the note below says what to do if you take it anyway.
- `docs/updating.md` explains the digest beside each path and which digest it is.
  `docs/reference.md` records the two environment variables that force a refusal for testing.

### Adopting this

**Nothing to do, and one thing to read if you take `AGENTS.md`.**

No frontmatter key, tier, folder or exit code has changed, and no command you run takes different
arguments. What did change is output, in three places, which matters only if something of yours
reads it by position rather than by the counts line. `--check` prints a digest column in the
safe-to-take list, a sentence in that list's heading and a sentence in the copy plan's preamble,
and the refusal warnings about a source folder now end with a count of how many entries there
were rather than a silent truncation.

`AGENTS.md` is shipped, so `--check` will offer it, and it is the one file in this release where
taking the bytes also takes a standing instruction every harness loads. The new rule scopes itself
to contributing to the template, so it costs a vault nothing, but read the bullet before you copy
it rather than after.

The symlink change is a hardening one and you will almost certainly never see it. It refuses a
source that reaches its own files through a symbolic link **inside** the folder, which a `git
clone` of this template never produces. The folder you point `--from` at may itself live under a
symlinked path, and that is not affected — only links below it are tested, because you chose that
folder and the template did not.

If you fetched this release with `--check`, read the digests in the safe-to-take list against the
folder you are about to copy out of. That is what they are for, and it applies whether or not your
vault is a git repository.

---

## 1.0.0 — 2026-09-21

The first version with a version. Everything before this shipped unnumbered, so a vault created
earlier has no record of where it came from.

### Added

- `VERSION`, a single line naming the template version.
- `CHANGELOG.md`, this file.
- `.claude/manifest-rules`, which decides for every tracked file whether the template owns it,
  hands it over, or keeps it to itself. It has no catch-all rule, so a new file cannot enter the
  template without somebody deciding what happens to it in your vault.
- `.claude/template-manifest`, generated from those rules. It records the class and the SHA-256 of
  every file the template ships, and it is what lets a vault answer "what have I changed" with no
  network, no git and no second copy of the template.
- `.claude/scripts/vault-update.sh`, with `--status`, `--check`, `--diff`, `--adopt`,
  `--generate` and `--verify-manifest`.
- `docs/updating.md`.
- One report-only line in `vault-check.sh` naming the template version this vault records.

### Changed

- `.gitattributes` now pins the catch-all to `eol=lf`. Without it, files named by no specific rule
  check out with carriage returns on Windows, and a hash of their bytes would depend on which
  platform took it.

### Adopting this

**Nothing, if your vault was created from this version or later.** You already have the manifest.

**If your vault predates this release**, it has no manifest, so `--status` cannot tell you anything.
1.0.0 is the first version that ships one, so 1.0.0 is the only thing there is to adopt against.
Fetch a copy yourself and record a baseline once:

```bash
git clone https://github.com/<owner>/claude-memory-vault.git ../template-new
bash .claude/scripts/vault-update.sh --adopt --from ../template-new
```

Read what it prints. Adopting records the template's hashes as your starting point, so **any
template file you had already changed is recorded as though the template shipped it that way**, and
it will read as untouched from then on. Nothing recovers that — the hashes were never written down.
Treat the first `--check` report as a starting point rather than a verdict.

From the next release onward the advice changes, because there will then be older releases to choose
between: adopt against the oldest one you might plausibly have started from, so the tool
over-reports what you changed rather than under-reporting it.
