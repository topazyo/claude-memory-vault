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

## 1.4.0 — 2026-09-25

The retention pass now tells whoever ran it what it did. Its judgement used to go only to its log,
so cron, launchd and a person at a terminal saw nothing of it on standard output, and a run that
refused to start could not be told from one that found nothing to move or one that never ran. It
also stops describing a journal a person has marked as replaced as one that is still being argued
over, and stops reporting a `20-projects/_logs` folder it can enter but not list as an empty one.

### Changed

- **`vault-retention.sh` prints what it logged.** Every line a run logs goes to
  `.claude/logs/vault-retention.log` and to a copy kept for that run alone, and as the run ends it
  prints the copy on standard output as `vault-retention: <text>`, without the timestamp and with
  every byte outside printable ASCII spelled out. A run that ends with any code but 0 adds a closing
  `vault-retention: FAILED: …` line, apart from the few ends § 4.3.1 lists, so a refusal is never
  silent and a summary is never the last thing a failed run says. The printed lines come from the
  run's own copy, so another run's lines in the shared log, or the log being rewritten while the run
  goes on, never appear as this run's, as long as nothing else can write to the run's temporary
  folder. [`docs/reference.md` § 4.3.1](docs/reference.md) has the contract.
- **A `20-projects/_logs` folder the runner cannot list or enter is refused**, with an `ERROR:`
  line of its own and exit 1. One it could enter but not list used to read exactly like an empty
  folder: `evaluated 0 candidate(s)`, `OK: there is nothing in 20-projects/_logs to evaluate.` and
  exit 0. One it could not enter was refused with exit 6 and a `PATH-BLOCKED:` line that called it
  a link or not a folder.
- **One refusal reason became two.** A journal carrying `contradicts:` or `superseded_by:` was
  refused with *"contradicts or superseded_by is set, so it is still being argued over"*, which is
  false of a journal a person has marked as replaced. It now reads
  `contradicts: is set, so it is still being argued over` or
  `superseded_by: is set, so a human has recorded that something replaces it, and this pass does not
  decide what that means`, and a journal carrying both gets the `contradicts:` one. Which journals
  are refused has not changed.
- The header of `vault-retention.sh` and `docs/reference.md` § 4.3.1 list every exit code the
  runner can end with, including 127 from `vault-retention.cmd` and the signal codes.
- The runner copies standard output to the first descriptor from 9 down to 3 that nothing holds
  open, rather than always to 9, so a wrapper that keeps a `flock(1)` lock on 9 keeps it, unless
  every one of them is held. The printing at the end of a run can be stopped with TERM, so a reader
  that stops reading no longer keeps the run alive until KILL, and nothing the run started goes on
  printing after it. A TERM that lands while the run lets its lock go is kept until the lock is
  released rather than lost. A run lock, or a process id, that the caller's environment names is no
  longer touched by a run that never took it, and `RUN_NONCE`, `RUN_STALL_SECONDS` or
  `RUN_GAPS_FILE` in that environment no longer reaches the run's watchdog.
- The control suite holds each of these. It lands other runs' lines, a rewritten log and signals at
  chosen moments of a run by construction, and reads what the run printed. CI names the new
  controls, and the existing control for a candidate name holding a line break, as ones that must
  run, the unlistable-folder and stalled-reader controls on every job but Windows.
- `AGENTS.md`, `docs/reference.md`, `docs/setup.md` and `docs/concepts.md` describe the new output.

### Adopting this

Three things change what you see, and the first may change your mail.

**A crontab line for the retention pass without a redirect now mails you its judgement every
week**, on a machine where cron can send mail, and a run that could not start mails its reason.
That is intended. The mail carries note names, paths, refusal reasons, git's own error text, any
commit-message text git reports and the value of any setting the run warns about. If your cron mail leaves the machine and you would rather
it did not, end the line with `>/dev/null` and read the log instead.
[`docs/reference.md` § 4.3.1](docs/reference.md) says where else the output may go, and why never
into `.claude/logs/vault-retention.log` itself. launchd appends the same lines to
`vault-retention.launchd.out`. Task Scheduler discards them, so nothing changes there.

**Anything that searches the retention log for `contradicts or superseded_by is set` stops
matching.** Search for `contradicts: is set` or `superseded_by: is set` instead.

**A `20-projects/_logs` folder your account cannot list or enter now stops the run with exit 1.**
If a scheduled retention pass starts failing after you take this release, check that folder's
permissions: before, one it could enter but not list was never judged at all, only reported as
empty. One it could not enter already stopped the run, with exit 6, so anything that watches for
that code sees 1 there now.

If your vault has never run the retention pass, this is a good release to start with: run
`bash .claude/scripts/vault-retention.sh --dry-run` by hand and read what it prints before you
schedule it.

