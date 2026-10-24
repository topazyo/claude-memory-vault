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

## 1.4.2 — 2026-10-24

A hardening release for the scheduled runners, and a fix for `/resume`. Each runner now clears
the inherited git settings that pointed git at another repository (with a `WARNING:`), refuses the
spellings under which git read another folder than the runner meant, checks its own temporary
folder before trusting what it holds, and, in claude mode, starts Claude Code with every hook but
managed ones turned off (measured for the vault's and plugins' hooks; for the account's own,
reasoned). `/resume` no longer briefs from the scheduled passes' own journals and reports, and stops
when `.claude` or `.claude/logs` is a link or does not list as a folder whose owner can write it
(`drwx`), because a tripwire may then be set in the state directory only. The command-mode sandbox
now also requires that a pass runs no hook and cannot write the vault's `.git` (or, with the commit
gate on, its `.claude/`), the harness README gives a check that the vault's hook scripts do not run
in one and that those folders refuse a pass's writes, the container recipes mount an empty file
read-only over the vault's `.env` and start a new container for each run, and the Aider guide's
scheduled config sets `git: false`, which Aider documents as stopping its use of git (not measured
for this release).

### Security

- **An inherited `GIT_DIR` sent a pass's commit into another repository.** With `GIT_DIR` naming
  a second repository, a dream pass and a promotion pass in command mode on 1.4.1 each exited 0
  with their commit landed there (measured on Linux), and nothing in the runner could see it:
  git took the vault as that repository's work tree. The library now clears, as it loads, git's
  own list of the variables that belong to one repository (the 15 names `git rev-parse
  --local-env-vars` prints, git 2.55.0), and each runner logs a `WARNING:` naming the ones it
  cleared. The variables that only change where git's search for a repository stops are kept,
  because a pass commits only when git's top level is the vault itself, and so are those naming
  the account's own configuration and tools. `vault-check.sh` and `vault-update.sh` load the
  library in a subshell, so their own git calls still honour inherited values.
- **On Windows, an inherited `MSYS2_ARG_CONV_EXCL` covering `core.` left git's `core.hooksPath`
  in Git Bash's form**, so `git.exe` looked for its hooks in a folder under the drive root, which
  another account could make (measured in Git Bash on 1.4.0 and 1.4.1's code). The library clears
  `MSYS_NO_PATHCONV`, `MSYS2_ARG_CONV_EXCL` and `MSYS2_ENV_CONV_EXCL` as it loads; the last does the
  same to the `GIT_INDEX_FILE` the retention runner hands git (reasoned). A `MSYS_NO_PATHCONV=1`
  set for the whole account, which made every pass fail at its first git step, now lets it run
  (measured in Git Bash with a dream pass in command mode).
- **A vault spelled with a part ending in a dot made git read another folder's repository.** On
  Windows, or wherever a `cygpath` is found on `PATH`, Win32 drops such a dot, so with a folder `v`
  beside a vault `v.` git read the repository in `v` (measured in Git Bash). Every runner, in every
  mode, now refuses such a vault, and one whose path holds a colon that is not a drive letter's or
  whose last part ends in a space (both reasoned), before the state directory, the run lock or any
  git call. On 1.4.1 a dream pass and a promotion pass in command mode, and the retention runner,
  each ran on such a vault and called git (measured on Linux, the platform read as Windows through
  a `cygpath` stand-in).
- **A relative `TMPDIR` put the runner's own folder inside the vault.** `mktemp` returns a relative
  path when `TMPDIR` is relative or starts with `~` (measured in Git Bash and on Linux), and the
  runners have moved into the vault by then, so on 1.4.1 the dream and promotion runners made their
  folder there and called git with that folder's hooks folder (measured on Linux, through a
  `mktemp` stand-in); in command mode their agents then started. The retention runner did the same
  only when a `mktemp` stand-in handed it a relative folder: its own rule takes `TMPDIR` only when it
  starts with `/`, and a relative `TMPDIR` reached it only through the fallback the next item
  describes. Every runner, in every mode, now refuses a temporary folder that is not an absolute
  path (a drive path counts only under Git Bash, MSYS or Cygwin), and, on Windows or wherever a
  `cygpath` is found, one holding a colon that is not a drive letter's: NTFS reads a part such as
  `x::$INDEX_ALLOCATION` as the folder `x`, and MSYS leaves a path with a colon unconverted
  (reasoned; on 1.4.1 a dream pass in command mode ran with such a folder, measured on Linux
  through the stand-ins).
- **The retention runner could make its folders, and its temporary files, inside the vault.** When
  neither `$TMPDIR` nor `/tmp` could hold a folder it fell back to a plain `mktemp -d`, which reads
  `TMPDIR` itself, a relative one included; and its git calls saw a relative `TMPDIR` as given (all
  16 saw `TMPDIR=rel`, measured on 1.4.1, through stand-ins), so the library's own temporary files,
  the watchdog's among them, follow it there (reasoned). The fallback is gone, so such a run
  refuses with `could not create a temporary directory`, and the runner sets `TMPDIR` to `/tmp` for
  the whole run when it does not start with `/`.
- **The fence trusted a folder the pass could change.** The runner keeps its snapshot of the vault,
  its backup of the steering surfaces and git's hooks folder in its own temporary folder. Measured
  on 1.4.1 with stand-in agents in command mode, on Linux: with that folder removed, or with the
  snapshot moved to a name holding a line break that forges the folder's listing, the pass exited
  1, its writes kept and no tripwire set; with its write added to the snapshot, or the snapshot
  replaced by a link, it exited 0; hooks planted in the hooks folder ran at the runner's commit; and
  a link put at the name of the "after" snapshot had a file outside the vault written through. Each
  runner now records the folder before the agent starts and again as soon as it returns, before
  writing anything there. When the two differ, or the second cannot be made, the pass ends with
  exit 78: an `UNVERIFIED:` line, the tripwire in a shape that says nothing was moved or restored,
  no in-flight marker, and the pre-pass backup and the folder kept for review. When no tripwire can
  be written the exit is 70 instead, with a `TRIPWIRE-ERROR:` line in place of the `UNVERIFIED:`
  one and the in-flight marker kept. When the watchdog also stopped the agent, 78 or 70 takes the
  place of 124 or 125, and the `TIMEOUT:` or `STALLED:` line is logged as well. Nothing is restored
  on that path, so `.git/config`, `.git/hooks` and `.obsidian/` may still hold what the pass
  planted: a `core.fsmonitor` command runs at the first `git status`, hooks run at git calls, and
  Obsidian loads plugins (reasoned). The `UNVERIFIED:` line now says not to open the vault in
  Obsidian or an agent session until it is reviewed, and to run no git command in it before the
  steering surfaces have been compared without git with the pre-pass backup, or checked by hand
  when there is no backup; with a backup it points to the tripwire for how. The tripwire says how:
  git that starts on its own in a shell prompt or an editor counts as a git command; the backup is
  unpacked into an empty folder with `tar -xf` and compared with the vault with `diff -r`, with
  `--no-dereference` where that `diff` has it, so a link is compared rather than followed; where
  `.git` is a file, the git folder it names is outside the vault and the backup, and is checked by
  hand too; and a `.git` deeper in the vault, which `diff -r` shows only as a new folder above it,
  is found with `find . -name .git` and its config and hooks checked. A link in `.claude/logs`, or
  `.claude` itself as a link, is in neither the backup nor git, so links are listed with
  `find .claude -type l`, and any the owner did not make is removed once what it names has been
  checked. Then the rest is
  reviewed, starting with
  `git -c core.fsmonitor=false --no-pager status --ignore-submodules=all`, which starts no
  fsmonitor command or pager and stays out of repositories nested in the vault, because a nested
  repository's own config, which is not a steering path of the vault, would run at a plain
  `git status` (reasoned). A backup an earlier pass kept is removed before the next pass copies
  its own, and a copy that fails, or leaves something other than a regular file, now refuses the
  pass with exit 1 before the in-flight marker and the agent; on 1.4.1 the copy was unchecked and
  the agent ran after a failed one (measured), so an older backup could be named as the pass's
  (reasoned). That covers a link already at the backup's name, which is removed before the copy,
  and a copy that succeeds leaving a link, or nothing, there: on 1.4.1 such a link was followed and
  the file it named overwritten, and a copy that left a link or nothing was taken and the agent ran
  (measured on 1.4.1). The record holds each file's digest (`sha256sum`, else `shasum`, else
  `cksum` with a `WARNING:`) and whether it has one link or more, refuses any name outside letters,
  digits, dot, underscore and hyphen, and passes the watchdog's `run` and `gaps` only as regular
  files with one link. Folders in it are recorded
  as empty or not, never entered, and one that cannot be listed fails the record: on Linux a hooks
  folder made searchable but not readable (`chmod 100`) listed as empty while a hook in it still
  ran through its search bit (measured on Linux; on Windows `chmod` does not stop a listing,
  measured in Git Bash), so such a folder now refuses the pass with exit 1 before the agent starts
  (reasoned) and ends it with 78 after. The library also clears `GLOBIGNORE` as it loads, because
  set before then it would hide names from both records (bash 5.3 does not take it from the
  environment, measured in Git Bash and on Linux; bash 3.2 is unmeasured). The record does not see
  a change undone before the agent returns, or one made after the check by a process still
  running; with `cksum`, anyone able to write the folder can forge a match.
- **The tripwire after a pass that never reached containment said the vault had been restored.**
  The tripwire a signal writes before containment ran (`INTERRUPTED before containment. Tripwire
  set.`, exit 130 or 143), and the one the next run writes from an in-flight marker a dead pass
  left (exit 78), said that changed files were moved to the quarantine and restored from the
  pre-pass backup, and sent the owner to `git reflog` (measured on 1.4.1). Containment never ran
  on either path, so nothing was moved or restored, and `git reflog` honours the `core.pager`, as
  `git status` runs the `core.fsmonitor`, of a `.git/config` the pass may have changed (reasoned).
  Both now say "Nothing was moved or restored, because containment did not run." and give the
  advice the `UNVERIFIED:` tripwire gives: check the steering surfaces against the pre-pass backup
  without git, before any git command.
- **After a signal before containment, the runner wrote its log through a symbolic link the pass
  made.** Containment had not run, so a symbolic link the pass put in place of
  `.claude/logs/<agent>.log` was still there, and the runner wrote the rest of its lines through it
  (measured on 1.4.1; through a link at `.claude` or `.claude/logs`, reasoned), so a command-mode
  pass could make the runner append to any file the account can write through a symbolic link. The
  78 path above leaves such a link in place too, and so does a pass that ended there or died, for
  the next run: on 1.4.1 that run wrote its `TRIPWIRE:` refusal, or the line it writes from a dead
  pass's in-flight marker, through a link at the log, and a run that waited for the run lock wrote
  its refusal through a link the log became while it waited (measured on 1.4.1, each for every
  runner). On all three paths, when the log, `.claude` or `.claude/logs` is a symbolic link,
  `.claude/logs` is not a folder, or the log is there and not a file, the runner now writes the rest
  of the run's lines to `dream-pass.uncontained.log`,
  `promotion-pass.uncontained.log` or `vault-retention.uncontained.log` in the state directory,
  with a `WARNING:` there, and a tripwire it writes says so. The retention runner's printed lines
  carry the `WARNING:` once when the run could keep its own copy of them; when it could keep none,
  or could not read it back, it prints instead that the lines are only in the state directory's
  log, and names it. A later run checks as soon as its state directory is known, before its run
  lock, whenever the tripwire or the passes' in-flight marker (`runner-inflight`) is there in
  either copy, and again once it holds the lock, because the pass holding the lock could make the
  link, and set the tripwire, while the run waited. A line logged before the first check, in every
  runner (a setting's warning, the state-directory error, the `WARNING:` naming the git variables
  the runner cleared, or the `ERROR:` refusing the vault's spelling), still goes to the vault's log
  path, and opening
  the log there may create, empty, a file a link at it names. A line a dream or promotion run logs
  while waiting for the lock (a stale-lock line, or the `LOCKED` line when the wait runs out) goes
  where the first check left the log: to the state directory when that check moved it, otherwise
  to the vault's log path. The retention runner passes on the lines it logged while waiting only
  after its second check, so they go to the state directory too, when it could keep its own copy of
  its lines and was not stopped while waiting; otherwise they too go where the first check left the
  log (reasoned). The signal handler checks only after it has stopped the agent's process tree,
  so a link that a process the stop reaches makes once it is reached is found too, where 1.4.1
  wrote its lines through such a link (measured on 1.4.1); a process that has left the tree and
  its process group is neither
  stopped nor recorded (reasoned).
  Besides the lines listed above as still going to the vault's log path, these are still open, and
  carried to a later release, each needing a command-mode pass with a shell, which `docs/setup.md`
  says not to give it (what the harness itself runs during a pass could give one all the same,
  reasoned: the vault's own hooks, where the wrapper left them on, git, which runs what the vault's
  git configuration and hooks name, or a tool the harness starts by itself (carried); so
  `docs/setup.md` now asks for hooks off too, and for the vault's `.git`, and, with the commit gate
  on, its `.claude/`, out of a pass's reach, the Aider guide sets Aider's documented `git: false`
  (not measured for this release) and the container recipes mount `.claude/` and the vault's `.git`
  read-only, while whether the Codex and Gemini CLI sandboxes leave those folders writable is
  carried; see Changed): a hard link at a log, which has the runner append its lines, names the pass
  chose included, to the file it shares, and one at `.claude/logs/dream-pass.git-state.txt`, which
  has the next dream run empty that file and write `git status`, those names included, into it; a
  FIFO at a log, which blocks every later run of that runner at the log's first write, before any
  check, and one at the git-state file, which blocks the next dream run while it holds the run lock,
  so a promotion run is refused with 75 and every later dream run blocks the same way, each with no
  tripwire at all, an outside time limit ending each run; and a symbolic link containment cannot
  move, as in a `.claude/logs` made read-only, which the runner still writes through (measured with
  this release; 1.4.1 behaves the same; the FIFO at a log measured for the dream runner only, and on
  1.4.1 by reading). A process that outlives the pass can also give the vault's `runner-tripwire` a
  second name, and a later note is then appended to the file it shares, and, after a stop that could
  not end it, put a link at the log once containment has run, so the runner's later lines go through
  it (both reasoned).
- **The vault's copy of the tripwire was written through a name a pass could work out.** The
  runner copied it first to `runner-tripwire.tmp.<pid>`, a name a command-mode pass could work out
  from the runner's pid in the vault's in-flight marker, and `cp` followed a link planted there: a
  file outside the vault was written through it, and the vault's tripwire was not a file (measured
  on 1.4.1). A note added to the tripwire was written through a linked `.claude/logs` too (measured
  on 1.4.1), the vault's in-flight marker was copied the same way, a link planted at
  `runner-inflight.tmp.<pid>` having a file outside the vault written through it (measured on
  1.4.1), and a link to a folder at the tripwire's own name had the copy moved into that folder,
  outside the vault, leaving the vault's tripwire not a file (measured on 1.4.1). The vault's
  copies of the tripwire and of the marker now go first into a file `mktemp` makes, or, where
  `mktemp` fails or makes no file, so the tripwire still does not depend on it, into one made under
  a name from `$RANDOM`, refused when anything is already there, because a pass can read the clock
  and the pid that seed `$RANDOM`, and created with noclobber, which refuses a file, a link to a
  file or a dangling link put there after that check but still opens a device or a FIFO (the seed,
  and the device and FIFO race, which only a process still running could win, reasoned); neither
  copy nor a note is written while `.claude` or `.claude/logs` is a link; a link at the copy's own
  name is removed before the copy is renamed into place, because `mv` would otherwise move the
  copy into a folder the link names, and nothing is written when that link cannot be removed, as
  an immutable link on macOS can make it (the cause reasoned).
  While `.claude` or `.claude/logs` is a link only the state directory's copies are written; the
  runners read both copies of each, and `vault-check.sh` the tripwire's, so they still refuse.
