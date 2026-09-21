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

Run it from the vault root, and unpiped, because a pipe reports the pager's exit status rather
than this script's, and the exit codes are the point of §6. On Windows run it from Git Bash, as
with every other script here.

No network, no git, no second copy of the template. It reads
`.claude/template-manifest` — which shipped with your vault and records what the template's files
looked like at the version you have — hashes your copies, and tells you which of them you have
changed.

```
vault-update: this vault records template version X.Y.Z.
vault-update: 69 of 72 template file(s) match that record, 2 changed here, 1 deleted, 0 could not be read.
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
# <owner> is the repository your vault was generated from. Your repository's
# GitHub page names it under the title, and `git remote get-url template`
# answers it if you followed customizing.md section 8.
git clone --depth 1 --branch 1.1.0 https://github.com/<owner>/claude-memory-vault.git ../template-new
bash .claude/scripts/vault-update.sh --check --from ../template-new
```

**Clone the release tag rather than the default branch.** A plain `git clone` takes whatever the
default branch holds at that moment, which is routinely ahead of the last release while still
carrying that release's version number, and two copies that claim one version and differ is the
`SAME-VERSION-DISAGREES` refusal in §6. Following the untagged command is the most likely way to
meet it.

A release zip works just as well. Point `--from` at the folder that **contains `.claude/`**, which
for a zip is the folder inside the archive rather than the folder you unpacked into. Pointing it
one level too high gives `NOT-A-TEMPLATE` and says nothing about why.

`--check` compares three things. What the template shipped at your version, what is on your disk
now, and what the newer copy ships. That gives nine answers.

| Bucket | Meaning |
| --- | --- |
| **Safe to take** | It moved upstream and you never touched your copy, so copying loses nothing. |
| **Moved upstream and changed here** | Both sides moved. Nothing will overwrite it. Read it with `--diff` and merge it yourself. |
| **Already yours, and now shipped too** | The template has started shipping a file at a path you already occupy. **Not safe to take**, and kept out of the copy plan. The record has never held that path, so nothing here can tell your file from an old copy of theirs. Open both yourself. |
| **Already carrying the newer copy** | You took this one at some point. Nothing to do. It is counted on the sentinel line and never listed for a decision. |
| **No longer shipped** | The template retired it. Your copy is left exactly where it is, because nothing here deletes. |
| **Shipped once and yours now** | Example notes, scaffolds, Obsidian settings. Reported as a count, because every vault drifts here and listing it every time would teach you to stop reading. |
| **You changed it** | A template file whose bytes differ from the record. `--status` reports these too, and it is the same list. |
| **You deleted it** | A template file the record names and your disk does not have. Deleting one is a normal thing to do and nothing puts it back. |
| **Could not be read** | It is on the disk and could not be opened, so nothing is known about it. This is the tool refusing to answer rather than a finding, and any file in this state makes the whole run leave on `2`. |

