# Concepts

Why this vault is shaped the way it is.

This document is the reasoning behind the layout. It explains what each tier is for, what it
costs to move a fact upward, and why several tempting conveniences (auto-resolving
contradictions, auto-repairing notes, letting an unattended agent edit your knowledge) are
deliberately absent.

For why this exists at all, instead of adopting one of the many existing agent-memory systems,
see [`why.md`](why.md).

---

## 1. The problem this solves

A coding assistant forgets. Not gradually, but completely and on a schedule: the context window
fills, the session ends, and whatever was understood at 16:00 is gone at 09:00 the next morning.
The model does not know that you already tried the obvious fix, that the obvious fix silently
does nothing on Windows, or that you discovered this at some cost three weeks ago.

The default remedy is a project instructions file that grows. Every lesson gets appended, the
file gets longer, and eventually it is a wall of imperatives that nobody re-reads. That failure
is worth naming precisely, because the shape of the fix follows from it:

- **It is unreviewable.** Once the file passes a few hundred lines, no reviewer can hold it in
  mind well enough to notice that line 210 contradicts line 74.
- **It has no provenance.** A line says "always pass `--strict`". Who established that? Against
  which version? Was it measured, or did somebody guess once and the guess calcified?
- **It has no expiry.** A claim about a tool's behaviour is true for the version that was
  current when it was written. Nothing in the file says when it was last checked, so a stale
  claim and a fresh claim look identical.
- **It cannot record a refutation.** When you learn that a rule was wrong, the only available
  move is to delete the line. The file then asserts the new belief with exactly the same
  confidence as it asserted the old one, and the fact that you ever believed otherwise, along
  with the reason you changed your mind, is unrecoverable.

That last point motivates most of this design. A memory store whose value is supposed to be
auditable provenance cannot answer "what did we believe last quarter, and why did we change our
minds" if its only edit operation is deletion.

So: markdown files, in tiers, with frontmatter that carries provenance and dates, in a directory
you can read with your eyes, diff in git, and browse in Obsidian. Nothing here is clever. The
work is in the discipline, and the tooling exists to make lapses in that discipline visible.

---

## 2. The tier model

Three tiers, and knowledge moves up through them.

| Tier | Lives in | Typical volume | Lifetime | Verification cost |
|---|---|---|---|---|
| short | `10-daily/`, `01-inbox/` | several notes a day | days | none: capture is not a claim |
| medium | `20-projects/_logs/` | one note per project per session or week | weeks to months | light: "this is what happened" |
| long | `31-standards/`, `40-llm-wiki/wiki/` | a handful per month, at most | years | high: must cite what established it |

The obvious reading is that the tiers differ in **age**. They do not, or not primarily. A note
does not become a standard by getting old; plenty of daily notes are worthless the moment they
are written and stay worthless forever.

The tiers differ in **verification cost**, and everything else follows from that.

**Short tier is cheap and disposable.** `10-daily/` is a scratchpad: what you are working on,
what you tried, the error text you pasted, half a thought you do not want to lose. `01-inbox/`
is raw capture, including material from outside sources. Nothing here is asserted to be true.
Nothing here steers a future session. You are allowed to be wrong, sloppy, and duplicative,
because the cost of a wrong short-tier note is that you read a wrong note once and discard it.

Because `01-inbox/` and `40-llm-wiki/raw/` hold content you did not write, they are also a trust
boundary. Instructions found inside a captured note are data, not commands. The path-scoped rule
in `.claude/rules/untrusted-captures.md` states this, and the lint hook scans for zero-width and
bidirectional-override codepoints, the mechanism behind the "rules file backdoor" class of
attack, where invisible characters hide instructions inside text that looks innocuous to a human
reader. Note the limit, though: the hook fires only on writes by a harness that runs it (Claude
Code, out of the box), so a file pasted into
Obsidian by hand, dropped into `01-inbox/` by a file manager, or downloaded there is not scanned
until something inside the tool edits it. The durable boundary is the rule itself, and the scan is
a backstop, not a gate.

