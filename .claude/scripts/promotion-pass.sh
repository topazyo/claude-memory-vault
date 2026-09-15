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
# It has no shell. This runner keeps the history for it: it records the vault's
# recent history for the agent to read, snapshots the vault before the run, and
# fails the run if anything changed OUTSIDE the areas a promotion pass may write.
# A change to a steering or execution surface - including an instruction file
# nested inside the long tier, such as 31-standards/CLAUDE.md - is also
# CONTAINED: quarantined outside the vault, restored from a pre-pass backup, and
# a tripwire stops every later run until a human clears it. After a clean pass
# the runner checks the notes the pass changed and commits exactly those, with a
# Vault-Pass: promotion trailer. Notes that fail the check are put back as they
# were before the pass, except a note someone changed or committed meanwhile,
# which the log lists. Notes a pass leaves uncommitted, because it timed out,
# failed or its commit failed, are checked by the next run before its agent
# starts, then committed with that run's notes or put back. See "Containment"
# and "Runner commits" in lib/runner-common.sh. Run it manually a few times
# first.
#
# EXAMPLE cron entry (Saturday 20:00):
#   0 20 * * 6 /path/to/your-vault/.claude/scripts/promotion-pass.sh
#
# Environment:
#   VAULT_AGENT             claude (default) or command; see lib/runner-common.sh
#   CLAUDE_BIN              path to the claude binary (schedulers get a minimal PATH)
#   VAULT_AGENT_CMD         command mode: your wrapper around another harness
#   VAULT_ALLOW_UNENFORCED_TOOLS  command mode: set to 1 once the wrapper is
#                           sandboxed (no shell, no network), or the run is refused
#   PROMOTION_PASS_TIMEOUT  seconds before a hung run is killed (default 5400)
#   VAULT_STATE_DIR         per-vault state outside the vault: run lock,
#                           quarantine, tripwire copy, in-flight marker (default
#                           under %LOCALAPPDATA% or ~/.local/state)
#   RUN_LOCK_WAIT           seconds to wait for another pass's run lock (default 1800)
#   RUN_LOCK_POLL           seconds between checks while waiting (default 30)
#   RUNNER_GIT_TIMEOUT      seconds each git step of the commit may take (default 120)
#   RUNNER_STALL_SECONDS    seconds without new stream output before a pass is
#                           stopped. Measured by default (lib/runner-common.sh),
#                           0 turns it off, and in command mode only this turns it on
#   RUNNER_STALL_FLOOR      the lowest measured stall threshold (default 600)
#
# Exit codes:
#   0    the pass reported a summary or changed the long tier, wrote nowhere else,
#        and its notes were committed (or the vault is not a repository of its
#        own, git ignores them, or HEAD already holds them)
#   1    NO-ARTIFACT: exited 0 with no summary line and no long-tier change,
#        or the runner could not set itself up (temp dir, state directory, backup,
#        prompt file, git state file, run lock, in-flight marker, git status), or
#        git cannot read the vault's repository
#   2    VIOLATION: files outside the allowed write areas changed during the run
#        (steering surfaces among them are contained and the tripwire is set),
#        or the pass changed a long-tier note or promotion report that already
#        had uncommitted changes, or one it changed is no longer a regular file,
#        even if the agent then failed, timed out or gave no summary. In those
#        last two cases the pass's other notes are put back as for exit 5
#   3    REFUSED: command mode without VAULT_ALLOW_UNENFORCED_TOOLS=1
#   4    COMMIT-FAILED: staging or committing the notes failed or ran past
#        RUNNER_GIT_TIMEOUT, and they are left uncommitted
#   5    CHECK-FAILED: vault-check rejected a note the pass changed, and every
#        note the pass changed was put back as it was before the pass, except
#        any the log lists as left as it is
#   64   VAULT_AGENT is not claude or command
#   70   TRIPWIRE-ERROR: containment was needed but no tripwire could be written
#   75   LOCKED: another pass held the run lock, or git's index.lock stayed, for
#        RUN_LOCK_WAIT seconds, the run lock is marked KILL_FAILED, the
#        index.lock is more than 10 minutes old,
#        another runner took the lock over before the pass started, a git
#        merge, rebase, cherry-pick, revert or bisect is in progress, or HEAD is
#        detached
#   78   TRIPWIRE: a tripwire is set, or an earlier pass died before containment
#   124  TIMEOUT: the watchdog killed a run that exceeded PROMOTION_PASS_TIMEOUT,
#        and everything it started
#   125  STALLED: the watchdog killed a claude-mode run whose stream stopped
#        growing for the stall threshold, and everything it started. After 124 or
#        125, KILL_FAILED in the log means a process may still be running and the
#        run lock is kept, so later runs exit 75
#   127  the claude binary or the VAULT_AGENT_CMD wrapper was not found
#   *    any other non-zero status is the agent's own