- **A pass that removed the runner's folder and then signalled its runner was not stopped.** The
  signal handler recorded its stop in the runner's folder for the pass. On 1.4.1 a pass that
  removed that folder and then sent its runner TERM was still running after the runner exited
  (measured on 1.4.1), and would run on until its own end or the watchdog's timeout (reasoned),
  and a link put at the folder had the stop's record written through it (measured on 1.4.1). The
  stop is now recorded in the state directory (`signal-stop.<pid>`), and once the runner's folder
  for the pass has been made, the agent's process tree is stopped whether or not that folder is
  still there.
- **A signal copied what a link at `run` named into the state directory.** Before the pass's
  output reached the run log, the signal handler kept it by copying the runner's `run` file, and
  followed a link put there to whatever it named (measured on 1.4.1), so a command-mode pass could
  have the runner copy any file the account can read into the state directory. The signal handler
  and the 78 path now keep no output when `run`, or the runner's folder itself, is a link, and the
  78 path logs `WARNING: the run output, …, is missing, is not a regular file or is in a folder that
  is a link, so it was not kept.`
- **Hooks ran inside every claude-mode pass.** Hooks in enabled plugins
  and in the vault's own settings ran inside the unattended pass, as the account, with a shell the
  agent's allowlist never sees, and so, by the same route, would hooks in the account's own settings
  (reasoned). With 1.4.1's settings file, Claude Code 2.1.301 ran a probe folder's
  own hooks and plugins' `SessionStart` and `Stop` hooks, one of which wrote a file outside the
  folder; with the runner's file now holding `"disableAllHooks":true`, it ran none, and the
  account's `CLAUDE.md` was still sent in the request (measured on Windows, `-p`); a live dream
  pass through the 1.4.2 runner ran to its journal (measured). The probe held no hook in the
  account's user settings, nor in an agent's or a skill's frontmatter, so that the line turns those
  off too is reasoned, not measured. Hooks from managed settings are not
  turned off (measured 2026-09-15 on an earlier version), and MCP servers, and the commands a
  settings file names outside hooks, still start (reasoned). The new line is measured on 2.1.301
  only.

### Changed

- **`/resume` skips the dream journals and promotion reports.** It read the three newest files in
  `20-projects/_logs/`, skipping only templates and compaction stubs, so in a vault where the
  passes run it briefed from their proposals and results as if they were the last session's work.
  Both copies of the skill, `docs/agent-onboarding.md`'s spelled-out form and `docs/reference.md`
  now name `dream-*.md` and `promotion-*.md` too.
- **`/resume` stops when `.claude` or `.claude/logs` is a link or does not list as `drwx`.** While
  either is a link, the runners now write their tripwire to the state directory only (see
  Security), as they do when `.claude/logs` is a file or a folder they cannot write, so `/resume`,
  which reads the vault's copy, would brief as if none were set. Both copies of the skill and a new
  first step in `docs/agent-onboarding.md`'s spelled-out form now run `ls -ld .claude .claude/logs`
  first and stop unless it prints a line for `.claude` and every line starts with `drwx` (a missing
  `.claude/logs` is fine), and look at the tripwire with `ls -ld` before reading it, without running
  any of the vault's scripts, which a pass may have changed. `AGENTS.md` adds the same folder check
  for an interactive session. The test reads the mode bits `ls` prints, not whether the runner can
  write, so a folder that lists as `drwx` but refuses the runner (a Windows ACL, a macOS `uchg`
  flag, or a folder another account owns) still lets `/resume` brief; that case is carried to a
  later release.
- **The command-mode sandbox text covers both passes.** The Codex, Copilot, Cursor, Hermes and
  OpenCode guides took the shell away for the dream pass only, against `docs/setup.md`, which asks
  it for the dream pass and the promotion pass alike; they now say both passes, and the Codex
  guide's wrapper gives both its profile with Codex's shell tool off, and the OpenCode wrapper picks
  an agent for each. `AGENTS.md`, the harness README and the Aider, Codex, Copilot, Cursor, Gemini
  CLI, Hermes and OpenCode guides now also say that each pass's tools may write only inside the
  vault.