**Medium tier is a record, not a ruling.** A project log in `20-projects/_logs/` says what
happened in a session: decisions taken, things that broke, what you would do differently. Its
verification bar is only "this is an accurate account of the session". It does not have to be
general, and it does not have to be right about the world; it has to be right about the day.

Each log carries a `Promotion candidates (for long-term)` section. That section is the point of
the tier, the queue of things that looked, at the time, like they might matter
beyond this project. Writing a line there costs nothing and commits to nothing.

**Long tier is expensive and must be earned.** `31-standards/` holds durable standards, the
notes that steer future sessions, because these are the ones you load into context on
purpose. `40-llm-wiki/wiki/` holds concept entities, the same bar applied to ideas rather than
rules.

By convention every long-tier note carries `confidence`, `last_reviewed`, `last_verified`, and a
`Sources / Verification` section. Those fields exist so that a reader six months later can
reconstruct why the note says what it says without asking you. "Convention" is precise here: of
those, nothing is machine-checked except the internal consistency of the dates (section 8).
Nobody will stop you promoting a note without them.

The long tier must stay small. A standards folder with four hundred notes in it has recreated
the unreviewable instructions file, only with more ceremony. If everything is promoted, nothing
is.

---

## 3. The promotion bar

Promote a lesson when it is **general** *and* **verified**.

**General** means it will recur outside the situation that produced it. The test is a
counterfactual: if the project that taught you this were cancelled tomorrow, would the lesson
still be worth knowing? "The deploy script needs `--region` on this repo" is configuration, not
knowledge. "A command that exits 0 can still have skipped its work, so check the artifact rather
than the exit code" is a rule that will find you again, in a different tool, next year.

**Verified** means you can point at what established it: a log line, a command output, a linked
upstream issue, a reproduction you ran. Not "I remember it being like this."

Both conditions, not either. The common failure is promoting a **vivid one-off**: the bug that
cost you a whole afternoon, that you are still annoyed about, and that therefore feels
important. Salience is not generality. An afternoon of pain proves the incident was expensive;
it says nothing about whether it will happen again. Vivid one-offs belong in the medium-tier
log, where they are preserved and dated and findable, and where they will not be loaded into
every future session as though they were a rule.

The inverse failure is quieter and worse: refusing to promote a small, boring, correct
observation because it does not feel like a big enough deal. Most of what saves you later is
boring.

A useful heuristic: if you cannot write the `Sources / Verification` section without vagueness,
the note is not ready. Leave it in the medium tier and let the next occurrence either confirm it
or quietly drop it.

---

## 4. Lifecycle of a fact

Below, one entirely fictional fact walks the whole path. The project is called **harbormaster**,
a made-up deployment CLI. Frontmatter is abbreviated to the fields that matter at each stage.

### Stage 1: captured (short tier, `10-daily/`)

You notice something odd and write it down without analysis. The file is `10-daily/2031-03-04.md`;
the timestamped string is its `title:`, and Obsidian resolves wikilinks by **filename**, so other
notes link to it as `[[2031-03-04]]`.

```yaml
---
title: "2031-03-04 – 14:20"
tier: short
tags: [tier/short]
status: active
type: daily
project: "harbormaster"
created: "2031-03-04"
last_reviewed: "2031-03-04"
---
```

```markdown
# Scratch

- `hm deploy --dry-run` printed "deploy plan OK" and exited 0, but the bundle directory was
  empty. The plan was OK because there was nothing to object to.
```

No claim, no confidence field, no sources. This note may be wrong. It cost thirty seconds.

### Stage 2: logged (medium tier, `20-projects/_logs/`)

At the end of the session, the observation is written up as part of what happened, and flagged
as a candidate.

```yaml
---
title: "harbormaster - Session Log - 2031-03-04"
tier: medium
tags: [tier/medium]
status: active
type: project-log
project: "harbormaster"
created: "2031-03-04"
last_reviewed: "2031-03-04"
source_notes: ["[[2031-03-04]]"]
---
```

```markdown
# Key decisions

- Stopped treating a green `--dry-run` as evidence that the release artifact exists.
  Reproduced twice: empty bundle dir, exit code 0 both times.

# Promotion candidates (for long-term)

- A dry run that validates a plan does not validate the inputs to that plan. Generalises past
  harbormaster? Probably; same shape as every "0 findings" scanner result.
```

