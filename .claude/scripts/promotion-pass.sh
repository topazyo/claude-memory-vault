#!/usr/bin/env bash
# .claude/scripts/promotion-pass.sh
#
# Scheduled runner for the promotion-agent (weekly medium -> long promotion).
# For cron on Linux, or launchd on macOS. The Windows equivalent is
# promotion-pass.cmd, driven by Task Scheduler.
#
# READ THIS BEFORE SCHEDULING IT.
# Unlike the dream-agent, the promotion-agent WRITES into 31-standards/ and
# 40-llm-wiki/wiki/ - your long tier, the notes that steer every future session.
# Its only guard is its own definition (.claude/agents/promotion-agent.md), which
# requires a git snapshot before any write. Run it unattended only once you have
# read that file and are happy with the bar it applies. Running it manually first,
# a few times, is the sensible default.
#
# EXAMPLE cron entry (Saturday 20:00):
#   0 20 * * 6 /path/to/your-vault/.claude/scripts/promotion-pass.sh

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

LOG_DIR="$ROOT/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG="$LOG_DIR/promotion-agent.log"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  printf '[%s] ERROR: claude binary not found (tried "%s"). Set CLAUDE_BIN.\n' \
    "$(date -Iseconds)" "$CLAUDE_BIN" >> "$LOG"
  exit 127
fi

# Snapshot BOTH signals before the run. A pass that legitimately promotes nothing
# is a valid outcome, so we accept either a new long-tier note OR substantive log
# growth - but never neither. Counting with awk, not `grep -c`: grep -c prints 0
# AND exits 1 on no-match, so `n=$(grep -c x f || echo 0)` yields "0\n0" and
# breaks the arithmetic comparison below.
count_long() {
  find "$ROOT/31-standards" "$ROOT/40-llm-wiki/wiki" \
    -path '*/templates/*' -prune -o -type f -name '*.md' -print 2>/dev/null \
    | awk 'END{print NR+0}'
}
log_size() {
  [ -f "$LOG" ] && wc -c < "$LOG" | tr -d ' ' || echo 0
}

BEFORE_COUNT="$(count_long)"
SIZE_BEFORE="$(log_size)"

printf '[%s] starting promotion-agent weekly pass\n' "$(date -Iseconds)" >> "$LOG"

# -p is REQUIRED; see the note in dream-pass.sh. Without it this becomes an
# interactive session that exits 0 in seconds having done nothing.
"$CLAUDE_BIN" -p "Run this week's promotion pass per your instructions: scan 20-projects/_logs/ for promotion candidates, run the trust sweep over the long-term notes, and write the ones that meet the promotion bar. Follow your write-safety rules -- take a git snapshot before any write and abort on unexpected drift." \
  --agent promotion-agent \
  --permission-mode acceptEdits >> "$LOG" 2>&1
RC=$?

printf '[%s] promotion-agent exited with code %s\n' "$(date -Iseconds)" "$RC" >> "$LOG"

AFTER_COUNT="$(count_long)"
SIZE_AFTER="$(log_size)"
GREW=$(( SIZE_AFTER - SIZE_BEFORE ))

if [ "$RC" -eq 0 ] && [ "$AFTER_COUNT" -le "$BEFORE_COUNT" ] && [ "$GREW" -le 500 ]; then
  printf '[%s] NO-ARTIFACT: exited 0 with no new long-tier note and only %s bytes of log growth (threshold 500)\n' \
    "$(date -Iseconds)" "$GREW" >> "$LOG"
  exit 1
fi

exit "$RC"