- **The command-mode sandbox now requires every hook off, and the vault's `.git` out of a pass's
  reach.** The hooks the template ships for interactive sessions (`.claude/settings.json`,
  `.codex/hooks.json`, `.cursor/hooks.json`, `.github/hooks/vault.json`, `.gemini/settings.json`,
  `.windsurf/hooks.json`, Hermes's snippet, OpenCode's plugin and Pi's extension once enabled, and
  the commit gate's `pre-commit`) run scripts inside the vault after a write, at a compaction or at
  a commit. A command-mode pass whose tools can write the vault could change such a script and get a
  shell through the next hook, whatever its shell tool was set to, so taking the shell tool away, as
  the guides did, was not enough (reasoned). With a stand-in agent that was itself a shell, on
  Linux, a script changed and put back before the agent returned left the runner nothing to see
  (exit 0, no tripwire); left changed, it was contained with a tripwire (measured). Whether each
  harness runs project hooks in its non-interactive mode was not measured for this release on any
  harness but one: Copilot CLI 1.0.86 runs the vault's repository hooks in `-p` mode in a folder it
  trusts (measured on Windows, 2026-10-18). A harness can also run git during a pass, and git runs
  what the vault's git configuration and hooks name, which a pass could write too (reasoned).
  `docs/setup.md`, `AGENTS.md` and the harness README now require that a scheduled pass runs no hook
  and can write nothing that turns one on, nor, where the harness itself can run git (assume any
  can), the vault's `.git` or, with the commit gate on, its `.claude/`, and the README gives a check
  every recipe must pass: on a scratch copy of the vault, whose `.git` is seen to be a folder, not a
  file or a link, and whose `.git`, `.claude/`, `.claude/hooks/` and `.claude/githooks/` are seen to
  resolve outside the vault and outside every folder the vault's own resolve to or name, with every
  script in its two hook folders a file with a single name, not a link, before its hook scripts are
  replaced with canaries (else the check is not verified; on Windows, one folder spelled two ways
  can read as two there, which stays open), the wrapper fires none, where the same wrapper with the
  measure taken away fires one. A control that fires no canary leaves the check not verified, never
  passed, and on a switch route the container is then the way on, where the check is run again. The
  check shows that the wrapper, the container definition, the switch file and the files they rest
  on, the home folders of the account the runner runs as (the one the schedule's environment names
  and the account's own, where they differ; on a switch route, the harness's too, the one the
  wrapper names among them), and every file of the class `docs/setup.md` names in its `UNVERIFIED`
  troubleshooting row that the runner or the harness reads at the per-user or the system level, or
  place named for one (in a container, outside the vault's mount too, with no other mount of a
  folder or file of the vault at or above them, the README's step 5 saying which), lie outside the
  vault and the copy, by their resolved paths (one inside, by any of its names, fails the check, and
  so does a folder this check requires outside both, or on a switch route a folder that holds the
  switch file or the wrapper, that holds the source of a mount from outside both whose target lies
  below the vault's or the copy's own folder), each file with a single name (a link count of 1) or
  each of its names found outside both, and no file or folder among them at or under a folder or
  file of the vault mounted elsewhere on the host, nor at or under the source of a mount from
  outside both into the vault or the copy, by the host's own list of mounts read as the README's
  step 5 says (each source and target spelled as an absolute path on the host, a source another
  listed mount also shows spelled through that mount as well, the list seen to show the mount that
  holds the vault, and a source spelled through another mount or on a share this host serves seen to
  show what its target shows; a list of mounts that cannot be read or does not show the vault's, a
  source that cannot be spelled or seen that way, or a pass-through file system, such as an overlay,
  not a bind mount or a share, mounted below the vault's or the copy's own folder leaving the step
  not verified), once a path inside the copy and one inside the vault have each read as inside, each
  spelled every way the paths compared reach the check, whether a file or a link's target spells
  them so (a short 8.3 name, another letter case, a substituted or mapped drive, a second path the
  host gives a folder above the vault or the copy, as WSL does for the distribution's root by
  default), unless the resolver used is seen, on that host, to turn each such spelling of the
  vault's and the copy's paths into the one compared, that the host's own list shows no mount at or
  under the vault's or the copy's `.git` or `.claude/`, nor any whose source lies there and whose
  target lies elsewhere in either (on a switch route, one whose target lies outside both leaving the
  step not verified), nor a mount of a folder or file of either at or under a copy outside both that
  the definition mounts read-only, and that no link below their `.git` or `.claude/` leads outside
  the one it lies below (the links listed only once the listing has shown control links made for the
  purpose in the copy's `.git` and `.claude/`, each to a folder outside both, a listing that does
  not show every one of them, or that cannot be made, leaving the step not verified, and on Windows
  a symbolic link, where the account cannot make one, stated open; where `.git` or `.claude/` is a
  link, or `.git` a file, the folder it resolves to or names, and any shared folder that one names,
  standing in its place and lying outside both, and, on a switch route, a vault whose `.git` or
  `.claude/` stands in that way leaving the step not verified; a file at or under `.git` or
  `.claude/` with a second name outside that folder, as a clone's shared object files have, not
  looked for, reasoned and carried), that the vault's hook scripts did not run, and that writes into
  the copy's `.git` and `.claude/` are refused, with a write the pass may make as that step's
  control (from a shell in the schedule's own container, each pass's where the wrapper sets them up
  differently, opened as the user the harness runs as, which must not be the superuser and whose
  home folder must lie outside the vault's mount, with no other mount of a folder or file of the
  vault at, above or inside it, the README's step 5 saying which, once the definition shows a new
  container for each run, which the runtime removes at exit, and every mount the README's rule and
  the guide require, and the container runtime's own listing shows every mount over or inside the
  vault but the vault's own, every mount of a file the wrapper or a switch rests on, and every mount
  over a hook or settings file a harness reads from the container's home, read-only, and any other
  writable mount discarded at exit, and that shell's own list of mounts, once it shows the
  definition's read-only `.git` mount with its source in the vault (in the check's run, the copy's),
  shows each mount at or under one that must be read-only as read-only too, and none of them but the
  `.git` and `.claude/` mounts having a folder or file of the vault or of the copy as its source (a
  source read as a file system and a path within it, those of the vault, the copy and any folder of
  either located from the host's own list, and the step not verified where that cannot be told); and
  a write to each hook or settings file the guide mounts in that home refused; or, on a switch
  route, with the harness running as a user other than the superuser (on Windows, not run elevated),
  through each of the harness's own tools for creating files, with a control file for each, judged
  by the harness's record of its tool calls, where writes into the folders that hold the switch file
  and the wrapper, into those home folders and into Gemini CLI's `~/.gemini/`, must be refused too,
  and where the sandbox's documentation or profile opens to a pass's writes any file or folder under
  those home folders outside the vault and the copy, or does not say which it opens, the step is not
  verified, because each probe samples only a new file, while files of that class that lie outside
  the vault and those home folders, at the per-user level or the system level, are not sampled at
  all and rest on the sandbox's documentation and the account's own permissions (reasoned; carried);
  this step was not run on any harness for this release); it cannot see a hook of the account's own.
  That nothing a pass writes turns one on rests on the switch file, the wrapper, the container
  definition and every file they name lying outside what the pass can write, and on the mounts, with
  the runner's fence restoring a harness config a pass leaves changed before a later run loads it (a
  root `.env`, `.hermes.md` and, should OpenCode read one, a project `opencode.jsonc` excepted,
  reasoned and carried). The Codex guide turns hooks off in its profile (`features.hooks`) and the
  Gemini CLI guide with `hooksConfig.enabled`. The Aider guide's scheduled config, now kept outside
  the vault, turns Aider's git off (`git: false`) and its lint after a change (`auto-lint: false`),
  so a pass's Aider should neither commit nor run git in the vault (Aider's documentation; not
  measured for this release); its check adds a canary in the copy's git configuration to the
  `pre-commit` one, with a control that turns git back on, says that a control fired by a commit
  alone shows only that Aider made no commit, and passes only with the README check's step 5 run in
  the schedule's container. The Copilot, Cursor, Hermes and OpenCode guides keep the hooks out of
  their containers (Copilot's and Cursor's mount `.claude/` with its `settings.json`, and any
  `settings.local.json`, from hook-free copies); those containers, and the Aider and Pi ones, now
  also mount the vault's `.git` read-only, the Hermes, OpenCode, Aider and Pi ones `.claude/` too,
  and OpenCode's all of `.opencode/` and `opencode.json`; every one of them also mounts an empty
  file read-only over the vault's `.env` (if the vault has none, create an empty one there yourself
  first), so that a pass can neither read the vault's `.env` nor leave one for a later run to load
  (reasoned); and each of these recipes now starts a new container for each run, whose own
  filesystem is discarded at exit, and follows the README's container rule, which keeps the home
  folder of the harness's user outside the vault's mount, with no other mount of a folder or file of
  the vault at, above or inside it (the README's step 5 says which), because several harnesses load
  settings or code at start from their home folder inside the container (reasoned). That closes only
  the next run: within a run the container's own filesystem stays writable, so the harness runs as a
  user other than the superuser, and the Cursor guide mounts files holding no hooks read-only over
  its two user-level hook files, because Cursor documents that it reloads its config files; Cursor's
  other home configuration, the folders that hold its two files included, Copilot's `~/.copilot/`,
  Hermes's configuration where it is not mounted read-only, any other home configuration whose load
  timing no guide documents, and the class `docs/setup.md` names in its `UNVERIFIED` troubleshooting
  row at its level in the home, stay open within a run (reasoned; carried), and a layout the owner
  builds that puts the vault's own mount at, above or under a folder from which the harness loads
  its user settings, home settings or code at start, other than the home folder and the files of
  that class the README's step 5 reads, stays open at the next run too, since step 5 does not look
  for it (reasoned; carried). Nor does step 5 look for (1) a link or junction in the vault or the
  copy, outside their `.git` and `.claude/`, whose target lies at or above an item it requires
  outside both, or at or under their `.git` or `.claude/`; (2) a link inside a folder copy the
  container definition mounts read-only that leads, in the container, into a folder a pass can write
  (the vault's writable mount or the container's own filesystem); (3) a mount or drive that only the
  schedule's own process or session sees, or that a container's own list of mounts does not show;
  (4) a pass-through file system at or above the vault's or the copy's own folder, or below it where
  the lists read do not show its kind; (5) on a switch route, a link outside both to their `.git` or
  `.claude/`, or a folder outside both that a pass-through file system above the vault presents as
  part of it; or (6) on a switch route, the vault, or a folder or file of it mounted or linked
  elsewhere, at, above or under a folder from which the harness loads its user settings, home
  settings or code at start, other than the home folders and the files of that class step 5 reads:
  those stay open too (reasoned; carried). One of kinds 1 to 5 that the owner finds fails the check
  where it puts an item step 5 requires outside both inside the vault or the copy, gives their
  `.git` or `.claude/` a second name, leads from a read-only folder copy into a folder a pass can
  write, lies at or under their `.git` or `.claude/`, is writable under a mount that must be
  read-only, or is one step 5 fails where its lists show it, and so does a folder or file of the
  vault found mounted or linked at or under a folder the harness loads from at start (kind 6), the
  harness's own folder in the vault and its own files apart, though not another folder or file of
  the vault mounted or linked under it, the runner's fence covering that folder and its own files.
  The Pi guide's wrapper loads no extension, and its check uses the vault's extension as the
  positive control. Whether the Codex and Gemini CLI sandboxes leave the vault's `.git` writable to
  a pass, or, with the commit gate on, its `.claude/`, or the folders that hold the switch file and
  the wrapper, or the home folders of the accounts the runner and the harness run as (those the
  schedule's environment and the wrapper name as homes, and the accounts' own), or, for Gemini CLI,
  `~/.gemini/`, was not checked, nor which settings layer wins for Codex's `features.hooks` and
  Gemini CLI's `hooksConfig.enabled`; the check's new step confirms part of it, a new file in each
  of those folders, and where it does not confirm all of them refused, or the sandbox's
  documentation or profile opens to a pass's writes any file or folder under those home folders
  outside the vault and the copy, or does not say which it opens, their guides now point to the
  container. The route is not new: 1.4.1's hooks and guides left it open in the same way.
- **The lines `shown_name` prints show C1 control characters, and the state directory, safely.** The
  `VIOLATION` list still prints the names it lists as they are (measured with U+009B on this release
  and on 1.4.1). `shown_name` mapped C0 control characters and DEL only, because under the runners'
  C locale `[:cntrl:]` matches nothing else, so a NEL or a CSI (U+0085, U+009B) in a name reached
  the log as it was (measured on Linux on 1.4.1). It now maps the UTF-8 encodings of U+0080 to
  U+009F too; a raw byte 0x80 to 0x9F that is not part of one, U+2028, U+2029 and the bidirectional
  controls are printed as they are. The state directory's path, which the owner sets, now goes
  through `shown_name` in every runner's log line and in the library's own; on 1.4.1 a line break in
  it split the state-directory line (measured). The tripwire file still writes the paths it names as
  they are, apart from its note that the log was moved.
- The control suite holds each of these. New control ids, required on all four test jobs:
  `resume-skips-pass-output`, `git-env-cleared`, `git-dir-pass`, `vault-root-spelling`,
  `runner-folder`, `retention-tmp`, `mem-override-drive-walk`, `mem-override-folder-above`,
  `shown-name-c1`, `state-shown` and `snapshot-sealed`; `msys-conv-pass` is required on the Windows
  job only, where MSYS converts paths. Each was seen failing against 1.4.1's code on its own
  assertion (on Linux; `msys-conv-pass`'s leg in Git Bash, run outside the suite, where all 18 of
  a pass's `core.hooksPath` values reached `git.exe` in Git Bash's form), except
  `mem-override-drive-walk` and `mem-override-folder-above`, which hold guards that were right in
  1.4.1 (the drive-path walk's own guard, and resolving a folder above at `/` or with `CDPATH` set)
  and were seen failing against mutants of them; and the unit rows of `vault-root-spelling` and
  `runner-folder`, and `snapshot-sealed`'s `GLOBIGNORE` row and its no-backup row, whose functions
  1.4.1 lacks, were seen failing against mutants of this release instead.
  `snapshot-sealed` also covers a hooks folder that cannot be listed (the stand-in checks that it
  can no longer list it), the folder replaced by a link and `run` replaced by a link (all three off
  Windows; the last two need a `WARNING:` that the run output was not kept, and nothing copied),
  `gaps` given a second name outside the folder, a stall with the folder removed (dream and
  promotion), the `cksum` path (a pass and a 78), a name outside the set before the record (exit
  1, no agent), `GLOBIGNORE` at load, both runners' logs linked to a file outside before the
  folder is removed (78, the lines in the state directory's log, the file as it was, off Windows),
  a TERM to the runner before containment (143, the tripwire in its uncontained shape, no marker),
  the same with `run` and the logs, or the folder, replaced by links first (nothing written or
  copied through them, off Windows), a copy of the pre-pass backup that fails after leaving an old
  one (exit 1, no agent, no backup left), an in-flight marker a dead pass left (78, the uncontained
  shape, no agent) and `snap_untrusted` with no backup (a unit row). It also covers, under the
  suite's names: `twlink`, a tripwire in the vault and both logs links to a file outside, as a
  pass that ended at 78 leaves them (78, no agent, the file as it was, the refusal and a
  `WARNING:` in the state directory's log), and `inflightlink`, the same with an in-flight marker a
  dead pass left (78, the file as it was, the tripwire saying the log was moved), each with the
  runner warning about its `RUN_LOCK_WAIT` before the lock is held, a line only the check before
  the lock keeps out of the link; for the
  retention runner, a tripwire and its log a link to a file outside (78, the file as it was, the
  refusal and a `WARNING:` in `vault-retention.uncontained.log`, and the `WARNING:` exactly once in
  its printed lines), again with no temporary folder to be had and a lock warning logged before
  the lock is held (that line not written through the link either, and its printed line saying it
  could keep no copy of its lines and naming that log), and `marker`, the same with a dead pass's
  in-flight marker in place of the tripwire (78, the file as it was, the lines and a `WARNING:` in
  that log, and the `WARNING:` once in its printed lines); for each runner, its log made a link to
  a file outside while it waited for the run lock, which a stand-in owner held, not aged, with a
  tripwire in the vault and a `RUN_LOCK_WAIT` the runner warns about as it starts to wait, which
  shows the run is past its first check (78, the file as it was, the refusal and a `WARNING:` in
  the state directory's log); `sigtrap`, the links made by the stand-in in its own TERM handler,
  so only once the runner stops the tree (the file as it was, the tripwire saying the log was
  moved); `sigrmdir`, the stand-in removing the runner's folder, sending its runner TERM and
  staying (143, the stand-in stopped all the same, the leg first checking that `ps` shows the
  suite's own shell); `tmplink`, a link to a file outside at the name the tripwire's copy used to
  take from the runner's pid, then TERM (the file as it was, the vault's tripwire a file);
  `twdirlink`, a link to a folder at the tripwire's own name, then TERM (nothing moved into that
  folder, the vault's tripwire a file); `sigtwfail`, folders where both copies of the tripwire
  go, then TERM (143, the `TRIPWIRE-ERROR:` line with its no-git sentence, the in-flight marker
  kept); `logdir`, folders at both logs' names, then the folder
  removed (78, the lines and a `WARNING:` in the state directory's log, the tripwire saying so);
  `logsdirlink`, `logsfile` and `claudelink`, `.claude/logs` moved and a link to it in its place,
  `.claude/logs` a file, and `.claude` a link to a copy of itself (78, the lines in the state
  directory's log, only the state directory's tripwire, nothing written through a link);
  `backuplink` and `backupnone`, a copy of the pre-pass backup that succeeds leaving a link, or
  nothing, at its name (exit 1 with the `ERROR:` line, no agent, nothing left there); and
  `backupseed`, a link to a file outside already at the backup's name, in a state directory made
  before the run (the pass ends 0, the file as it was). `sigdirlink` now also needs nothing of the
  stop recorded through the link at the folder, and `sigterm` its lines in the vault's log and no
  moved-log note, a control that the log is not moved when nothing is a link. Ten unit rows hold
  `log_outside_links` with `.claude/logs` a file and `LOG_MOVED_NOTE` exported before the library
  loads (cleared at load, the log moved once, a second call changing nothing, one `WARNING:` naming
  the vault's log); `note_tripwire` with `.claude/logs` a link, in one row with a tripwire file
  where the link points and in one without (the note in the state directory's copy only, and
  nothing written through the link; each row first checks that the link was made);
  `mark_inflight` with a link at `runner-inflight.tmp.<pid>` (the vault's marker a file, the file
  the link named as it was); `write_vault_copy` with no `mktemp` and a link at
  `runner-tripwire.tmp.<pid>` (the copy a file, the file the link named as it was), and with no
  `mktemp` and a link to `/dev/null` already at the name `$RANDOM` gives, seeded (refused, nothing
  at the copy's name), each first checking that its `mktemp` stand-in took; with a link to a
  folder at the copy's name that `rm` cannot remove (an `rm` stand-in that removes nothing:
  refused, nothing moved into the folder); with no `mktemp` and a link put at the `$RANDOM` name
  between the check and the write, by a DEBUG trap the write's subshell inherits (refused, the
  file the link named as it was); and, with no copy of
  the tripwire writable, `snap_untrusted`, and `tripwire_check` with a dead pass's marker (each
  70, the `TRIPWIRE-ERROR:` line saying to run no git command in the vault before the steering
  surfaces have been checked). Of the legs and rows named from `twlink` on, these run on Windows:
  `logdir`, both runners' `backupnone` and `sigtwfail`, `sigterm`'s new requirements, the
  `log_outside_links` row and the two `TRIPWIRE-ERROR:` rows; the rest run off Windows only.
  The legs that end 78 because the runner's folder changed, with a tripwire in the vault, also need
  the `UNVERIFIED:` line to say that no git command is run in the vault before the steering surfaces
  are checked, and their tripwire, that of every signal leg that writes one and that of the
  `inflight` leg now need the advice: git that starts on its own, the
  comparison without git with `--no-dereference` (where a backup is there), the line on a `.git`
  deeper in the vault, the line on links in `.claude/logs` or at `.claude`, and the first
  `git -c core.fsmonitor=false` status. Of the other 78 legs, `logsdirlink`, `logsfile` and
  `claudelink` need the no-git sentence in the state directory's tripwire, the only copy written,
  but not the advice, `inflightlink` needs neither, and `twlink` refuses a tripwire the suite wrote,
  so neither applies. The first kind also need the tripwire to say that the runner's folder for the
  pass is kept for the review, naming that folder, and the folder still there with its steering
  backup in it once the runner has exited, unless the leg removed it itself; `logsdirlink`,
  `logsfile` and `claudelink`, whose legs remove it, need the sentence and the name. `sigterm`
  needs each runner's run output kept in the state directory, its stand-in first printing a line
  and seeing it in `run`. The promotion runner takes the `rmdir`, `rmslow`, `hooks`,
  `dirlink`, `runlink`, `rmstall`, `cksum`, `badname`, `loglink`, `sigterm`, `sigrunlink`,
  `sigdirlink`, `backupfail`, `sigtrap`, `sigrmdir`, `sigtwfail`, `twlink`, `inflightlink`,
  `backuplink`, `backupnone` and `backupseed` legs. Each new runner leg was seen failing against
  1.4.1's code on its own assertion, and so were `sigdirlink`'s new need, both `note_tripwire`
  rows, `mark_inflight`'s row and `tripwire_check`'s `TRIPWIRE-ERROR:` row (70, the line without
  that sentence), except `logdir`, `logsdirlink`, `logsfile` and `claudelink`, which reach 78
  through the folder check 1.4.1 lacks, so they say nothing about 1.4.1's log (a write through a
  link at `.claude` or `.claude/logs` is reasoned for 1.4.1); the `log_outside_links` row,
  `snap_untrusted`'s `TRIPWIRE-ERROR:` row and the four `write_vault_copy` rows, whose functions
  1.4.1 lacks, were seen failing against mutants of this release. So were the kept-folder
  requirement (with `on_exit` removing the folder, or only its steering backup, in either runner,
  and with the sentence changed or naming another folder), a promise 1.4.1 does not make, and
  `sigterm`'s run output (with either runner's signal path keeping none), which until now only the
  dream runner's legs asserted.
  `state-shown` covers all three forms of the tripwire refusal (a tripwire in the vault only, a
  tripwire file in the state directory, and a folder where the state directory's copy goes) with a
  state directory named with a line break and an escape (off Windows); and `git-dir-pass`'s
  retention leg needs the run's move of an aged journal committed in the vault with its
  `Vault-Pass: retention` trailer. Eleven
  existing comparisons of the settings file's exact bytes now expect the new line, and two existing
  controls, `mem-override-mixed-release` and `mem-override-settings-space`, now set
  `SNAP_SEALS=sealed` after loading the library, which takes them past `run_agent`'s new refusal.

### Adopting this

1. **Take `.claude/scripts/lib/runner-common.sh`, `dream-pass.sh`, `promotion-pass.sh` and
   `vault-retention.sh` together.** With the 1.4.2 library and 1.4.1's dream or promotion runner,
   every pass, in either mode, exits 1 before its agent starts, with no tripwire, and the run log
   (`.claude/logs/dream-agent.run.log` or `promotion-agent.run.log`) says `no record of the
   runner's folder for the pass was taken before the agent started`; in claude mode the memory
   override is written first. 1.4.1's retention runner runs with the 1.4.2 library, and gets
   neither its refusals nor its `TMPDIR` rule. With 1.4.1's library and a 1.4.2 runner, every runner
   exits 1 before its agent, with `git_env_warning: command not found` and `vault_root_spelling_ok:
   command not found` on its stderr, not in its log. (All measured on Linux, for each runner and
   mode, with 1.4.1's files.)
2. **Nothing to configure for most vaults.** A vault whose `.claude` or `.claude/logs` is a link,
   or does not list as `drwx`, reads step 8 first; a command-mode schedule reads step 9.
3. **A runner refuses to start while the vault's path, on Windows or with a `cygpath` on `PATH`,
   holds a part ending in a dot, a colon that is not a drive letter's, or a last part ending in a
   space.** The log says `ERROR: the vault, …, is spelled with a part that ends in a dot`. Rename the
   folder, or reach the vault through a path with none of these. The `.cmd` wrappers cannot reach
   such a vault (reasoned); a Git Bash prompt can.
4. **A runner refuses to start while its temporary folder is not an absolute path, or, on Windows
   or wherever a `cygpath` is found on `PATH`, holds a colon that is not a drive letter's.** The log
   says `is not an absolute path, so it was made inside the vault` or `is spelled with a colon that
   is not a drive letter's`. Point `TMPDIR` at an absolute folder outside the vault, or leave it
   unset. The retention runner uses `TMPDIR` only when it starts with `/` (otherwise `/tmp`, now for
   its temporary files too), so it cannot meet the first line through `TMPDIR`. It now refuses with
   `could not create a temporary directory` (exit 1) when neither an absolute `TMPDIR` nor `/tmp`
   can hold its folder, where 1.4.1 fell back to a plain `mktemp -d`; make one of them writable.
5. **A pass whose runner's folder changed while the agent ran now exits 78**, with `UNVERIFIED: the
   runner's own folder for the pass, …, was changed while the pass ran`. Nothing was moved or
   restored, so `.git/config`, `.git/hooks` and `.obsidian/` may still hold what the pass planted
   (reasoned). Until you have reviewed the vault, do not open it in Obsidian or an agent session,
   and run no git command in it before the steering surfaces have been checked, git that starts on
   its own included: a shell prompt that shows git state, or an editor with git integration. First
   copy the pre-pass backup in the state directory, `inflight-backup.tar`, because the next pass
   replaces it. Compare the steering surfaces, those three among them, with it without git: unpack
   the copy into an empty folder with `tar -xf`, compare that folder with the vault with `diff -r`
   (with `--no-dereference` where your `diff` has it, so a link is compared rather than followed),
   and put back what differs. When the line says no backup was made, check them by hand. Where
   `.git` is a file (a linked worktree), the git folder it names is outside the vault and outside
   the backup, so check its config and hooks by hand as well. A `.git` deeper in the vault is a
   steering surface too, and `diff -r` shows a new one only as a new folder above it: list every
   `.git` with `find . -name .git`, and check the config and hooks of any you did not make. A link
   in `.claude/logs`, or `.claude` itself as a link, is in neither the backup nor git: list them
   with `find .claude -type l`, and remove any you did not make once you have checked what it
   names. Then review the rest of
   the vault; where it is a git repository, start with
   `git -c core.fsmonitor=false --no-pager status --ignore-submodules=all`, which starts no
   fsmonitor command or pager and stays out of repositories nested in it. The folder named in the
   line is kept for the review. Last, delete the tripwire as for any other. When no tripwire could
   be written the exit is 70 instead, with a `TRIPWIRE-ERROR:` line in place of the `UNVERIFIED:`
   one and the in-flight marker kept; the vault is as unrestored as at 78, so review it the same
   way, because the only advice that line gives, as do the ones a signal before containment and a
   run that finds a dead pass's marker log when they cannot write the tripwire, is "Treat the vault
   as unverified, and run no git command in it before the steering surfaces have been checked." A
   tripwire set by a signal before containment (the log says
   `INTERRUPTED before containment. Tripwire set.`), or from an in-flight marker a pass that died
   left, now says "Nothing was moved or restored, because containment did not run." and gives the
   same advice: follow it before any git command. After a signal before containment, at 78, and on
   a later run that finds the tripwire or the passes' in-flight marker (`runner-inflight`), when the
   vault's log, `.claude` or `.claude/logs` is a symbolic link, `.claude/logs` is not a folder, or
   the log is
   there and not a file, the rest of the run's lines are in `dream-pass.uncontained.log`,
   `promotion-pass.uncontained.log` or `vault-retention.uncontained.log` in the state directory. A
   hard link or a FIFO at a log or at `dream-pass.git-state.txt`, and a symbolic link containment
   cannot move, are still open and carried to a later release (see Security); keep command-mode
   passes without a shell, with no hook running and, where the harness itself can run git (assume
   any can), unable to write the vault's `.git` or, with the commit gate on, its `.claude/`, as
   `docs/setup.md` and step 9 say. A later run checks before it takes the run lock and again once it
   holds it. The lines any runner logs before its first check (a setting's warning, the
   state-directory error, the `WARNING:` naming the git variables it cleared, or the `ERROR:`
   refusing the vault's spelling) still go to the vault's log path, and so do those a dream or
   promotion run, or a retention run that could keep no copy of its lines or was stopped while
   waiting, logs while it waits for the lock, unless the first check already moved the log. A runner
   that cannot record its folder before the agent starts exits 1 with
   `the runner could not record its folder for the pass`, and the line names the six causes: the
   folder missing or a link, a name in it outside letters, digits, dot, underscore and hyphen, a
   file it could not checksum, a folder in it that could not be listed, no `sha256sum`, `shasum` or
   `cksum` found, or a record that came out empty. Find what wrote into the runner's folder, put
   `sha256sum` or `shasum` on the task's `PATH`, and point `TMPDIR` at a folder only this account
   can change. A runner that finds no `sha256sum` or `shasum` logs a `WARNING:` and checks the
   folder with `cksum`. A runner that cannot copy the pre-pass backup to the state directory exits 1
   with `could not copy the pre-pass backup of the steering surfaces to the state directory`, before
   the in-flight marker and the agent: free space there, or remove what is at the path the line
   names once you have checked that it holds nothing you still need.
6. **Hooks are off in claude-mode passes.** That includes plugins' hooks and the vault's own
   (measured on 2.1.301), and the account's own user-level hooks, any guard hook among them
   (reasoned: the probe held none, nor any in an agent's or a skill's frontmatter, so do not count
   on a user-level guard hook running in a pass, or on its being off): the agent no longer gets
   `vault-lint.sh`'s advice after each write (the runner still checks the notes a pass wrote with
   `vault-check.sh` before committing them), and no compaction stub is written during a pass. Hooks
   from managed settings still run (measured on an earlier version), and so do MCP servers
   (reasoned). Command mode is unchanged: a
   wrapper that starts Claude Code gets neither the memory override nor the hook switch.
7. **Settings a parent git passed down with `-c` (in `GIT_CONFIG_PARAMETERS`), and those set
   through `GIT_CONFIG_COUNT`, no longer reach a pass, `safe.directory` among them**; put such a
   setting in the account's global git configuration. A `git` wrapper on `PATH` that adds `-c` to
   every call is not affected. A vault git reached only through `GIT_DIR`, with no `.git` entry of
   its own, now reads as no repository: dream and promotion passes run without committing, and the
   retention runner refuses (reasoned). A `.git` file in the vault naming its git directory
   (`gitdir: <path>`, with no part ending in a dot) would let git find it (reasoned). The runner's
   `WARNING:` names the variables it cleared. A command-mode wrapper no longer inherits git's
   per-repository variables or the MSYS switches (`MSYS_NO_PATHCONV`, `MSYS2_ARG_CONV_EXCL`,
   `MSYS2_ENV_CONV_EXCL`), because the library clears them as it loads; a wrapper that needs one
   sets it itself.
8. **`/resume`**: take both copies of `.claude/skills/resume/SKILL.md` (`.claude/` and `.agents/`)
   together, as the control suite requires them byte-identical.
   **If your `.claude` or `.claude/logs` is a link** (to keep the logs out of a sync, for example),
   **or does not list as `drwx`**, `/resume` now stops at its first step on every run,
   and so does an agent that follows `AGENTS.md` in an interactive session, because the runners
   may then write their tripwire to the state directory only. Look for `runner-tripwire` in the
   state directory yourself before you start a session there, without running any of the vault's
   scripts: the state directory is a folder under `claude-memory-vault/` in the account's state
   folder, `VAULT_STATE_DIR` when you set it, or, when neither can be used,
   `claude-memory-vault-state-<id>` under `TMPDIR` or `/tmp` (`docs/reference.md` §4.3), so
   `ls <state folder>/claude-memory-vault/*/runner-tripwire`,
   `ls "<the VAULT_STATE_DIR the scheduled task sets>/runner-tripwire"` or
   `ls "${TMPDIR:-/tmp}"/claude-memory-vault-state-*/runner-tripwire` (the scheduler's `TMPDIR`)
   finds it (the globs list every vault's folder). Clear one as for any other. Making the folder a
   real one that lists as `drwx` afterwards (for example with `chmod u+rwx`) stops `/resume`
   stopping, but does not show a tripwire set before.
9. **A command-mode wrapper built from the Codex, Copilot, Cursor, Hermes or OpenCode guide** may
   have left the promotion pass a shell, because those guides took it away for the dream pass
   only. Take it away for both passes, as `docs/setup.md` asks: the Codex guide's wrapper now
   gives both passes its profile with the shell tool off, and the OpenCode guide's wrapper selects
   the agents `vault-dream` and `vault-promotion`: define both, with `bash` and `webfetch` denied,
   deny any other tool an agent lists that can run a command or reach the web, and run the guide's
   check that each refuses a shell command with no fallback warning, before you take it. Keep
   each pass's tools writing only inside the vault. **Any command-mode wrapper**, from any guide,
   must also run with no hook, because a pass can change the script a hook runs and get a shell
   through it (reasoned); keep the wrapper, the container definition and every file they name
   outside the vault and every folder a pass can write, because the runner starts what
   `VAULT_AGENT_CMD` names outside every sandbox (`docs/setup.md` §8). Remove
   `VAULT_ALLOW_UNENFORCED_TOOLS=1` from the scheduled task (or disable the task), follow your
   harness's guide, and set it again only once the check in `docs/harnesses/README.md`, "No vault
   hook in a scheduled pass", passes, including its new step that confirms, by their resolved paths,
   that the wrapper, the container definition, the switch file and the files they rest on, the home
   folders of the account the runner runs as (the one the schedule's environment names and the
   account's own, where they differ; on a switch route, the harness's too, the one the wrapper names
   among them), and every file of the class `docs/setup.md` names in its `UNVERIFIED`
   troubleshooting row that the runner or the harness reads at the per-user or the system level, or
   place named for one (in a container, outside the vault's mount too, with no other mount of a
   folder or file of the vault at or above them, the README's step 5 saying which), lie outside the
   vault and the copy (one inside, by any of its names, fails the check, and so does a folder this
   check requires outside both, or on a switch route a folder that holds the switch file or the
   wrapper, that holds the source of a mount from outside both whose target lies below the vault's
   or the copy's own folder), each file with a single name (a link count of 1) or each
   of its names found outside both, and no file or folder among them at or under a folder or
   file of the vault mounted elsewhere on the host, nor at or under the source of a mount from
   outside both into the vault or the copy, by the host's own list of mounts read as the README's
   step 5 says (each source and target spelled as an absolute path on the host, a source another
   listed mount also shows spelled through that mount as well, the list seen to show the mount that
   holds the vault, and a source spelled through another mount or on a share this host serves seen
   to show what its target shows; a list of mounts that cannot be read or does not show the vault's,
   a source that cannot be spelled or seen that way, or a pass-through file system, such as an
   overlay, not a bind mount or a share, mounted below the vault's or the copy's own folder leaving
   the step not verified), once a path inside the copy and one inside the vault have each read as
   inside, each spelled every way the paths compared reach the check, whether a file or a link's
   target spells them so (a short 8.3 name, another letter case, a substituted or mapped drive, a
   second path the host gives a folder above the vault or the copy, as WSL does for the
   distribution's root by default), unless the resolver used is seen, on that host, to turn each
   such spelling of the vault's and the copy's paths into the one compared, that the host's own list
   shows no mount at or under the vault's or the copy's `.git` or `.claude/`, nor any whose source
   lies there and whose target lies elsewhere in either (on a switch route, one whose target lies
   outside both leaving the step not verified), nor a mount of a folder or file of either at or
   under a copy outside both that the definition mounts read-only, and that no link below their
   `.git` or `.claude/` leads outside the one it lies below (the links listed only once the listing
   has shown control links made for the purpose in the copy's `.git` and `.claude/`, each to a
   folder outside both, a listing that does not show every one of them, or that cannot be made,
   leaving the step not verified, and on Windows a symbolic link, where the account cannot make one,
   stated open; where `.git` or `.claude/` is a link, or `.git` a file, the folder it resolves to or
   names, and any shared folder that one names, standing in its place and lying outside both, and,
   on a switch route, a vault whose `.git` or `.claude/` stands in that way leaving the step not
   verified; a file at or under `.git` or `.claude/` with a second name outside that folder, as a
   clone's shared object files have, not looked for, reasoned and carried), that the harness runs as
   a user other than the superuser (on Windows, not run elevated), and, on the scratch copy, that
   writes into `.git` and `.claude/` are refused, and, in a container, from the definition, that
   each run starts a new container, which the runtime removes at exit, and that the definition names
   every mount the README's rule and the guide require; from the container runtime's own listing,
   that every mount over or inside the vault but the vault's own, every mount of a file the wrapper
   or a switch rests on, and every mount over a hook or settings file a harness reads from the
   container's home, is read-only, that any other writable mount is discarded at exit, never a
   folder or volume kept between runs, and that no mount of a folder or file of the vault, the
   vault's own and those over or inside it apart, lies at, above or inside the home folder of the
   harness's user (the README's step 5 says which); from a shell opened in the container as that
   user, that its home folder lies outside the vault's mount and that a write to each hook or
   settings file the guide mounts in that home is refused; and from that shell's own list of mounts,
   once it shows the definition's read-only `.git` mount with its source in the vault (in the
   check's run, the copy's), that every mount at or under one that must be read-only is read-only
   too, and that none of them but the `.git` and `.claude/` mounts has a folder or file of the vault
   or of the copy as its source (a source read as a file system and a path within it, those of the
   vault, the copy and any folder of either located from the host's own list, and the step not
   verified where that cannot be told). The Codex profile gains `hooks = false` (and the wrapper
   never passes `--dangerously-bypass-hook-trust`); the Gemini CLI guide sets `hooksConfig.enabled`
   to false in a settings file outside the vault, in a folder the sandbox does not let a pass write;
   for both, whether the sandbox leaves the vault's `.git` writable to a pass, or, with the commit
   gate on, its `.claude/`, or the folders that hold that profile or settings file and the wrapper,
   or the home folders of the accounts the runner and the harness run as (those the schedule's
   environment and the wrapper name as homes, and the accounts' own), or, for Gemini CLI,
   `~/.gemini/`, is still to check: that step confirms part of it through each of the harness's own
   tools for creating files, a new file in each folder, and where it does not confirm all of them
   refused, or the sandbox's documentation or profile opens to a pass's writes any file or folder
   under those home folders outside the vault and the copy, or does not say which it opens, use the
   README's container; files of that class that lie outside the vault and those home folders, at the
   per-user level or the system level, are not sampled, and rest on the sandbox's documentation and
   the account's own permissions (reasoned; carried). The Copilot, Cursor, Hermes and OpenCode
   guides keep the hooks out of their container (Copilot's and Cursor's mount `.claude/` with its
   `settings.json`, and any `settings.local.json`, from hook-free copies) and mount `.claude/` and
   the vault's `.git` read-only there (OpenCode all of `.opencode/` and `opencode.json` too), and an
   empty file read-only over its `.env` (if the vault has none, create an empty one there yourself
   first); a Cursor schedule also mounts, read-only, files holding no hooks over
   `~/.cursor/hooks.json` and `~/.claude/settings.json` in the container's home; a Pi schedule
   mounts `.claude/` and `.git` read-only as well, and empty files read-only over its `.env` files
   (if the vault has no `.env`, create an empty one there yourself first), and runs the check with
   the vault's extension as its positive control; an Aider schedule moves `aider-scheduled.conf.yml`
   outside the vault with absolute `read:` paths, takes its new `git: false`, `auto-lint: false`,
   `git-commit-verify: false` and `auto-commits: false` lines, mounts the vault's `.claude/` and
   `.git` read-only and an empty file read-only over its `.env` (if the vault has none, create an
   empty one there yourself first), and runs the guide's check with its `pre-commit` canary, its
   git-configuration one, and the control that turns git back on. For any container schedule, start
   a new container for each run, whose own filesystem is discarded at exit, never one kept between
   runs, and run the harness in it as a user other than the superuser, with that user's home folder
   outside the vault's mount, with no other mount of a folder or file of the vault at, above or
   inside it (the README's step 5 says which; in the definition, the image, or the entrypoint or
   wrapper that sets it): the new container closes only the next run, and within a run the
   container's own filesystem stays writable.
10. The shipped files this release touches: `.claude/scripts/lib/runner-common.sh`,
   `.claude/scripts/dream-pass.sh`, `.claude/scripts/promotion-pass.sh`,
   `.claude/scripts/vault-retention.sh`, `.claude/scripts/run-tests.sh`,
   `.claude/skills/resume/SKILL.md`, `.agents/skills/resume/SKILL.md`, `docs/reference.md`,
   `docs/setup.md`, `docs/agent-onboarding.md`, `docs/harnesses/claude-code.md`,
   `docs/harnesses/README.md`, `docs/harnesses/aider.md`, `docs/harnesses/codex.md`,
   `docs/harnesses/copilot.md`, `docs/harnesses/cursor.md`, `docs/harnesses/gemini-cli.md`,
   `docs/harnesses/hermes.md`, `docs/harnesses/opencode.md`, `docs/harnesses/pi.md`,
   `AGENTS.md`, `.claude/scripts/vault-check.sh` (a comment), besides `VERSION` and
   `CHANGELOG.md`, which move on every release.

## 1.4.1 — 2026-10-13

A security fix for the dream and promotion passes in claude mode. Claude Code's memory folder for
a pass is now pointed inside the vault, where the write fence sees it. On Windows that holds for a
vault on a drive path, and a vault on a `//` network path is refused instead. Measured for the
Write tool on Windows, with ASCII and non-ASCII vault paths; Linux and macOS are unverified. On
Windows, or wherever a `cygpath` is found on `PATH`, every runner, the retention runner included,
also refuses in every mode a temporary folder spelled with a `..` or with a part ending in a dot,
which git there can read as another folder.

### Security

In 1.4.0 a claude-mode pass could write memory **outside the fence**. Claude Code grants the
agent's Write and Edit tools its memory folder: the folder a settings file names as
`autoMemoryDirectory`, or by default one under `~/.claude/projects/` for the vault's path. The
default folder lies outside the vault, and a named one may too. Memory kept there is meant to be
read by later Claude Code sessions, which this release did not measure. The runner's
`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` does not withdraw the grant, although `docs/reference.md` and
the runner's comments said the pass wrote no memory.

Each claude-mode pass now gets a settings file of the runner's own, passed with `--settings`. It
points the memory folder at `90-auto-memory/.pass-agent/`, inside the vault and inside the fence.
What that covers, and what it does not:

- **A folder the vault's local settings name is no longer granted.** Measured on Windows with a
  probe agent, for an ASCII vault path: a Write to the folder `.claude/settings.local.json` named
  as `autoMemoryDirectory` landed without the runner's file and was refused with it. A folder named
  in the project's `.claude/settings.json` was not measured; a `--settings` file outranks it in
  Claude Code's settings precedence.
- **The default memory folder is no longer granted to a vault on a drive path.** Measured on
  Windows the same way, for an ASCII vault path on a drive, and for one on a drive mapped with
  `net use` to the measuring host's own administrative share (`\\localhost\c$`), started through
  `dream-pass.cmd`: a Write there landed without the runner's file and was refused with it.
- **A vault on a `//` network path is refused, because the file does not protect it.** For a vault
  reached as `//localhost/c$/...` (the measuring host's own administrative share) or
  `//wsl.localhost/...` and started from Git Bash, Claude Code 2.1.289 and 2.1.292 ignored the
  runner's file: a Write to the default memory folder landed with it as without it (measured; a
  share on another server is unmeasured, and refused all the same). On Windows the runner now
  accepts only a drive path for the vault and for its settings file, and refuses any other with
  exit 1. The `.cmd` wrappers could not
  start such a vault before either. A mapped drive was measured for one mapping only, to the
  measuring host's own administrative share; a drive mapped to another server is unmeasured, and
  for the vault, any other drive letter whose target is a network path (DFS, WebDAV, a local link
  to a share, `subst` onto one, a drive mapped to `\\wsl.localhost\...`) is accepted too and
  unmeasured.
- **A vault path that is not ASCII is converted faithfully.** On Windows the runner converts the
  vault's path, and the settings file's, with Git Bash's `cygpath`. Under the runners' `LC_ALL=C`
  that cuts a path at its first character outside the ANSI code page and turns `é` into one invalid
  byte, so the file would name a folder outside the vault, and a Write there landed (measured). The
  conversions now run under a UTF-8 locale, and the pass refuses unless each converted path names,
  converted back, the folder or file it came from. Measured with real Claude Code for vaults under
  a folder named in Cyrillic and one holding a Git Bash `"` (2.1.287, 2.1.289, 2.1.292, 2.1.295 and
  2.1.296), and, in one run on 2.1.287 against an earlier build, one named `José`: a Write to the
  folder the C-locale conversion named landed with that conversion's file and was refused with the
  new one.
- **A memory folder named in your user settings is unmeasured.** Measuring it would have meant
  editing someone's user settings. The fix rests on settings precedence there too: a `--settings`
  file outranks user settings.
- **Managed settings are outside this fix and unmeasured.** Claude Code ranks them above
  `--settings`, so a memory folder set there would not be overridden.
- **An agent definition's own `memory:` key is outside this fix and unmeasured.** The template's
  agents set none.
- **Edit is unmeasured.** Only the Write tool was probed under the runner's file. Edit is granted
  the same folder by the same setting.
- **An empty or invalid settings file fails open in Claude Code.** Claude Code 2.1.287 reads one as
  if there were none, with exit 0 and nothing on stderr, and grants the folders outside the vault
  again (measured; not re-run after 2.1.287). The runner reads its file back byte for byte before it
  starts the agent and refuses on any difference, but a change made between that read and Claude
  Code's is not seen, nor one Claude Code might read later in the pass (whether it re-reads the file
  is unmeasured). So the file is not kept in the state directory, which may be shared or, on
  Windows, take its parent's permissions: it is written, by its resolved path, in the runner's own
  folder for the pass, which must pass the checks the state directory gets and an identity check of
  its own, which only the runner's account can enter on Linux and macOS, and which on Windows
  carries the temporary folder's permissions, under the per-user default the account's, SYSTEM's and
  Administrators' (measured). Whoever can change `TMPDIR`, a folder above it or what lies under it
  (another account that owns a folder above it, or can write one through a group or an access
  control list, is not refused) could already change what the pass keeps in that folder since 1.4.0:
  its snapshots, its steering backup, which is restored into the vault on containment, and, in a git
  vault, the folder git takes hooks from. The settings file adds one there whose hooks Claude Code
  would run as your account at every claude-mode pass (a settings file can name hooks; not probed
  here), whether or not the vault is a git repository.
- **The settings file goes in the folder `mktemp -d` made, however `TMPDIR` is spelled through
  links, and on Windows a temporary folder spelled with a `..` or with a part ending in a dot is
  refused before git runs.** An earlier build of this release resolved the folder above it with a
  logical `cd`, which takes a `..` after a link as text. With `TMPDIR` spelled `<folder>/<link>/..`
  it named a folder `mktemp` never made, so the pass was refused as if its folder had gone (measured
  on Linux, and in Git Bash through a junction), and where a folder of that name had been made
  beforehand in the link's own folder it checked that folder instead and wrote the settings file
  there (measured on Linux; in Git Bash such a pass ran on to the commit). The folder above is now
  resolved as `mktemp` resolves it (`cd -P`), and the pass is refused when the path so resolved is
  not the folder as given, compared by file identity. That covers the settings file only: the
  snapshots, the steering backup and git's hooks folder are still reached through `TMPDIR` as
  spelled, as in 1.4.0. On Windows git reads that spelling as text, so with a `..` after a junction
  in Git Bash's `/c/...` spelling it took its hooks folder and the commit message from a folder of
  the textual name, and the journal commit failed (exit 4): a `pre-commit` hook placed in a folder
  of that name ran (measured in Git Bash, with a stand-in agent, on 1.4.0 and on earlier builds of
  this release, `53b728b` and `753e1f9`), and so did a `post-index-change` hook, at the pass's first
  `git status` (measured on 1.4.0, and on `b4d1344`, which refused such a pass in claude mode only,
  after that `git status`). In the `C:/...` spelling Win32 reduces the `..` for `mktemp` as well,
  and the two agreed (measured). Win32 also drops the dot that ends a part, so with `TMPDIR` spelled
  `<folder>/x.` git looked for its hooks in `<folder>/x` (measured in Git Bash on 1.4.0 and
  `b4d1344`; spawning the hooks placed there failed, and so did the commit). The `C:/...` spelling
  does not help there: `mktemp` keeps the dot in it too, and git, given that spelling, looked for a
  hook in `<folder>/x` and not in the folder `mktemp` made (measured in Git Bash with git alone). On
  Windows (and wherever a `cygpath` is found on `PATH`, as for the override) the dream, promotion
  and retention runners now refuse a temporary folder spelled with a `..` or with a part ending in a
  dot, in either spelling, right after `mktemp` makes the folder git is given, before their first
  git call, in every mode, command mode included (measured in Git Bash: for a dream pass with a
  stand-in agent; and with the suite's twin, on the measuring host and on CI's windows-latest, for
  a `..` with the dream and promotion runners in claude and command mode and the retention runner,
  for a part ending in a dot with the dream runner in claude mode only, and through the check
  itself for 18 spellings; the twin records no git call naming the folder before the refusal. That
  no hook placed there ran tells this release from earlier builds for the dream and promotion
  runners' `..`, where an earlier build ran them, and not for the retention runner or a part ending
  in a dot, where the earlier builds measured ran none either). The retention runner takes `TMPDIR`
  only when it starts with `/`, so for a `C:/...` spelling it makes its folder under `/tmp`
  instead, as in 1.4.0, and has nothing to refuse unless no folder can be made under `/tmp` either
  (reasoned from the code).
  A part that is `.` alone is not refused: Win32 and Git Bash both read it as the folder it is in
  (reasoned). Claude Code itself keeps the dot: handed `--settings <folder>/x./s.json`, 2.1.296 read
  that file, not `<folder>/x/s.json` (measured); its memory folder is reached the same way
  (reasoned; not measured for the Write tool).
- **Linux and macOS are unverified.** No Claude Code run has measured the grant on either. There the
  runner refuses a vault or settings-file path that does not come back byte for byte when `iconv`
  converts it from UTF-8 to UTF-16LE and back, which Claude Code could read as another folder:
  invalid bytes, surrogates, overlong forms, code points above U+10FFFF and 5- and 6-byte forms. An
  earlier build's one-way check, to UTF-16LE, was measured refusing such vault names on Linux (glibc
  2.43) with a stand-in agent; the round trip, for the vault's path and the settings file's, is held
  by the suite's twins on CI's Linux and macOS jobs. glibc 2.43's conversion to UTF-8, which an
  earlier build of this release used, let code points above U+10FFFF and 5- and 6-byte forms
  through (on CI's ubuntu-latest the one form its job asks about, a code point above U+10FFFF, went
  through too), and macOS's `iconv`, under the C locale the runners set, takes them to UTF-16LE
  without an error (measured on CI), which is why the result must also convert back.
- **Measured on Claude Code 2.1.284 (a named folder), 2.1.285 and 2.1.287 (a named folder and the
  default one, and on 2.1.287 the non-ASCII paths), 2.1.289 (the named and default folders,
  the Cyrillic and `"` vaults, glob and trailing-dot names, a drive root (on an earlier build of
  this release), a drive mapped to the host's own administrative share, and the network paths it
  does not honour), 2.1.292 (the named and default folders, the Cyrillic and `"` vaults, glob and
  trailing-dot names, that mapped drive and the network paths, on an earlier build of this
  release), 2.1.293 (starting with a settings file under a non-ASCII temporary folder, on that
  build), 2.1.295 (the named and default folders, the Cyrillic and `"` vaults and starting with
  a settings file under a Cyrillic `TMPDIR`, on the earlier build `53b728b`), and 2.1.296 (the
  same, with this release's runner, and which file a `--settings` path through a folder ending in a
  dot names, Claude Code started on its own).** No other version was measured.
- **Memory only.** A folder a settings file grants through `additionalDirectories` stays outside
  the fence, as in 1.4.0.

### Changed

- **Both runners write `pass-settings.json` into their own folder for the pass before a claude-mode
  pass**, the one each already makes with `mktemp -d` for its snapshots, under `TMPDIR` or `/tmp`
  (on macOS in the per-user temporary folder, where Apple's `mktemp` makes it even when `TMPDIR`
  names another folder, measured on CI), and removes when the pass ends. They start the agent with
  `--settings <that file>` just before `--disallowedTools`, the file named by its folder's resolved
  path, the folder above it resolved as `mktemp -d` resolves it (`cd -P`), so a link in `TMPDIR`'s
  spelling, or a `..` after one, cannot be pointed elsewhere after the checks. The file holds one
  key, `autoMemoryDirectory`. On Linux and macOS it is written readable by the runner's account
  only, whatever the umask, in a folder only that account can enter, because a settings file can
  name hooks Claude Code runs; on Windows it carries the temporary folder's permissions. The folder
  gets the state directory's checks first, and a check that it is not inside the vault by file
  identity (Adopting 15). A `pass-settings.json` that an earlier build of this release left in the
  state directory is removed by the next claude-mode pass whose folder passes its checks, just
  before the check for names planted there. The runner never creates `.pass-agent/` itself. Command
  mode is unchanged, apart from `AGENT_SETTINGS_FILE` being unset when the runners' library loads
  and, on Windows or wherever a `cygpath` is found on `PATH`, the refusal of a temporary folder
  spelled with a `..` or a part ending in a dot (next item).
- **On Windows the dream, promotion and retention runners refuse a temporary folder spelled with a
  `..` or with a part ending in a dot**, in every mode, with exit 1 and an `ERROR:` line saying
  `is spelled with .. or with a part that ends in a dot`, right after each makes the folder git is
  given and before its first git call, because git there would read that spelling as another folder
  (Security). The override checks it again for any other caller. Elsewhere the runners are
  unchanged by it, unless a `cygpath` is found on `PATH`, which makes every runner treat the
  platform as Windows here, as the override does.
- **A claude-mode pass now needs `cmp`, and `iconv` for a vault or settings-file path with a byte
  outside printable ASCII.** It reads the file back with the first and checks the path with the
  second, and refuses to start without them. Git for Windows and macOS ship both.
- **A memory Write the agent makes during a pass lands inside the vault**, in
  `90-auto-memory/.pass-agent/`, and one aimed at the folder the vault's local settings name or at
  the default folder is refused (measured for Write on Windows, for a vault on a drive path; the
  Security section lists what is not covered). `90-auto-memory/` is a steering surface, so the
  fence contains a write there and sets the tripwire, as for any other write under
  `90-auto-memory/`. In 1.4.0 a write to a memory folder outside the vault landed there unseen.
- **A claude-mode pass refuses to start, with exit 1 and an `ERROR:` line, when**:
  - `90-auto-memory/.pass-agent/` holds anything but a regular `.DS_Store` file, or cannot be
    listed. A hidden file, an empty folder, a `.DS_Store` beside another entry, and a `.DS_Store`
    that is a link, a FIFO or has a second hard link all count. What the folder holds could be read
    into the pass as memory, and a linked file could let a write leave the vault.
  - `90-auto-memory` or `.pass-agent` is a symlink or junction. The fence sees a folder link that
    was there before the pass only as a link, so writes through it would leave the vault unseen.
  - `90-auto-memory` or `.pass-agent` is not a folder, so the memory folder cannot be made there.
  - The vault's path holds a `"`, a `\` or a control character, which the settings file cannot
    carry. On Windows, Git Bash keeps a `"` or a tab in a folder name as the private-use character
    U+F022 or U+F009. `dream-pass.cmd` and `promotion-pass.cmd` start the runner with the path
    spelled that way, which `cygpath` gives back, so from them the override names such a vault as
    Windows spells it (measured through `cmd.exe` with a stand-in agent, and for a `"` with real
    Claude Code). Started from a Git Bash prompt, which shows such a name with the `"` or the tab
    itself in `ls` and `pwd`, git cannot enter the folder and the pass exits 1 before the override
    (measured on this release; the git step that stops it is unchanged from 1.4.0).
  - The vault's path, or the settings file's in the temporary folder, holds bytes `iconv` will not
    convert from UTF-8 to UTF-16LE and back unchanged, which Claude Code could read as another
    folder, or holds a byte outside printable ASCII and `iconv` is missing to check it. A path
    can be invalid UTF-8 on Linux, where it is bytes.
  - On Windows, `cygpath` is missing, fails or prints nothing for a path the override needs, or
    gives one that is not a Windows drive path (a network path `//server/share/...`, a `//?/` or
    `//./` device path, a Git Bash `/c/...` path), or one that names another folder or file.
    A `cygpath` found on `PATH` elsewhere goes through the same checks, so one that does not
    convert a path and back to the same folder refuses; one that does is outside what the runner
    can check.
  - Outside Git Bash, where no `cygpath` is found, the Claude Code the runner would start is a
    Windows program: the file `CLAUDE_BIN` names, or the `claude` found on `PATH`, ends in `.exe`
    or, read through any link, starts with a Windows program's `MZ` header, as when a runner in WSL
    starts Windows' `claude.exe`. Such a program would read the runner's POSIX paths as other
    folders. A name that is not a file at all, such as an exported shell function, and a file whose
    first bytes the runner cannot read refuse too, with `is not a file the runner can check`. A
    wrapper script that starts a Windows program is not recognised.
  - The runner's folder for the pass, under `TMPDIR`, fails the checks the state directory gets: it
    lies inside the vault by name, where the agent could change the file (and under `.claude/logs`,
    `.obsidian` or `.git` the fence would not see it), or, off Windows, a folder above it every
    account can write has no sticky bit. Or it lies inside the vault by file identity, the check
    only this folder gets (a letter in another case or a vault at a drive or file-system root does
    not hide it, nor, reasoned, an 8.3 name on a volume with file IDs; a `subst` or mapped drive, or
    a mount, whose root lies inside the vault does, reasoned). The walk up its path goes on past a
    folder whose name ends in `:`, where an earlier build of this release looped for ever, holding
    the run lock and logging nothing (measured on Linux and in Git Bash). Or it is a link, which
    `mktemp -d` never makes, or a folder above it became one during the checks (a link above it that
    is there all along is resolved and accepted for the settings file, which is reached through the
    resolved path; the snapshots, the steering backup and git's hooks folder are reached through
    `TMPDIR` as spelled), so it is not the path it resolves to (an earlier build of this release
    resolved such a link and wrote where it led, measured on Linux; off Windows one in a folder
    every account can write is refused as such, measured on Linux for a dangling one with the
    suite's twin). Off Windows the folder itself, new from `mktemp -d`, is this account's own with
    mode 0700, so the owner and mode checks on it pass; on Windows those checks do not apply, and
    the folder carries the temporary folder's permissions.
  - The runner's folder for the pass cannot be reached: this account cannot enter a folder above it,
    or that folder is not there, so the checks cannot see the folder the runner made. An earlier
    build of this release said the folder was not there, as if something had removed it (measured
    on Linux). On Windows, by default, only the second cause applies: an account may pass through a
    folder it cannot enter, so the checks reach the folder the runner made and accept it (measured
    in Git Bash for a folder spelled with no link).
  - The path resolving the folder above the runner's folder gives is not that folder, compared by
    file identity, so the settings file would go to another folder, one someone else may have made:
    a folder above it is named with a line break at its end, which the shell drops (measured with
    the suite's twin, off Windows), or a link above it was repointed while it was resolved
    (reasoned).
  - The identity walk up the runner's folder ends with a status that is no answer, so the folder
    cannot be shown to lie outside the vault. An earlier build of this release read such a status as
    "not under" (measured on Linux with a stand-in walk).
  - The vault itself cannot be resolved, so the folder cannot be checked against it. The line names
    the vault; an earlier build of this release blamed the runner's folder and gave `TMPDIR` advice
    (measured on Linux).
  - The runner's folder for the pass is not there as a folder. The runner makes it before the pass's
    "before" snapshot and keeps the snapshot in it, so a folder that went away may have taken the
    snapshot with it, and the fence would compare the pass with nothing. It is refused, never made
    again: an earlier build of this release made it again, and an agent's write under
    `90-auto-memory/` then stayed in the vault with no tripwire (measured on Linux), where 1.4.0
    failed closed. A folder emptied, or removed and made again, before the override by another
    process of your account, by root, or on Windows by any account that can change the temporary
    folder, is not caught (reasoned; off Windows a folder another account owns fails the owner
    check), nor, off Windows, another folder of yours moved into its place by an account that can
    rename entries in `TMPDIR`, nor one replaced once the checks have resolved it and before Claude
    Code has read the settings file, which is then written into, or read from, whatever took its
    place (both reasoned), and one removed while the agent runs, or after it ran, is not caught
    either, as in 1.4.0 (measured on 1.4.0 and on this release, with a stand-in agent writing under
    `90-auto-memory/` and to `AGENTS.md`): the fence then contains nothing.
  - `pass-settings.json`, `pass-settings.new`, or the temporary name ending in the runner's process
    id that the file is written through, is already in that folder, which only another process
    could have put there: a link would carry the write elsewhere, a folder would take it in, and a
    FIFO would hold the pass. Only a name there when the runner checks is seen; one planted after
    the check is still written through. Off Windows the folder `mktemp -d` made is this account's
    with mode 0700, so only a process of this account or root can plant a name there, whatever
    `TMPDIR` names, unless an account that can rename entries in `TMPDIR`, or in a folder above it
    (a group-writable one is allowed), put another folder of yours in its place; on Windows any
    account that can change the temporary folder can.
  - The settings file could not be written, or does not read back exactly as written.
  - No settings file was written for the pass, which happens only when the runner and
    `runner-common.sh` come from different releases (Adopting 1). This refusal comes from the
    library just before Claude Code would start, so its `ERROR:` line is in the run log.
- **`Skill` is no longer among the dream agent's tools.** Every `Skill` call was already refused
  under `-p` (measured on Claude Code 2.1.284), so on that version no pass loses anything.
  Removing it closes a route nobody measured: whether a skill's own `allowed-tools` could widen
  what the pass may use.
- `docs/reference.md` states what the memory override covers, its limits, the new exit-1 reasons,
  `pass-settings.json`, the agent's argv and its tools. `AGENTS.md` lets an agent empty
  `90-auto-memory/.pass-agent/` only when you ask, and only once you have cleared the tripwire, the
  one exception to "never by hand" there. `docs/setup.md` has a troubleshooting row for each refusal
  and lists `cmp` and `iconv`, `docs/customizing.md` and the `onboard-project` skill say to keep
  `90-auto-memory` a plain folder (the skill also its `<slug>` folder, since a link there is not
  refused), `docs/harnesses/claude-code.md` describes the override, `README.md` scopes "any
  unattended write fenced and revertible" to writes inside the vault, within the limits
  `docs/reference.md` lists, and the runners' comments no longer credit
  `CLAUDE_CODE_DISABLE_AUTO_MEMORY` with keeping memory in, and name `TMPDIR` among their settings.
  `docs/setup.md` says that a command-mode wrapper that starts Claude Code gets no memory override.
- The control suite holds each of these on the jobs its lists below name, apart from three guards
  no leg tests yet, each right today by reading the code: on Windows, the drive-path walk's own guard
  (no leg follows a first walk that gives no answer, or "under", with a drive-path walk that answers
  "not under"); and on every platform, resolving a folder above the runner's folder that is `/`, or
  with `CDPATH` set. Each new control id was seen failing against 1.4.0 first, except
  `mem-override-sink-contained`: it holds the unchanged fence to containing a write in
  `.pass-agent/`, and was seen failing against a runner that exempts that folder;
  `mem-override-utf8-lax-host` and `mem-override-utf16-lax-host`, which record what the host's
  `iconv` does rather than holding a refusal; `mem-override-work-root` and `mem-override-work-made`,
  which call `memory_override` directly and so fail against 1.4.0, which has none, for that alone,
  and were seen failing against an earlier build of this release that had it (on Linux);
  `mem-override-cygpath-refused` and `mem-override-work-case`, which run only on Windows or macOS,
  where no run of 1.4.0 was made, and call `memory_override` directly; `mem-override-work-colon`,
  `mem-override-work-gone` and `mem-override-work-names`, which guard regressions inside this
  release (1.4.0 has no walk and no override to call) and were seen failing against the earlier
  build `444ec86` (on Linux): its walk did not return, it made the missing folder again, and it
  wrote through a planted name; and `mem-override-settings-space` and
  `mem-override-work-root-drive`, which hold code that was already right and were seen failing
  against a mutant of it (the `--settings` argument unquoted; on Windows, the drive-path walk
  removed); `mem-override-work-dotdot`, `mem-override-work-backstop`,
  `mem-override-work-unreachable`, `mem-override-vault-unresolved` and `mem-override-walk-status`,
  which guard regressions inside this release and were seen failing against the earlier build
  `53b728b` (on Linux): it refused a folder spelled with `..` after a link, or wrote the file into a
  folder of the same name in the link's own folder; it took the path a folder name ending in a line
  break was cut to for the folder; it said a folder it could not reach was gone, and blamed the
  runner's folder for a vault it could not resolve; and it read a walk's error as "not under"
  (all five failed against `444ec86` as well, work-dotdot at its second leg only; `temp-dir-spelling`,
  work-backstop's dangling-link leg and work-names' first line-break leg failed against `b4d1344`
  too, on Linux: its runners called git with the hooks folder before any refusal, it named the wrong
  cause, and it split the line); and `mem-override-state-copy` and `mem-override-work-space`, which
  hold code that was already right and were seen failing against mutants of it (the stale copy
  removed before every check, or after the check for planted names; the folder for the pass unquoted
  in the off-Windows check). `mem-override-flag`, `mem-override-sink-refused`,
  `mem-override-sink-link`, `mem-override-sink-hardlink`, `mem-override-sink-contained`,
  `mem-override-sink-fifo`, `mem-override-path-refused`, `mem-override-nonascii`,
  `mem-override-order`, `mem-override-mixed-release`, `mem-override-unc-refused`,
  `mem-override-work-refused`, `mem-override-work-root`, `mem-override-work-made` (`memory_override`
  called directly with a folder for the pass that does not exist, spelled through a link, and with
  one that is a link to a folder of yours), `mem-override-no-iconv`, `mem-override-work-colon` (a
  folder for the pass under folders whose names end in `:`, every call bounded),
  `mem-override-work-gone` (a folder for the pass that is not there), `mem-override-work-names`
  (`pass-settings.json`, `pass-settings.new` or the temporary name planted in that folder; off
  Windows also links and a FIFO, on Windows a junction whose target was removed, which `test -e`
  does not see and a write through it lands at that target, measured in Git Bash; off Windows also a
  name planted under a folder named with a line break inside, and a folder for the pass under one
  that every account can write, reached through a link, whose lines must show the break as `?` and
  name the folder as the checks see it), `mem-override-settings-space` (a settings path holding a
  space, handed over as one argument), `mem-override-work-dotdot` (`memory_override` called directly
  with its folder spelled with `..` after a link, a junction on Windows, with and without a folder
  of the same name in the link's own folder, and where `mktemp` takes `TMPDIR` a dream pass with
  that `TMPDIR`: off Windows each runs with the file in the folder `mktemp` made, and on Windows
  each is refused for the `..`, also spelled with backslashes; and a folder for the pass given
  relative to the current folder, under a folder named `-`), `mem-override-state-copy` (a copy an
  earlier build left in the state directory kept when the folder fails the last of its checks, and
  gone when a planted name is refused after them), `mem-override-walk-status` (a walk that ends with
  no answer; on Windows also the drive-path walk after the first answered "not under"; off Windows
  also with the folder given through a link above, its line naming the folder as the checks see it),
  `mem-override-work-backstop` (the folder above reported as another folder of yours while it is
  resolved, by a stand-in `pwd`, and as one inside the vault, which the checks refuse with a code of
  their own; off Windows also a folder above named with a line break at its end, with nothing, a
  folder of yours, or one every account can write at the path its resolution gives, a dangling link
  there with the folder as given in place, the folder as given gone with a folder every account can
  write there, or gone with a dangling link there; and a dangling link at the folder's name in a
  folder every account can write, reached directly and through a link above, which keeps the state
  directory's own line), `temp-dir-spelling` (`temp_dir_spelling_ok` with the platform given as
  Windows, over 18 spellings it must refuse and 12 it must accept; off Windows, with no `cygpath`, a
  `..` and an `x.` left alone; and each runner handed a `..` spelling, and the dream runner in
  claude mode an `x.` one, by a `mktemp` stand-in, its git calls recorded and, off Windows, a
  `cygpath` stand-in making the platform read as Windows: the dream and promotion runners in claude
  and command mode and the retention runner must refuse before any git call names the hooks folder
  or the spelling, where the controls, the dream and promotion runners in command mode, which start
  their agent, and the retention runner, with the folder spelled plainly, call git with that hooks
  folder; and on Windows the hooks placed in a folder of the textual name must not run, which tells
  this release from earlier builds only on the dream and promotion legs with `..`) and
  `dream-agent-tools` are required on every suite job. `mem-override-work-space`, a pass with a
  `TMPDIR` holding a space, is required on the ubuntu and Windows jobs, where `mktemp` takes
  `TMPDIR`, and not on macOS. `mem-override-work-unreachable` (a folder above that this account
  cannot enter; skipped as root) and `mem-override-vault-unresolved` (a vault that is not there)
  are required on the Linux and macOS jobs and not on Windows, where Git Bash's mode bits are not
  permissions, an account may by default pass through a folder it cannot enter, and `cygpath`'s
  round trip refuses a vault that is not there first. `mem-override-work-root-drive`, a vault at
  the drive root refused by the drive-path walk alone, is required on the Windows job only.
  `mem-override-sink-unreadable`, `mem-override-sink-filelink`, `mem-override-file-mode`,
  `mem-override-utf8-refused`, `mem-override-winbin`, `mem-override-winbin-unreadable`,
  `mem-override-stray-cygpath`, `mem-override-no-cygpath` and `mem-override-work-open` are required
  on the Linux and macOS jobs and not on Windows, where they skip or may skip; the two unreadable
  ones also skip as root. `mem-override-winbin` also holds that both of its lines show a line break
  in the agent's name, or in its path, as `?`, on one line. `mem-override-cygpath-refused` is
  required on the Windows job, the only one with `cygpath`. `mem-override-work-case`,
  `memory_override` called directly with its folder inside the vault, spelled with a letter in the
  other case, is required on the Windows and macOS jobs, whose file systems ignore case, and not on
  ubuntu. `mem-override-work-resolved`, a `TMPDIR` spelled through a link, the link last with no
  `..` after it, is required on the ubuntu and Windows jobs, where `mktemp` takes `TMPDIR`, and not
  on macOS. `mem-override-utf8-lax-host`, required on the ubuntu job only, is recorded where
  `iconv`'s conversion to UTF-8 lets a sequence above U+10FFFF through, as glibc's does, so that job
  shows its UTF-8 twins can tell the round trip from a conversion to UTF-8 alone.
  `mem-override-utf16-lax-host`, required on the two macOS jobs only, is recorded where the
  conversion to UTF-16LE, asked under the C locale as the runners ask it, takes that sequence
  without an error, as macOS's does, so those jobs show the same against a conversion to UTF-16LE
  alone.

### Adopting this

1. **Take `.claude/scripts/lib/runner-common.sh`, `dream-pass.sh`, `promotion-pass.sh` and
   `vault-retention.sh` together.** The three runners depend on the library. With the 1.4.1
   library and an older dream or promotion runner, every claude-mode pass exits 1 before Claude
   Code starts, and the run log (`.claude/logs/dream-agent.run.log` or `promotion-agent.run.log`)
   says `no memory override was written for this pass`; no tripwire is left, also when
   `AGENT_SETTINGS_FILE` is set in the environment (measured on Linux with 1.4.0's `dream-pass.sh`
   and `promotion-pass.sh`; older releases are unmeasured). A dream pass in command mode and 1.4.0's
   retention pass run there (measured on Linux), as in 1.4.0, so on Windows they would not refuse a
   `..` or a part ending in a dot (Security; reasoned: 1.4.0's runners never call the check).
   With 1.4.0's library and a 1.4.1 runner, each runner exits 1 with
   `temp_dir_spelling_ok: command not found`, which goes to its stderr, not to its log (measured
   on Linux, for the dream runner in both modes, the promotion runner in claude mode and the
   retention runner; older libraries are unmeasured). Either way no agent ran in claude mode: take
   all four.
2. **Nothing to configure for most vaults.** The override is on in claude mode for every pass.
   Item 11 asks some Windows accounts to set `VAULT_STATE_DIR`, and items 5 and 9 name the tools
   (`iconv`, `cmp`) a pass now needs.
3. **A pass refuses to start while `90-auto-memory/.pass-agent/` holds anything but a plain
   `.DS_Store` file (not a link, a FIFO or one with another hard link), or cannot be listed.** The
   log says `the memory override folder already held a file`. What is there was written by an
   unattended agent, so treat it as data: read it before you keep any of it, keep it outside every
   memory folder, and empty the folder. `AGENTS.md` now lets an agent make this one edit under
   `90-auto-memory/`, only when you ask and only once the tripwire is cleared.
4. **Outside Windows, a pass refuses to start while the vault's path holds a `"` or a `\`** (or a
   control character). The log says `the vault's path holds a character the settings file cannot
   carry`. Rename the folder. On Windows a `"` or a tab Git Bash put in a folder name is kept as
   U+F022 or U+F009, and such a vault runs from the `.cmd` wrappers. Started from a Git Bash
   prompt, which shows the name with the `"` or the tab itself, the pass exits 1 with `git could not
   read this vault's repository` (measured on this release; that git step is unchanged from
   1.4.0); start it from the `.cmd` wrapper, or rename the folder.
5. **A pass refuses to start while the vault's path, or the settings file's under `TMPDIR`, holds
   bytes that do not come back unchanged from UTF-8 to UTF-16LE and back**, which can happen on
   Linux, where a path is bytes: a folder name kept from a legacy encoding (GBK, Big5) by `unzip`
   or `rsync`, say. The log says `is not valid UTF-8, or iconv could not check it`. Rename the
   folder, or point `TMPDIR` at one with a plain name. The same line appears on any platform when
   the path is valid but holds a byte outside printable ASCII and `iconv` is not installed; install
   it.
6. **A pass refuses to start while `90-auto-memory` or `90-auto-memory/.pass-agent` is a symlink or
   junction.** The log says `the memory override folder is a link`. Replace the link with a plain
   folder.
7. **A pass refuses to start while `90-auto-memory` or `90-auto-memory/.pass-agent` is a file.**
   The log says `is not a folder, so the memory override folder cannot be made there`. Make both
   plain folders.
8. **A pass whose agent writes memory now exits 2 and sets the tripwire.** The write lands in
   `90-auto-memory/.pass-agent/`, a steering surface, where 1.4.0 usually let it land outside the
   vault unseen (the containment measured with a stand-in agent). Read the tripwire and its
   quarantine as for any contained pass. Containment moves the files, but a folder the agent made
   inside `.pass-agent/` stays behind. The tripwire stops every pass first; once you clear it, a
   folder left there makes the next pass refuse under item 3 until you empty it.
9. **A pass refuses to start when it cannot write its settings file, or the file does not read back
   as written.** The log says `could not write the memory override` or `does not hold what was
   written to it`. Check that the temporary folder (`TMPDIR`, or `/tmp`) is writable and has space,
   and that `command -v cmp` finds `cmp`, which the read-back needs. On Windows the line may instead
   say `cygpath could not convert a path for the memory override`, `which is not a Windows drive
   path` or `which is not the same folder or file`; check Git Bash's `cygpath` (`docs/setup.md`,
   Troubleshooting), and for a quoted path that starts `//` and a host name, which means the vault
   or the temporary folder is on a network path, see item 14. When the quoted path starts `//?/`,
   the vault's path, or the temporary folder's, is about 260 characters or more, which `cygpath`
   gives in that form: move the vault nearer a drive root, or point `TMPDIR` at a shorter folder
   outside the vault that only your account can change, made private yourself as in item 11, since
   the runner cannot read its permissions on Windows. A runner started outside Git Bash, with no
   `cygpath` on `PATH`, whose Claude Code is Windows' `claude.exe`, named in `CLAUDE_BIN` or found
   on `PATH`, directly or through a link, now refuses with `looks like a Windows program`; run the
   `.cmd` runner instead.
10. **If you renamed `90-auto-memory`, rename it in `runner-common.sh` too**, in `memory_override`
    and in the fence's steering list (`docs/customizing.md` § 2). Otherwise a pass checks, and
    points memory at, a folder that is no longer your memory tier.
11. **On Windows, an account whose name is not ASCII (`Łukasz`, `José`, a Cyrillic name) needs
    `VAULT_STATE_DIR`, as it already did in 1.4.0.** The default state directory is under
    `%LOCALAPPDATA%`, and the runners still convert that path under `C`, which turns such a name
    into a different, double-encoded folder beside the profile. Windows does not let a
    non-elevated account create a folder in `C:\Users`, so every pass of a task that does not run
    with highest privileges exits 1 with `the state directory ... could not be created, or cannot
    be entered` (measured the same before and after this release, with a profile folder named
    `Łukasz` whose parent the account could not write to). Make a new folder with an ASCII path
    outside the vault, directly under `C:\`, for example `C:\vault-state`, and make it private to
    your account: a new folder under `C:\` lets every signed-in account change its files, and the
    runner trusts the tripwire, in-flight marker and backup it keeps there. Make the folder
    yourself. If `mkdir` says it already exists, check its owner with `dir /q C:\` or `(Get-Acl
    C:\vault-state).Owner`, and do not use one another account owns, because its owner can change
    its permissions back at any time. In Command Prompt run
    `icacls C:\vault-state /inheritance:r /grant:r "%USERDOMAIN%\%USERNAME%:(OI)(CI)F"` (in
    PowerShell write `"${env:USERDOMAIN}\${env:USERNAME}:(OI)(CI)F"`) as the account the scheduled
    task runs as, or write that account's name in their place, then check that
    `icacls C:\vault-state` lists only that account; both forms left only the account, on the
    folder and on a subfolder already inside it (measured). Until `icacls` runs, other accounts can
    make folders inside the new one, so then check that it is still empty (`dir /a /q
    C:\vault-state`) and point `VAULT_STATE_DIR` at a subfolder that does not exist yet, which the
    runner makes. `C:\` itself gave other accounts only the rights to read it and to add folders
    (measured with `icacls C:\`), but another drive's root may give them more, as `D:\` did here
    (`Everyone:(OI)(CI)(F)`). A root where any account but yours, SYSTEM and Administrators has
    `(F)` or `(DC)` lets that account rename your folder and put its own in its place, and `(WDAC)`
    or `(WO)` lets it give itself those rights: check a root with `icacls` before you use it.
    A folder deeper down, such as `D:\data\vault-state`, is only as safe as the folders above it,
    for the same reason. Then set `VAULT_STATE_DIR` to `C:\vault-state\my-vault`. The vault itself
    may stay under the profile, because the memory override now converts its path faithfully (other
    path checks still convert under `C`; `docs/reference.md` § 4.3, Known limits). For such an
    account's own temporary folder, which holds the settings file, that rests on a suite twin with a
    stand-in agent (a vault and `TMPDIR` under one folder named in Cyrillic); no run with real
    Claude Code under a non-ASCII account has measured it. Give
    `VAULT_STATE_DIR` an ASCII path on Windows. A non-ASCII one is used under a double-encoded name
    the runner makes itself beside the folder you named, which takes its parent's permissions, not
    yours: directly under `C:\`, every signed-in account could then change the state it holds
    (measured), and where you cannot create folders, as in `C:\Users`, every pass exits 1. The
    memory override's settings file is not kept in the state directory (Changed).
12. **The override was measured on Claude Code 2.1.284, 2.1.285, 2.1.287, 2.1.289, 2.1.292, 2.1.293,
    2.1.295 and 2.1.296 only.** 2.1.284 for a named folder, 2.1.285 for the default folder too,
    2.1.287 for both again, the non-ASCII paths and the fail-open on an empty or invalid file,
    2.1.289 for the named and default folders, the Cyrillic and `"` vaults, glob and trailing-dot
    names, a drive root (on an earlier build of this release), a drive mapped to the host's own
    administrative share and the network paths it does not honour, 2.1.292 for the named and default
    folders, the Cyrillic and `"` vaults, glob and trailing-dot names, that mapped drive and the
    network paths (on an earlier build of this release), 2.1.293 for starting with a settings file
    under a non-ASCII temporary folder (on that build), 2.1.295 for the named and default folders,
    the Cyrillic and `"` vaults and starting with a settings file under a Cyrillic `TMPDIR`, on the
    earlier build `53b728b`, and 2.1.296 for the same with this release's runner, and for which file
    a `--settings` path through a folder ending in a dot names, Claude Code started on its own. The
    fail-open was not re-run after
    2.1.287. Any other version, older or newer, is unmeasured, and a native install updates itself:
    `claude --version` says which one a pass will run.
13. **Remove `Skill` from your `dream-agent.md`'s `tools:` line if it still names it.** Keeping it
    leaves open the route this release closes, which nobody measured; on Claude Code 2.1.284 no
    pass lost anything, because every `Skill` call was already refused under `-p`. In that vault
    `run-tests.sh`'s `dream-agent-tools` control fails until you remove it.
14. **On Windows a vault on a network path no longer runs from Git Bash.** A vault on a `//` path
    (a NAS share, the WSL file system, a Documents folder redirected to a server) was accepted from
    Git Bash by an earlier build of this release, but for one reached as `//localhost/c$/...` (the
    measuring host's own administrative share) or `//wsl.localhost/...` Claude Code did not honour
    the memory override (measured; a share on another server is unmeasured), so such a pass now
    exits 1 with `cygpath gave //... for a path of the memory override, which is not a Windows drive
    path`. Move the vault to a local drive. A mapped drive letter gives a drive path, which the
    runner accepts, but only one mapped to the measuring host's own administrative share
    (`\\localhost\c$`) was measured, where a memory Write to the default folder was refused (Claude
    Code 2.1.289 and 2.1.292, through `dream-pass.cmd`). A drive mapped to a NAS, another server or
    `\\wsl.localhost\...` is unmeasured, and Claude Code may ignore the file there as it did for the
    `//` form; where that server reports no file IDs the runner's identity checks could refuse it
    (reasoned). A share other accounts can write gives them the
    vault's `.claude/` too, hooks among it, so map only one that no other account can change. The
    `.cmd` wrappers cannot start a vault from a `//` path (`CMD does not support UNC paths as
    current directories`, measured on this release).
15. **A claude-mode pass refuses to start when its folder under `TMPDIR` fails the state directory's
    checks, lies inside the vault by file identity, is not the path it resolves to, is not there,
    cannot be reached, is not the folder its resolution led to, or already holds a name the settings
    file is written through; on Windows, or wherever a `cygpath` is found on `PATH`, every pass, in
    either mode, and the retention pass refuse one spelled with a `..` or a part ending in a dot.**
    The log says `the runner's folder for the
    pass, ...`, then why (`resolves into the vault`, `is inside a folder every account can write
    that has no sticky bit`, `is not the path it resolves to`, and so on), `and the memory
    override's settings file there can name hooks Claude Code runs`. A folder that is not there
    gives `is not there as a folder, though the runner made it before the pass's snapshot`:
    something removed it during the pass (you, root, an account that owns a folder above it, or on
    Windows another account under a `TMPDIR` it can change; a cleaning tool is unlikely to pick a
    folder that new), so find what and stop it. If `TMPDIR` was already unset, or already named a
    folder only your account can change, a process running as you, as root or as an administrator,
    or on Windows a task run as another account, did it: find that process before the next pass. Off
    Windows, a folder above it that your account cannot enter gives `cannot be reached: this account
    cannot enter the folder above it`: give your account back its access, or point `TMPDIR` at a
    folder outside the vault that your account can enter and only it can change. On Windows an
    account may by default pass through a folder it cannot enter, and the checks then reach the
    runner's folder and accept it (measured in Git Bash for a folder spelled with no link), so there
    the line normally means a folder above it is not there: the pass's snapshot went with it, so
    find what removed it, then leave `TMPDIR` unset and schedule the task as your own account. `is
    not the folder that resolving the folder above it led to` means a folder above it is named with
    a line break at its end, or a link above it changed while the runner resolved it: rename the
    folder, or find what changed the link. `which is not an answer, so the folder cannot be shown to
    lie outside the vault` means the check that walks up the folder ended with neither answer, which
    this release's walk never gives: `runner-common.sh` was edited or damaged, so take it and the
    runners from this release again. A planted name gives `was already there, and the memory
    override is written through
    it`. Off Windows the folder is yours with mode 0700, so a process of your account or root wrote
    there, unless an account that can rename entries in `TMPDIR` or in a folder above it swapped in
    another folder of yours: point `TMPDIR` at a folder only you can change, then find that process.
    On Windows any account that can change the temporary folder can do it: leave `TMPDIR` unset,
    schedule the task as your own account, and find what wrote there. On Windows, or wherever a
    `cygpath` is found on `PATH`, `is spelled with .. or with a part that ends in a dot` means
    `TMPDIR` holds a `..`, or a part ending in a dot, which git on Windows reads as text; every
    runner, the retention pass among them, refuses it in every mode before its first git call (the
    retention pass takes only a `TMPDIR` starting with `/`, and uses `/tmp` for a `C:/...` one):
    point `TMPDIR` at the folder itself, or leave it unset and schedule the task as your own
    account. A vault the pass cannot resolve gives `the vault, ..., cannot be resolved`: check that
    the vault's folder is there and that the task's account can enter it. A vault that holds the
    default temporary folder, as one at a drive root does, must move into a folder of its own, or
    `TMPDIR` must point outside it. The default temporary folder passes on Linux (`/tmp`, sticky),
    macOS (a per-user folder) and Windows (Git Bash's `/tmp`, this account's temporary folder),
    measured on CI's three platforms. If you set `TMPDIR` for the passes, point it at a folder
    outside the vault that only your account can change, named directly, with no link, no `..` and
    no part ending in a dot: the settings file is reached through the folder's resolved path, but
    the snapshots, the steering backup and git's hooks folder there are reached through `TMPDIR` as
    spelled, as in 1.4.0. On Windows the runner cannot read a folder's permissions, so schedule the
    task as your own account, and leave `TMPDIR` unset there unless item 9's `//?/` refusal needs a
    shorter folder (on the one host measured, setting `TEMP` and `TMP` for the `.cmd` did
    not move Git Bash's `/tmp`). A Git Bash login shell, as a Git Bash terminal starts one, sets
    `TMPDIR` from `TMP`, spelled `C:/...`, and a pass started from it fails at its steering backup,
    as in 1.4.0, because `tar` reads `C:` as a host name (measured on 1.4.0 and this release): start
    passes with the `.cmd` wrappers, or unset `TMPDIR` first. That advice assumes the task runs as
    your own account, whose `TEMP` is a folder of its own: a task run as SYSTEM gets
    `C:\Windows\Temp` instead (unmeasured), so schedule the passes as your account. On macOS
    `TMPDIR` does not move the folder: Apple's `mktemp` takes the per-user one (measured on CI).

`--check` will list `.claude/scripts/lib/runner-common.sh`, `.claude/scripts/dream-pass.sh`,
`.claude/scripts/promotion-pass.sh`, `.claude/scripts/vault-retention.sh`,
`.claude/scripts/run-tests.sh`, `.claude/agents/dream-agent.md`, both copies of
`onboard-project/SKILL.md` (under `.claude/skills/` and `.agents/skills/`), `AGENTS.md`,
`docs/reference.md`, `docs/setup.md`, `docs/customizing.md` and `docs/harnesses/claude-code.md` as
safe to take, alongside `VERSION` and `CHANGELOG.md`. Take the library and the three runners in one
step (item 1). If you customized `dream-agent.md`, `AGENTS.md` or one of
the docs, take it as a merge rather than a copy. `README.md` changed in one bullet too; it is yours
once the vault exists, so `--check` does not list it. `AGENTS.md` gains one exception to "never by
hand"; no note, `.claude/rules/` file, hook, frontmatter key or checker behaviour a vault relies on
has moved.

---

## 1.4.0 — 2026-09-27

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
  every one of them is held. The printing at the end of a run can be stopped with TERM, INT or HUP,
  under bash 3.2 too, so a reader that stops reading no longer keeps the run alive until KILL, and
  nothing the run started goes on printing after the signal has ended it. A TERM that lands while
  the run lets its lock go is kept until the lock is released rather than lost. A run lock, or a
  process id, that the caller's environment names is no longer touched by a run that never took
  it, and `RUN_NONCE`, `RUN_STALL_SECONDS` or `RUN_GAPS_FILE` in that environment no longer reaches
  the run's watchdog.
- The control suite holds each of these. It lands other runs' lines, a rewritten log and signals at
  chosen moments of a run by construction, and reads what the run printed. CI names the new
  controls, and the existing control for a candidate name holding a line break, as ones that must
  run wherever they can: the unlistable-folder control on every job but Windows, where the job's
  account can list a folder denied to it, and the POSIX-mode control on the Linux and Windows jobs,
  whose bash is new enough to parse the runner in that mode.
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

## 1.3.2 — 2026-09-26

Pi, the terminal coding agent from Earendil Works, becomes the tenth harness with a guide. It gets
an opt-in extension that guards the secret paths, lints written notes and records compactions, and
an onboarding prompt whose checks prove the extension runs. The scheduled passes now contain a file
planted under `.pi/`, and the lint's invisible-character scan reaches Pi's instruction files,
`AGENTS.override.md` and `CLAUDE.local.md`.

### Added

- **`docs/harnesses/pi.md`**, the guide: what ships, what is enforced and what stays guidance, the
  one-time setup, the onboarding prompt and its checks, a wrapper for the scheduled passes, and its
  sources, checked against Pi v0.87.1 on 2026-09-25.
- **`.claude/adapters/pi/vault.js`, the extension, which is opt-in.** Pi runs `.pi/extensions/`
  once a project is trusted, and it treats a trust decision saved for a folder as covering every
  folder below it, so a vault cloned into a trusted folder would run a shipped extension without
  asking. The extension therefore ships where Pi does not look, and you load it with `pi -e` or
  copy it into `.pi/extensions/`. Once loaded it:
  - refuses a `read`, `write`, `edit`, `grep`, `find` or `ls` call whose path names `.env` or
    `.env.*`, or passes through or ends at a part named `secrets` at any depth, reading the path
    the way Pi's own tools will open it and following symbolic links, including one whose target
    does not exist yet. A `grep`, `find` or `ls` with no path is tested against the folder it
    searches;
  - refuses a `grep` whose glob names one of them: by its text, by a last part that matches `.env`,
    `.env.local` or `secrets` or spells `.env.` with `?`, `[...]` or `{...}` standing in for letters
    of `.env`, or by a folder part other than `*` or `**` that matches `secrets`, comparing
    letters without regard to case. A `[...]` set that could match a `/` is tried as one too,
    since ripgrep lets it, and a backslash is read as the escape it is to ripgrep; on Windows a
    glob holding a backslash is refused as one the guard cannot decide. Sets, such as
    `[a-b-z]`, which runs from `a` to `z`, and a glob's trailing white space are read as ripgrep
    reads them. ripgrep lets a matching glob override `.gitignore`. A glob that starts with `!`
    only excludes files, so it is let through. A glob that reaches a `.env.*` name other than
    `.env.local` only
    through a `*` standing in for some or all of `.env`, such as `*.production` or
    `.e*.production`, is let through, and the guide says so;
  - refuses a `read`, `write` or `edit` call that carries no path, and a call it cannot decide,
    such as a glob longer than 256 characters, rather than letting it through unchecked;
  - runs `vault-lint.sh` after each successful `write` and `edit` and adds what it reports to the
    tool's result, cut at 4000 characters with a line saying so, and runs
    `postcompact-wrap-up.sh` after each compaction. Both run with `CLAUDE_PROJECT_DIR` naming the
    vault, are stopped at 15 s and answered by 16 s, and the extension says once when either could
    not run.

  Pi's `bash` tool, and `powershell` where you enable it, run without asking and can read any of
  these files, so the guard keeps the file tools from reading a secret by accident and is not a
  boundary.
- **Controls for the extension**, driven through Node 18 or later: each spelling of a secret path
  Pi would open, the globs and links that reach one, the names it must let through, the reason
  each refusal gives, the lint and stub calls, and the warning when a script fails. Without Node
  they skip with a reason, and the file-link cases skip on a Windows machine that may not make
  file links. CI requires the behaviour, folder-link and file-link controls on every job.

### Changed

- **A scheduled pass that writes under a `.pi/` folder is now contained.** `.pi` joins the harness
  folders the runners treat as a steering or execution surface, in any letter case and at any
  depth, because Pi runs code from `.pi/extensions/`, installs what `.pi/settings.json` declares
  into `.pi/npm` and replaces its system prompt from `.pi/SYSTEM.md`. Until now such a write was
  treated like any other file the pass wrote, and nothing put it aside. Now the runner puts it
  aside and sets `.claude/logs/runner-tripwire`, so later runs exit 78 until you have looked.
- **The lint's invisible-character scan reaches Pi's instruction files**: `.pi/SYSTEM.md`,
  `.pi/APPEND_SYSTEM.md`, `.pi/skills/` and `.pi/prompts/`.
- **It also reaches `AGENTS.override.md` and `CLAUDE.local.md`.** Codex and Pi load
  `AGENTS.override.md` in place of `AGENTS.md` in the folder that holds it, and Claude Code loads
  `CLAUDE.local.md` beside `CLAUDE.md`. Both gaps predate Pi: the runners already contained the
  two files, and the lint did not scan them.
- **`docs/reference.md` §3.1 is now the one complete list of what the scan covers.** `README.md`,
  `docs/setup.md` and `docs/customizing.md` point to it instead of repeating a list that had fallen
  behind, since none of them named `.agents/skills/` or `.hermes.md`.
- `AGENTS.md` §8, `docs/harnesses/README.md`, `README.md` and `docs/setup.md` name Pi alongside
  the other harnesses, and the skills row of `AGENTS.md` §8 now says Hermes, like Pi, reads
  `.agents/skills/` only once the project is trusted. `docs/reference.md` describes Pi's guard and
  the new controls, lists Node as an optional dependency of the suite, names `.opencode/` and
  `.pi/` among the containment surfaces, and says that the lists of required controls it shows
  are excerpts of the ones in `.github/workflows/ci.yml`. The comments in
  `postcompact-wrap-up.sh` name Pi's event.

### Adopting this

Take the changed owned files. The one that changes what your scheduled passes do is
`.claude/scripts/lib/runner-common.sh`: once you have it, a pass that writes under `.pi/` sets the
tripwire, and later runs exit 78 until you have looked. A `.pi/` folder you keep for interactive
use does not stop the schedule, because only what a pass changes counts, though the runner now
backs it up with the other steering files before every run, which a large `.pi/npm` makes slower.
If you run the passes under Pi, use the wrapper in `docs/harnesses/pi.md`: its `--no-approve`
stops Pi installing project packages into `.pi/npm` during a pass, which would now stop the
schedule. `.claude/hooks/vault-lint.sh` scans six more kinds of steering file and still always
exits 0. `AGENTS.md` is a standing instruction every harness loads, and its §8 table names Pi in
five rows.

`.claude/adapters/pi/vault.js` is new code, and nothing runs it until you load it, so to use Pi
with this vault, follow `docs/harnesses/pi.md`. `docs/harnesses/pi.md` is new too, and
`docs/harnesses/README.md`, `docs/reference.md`, `docs/setup.md`, `docs/customizing.md`,
`.claude/hooks/postcompact-wrap-up.sh` and `.claude/scripts/run-tests.sh` changed. `VERSION` and
`CHANGELOG.md` move as on every release. No rule, note, frontmatter key or `vault-check.sh`
invariant changed.

`README.md` changed too, and it is seed, so your copy stays as you wrote it.

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