Note the honest hedge in the candidate line. The medium tier is where hedging belongs.

### Stage 3: promoted (long tier, `31-standards/`)

It recurs in a second project, in a different tool, so the generality condition is now met by
observation rather than by guess.

```yaml
---
title: "Dry runs validate plans, not inputs"
tier: long
tags: [tier/long]
status: stable
type: standard
project: "harbormaster"
created: "2031-04-18"
last_reviewed: "2031-04-18"
confidence: medium
last_verified: "2031-04-18"
related_logs: ["[[harbormaster - Session Log - 2031-03-04]]"]
---
```

```markdown
# Decision

Never accept a successful dry run as evidence that the artifacts it would have acted on exist.
Check the artifact directly.

# Sources / Verification

- [Source: [[harbormaster - Session Log - 2031-03-04]] | 2031-03-04 | confidence: medium]
- Reproduced on harbormaster 3.9.1 and on an unrelated bundler, 2031-04-18.
```

`confidence: medium`, not high. Two reproductions on two tools is decent evidence and not proof.

### Stage 4: re-verified

Months later you re-run the reproduction against a newer release. It still behaves this way.

```yaml
last_reviewed: "2031-09-02"
last_verified: "2031-09-02"
confidence: high
```

Both stamps move, because you actually re-probed the claim. Section 6 explains why the word
"actually" is doing real work there.

### Stage 5: superseded

harbormaster 4.2 ships a `--strict` dry run that fails when the bundle is absent. The old
standard's advice is now wrong in a specific way: it tells you to work around something that has
been fixed. The note is **not** deleted.

```yaml
---
title: "Dry runs validate plans, not inputs"
status: superseded
superseded_by: "[[Dry runs are trustworthy under --strict from 4.2]]"
last_reviewed: "2032-01-15"
last_verified: "2031-09-02"
confidence: high
---
```

`last_verified` does not move here. Nothing was re-probed about the old claim; it was retired.
The new note carries its own verification and links back with `related_notes`, the standard-to-
standard edge (`related_logs` is reserved for the medium-tier logs a standard came from):

```yaml
---
title: "Dry runs are trustworthy under --strict from 4.2"
tier: long
status: stable
type: standard
created: "2032-01-15"
last_reviewed: "2032-01-15"
last_verified: "2032-01-15"
confidence: high
related_notes: ["[[Dry runs validate plans, not inputs]]"]
---
```

The superseded note stays in place, readable, dated, and pointing forward. Six months later,
when someone finds a 4.1 deployment still running, the reason the old rule existed is right
there.

The shipped example notes tell a second, smaller version of the same story: a fictional
`example-api` service double-charged customers because its retries carried no idempotency key,
and `31-standards/EXAMPLE-retry-on-any-5xx.md` is marked `status: superseded` rather than
deleted.

**Archiving is a different move.** Superseded knowledge stays in its tier, because its successor
links to it and the reason it changed is still worth reading. `99-archive/` is for notes that no
longer belong to any live concern: a retired project's logs, a standard for a system you no longer
run. When you move one there, move the file whole, with its frontmatter unchanged, and do not
rename it. Obsidian resolves wikilinks by filename, so inbound links keep working. Expect it to
drop out of the dashboards and out of `vault-check.sh`, neither of which scans `99-archive/`; a
lower file count after an archiving session is the move working, not a fault.

**One part of archiving is automatic, and its boundary is narrow on purpose.**
`vault-retention.sh` moves aged dream journals and compaction stubs out of `20-projects/_logs/`
unattended. Those are the two things in the vault nobody authored. A journal is the dream pass's
own output and a stub is the compaction hook's, and git says so, because the runner moves a file
only when one machine commit added it, its trailers match what that commit stored, and nothing has
touched it since. A note you wrote fails that test at the first step, so the automatic move can
never reach one. It also never renames a file or alters its frontmatter, which is what keeps the
human rule above and the automatic one the same move rather than two.

Because that now happens without anyone present, the falling file count above happens without
anyone present too. That is why `vault-check.sh` prints the archive count and names the last
retention pass after its own count. Without those lines an archived note would simply be gone from
every number the checker prints, and an archived vault would be indistinguishable from one that
had lost notes.

