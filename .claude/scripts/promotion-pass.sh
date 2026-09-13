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
#   CLAUDE_BIN              path to the claude binary (schedulers get a minimal PATH)
#   PROMOTION_PASS_TIMEOUT  seconds before a hung run is killed (default 5400)
#
# Exit codes:
#   0    the pass reported a summary or changed the long tier, and wrote nowhere else
#   1    NO-ARTIFACT: exited 0 with no summary line and no long-tier change
#   2    VIOLATION: files outside the allowed write areas changed during the run
#   124  TIMEOUT: the watchdog killed a run that exceeded PROMOTION_PASS_TIMEOUT
#   127  the claude binary was not found
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

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  printf '[%s] ERROR: claude binary not found (tried "%s"). Set CLAUDE_BIN.\n' \
    "$(ts)" "$CLAUDE_BIN" >> "$LOG"
  exit 127
fi

SNAP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t promopass)" || {
  printf '[%s] ERROR: could not create a temporary directory\n' "$(ts)" >> "$LOG"
  exit 1
}
trap 'rm -rf "$SNAP_DIR"' EXIT
trap 'rm -rf "$SNAP_DIR"; exit 130' INT
trap 'rm -rf "$SNAP_DIR"; exit 143' TERM

snapshot_tree "$ROOT" "$SNAP_DIR/before"
printf '[%s] starting promotion-agent weekly pass (timeout %ss)\n' "$(ts)" "$TIMEOUT" >> "$LOG"

# This run's output goes to its own file, so the evidence checked below is the
# agent's output from THIS run - never the runner's own log lines, never a
# previous run's. It is appended to the history log afterwards.
: > "$SNAP_DIR/run"

# -p is REQUIRED; see the note in dream-pass.sh.
run_with_watchdog "$TIMEOUT" "$SNAP_DIR/run" \
  "$CLAUDE_BIN" -p "Run this week's promotion pass per your instructions: scan 20-projects/_logs/ for promotion candidates, run the trust sweep over the long-term notes, and write the ones that meet the promotion bar. Follow your write-safety rules -- take a git snapshot before any write and abort on unexpected drift. End your final message with one line of the form: ${SUMMARY_MARKER} promoted=<n> pending=<n>" \
  --agent promotion-agent \
  --permission-mode acceptEdits

cat "$SNAP_DIR/run" >> "$RUN_OUT" 2>/dev/null

snapshot_tree "$ROOT" "$SNAP_DIR/after"
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
