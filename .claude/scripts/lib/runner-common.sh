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

# snapshot_tree <root> <output-file>
#
# Writes one "checksum size path" line per file under <root>, sorted.
#
# Pruned: .claude/logs/ (the runner writes there) and the three Obsidian
# workspace files, which Obsidian rewrites whenever a pane moves and which carry
# no code. Everything else in .obsidian/ stays inside the fence: a plugin's
# main.js plus an entry in community-plugins.json is code Obsidian runs on its
# next start, and .obsidian/ is not one of the paths Claude Code protects.
#
# Agent memory (.claude/agent-memory*) and 90-auto-memory/ are fenced in every
# mode. Memory loads into later sessions, so an unseen write there would be a
# planted instruction. run_agent turns Claude Code's own auto memory off for the
# pass, which is what makes fencing it in claude mode possible.
#
# .git/ is pruned as a tree, but the files in it that run code or move history
# are checksummed: config, hooks, info, HEAD, refs (not remote-tracking refs,
# which a background fetch updates), packed-refs, alternates, and each
# submodule's config and hooks. A vault whose .git is a file (a worktree
# pointer) has that file checksummed instead.
#
# `find -exec ... +` rather than xargs: xargs with empty input runs cksum with
# no arguments on some platforms, and cksum would then wait on stdin forever.
snapshot_tree() {
  local root="$1" out="$2"
  (
    cd "$root" || exit 1
    find . \( -path ./.git -o -path ./.claude/logs \
              -o -path ./.obsidian/workspace.json -o -path ./.obsidian/workspace-mobile.json \
              -o -path ./.obsidian/workspace.json.bak \) -prune \
         -o -type f -exec cksum {} + 2>/dev/null
    if [ -d .git ]; then
      for f in .git/config .git/HEAD .git/packed-refs .git/objects/info/alternates; do
        [ -f "$f" ] && cksum "./$f" 2>/dev/null
      done
      for d in .git/hooks .git/info .git/refs; do
        [ -d "$d" ] && find "./$d" -path ./.git/refs/remotes -prune -o -type f -exec cksum {} + 2>/dev/null
      done
      [ -d .git/modules ] && find ./.git/modules \( -name config -o -path '*/hooks/*' \) -type f \
        -exec cksum {} + 2>/dev/null
    elif [ -f .git ]; then
      cksum ./.git 2>/dev/null
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
# Containment.
#
# A fence that only reports leaves whatever a steered pass planted in place: the
# run exits 2, the scheduler shows a task that ran, and the planted Obsidian
# plugin or git hook runs the next time something opens the vault. So a change
# to a STEERING or EXECUTION surface is contained before the runner exits:
#
#   1. the file as the pass left it is moved to a quarantine directory OUTSIDE
#      the vault (never deleted, so nothing a human wrote at the same moment is
#      lost);
#   2. the pre-pass copy is restored from a backup taken before the agent ran;
#   3. a tripwire file is written, and every runner and vault-check.sh refuse to
#      run until a human has read it and deleted it.
#
# Changes to ordinary notes are not contained. They run no code, a human may be
# editing one at the same moment, and git already shows the diff; the fence
# reports them as before.

TRIPWIRE_REL=".claude/logs/runner-tripwire"

# is_steering_path <relative-path>
# True for files that run code or steer later sessions: Obsidian configuration and
# plugins (not the workspace files), everything under .claude/ except logs and
# worktrees, every shipped harness's configuration, the instruction files, memory,
# and git's config, hooks, info, refs and alternates.
is_steering_path() {
  case "$1" in
    .obsidian/workspace.json|.obsidian/workspace-mobile.json|.obsidian/workspace.json.bak) return 1 ;;
    .claude/logs/*|.claude/worktrees/*) return 1 ;;
    .obsidian/*|.claude/*|.agents/*|.codex/*|.gemini/*|.cursor/*|.windsurf/*|.opencode/*|.github/*|.vscode/*) return 0 ;;
    90-auto-memory/*) return 0 ;;
    .mcp.json|opencode.json|.aider.conf.yml|AGENTS.md|CLAUDE.md|GEMINI.md) return 0 ;;
    .gitattributes|.gitignore|.geminiignore|.cursorignore) return 0 ;;
    .git|.git/*) return 0 ;;
    *) return 1 ;;
  esac
}

# is_restorable_path <relative-path>
# Git's HEAD, refs and packed-refs are contained by the tripwire alone. Rewriting
# them back could undo a real commit made while the pass ran, and git's reflog is
# the better recovery tool; with the tripwire set, no runner builds on them.
is_restorable_path() {
  case "$1" in
    .git/HEAD|.git/packed-refs|.git/refs/*) return 1 ;;
    *) return 0 ;;
  esac
}

# steering_files <root>
# Prints every existing steering file as a relative path, one per line, sorted.
# This is the list the pre-pass backup holds.
steering_files() {
  (
    cd "$1" || exit 1
    for d in .obsidian .claude .agents .codex .gemini .cursor .windsurf .opencode .github .vscode 90-auto-memory; do
      [ -d "$d" ] && find "$d" \( -path .claude/logs -o -path .claude/worktrees \) -prune -o -type f -print 2>/dev/null
    done
    for f in .mcp.json opencode.json .aider.conf.yml AGENTS.md CLAUDE.md GEMINI.md \
             .gitattributes .gitignore .geminiignore .cursorignore; do
      [ -f "$f" ] && printf '%s\n' "$f"
    done
    if [ -d .git ]; then
      for f in .git/config .git/objects/info/alternates; do [ -f "$f" ] && printf '%s\n' "$f"; done
      for d in .git/hooks .git/info; do [ -d "$d" ] && find "$d" -type f -print 2>/dev/null; done
      [ -d .git/modules ] && find .git/modules \( -name config -o -path '*/hooks/*' \) -type f -print 2>/dev/null
    elif [ -f .git ]; then
      printf '.git\n'
    fi
  ) | grep -vE '^\.obsidian/workspace(-mobile)?\.json(\.bak)?$' | LC_ALL=C sort
}

# backup_steering <root> <tarball>
# Writes <tarball> and <tarball>.list. Returns non-zero, after which the runner
# must refuse to start, when tar is missing or the archive cannot be written: a
# pass whose containment cannot work must not run unattended.
backup_steering() {
  local root="$1" tarball="$2"
  command -v tar >/dev/null 2>&1 || return 1
  steering_files "$root" > "$tarball.list" || return 1
  if [ -s "$tarball.list" ]; then
    ( cd "$root" && tar -cf "$tarball" -T "$tarball.list" ) 2>/dev/null || return 1
  else
    : > "$tarball"
  fi
  return 0
}

# vault_state_dir <root>
# Per-vault state directory OUTSIDE the vault, so nothing kept there is indexed by
# Obsidian, synced with the vault folder, or reachable by an agent's file tools
# in the vault. VAULT_STATE_DIR overrides it (the test suite uses that).
vault_state_dir() {
  local root="$1" base id
  if [ -n "${VAULT_STATE_DIR:-}" ]; then
    printf '%s\n' "$VAULT_STATE_DIR"
    return 0
  fi
  if [ -n "${LOCALAPPDATA:-}" ]; then
    base="$LOCALAPPDATA"
    command -v cygpath >/dev/null 2>&1 && base="$(cygpath -u "$base")"
  else
    base="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}"
  fi
  id="$(printf '%s' "$root" | cksum | cut -d' ' -f1)"
  printf '%s/claude-memory-vault/%s\n' "$base" "$id"
}

# contain_steering_changes <root> <changed-list> <tarball> <quarantine-dir> <log>
# For each changed steering path: quarantine the current file (if any), then
# restore the pre-pass copy (if one existed and the path is restorable). Prints
# each steering path it handled. Returns 0 when at least one was found.
contain_steering_changes() {
  local root="$1" changed="$2" tarball="$3" qdir="$4" log="$5" rel found=1
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    is_steering_path "$rel" || continue
    found=0
    printf '%s\n' "$rel"
    is_restorable_path "$rel" || continue
    if [ -e "$root/$rel" ]; then
      if ! { mkdir -p "$qdir/$(dirname "$rel")" && mv -f "$root/$rel" "$qdir/$rel"; } 2>/dev/null; then
        printf '[%s] CONTAINMENT-ERROR: could not quarantine %s\n' "$(ts)" "$rel" >> "$log"
        continue
      fi
    fi
    if grep -qxF -e "$rel" "$tarball.list" 2>/dev/null; then
      if ! ( cd "$root" && tar -xf "$tarball" "$rel" ) 2>/dev/null; then
        printf '[%s] CONTAINMENT-ERROR: could not restore %s from the pre-pass backup\n' "$(ts)" "$rel" >> "$log"
      fi
    fi
  done < "$changed"
  return "$found"
}

# write_tripwire <root> <runner> <quarantine-dir> <handled-list>
write_tripwire() {
  {
    printf 'TRIPWIRE set by %s at %s\n\n' "$2" "$(ts)"
    printf 'An unattended pass changed a steering or execution surface. The files below were\n'
    printf 'moved to the quarantine and restored from the pre-pass backup where one existed.\n'
    printf "Git HEAD and refs are never rewritten: check them with 'git reflog'.\n\n"
    printf 'Quarantine: %s\n\nPaths:\n' "$3"
    sed 's/^/  /' "$4"
    printf '\nNo runner, and not vault-check.sh, will run while this file exists.\n'
    printf 'Read the quarantined files, then delete this file to clear the tripwire.\n'
  } > "$1/$TRIPWIRE_REL"
}

# tripwire_check <root> <log>
# Returns 0 when clear, otherwise logs the refusal and returns 78.
tripwire_check() {
  if [ -e "$1/$TRIPWIRE_REL" ]; then
    printf '[%s] TRIPWIRE: refusing to run. A previous pass changed a steering or execution surface; read %s, then delete it.\n' \
      "$(ts)" "$TRIPWIRE_REL" >> "$2"
    return 78
  fi
  return 0
}

# safe_git <empty-hooks-dir> <git args...>
# Git as the runner calls it: no hooks, no fsmonitor, no prompts. Both are ways a
# changed config or hook directory would otherwise run code in the runner's shell.
safe_git() {
  local hooks="$1"
  shift
  GIT_TERMINAL_PROMPT=0 git -c core.hooksPath="$hooks" -c core.fsmonitor=false "$@"
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
      #
      # Auto memory is switched off for the pass. Claude Code would otherwise
      # write memory files the fence has to treat as a planted instruction.
      export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1
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
