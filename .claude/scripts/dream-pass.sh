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
#   TMPDIR              where the runner makes its own folder for the pass (on
#                       macOS Apple's mktemp uses the per-user temporary
#                       folder, whatever TMPDIR says): snapshots, backup, git's
#                       hooks folder and, in claude mode, pass-settings.json,
#                       which Claude Code reads as settings, hooks and other
#                       commands among them. Keep it an absolute folder only
#                       this account can change, named with no link, no .., no
#                       part ending in a dot and no colon but a drive letter's
#                       (a pass refuses a folder that is not an absolute path,
#                       and on Windows, or wherever a cygpath is found on PATH,
#                       one with a .., a part ending in a dot or another colon,
#                       in every mode, before its first git call); on Windows
#                       schedule the task as your own account, and leave it
#                       unset unless a long path needs a shorter folder
#                       (docs/reference.md, Known limits)
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
#        read the vault's repository, or in claude mode the memory override
#        refused the pass (memory_override in lib/runner-common.sh), or, on
#        Windows or wherever a cygpath is found, the vault's path holds a part
#        ending in a dot, a colon that is not a drive letter's or a last part
#        ending in a space, or the temporary folder is refused (above), or the
#        runner could not record its folder for the pass, or its library comes
#        from another release (no record of that folder was taken)
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
#   70   TRIPWIRE-ERROR: containment was needed, or the runner's folder changed
#        while the agent ran, but no tripwire could be written
#   75   LOCKED: another pass held the run lock, or git's index.lock stayed, for
#        RUN_LOCK_WAIT seconds, the run lock is marked KILL_FAILED, the
#        index.lock is more than 10 minutes old,
#        another runner took the lock over before the pass started, a git
#        merge, rebase, cherry-pick, revert or bisect is in progress, or HEAD is
#        detached
#   78   TRIPWIRE: a tripwire is set, or an earlier pass died before containment,
#        or UNVERIFIED: the runner's own folder for the pass changed while the
#        agent ran, or could not be recorded again when it returned, so nothing
#        was moved or restored and the tripwire is set (also when the run timed
#        out or stalled: 78, or 70 when no tripwire could be written, then takes
#        the place of 124 or 125, and the TIMEOUT or STALLED line is logged as
#        well)
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

# The same pin the retention runner carries, and for a sharper reason here.
# steering_filter in the library decides which files the fence backs up and
# quarantines, and it decides it by folding a path to lower case and comparing
# it against ASCII literals. gawk folds by the locale, so under a Turkish or an
# Azeri locale tolower on GEMINI.md gives a dotless i, the literal comparison
# fails, and a planted steering file is reported by the fence and then left
# exactly where it is, to load into the next session as instructions. That is
# the direction a containment control must never fail in. The scheduled runners
# are started by cron, launchd or Task Scheduler under whatever locale that
# user's session carries, which no CI job models, and LC_ALL rather than
# LC_COLLATE because LC_ALL in the environment overrides LC_COLLATE. The pin
# also covers the other unprefixed awks and the one sed the library runs on this
# path. Nothing here reads a translated message. It also reaches Git Bash's
# cygpath, which under C cuts a path at its first character outside the ANSI
# code page, so on Windows memory_override runs its cygpath calls, and
# state_dir_ready's check of its own folder, under C.UTF-8 and checks what they
# give; memory_override's own pwd -P and both identity walks run under C, as do
# the state directory's and path_key's checks elsewhere.
LC_ALL=C
export LC_ALL

