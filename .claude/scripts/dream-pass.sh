#!/usr/bin/env bash
# .claude/scripts/dream-pass.sh
#
# Scheduled runner for the dream-agent (nightly consolidation pass).
# For launchd on macOS or cron on Linux. On Windows, dream-pass.cmd calls this
# same script through Git Bash, so there is exactly one implementation.
#
# The dream-agent is READ-AND-PROPOSE ONLY: its single write is one dated
# journal at 20-projects/_logs/dream-<date>.md. That constraint is what makes an
# unattended run acceptable - and an instruction to a model is not a sandbox. So
# this runner does not trust it. It snapshots the vault before the run and
# reports any change outside the dream journals afterwards, and it fails a run
# that produced no journal change at all.
#
# EXAMPLE cron entry (23:00 nightly):
#   0 23 * * * /path/to/your-vault/.claude/scripts/dream-pass.sh
#
# Environment:
#   CLAUDE_BIN          path to the claude binary (schedulers get a minimal PATH)
#   DREAM_PASS_TIMEOUT  seconds before a hung run is killed (default 3600)
#
# Exit codes:
#   0    the pass changed a dream journal and nothing else
#   1    NO-ARTIFACT: exited 0 but no dream journal was added or changed
#   2    VIOLATION: files outside the dream journals changed during the run
#   124  TIMEOUT: the watchdog killed a run that exceeded DREAM_PASS_TIMEOUT
#   127  the claude binary was not found
#   *    any other non-zero status is the agent's own

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
# shellcheck source=lib/runner-common.sh
. "$ROOT/.claude/scripts/lib/runner-common.sh"

LOG_DIR="$ROOT/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG="$LOG_DIR/dream-agent.log"
RUN_OUT="$LOG_DIR/dream-agent.run.log"
TIMEOUT="${DREAM_PASS_TIMEOUT:-3600}"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  printf '[%s] ERROR: claude binary not found (tried "%s"). Set CLAUDE_BIN.\n' \
    "$(ts)" "$CLAUDE_BIN" >> "$LOG"
  exit 127
fi

SNAP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t dreampass)" || {
  printf '[%s] ERROR: could not create a temporary directory\n' "$(ts)" >> "$LOG"
  exit 1
}
trap 'rm -rf "$SNAP_DIR"' EXIT
trap 'rm -rf "$SNAP_DIR"; exit 130' INT
trap 'rm -rf "$SNAP_DIR"; exit 143' TERM

# The agent has no Bash tool, so it cannot run git itself. Record the repository
# state here for it to read, instead of widening its tool list.
{
  printf 'Recorded by dream-pass.sh at %s, before the agent started.\n\n' "$(ts)"
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '## git log --oneline -5\n'; git -C "$ROOT" log --oneline -5 2>&1
    printf '\n## git status --short\n'; git -C "$ROOT" status --short 2>&1
  else
    printf 'This vault is not a git repository; no history is available.\n'
  fi
} > "$LOG_DIR/dream-pass.git-state.txt" 2>/dev/null

snapshot_tree "$ROOT" "$SNAP_DIR/before"

printf '[%s] starting dream-agent (timeout %ss)\n' "$(ts)" "$TIMEOUT" >> "$LOG"

# -p is REQUIRED. Without it, `claude --agent X` starts an INTERACTIVE session;
# under a scheduler there is no TTY, so it either reads EOF and exits 0 having
# done nothing, or waits on input that never arrives. Both look like success to
# the scheduler, which is why the artifact assertion below exists.
run_with_watchdog "$TIMEOUT" "$RUN_OUT" \
  "$CLAUDE_BIN" -p "Run tonight's dream/consolidation pass and write today's dream journal per your instructions. The repository state recorded before this run is in .claude/logs/dream-pass.git-state.txt." \
  --agent dream-agent \
  --permission-mode acceptEdits

snapshot_tree "$ROOT" "$SNAP_DIR/after"
changed_paths "$SNAP_DIR/before" "$SNAP_DIR/after" > "$SNAP_DIR/changed"

if [ "$RUN_TIMED_OUT" -eq 1 ]; then
  printf '[%s] TIMEOUT: dream-agent exceeded %ss and was killed (status %s)\n' \
    "$(ts)" "$TIMEOUT" "$RUN_RC" >> "$LOG"
  exit 124
fi

printf '[%s] dream-agent exited with code %s\n' "$(ts)" "$RUN_RC" >> "$LOG"

# SINGLE-WRITE FENCE. Anything that changed other than a dream journal - or an
# auto-written compaction stub - was written by a pass that is only allowed to
# write its journal. If something else writes to the vault while the pass runs
# (a sync client, an editor), this fires too; the paths it names tell you which.
grep -vE '^20-projects/_logs/(dream-|compaction-)[^/]*\.md$' "$SNAP_DIR/changed" > "$SNAP_DIR/outside"
if [ -s "$SNAP_DIR/outside" ]; then
  printf '[%s] VIOLATION: files outside the dream journal changed during the run:\n' "$(ts)" >> "$LOG"
  sed 's/^/    /' "$SNAP_DIR/outside" >> "$LOG"
  exit 2
fi

[ "$RUN_RC" -ne 0 ] && exit "$RUN_RC"

# ARTIFACT ASSERTION. An exit code says the process ended; it does not say the
# pass did anything. A dream journal must have been ADDED or CHANGED during this
# run. Matching any dream-*.md, rather than today's date computed up front,
# means a 23:59 run that writes after midnight still counts, and a journal left
# by an earlier run on the same day does not pre-satisfy the check.
if ! grep -qE '^20-projects/_logs/dream-[^/]*\.md$' "$SNAP_DIR/changed"; then
  printf '[%s] NO-ARTIFACT: exited 0 but no dream journal was added or changed\n' "$(ts)" >> "$LOG"
  exit 1
fi

printf '[%s] OK: %s\n' "$(ts)" "$(grep -E '^20-projects/_logs/dream-' "$SNAP_DIR/changed" | tr '\n' ' ')" >> "$LOG"
exit 0