---

## 5. `superseded` versus `contradicts`

These are different, and confusing them is the most likely user error in the whole system.

### `superseded_by` closes a lifecycle

One belief replaced another. There is a winner. The old note is retired: `status: superseded`,
`superseded_by:` pointing at the replacement. Because its status is now terminal, it drops out
of staleness queries. Nobody should be nagged to re-verify a claim that has been retired on
purpose, and nothing should load it as current guidance.

That is the example in stage 5 above: `--strict` exists now, the old workaround is obsolete, and
the old note is closed.

### `contradicts` closes nothing

Two notes disagree, both are still standing, and nothing has been resolved.

```yaml
# note A
title: "Batch size 256 is fastest for the ingest job"
status: stable
last_verified: "2031-06-11"
confidence: high
contradicts: "[[Batch size 64 is fastest for the ingest job]]"
```

```yaml
# note B
title: "Batch size 64 is fastest for the ingest job"
status: stable
last_verified: "2031-08-02"
confidence: high
contradicts: "[[Batch size 256 is fastest for the ingest job]]"
```

Both were measured. Both measurements were real. Nobody has yet worked out what differed, and
until somebody does, the honest state of the knowledge base is *we have two credible results
that disagree*. So:

- neither `status` changes,
- neither note is suppressed from staleness queries,
- neither is deleted,
- the edge is recorded in both directions, so that whichever note you open, you learn there is a
  dispute.

`.claude/rules/vault-notes.md` documents `contradicts` as a wikilink, which is the form used
above; the dashboard query only tests whether the key is present, so a list works too, but stick
to one shape across your vault.

The temptation is to write a resolver: newest wins, or highest confidence wins, or ask the model
to pick. Resist it. Automatic contradiction-resolution silently drops memories that are still
needed, and it does so precisely in the cases where the disagreement was informative. The
disagreement above is a clue about a hidden variable, probably a hardware or dataset difference.
An auto-resolver would have discarded the clue and left you with a confident, unqualified,
possibly wrong answer.

The rule is short enough to memorise: **`superseded` means one of these is dead; `contradicts`
means both are alive and we do not yet know why.** Only a human moves a `contradicts` edge to a
`superseded` one, and doing so means they established which is right.

---

## 6. Earned and unearned freshness stamps

Two date fields, and the distinction between them carries most of the system's honesty:

- `last_reviewed` — a human or agent read this note and it still looks right.
- `last_verified` — the claim was re-probed against reality and held.

Move `last_verified` only when you actually re-ran the check. Read the note, nodded, changed
nothing? That is `last_reviewed`. The command was re-run, the endpoint re-queried, the
reproduction re-executed? Then `last_verified`, and say in the note what you ran.

An unearned `last_verified` stamp is worse than no stamp at all, and the reason is mechanical
rather than moral. A note with no verification date is visibly unverified: every staleness
query, every review pass, every agent that sorts by age will surface it. A note stamped today
because somebody reviewed it and moved the wrong field looks maximally healthy. **It suppresses
its own detection by every later pass, human or agent.** The stamp does not merely fail to add
information; it removes the note from the set of things anyone will ever look at again.

This is the same failure as a green test suite that skipped the test you cared about. The signal
reads "checked and fine" and means "not checked".

Practical consequences:

- When in doubt, move `last_reviewed` and leave `last_verified` alone. An older `last_verified`
  is not an embarrassment; it is an accurate statement about when you last did the work.
- Lower `confidence` when a re-check was not possible. A note can be reviewed today and
  low-confidence at the same time, and that combination is useful information.
- Record what the verification *was*, not just that it happened. "Re-ran the reproduction on
  4.0.2, still fails" survives; "verified" does not.

The path-scoped rule in `.claude/rules/verification.md` states this contract for notes in the
long tier.

---

## 7. Why the unattended agent only proposes

