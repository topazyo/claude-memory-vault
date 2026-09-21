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
what you have to do by hand. That note is the only thing that can carry a change in *meaning* —
a tool can tell you `vault-check.sh` changed, but only prose can tell you that your customized
`TIERS=` line now needs a seventh entry. Apply the notes in release order, oldest first.

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
vault-update: this vault records template version 1.0.0.
vault-update: 69 of 72 template file(s) match that record, 2 changed here, 1 deleted.
```

Those counts are whatever your vault has. Read the numbers rather than matching the wording around
them, which is the same habit `vault-check.sh`'s own summary line asks for.

**Read that as a record, not as a verdict on the template.** The manifest says what the template
shipped at 1.0.0. It says nothing about what the template holds today, and a hash edited to make
this report go quiet would clear the alarm without establishing anything — the same unearned
freshness stamp this vault's own rules warn about for `last_verified`.

Files you have changed are expected. [`customizing.md`](customizing.md) invites most of them.

---

## 3. Seeing what moved

You fetch the new template yourself. That is the security boundary, and it is deliberate.

```bash
git clone https://github.com/<owner>/claude-memory-vault.git /tmp/template-new
# or download the release zip from GitHub and unpack it somewhere
bash .claude/scripts/vault-update.sh --check --from /tmp/template-new
```

`--check` compares three things: what the template shipped at your version, what is on your disk
now, and what the newer copy ships. That gives four answers that matter.

| Bucket | Meaning |
| --- | --- |
| **Safe to take** | It moved upstream and you never touched your copy, so copying loses nothing. |
| **Moved upstream and changed here** | Both sides moved. Nothing will overwrite it. Read it with `--diff` and merge it yourself. |
| **No longer shipped** | The template retired it. Your copy is left exactly where it is, because nothing here deletes. |
| **Shipped once and yours now** | Example notes, scaffolds, Obsidian settings. Reported as a count, because every vault drifts here and listing it every time would teach you to stop reading. |

`--check` ends with a ready-to-paste list of `cp` commands for the safe ones. Read the diff before
you run them.

```bash
bash .claude/scripts/vault-update.sh --diff --from /tmp/template-new
```

### If your vault predates all of this

It has no manifest, so there is no baseline to compare against and `--status` says so rather than
guessing. Record one, once:

```bash
bash .claude/scripts/vault-update.sh --adopt --from /tmp/template-new
```

It writes `.claude/template-manifest` and touches nothing else. Be clear about what it costs:
**every template file you had already changed is recorded as though the template shipped it that
way**, so from then on it reads as untouched. There is no way around that — the hashes were never
written down, and no design recovers information that does not exist. Adopt against the oldest
release you might plausibly have started from, so the damage runs in the safe direction.

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
`.claude/agents/dream-agent.md`: adding `Bash` to its `tools:` line turns one file you copied into
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
- **It never treats anything under your note folders as the template's**, whatever a manifest says.
  A hostile copy that reclassifies one of your standards as template machinery is refused rather
  than obeyed, because that refusal lives in the running script and not in the data.
- **It refuses while a scheduled pass is running**, and refuses entirely while a runner tripwire is
  set.

What it does not do:

- Read the diff for you.
- Merge a file you have both changed.
- Reach a vault whose owner never runs anything.
- Tell you anything about a file that is not the template's. Your notes are not read, not hashed
  and not named.

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
| `2` | It could **not** look, so it is saying nothing about the template. No manifest, no working hash tool, an unreadable source, or a comparison of zero files. |
| `1` | This vault has a problem. The manifest disagrees with itself, or `--verify-manifest` found it stale. |
| `6` | A manifest entry named a path outside the vault. |
| `64` | The command line was wrong. |
| `75` | A scheduled pass is in flight, so nothing was done. |
| `78` | A runner tripwire is set, so nothing was done. |

`10` rather than `1` for "there is something to adopt", on purpose.
[`reference.md` §10](reference.md#10-exit-codes-and-log-locations) records that `1` means *the
vault has a problem* everywhere else here, and an available release is not a problem with your
vault. Folding it into `0` instead would leave "up to date" and "an update exists" sharing one
answer, and those are two different answers.

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