`--check` will list `.claude/scripts/vault-retention.sh`, `.claude/scripts/run-tests.sh`,
`AGENTS.md`, `docs/reference.md`, `docs/setup.md` and `docs/concepts.md` as safe to take, alongside
`VERSION` and `CHANGELOG.md`. If you changed `LOGS_REL` or `ARCH_REL` inside `vault-retention.sh`,
take it as a merge rather than a copy. No note, rule, hook, frontmatter key or checker behaviour a
vault relies on has moved.

---

## 1.3.1 — 2026-09-25

Of the files a vault is offered, this release changes only the control suite. Some of its run-lock
controls depended on how fast the machine running them was. On a slow Windows host the suite
failed two of them against a correct runner library, and skipped three others with a reason that
was not true.

### Changed

- **The control for a bad `RUN_LOCK_POLL` counts sleeps instead of timing the run.** It required
  the whole run to finish within 20 s, which no fixed limit can promise on every host: on a slow
  Windows host a run that the lock refuses with no wait at all takes about 30 s. The control now
  waits 25 s and records every sleep the runner takes. It fails when a sleep is longer than the
  whole wait or is not a whole number of seconds above zero, when the wait never slept at all, and
  when the replacement poll the log names is not longer than the wait, so an uncut sleep of the
  30 s replacement poll still fails it.
- **The control for a file named `run.lock` counts retries instead of timing them.** It required
  the lock to give up within 3 s, and loading the runner library and asking for the lock took 3–4 s
  on that host. It now requires the lock to give up without a single retry, after first showing
  that the count can see one.
- **The Windows process-id lock controls start their own lock holder.** They used to read the
  Windows process id of the holder started at the top of the run-lock section. That holder lives
  ten minutes, and on a slow host it can be gone by the time they run. They then skipped, reporting
  "not Git Bash on Windows" whatever the cause. They now start a holder of their own, and a skip
  names what was missing. The repository's CI now requires them on its Windows job, so a skip
  there fails the run. It could not do that before, because they never recorded that they had run.

### Adopting this

Nothing to do. Taking `.claude/scripts/run-tests.sh` is optional, and it changes nothing about how
your vault is written or checked. It stops the suite from failing two run-lock controls, and
skipping three others, on a slow Windows host. No runner, hook, rule, doc, note or frontmatter key
changed. `--check` will list `.claude/scripts/run-tests.sh` as safe to take, alongside `VERSION` and
`CHANGELOG.md`, which move on every release.

---

## 1.3.0 — 2026-09-23

The weekly promotion pass becomes create-only over the long tier. It may add notes to
`31-standards/` and `40-llm-wiki/wiki/` and never change one already there. Freshness stamps,
supersessions and corrections of existing notes now reach you as proposals in its promotion report.

### Changed

- **A promotion pass that changes a long-tier note that was there before it is refused and put
  back.** Until now the runner committed any change to an existing standard or wiki entity that
  passed vault-check, unattended and under a `Vault-Pass: promotion` trailer: a supersession, a
  `last_verified` stamp with no probe behind it, a gutted body, a claim reversed under untouched
  frontmatter. C1–C5 cannot see what a change means, so none of those was caught. A note counts as
  there when the commit HEAD pointed at before the pass holds it, or when it was on disk before the
  pass, a note git ignores included, unless it is an earlier promotion pass's own uncommitted note
  that this run adopted. A new name that differs from such a note only in ASCII case counts as that
  note, adopted or not, because on Windows and macOS it is one. Such a pass exits 2 with
  `VIOLATION: long-tier notes that were there before the pass started changed during it`, commits
  nothing, and puts back every note it changed except one that already had uncommitted changes,
  whether the agent succeeded, failed, timed out or gave no summary. When the commit from before
  the pass cannot be listed, the pass is refused under a line that says so. A note git ignores is
  in no commit, so it is refused but left as the pass wrote it, and the log says so. So a failing
  or timed-out pass that changed one, and wrote nowhere else, now exits 2 rather than with the
  agent's status, 124 or 125, and its notes are no longer left for the next run. A pass that also
  wrote outside its allowed folders, or changed a steering surface, is refused for that first and
  puts none of its notes back, as before, but its log now names each long-tier note that was there
  before the pass and changed during it, and names one someone was already editing as such. Such a
  note is left as it is and may hold your edit as well as the pass's, so the log asks for a look
  with `git diff` against the commit from before the pass, which it names, before any
  `git restore`. The check comes before vault-check, so a pass that also wrote an invalid note
  exits 2 rather than 5. The dream pass is unaffected.
