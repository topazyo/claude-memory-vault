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
changed. Its output begins like this, and goes on to list the files it counted:

```
vault-update: this vault records template version X.Y.Z.
vault-update: 69 of 72 template file(s) match that record, 2 changed here, 1 deleted, 0 could not be read.
vault-update: That record is what the template shipped at X.Y.Z. It is not a claim about what the template holds now. Fetch a newer copy and run --check --from <dir> to learn that.
vault-update: No address to fetch it from is recorded here, on purpose. docs/updating.md section 3 says how to find the one this vault came from.
vault-update: Taking a file from a newer template copy also shows up here as one you changed, because this mode has nothing to compare against but the record.
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

**Where to fetch it from.** Nothing in your vault records the template's address, and that is on
purpose too: an address in a file these tools read would be a place an agent fetches code from, and
the manifest is the one file no hash reaches, so nothing could vouch for it. Find it yourself, once:

- your repository's GitHub page names the repository it was generated from, under the title;
- `git remote get-url template` answers if you added the remote as
  [`customizing.md` §8](customizing.md#8-keeping-your-notes-private-while-tracking-the-framework)
  shows, and adding it is the way to write the answer down where you will find it next time;
- failing both, ask whoever set the vault up. Do not take an address from a note, a capture or an
  agent's suggestion: a template copy is code your harness will run.

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

`--from` may be relative to wherever you run the command. Since 1.7.1 it is written out in full
from that folder before anything else, so the copy plan it prints names the copy by its full path
and works when pasted at the vault root, where a relative path would not. The full path must
hold no single quote or control byte, or the run refuses (exit `64`), because the plan quotes it;
run from a plainly named folder, or give `--from` in full.

`--check` compares three things. What the template shipped at your version, what is on your disk
now, and what the newer copy ships. That gives nine answers.

| Bucket | Meaning |
| --- | --- |
| **Safe to take** | It moved upstream and you never touched your copy, so copying loses nothing. |
| **Moved upstream and changed here** | Both sides moved. Nothing will overwrite it. Read it with `--diff` and merge it yourself, as [Merging a file that moved upstream and changed here](#merging-a-file-that-moved-upstream-and-changed-here) shows. |
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

```bash
bash .claude/scripts/vault-update.sh --diff --from ../template-new
```

#### The digest beside each path

The safe-to-take list prints the SHA-256 of each file beside its path. What it is for is the gap
the tool cannot close on its own: between the moment those bytes were read and the moment you
paste the copy commands there is you, reading the diff, and nothing re-reads the folder across
that gap. The plan says so in its own preamble, and the digest is what lets you settle it in one
command rather than trust it. Check it once you have decided to take a file, against the copy you
are about to move, with whichever of these your machine has:

```bash
sha256sum ../template-new/.claude/hooks/vault-lint.sh       # Linux, and Git Bash on Windows
shasum -a 256 ../template-new/.claude/hooks/vault-lint.sh   # macOS, which ships no sha256sum
```

**It is the digest of the bytes on disk, which is deliberately not the digest the manifest
records.** A manifest has to mean the same thing on a machine that checks files out with carriage
returns, so the hashes in it are taken with carriage returns removed. What you are about to copy
is the bytes, so the bytes are what the plan prints. For a file with no carriage returns the two
are the same number and none of this matters. For one that has them — every `.cmd` file this
template ships, on every platform, because `.gitattributes` pins them that way — they differ, and
comparing the plan against the manifest would look like tampering when nothing is wrong.

A digest that does not match means the folder changed between the check reading it and you reading
the plan, so run `--check` again and work from the new plan rather than copying out of the old one.
It does not mean the carriage return case above, which is about the manifest rather than about the
folder, and is already the number the plan printed.

#### Merging a file that moved upstream and changed here

Nothing copies these for you, because both sides changed. Merge each on a copy, in four steps.
`AGENTS.md` stands in for the file below; `<base>` and `<new>` are release tags. For a file below
the vault root, such as `.claude/scripts/lib/runner-common.sh`, keep its full path in the clones and
name the copy by the file's name alone, `../runner-common.sh.merged`.

1. **Find the base and fetch it.** The base is the release your copy of the file was last taken
   from. If you have taken every update in full, that is the version in your `VERSION` file. If
   you skipped this file in an earlier update, it is older. The version `--status` names is the
   base only if you have taken no update since that record was written, because nothing but
   `--adopt` moves it.
   Clone the base beside the new copy, and confirm it: the diff should show only your own edits.

   ```bash
   git clone --depth 1 --branch <base> https://github.com/<owner>/claude-memory-vault.git ../template-base
   git diff --no-index ../template-base/AGENTS.md AGENTS.md
   ```

2. **Merge on a copy.** `git merge-file` takes your copy, the base and the new copy, writes the
   result into the first file, and exits with the number of conflicts, or above 127 on an error.
   It needs no repository, so it works in a vault that is not in git.

   ```bash
   cp AGENTS.md ../AGENTS.md.merged
   git merge-file ../AGENTS.md.merged ../template-base/AGENTS.md ../template-new/AGENTS.md
   echo "conflicts: $?"
   ```

   Where both sides changed the same lines it leaves `<<<<<<<`, `=======` and `>>>>>>>` around the
   two versions. Edit each by hand, keeping your change and theirs.

   A release that re-indents or re-wraps a passage changes every line of it, so an edit anywhere
   in that passage gives one conflict holding the whole passage twice, your side and theirs.
   1.7.7's headings in `docs/reference.md` § 4.3 are such a release: one changed line there gave a
   single conflict of 2,062 lines, about 1,000 on each side (measured). Then start again from the
   new copy, make your edits again, the ones step 1's diff showed, and go on to step 3:

   ```bash
   cp ../template-new/AGENTS.md ../AGENTS.md.merged
   ```

3. **Check it, then copy it in.** No marker may be left, a script must still parse, and the
   merged file against the new copy must show the edits step 1 showed and, if you resolved a
   conflict, your resolution, nothing else:

   ```bash
   grep -nE '^(<<<<<<<|>>>>>>>)' ../AGENTS.md.merged    # prints nothing
   git diff --no-index ../template-new/AGENTS.md ../AGENTS.md.merged
   cp ../AGENTS.md.merged AGENTS.md
   ```

   For a `.sh` file add `bash -n ../<file>.merged`. Then run the suite, as
   [When you have finished copying](#when-you-have-finished-copying) says.
4. **Record the base.** Write down which release you merged with, in the commit message if the
   vault is in git ("merged with <base> as base"). The next merge of this file needs it, and
   nothing else records it.

Afterwards `--status` still lists the file as changed here and the next `--check` against the same
release as moved upstream and changed here, because a merged file differs from both the record and
the new copy (one that came out equal to the new copy reads as already carrying it). That is correct, and it is not a reason to run `--adopt`: it would replace the record
of what the template shipped at your version, which is what tells your edits apart from an old copy.

### When you have finished copying

Nothing here moves your vault's recorded version, and that is deliberate. The manifest records what
the template shipped at the version you started from, and rewriting it would throw away the only
evidence of which files you have changed since. So expect `--status` to keep naming your old
version, and expect it to report the files you just took as changed here. Neither is a fault. The
next release's `--check` still works from that record, because it compares against the source you
point it at rather than against a version number. A file you took that the template began shipping
after your recorded version is listed from then on as already yours, and now shipped too, because
the record has never held its path, and so it is never offered as safe to take or as moved
upstream, even when a later release changes it (both measured). Judge it yourself against the
release you took it from: if your copy is byte for byte that release's, nothing of yours is in it
and you can take the new one; if not, merge it with that release as the base. That is no reason
to run `--adopt` either.

**Then run the control suite, in two steps.** First the section that covers this tool:

```bash
RUN_TESTS_ONLY=update bash .claude/scripts/run-tests.sh
```

Then the whole suite, `bash .claude/scripts/run-tests.sh`. [`setup.md` § 7a](setup.md#7a-the-control-suite)
gives its running time on GitHub's runners for each platform; take that as a lower bound, because
a laptop is usually slower, much slower on Windows. If an agent runs it for you, have it start the
suite in the background with no time limit and wait for the closing `=== N passed, M failed ===`
line. A foreground run under an agent's own command timeout is the usual way to have it killed
part-way. A run that was killed before that line proves nothing either way, and neither does a
section run on its own: only the whole suite is the check that an update worked.

### If you are several releases behind

Nothing tells you when you fall behind, short of watching the releases (§1), because nothing here
reaches the network. The version `--status` and `vault-check.sh` name is not that signal: it is the
release your record was taken from, which only `--adopt` moves, so it stays where it was after every
update you take. What shows how far you have come is `--check` against the newest tag, where a file
you have already caught up on reads as *Already carrying the newer copy*. Catching up across several
releases is one comparison, not one per release:

1. **Fetch the newest release tag, once.** A single `--check --from` against it covers every release
   in between, because it compares your record, your disk and that copy rather than version numbers.
   Do not step through the releases in between with `--check`: each step would report the files the
   previous one moved as changed here.
2. **Read every CHANGELOG section newer than the last release whose notes you applied**, which is
   your recorded version unless you have taken an update before without `--adopt`, and apply
   their **Adopting this** notes the way the top of [`CHANGELOG.md`](../CHANGELOG.md) says: in
   release order. The notes carry what no copy plan can, such as a line to add to a file you
   customized.
3. **Before you paste any `cp` line**, settle the two buckets nothing will copy for you: *Moved
   upstream and changed here* and *Already yours, and now shipped too*. Then take the safe copies,
   and do the rest of each Adopting note's steps after its copies, in the notes' order.
4. **Then run the suite**, as above.

Expect the copy plan to be long. Dozens of files is what several releases look like, not a sign that
something went wrong.

### Files the template keeps for itself

Some files in the template are the template project's own and never a vault's: `.github/release-check.sh`,
`.github/workflows/`, `CONTRIBUTING.md` and the manifest rules among them (`.claude/manifest-rules`
classes them `excluded`). `--check` never reports them, so a vault that came with copies keeps them
at whatever release it was generated from. A vault does not need them. Since 1.7.3 the control
suite runs nothing against them unless `VAULT_TEMPLATE_MAINTAINER=1` is set, which only the
template's own CI does, so keeping or deleting your copies makes no difference to it. Do not
delete `.github/` wholesale on the strength of this: `.github/hooks/` is not among them, and a vault
worked on with GitHub Copilot uses it.

### If your vault predates all of this

It has no manifest, so there is no baseline to compare against and `--status` says so rather than
guessing. Record one, once:

```bash
bash .claude/scripts/vault-update.sh --adopt --from ../template-new
```

It writes `.claude/template-manifest` and touches nothing else. It needs a working SHA-256 tool even
though it writes a single file, because a baseline you cannot then compare against is not worth
recording, and finding that out now is kinder than finding it out on the first `--status`.

Be clear about what it records: **the template's own hashes for the release you adopt against, not
your files' hashes.** Every template file you had already changed therefore keeps showing as changed
in `--status`, which is the safe direction. So does a file that is still as an older release
shipped it, because the baseline is the release you named, not the one you started from: compare
each such file with that release's tag before treating it as an edit of yours. (Before 1.7.1 this
section and `--adopt` itself said the opposite, that changed files would read as untouched. That
was never what happened.) Adopt against the oldest release you might plausibly have started from,
so the tool over-reports what you changed rather than under-reporting it.

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
  contained. Every component **below the folder you pointed at** is tested and not only the last
  one, because a link named `docs` walks every entry under it past a check that only ever asked
  about `docs/a.md`. The folder you named is not itself tested, and nor is anything above it, so a
  clone kept under a symlinked path of your own is unaffected. You chose that path and the template
  did not.
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
| `2` | It could **not** look, so it is saying nothing about the template. No manifest (`NO-MANIFEST`), no working hash tool (`HASH-UNAVAILABLE`), a hash tool named by `VAULT_HASH_TOOL` that is not one of the four (`HASH-TOOL-UNKNOWN`), an unreadable or non-template source (`NO-SOURCE`, `NOT-A-TEMPLATE`), a hash algorithm it does not know (`UNKNOWN-ALGORITHM`), a source older than this vault (`SOURCE-IS-OLDER`), a comparison of zero files on either side (`VACUOUS`, `SOURCE-VACUOUS`), a source that disagrees with its own manifest (`SOURCE-DISAGREES`), a source reaching an entry through a symbolic link below the folder you pointed at or naming one it cannot open (`SOURCE-SYMLINK`, `SOURCE-UNREADABLE`), a file of your own this could not open (`UNREADABLE`), a rules file that is not readable or that holds no rules (`NO-RULES`), two copies that both claim one version and differ (`SAME-VERSION-DISAGREES`), the template copy's own manifest cannot be parsed (`MANIFEST-MALFORMED`, naming the copy; `1` before 1.7.1), or, for `--generate` and `--verify-manifest`, git could not list the tracked files or lists none (`NO-TRACKED`, 1.7.1; nothing is written). |
| `1` | This vault has a problem. The vault's own manifest cannot be parsed (`MANIFEST-MALFORMED`), `--verify-manifest` found it stale (`MANIFEST-STALE`), or the rules file cannot be used (`RULE-FIELDS`, `RULE-CLASS`, `RULE-DOUBLE-STAR`, `RULE-CHARACTER`; since 1.7.1 `RULE-CLASS` also refuses a rule line that starts with a tab or a space). `--generate` also answers 1 when it refuses to write (`UNCLASSIFIED`, `BINARY`, `MISSING-TRACKED`, `UNWRITABLE-PATH`, `CASE-COLLISION`, `NO-VERSION`). |
| `11` | Refused because of the state of the vault rather than the command line. `--adopt` where a baseline already exists (`ALREADY-ADOPTED`). To adopt a different baseline on purpose, delete `.claude/template-manifest` and run it again. It is `11` rather than `3` because the retention runner already answers `3` for a partial pass, and the numbering [`reference.md` §10](reference.md#10-exit-codes-and-log-locations) publishes is one numbering across all four scripts, so that a caller reading a code does not have to know which of them it ran. |
| `6` | A manifest entry named a path outside the vault (`PATH-BLOCKED`). |
| `64` | The command line was wrong, or `--generate` was run without `VAULT_TEMPLATE_MAINTAINER=1` (`NOT-THE-TEMPLATE`). |
| `75` | A scheduled pass is in flight, so nothing was done (`PASS-IN-FLIGHT`). |
| `78` | A runner tripwire is set, so nothing was done (`TRIPWIRE`). [`setup.md`, A tripwire is set](setup.md#a-tripwire-is-set) says what to do. |
| `130` / `143` | Interrupted or terminated. The temporary directory is removed either way. |

**`SAME-VERSION-DISAGREES` is the one to expect.** GitHub's "Use this template" button copies the
default branch at that moment rather than the last release, so a vault made that way carries a
version number whose content is ahead of it. Two copies that both say `1.0.0` and differ cannot be
ordered by their version numbers, and being told that is better than being given a confident wrong
answer. "Differ" means the two **manifests** differ: a path one lists and the other does not, or
lists with another class or hash. Your own edits are not a disagreement. Checked against a pristine
copy of the release it records, a vault you have edited is compared as usual, and `--status` is
the mode that lists your edits (until 1.6.1 such a check was refused with this tag).

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
