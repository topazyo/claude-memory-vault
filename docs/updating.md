# Updating a vault when the template moves

This repository is a template. You made a vault from it, and then you lived in that vault for
months while the template kept changing. This page is how you find out what changed, and how you
take the parts you want without losing the parts you wrote.

Two things are deliberately separate here, and it is worth knowing why before you read the rest.

**Finding out is free and safe.** Being told that version 1.2.0 exists cannot hurt your vault, and
it should reach you even if your vault is not in git and you never open a terminal in it.

**Taking a change is neither.** Almost everything the template owns lives under `.claude/`, and
`.claude/` is what your harness reads to decide what code to run and what instructions to load.
Copying a file in from anywhere puts whoever wrote it in charge of that. So nothing here fetches
anything, nothing here runs anything it fetched, and nothing here overwrites a file for you.

---

## 1. Finding out

**Watch the releases.** On the template's GitHub page, use *Watch → Custom → Releases*. That is the
whole notification mechanism, it costs this repository one tag per release, and it works for people
who have never run a command in their vault.

**Read [`CHANGELOG.md`](../CHANGELOG.md).** Every entry carries an **Adopting this** note saying
what you have to do by hand. That note is the only thing that can carry a change in *meaning* — a
tool can tell you `vault-check.sh` changed, but only prose can tell you that the `TIERS=` line you
customized inside it (see [`customizing.md` §2](customizing.md)) now needs a seventh entry. Apply
the notes in release order, oldest first.

If your vault is not on GitHub, nothing will push you a notification and nothing here pretends
otherwise. The alternative would be an outbound network call from a personal knowledge vault, and
this project does not want one. Put a quarterly reminder somewhere instead.

---

## 2. Seeing where you stand, offline

```bash
bash .claude/scripts/vault-update.sh --status
```

No network, no git, no second copy of the template. It reads
`.claude/template-manifest` — which shipped with your vault and records what the template's files
looked like at the version you have — hashes your copies, and tells you which of them you have
changed.

```
vault-update: this vault records template version X.Y.Z.
vault-update: 69 of 72 template file(s) match that record, 2 changed here, 1 deleted.
vault-update: That record is what the template shipped at X.Y.Z. It is not a claim about what the template holds now.
```

Those counts are whatever your vault has. Read the numbers rather than matching the wording around
them, which is the same habit `vault-check.sh`'s own summary line asks for.

**And it is not a claim about what is on your disk either.** The gap between the record and your
disk is exactly what that second line counted. Believing the record describes your files is the one
misreading that costs you something, because it makes a file you changed look untouched.

**Read that as a record, not as a verdict on the template.** The manifest says what the template
shipped at 1.0.0. It says nothing about what the template holds today, and a hash edited to make
this report go quiet would clear the alarm without establishing anything — the same unearned
freshness stamp this vault's own rules warn about for `last_verified`.

Files you have changed are expected. [`customizing.md`](customizing.md) invites most of them.

---

## 3. Seeing what moved

You fetch the new template yourself. That is the security boundary, and it is deliberate.

```bash
git clone https://github.com/<owner>/claude-memory-vault.git ../template-new
# or download the release zip from GitHub and unpack it somewhere
bash .claude/scripts/vault-update.sh --check --from ../template-new
```

`--check` compares three things. What the template shipped at your version, what is on your disk
now, and what the newer copy ships. That gives six answers.

| Bucket | Meaning |
| --- | --- |
| **Safe to take** | It moved upstream and you never touched your copy, so copying loses nothing. |
| **Moved upstream and changed here** | Both sides moved. Nothing will overwrite it. Read it with `--diff` and merge it yourself. |
| **Already yours, and now shipped too** | The template has started shipping a file at a path you already occupy. **Not safe to take**, and kept out of the copy plan. The record has never held that path, so nothing here can tell your file from an old copy of theirs. Open both yourself. |
| **Already carrying the newer copy** | You took this one at some point. Nothing to do, and it is not asked about again. |
| **No longer shipped** | The template retired it. Your copy is left exactly where it is, because nothing here deletes. |
| **Shipped once and yours now** | Example notes, scaffolds, Obsidian settings. Reported as a count, because every vault drifts here and listing it every time would teach you to stop reading. |

`--check` ends with a ready-to-paste list of `cp` commands for the safe ones. Read the diff before
you run them.

```bash
bash .claude/scripts/vault-update.sh --diff --from ../template-new
```

### If your vault predates all of this

It has no manifest, so there is no baseline to compare against and `--status` says so rather than
guessing. Record one, once:

```bash
bash .claude/scripts/vault-update.sh --adopt --from ../template-new
```

It writes `.claude/template-manifest` and touches nothing else. It needs a working SHA-256 tool even
though it only copies a file, because a baseline you cannot then compare against is not worth
recording, and finding that out now is kinder than finding it out on the first `--status`.