RUNNER=dream-pass
CONTAINMENT_CHECKED=0
INFLIGHT=0
SNAP_DIR=""
# 1 once the check of the runner's folder failed, so on_exit keeps it for review.
SNAP_KEEP=0
SESSION_RECORDED=0
AGENT_SESSION_ID=""
KILL_FAILED_MARKED=0
KILL_FAILED_LOCKED=0
RUN_LOG_APPENDED=0
STOP_REPORT_PENDING=0
AGENT_KILL_REPORT=""
# 1 only while the agent's own run owns the watchdog's result. Until run_agent
# starts its watchdog, this keeps a signal from reading a result another watchdog
# left, such as the run lock's liveness probe. The agent's watchdog clears any
# such result as it starts, and the probe clears its own.
AGENT_RUNNING=0

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
      printf '[%s] The pre-pass backup is kept at %s for the review after KILL_FAILED.\n' "$(ts)" "$(shown_name "$STATE/inflight-backup.tar")" >> "$LOG"
    else
      printf '[%s] WARNING: there is no pre-pass backup at %s to review against after KILL_FAILED.\n' "$(ts)" "$(shown_name "$STATE/inflight-backup.tar")" >> "$LOG"
    fi
  fi
  # What a tripwire or stop report left when a signal cut it short.
  [ -n "${STATE:-}" ] && rm -f "$STATE/tripwire-body.$$" "$STATE/kill-report.$$" "$STATE/runner-tripwire.tmp.$$" "$STATE/$RUNNER.interrupted.run.tmp.$$" "$STATE/signal-stop.$$" "$STATE/signal-stop.$$.powershell" 2>/dev/null
  [ -n "${ROOT:-}" ] && rm -f "$ROOT/$TRIPWIRE_REL.tmp.$$" "$ROOT/$TRIPWIRE_REL.tmp.$$".?????? 2>/dev/null
  [ -n "$SNAP_DIR" ] && [ "$SNAP_KEEP" -eq 0 ] && rm -rf "$SNAP_DIR"
  run_lock_release
}

