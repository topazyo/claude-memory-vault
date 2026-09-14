#!/usr/bin/env bash
# .claude/scripts/promotion-pass.sh
#
# Scheduled runner for the promotion-agent (weekly medium -> long promotion).
# For launchd on macOS or cron on Linux. On Windows, promotion-pass.cmd calls
# this same script through Git Bash, so there is exactly one implementation.
#
# READ THIS BEFORE SCHEDULING IT.
# Unlike the dream-agent, the promotion-agent WRITES into 31-standards/ and
# 40-llm-wiki/wiki/ - your long tier, the notes that steer every future session.
# Its own definition (.claude/agents/promotion-agent.md) requires a git snapshot
# before any write. This runner adds a second, mechanical fence: it snapshots
# the vault before the run and fails the run if anything changed OUTSIDE the
# areas a promotion pass may write. Run it manually a few times first.
#
# EXAMPLE cron entry (Saturday 20:00):
#   0 20 * * 6 /path/to/your-vault/.claude/scripts/promotion-pass.sh
#
# Environment:
#   VAULT_AGENT             claude (default) or command; see lib/runner-common.sh
#   CLAUDE_BIN              path to the claude binary (schedulers get a minimal PATH)
#   VAULT_AGENT_CMD         command mode: your wrapper around another harness
#   VAULT_ALLOW_UNENFORCED_TOOLS  command mode: set to 1 once the wrapper is
#                           sandboxed (git only, no network), or the run is refused
#   PROMOTION_PASS_TIMEOUT  seconds before a hung run is killed (default 5400)
#
# Exit codes:
#   0    the pass reported a summary or changed the long tier, and wrote nowhere else
#   1    NO-ARTIFACT: exited 0 with no summary line and no long-tier change
#   2    VIOLATION: files outside the allowed write areas changed during the run
#   3    REFUSED: command mode without VAULT_ALLOW_UNENFORCED_TOOLS=1
#   64   VAULT_AGENT is not claude or command
#   124  TIMEOUT: the watchdog killed a run that exceeded PROMOTION_PASS_TIMEOUT
#   127  the claude binary or the VAULT_AGENT_CMD wrapper was not found
#   *    any other non-zero status is the agent's own

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
# shellcheck source=lib/runner-common.sh
. "$ROOT/.claude/scripts/lib/runner-common.sh"

LOG_DIR="$ROOT/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG="$LOG_DIR/promotion-agent.log"
RUN_OUT="$LOG_DIR/promotion-agent.run.log"
TIMEOUT="${PROMOTION_PASS_TIMEOUT:-5400}"

# The agent is asked to end with this exact line. It is the positive evidence
# that a pass reached its end: an error dump, however long, does not contain it.
SUMMARY_MARKER='PROMOTION-SUMMARY:'

agent_preflight "$LOG"
preflight_rc=$?
[ "$preflight_rc" -eq 0 ] || exit "$preflight_rc"

TASK="Run this week's promotion pass per your instructions: scan 20-projects/_logs/ for promotion candidates, run the trust sweep over the long-term notes, and write the ones that meet the promotion bar. Follow your write-safety rules -- take a git snapshot before any write and abort on unexpected drift. End your final message with one line of the form: ${SUMMARY_MARKER} promoted=<n> pending=<n>"
PROMPT_REL=".claude/logs/promotion-pass.prompt.md"
if [ "$AGENT_KIND" = command ]; then
  DEF="$ROOT/.claude/agents/promotion-agent.md"
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

SNAP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t promopass)" || {
  printf '[%s] ERROR: could not create a temporary directory\n' "$(ts)" >> "$LOG"
  exit 1
}
trap 'rm -rf "$SNAP_DIR"' EXIT
trap 'rm -rf "$SNAP_DIR"; exit 130' INT
trap 'rm -rf "$SNAP_DIR"; exit 143' TERM

snapshot_tree "$ROOT" "$SNAP_DIR/before" "$AGENT_KIND"
printf '[%s] starting promotion-agent weekly pass via %s (timeout %ss)\n' "$(ts)" "$AGENT_KIND" "$TIMEOUT" >> "$LOG"

# This run's output goes to its own file, so the evidence checked below is the
# agent's output from THIS run - never the runner's own log lines, never a
# previous run's. It is appended to the history log afterwards.
: > "$SNAP_DIR/run"

run_agent "$TIMEOUT" "$SNAP_DIR/run" promotion-agent "$TASK" "$PROMPT_REL"

cat "$SNAP_DIR/run" >> "$RUN_OUT" 2>/dev/null

snapshot_tree "$ROOT" "$SNAP_DIR/after" "$AGENT_KIND"
changed_paths "$SNAP_DIR/before" "$SNAP_DIR/after" > "$SNAP_DIR/changed"

if [ "$RUN_TIMED_OUT" -eq 1 ]; then
  printf '[%s] TIMEOUT: promotion-agent exceeded %ss and was killed (status %s)\n' \
    "$(ts)" "$TIMEOUT" "$RUN_RC" >> "$LOG"
  exit 124
fi

printf '[%s] promotion-agent exited with code %s\n' "$(ts)" "$RUN_RC" >> "$LOG"

# WRITE FENCE. A promotion pass may write long-tier notes (never their
# templates), a promotion report in 20-projects/_logs/, and nothing else. An
# auto-written compaction stub is tolerated. Anything else - a rule, an agent
# definition, CLAUDE.md, someone's daily note - is a violation.
grep -vE '^(31-standards|40-llm-wiki/wiki)/' "$SNAP_DIR/changed" \
  | grep -vE '^20-projects/_logs/(promotion-|compaction-)[^/]*\.md$' > "$SNAP_DIR/outside"
grep -E '^(31-standards|40-llm-wiki/wiki)/(.*/)?templates/' "$SNAP_DIR/changed" >> "$SNAP_DIR/outside"
if [ -s "$SNAP_DIR/outside" ]; then
  printf '[%s] VIOLATION: files outside the allowed write areas changed during the run:\n' "$(ts)" >> "$LOG"
  LC_ALL=C sort -u "$SNAP_DIR/outside" | sed 's/^/    /' >> "$LOG"
  exit 2
fi

[ "$RUN_RC" -ne 0 ] && exit "$RUN_RC"

# ARTIFACT ASSERTION. Promoting nothing is a legitimate outcome, so a pass may
# change no note at all - but then it must say so with the summary line. A pass
# with neither a long-tier change nor a summary produced no evidence it ran.
summary="$(grep -E "^${SUMMARY_MARKER}" "$SNAP_DIR/run" | tail -n 1)"
long_changes="$(awk '/^(31-standards|40-llm-wiki\/wiki)\//{n++} END{print n+0}' "$SNAP_DIR/changed")"
if [ -z "$summary" ] && [ "${long_changes:-0}" -eq 0 ]; then
  printf '[%s] NO-ARTIFACT: exited 0 with no %s line and no long-tier change\n' \
    "$(ts)" "$SUMMARY_MARKER" >> "$LOG"
  exit 1
fi

printf '[%s] OK: %s long-tier file(s) changed; %s\n' \
  "$(ts)" "${long_changes:-0}" "${summary:-no summary line}" >> "$LOG"
exit 0