set -u

RUNNER=promotion-pass
CONTAINMENT_CHECKED=0
INFLIGHT=0
SNAP_DIR=""

# On any exit: clear the in-flight marker only once containment has checked the
# pass, then remove the temporary directory.
on_exit() {
  if [ "$CONTAINMENT_CHECKED" -eq 1 ]; then
    clear_inflight "$ROOT" "$STATE"
    rm -f "$STATE/inflight-backup.tar" 2>/dev/null
  fi
  [ -n "$SNAP_DIR" ] && rm -rf "$SNAP_DIR"
  run_lock_release
}

# On INT or TERM: stop the agent, and if it had started, containment cannot be
# trusted to have run, so set the tripwire now rather than leave the vault to the
# next pass's baseline.
on_signal() {
  # The whole tree, so a child of the agent cannot keep writing after the exit.
  [ -n "${RUN_PID:-}" ] && stop_tree "$RUN_PID" 2 "${TMPDIR:-/tmp}/promotion-pass-signal.$$" "${AGENT_SESSION_ID:-}" 1 \
    && rm -f "${TMPDIR:-/tmp}/promotion-pass-signal.$$"
  if [ "$INFLIGHT" -eq 1 ] && [ "$CONTAINMENT_CHECKED" -eq 0 ]; then
    : > "$SNAP_DIR/empty"
    if write_tripwire "$ROOT" "$STATE" "$RUNNER" \
         "the pass was interrupted by a signal before containment ran, so the vault's steering surfaces are unverified (the pre-pass backup is $STATE/inflight-backup.tar)" \
         "(none, because containment did not run)" "$SNAP_DIR/empty"; then
      clear_inflight "$ROOT" "$STATE"
      printf '[%s] INTERRUPTED before containment. Tripwire set.\n' "$(ts)" >> "$LOG"
    else
      # With no tripwire the marker stays, so the next run still refuses.
      printf '[%s] TRIPWIRE-ERROR: interrupted before containment and no tripwire could be written. The in-flight marker is kept.\n' "$(ts)" >> "$LOG"
    fi
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
  LOG="$LOG_DIR/promotion-agent.log"
  RUN_OUT="$LOG_DIR/promotion-agent.run.log"
  # Settings that reach arithmetic are checked first. A value that is not a whole
  # number would abort the runner with nothing in the log, and bash evaluates a
  # variable in arithmetic as an expression.
  TIMEOUT="$(uint_setting PROMOTION_PASS_TIMEOUT 5400 1 "$LOG")"
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

  # The agent is asked to end with this exact line. It is the positive evidence
  # that a pass reached its end: an error dump, however long, does not contain it.
  SUMMARY_MARKER='PROMOTION-SUMMARY:'

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

  TASK="Run this week's promotion pass per your instructions: scan 20-projects/_logs/ for promotion candidates, run the trust sweep over the long-term notes, and write the ones that meet the promotion bar. You have no shell. The repository state recorded before this run, with the long-tier changes since the last promotion pass, is in .claude/logs/promotion-pass.git-state.txt, and the runner commits your notes after the pass. End your final message with one line of the form: ${SUMMARY_MARKER} promoted=<n> pending=<n>"
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
    SNAP_DIR=""
    printf '[%s] ERROR: could not create a temporary directory\n' "$(ts)" >> "$LOG"
    exit 1
  }
  mkdir -p "$SNAP_DIR/nohooks"

  # A git operation in progress or a detached HEAD stops the run before the agent
  # starts, because the runner commits the pass's notes.
  git_preflight "$ROOT" "$SNAP_DIR/nohooks" "$LOG"
  git_rc=$?
  [ "$git_rc" -eq 0 ] || exit "$git_rc"

  # Files someone was already editing, which the pass must not change.
  : > "$SNAP_DIR/predirty"
  : > "$SNAP_DIR/predirty.adopted"
  if [ "$VAULT_GIT" -eq 1 ] && ! git_dirty_paths "$ROOT" "$SNAP_DIR/nohooks" "$SNAP_DIR/predirty"; then
    printf '[%s] ERROR: git status failed, so the files already being edited are unknown. Refusing to run.\n' "$(ts)" >> "$LOG"
    exit 1
  fi
  if [ "$VAULT_GIT" -eq 1 ]; then
    # Notes an earlier run of this runner left uncommitted, and nobody has
    # touched since, are this runner's own, not someone's edit. One that fails
    # the check is put back now, so it cannot take this pass's notes down with it.
    adopt_uncommitted "$ROOT" "$SNAP_DIR/nohooks" "$STATE" "$RUNNER" "$SNAP_DIR/predirty"
    head_now="$(head_state "$ROOT" "$SNAP_DIR/nohooks")"
    check_leftovers "$ROOT" "$SNAP_DIR" "${head_now##* }" \
      "$STATE/quarantine/$(date +%Y%m%dT%H%M%S)-$RUNNER-$$-leftover" "$LOG" 1
    if [ -s "$SNAP_DIR/predirty.adopted" ]; then
      printf '[%s] ADOPTED: notes an earlier run left uncommitted are checked and committed, or put back, with this pass:\n' "$(ts)" >> "$LOG"
      sed 's/^/    /' "$SNAP_DIR/predirty.adopted" >> "$LOG"
    fi
  fi

  # The agent has no shell, so the runner records the history it needs: recent
  # commits, the long-tier changes committed since the last promotion pass, and
  # the long-tier changes nobody has committed yet, kept apart so a note a human
  # committed does not look like work in progress. An earlier run's file is
  # removed first, and a file that cannot be written stops the run, so the agent
  # never reads a stale history.
  GIT_STATE_FILE="$LOG_DIR/promotion-pass.git-state.txt"
  rm -f "$GIT_STATE_FILE" 2>/dev/null
  {
    printf 'Recorded by promotion-pass.sh at %s, before the agent started.\n\n' "$(ts)"
    if [ "$VAULT_GIT" -eq 1 ]; then
      printf '## git log --oneline -10\n'
      safe_git "$SNAP_DIR/nohooks" -C "$ROOT" log --oneline -10 2>&1
      last_pass="$(safe_git "$SNAP_DIR/nohooks" -C "$ROOT" log -1 --format=%H --grep='^Vault-Pass: promotion$' 2>/dev/null)"
      if [ -n "$last_pass" ]; then
        printf '\n## Long-tier changes committed since the last promotion pass (%s), first 400 lines\n' "$last_pass"
        safe_git "$SNAP_DIR/nohooks" -C "$ROOT" diff --stat "$last_pass" HEAD -- 31-standards 40-llm-wiki/wiki 2>&1
        safe_git "$SNAP_DIR/nohooks" -C "$ROOT" diff "$last_pass" HEAD -- 31-standards 40-llm-wiki/wiki 2>&1 | head -n 400
      else
        printf '\n## No earlier promotion pass commit was found, so there is no diff since one.\n'
      fi
      printf '\n## Uncommitted long-tier changes, first 400 lines\n'
      safe_git "$SNAP_DIR/nohooks" -C "$ROOT" status --short --untracked-files=all -- 31-standards 40-llm-wiki/wiki 2>&1
      if safe_git "$SNAP_DIR/nohooks" -C "$ROOT" rev-parse -q --verify HEAD >/dev/null 2>&1; then
        safe_git "$SNAP_DIR/nohooks" -C "$ROOT" diff HEAD -- 31-standards 40-llm-wiki/wiki 2>&1 | head -n 400
      fi
      if [ -s "$SNAP_DIR/predirty.adopted" ]; then
        printf '\n## Notes an earlier promotion pass left uncommitted, which the runner checks and commits with yours\n'
        cat "$SNAP_DIR/predirty.adopted"
      fi
      printf '\n## git status --short\n'
      safe_git "$SNAP_DIR/nohooks" -C "$ROOT" status --short 2>&1
    else
      printf 'No git history is available, because %s.\n' "$VAULT_GIT_NOTE"
    fi
  } > "$GIT_STATE_FILE" 2>/dev/null
  if [ ! -f "$GIT_STATE_FILE" ] || [ ! -s "$GIT_STATE_FILE" ]; then
    printf '[%s] ERROR: could not write the git state file %s, so the agent would have no history to read. Refusing to run.\n' "$(ts)" "$GIT_STATE_FILE" >> "$LOG"
    exit 1
  fi

  snapshot_tree "$ROOT" "$SNAP_DIR/before"
  # Containment needs the pre-pass copy. Without it, refuse rather than run a pass
  # whose planted files could not be undone.
  if ! backup_steering "$ROOT" "$SNAP_DIR/before" "$SNAP_DIR/steering.tar"; then
    printf '[%s] ERROR: could not back up the steering surfaces (tar missing, or the archive is incomplete). Refusing to run without containment.\n' "$(ts)" >> "$LOG"
    exit 1
  fi
  HEAD_BEFORE="$(head_state "$ROOT" "$SNAP_DIR/nohooks")"
  # The last check before the in-flight marker and backup are written to the
  # shared state directory. A leftover put back above has already written its
  # quarantine copy there.
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
  printf '[%s] starting promotion-agent weekly pass via %s (timeout %ss, stall %ss, %s, session %s)\n' \
    "$(ts)" "$AGENT_KIND" "$TIMEOUT" "$AGENT_STALL_SECONDS" "$AGENT_STALL_NOTE" "$AGENT_SESSION_ID" >> "$LOG"

  # This run's output goes to its own file, so the evidence checked below is the
  # agent's output from THIS run - never the runner's own log lines, never a
  # previous run's. It is appended to the history log after containment.
  : > "$SNAP_DIR/run"

  run_agent "$TIMEOUT" "$SNAP_DIR/run" promotion-agent "$TASK" "$PROMPT_REL"

  snapshot_tree "$ROOT" "$SNAP_DIR/after"
  changed_paths "$SNAP_DIR/before" "$SNAP_DIR/after" > "$SNAP_DIR/changed"

  # CONTAINMENT comes first, before the exit code is even looked at: a pass that
  # timed out may still have planted something, and nothing from the vault may
  # run until it has been put back.
  contain_pass "$ROOT" "$STATE" "$RUNNER" "$SNAP_DIR" "$LOG" "$HEAD_BEFORE"
  contain_rc=$?
  # Nothing is written to the vault's logs between the agent's end and
  # containment, because the pass may have put a link in place of a log. What
  # the stop found, and a KILL_FAILED mark on the lock, come now.
  if [ "$RUN_TIMED_OUT" -eq 1 ] || [ "$RUN_STALLED" -eq 1 ]; then
    report_stop "$LOG" promotion-agent "$ROOT"
  fi
  # The pass could have put a link, or something other than a file, where the
  # run log was. Containment has moved a link out by now, and the output is
  # written only to a regular file or a new one, never through a link.
  if [ ! -L "$RUN_OUT" ] && { [ -f "$RUN_OUT" ] || [ ! -e "$RUN_OUT" ]; }; then
    cat "$SNAP_DIR/run" >> "$RUN_OUT" 2>/dev/null
  fi
  if [ "$contain_rc" -ne 0 ]; then
    exit "$contain_rc"
  fi
  CONTAINMENT_CHECKED=1
  # The session is recorded however the pass ended, so a later capture of Claude
  # Code sessions never takes a runner's pass for a person's work. A clean pass's
  # silent stretches teach the stall threshold.
  if [ "$AGENT_KIND" = claude ]; then
    record_runner_session "$STATE" "$RUNNER" "$SNAP_DIR/run" 0 "$AGENT_SESSION_ID" "$LOG"
    if [ "$RUN_TIMED_OUT" -eq 0 ] && [ "$RUN_STALLED" -eq 0 ] && [ "$RUN_RC" -eq 0 ]; then
      record_stream_gaps "$STATE" "$RUNNER" "$AGENT_GAPS_FILE"
    fi
  fi
  if [ "$CONTAINED" -eq 1 ]; then
    [ "$RUN_TIMED_OUT" -eq 1 ] && printf '[%s] (the run had also exceeded %ss and was killed)\n' "$(ts)" "$TIMEOUT" >> "$LOG"
    [ "$RUN_STALLED" -eq 1 ] && printf '[%s] (the run had also stalled for %ss and was killed)\n' "$(ts)" "$AGENT_STALL_SECONDS" >> "$LOG"
    exit 2
  fi

  # WRITE FENCE. A promotion pass may write long-tier notes (never their
  # templates), a promotion report in 20-projects/_logs/, and nothing else. An
  # auto-written compaction stub is tolerated. Anything else - a rule, an agent
  # definition, CLAUDE.md, someone's daily note - is a violation. The pass owns
  # what it may write, except the compaction stub.
  grep -vE '^(31-standards|40-llm-wiki/wiki)/' "$SNAP_DIR/changed" \
    | grep -vE '^20-projects/_logs/(promotion-|compaction-)[^/]*\.md$' > "$SNAP_DIR/outside"
  grep -E '^(31-standards|40-llm-wiki/wiki)/(.*/)?templates/' "$SNAP_DIR/changed" >> "$SNAP_DIR/outside"
  OWNED_PATTERN='^(31-standards|40-llm-wiki/wiki)/|^20-projects/_logs/promotion-[^/]*\.md$'
  grep -E "$OWNED_PATTERN" "$SNAP_DIR/changed" > "$SNAP_DIR/owned"
  # Notes an earlier run left uncommitted are checked and committed, or put back,
  # with this pass's own, whether or not this pass touched them.
  own_adopted "$SNAP_DIR" "$OWNED_PATTERN"

  # put_back <exit-status>
  # Puts back the notes the pass owns, except the ones someone was already
  # editing, whose pre-pass bytes are in no commit, forgets the leftover record,
  # and exits.
  put_back() {
    awk 'FILENAME == ARGV[1] { dirty[$0] = 1; next } !($0 in dirty)' "$SNAP_DIR/predirty" "$SNAP_DIR/owned" > "$SNAP_DIR/revert"
    if [ -s "$SNAP_DIR/revert" ]; then
      printf '[%s] REVERTED: the notes the pass changed are put back as they were before the pass, except any listed as left:\n' "$(ts)" >> "$LOG"
      if ! revert_owned "$ROOT" "$SNAP_DIR/nohooks" "$SNAP_DIR" "$SNAP_DIR/revert" "${HEAD_BEFORE##* }" \
             "$STATE/quarantine/$(date +%Y%m%dT%H%M%S)-$RUNNER-$$-rejected" "$LOG"; then
        printf '[%s] ERROR: some notes could not be put back, as listed above. Review them before the next pass.\n' "$(ts)" >> "$LOG"
      fi
    fi
    forget_uncommitted "$STATE" "$RUNNER"
    exit "$1"
  }

  if [ "$RUN_TIMED_OUT" -eq 1 ] || [ "$RUN_STALLED" -eq 1 ]; then
    if [ "$RUN_TIMED_OUT" -eq 1 ]; then
      printf '[%s] TIMEOUT: promotion-agent exceeded %ss and was killed (status %s)\n' \
        "$(ts)" "$TIMEOUT" "$RUN_RC" >> "$LOG"
      stop_rc=124
    else
      printf '[%s] STALLED: promotion-agent wrote no output for %ss (%s) and was killed (status %s)\n' \
        "$(ts)" "$AGENT_STALL_SECONDS" "$AGENT_STALL_NOTE" "$RUN_RC" >> "$LOG"
      stop_rc=125
    fi
    # What the pass wrote before it was killed is still listed.
    if [ -s "$SNAP_DIR/outside" ]; then
      printf '[%s] VIOLATION: files outside the allowed write areas changed before the pass was killed, so nothing it wrote is recorded for the next run:\n' "$(ts)" >> "$LOG"
      LC_ALL=C sort -u "$SNAP_DIR/outside" | sed 's/^/    /' >> "$LOG"
      [ "$VAULT_GIT" -eq 1 ] && owned_predirty "$SNAP_DIR/owned" "$SNAP_DIR/predirty" "$SNAP_DIR" "$LOG"
    elif [ "$VAULT_GIT" -eq 1 ] && ! check_owned "$ROOT" "$SNAP_DIR/owned" "$SNAP_DIR/predirty" "$SNAP_DIR" "$LOG"; then
      # Put back as a failing pass is, so a pass that hangs cannot keep its
      # other notes for the next run to commit.
      put_back 2
    fi
    record_leftovers "$ROOT" "$SNAP_DIR/nohooks" "$STATE" "$RUNNER" "$SNAP_DIR" "$LOG"
    exit "$stop_rc"
  fi

  printf '[%s] promotion-agent exited with code %s\n' "$(ts)" "$RUN_RC" >> "$LOG"

  if [ -s "$SNAP_DIR/outside" ]; then
    printf '[%s] VIOLATION: files outside the allowed write areas changed during the run:\n' "$(ts)" >> "$LOG"
    LC_ALL=C sort -u "$SNAP_DIR/outside" | sed 's/^/    /' >> "$LOG"
    exit 2
  fi

  if [ "$RUN_RC" -ne 0 ]; then
    # A failing pass that wrote into a note someone was editing, or removed or
    # replaced a note, is a violation whatever the agent's own status, and is put
    # back like a pass whose commit stopped for that reason. Any other failing
    # pass leaves its notes for the next run to check.
    if [ "$VAULT_GIT" -eq 1 ] && ! check_owned "$ROOT" "$SNAP_DIR/owned" "$SNAP_DIR/predirty" "$SNAP_DIR" "$LOG"; then
      put_back 2
    fi
    record_leftovers "$ROOT" "$SNAP_DIR/nohooks" "$STATE" "$RUNNER" "$SNAP_DIR" "$LOG"
    exit "$RUN_RC"
  fi

  # ARTIFACT ASSERTION. Promoting nothing is a legitimate outcome, so a pass may
  # change no note at all - but then it must say so with the summary line. A pass
  # with neither a long-tier change nor a summary produced no evidence it ran.
  if [ "$AGENT_KIND" = claude ]; then
    # In the stream the agent's final text is the "result" string of the result
    # event, JSON-escaped. The line counts only there, at the start of the text
    # or right after an escaped line break.
    summary="$(awk 'index($0, "\"type\":\"result\"") {
        s = $0
        while (match(s, /("|\\n)PROMOTION-SUMMARY: promoted=[0-9]+ pending=[0-9]+/)) { last = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) }
      }
      END { if (last != "") { sub(/^[^P]*/, "", last); print last } }' "$SNAP_DIR/run")"
  else
    summary="$(grep -E "^${SUMMARY_MARKER}" "$SNAP_DIR/run" | tail -n 1)"
  fi
  long_changes="$(awk '/^(31-standards|40-llm-wiki\/wiki)\//{n++} END{print n+0}' "$SNAP_DIR/changed")"
  if [ -z "$summary" ] && [ "${long_changes:-0}" -eq 0 ]; then
    printf '[%s] NO-ARTIFACT: exited 0 with no %s line and no long-tier change\n' \
      "$(ts)" "$SUMMARY_MARKER" >> "$LOG"
    # A promotion report such a run wrote is kept for the next run to check,
    # unless the run also deleted a report or wrote into one someone was editing.
    if [ "$VAULT_GIT" -eq 1 ] && ! check_owned "$ROOT" "$SNAP_DIR/owned" "$SNAP_DIR/predirty" "$SNAP_DIR" "$LOG"; then
      put_back 2
    fi
    record_leftovers "$ROOT" "$SNAP_DIR/nohooks" "$STATE" "$RUNNER" "$SNAP_DIR" "$LOG"
    exit 1
  fi

  # COMMIT. Exactly the notes the pass changed, and the leftovers adopted above,
  # checked first. Notes that fail the check are put back, and so are the notes of
  # a pass whose commit stopped with exit 2, so deleting a note cannot keep the
  # others in place. A note someone was already editing is never put back,
  # because its pre-pass bytes are in no commit.
  commit_owned "$ROOT" promotion "$SNAP_DIR/owned" "$SNAP_DIR/predirty" "$SNAP_DIR" "$LOG"
  commit_rc=$?
  case "$commit_rc" in
    0) forget_uncommitted "$STATE" "$RUNNER" ;;
    4)
      record_leftovers "$ROOT" "$SNAP_DIR/nohooks" "$STATE" "$RUNNER" "$SNAP_DIR" "$LOG"
      exit 4
      ;;
    2|5) put_back "$commit_rc" ;;
    *) exit "$commit_rc" ;;
  esac

  printf '[%s] OK: %s long-tier file(s) changed; %s\n' \
    "$(ts)" "${long_changes:-0}" "${summary:-no summary line}" >> "$LOG"
  exit 0
}

main "$@"
exit $?
