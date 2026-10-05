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

## 1.4.1 — 2026-10-05

A security fix for the dream and promotion passes in claude mode. Claude Code's memory folder for
a pass is now pointed inside the vault, where the write fence sees it, for a vault on a drive path;
on Windows a vault on a network path is refused instead. Measured for the Write tool on Windows,
with ASCII and non-ASCII vault paths; Linux and macOS are unverified.

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
  Windows the same way, for an ASCII vault path on a drive, and for one on a mapped network drive
  (`net use`) started through `dream-pass.cmd`: a Write there landed without the runner's file and
  was refused with it.
- **A vault on a network path is refused, because the file does not protect it.** For a vault
  reached as `//server/share/...` or `//wsl.localhost/...` and started from Git Bash, Claude Code
  2.1.289 ignored the runner's file: a Write to the default memory folder landed with it as without
  it (measured). On Windows the runner now accepts only a drive path for the vault and for its
  settings file, and refuses any other with exit 1. The `.cmd` wrappers could not start such a vault
  before either. Measured for one mapped drive; DFS, WebDAV and other redirectors are unmeasured.
- **A vault path that is not ASCII is converted faithfully.** On Windows the runner converts the
  vault's path, and the settings file's, with Git Bash's `cygpath`. Under the runners' `LC_ALL=C`
  that cuts a path at its first character outside the ANSI code page and turns `é` into one invalid
  byte, so the file would name a folder outside the vault, and a Write there landed (measured). The
  conversions now run under a UTF-8 locale, and the pass refuses unless each converted path names,
  converted back, the folder or file it came from. Measured with real Claude Code for vaults under
  a folder named in Cyrillic and one holding a Git Bash `"` (2.1.287 and 2.1.289), and, in one run
  on 2.1.287 against an earlier build, one named `José`: a Write to the folder the C-locale
  conversion named landed with that conversion's file and was refused with the new one.
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
  again (measured; not re-run on 2.1.289). The runner reads its file back byte for byte before it
  starts the agent and refuses on any difference, but a change made between that read and Claude
  Code's is not seen. So the file is not kept in the state directory, which may be shared or, on
  Windows, take its parent's permissions: it is written in the runner's own folder for the pass,
  which only the runner's account can enter on Linux and macOS, and which on Windows carries the
  per-user temporary folder's permissions (the account, SYSTEM and Administrators, measured).
- **Linux and macOS are unverified.** No Claude Code run has measured the grant on either. There
  the runner refuses a vault or settings-file path that `iconv` will not convert from UTF-8 to
  UTF-16LE, which Claude Code could read as another folder: invalid bytes, surrogates, overlong
  forms, code points above U+10FFFF and 5- and 6-byte forms. That refusal was measured on Linux
  (glibc 2.43) with a stand-in agent; glibc's conversion to UTF-8, which an earlier build of this
  release used, let the last two through. macOS's `iconv` was not measured.
- **Measured on Claude Code 2.1.284 (a named folder), 2.1.285 and 2.1.287 (a named folder and the
  default one, and on 2.1.287 the non-ASCII paths), and 2.1.289 (the named and default folders,
  the Cyrillic and `"` vaults, glob and trailing-dot names, a drive root, a mapped network drive,
  and the network paths it does not honour).** No other version was measured.
- **Memory only.** A folder a settings file grants through `additionalDirectories` stays outside
  the fence, as in 1.4.0.

### Changed

- **Both runners write `pass-settings.json` into their own folder for the pass before a
  claude-mode pass**, the one each already makes with `mktemp -d` for its snapshots, under
  `TMPDIR` or `/tmp`, and removes when the pass ends. They start the agent with `--settings <that
  file>` just before `--disallowedTools`. The file holds one key, `autoMemoryDirectory`. On Linux
  and macOS it is written readable by the runner's account only, whatever the umask, in a folder
  only that account can enter, because a settings file can name hooks Claude Code runs; on Windows
  it carries the temporary folder's permissions. A `pass-settings.json` found in the state
  directory, which an earlier build of this release wrote there, is removed. The runner never
  creates `.pass-agent/` itself. Command mode is unchanged.
- **A claude-mode pass now needs `cmp`, and `iconv` for a vault or settings-file path that is not
  plain ASCII.** It reads the file back with the first and checks the path with the second, and refuses
  to start without them. Git for Windows and macOS ship both.