The vault ships a scheduled dream-agent (`.claude/agents/dream-agent.md`), driven by the shipped
runners `.claude/scripts/dream-pass.sh` and `.claude/scripts/dream-pass.cmd`. It reads across the
tiers, looks for repeated themes, finds candidates nobody promoted, notices contradictions, and
writes **one dated journal file**. That is its only write. It never edits an existing note,
never moves a note between tiers, never changes a status, never touches a date field.

That constraint is what makes running it unattended acceptable. An unattended process that can
rewrite your standards is an unattended process that can quietly corrupt the exact material you
rely on to catch errors, and it does so while you are asleep and not reading diffs. And because an
instruction to a model is not a sandbox, the constraint is also checked from outside: the runner
fails the pass if any file other than the journal changed, and the agent has no Bash tool with
which to reach around it.

There is a second, subtler reason, and it is the one worth internalising: **an agent that
consolidates its own prior output converges on its own errors.**

Consider the loop. The agent notices a theme and writes it up. Next week it reads the vault
again, finds its own write-up, and counts that as an occurrence of the theme. The theme now
looks better supported than it did, so it gets written up more confidently. Week three, two
mentions. Week four, three. Nothing new has been learned from the world; the agent has been
measuring its own echo and rounding it up into confidence. Any pipeline that consumes what it
produces needs an explicit rule against counting its own output, or it will manufacture
consensus out of a single unverified observation.

That is why the dream-agent excludes the auto-written compaction stubs from its own occurrence
counting. Those stubs are produced by the compaction hook
(`.claude/hooks/postcompact-wrap-up.sh`), one idempotent, size-capped stub per session, so that
a compaction's material is recoverable rather than lost. They are machine-written artifacts of
the session, not independent evidence that a topic mattered. Counting them would let a single
long session, chopped into six compactions, look like six separate corroborations.

The output shape follows: the agent proposes, you dispose. Its journal is a list of suggestions
with links, and promoting any of them is a human action. The weekly promotion-agent is allowed
to write into the long tier, which is why its runner commits every note a pass writes, and puts
back the notes of a pass that fails the check. Its output is recoverable by `git` rather than by
trust. The runner fences where it may write (the long tier and a promotion report), but a fence
only catches a write in the wrong place. Undoing a bad write in the right place takes the commit
before it, which is why `git` is a hard requirement.

There is a third shape, and naming it keeps the argument above honest. `vault-retention.sh` runs
unattended and is neither a proposer nor a writer. It authors nothing, so the echo problem cannot
reach it, and it decides nothing about meaning, so there is no judgement to disagree with later.
What it does is mechanical and checkable from outside — it moves a file only when git can prove a
machine wrote it and nobody has edited it since. The safety argument for it is therefore a
different one from the dream agent's. The dream agent is safe because the only thing it can write
is one new file at a predictable path. The retention pass is safe because it cannot change what a
file says at all, only where it sits, and one `git revert` puts every move back. That the three
passes need three different arguments is the point. "Unattended" is not one risk with one answer.

---

## 8. Why checks report and never repair

`.claude/scripts/vault-check.sh` walks the six content tiers (`01-inbox/`, `10-daily/`,
`20-projects/`, `30-knowledge/`, `31-standards/`, `40-llm-wiki/`), skipping every `templates/`
folder and the auto-written `compaction-*.md` stubs. `90-auto-memory/` is machine-managed and
deliberately out of scope, as are `99-archive/`, `.claude/` and the repo root. It prints what it
finds, prints how many files it checked, and exits non-zero when something is wrong. It changes
nothing. Given a note with a missing `tier:`, it will not add one. On a full scan it also reports
how many notes sit in `99-archive/` and what the last retention pass moved, which is reporting in
the same spirit — it judges neither, and changes no count and no exit code, but without it a note
the retention pass archived would leave no trace in anything this script prints.

Five checks, and that is the entire list:

- **C1** — the first line of the file is a bare `---` fence.
- **C2** — the frontmatter contains a `tier:` key.
- **C3** — the frontmatter contains a `type:` key.
- **C4** — if both `created:` and `last_verified:` are present, `last_verified` is not earlier
  than `created`; a `created` that is not a `YYYY-MM-DD` date is reported too.
- **C5** — if `last_verified:` is present, it is not later than today; a `last_verified` that is
  not a `YYYY-MM-DD` date is reported too.