`--check` ends with a ready-to-paste list of `cp` commands for the safe ones. **"Safe to take"
means you have not changed your copy, not that the incoming file is safe.** Most of what the
template owns lives under `.claude/`, which is what your harness reads to decide what code to run,
so read the diff before you paste anything and read [§5](#5-what-this-does-not-protect-against)
before you read the diff.

The safe-to-take list prints the SHA-256 of each file beside its path, and it is the digest this
run took out of the folder rather than the one that folder's manifest claims. The two agree by the
time anything is printed, because a folder that disagrees with its own manifest is refused whole.
What the digest is for is the gap the tool cannot close on its own. Between the moment those bytes
were read and the moment you paste the copy commands there is you, reading, and nothing re-reads
the folder across that gap. The plan says so in its own preamble, and the digest is what lets you
settle it in one command rather than trust it:

```bash
sha256sum ../template-new/.claude/hooks/vault-lint.sh
```

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
though it writes a single file, because a baseline you cannot then compare against is not worth
recording, and finding that out now is kinder than finding it out on the first `--status`.

Be clear about what it costs: **every template file you had already changed is recorded as though
the template shipped it that way**, so from then on it reads as untouched. There is no way around
that — the hashes were never written down, and no design recovers information that does not exist.
Adopt against the oldest release you might plausibly have started from, so the tool over-reports
what you changed rather than under-reporting it.

It does **not** copy that folder's manifest. It writes a new one out of the entries this run read
and accepted, after the path validation and after the narrowing. That distinction is worth the
sentence: the source manifest is excluded from every manifest by design, so it is the one file in
that folder no hash of the run ever reaches, and copying it would have made bytes nothing verified
into this vault's permanent record. If the source claimed one of your notes was template machinery
you will have seen a `NARROWED` warning, and what gets written down is the narrowed class, so the
claim does not survive into your baseline at all.

One consequence to expect. Every file the baseline names that your vault does not have reads as
deleted from the next `--status` onwards, and `VERSION` is normally one of them, because this
writes only the manifest and leaves writing a `VERSION` file to you. `--adopt` counts them and
says so before you see them reported.

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
  The folder names it protects are the ones this template ships **plus the ones your own
  `vault-check.sh` names on its `TIERS=` line**, which is where [`customizing.md`](customizing.md)
  sends you if you rename a tier. The two lists are unioned rather than swapped, so renaming
  nothing costs nothing and renaming something is covered under both names.
- **It carries a list of the places a template is allowed to ship machinery**, and forces anything
  else back to yours. That list is an *allowlist* — the folders and top-level files this template
  ships, plus five exact paths under content tiers — rather than a list of where your files live,
  because the second one is unbounded and the first is ours to state. The difference is not
  academic. Under the earlier shape, anything outside the content tiers was machinery by default,
  so a source manifest could name `.github/workflows/anything.yml`, have it printed under *safe to
  take*, and a paste would install a workflow that runs unattended on GitHub's runners with your
  repository's secrets. `.vscode/tasks.json` and `.devcontainer/devcontainer.json` are the same
  shape and both auto-execute. All of them are now narrowed and warned about instead.
  A release that adds a machinery folder an older copy of the script has never heard of is narrowed
  by that older copy rather than offered, which is the fail-closed direction, and you can still take
  it by hand.
- **It checks that the folder you pointed at holds what its own manifest says it holds**, and
  refuses the whole comparison when it does not. Without that, "safe to take" would be that copy's
  unverified claim about itself and the copy commands would move bytes nothing had looked at. It is
  a coherence check rather than a defence — somebody who can rewrite a file there can rewrite its
  manifest line too — and what it buys is that the manifest becomes the one artefact worth reading,
  and that a half-finished download is caught rather than presented as an update. An entry it
  cannot open is a refusal rather than a warning it carries on past, and an entry shipped as a
  **symbolic link is refused outright**, because every existence test here follows a link and the
  copy command you paste would move whatever the link points at rather than anything the source
  contained. Every component of the path is tested and not only the last one, because a link named
  `docs` walks every entry under it past a check that only ever asked about `docs/a.md`.
- **It refuses while a scheduled pass is running**, and refuses while a runner tripwire is set.
  The two maintainer modes in §7 take the same refusals, and are deliberately **not** exempt. Both
  ask git for the tracked file list, and a pass mid-commit is exactly the moment that list is a
  snapshot of something in motion, so rewriting or checking the provenance record there is what
  those two codes exist to prevent.

Four limits inside those guarantees, stated rather than left implied.

A file that is on disk and cannot be read is reported as **unreadable** and not as one you deleted,
because "the owner removed this" is a finding and "this could not be read" is a refusal to answer,
and those want different responses. Any file in that state also makes the whole run leave on `2`,
because the counts it printed then describe part of your vault rather than all of it.

`PATH-BLOCKED` tests the *text* of a path rather than resolving it, so a symlinked folder you
created yourself is followed — your own links are not the threat this guards against, but the
guard is about the shape of a path rather than about where it lands.

**Binary detection reads the start of a file, not all of it.** Generation refuses a tracked file
holding a NUL byte, and it asks that question with one `grep` for a whole batch, which stops at the
first matching line. A file whose opening is ordinary text and which turns binary tens of kilobytes
in is therefore hashed as text and not named. Counting every line instead would read the whole file
and was rejected, because BSD `grep` skips an ignored file rather than reporting a zero for it and
the answers could then no longer be matched to the files they belong to on macOS. Every file this
template ships is short text, so the limit costs nothing here.

**A file the template hands over from machinery to yours is still reported as machinery.** When a
path is in both manifests the class is taken from *your* record, which is what stops a source
widening `seed` into `owned` before the narrowing even runs. The same rule means a release that
reclassifies one of its own files the other way is reported and planned as `owned` until your
baseline is renewed. That is the safe direction of the same decision, and it is worth knowing so
the listing is not mistaken for the template disagreeing with itself.

What it does not do:

- Read the diff for you.
- Merge a file you have both changed.
- Reach a vault whose owner never runs anything.
- Tell you anything about a file that **neither** manifest names. Those are never read, never hashed
  and never listed. The one exception is a file the newer template has started shipping at a path
  you already occupy, which is named on purpose — that is the collision warning, and naming it is
  the whole point of it.
- Offer you machinery the template has started shipping somewhere your copy of this script does not
  yet know about. The list of those places is compiled into the script **you** are running, which is
  what stops a source widening it, and the price is that a genuinely new location is narrowed to
  *yours* and left out of the copy plan rather than offered. The `NARROWED` line names it, and you
  can still take the file by hand.

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
| `2` | It could **not** look, so it is saying nothing about the template. No manifest (`NO-MANIFEST`), no working hash tool (`HASH-UNAVAILABLE`), a hash tool named by `VAULT_HASH_TOOL` that is not one of the four (`HASH-TOOL-UNKNOWN`), an unreadable or non-template source (`NO-SOURCE`, `NOT-A-TEMPLATE`), a hash algorithm it does not know (`UNKNOWN-ALGORITHM`), a source older than this vault (`SOURCE-IS-OLDER`), a comparison of zero files on either side (`VACUOUS`, `SOURCE-VACUOUS`), a source that disagrees with its own manifest (`SOURCE-DISAGREES`), a source reaching an entry through a symbolic link at any point in its path or naming one it cannot open (`SOURCE-SYMLINK`, `SOURCE-UNREADABLE`), a file of your own this could not open (`UNREADABLE`), a rules file that is not readable or that holds no rules (`NO-RULES`), or two copies that both claim one version and differ (`SAME-VERSION-DISAGREES`). |
| `1` | This vault has a problem. The manifest cannot be parsed (`MANIFEST-MALFORMED`), `--verify-manifest` found it stale (`MANIFEST-STALE`), or the rules file cannot be used (`RULE-FIELDS`, `RULE-CLASS`, `RULE-DOUBLE-STAR`, `RULE-CHARACTER`). `--generate` also answers 1 when it refuses to write (`UNCLASSIFIED`, `BINARY`, `MISSING-TRACKED`, `UNWRITABLE-PATH`, `CASE-COLLISION`, `NO-VERSION`). |
| `11` | Refused because of the state of the vault rather than the command line. `--adopt` where a baseline already exists (`ALREADY-ADOPTED`). To adopt a different baseline on purpose, delete `.claude/template-manifest` and run it again. It is `11` rather than `3` because the retention runner already answers `3` for a partial pass, and the numbering [`reference.md` §10](reference.md#10-exit-codes-and-log-locations) publishes is one numbering across all four scripts, so that a caller reading a code does not have to know which of them it ran. |
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

Every refusal prints a tag as the first word after `vault-update:`. The table above names the ones
a vault owner meets, which is not all of them — the generation-time and diff-time tags are not
here, because they belong to the two maintainer modes in §7 and to a missing `diff`.
[`reference.md` §4.5](reference.md) lists every tag, and that is the one to grep against. Saying
this table was the complete list would send a reader who found something else to the conclusion
that the tool had printed something undocumented.

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
vault-update: 7 moved upstream, 2 also changed here, 5 safe to take, 1 already taken (recorded 1.0.0, source 1.1.0).
```

The fourth number counts files that moved upstream and that you already carry, because you took
them at some point. They are deliberately left out of the first number, because the exit code
hangs off that number and there is nothing to do about a file you already have. Without a number
of their own a run whose only finding was one of these printed three zeros directly above a
section listing files that had moved.

A file you took from upstream keeps reading as one you changed under `--status`, which has no
source to compare against and so cannot tell the two apart. `--check` against the copy you took it
from is what separates them, and `--status` says so in its own output.

---

## 7. For maintainers of the template itself

Two modes exist for the template repository and not for a vault.

```bash
VAULT_TEMPLATE_MAINTAINER=1 bash .claude/scripts/vault-update.sh --generate
VAULT_TEMPLATE_MAINTAINER=1 bash .claude/scripts/vault-update.sh --verify-manifest
```

**Both** need the variable, and `--verify-manifest` needs it even though it writes nothing. It
rebuilds the manifest from the whole tracked tree in order to have something to compare against,
so inside a vault it classifies, hashes and then prints the names of the owner's own notes, which
is the one boundary this tool is built around. It would also finish by printing the `--generate`
command, which is precisely the command the other variable exists to keep out of reach.

`--generate` rewrites the manifest from `.claude/manifest-rules` and the tracked tree. It needs
`VAULT_TEMPLATE_MAINTAINER=1` because running it inside a vault would take that vault's notes in as
template entries and restamp every hash from the current files, after which every file reads as
untouched and the record of what the user had changed is gone. That is the most destructive thing
the tool can do, and an environment variable is what stops it being reachable by curiosity.

`--verify-manifest` runs in CI and fails when the manifest has drifted from the tree. It catches a
maintainer who edited a file and forgot to regenerate, which is the mistake that actually happens.
It does **not** check that the classification is *right*, because both sides run the same rules, so a wrong
rule is perfectly self-consistent. A hand-maintained table in `run-tests.sh` names specific paths
and their expected class, and that is the control that can fail.

Adding a file to the template means adding a rule for it. There is no catch-all, so an
unclassified file fails generation and fails CI, naming the path.