- **A memory Write the agent makes during a pass lands inside the vault**, in
  `90-auto-memory/.pass-agent/`, and one aimed at the folder the vault's local settings name or at
  the default folder is refused (measured for Write on Windows, for a vault on a drive path; the
  Security section lists what is not covered). `90-auto-memory/` is a steering surface, so the fence contains a write there and
  sets the tripwire, as for any other write under `90-auto-memory/`. In 1.4.0 a write to a memory
  folder outside the vault landed there unseen.
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
    convert from UTF-8 to UTF-16LE, which Claude Code could read as another folder, or holds a byte
    outside printable ASCII and `iconv` is missing to check it. A path can be invalid UTF-8 on
    Linux, where it is bytes.
  - On Windows, `cygpath` is missing, fails or prints nothing for a path the override needs, or
    gives one that is not a Windows drive path (a network path `//server/share/...`, a `//?/` or
    `//./` device path, a Git Bash `/c/...` path), or one that names another folder or file.
    A `cygpath` found on `PATH` elsewhere goes through the same checks, so one that does not
    convert a path and back to the same folder refuses; one that does is outside what the runner
    can check.
  - Outside Git Bash, the Claude Code the runner would start is a Windows program: the file
    `CLAUDE_BIN` names, or the `claude` found on `PATH`, ends in `.exe` or, read through any link,
    starts with a Windows program's `MZ` header, as when a runner in WSL starts Windows'
    `claude.exe`. Such a program would read the runner's POSIX paths as other folders. A name that
    is not a file at all, such as an exported shell function, and a file whose first bytes the
    runner cannot read refuse too, with `is not a file the runner can check`. A wrapper script that starts a Windows
    program is not recognised.
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
  `90-auto-memory/.pass-agent/` only when you ask, and only once you have cleared the tripwire,
  the one exception to "never by hand" there.
  `docs/setup.md` has a troubleshooting row for each refusal and lists `cmp` and `iconv`,
  `docs/customizing.md` and the `onboard-project` skill say to keep `90-auto-memory` a plain folder,
  `docs/harnesses/claude-code.md` describes the override, `README.md` scopes "every unattended write
  fenced" to writes inside the vault, and the runners' comments no longer credit
  `CLAUDE_CODE_DISABLE_AUTO_MEMORY` with keeping memory in.
- The control suite holds each of these. Each new control id was seen failing against 1.4.0
  first, except `mem-override-sink-contained`: it holds the unchanged fence to containing a write
  in `.pass-agent/`, and was seen failing against a runner that exempts that folder; and
  `mem-override-utf8-lax-host`, which records what the host's `iconv` does rather than holding a
  refusal.
  `mem-override-flag`, `mem-override-sink-refused`, `mem-override-sink-link`,
  `mem-override-sink-hardlink`, `mem-override-sink-contained`, `mem-override-sink-fifo`,
  `mem-override-path-refused`, `mem-override-nonascii`, `mem-override-order`,
  `mem-override-mixed-release`, `mem-override-unc-refused` and `dream-agent-tools` are required on
  every CI job. `mem-override-sink-unreadable`, `mem-override-sink-filelink`,
  `mem-override-file-mode`, `mem-override-utf8-refused`, `mem-override-winbin`,
  `mem-override-winbin-unreadable`, `mem-override-stray-cygpath` and `mem-override-no-cygpath` are
  required on the Linux and macOS jobs and not on Windows, where they skip or may skip; the two
  unreadable ones also skip as root. `mem-override-cygpath-refused` is required on the Windows
  job, the only one with `cygpath`. `mem-override-utf8-lax-host`, required on the ubuntu job only,
  is recorded where `iconv`'s conversion to UTF-8 lets a sequence above U+10FFFF through, as
  glibc's does, so that job shows its UTF-8 twins could fail there.

### Adopting this