Notice what is *not* there. Nothing requires a long-tier note to have a `last_verified` date at
all, and nothing reads the `Sources / Verification` section. The discipline in sections 3 and 6
is a human contract. The checker catches only the cases where the metadata is structurally
absent or internally impossible.

That narrowness looks like a missing feature. It is the point, and so is the refusal to repair.

The invariants are proxies. C5 is worth running because a `last_verified` in the future is a
defect in the stamp itself: somebody typed the wrong year, copied a template without editing it,
or let a script write a date nobody checked. C2 is worth running because a note with no `tier:`
is invisible to every dashboard query, so it has quietly left the system.

Now imagine either one auto-repaired. A fixer that clamps an out-of-range `last_verified` back to
today satisfies C5 perfectly and converts "this stamp is provably wrong" into "this note was
verified today", the strongest claim in the vocabulary, manufactured from the weakest possible
evidence. A fixer that inserts a default `tier:` into every note missing one clears C2 and
silently misfiles whatever was actually a standard. Either way the vault ends up fully compliant
and you have lost the thing the check was measuring. The alarm is cleared; the fact is not
established. Worse, by section 6's logic, a note stamped by an auto-repair is now permanently
invisible to every future staleness pass.

The same reasoning applies to the lint hook (`.claude/hooks/vault-lint.sh`): it runs on write,
prints advice, and always exits 0. It will tell you a note is missing `tier:` or `type:`. It
will not add them. And it could not block the write even if it wanted to, because it runs as a
post-write hook (Claude Code's `PostToolUse`), so the file is already on disk by the time it runs.
The place a violation can stop something is the opt-in commit gate, which refuses the commit.

A related discipline governs the checks themselves: **a check that cannot run must say so rather
than report clean.** A "0 findings" result from a scanner that never scanned anything is
indistinguishable, in the output, from a clean vault. That is why `vault-check.sh`
prints its file count, and why a scan of zero notes exits 2 with a `VACUOUS` message instead of
reporting a pass. Against the shipped example notes the correct output is
`0 violation(s) across 9 file(s) checked`.

The exit code carries the same distinction. `1` means a note violates an invariant and `2` means
the checker could not run at all, because a caller that reads only the code should not have to
guess which of those it is looking at. The count line is the sentinel behind that promise, so read
its numbers rather than matching its wording — a check that greps for a prefix passes whatever the
counts say, which is the same vacuity one level up.

The optional dependencies degrade loudly for the same reason. The lint hook's
invisible-character scan prefers `perl`; `grep -P` is a GNU extension, absent from the BSD grep
on macOS, and is only the fallback. When neither is available the hook says the scan did not run
instead of falling through to silence. `jq` gets a related treatment for a different job: it
parses the hook's JSON input, it is not bundled with Git for Windows, and when it is missing the
hook falls back to a cruder path parse and prints a degraded-mode warning rather than silently
extracting an empty path and exiting 0. The scheduled passes carry the same idea in a different
place: the dream and promotion runners assert that an artifact was produced, and exit 1 when a pass
exits 0 having written nothing, so a silent no-op cannot masquerade as a green run. A pass that
hangs is killed and exits 124 rather than holding the scheduler slot indefinitely, and one whose
output stops for longer than it normally goes quiet is killed sooner, with exit 125. The retention
runner is the exception that shows what the rule is really for. It has no artifact to assert,
because having nothing to move is its ordinary outcome and writing nothing is a correct exit 0.
What stands in place of the assertion is that every run logs the judgement it made about every
candidate, with a reason for each, and `--dry-run` produces exactly that log and nothing else. The
demand is not that a pass must always produce something. It is that a pass must never leave you
unable to tell whether it did. (`docs/setup.md` covers installing `jq`, `perl` and the Dataview
plugin.)

The shipped test suite in `.claude/scripts/run-tests.sh` applies the rule to itself with **both**
positive and negative controls: a positive control is known-bad input the hook must flag, and a
negative control is known-good input that must produce silence. A suite that only ever asserts
silence cannot distinguish a working detector from a broken one. Note the scope limit, though: the suite builds synthetic fixtures in a temporary directory
and runs the hooks against those. It never looks at your vault's actual folder layout, so it will
stay green after a botched tier rename. Only `vault-check.sh` sees your real notes.

---

## 9. Honest limitations

This is a **discipline supported by tooling**, not an enforced system. Be clear-eyed about what
that means before adopting it.

- **The lint hook cannot stop a bad write.** It runs after the write has already landed
  (a post-write hook), so no exit code could block it, and it always exits 0 so it never even
  surfaces as a failure. It also only sees files written by a harness that runs it, which out of
  the box means Claude Code. A note you type in Obsidian is never linted.
- **Nothing stops you writing a bad note.** A standard with a fabricated `Sources /
  Verification` section passes every check in this repo. The checks read structure; they cannot
  read truth.
- **`vault-check.sh` is report-only.** It exits 1 on violations and 2 when it could not run, both
  of which are useful in a pre-commit hook or in CI. The shipped `.github/workflows/ci.yml` runs it against the template's own
  example notes on Linux, macOS and Windows, and `.claude/githooks/pre-commit` runs it before
  each commit of *your* notes, but only once you enable it with
  `git config core.hooksPath .claude/githooks`.
- **Promotion is manual by design, which means it can simply not happen.** The medium tier will
  fill with promotion candidates that nobody promotes. The dream-agent surfaces them; it cannot
  make you act.
- **The tier folder names are hardcoded in many places.** Renaming a tier touches, at minimum,
  `AGENTS.md`, `.claude/hooks/vault-lint.sh`, `.claude/scripts/vault-check.sh` (its `TIERS=`
  line), `.claude/hooks/postcompact-wrap-up.sh`, both agents, all four files in
  `.claude/rules/`, all five skills, `30-knowledge/moc/VAULT-INDEX.md` (every Dataview query
  names folders), `dream-pass.sh`, `promotion-pass.sh` and `vault-retention.sh`, the `run-tests.sh` fixtures,
  `.obsidian/daily-notes.json`, and `.gitignore`. Treat that list as a floor, not an inventory,
  and grep for the old folder name before you declare the rename done. It is the template's
  largest customization cost, and it is worth deciding on the folder names before you have a
  thousand notes rather than after.
- **Some of the value depends on Obsidian.** Dataview is required for the dashboards; without it
  the vault is still a perfectly good directory of markdown, but the queries render as inert
  code blocks. Obsidian also opens an unfamiliar vault in Restricted Mode, where community
  plugins are disabled entirely until you turn it off.
- **The scale is personal.** This design assumes one person, or a small team with shared
  judgment, curating a long tier of tens of notes. It has not been designed for an organisation
  of a hundred contributors writing standards concurrently.

What the system buys you is narrower than "reliable memory": **the value is in making a bad note visible, not impossible.** A wrong standard in this
vault has a date on it, a stated confidence, a sources section, a link to the log it came from,
and a place in a folder small enough to read end to end. When it turns out to be wrong, you mark
it superseded, and the record of having believed it survives.

That is a much lower promise than an enforced system. It is also one this design can keep.

---

## Where the rules live

- `AGENTS.md` — the operating instructions every harness follows for the whole vault. `CLAUDE.md`
  imports it for Claude Code and adds the Claude-only adapter notes.
- `.claude/rules/vault-notes.md` — the frontmatter contract, wikilinks, Dataview, filing.
  Path-scoped to the six content tiers.
- `.claude/rules/verification.md` — freshness, citation, and the earned-stamp discipline. Also
  path-scoped to the six content tiers.
- `.claude/rules/untrusted-captures.md` — the prompt-injection boundary, path-scoped to
  `01-inbox/` and `40-llm-wiki/raw/` only.
- `.claude/rules/security.md` — global safety rules. No path scope: it always loads.
- The five `EXAMPLE-` notes, which live in their real tier folders rather than a separate
  examples directory, so the dashboards and graph colours populate on first run. Delete them
  with `find . -name 'EXAMPLE-*.md' -delete`.
- `docs/setup.md`, `docs/customizing.md` and `docs/reference.md` — installation, the
  customization walkthrough, and the field-by-field reference.