# On INT or TERM: stop the agent, and if it had started, containment cannot be
# trusted to have run, so set the tripwire now rather than leave the vault to the
# next pass's baseline.
on_signal() {
  local report=""
  # The whole tree, so a child of the agent or of a git step cannot keep writing
  # after the exit. RUN_PID is set while such a command runs, and while the
  # watchdog finishes stopping one that has ended (RUN_REAPED=1). It runs once the
  # private temporary directory has been made, whether or not it is still there,
  # and is recorded in the state directory, because a pass can remove that
  # directory or put a link in its place. A stop that may have left a
  # process marks the run lock. Before containment the tripwire below is set, so
  # the stop's report goes into it as well.
  if [ -n "${RUN_PID:-}" ] && [ -n "$SNAP_DIR" ]; then
    stop_tree "$RUN_PID" 2 "$STATE/signal-stop.$$" "${AGENT_SESSION_ID:-}" 1
    if grep -qE '^(alive|unknown)' "$STATE/signal-stop.$$" 2>/dev/null; then
      if [ "$INFLIGHT" -eq 1 ] && [ "$CONTAINMENT_CHECKED" -eq 0 ]; then
        report="$(cat "$STATE/signal-stop.$$")"
      else
        mark_kill_failed "$LOG" "$(cat "$STATE/signal-stop.$$")"
      fi
    fi
  fi
  # Before containment the pass may have put a link in place of the vault's log,
  # so the lines below go to the state directory then (log_outside_links). The
  # log is checked once the tree is stopped, so a pass cannot put the link there
  # after the check.
  if [ "$INFLIGHT" -eq 1 ] && [ "$CONTAINMENT_CHECKED" -eq 0 ]; then
    log_outside_links "$ROOT" "$STATE" "$RUNNER"
  fi
  record_session_once
  # Before its output reached the run log, the pass's stream would go with the
  # temporary directory, so it is kept in the state directory, unless run or the
  # folder is a link, which the copy would follow to whatever it names.
  if [ "$RUN_LOG_APPENDED" -eq 0 ] && [ -n "$SNAP_DIR" ] && [ -f "$SNAP_DIR/run" ] \
     && [ ! -L "$SNAP_DIR/run" ] && [ ! -L "$SNAP_DIR" ]; then
    keep_run_output "$SNAP_DIR/run" "$STATE" "$RUNNER" "$LOG"
  fi
  if [ "$INFLIGHT" -eq 1 ] && [ "$CONTAINMENT_CHECKED" -eq 0 ]; then
    # A tripwire this run already set, by containment or by a stop's report,
    # stays as it is, with a note. tripwire_check made sure neither copy existed
    # when the run started, and the pass cannot write the state directory copy.
    if { [ "${CONTAINED:-0}" -eq 1 ] || [ -f "$STATE/$(basename "$TRIPWIRE_REL")" ]; } \
       && note_tripwire "$ROOT" "$STATE" "$LOG" "The runner was then interrupted by a signal, so its log may lack some of what is above."; then
      clear_inflight "$ROOT" "$STATE"
      printf '[%s] INTERRUPTED after the tripwire was set. The tripwire is kept.\n' "$(ts)" >> "$LOG"
    elif write_tripwire "$ROOT" "$STATE" "$RUNNER" \
         "the pass was interrupted by a signal before containment ran, so the vault's steering surfaces are unverified (the pre-pass backup is $STATE/inflight-backup.tar)" \
         "(none, because containment did not run)" /dev/null "" uncontained; then
      clear_inflight "$ROOT" "$STATE"
      printf '[%s] INTERRUPTED before containment. Tripwire set.\n' "$(ts)" >> "$LOG"
    else
      # With no tripwire the marker stays, so the next run still refuses.
      printf '[%s] TRIPWIRE-ERROR: interrupted before containment and no tripwire could be written. Treat the vault as unverified, and run no git command in it before the steering surfaces have been checked. The in-flight marker is kept.\n' "$(ts)" >> "$LOG"
    fi
  fi
  # A stop by the watchdog that may have left a process, and that the runner had
  # not reported yet, is reported now, so the lock is marked and the tripwire says
  # so. Before the run log is written that includes a result the watchdog has set
  # while run_agent had not returned, which is why the result is read only while
  # the agent's own run owns it, which AGENT_RUNNING records.
  if [ "$STOP_REPORT_PENDING" -eq 1 ]; then
    report="$AGENT_KILL_REPORT${report:+
$report}"
  elif [ "$AGENT_RUNNING" -eq 1 ] && [ "$RUN_LOG_APPENDED" -eq 0 ] && [ "${RUN_KILL_FAILED:-0}" -eq 1 ] && [ "$KILL_FAILED_MARKED" -eq 0 ]; then
    report="${RUN_KILL_REPORT:-}${report:+
