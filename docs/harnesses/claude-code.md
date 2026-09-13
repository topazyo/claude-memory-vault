# Claude Code

Claude Code gets the most automation, because the template was built on it. Everything below
already works when you start Claude Code from the vault root.

## What ships

| File | What it does |
| --- | --- |
| `CLAUDE.md` | Imports `AGENTS.md` and `30-knowledge/moc/ARCH-INDEX.md`, and lists the Claude-only extras |
| `.claude/settings.json` | Registers the three hooks (`PostToolUse` lint, `PostCompact` stub, `InstructionsLoaded` audit) and denies reads of `.env`, `.env.*`, `secrets/**` |
| `.claude/rules/*.md` | Loaded automatically; three are path-scoped |
| `.claude/skills/*/SKILL.md` | The five skills, as slash commands |
| `.claude/agents/*.md` | `dream-agent` and `promotion-agent`, with `tools:` allowlists |

## Enforced, and guidance

- **Enforced:** the lint after every Write or Edit, the compaction stub, the Read deny for the
  three secret paths (not for shell commands such as `cat`), and each agent's tool allowlist in
  the scheduled passes.
- **Guidance:** everything else in `.claude/rules/security.md`, and the note contract itself,
  which the lint reports on but never blocks.

## Setup

Start Claude Code with the vault as the working directory. Nothing else is required. Enable the
commit gate if you want violations to stop a commit.

## Onboarding prompt

```text
Onboard this vault for Claude Code. Work from the vault root.

1. Follow docs/harnesses/README.md, section "Common onboarding checklist", steps O1 to O6.
2. Then run the checks in docs/harnesses/claude-code.md, section "Harness-specific checks".
3. Report every step as PASS, FAILED or NOT VERIFIED, with the evidence for each PASS.

Do not repair anything you find broken, and do not change settings outside this repository
without asking me.
```

## Harness-specific checks

- **H1. Hooks registered.** Ask the human to run `/hooks` and confirm `PostToolUse`,
  `PostCompact` and `InstructionsLoaded` each list a `.claude/hooks/` script. You cannot open
  that menu yourself, so record their answer, or NOT VERIFIED.
- **H2. Instruction audit.** Read `.claude/logs/instructions-loaded.log`. PASS if it has
  `session_start` entries for this session naming `CLAUDE.md`.
- **H3. Read deny.** Use the Read tool on `.env` (the file does not need to exist). PASS if the
  tool reports the read was denied by permissions. A "file not found" error means the deny did
  not apply: FAILED.
- **H4. Compaction stub.** NOT VERIFIED unless the session compacts. If it does, a
  `20-projects/_logs/compaction-<session>.md` file gains an entry.

## Scheduled passes

The runners use Claude Code by default (`VAULT_AGENT=claude`), and the agents' allowlists are
enforced. See `docs/setup.md` § 8.

## Sources

Configured and tested in this repository's control suite. See `docs/reference.md` § 3 and § 4.3.