1. **Take `.claude/scripts/lib/runner-common.sh`, `dream-pass.sh` and `promotion-pass.sh`
   together.** Each depends on the others. With the 1.4.1 library and an older runner, every
   claude-mode pass exits 1 before Claude Code starts, and the run log
   (`.claude/logs/dream-agent.run.log` or `promotion-agent.run.log`) says `no memory override was
   written for this pass`; no tripwire is left, also when `AGENT_SETTINGS_FILE` is set in the
   environment (measured on Linux with 1.4.0's `dream-pass.sh` and `promotion-pass.sh`; older
   releases are unmeasured). With an older library and a 1.4.1 runner, every claude-mode pass exits 1 with
   `memory_override: command not found`, which goes to the runner's stderr, not to its log
   (measured on Linux). Either way no agent ran: take all three.
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
   bytes `iconv` will not convert from UTF-8**, which can happen on Linux, where a path is bytes:
   a folder name kept from a legacy encoding (GBK, Big5) by `unzip` or `rsync`, say. The log says
   `is not valid UTF-8, or iconv could not check it`. Rename the folder, or point `TMPDIR` at one
   with a plain name. The same line appears on any platform when the path is valid but holds a
   byte outside printable ASCII and `iconv` is not installed; install it.
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
9. **A pass refuses to start when it cannot write its settings file, or the file does not read
   back as written.** The log says `could not write the memory override` or `does not hold what
   was written to it`. Check that the temporary folder (`TMPDIR`, or `/tmp`) is writable and has
   space, and that `command -v cmp` finds `cmp`, which the read-back needs. On
   Windows the line may instead say `cygpath could not convert a path for the memory override`,
   `which is not a Windows drive path` or `which is not the same folder or file`; check Git Bash's
   `cygpath` (`docs/setup.md`, Troubleshooting), and for a quoted path that starts `//` and a host
   name see item 14. When the quoted path starts `//?/`, the vault's path, or the temporary
   folder's, is about 260 characters or more, which `cygpath` gives in that form: move the vault
   nearer a drive root, or point `TMPDIR` at a shorter folder. A runner started outside Git Bash whose
   Claude Code is Windows' `claude.exe`, named in `CLAUDE_BIN` or found on `PATH`, directly or
   through a link, now refuses with `looks like a Windows program`; run the `.cmd` runner instead.
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
    runner trusts the tripwire, in-flight marker and backup it keeps there. Make the folder yourself. If `mkdir` says
    it already exists, check its owner with `dir /q C:\` or `(Get-Acl C:\vault-state).Owner`, and
    do not use one another account owns, because its owner can change its permissions back at any
    time. In Command Prompt run
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
    for the same reason. Then set `VAULT_STATE_DIR` to `C:\vault-state\my-vault`. The vault itself may stay
    under the profile, because the memory override now converts its path faithfully (other path
    checks still convert under `C`; `docs/reference.md` § 4.3, Known limits). Give `VAULT_STATE_DIR`
    an ASCII path on Windows. A non-ASCII one is used under a double-encoded name the runner makes
    itself beside the folder you named, which takes its parent's permissions, not yours: directly
    under `C:\`, every signed-in account could then change the state it holds (measured), and where
    you cannot create folders, as in `C:\Users`, every pass exits 1. The memory override's settings
    file is not kept in the state directory (Changed).
12. **The override was measured on Claude Code 2.1.284, 2.1.285, 2.1.287 and 2.1.289 only.**
    2.1.284 for a named folder, 2.1.285 for the default folder too, 2.1.287 for both again, the
    non-ASCII paths and the fail-open on an empty or invalid file, and 2.1.289 for the named and
    default folders, the Cyrillic and `"` vaults, glob and trailing-dot names, a drive root, a
    mapped network drive and the network paths it does not honour; the fail-open was not re-run
    there. Any other version, older or newer, is unmeasured, and a native install updates itself:
    `claude --version` says which one a pass will run.
13. **If your `dream-agent.md` still names `Skill`, it keeps working**, because the call was already
    refused under `-p` (measured on Claude Code 2.1.284). In that vault `run-tests.sh`'s
    `dream-agent-tools` control fails until you remove `Skill` from its `tools:` line.
14. **On Windows a vault on a network path no longer runs from Git Bash.** A vault reached as
    `//server/share/...` or `//wsl.localhost/...` (a NAS share, the WSL file system, a Documents
    folder redirected to a server) ran a claude-mode pass from Git Bash under an earlier build of
    this release, but Claude Code did not honour the memory override for it (measured), so such a
    pass now exits 1 with `cygpath gave //... for a path of the memory override, which is not a
    Windows drive path`. Move the vault to a local drive, or reach
    the share through a mapped drive letter (`net use Z: \\server\share`), which runs: for one drive
    mapped to an SMB share, a memory Write to the default folder was refused (Claude Code 2.1.289,
    through `dream-pass.cmd`). The `.cmd` wrappers never could start a vault on a network path.

`--check` will list `.claude/scripts/lib/runner-common.sh`, `.claude/scripts/dream-pass.sh`,
`.claude/scripts/promotion-pass.sh`, `.claude/scripts/run-tests.sh`, `.claude/agents/dream-agent.md`,
both copies of `onboard-project/SKILL.md` (under `.claude/skills/` and `.agents/skills/`),
`AGENTS.md`, `docs/reference.md`, `docs/setup.md`, `docs/customizing.md` and
`docs/harnesses/claude-code.md` as safe to take, alongside `VERSION` and `CHANGELOG.md`. Take the
three runner files in one step (item 1). If you customized `dream-agent.md`, `AGENTS.md` or one of
the docs, take it as a merge rather than a copy. `README.md` changed in one line too; it is yours
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