- **The put-back no longer moves a note out of the vault when the pass wrote it under a name that
  differs only in case.** A writer that replaces files, as the agent's Write tool does, leaves the
  note under the new name on Windows, and the put-back could take that for a new note and move it
  to the quarantine, depending on which of the two names it reached first. The pass's bytes now go
  to the quarantine as a copy and the note is restored under its own name from the commit before
  the pass, whichever name comes first, unless no commit holds that name, someone was already
  editing it or it was committed while the pass ran, when it is left as it is, or the copy or the
  restore failed. The log says which, and what was done. On macOS a rename over such a name was measured to keep the old one, so the note is put
  back as any changed note is.
- **The promotion agent writes new notes only.** It never changes, retires or stamps an existing
  long-tier note, whoever wrote it. Its trust sweep proposes the stamps it would make. When a new
  note replaces an old one on evidence, it proposes retiring the old one; when two disagree and
  neither is established, it gives the new note a `contradicts:` edge and proposes the matching
  edge on the old one. The task text `promotion-pass.sh` gives it now asks for new notes only,
  with stamps, retirements and corrections as proposals.
- **An earlier pass's uncommitted edit of a committed long-tier note is put back before the next
  pass starts.** A pass that timed out or failed could leave such an edit for the next run to adopt
  and commit. The next run now logs it under `LEFTOVER-REJECTED` with a `create-only:` line, keeps
  a copy in the state directory's quarantine, in a folder ending in `-leftover`, and restores the
  note before its agent starts, so it cannot take that run's own notes down with it.

### Adopting this

Take the changed owned files: `.claude/scripts/lib/runner-common.sh`,
`.claude/scripts/promotion-pass.sh`, `.claude/agents/promotion-agent.md`,
`.claude/scripts/run-tests.sh`, `AGENTS.md`, `docs/reference.md`, `docs/setup.md`,
`docs/customizing.md` and `docs/concepts.md`, besides `VERSION` and `CHANGELOG.md`, which move on
every release. Then:

- **If you renamed `31-standards/` or `40-llm-wiki/wiki/`, change where the new code names them**
  after you take it: in `.claude/scripts/lib/runner-common.sh`, the `case` pattern and the
  `git ls-tree` paths in `long_tier_existing` and the `case` pattern in `check_leftovers`; in
  `promotion-pass.sh`, the grep that lists the long-tier notes a contained pass changed. Without
  the first two the create-only check matches none of your notes and lets every change through,
  with exit 0 and nothing logged, and without the last a contained pass names none of the notes
  it left.
- **If you customized `promotion-agent.md`, drop every instruction to stamp, supersede or edit an
  existing note** when you merge the new one. An agent still told to do any of those makes each
  such pass exit 2 and lose that week's notes.
- **Stamps and retirements now arrive as proposals** in `20-projects/_logs/promotion-*.md`.
  Applying one is yours: edit the note and commit it.
- **Read the log of your first run on this version.** If a pass on an earlier version left an
  uncommitted edit of an existing standard or wiki entity, that run puts it back and logs
  `LEFTOVER-REJECTED`. The edit is in the state directory's quarantine, in a folder ending in
  `-leftover`. Apply it by hand if you want it.
- **Avoid editing an existing long-tier note while a promotion pass runs.** The runner cannot tell
  your edit from the pass's, so it refuses the pass and restores a committed note, and your edit is
  in the quarantine copy the log names, unless the log says the note was committed during the pass
  or changed after it ended, or the pass also wrote outside its folders or changed a steering
  surface, when it was left as it is. Read such a note with `git diff` before you restore it,
  because `git restore` discards your edit too. Diff against the commit from before the pass when
  a sync client may have committed since; the exits that put none of the pass's notes back name
  that commit.
- **Pause any auto-commit, such as obsidian-git's, around the scheduled pass.** A sync client that
  commits during the pass can commit the pass's change to an existing note before the runner looks.
  The runner then refuses the pass and logs the note as committed while the pass ran, but it cannot
  undo someone else's commit, so read that commit with `git show` and revert it yourself if the
  change is the pass's.
- Create-only needs the vault to be its own git repository, as the commit and the put-back already
  did. In any other vault the runner checks nothing of this.

`README.md` changed too, and it is seed, so your copy stays as you wrote it.

## 1.2.0 — 2026-09-22

A release about the release check, which 1.1.0 introduced and which review rounds then read.
Everything here comes out of what those rounds recorded and deliberately left, and the first two
items are the ones that let the check answer green when it had not compared what it claimed to.

### Fixed

- **A commit that changes only how a path is classified is no longer invisible to the release
  check.** Which files this template ships is itself something it ships, and the check only ever
  compared their content. A path's class lives in `.claude/template-manifest`, and neither that
  file nor the `.claude/manifest-rules` it is generated from is itself shipped, so moving a path
  between `owned`, `seed` and `excluded` changed what every vault is told this template ships
  while the only two files whose bytes moved were the two the comparison filters out. The check
  printed that nothing was owed, on exit 0. It now compares the classes as well and refuses with
  `SHIPPED-RECLASSIFIED`. The direction that matters most is a path leaving the shipped set,
  because once the next release is cut for any reason the new tag does not name it either, and
  every later change to it is filtered out of every comparison from then on.