$report}"
  fi
  if [ -n "$report" ]; then
    RUN_KILL_FAILED=1
    RUN_KILL_REPORT="$report"
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
  git_env_warning "$LOG"
  # On Windows git reads the vault's folder as it is spelled, so a spelling it
  # reads as another folder is refused before the state directory, the lock or
  # any git call.
  vault_root_spelling_ok "$ROOT" "$LOG" || exit 1
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
    printf '[%s] ERROR: the state directory %s %s. Refusing to run.\n' "$(ts)" "$(shown_name "$STATE")" "$(state_dir_problem "$state_rc")" >> "$LOG"
    exit 1
  fi
  STATE="$STATE_REAL"
  # A tripwire or a marker means an earlier pass ended without containment, and a
  # link it put in place of the vault's log may still be there. This run's lines
  # then go to the state directory (log_outside_links).
  if guard_exists "$ROOT" "$STATE" "$TRIPWIRE_REL" || guard_exists "$ROOT" "$STATE" "$INFLIGHT_REL"; then
    log_outside_links "$ROOT" "$STATE" "$RUNNER"
  fi

  # One pass at a time per vault. The traps come first, so a signal that lands
  # while the lock is being taken still releases it. The lock is taken before any
  # vault state is checked, and on_exit releases it on every exit path.
  trap on_exit EXIT
  trap 'on_signal 130' INT
  trap 'on_signal 143' TERM
  run_lock_acquire "$STATE" "$ROOT" "$RUNNER" "$LOG" "$((TIMEOUT + WATCHDOG_GRACE + 900))"
  lock_rc=$?
  [ "$lock_rc" -eq 0 ] || exit "$lock_rc"
  # Again once the lock is held: the pass that held it while this run waited may
  # have put the link there, and set the tripwire, after the check above.
  if guard_exists "$ROOT" "$STATE" "$TRIPWIRE_REL" || guard_exists "$ROOT" "$STATE" "$INFLIGHT_REL"; then
    log_outside_links "$ROOT" "$STATE" "$RUNNER"
  fi

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
  # On Windows git reads this folder as TMPDIR spells it, so a spelling it reads
  # as another folder is refused before the first git call, in every mode, and so
  # is a folder that is not an absolute path.
  temp_dir_spelling_ok "$SNAP_DIR" "$LOG" || exit 1
  runner_folder_ok "$SNAP_DIR" "$LOG" || exit 1
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
  # The last check of the run lock before the memory override, the backup and
  # the in-flight marker touch the shared state directory.
  if ! run_lock_held; then
    printf '[%s] LOCKED: another runner replaced or removed this one'"'"'s owner file in the run lock before the pass started. Not starting.\n' "$(ts)" >> "$LOG"
    exit 75
  fi
  # In claude mode, Claude Code's memory for this pass is pointed inside the
  # fence, or the pass does not start.
  if [ "$AGENT_KIND" = claude ] && ! memory_override "$ROOT" "$STATE" "$SNAP_DIR" "$LOG"; then
    exit 1
  fi
  # The runner's folder for the pass is recorded now, before the in-flight
  # marker, and again as soon as the agent returns (snap_manifest).
  if ! SNAP_SEALS="$(snap_manifest "$SNAP_DIR")" || [ -z "$SNAP_SEALS" ]; then
    SNAP_SEALS=
    printf '[%s] ERROR: the runner could not record its folder for the pass, %s, before the agent started (the folder missing or a link, a name in it outside letters, digits, dot, underscore and hyphen, a file it could not checksum, a folder in it that could not be listed, no sha256sum, shasum or cksum found, or a record that came out empty), so it could not check the folder afterwards. Refusing to run.\n' "$(ts)" "$(shown_name "$SNAP_DIR")" >> "$LOG"
    exit 1
  fi
  case "$(snap_tool)" in
    cksum\ *) printf '[%s] WARNING: no sha256sum or shasum was found, so the runner checks its folder for the pass with cksum, a CRC that anyone able to write the folder can make a file match.\n' "$(ts)" >> "$LOG" ;;
  esac
  # A backup an earlier pass kept, after a 78 or a KILL_FAILED, goes first, so a
  # copy that fails cannot leave it to be named as this pass's backup.
  rm -f "$STATE/inflight-backup.tar" 2>/dev/null
  cp "$SNAP_DIR/steering.tar" "$STATE/inflight-backup.tar" 2>/dev/null
  backup_rc=$?
  if [ "$backup_rc" -ne 0 ] || [ ! -f "$STATE/inflight-backup.tar" ] || [ -L "$STATE/inflight-backup.tar" ]; then
    rm -f "$STATE/inflight-backup.tar" 2>/dev/null
    printf '[%s] ERROR: could not copy the pre-pass backup of the steering surfaces to the state directory as %s. Refusing to run.\n' "$(ts)" "$(shown_name "$STATE/inflight-backup.tar")" >> "$LOG"
    exit 1
  fi
  # Without the marker outside the vault, a pass killed mid-run would leave no
  # trace the next run can trust. Refuse rather than start the agent.
  if ! mark_inflight "$ROOT" "$STATE" "$RUNNER"; then
    clear_inflight "$ROOT" "$STATE"
    printf '[%s] ERROR: could not write the in-flight marker in the state directory %s. Refusing to run.\n' "$(ts)" "$(shown_name "$STATE")" >> "$LOG"
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
  AGENT_RUNNING=1
  run_agent "$TIMEOUT" "$SNAP_DIR/run" dream-agent "$TASK" "$PROMPT_REL"
  # A stop that may have left a process is reported after containment. Until
  # report_stop has done it, a signal does it instead.
  AGENT_KILL_REPORT="${RUN_KILL_REPORT:-}"
  STOP_REPORT_PENDING="${RUN_KILL_FAILED:-0}"
  AGENT_RUNNING=0

  # Before anything is written to the folder again, it must be as it was when
  # the agent started; otherwise nothing in it can be trusted, and the pass ends
  # with the tripwire and the folder kept (snap_untrusted).
  if ! SNAP_NOW="$(snap_manifest "$SNAP_DIR")" || [ "$SNAP_NOW" != "$SNAP_SEALS" ]; then
    SNAP_KEEP=1
    # Containment does not run on this path, so a link the pass put in place of
    # the vault's log stays, and is not written through (log_outside_links).
    log_outside_links "$ROOT" "$STATE" "$RUNNER"
    snap_untrusted "$ROOT" "$STATE" "$RUNNER" "$SNAP_DIR" "$LOG"
    snap_rc=$?
    [ "$snap_rc" -eq 78 ] && INFLIGHT=0
    if [ "$RUN_TIMED_OUT" -eq 1 ]; then
      printf '[%s] TIMEOUT: dream-agent exceeded %ss and was killed (status %s)\n' \
        "$(ts)" "$TIMEOUT" "$RUN_RC" >> "$LOG"
    elif [ "$RUN_STALLED" -eq 1 ]; then
      printf '[%s] STALLED: dream-agent wrote no output for %ss (%s) and was killed (status %s)\n' \
        "$(ts)" "$AGENT_STALL_SECONDS" "$AGENT_STALL_NOTE" "$RUN_RC" >> "$LOG"
    fi
    if [ "$RUN_TIMED_OUT" -eq 1 ] || [ "$RUN_STALLED" -eq 1 ]; then
      report_stop "$LOG" dream-agent "$ROOT" "$STATE" "$RUNNER"
    fi
    # A signal before RUN_LOG_APPENDED is set keeps the output itself, so it is
    # set only once the output is kept, or at once when it cannot be. Neither
    # copy follows a link at run or at the folder.
    if [ -f "$SNAP_DIR/run" ] && [ ! -L "$SNAP_DIR/run" ] && [ ! -L "$SNAP_DIR" ]; then
      keep_run_output "$SNAP_DIR/run" "$STATE" "$RUNNER" "$LOG"
      RUN_LOG_APPENDED=1
      record_session_once
    else
      RUN_LOG_APPENDED=1
      printf '[%s] WARNING: the run output, %s, is missing, is not a regular file or is in a folder that is a link, so it was not kept.\n' "$(ts)" "$(shown_name "$SNAP_DIR/run")" >> "$LOG"
    fi
    exit "$snap_rc"
  fi
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
  # A process the stop may have left can swap the run log's temporary file for a
  # link while it is built, so after KILL_FAILED the output stays out of the vault.
  if [ "$KILL_FAILED_MARKED" -eq 1 ]; then
    printf '[%s] A process of the stopped pass may still be running, so the run output is not added to %s.\n' "$(ts)" "$RUN_OUT" >> "$LOG"
    keep_run_output "$SNAP_DIR/run" "$STATE" "$RUNNER" "$LOG"
  else
    append_run_log "$SNAP_DIR/run" "$RUN_OUT" "$LOG" || keep_run_output "$SNAP_DIR/run" "$STATE" "$RUNNER" "$LOG"
  fi
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
