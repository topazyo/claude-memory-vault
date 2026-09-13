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
#   agent_preflight    a harness that cannot enforce a tool allowlist must not
#                      run an unattended pass unless someone said so on purpose
#   write_agent_prompt / run_agent   one invocation path per harness kind

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

# snapshot_tree <root> <output-file> [agent-kind]
#
# Writes one "checksum size path" line per file under <root>, sorted. Pruned:
# .git/, .obsidian/ (Obsidian rewrites its workspace state while open),
# .claude/logs/ (the runner writes there), and - in claude mode only -
# .claude/agent-memory*/ and 90-auto-memory/ (machine-managed memory Claude Code
# may update during a run). In command mode those two stay inside the fence:
# nothing legitimate writes there during a wrapper run, and memory files are
# loaded into later sessions, so an unseen write there would be a planted
# instruction rather than noise.
# `find -exec ... +` rather than xargs: xargs with empty input runs cksum with
# no arguments on some platforms, and cksum would then wait on stdin forever.
snapshot_tree() {
  local root="$1" out="$2" kind="${3:-claude}"
  (
    cd "$root" || exit 1
    if [ "$kind" = command ]; then
      find . \( -path ./.git -o -path ./.obsidian -o -path ./.claude/logs \) -prune \
           -o -type f -exec cksum {} + 2>/dev/null
    else
      find . \( -path ./.git -o -path ./.obsidian -o -path ./.claude/logs \
                -o -path './.claude/agent-memory*' -o -path ./90-auto-memory \) -prune \
           -o -type f -exec cksum {} + 2>/dev/null
    fi
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

# ---------------------------------------------------------------------------
# Which harness runs the agent.
#
#   VAULT_AGENT=claude   (default) The Claude Code CLI, CLAUDE_BIN or `claude`.
#                        The agent definition's `tools:` allowlist is enforced
#                        by Claude Code itself, so the dream-agent really has no
#                        shell.
#   VAULT_AGENT=command  VAULT_AGENT_CMD, an executable you write around any
#                        other harness. It is called from the vault root with
#                        ONE argument: the relative path of a prompt file that
#                        holds the agent's instructions and this run's task.
#                        It must `exec` the harness: the watchdog signals the
#                        wrapper's own process, so a harness left running as
#                        its child would survive a timeout and keep writing
#                        after the fence was checked.
#
# A wrapper cannot be made to honour a `tools:` allowlist, and the snapshot
# fence below sees only files changed inside the vault - not a shell command,
# not network traffic, not a write outside the vault. So command mode refuses
# to start unless VAULT_ALLOW_UNENFORCED_TOOLS=1 says the wrapper's own sandbox
# was set up to take the allowlist's place. A warning in an unattended log is
# not degrading loudly; a refusal is.

# agent_preflight <log-file>
#
# Sets AGENT_KIND and AGENT_BIN. Returns 0 when the run may start, otherwise
# the status the runner should exit with, after logging why:
#   3    REFUSED  command mode without VAULT_ALLOW_UNENFORCED_TOOLS=1
#   64   VAULT_AGENT is neither claude nor command
#   127  the claude binary or the VAULT_AGENT_CMD wrapper was not found
agent_preflight() {
  local log="$1"
  AGENT_KIND="${VAULT_AGENT:-claude}"
  AGENT_BIN=""
  case "$AGENT_KIND" in
    claude)
      AGENT_BIN="${CLAUDE_BIN:-claude}"
      if ! command -v "$AGENT_BIN" >/dev/null 2>&1; then
        printf '[%s] ERROR: claude binary not found (tried "%s"). Set CLAUDE_BIN, or set VAULT_AGENT=command to use another harness.\n' \
          "$(ts)" "$AGENT_BIN" >> "$log"
        return 127
      fi
      ;;
    command)
      if [ "${VAULT_ALLOW_UNENFORCED_TOOLS:-}" != "1" ]; then
        printf '[%s] REFUSED: VAULT_AGENT=command cannot enforce the agent'"'"'s tool allowlist. Sandbox the wrapper (no shell for the dream pass, no network), then set VAULT_ALLOW_UNENFORCED_TOOLS=1.\n' \
          "$(ts)" >> "$log"
        return 3
      fi
      AGENT_BIN="${VAULT_AGENT_CMD:-}"
      if [ -z "$AGENT_BIN" ] || ! command -v "$AGENT_BIN" >/dev/null 2>&1; then
        printf '[%s] ERROR: VAULT_AGENT=command but VAULT_AGENT_CMD is unset or not an executable (got "%s").\n' \
          "$(ts)" "$AGENT_BIN" >> "$log"
        return 127
      fi
      printf '[%s] WARNING: command mode (%s). The tool allowlist is NOT enforced by this runner; it relies on the wrapper'"'"'s sandbox and the snapshot fence.\n' \
        "$(ts)" "$AGENT_BIN" >> "$log"
      ;;
    *)
      printf '[%s] ERROR: unknown VAULT_AGENT "%s" (expected claude or command).\n' \
        "$(ts)" "$AGENT_KIND" >> "$log"
      return 64
      ;;
  esac
  return 0
}

# write_agent_prompt <agent-definition> <task> <output-file>
#
# The agent's instructions - its definition file minus the frontmatter, which
# only Claude Code reads - followed by this run's task. A file rather than a
# command-line argument: the prompt is kilobytes of Markdown full of quotes and
# backticks, which a .cmd or .bat wrapper would mangle, and stdin is not
# available because run_with_watchdog pins it to /dev/null.
write_agent_prompt() {
  local def="$1" task="$2" out="$3"
  {
    awk 'NR==1&&/^---[ \t\r]*$/{f=1;next} f==1&&/^---[ \t\r]*$/{f=2;next} f!=1{print}' "$def" \
      && printf '\n## Task for this run\n\n%s\n' "$task"
  } > "$out"
}

# run_agent <timeout> <output-file> <agent-name> <task> <prompt-file-relative>
#
# Starts the agent chosen by agent_preflight under the watchdog. The prompt
# file path is RELATIVE to the vault root, which is the working directory: an
# absolute Git Bash path such as /c/Users/... would reach a Windows wrapper
# only if MSYS path conversion happened to rewrite it.
run_agent() {
  local timeout="$1" out="$2" agent="$3" task="$4" prompt_rel="$5"
  case "$AGENT_KIND" in
    claude)
      # -p is REQUIRED. Without it, `claude --agent X` starts an INTERACTIVE
      # session; under a scheduler there is no TTY, so it either reads EOF and
      # exits 0 having done nothing, or waits on input that never arrives. Both
      # look like success to the scheduler, which is why each runner asserts an
      # artifact afterwards.
      run_with_watchdog "$timeout" "$out" \
        "$AGENT_BIN" -p "$task" --agent "$agent" --permission-mode acceptEdits
      ;;
    command)
      run_with_watchdog "$timeout" "$out" "$AGENT_BIN" "$prompt_rel"
      ;;
    *)
      # agent_preflight rejects any other kind first. Set both globals anyway,
      # so a future caller that skips it fails with a status, not set -u.
      RUN_RC=64
      RUN_TIMED_OUT=0
      ;;
  esac
}
