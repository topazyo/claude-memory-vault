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
# that produced no journal change at all. A change to a steering or execution
# surface (Obsidian plugins, .claude/, harness configs, instruction files at any
# depth, memory, git config and hooks, a rewritten HEAD) is also CONTAINED:
# quarantined outside the vault, restored from a pre-pass backup, and a tripwire
# stops every later run until a human clears it. See "Containment" in
# lib/runner-common.sh.
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
#   VAULT_STATE_DIR     per-vault state outside the vault: run lock, quarantine,
#                       tripwire copy, in-flight marker (default under
#                       %LOCALAPPDATA% or ~/.local/state)
#   RUN_LOCK_WAIT       seconds to wait for another pass's run lock (default 1800)
#   RUN_LOCK_POLL       seconds between checks while waiting (default 30)
#   RUNNER_GIT_TIMEOUT  seconds each git step of the journal commit may take
#                       (default 120)
#   RUNNER_STALL_SECONDS  seconds without new stream output before a pass is
#                       stopped. Measured by default (lib/runner-common.sh), 0
#                       turns it off, and in command mode only this turns it on
#   RUNNER_STALL_FLOOR  the lowest measured stall threshold (default 600)
#   RUNNER_RUN_LOG_MAX_BYTES  the most .claude/logs/dream-agent.run.log keeps,
#                       newest part first (default 10000000, at least 1000)
#
# Exit codes:
#   0    the pass changed a dream journal and nothing else, and the journal was
#        committed (or the vault is not a git repository, or git ignores it)
#   1    NO-ARTIFACT: exited 0 but no dream journal was added or changed,
#        or the runner could not set itself up (temp dir, state directory, backup,
#        prompt file, run lock, in-flight marker, git status), or git cannot
#        read the vault's repository
#   2    VIOLATION: files outside the dream journals changed during the run
#        (steering surfaces among them are contained and the tripwire is set),
#        or the pass changed a journal that already had uncommitted changes, or
#        one it changed is no longer a regular file, even if the agent then
#        failed or timed out. Nothing it wrote is recorded for the next run
#   3    REFUSED: command mode without VAULT_ALLOW_UNENFORCED_TOOLS=1
#   4    COMMIT-FAILED: staging or committing the journal failed or ran past
#        RUNNER_GIT_TIMEOUT, and the journal is left uncommitted and unstaged
#   5    CHECK-FAILED: vault-check rejected the journal, which is left uncommitted
#   64   VAULT_AGENT is not claude or command
#   70   TRIPWIRE-ERROR: containment was needed but no tripwire could be written
#   75   LOCKED: another pass held the run lock, or git's index.lock stayed, for
#        RUN_LOCK_WAIT seconds, the run lock is marked KILL_FAILED, the
#        index.lock is more than 10 minutes old,
#        another runner took the lock over before the pass started, a git
#        merge, rebase, cherry-pick, revert or bisect is in progress, or HEAD is
#        detached
#   78   TRIPWIRE: a tripwire is set, or an earlier pass died before containment
#   124  TIMEOUT: the watchdog killed a run that exceeded DREAM_PASS_TIMEOUT, and
#        everything it started
#   125  STALLED: the watchdog killed a run whose output stopped growing for the
#        stall threshold (claude mode, or command mode with RUNNER_STALL_SECONDS
#        set), and everything it started. After 124 or 125, KILL_FAILED in the
#        log means a process may still be running. The run lock is kept, so later
#        runs exit 75, and the tripwire is set
#   127  the claude binary or the VAULT_AGENT_CMD wrapper was not found
#   *    any other non-zero status is the agent's own

set -u

RUNNER=dream-pass
CONTAINMENT_CHECKED=0
INFLIGHT=0
SNAP_DIR=""
SESSION_RECORDED=0
AGENT_SESSION_ID=""
KILL_FAILED_MARKED=0
KILL_FAILED_LOCKED=0
RUN_LOG_APPENDED=0
STOP_REPORT_PENDING=0
AGENT_KILL_REPORT=""

