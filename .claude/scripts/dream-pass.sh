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
#   VAULT_AGENT         claude (default) or command; see lib/runner-common.sh
#   CLAUDE_BIN          path to the claude binary (schedulers get a minimal PATH)
#   VAULT_AGENT_CMD     command mode: your wrapper around another harness
#   VAULT_ALLOW_UNENFORCED_TOOLS  command mode: set to 1 once the wrapper is
#                       sandboxed (no shell, no network), or the run is refused
#   DREAM_PASS_TIMEOUT  seconds before a hung run is killed (default 3600)
#
# Exit codes:
#   0    the pass changed a dream journal and nothing else
#   1    NO-ARTIFACT: exited 0 but no dream journal was added or changed
#   2    VIOLATION: files outside the dream journals changed during the run
#   3    REFUSED: command mode without VAULT_ALLOW_UNENFORCED_TOOLS=1
#   64   VAULT_AGENT is not claude or command
#   124  TIMEOUT: the watchdog killed a run that exceeded DREAM_PASS_TIMEOUT
#   127  the claude binary or the VAULT_AGENT_CMD wrapper was not found
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

agent_preflight "$LOG"
preflight_rc=$?
[ "$preflight_rc" -eq 0 ] || exit "$preflight_rc"

TASK="Run tonight's dream/consolidation pass and write today's dream journal per your instructions. The repository state recorded before this run is in .claude/logs/dream-pass.git-state.txt."
PROMPT_REL=".claude/logs/dream-pass.prompt.md"
if [ "$AGENT_KIND" = command ]; then
  DEF="$ROOT/.claude/agents/dream-agent.md"
  if [ ! -f "$DEF" ]; then
    printf '[%s] ERROR: agent definition not found: %s\n' "$(ts)" "$DEF" >> "$LOG"
    exit 1
  fi
  # Remove any earlier prompt first, so a failed write can never leave the
  # agent reading a stale one.
  rm -f "$ROOT/$PROMPT_REL"
  if ! write_agent_prompt "$DEF" "$TASK" "$ROOT/$PROMPT_REL"; then
    printf '[%s] ERROR: could not write the prompt file %s\n' "$(ts)" "$PROMPT_REL" >> "$LOG"
    exit 1
  fi
fi

SNAP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t dreampass)" || {
  printf '[%s] ERROR: could not create a temporary directory\n' "$(ts)" >> "$LOG"
  exit 1
}
trap 'rm -rf "$SNAP_DIR"' EXIT
trap 'rm -rf "$SNAP_DIR"; exit 130' INT
trap 'rm -rf "$SNAP_DIR"; exit 143' TERM

# The agent is given no shell, so it cannot run git itself. Record the
# repository state here for it to read, instead of widening its tool list.
{
  printf 'Recorded by dream-pass.sh at %s, before the agent started.\n\n' "$(ts)"
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '## git log --oneline -5\n'; git -C "$ROOT" log --oneline -5 2>&1
    printf '\n## git status --short\n'; git -C "$ROOT" status --short 2>&1
  else
    printf 'This vault is not a git repository; no history is available.\n'
  fi
} > "$LOG_DIR/dream-pass.git-state.txt" 2>/dev/null

snapshot_tree "$ROOT" "$SNAP_DIR/before" "$AGENT_KIND"

printf '[%s] starting dream-agent via %s (timeout %ss)\n' "$(ts)" "$AGENT_KIND" "$TIMEOUT" >> "$LOG"

run_agent "$TIMEOUT" "$RUN_OUT" dream-agent "$TASK" "$PROMPT_REL"

snapshot_tree "$ROOT" "$SNAP_DIR/after" "$AGENT_KIND"
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
