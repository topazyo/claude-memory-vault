#!/usr/bin/env bash
# .claude/scripts/dream-pass.sh
#
# Scheduled runner for the dream-agent (nightly consolidation pass).
# For cron on Linux, or launchd on macOS. The Windows equivalent is
# dream-pass.cmd, driven by Task Scheduler.
#
# The dream-agent is READ-AND-PROPOSE ONLY: its single write is one dated
# journal at 20-projects/_logs/dream-<date>.md. That constraint is what makes
# running it unattended acceptable, so the agent definition and this runner are
# a safety PAIR - read .claude/agents/dream-agent.md before changing either.
#
# EXAMPLE cron entry (23:00 nightly):
#   0 23 * * * /path/to/your-vault/.claude/scripts/dream-pass.sh
#
# Cron runs with a minimal PATH and no interactive profile, so set CLAUDE_BIN
# below (or export it in the crontab) if `claude` is not on the default PATH.

set -u

# Resolve the vault root from this script's own location, so the file is
# portable and contains no absolute paths.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

LOG_DIR="$ROOT/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG="$LOG_DIR/dream-agent.log"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  printf '[%s] ERROR: claude binary not found (tried "%s"). Set CLAUDE_BIN.\n' \
    "$(date -Iseconds)" "$CLAUDE_BIN" >> "$LOG"
  exit 127
fi

TODAY="$(date +%F)"
JOURNAL="$ROOT/20-projects/_logs/dream-$TODAY.md"

printf '[%s] starting dream-agent\n' "$(date -Iseconds)" >> "$LOG"

# -p is REQUIRED. Without it, `claude --agent X` starts an INTERACTIVE session;
# under a scheduler there is no TTY and stdin is /dev/null, so it reads EOF and
# exits 0 within seconds having done nothing. That failure is invisible - the
# scheduler records success - which is why the artifact assertion below exists.
"$CLAUDE_BIN" -p "Run tonight's dream/consolidation pass and write today's dream journal per your instructions." \
  --agent dream-agent \
  --permission-mode acceptEdits >> "$LOG" 2>&1
RC=$?

printf '[%s] dream-agent exited with code %s\n' "$(date -Iseconds)" "$RC" >> "$LOG"

# ARTIFACT ASSERTION.
# An exit code says the process ended; it does not say the pass did anything.
# The dream-agent's whole contract is "write exactly one journal", so the journal
# either exists or the run failed - regardless of what the exit code claims.
# Turning a silent no-op into a non-zero status is the entire point: a green
# scheduler entry that produces nothing rots unnoticed for weeks.
if [ "$RC" -eq 0 ] && [ ! -f "$JOURNAL" ]; then
  printf '[%s] NO-ARTIFACT: exited 0 but %s was not written\n' \
    "$(date -Iseconds)" "$JOURNAL" >> "$LOG"
  exit 1
fi

exit "$RC"