# record_session_once
# Records a claude-mode pass's session, once, however the pass ended, so a later
# capture of Claude Code sessions never takes a runner's pass for a person's
# work. The stream is read from the runner's private copy.
record_session_once() {
  [ "$SESSION_RECORDED" -eq 0 ] && [ -n "$AGENT_SESSION_ID" ] && [ "${AGENT_KIND:-}" = claude ] \
    && [ -n "$SNAP_DIR" ] && [ -f "$SNAP_DIR/run" ] || return 0
  SESSION_RECORDED=1
  record_runner_session "$STATE" "$RUNNER" "$SNAP_DIR/run" 0 "$AGENT_SESSION_ID" "$LOG"
}

# On any exit: clear the in-flight marker only once containment has checked the
# pass, then remove the temporary directory. The pre-pass backup goes with the
# marker, unless a stop left a process that may have written after containment,
# because the owner needs the backup to review what it wrote.
on_exit() {
  if [ "$CONTAINMENT_CHECKED" -eq 1 ]; then
    clear_inflight "$ROOT" "$STATE"
    if [ "$KILL_FAILED_MARKED" -eq 0 ]; then
      rm -f "$STATE/inflight-backup.tar" 2>/dev/null
    elif [ -s "$STATE/inflight-backup.tar" ]; then
      printf '[%s] The pre-pass backup is kept at %s for the review after KILL_FAILED.\n' "$(ts)" "$STATE/inflight-backup.tar" >> "$LOG"
    else
      printf '[%s] WARNING: there is no pre-pass backup at %s to review against after KILL_FAILED.\n' "$(ts)" "$STATE/inflight-backup.tar" >> "$LOG"
    fi
  fi
  # What a tripwire or stop report left when a signal cut it short.
  [ -n "${STATE:-}" ] && rm -f "$STATE/tripwire-body.$$" "$STATE/kill-report.$$" "$STATE/runner-tripwire.tmp.$$" 2>/dev/null
  [ -n "$SNAP_DIR" ] && rm -rf "$SNAP_DIR"
  run_lock_release
}

# On INT or TERM: stop the agent, and if it had started, containment cannot be
# trusted to have run, so set the tripwire now rather than leave the vault to the
# next pass's baseline.
on_signal() {
  # The whole tree, so a child of the agent or of a git step cannot keep writing
  # after the exit. RUN_PID is set while such a command runs, and while the
  # watchdog finishes stopping one that has ended (RUN_REAPED=1). Then the private
  # temporary directory exists. A stop that may have left a process marks the run
  # lock.
  if [ -n "${RUN_PID:-}" ] && [ -n "$SNAP_DIR" ] && [ -d "$SNAP_DIR" ]; then
    stop_tree "$RUN_PID" 2 "$SNAP_DIR/signal-stop" "${AGENT_SESSION_ID:-}" 1
    grep -qE '^(alive|unknown)' "$SNAP_DIR/signal-stop" 2>/dev/null \
      && mark_kill_failed "$LOG" "$(cat "$SNAP_DIR/signal-stop")"
  fi
  record_session_once
  # Before its output reached the run log, the pass's stream would go with the
  # temporary directory, so it is kept in the state directory.
  if [ "$RUN_LOG_APPENDED" -eq 0 ] && [ -n "$SNAP_DIR" ] && [ -f "$SNAP_DIR/run" ]; then
    keep_run_output "$SNAP_DIR/run" "$STATE" "$RUNNER" "$LOG"
  fi
  if [ "$INFLIGHT" -eq 1 ] && [ "$CONTAINMENT_CHECKED" -eq 0 ]; then
    : > "$SNAP_DIR/empty"
    # A tripwire this run already set, by containment or by a stop's report,
    # stays as it is, with a note. tripwire_check made sure neither copy existed
    # when the run started, and the pass cannot write the state directory copy.
    if { [ "${CONTAINED:-0}" -eq 1 ] || [ -f "$STATE/$(basename "$TRIPWIRE_REL")" ]; } \
       && note_tripwire "$ROOT" "$STATE" "$LOG" "The runner was then interrupted by a signal, so its log may lack some of what is above."; then
      clear_inflight "$ROOT" "$STATE"
      printf '[%s] INTERRUPTED after the tripwire was set. The tripwire is kept.\n' "$(ts)" >> "$LOG"
    elif write_tripwire "$ROOT" "$STATE" "$RUNNER" \
         "the pass was interrupted by a signal before containment ran, so the vault's steering surfaces are unverified (the pre-pass backup is $STATE/inflight-backup.tar)" \
         "(none, because containment did not run)" "$SNAP_DIR/empty"; then
      clear_inflight "$ROOT" "$STATE"
      printf '[%s] INTERRUPTED before containment. Tripwire set.\n' "$(ts)" >> "$LOG"
    else
      # With no tripwire the marker stays, so the next run still refuses.
      printf '[%s] TRIPWIRE-ERROR: interrupted before containment and no tripwire could be written. The in-flight marker is kept.\n' "$(ts)" >> "$LOG"
    fi
  fi
  # A stop by the watchdog that may have left a process, and that the runner had
  # not reported yet, is reported now, so the lock is marked and the tripwire says
  # so.
  if [ "$STOP_REPORT_PENDING" -eq 1 ]; then
    RUN_KILL_FAILED=1
    RUN_KILL_REPORT="$AGENT_KILL_REPORT"
    report_stop "$LOG" dream-agent "$ROOT" "$STATE" "$RUNNER"
  fi
  exit "$1"
}

