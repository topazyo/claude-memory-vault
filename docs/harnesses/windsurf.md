# Windsurf / Devin Desktop

Windsurf's documentation now lives under Devin Desktop, and the product is named that way there.
This guide covers Cascade, its agent. Cascade treats a root `AGENTS.md` as an always-on rule, and
the template ships workspace hooks for the lint and for a secrets read guard.

## What ships

| File | What it does |
| --- | --- |
| `.windsurf/hooks.json` | `pre_read_code` runs `read-guard.sh`, which blocks reads of `.env`, `.env.*` and `secrets/`; `post_write_code` runs `vault-lint.sh` |

Hooks run from the workspace root. Each hook has a `command` for macOS and Linux (run with
`bash -c`) and a `powershell` entry for Windows that calls Git Bash at
`%ProgramFiles%\Git\bin\bash.exe`, rather than a bare `bash` that could resolve to WSL.

## Enforced, and guidance

- **Enforced:** the lint after Cascade writes code files, and the read guard, which exits 2 and so
  blocks the read.
- **No compaction stub:** none of Cascade's twelve hook events fires on compaction.
- **Not covered:** a terminal command run by Cascade can still read a secret or write a note
  unlinted. The rule and the commit gate cover those.

## Setup

1. Open the vault folder as the workspace, and leave Restricted Mode. Hooks do not run in
   Restricted Mode.
2. On Windows, if Git for Windows is not installed under `%ProgramFiles%\Git`, edit both
   `powershell` entries in `.windsurf/hooks.json` to point at your `bash.exe`.

## Onboarding prompt

```text
Onboard this vault for Windsurf / Devin Desktop (Cascade). Work from the vault root.

1. Follow docs/harnesses/README.md, section "Common onboarding checklist", steps O1 to O6.
   Write the O4 probe with your file-writing tool.
2. Then run the checks in docs/harnesses/windsurf.md, section "Harness-specific checks".
3. Report every step as PASS, FAILED or NOT VERIFIED, with the evidence for each PASS.

Do not repair anything you find broken, and do not change settings outside this repository
without asking me.
```

## Harness-specific checks

- **H1. Read guard blocks.** Create `secrets/harness-probe.txt` containing `not a secret` (the
  folder is gitignored), then try to read it with your read tool. PASS if the read is refused and
  `.claude/logs/read-guard.log` gains a `BLOCKED:` line naming it. Afterwards delete the probe
  file and the `secrets/` folder if you created it. They are test artifacts, not notes.
- **H2. Hook failure causes.** If O4 or H1 FAILED: the workspace is in Restricted Mode; `bash` is
  missing or, on Windows, the `powershell` entry points at the wrong `bash.exe`. If
  `.claude/logs/read-guard.log` shows `DEGRADED: no path` and every read is being refused, the
  hook ran but received no input, which on Windows points at the PowerShell entry not passing
  stdin through. Name the cause you can confirm.

## Scheduled passes

Not covered. No headless Cascade command was documented for this purpose. Run the scheduled
passes with Claude Code or another harness whose guide gives a wrapper.

## Known limits

- The read guard fails **closed** on its hook input: if it cannot read a path, it blocks the read
  and logs `DEGRADED`. On a broken setup every read is refused, which you notice at once, rather
  than every read quietly going unchecked.
- It cannot fail closed when it never runs. If Windows cannot start the `bash.exe` in the
  `powershell` entry, the hook exits with an error other than 2 and Cascade lets the read
  through. H1 is how you find out. Until H1 passes on your machine, treat the guard as NOT
  VERIFIED.
- Skills were not researched for Cascade. Ask the agent to follow a `SKILL.md` as a checklist.

## Sources (checked 2026-09-13)

- AGENTS.md: <https://docs.windsurf.com/windsurf/cascade/agents-md>
- Rules and memories: <https://docs.windsurf.com/windsurf/cascade/memories>
- Cascade hooks (file locations, events, `pre_read_code` exit 2, `post_write_code` input, `command`/`powershell`, working directory, Restricted Mode): <https://docs.devin.ai/desktop/cascade/hooks>