Be clear about what it costs: **every template file you had already changed is recorded as though
the template shipped it that way**, so from then on it reads as untouched. There is no way around
that — the hashes were never written down, and no design recovers information that does not exist.
Adopt against the oldest release you might plausibly have started from, so the tool over-reports
what you changed rather than under-reporting it.

It copies that folder's manifest as it stands. If the manifest claimed one of your notes was
template machinery you will have seen a `NARROWED` warning, and the claim stays in the file — it is
refused again every time the file is read, because that refusal lives in the script rather than in
the record.

---

## 4. The other route, for a vault that is in git

[`customizing.md` §8](customizing.md#8-keeping-your-notes-private-while-tracking-the-framework)
documents `git remote add template`, `git fetch template` and `git merge template/main`, including
the `fatal: refusing to merge unrelated histories` trap that GitHub's "Use this template" button
causes and the `--allow-unrelated-histories` fix for the first sync.

**The two routes are alternatives, not layers.** Running both double-applies and leaves you
resolving conflicts against files the other one already moved. Pick one:

- **The merge route** if you forked, keep your vault in git, and are comfortable with
  `git mergetool`. Git does a real three-way merge, which is genuinely better at merging than
  anything here.
- **This tool** otherwise, and that is most people. It is the only route that works for a vault
  that is not a git repository at all, and it is the only one that knows which files are the
  template's and which are yours — `git merge` will happily carry template changes into
  `30-knowledge/moc/ARCH-INDEX.md`, a scaffold you were told to rewrite, and conflict there for no
  reason.

---

## 5. What this does not protect against

Say the honest version, because a security mechanism you have the wrong idea about is worse than
none.

**Whoever controls the template can change any file the template ships.** A hook under
`.claude/hooks/`, `.claude/settings.json`, a rules file, an agent definition. If you copy one of
those in, your harness runs it in the next session. The sharpest single case is
`.claude/agents/dream-agent.md`. Adding `Bash` to its `tools:` line turns one file you copied into
scheduled, unattended execution on your next nightly pass.

That exposure is not created by this tool. It is identical for `git merge template/main`, which the
docs already recommend, and for copying a file by hand. What this adds is that the exposure is
**enumerated and shown to you before it happens**, and that it happens at a moment you chose.

What the tool does do:

- **It never reaches the network.** Not in any mode. You fetch the template yourself, with tools
  you already trust, and the trust decision stays where you can see it.
- **It never runs anything out of the folder you point it at**, including that folder's own copy of
  this script. It reads bytes and hashes them. `--diff` pins git's configuration off, because
  `git diff` otherwise honours `diff.external` and `textconv` filters, and both of those run a
  command named in configuration.
- **It never writes a file for you.** The only file it ever writes is the manifest, under `--adopt`
  and `--generate`.
- **It never treats a path under your note folders as the template's**, whatever a manifest says,
  with five exceptions it carries by name — `30-knowledge/moc/VAULT-INDEX.md` and the four per-tier
  note templates, which are machinery wearing a note's clothes. Everything else under a content tier
  is forced back to *yours*, and the tier names are compared with case folded because Windows and
  macOS fold it for you when a copy command is pasted. That refusal lives in the running script and
  not in the data, so a hostile copy can only ever narrow what this treats as the template's.
- **It checks that the folder you pointed at holds what its own manifest says it holds**, and
  refuses the whole comparison when it does not. Without that, "safe to take" would be that copy's
  unverified claim about itself and the copy commands would move bytes nothing had looked at. It is
  a coherence check rather than a defence — somebody who can rewrite a file there can rewrite its
  manifest line too — and what it buys is that the manifest becomes the one artefact worth reading,
  and that a half-finished download is caught rather than presented as an update.
- **It refuses while a scheduled pass is running**, and refuses while a runner tripwire is set. The
  two maintainer modes in §7 are exempt, because they run in the template repository where there is
  no pass to collide with.

Two limits inside those guarantees, stated rather than left implied. A file that is on disk and
cannot be read is reported as **unreadable** and not as one you deleted, because "the owner removed
this" is a finding and "this could not be read" is a refusal to answer, and those want different
responses. And `PATH-BLOCKED` tests the *text* of a path rather than resolving it, so a symlinked
folder you created yourself is followed — your own links are not the threat this guards against, but
the guard is about the shape of a path rather than about where it lands.

What it does not do:

- Read the diff for you.
- Merge a file you have both changed.
- Reach a vault whose owner never runs anything.
- Tell you anything about a file that **neither** manifest names. Those are never read, never hashed
  and never listed. The one exception is a file the newer template has started shipping at a path
  you already occupy, which is named on purpose — that is the collision warning, and naming it is
  the whole point of it.

**Do not schedule it.** It is not wired into any scheduled pass, ships no `.cmd` wrapper, and is
documented here as the one thing not to automate. An adopter running unattended would be doing on a
timer precisely what the runners' snapshot fence exists to catch.

---

## 6. Exit codes

`--check` and `--status` are comparisons, so they have three answers rather than two.

| Code | Meaning |
| --- | --- |
| `0` | It could look, and there is nothing to adopt. |
| `10` | It could look, and there **is** something to adopt, or `--status` found local drift. |
| `2` | It could **not** look, so it is saying nothing about the template. No manifest (`NO-MANIFEST`), no working hash tool (`HASH-UNAVAILABLE`), an unreadable or non-template source (`NO-SOURCE`, `NOT-A-TEMPLATE`), a hash algorithm it does not know (`UNKNOWN-ALGORITHM`), a source older than this vault (`SOURCE-IS-OLDER`), a version it cannot order (`VERSION-UNREADABLE`), a comparison of zero files on either side (`VACUOUS`, `SOURCE-VACUOUS`), a source that disagrees with its own manifest (`SOURCE-DISAGREES`), or two copies that both claim one version and differ (`SAME-VERSION-DISAGREES`). |
| `1` | This vault has a problem. The manifest cannot be parsed (`MANIFEST-MALFORMED`), or `--verify-manifest` found it stale (`MANIFEST-STALE`). |
| `3` | Refused because of the state of the vault rather than the command line. `--adopt` where a baseline already exists (`ALREADY-ADOPTED`). To adopt a different baseline on purpose, delete `.claude/template-manifest` and run it again. |
| `6` | A manifest entry named a path outside the vault (`PATH-BLOCKED`). |
| `64` | The command line was wrong, or `--generate` was run without `VAULT_TEMPLATE_MAINTAINER=1` (`NOT-THE-TEMPLATE`). |
| `75` | A scheduled pass is in flight, so nothing was done (`PASS-IN-FLIGHT`). |
| `78` | A runner tripwire is set, so nothing was done (`TRIPWIRE`). |
| `130` / `143` | Interrupted or terminated. The temporary directory is removed either way. |

**`SAME-VERSION-DISAGREES` is the one to expect.** GitHub's "Use this template" button copies the
default branch at that moment rather than the last release, so a vault made that way carries a
version number whose content is ahead of it. Two copies that both say `1.0.0` and differ cannot be
ordered by their version numbers, and being told that is better than being given a confident wrong
answer.

Every refusal prints a tag like those above as the first word after `vault-update:`, so the output
is greppable against this table.

`10` rather than `1` for "there is something to adopt", on purpose.
[`reference.md` §10](reference.md#10-exit-codes-and-log-locations) records that `1` means *the
vault has a problem* everywhere else here. An available release is not a problem with your vault,
and [`customizing.md`](customizing.md) actively invites the edits that produce local drift, so a
correctly customized vault would sit on exit 1 for ever and nobody could put this in a gate.
Folding it into `0` instead would leave "up to date" and "an update exists" sharing one answer, and
those are two different answers.

**Which of the two to gate on.** `--status` returns 10 on any vault you have customized, which is
most of them, so it is a report rather than a gate. `--check` is the one worth gating on, because
`0` there means there is nothing upstream to look at. `--diff` returns 10 whenever it printed a
difference, which is its ordinary outcome.

Read the counts line rather than matching the words around it:

```
vault-update: 7 moved upstream, 2 also changed here, 5 safe to take (recorded 1.0.0, source 1.1.0).
```

---

## 7. For maintainers of the template itself

Two modes exist for the template repository and not for a vault.

```bash
VAULT_TEMPLATE_MAINTAINER=1 bash .claude/scripts/vault-update.sh --generate
bash .claude/scripts/vault-update.sh --verify-manifest
```

`--generate` rewrites the manifest from `.claude/manifest-rules` and the tracked tree. It needs
`VAULT_TEMPLATE_MAINTAINER=1` because running it inside a vault would take that vault's notes in as
template entries and restamp every hash from the current files, after which every file reads as
untouched and the record of what the user had changed is gone. That is the most destructive thing
the tool can do, and an environment variable is what stops it being reachable by curiosity.

`--verify-manifest` runs in CI and fails when the manifest has drifted from the tree. It catches a
maintainer who edited a file and forgot to regenerate, which is the mistake that actually happens.
It does **not** check that the classification is *right*: both sides run the same rules, so a wrong
rule is perfectly self-consistent. A hand-maintained table in `run-tests.sh` names specific paths
and their expected class, and that is the control that can fail.

Adding a file to the template means adding a rule for it. There is no catch-all, so an
unclassified file fails generation and fails CI, naming the path.