# Everything else runs inside main, and the script's last lines call it and
# exit. Bash reads a script as it executes it, so a change made to this file
# while a pass runs could otherwise be executed by this very run. A function
# body is parsed in full before any of it runs.
main() {
  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  cd "$ROOT" || exit 1
  # shellcheck source=lib/runner-common.sh
  . "$ROOT/.claude/scripts/lib/runner-common.sh"

  LOG_DIR="$ROOT/.claude/logs"
  mkdir -p "$LOG_DIR" 2>/dev/null
  LOG="$LOG_DIR/dream-agent.log"
  RUN_OUT="$LOG_DIR/dream-agent.run.log"
  # Settings that reach arithmetic are checked first. A value that is not a whole
  # number would abort the runner with nothing in the log, and bash evaluates a
  # variable in arithmetic as an expression.
  TIMEOUT="$(uint_setting DREAM_PASS_TIMEOUT 3600 1 "$LOG")"
  WATCHDOG_GRACE="$(uint_setting WATCHDOG_GRACE 15 0 "$LOG")"
  WATCHDOG_POLL="$(uint_setting WATCHDOG_POLL 5 1 "$LOG")"
  STATE="$(vault_state_dir "$ROOT" 2>>"$LOG")"
  # From here on the resolved path that was checked, so pointing a symlink
  # elsewhere after the check changes nothing.
  STATE_REAL="$(state_dir_ready "$STATE" "$ROOT")"
  state_rc=$?
  if [ "$state_rc" -ne 0 ]; then
    printf '[%s] ERROR: the state directory %s %s. Refusing to run.\n' "$(ts)" "$STATE" "$(state_dir_problem "$state_rc")" >> "$LOG"
    exit 1
  fi
  STATE="$STATE_REAL"

  # One pass at a time per vault. The traps come first, so a signal that lands
  # while the lock is being taken still releases it. The lock is taken before any
  # vault state is checked, and on_exit releases it on every exit path.
  trap on_exit EXIT
  trap 'on_signal 130' INT
  trap 'on_signal 143' TERM
  run_lock_acquire "$STATE" "$ROOT" "$RUNNER" "$LOG" "$((TIMEOUT + WATCHDOG_GRACE + 900))"
  lock_rc=$?
  [ "$lock_rc" -eq 0 ] || exit "$lock_rc"

  tripwire_check "$ROOT" "$STATE" "$RUNNER" "$LOG"
  guard_rc=$?
  [ "$guard_rc" -eq 0 ] || exit "$guard_rc"

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
    SNAP_DIR=""
    printf '[%s] ERROR: could not create a temporary directory\n' "$(ts)" >> "$LOG"
    exit 1
  }
  mkdir -p "$SNAP_DIR/nohooks"

  # The journal is committed at the end, so a git operation in progress or a
  # detached HEAD stops the run before the agent starts.
  git_preflight "$ROOT" "$SNAP_DIR/nohooks" "$LOG"
  git_rc=$?
  [ "$git_rc" -eq 0 ] || exit "$git_rc"

  # The agent is given no shell, so it cannot run git itself. Record the
  # repository state here for it to read, instead of widening its tool list.
  {
    printf 'Recorded by dream-pass.sh at %s, before the agent started.\n\n' "$(ts)"
    if safe_git "$SNAP_DIR/nohooks" -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      printf '## git log --oneline -5\n'; safe_git "$SNAP_DIR/nohooks" -C "$ROOT" log --oneline -5 2>&1
      printf '\n## git status --short\n'; safe_git "$SNAP_DIR/nohooks" -C "$ROOT" status --short 2>&1
    else
      printf 'This vault is not a git repository; no history is available.\n'
    fi
  } > "$LOG_DIR/dream-pass.git-state.txt" 2>/dev/null

  # Files someone was already editing, which the pass must not commit over.
  : > "$SNAP_DIR/predirty"
  if [ "$VAULT_GIT" -eq 1 ] && ! git_dirty_paths "$ROOT" "$SNAP_DIR/nohooks" "$SNAP_DIR/predirty"; then
    printf '[%s] ERROR: git status failed, so the files already being edited are unknown. Refusing to run.\n' "$(ts)" >> "$LOG"
    exit 1
  fi
  # A journal an earlier run of this runner left uncommitted, and nobody has
  # touched since, is this runner's own, not someone's edit.
  # One that fails the check is left in place for review, not committed.
  : > "$SNAP_DIR/predirty.adopted"
  if [ "$VAULT_GIT" -eq 1 ]; then
    adopt_uncommitted "$ROOT" "$SNAP_DIR/nohooks" "$STATE" "$RUNNER" "$SNAP_DIR/predirty"
    check_leftovers "$ROOT" "$SNAP_DIR" NONE "" "$LOG" 0
    if [ -s "$SNAP_DIR/predirty.adopted" ]; then
      printf '[%s] ADOPTED: journals an earlier run left uncommitted are checked and committed with this pass:\n' "$(ts)" >> "$LOG"
      sed 's/^/    /' "$SNAP_DIR/predirty.adopted" >> "$LOG"
    fi
  fi

  snapshot_tree "$ROOT" "$SNAP_DIR/before"
  # Containment needs the pre-pass copy. Without it, refuse rather than run a pass
  # whose planted files could not be undone.
  if ! backup_steering "$ROOT" "$SNAP_DIR/before" "$SNAP_DIR/steering.tar"; then
    printf '[%s] ERROR: could not back up the steering surfaces (tar missing, or the archive is incomplete). Refusing to run without containment.\n' "$(ts)" >> "$LOG"
    exit 1
  fi
  HEAD_BEFORE="$(head_state "$ROOT" "$SNAP_DIR/nohooks")"
  # The last check before anything is written to the shared state directory.
  if ! run_lock_held; then
    printf '[%s] LOCKED: another runner replaced or removed this one'"'"'s owner file in the run lock before the pass started. Not starting.\n' "$(ts)" >> "$LOG"
    exit 75
  fi
  cp "$SNAP_DIR/steering.tar" "$STATE/inflight-backup.tar" 2>/dev/null
  # Without the marker outside the vault, a pass killed mid-run would leave no
  # trace the next run can trust. Refuse rather than start the agent.
  if ! mark_inflight "$ROOT" "$STATE" "$RUNNER"; then
    clear_inflight "$ROOT" "$STATE"
    printf '[%s] ERROR: could not write the in-flight marker in the state directory %s. Refusing to run.\n' "$(ts)" "$STATE" >> "$LOG"
    exit 1
  fi
  INFLIGHT=1
  # The stall threshold, the session id, and where the watchdog notes the
  # silent stretches this pass has.
  stall_plan "$STATE" "$RUNNER" "$LOG"
  AGENT_SESSION_ID="$(new_uuid)"
  AGENT_GAPS_FILE="$SNAP_DIR/gaps"

  printf '[%s] starting dream-agent via %s (timeout %ss, stall %ss, %s, session %s)\n' \
    "$(ts)" "$AGENT_KIND" "$TIMEOUT" "$AGENT_STALL_SECONDS" "$AGENT_STALL_NOTE" "$AGENT_SESSION_ID" >> "$LOG"

  # The stream goes to a private file outside the vault, where the pass cannot
  # rewrite what the watchdog measures or the session record reads. It is added
  # to the run log after containment.
  : > "$SNAP_DIR/run"
  run_agent "$TIMEOUT" "$SNAP_DIR/run" dream-agent "$TASK" "$PROMPT_REL"
  # A stop that may have left a process is reported after containment. Until
  # report_stop has done it, a signal does it instead.
  AGENT_KILL_REPORT="${RUN_KILL_REPORT:-}"
  STOP_REPORT_PENDING="${RUN_KILL_FAILED:-0}"

  snapshot_tree "$ROOT" "$SNAP_DIR/after"
  changed_paths "$SNAP_DIR/before" "$SNAP_DIR/after" > "$SNAP_DIR/changed"

  # CONTAINMENT comes first, before the exit code is even looked at: a pass that
  # timed out may still have planted something, and nothing from the vault may
  # run until it has been put back.
  contain_pass "$ROOT" "$STATE" "$RUNNER" "$SNAP_DIR" "$LOG" "$HEAD_BEFORE"
  contain_rc=$?
  [ "$contain_rc" -eq 0 ] && CONTAINMENT_CHECKED=1
  # Containment has run, so from here a signal leaves its tripwire as it is.
  # Nothing is written to the vault's logs between the agent's end and
  # containment, because the pass may have put a link in place of a log. What
  # the stop found, with a KILL_FAILED mark and tripwire, and the run's output
  # come now.
  if [ "$RUN_TIMED_OUT" -eq 1 ] || [ "$RUN_STALLED" -eq 1 ]; then
    report_stop "$LOG" dream-agent "$ROOT" "$STATE" "$RUNNER"
  fi
  append_run_log "$SNAP_DIR/run" "$RUN_OUT" "$LOG" || keep_run_output "$SNAP_DIR/run" "$STATE" "$RUNNER" "$LOG"
  RUN_LOG_APPENDED=1
  record_session_once
  if [ "$contain_rc" -ne 0 ]; then
    exit "$contain_rc"
  fi
  if [ "$CONTAINED" -eq 1 ]; then
    [ "$RUN_TIMED_OUT" -eq 1 ] && printf '[%s] (the run had also exceeded %ss and was killed)\n' "$(ts)" "$TIMEOUT" >> "$LOG"
    [ "$RUN_STALLED" -eq 1 ] && printf '[%s] (the run had also stalled for %ss and was killed)\n' "$(ts)" "$AGENT_STALL_SECONDS" >> "$LOG"
    exit 2
  fi

  # What the pass may write, and owns: dream journals, plus an auto-written
  # compaction stub it may leave but does not own.
  grep -vE '^20-projects/_logs/(dream-|compaction-)[^/]*\.md$' "$SNAP_DIR/changed" > "$SNAP_DIR/outside"
  OWNED_PATTERN='^20-projects/_logs/dream-[^/]*\.md$'
  grep -E "$OWNED_PATTERN" "$SNAP_DIR/changed" > "$SNAP_DIR/owned"
  # Journals an earlier run left uncommitted are checked and committed with this
  # pass's own, whether or not this pass touched them.
  own_adopted "$SNAP_DIR" "$OWNED_PATTERN"

  # no_record_exit
  # A pass that wrote into a journal someone was editing, or removed or replaced
  # a journal, has nothing recorded for the next run, whether it timed out,
  # stalled, failed or finished, so the next run cannot commit its other
  # journals while that change stays. Its journals are left in place for review.
  no_record_exit() {
    printf '[%s] Nothing the pass wrote is recorded for the next run. Its journals are left in place for review.\n' "$(ts)" >> "$LOG"
    exit 2
  }

  if [ "$RUN_TIMED_OUT" -eq 1 ] || [ "$RUN_STALLED" -eq 1 ]; then
    if [ "$RUN_TIMED_OUT" -eq 1 ]; then
      printf '[%s] TIMEOUT: dream-agent exceeded %ss and was killed (status %s)\n' \
        "$(ts)" "$TIMEOUT" "$RUN_RC" >> "$LOG"
      stop_rc=124
    else
      printf '[%s] STALLED: dream-agent wrote no output for %ss (%s) and was killed (status %s)\n' \
        "$(ts)" "$AGENT_STALL_SECONDS" "$AGENT_STALL_NOTE" "$RUN_RC" >> "$LOG"
      stop_rc=125
    fi
    # What the pass wrote before it was killed is still listed.
    if [ -s "$SNAP_DIR/outside" ]; then
      printf '[%s] VIOLATION: files outside the dream journals changed before the pass was killed, so nothing it wrote is recorded for the next run:\n' "$(ts)" >> "$LOG"
      sed 's/^/    /' "$SNAP_DIR/outside" >> "$LOG"
      [ "$VAULT_GIT" -eq 1 ] && owned_predirty "$SNAP_DIR/owned" "$SNAP_DIR/predirty" "$SNAP_DIR" "$LOG"
    elif [ "$VAULT_GIT" -eq 1 ] && ! check_owned "$ROOT" "$SNAP_DIR/owned" "$SNAP_DIR/predirty" "$SNAP_DIR" "$LOG"; then
      no_record_exit
    fi
    record_leftovers "$ROOT" "$SNAP_DIR/nohooks" "$STATE" "$RUNNER" "$SNAP_DIR" "$LOG"
    exit "$stop_rc"
  fi

  printf '[%s] dream-agent exited with code %s\n' "$(ts)" "$RUN_RC" >> "$LOG"

  # SINGLE-WRITE FENCE. Anything that changed other than a dream journal - or an
  # auto-written compaction stub - was written by a pass that is only allowed to
  # write its journal. If something else writes to the vault while the pass runs
  # (a sync client, an editor), this fires too; the paths it names tell you which.
  if [ -s "$SNAP_DIR/outside" ]; then
    printf '[%s] VIOLATION: files outside the dream journal changed during the run:\n' "$(ts)" >> "$LOG"
    sed 's/^/    /' "$SNAP_DIR/outside" >> "$LOG"
    exit 2
  fi

  if [ "$RUN_RC" -ne 0 ]; then
    if [ "$VAULT_GIT" -eq 1 ] && ! check_owned "$ROOT" "$SNAP_DIR/owned" "$SNAP_DIR/predirty" "$SNAP_DIR" "$LOG"; then
      no_record_exit
    fi
    record_leftovers "$ROOT" "$SNAP_DIR/nohooks" "$STATE" "$RUNNER" "$SNAP_DIR" "$LOG"
    exit "$RUN_RC"
  fi

  # ARTIFACT ASSERTION. An exit code says the process ended; it does not say the
  # pass did anything. A dream journal must have been ADDED or CHANGED during this
  # run. Matching any dream-*.md, rather than today's date computed up front,
  # means a 23:59 run that writes after midnight still counts, and a journal left
  # by an earlier run on the same day does not pre-satisfy the check. An adopted
  # leftover does not either, which is why this reads the changes, not owned.
  if ! grep -qE "$OWNED_PATTERN" "$SNAP_DIR/changed"; then
    printf '[%s] NO-ARTIFACT: exited 0 but no dream journal was added or changed\n' "$(ts)" >> "$LOG"
    exit 1
  fi

  # COMMIT. Exactly the journals the pass changed, checked first, with trailers
  # that let later tooling tell a pass's commit from a human's.
  commit_owned "$ROOT" dream "$SNAP_DIR/owned" "$SNAP_DIR/predirty" "$SNAP_DIR" "$LOG"
  commit_rc=$?
  case "$commit_rc" in
    0) forget_uncommitted "$STATE" "$RUNNER" ;;
    4) record_leftovers "$ROOT" "$SNAP_DIR/nohooks" "$STATE" "$RUNNER" "$SNAP_DIR" "$LOG"; exit 4 ;;
    5)
      printf '[%s] The rejected journal is left in place, uncommitted, for review.\n' "$(ts)" >> "$LOG"
      # Only the journals that pass the check on their own are recorded for the
      # next run. A rejected one recorded too would be adopted and rejected again
      # every night, and no later journal would be committed.
      while IFS= read -r p; do
        [ -n "$p" ] && CLAUDE_PROJECT_DIR="$ROOT" bash "$ROOT/.claude/scripts/vault-check.sh" -- "$p" </dev/null >/dev/null 2>&1 \
          && printf '%s\n' "$p"
      done < "$SNAP_DIR/owned" > "$SNAP_DIR/owned.passing"
      mv -f "$SNAP_DIR/owned.passing" "$SNAP_DIR/owned"
      record_leftovers "$ROOT" "$SNAP_DIR/nohooks" "$STATE" "$RUNNER" "$SNAP_DIR" "$LOG"
      exit 5
      ;;
    *) exit "$commit_rc" ;;
  esac

  # Only a pass that ended OK teaches the stall threshold.
  [ "$AGENT_KIND" = claude ] && record_stream_gaps "$STATE" "$RUNNER" "$AGENT_GAPS_FILE"
  printf '[%s] OK: %s\n' "$(ts)" "$(tr '\n' ' ' < "$SNAP_DIR/owned")" >> "$LOG"
  exit 0
}

main "$@"
exit $?