- **A shipped path that git does not recognise is refused even when its neighbours are fine.** The
  guard for two sides that spell paths differently fired only when a whole side matched nothing,
  and one unrecognised path among all the rest leaves that far from nothing. Measured on a five-file
  fixture whose manifests spell one path with a different case from git's index, which is the state
  a repository generated on a case-insensitive filesystem is in: that file's content changed, both
  sides recognised four of five, the guard stayed silent and the run reported that nothing was
  owed. Each side is now held against the files git tracked when that side was generated, and every
  path on it has to be recognised. Holding the tag's manifest against what git tracks *now* was
  what made the loose test necessary, because a shipped file deleted since the tag is legitimately
  absent from that list. A path this tree's manifest names and git no longer tracks is still not
  refused when the tag *did* track it, because that is a deletion or a rename with the manifest
  left unregenerated — a finding the ordinary comparison was going to make correctly, and refusing
  it would replace an answer with "the check could not run".

### Changed

- **`VERSION-SPELLING` and `TAG-FAILED` leave on 2 rather than 1.** Exit 2 in that script means the
  check could not run and is saying nothing about the release, and both of these are that. A
  `VERSION` holding something that is not a version ended its own message with "nothing could be
  compared against it" while leaving by the door that says a release is owed, and its sibling for
  an absent `VERSION` had always been a 2. A `git tag` the tool refused to write is the tool
  failing. No vault reads either code, because that script is classed `excluded` and is never
  copied into one. The reader that does is this project's own CI step, which gives a 1 and a 2
  different annotations, so both of these now say the check could not answer rather than that a
  release is owed — which is the point of the change.
- The control suite gains controls for the two refusals above, for the emptiness assertion on the
  release check's scratch directory, for a tag git will not write, and for both sides of the
  spelling guard. All of those are about the template's own release check and skip in a vault,
  which has no releases to cut.
- `AGENTS.md` says that changing **which** files the template ships owes a release too. The rule
  there read "every merge that changes a shipped file", and a commit that only reclassifies a path
  changes nothing shipped while changing exactly what a release exists to announce, so an agent
  following the rule as written would have believed it had complied.
- `CONTRIBUTING.md` carries the same correction in the two places that tell a contributor what to
  do rather than merely stating the policy, records the two exit codes that moved, and says which
  direction of a reclassification reaches a vault immediately and which waits for their baseline to
  be renewed.
- **The suite's own test for whether an update was offered means what its name says.** It matched
  the counts line as well as the copy plan's heading, and "0 safe to take," contains the counts
  line's spelling, so a `--check` that ran honestly and had nothing to copy read as one that had
  offered something. Every use of it is a negative, and a negative assertion only gets weaker when
  its predicate matches less, so nothing in the suite could have caught it. It now matches the copy
  plan's heading alone, and a control holds both directions.

### Adopting this

Nothing to do, and here is what you will nevertheless be offered so that you can tell an omission
from a deliberate silence.

`--check` will list `.claude/scripts/run-tests.sh` and `AGENTS.md` as safe to take, alongside
`VERSION` and `CHANGELOG.md`, which move on every release. Taking them is optional and changes
nothing about how your vault is written or checked. The suite's new controls are about the template
project's own release check and every one of them skips in a vault, which has no releases to cut.
The `AGENTS.md` change is one sentence in the rule a contributor follows, and that sentence says in
as many words that it asks nothing of you in your own vault.

No note, rule, hook, frontmatter key or checker behaviour a vault relies on has moved.

---

## 1.1.0 — 2026-09-22

Mostly a release about releases. 1.0.0 shipped a mechanism that tells a vault what moved upstream
and relies on a release being cut whenever something does, and nothing enforced that. 1.0.0 was
itself merged first and tagged afterwards by hand.

### Added

- `.github/release-check.sh`, which is what now enforces the rule the paragraph above says nothing
  enforced. It refuses a default branch whose `VERSION` names no tag, and a tree whose shipped
  files differ from the tag `VERSION` does name, so that every merge changing a shipped file is a
  release. It belongs to the template project rather than to a vault and is never copied into one,
  because a vault has no releases to cut, and `run-tests.sh` gains ten controls holding it.
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

**Take `.claude/scripts/vault-update.sh` first and on its own, then run `--check` again.** The
digest column and the stricter symlink test are both inside that file, so the run that offers you
this release is your old copy and cannot use either of them. The second run can. This is worth the
extra pass because both of this release's safeguards protect the copying, and the copy that brings
them in is the one they cannot cover.

Once that second run is the one you are reading, check the digests in its safe-to-take list against
the folder you are about to copy out of. That is what they are for.

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
