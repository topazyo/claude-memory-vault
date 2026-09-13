#!/usr/bin/env bash
# .claude/scripts/lib/runner-common.sh
#
# Shared helpers for the scheduled runners (dream-pass.sh, promotion-pass.sh).
# Sourced, not executed. Bash 3.2 compatible (macOS /bin/bash), no GNU-only
# flags, no jq.
#
# The runners exist to make an UNATTENDED agent run trustworthy, and each helper
# below closes one way such a run fails quietly:
#
#   ts                 an undated log cannot tell last night from last month
#   run_with_watchdog  a hung run never exits, so the next run never starts
#   snapshot_tree      an agent told "write only X" is trusting a prompt; the
#   changed_paths      snapshot diff turns that instruction into a detected fence

# Portable ISO-8601 timestamp. `date -Iseconds` is a GNU extension: BSD/macOS
# date has no -I flag, and an unguarded call yields an empty string.
ts() {
  date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z
}

# run_with_watchdog <timeout-seconds> <output-file> <command> [args...]
#
# Runs the command with stdin at /dev/null (it must never wait for input), its
# output appended to <output-file>, and a watchdog that sends TERM when the
# timeout elapses and KILL after a grace period. Sets two globals:
#   RUN_RC         the command's exit status (143/137 when the watchdog fired)
#   RUN_TIMED_OUT  1 if the watchdog fired, else 0
#
# The watchdog polls rather than sleeping for the full timeout, so it exits on
# its own within one poll interval of the command finishing and never outlives
# the run by more than that. WATCHDOG_POLL and WATCHDOG_GRACE are overridable so
# the test suite can exercise the timeout path in seconds instead of hours.
run_with_watchdog() {
  local timeout="$1" out="$2"
  shift 2
  local poll="${WATCHDOG_POLL:-5}" grace="${WATCHDOG_GRACE:-15}"
  local flag
  flag="$(mktemp 2>/dev/null || mktemp -t runner)" || flag="${out}.timed-out"
  rm -f "$flag"

  "$@" </dev/null >>"$out" 2>&1 &
  local pid=$!

  (
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$waited" -ge "$timeout" ]; then
        : >"$flag"
        kill -TERM "$pid" 2>/dev/null
        g=0
        while [ "$g" -lt "$grace" ] && kill -0 "$pid" 2>/dev/null; do
          sleep 1
          g=$((g + 1))
        done
        kill -KILL "$pid" 2>/dev/null
        exit 0
      fi
      sleep "$poll"
      waited=$((waited + poll))
    done
  ) &
  local watchdog=$!

  wait "$pid"
  RUN_RC=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null

  RUN_TIMED_OUT=0
  if [ -f "$flag" ]; then
    RUN_TIMED_OUT=1
    rm -f "$flag"
  fi
  return 0
}

# snapshot_tree <root> <output-file>
#
# Writes one "checksum size path" line per file under <root>, sorted. Pruned:
# .git/, .obsidian/ (Obsidian rewrites its workspace state while open),
# .claude/logs/ (the runner writes there), .claude/agent-memory*/ and
# 90-auto-memory/ (machine-managed memory Claude Code may update during a run).
# `find -exec ... +` rather than xargs: xargs with empty input runs cksum with
# no arguments on some platforms, and cksum would then wait on stdin forever.
snapshot_tree() {
  local root="$1" out="$2"
  (
    cd "$root" || exit 1
    find . \( -path ./.git -o -path ./.obsidian -o -path ./.claude/logs \
              -o -path './.claude/agent-memory*' -o -path ./90-auto-memory \) -prune \
         -o -type f -exec cksum {} + 2>/dev/null
  ) | LC_ALL=C sort >"$out"
}

# changed_paths <before-snapshot> <after-snapshot>
#
# Prints each path that was added, removed or modified between two snapshots,
# once, sorted. comm needs both inputs sorted under the same collation, which is
# why snapshot_tree sorts with LC_ALL=C.
changed_paths() {
  LC_ALL=C comm -3 "$1" "$2" \
    | sed 's/^[[:space:]]*//' \
    | cut -d' ' -f3- \
    | sed 's|^\./||' \
    | LC_ALL=C sort -u
}
