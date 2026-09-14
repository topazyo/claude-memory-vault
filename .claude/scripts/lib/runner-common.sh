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
#   containment        a fence that only reports leaves a planted file in place
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
# timeout elapses and KILL after a grace period. Sets three globals:
#   RUN_PID        the command's pid, so a signal handler can stop it
#   RUN_RC         the command's exit status (143/137 when the watchdog fired)
#   RUN_TIMED_OUT  1 if the watchdog fired, else 0
#
# The watchdog signals this pid only. A wrapper's children, or a native Windows
# process started from Git Bash, can outlive it; the scheduled-pass plan tracks a
# process-tree kill as separate work.
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
  RUN_PID=$pid

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

# ---------------------------------------------------------------------------
# What the fence sees.

# git_dirs_of <root>
# For a vault whose .git is a FILE (a linked worktree), prints the per-worktree
# git directory and the common git directory, one per line, read from the
# pointer file without running git. Returns 1 when .git is not a file.
git_dirs_of() {
  local root="$1" gd cd
  [ -f "$root/.git" ] || return 1
  gd="$(sed -n 's/^gitdir: //p' "$root/.git" | tr -d '\r' | head -n 1)"
  [ -n "$gd" ] || return 1
  command -v cygpath >/dev/null 2>&1 && gd="$(cygpath -u "$gd")"
  case "$gd" in /*) ;; *) gd="$root/$gd" ;; esac
  if [ -f "$gd/commondir" ]; then
    cd="$(tr -d '\r' < "$gd/commondir" | head -n 1)"
    command -v cygpath >/dev/null 2>&1 && cd="$(cygpath -u "$cd")"
    case "$cd" in /*) ;; *) cd="$gd/$cd" ;; esac
  else
    cd="$gd"
  fi
  printf '%s\n%s\n' "$gd" "$cd"
}

# fence_find <find start and prune arguments...>
# One line per file ("checksum size path", from cksum) and per symlink
# ("L<checksum of the link target> 0 path"), so a file swapped for a symlink, or
# a link retargeted, changes its line. `find -exec ... +` rather than xargs:
# xargs with empty input runs cksum with no arguments on some platforms, and
# cksum would then wait on stdin forever.
fence_find() {
  find "$@" -type f -exec cksum {} + 2>/dev/null
  find "$@" -type l -print 2>/dev/null | while IFS= read -r link; do
    printf 'L%s 0 %s\n' "$(readlink "$link" 2>/dev/null | cksum | cut -d' ' -f1)" "$link"
  done
}

# relabel <prefix> <label>
# Rewrites the leading <prefix> of each fence line's path to <label>, for files
# that live outside the vault but belong to it (a worktree vault's git dirs).
relabel() {
  awk -v pre="$1" -v lab="$2" '{ i = index($0, pre); if (i) $0 = substr($0, 1, i - 1) lab substr($0, i + length(pre)); print }'
}

# snapshot_tree <root> <output-file>
#
# Writes one fence line per file and symlink under <root>, sorted.
#
# Not fenced: .claude/logs/ (the runner writes there), and in .obsidian/
# everything except what carries or enables code: community-plugins.json and
# the plugins/, themes/ and snippets/ folders. Obsidian rewrites its workspace,
# graph and app settings while open, and none of them runs anything.
# .obsidian/ is not a path Claude Code protects, so the code-bearing part must
# be inside the fence.
#
# A plugin's data.json holds its settings, and many plugins rewrite it during
# normal use, so it is fenced only for the plugins in CODE_PLUGINS, which run
# code or commands named in their settings. Everything else in a plugin folder
# (main.js, manifest.json, styles.css) is fenced for every plugin.
#
# Agent memory (.claude/agent-memory*) and 90-auto-memory/ are fenced in every
# mode. Memory loads into later sessions, so an unseen write there would be a
# planted instruction. run_agent turns Claude Code's own auto memory off for the
# pass, which is what makes fencing it in claude mode possible.
#
# In .git/ only the files that make git run code are fenced: config,
# config.worktree, hooks/, info/attributes and info/grafts, objects/info/alternates,
# and each submodule's config and hooks/. The rest of info/ is not, because
# `git gc --auto` after an ordinary commit rewrites info/refs. HEAD and refs are
# NOT fenced, because a pass may commit (the promotion agent takes a snapshot)
# and a human may commit while it runs. A rewound HEAD is caught separately
# (head_moved_backwards). For a worktree vault, whose .git is a file, the
# pointer is fenced and the same files in the common git directory appear under
# the label .git-common/.
#
# Known limit: a directory symlink that existed before the pass is fenced as a
# link, not by its target's contents, so a write through it is not seen.
CODE_PLUGINS="dataview templater-obsidian obsidian-shellcommands quickadd customjs obsidian-git execute-code terminal"
snapshot_tree() {
  local root="$1" out="$2" dirs gd cdir
  (
    cd "$root" || exit 1
    fence_find . \( -path ./.git -o -path ./.claude/logs -o -path ./.obsidian \) -prune -o
    [ -e .obsidian/community-plugins.json ] && fence_find ./.obsidian/community-plugins.json
    if [ -e .obsidian/plugins ] || [ -L .obsidian/plugins ]; then
      keep=()
      for p in $CODE_PLUGINS; do
        keep+=(! -path "./.obsidian/plugins/$p/data.json")
      done
      fence_find ./.obsidian/plugins \( -name data.json "${keep[@]}" \) -prune -o
    fi
    for d in .obsidian/themes .obsidian/snippets; do
      { [ -e "$d" ] || [ -L "$d" ]; } && fence_find "./$d"
    done
    if [ -d .git ]; then
      for f in .git/config .git/config.worktree .git/objects/info/alternates .git/info/attributes .git/info/grafts; do
        { [ -e "$f" ] || [ -L "$f" ]; } && fence_find "./$f"
      done
      { [ -e .git/hooks ] || [ -L .git/hooks ]; } && fence_find ./.git/hooks
      [ -d .git/modules ] && fence_find ./.git/modules \( -name config -o -path '*/hooks/*' \)
    elif [ -e .git ] || [ -L .git ]; then
      fence_find ./.git
      if dirs="$(git_dirs_of "$root")"; then
        gd="$(printf '%s\n' "$dirs" | sed -n 1p)"
        cdir="$(printf '%s\n' "$dirs" | sed -n 2p)"
        [ -e "$gd/config.worktree" ] && fence_find "$gd/config.worktree" | relabel "$gd" ./.git-common/worktree
        for f in config objects/info/alternates info/attributes info/grafts; do
          [ -e "$cdir/$f" ] && fence_find "$cdir/$f" | relabel "$cdir" ./.git-common
        done
        [ -e "$cdir/hooks" ] && fence_find "$cdir/hooks" | relabel "$cdir" ./.git-common
      fi
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

# snapshot_paths <snapshot>
# The relative paths a snapshot covers, one per line.
snapshot_paths() {
  cut -d' ' -f3- "$1" | sed 's|^\./||'
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
#      lost). If that move fails, the file is renamed in place with the suffix
#      .runner-quarantined, which stops Obsidian or git from loading it;
#   2. the pre-pass copy is restored from a backup taken before the agent ran;
#   3. a tripwire is written, inside the vault and in the per-vault state
#      directory, and every runner and vault-check.sh refuse to run until a human
#      has read it and deleted it.
#
# A pass that dies before containment runs (the scheduler ends the task, the
# machine powers off) leaves an in-flight marker, and the next runner turns that
# marker into a tripwire instead of adopting the unknown state as its baseline.
#
# Changes to ordinary notes are not contained. They run no code, a human may be
# editing one at the same moment, and git already shows the diff; the fence
# reports them as before.

TRIPWIRE_REL=".claude/logs/runner-tripwire"
INFLIGHT_REL=".claude/logs/runner-inflight"

# steering_filter
# Reads relative paths on stdin and prints the ones that are steering or
# execution surfaces. One awk program, so the fence, the backup and containment
# can never disagree about the set, and matching is case-insensitive (a
# case-insensitive filesystem loads Gemini.md as GEMINI.md). Inside
# .claude/worktrees/<name>/ the same rules apply to the rest of the path, so a
# worktree's own CLAUDE.md or .claude/ counts and its notes do not.
steering_filter() {
  # Every test is a plain anchored pattern: the BWK awk that macOS ships does not
  # reliably treat $ or ^ as anchors inside an alternation group.
  awk '
    function steer(lp) {
      if (lp == ".claude/logs" || lp ~ /^\.claude\/logs\//) return 0
      if (lp == ".obsidian/community-plugins.json") return 1
      if (lp ~ /^\.obsidian\/plugins\// || lp ~ /^\.obsidian\/themes\// || lp ~ /^\.obsidian\/snippets\//) return 1
      if (lp == ".obsidian/plugins" || lp == ".obsidian/themes" || lp == ".obsidian/snippets") return 1
      if (lp ~ /^\.obsidian\//) return 0
      if (lp == ".git" || lp ~ /^\.git\// || lp == ".git-common" || lp ~ /^\.git-common\//) return 1
      if (lp == "90-auto-memory" || lp ~ /^90-auto-memory\//) return 1
      if (lp == "opencode.json" || lp == ".aider.conf.yml" || lp == ".geminiignore" || lp == ".cursorignore" || lp == ".cursorrules" || lp == ".windsurfrules") return 1
      n = split(lp, part, "/")
      base = part[n]
      if (base == "claude.md" || base == "claude.local.md" || base == "agents.md" || base == "agents.override.md" || base == "gemini.md" || base == ".mcp.json" || base == ".gitattributes" || base == ".gitignore") return 1
      # Every component, the last included: a symlink named .claude is a harness
      # folder too, wherever it points.
      for (i = 1; i <= n; i++) {
        if (part[i] == ".claude" || part[i] == ".agents" || part[i] == ".codex" || part[i] == ".gemini" || part[i] == ".cursor" || part[i] == ".windsurf" || part[i] == ".opencode" || part[i] == ".github" || part[i] == ".vscode") return 1
      }
      return 0
    }
    {
      lp = tolower($0)
      if (lp ~ /^\.claude\/worktrees\/[^\/]+\//) {
        sub(/^\.claude\/worktrees\/[^\/]+\//, "", lp)
      } else if (lp == ".claude/worktrees" || lp ~ /^\.claude\/worktrees\/[^\/]*$/) {
        next
      }
      if (steer(lp)) print $0
    }'
}

# is_restorable_path <relative-path>
# .git-common/ lives outside the vault, so it is detected and put in the
# tripwire but never restored by this runner.
is_restorable_path() {
  case "$1" in
    .git-common|.git-common/*) return 1 ;;
    *) return 0 ;;
  esac
}

# backup_steering <root> <before-snapshot> <tarball>
# Archives every steering file and symlink the before-snapshot lists, and writes
# <tarball>.list. Returns non-zero, after which the runner must refuse to start,
# when tar is missing or the archive does not hold every listed member. GNU tar
# exits 1 when a file changed while it was read, which is not a failure if the
# member is there, so the archive's own listing is the evidence, not the status.
backup_steering() {
  local root="$1" snap="$2" tarball="$3" want have
  command -v tar >/dev/null 2>&1 || return 1
  snapshot_paths "$snap" | steering_filter | grep -v '^\.git-common' > "$tarball.list"
  if [ ! -s "$tarball.list" ]; then
    : > "$tarball"
    return 0
  fi
  ( cd "$root" && tar -cf "$tarball" -T "$tarball.list" ) 2>/dev/null
  want="$(awk 'END{print NR+0}' "$tarball.list")"
  have="$(tar -tf "$tarball" 2>/dev/null | awk 'END{print NR+0}')"
  [ "$have" -ge "$want" ] && [ "$want" -gt 0 ]
}

# vault_state_dir <root>
# Per-vault state directory OUTSIDE the vault, so nothing kept there is indexed by
# Obsidian, synced with the vault folder, or reachable by an agent's file tools
# in the vault. VAULT_STATE_DIR overrides it (the test suite uses that). Only an
# absolute path that is not inside the vault is accepted. A Windows path such as
# C:/Users/... is converted first. A rejected value is replaced with a directory
# under the system temp folder, and a warning saying so goes to stderr, which the
# runners append to their log. Set VAULT_STATE_DIR the same way for both runners
# and for any shell that runs vault-check.sh, or they look in different places.
vault_state_dir() {
  local root="$1" base id dir croot
  id="$(printf '%s' "$root" | cksum | cut -d' ' -f1)"
  if [ -n "${VAULT_STATE_DIR:-}" ]; then
    dir="$VAULT_STATE_DIR"
    command -v cygpath >/dev/null 2>&1 && dir="$(cygpath -u "$dir" 2>/dev/null || printf '%s' "$dir")"
  else
    base=""
    if [ -n "${LOCALAPPDATA:-}" ] && command -v cygpath >/dev/null 2>&1; then
      base="$(cygpath -u "$LOCALAPPDATA")"
    fi
    case "$base" in /*) ;; *) base="${XDG_STATE_HOME:-${HOME:-}/.local/state}" ;; esac
    dir="$base/claude-memory-vault/$id"
  fi
  croot="$(cd "$root" 2>/dev/null && pwd -P)"
  case "$dir" in
    ""|/.local/state/*|*/../*|*/..|"$root"|"$root"/*|"$croot"|"$croot"/*) dir="" ;;
    /*) [ -d "$dir" ] && case "$(cd "$dir" && pwd -P)" in "$croot"|"$croot"/*) dir="" ;; esac ;;
    *) dir="" ;;
  esac
  if [ -z "$dir" ]; then
    dir="${TMPDIR:-/tmp}/claude-memory-vault-state-$id"
    [ -n "${VAULT_STATE_DIR:-}" ] && printf '[%s] WARNING: VAULT_STATE_DIR "%s" is not an absolute path outside the vault; using %s\n' \
      "$(ts)" "$VAULT_STATE_DIR" "$dir" >&2
  fi
  printf '%s\n' "$dir"
}

# write_file_atomic <path> <content-file>
# Copies <content-file> to a temporary name beside <path> and renames it into
# place, then verifies a regular file (not a symlink) is there.
write_file_atomic() {
  local path="$1" src="$2" tmp
  tmp="$path.tmp.$$"
  mkdir -p "$(dirname "$path")" 2>/dev/null
  cp "$src" "$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  [ -f "$path" ] && [ ! -L "$path" ]
}

# guard_exists <root> <state-dir> <relative-name>
# True when the named guard file exists, or is a symlink (even a dangling one),
# in the vault or in the state directory.
guard_exists() {
  local p1="$1/$3" p2="$2/$(basename "$3")"
  [ -e "$p1" ] || [ -L "$p1" ] || [ -e "$p2" ] || [ -L "$p2" ]
}

# write_tripwire <root> <state-dir> <runner> <reason> <quarantine-dir> <handled-list> [<errors-list>]
# Writes the tripwire in the vault and in the state directory. Returns 0 when at
# least one copy is verified in place, 1 when neither could be written.
write_tripwire() {
  local root="$1" state="$2" runner="$3" reason="$4" qdir="$5" handled="$6" errors="${7:-}" body ok=1
  body="$(mktemp 2>/dev/null || mktemp -t tripwire)" || return 1
  {
    printf 'TRIPWIRE set by %s at %s\n\n' "$runner" "$(ts)"
    printf 'Reason: %s\n\n' "$reason"
    printf 'Changed files were moved to the quarantine and restored from the pre-pass\n'
    printf 'backup where one existed. Git HEAD and refs are never rewritten: check them\n'
    printf "with 'git reflog'. Anything under .git-common/ is outside the vault and was not\n"
    printf 'restored.\n\n'
    printf 'Quarantine: %s\n\n' "$qdir"
    if [ -s "$handled" ]; then
      printf 'Paths:\n'
      sed 's/^/  /' "$handled"
    fi
    if [ -n "$errors" ] && [ -s "$errors" ]; then
      printf '\nCONTAINMENT-ERROR (not quarantined, or not restored; check these first):\n'
      sed 's/^/  /' "$errors"
    fi
    printf '\nNo runner, and not vault-check.sh, will run while this file exists.\n'
    printf 'Review the paths above, then delete this file. The runners also keep a copy\n'
    printf 'at %s; delete that too.\n' "$state/$(basename "$TRIPWIRE_REL")"
  } > "$body"
  write_file_atomic "$root/$TRIPWIRE_REL" "$body" && ok=0
  write_file_atomic "$state/$(basename "$TRIPWIRE_REL")" "$body" && ok=0
  rm -f "$body"
  return "$ok"
}

# mark_inflight <root> <state-dir> <runner> / clear_inflight <root> <state-dir>
# The marker names the runner and its pid. It is removed only once containment
# has checked the pass, so any death before that leaves it behind. mark_inflight
# fails unless the state-directory copy, which the agent cannot reach, is in
# place; the runner must not start the agent without it.
mark_inflight() {
  local body rc
  body="$(mktemp 2>/dev/null || mktemp -t inflight)" || return 1
  printf 'runner=%s\npid=%s\nstarted=%s\n' "$3" "$$" "$(ts)" > "$body"
  write_file_atomic "$1/$INFLIGHT_REL" "$body"
  write_file_atomic "$2/$(basename "$INFLIGHT_REL")" "$body"
  rc=$?
  rm -f "$body"
  return "$rc"
}
clear_inflight() {
  rm -f "$1/$INFLIGHT_REL" "$2/$(basename "$INFLIGHT_REL")" 2>/dev/null
}

# tripwire_check <root> <state-dir> <runner> <log>
# Returns 0 when the vault is clear. Otherwise logs why and returns:
#   78  a tripwire exists, or an in-flight marker from a run that died before
#       containment (turned into a tripwire here)
#   75  an in-flight marker whose runner is still alive: another pass is running
#   70  an in-flight marker needed a tripwire and none could be written; the
#       marker is kept, so the next run refuses too
tripwire_check() {
  local root="$1" state="$2" runner="$3" log="$4" marker pid empty wrote
  if guard_exists "$root" "$state" "$TRIPWIRE_REL"; then
    printf '[%s] TRIPWIRE: refusing to run. A previous pass changed a steering or execution surface; read %s, then delete it.\n' \
      "$(ts)" "$TRIPWIRE_REL" >> "$log"
    return 78
  fi
  if guard_exists "$root" "$state" "$INFLIGHT_REL"; then
    # The state-directory copy first: the agent cannot reach it, while the copy
    # in the vault is a file the pass itself could have rewritten.
    marker="$state/$(basename "$INFLIGHT_REL")"
    [ -f "$marker" ] || marker="$root/$INFLIGHT_REL"
    pid="$(sed -n 's/^pid=//p' "$marker" 2>/dev/null | head -n 1)"
    case "$pid" in ''|*[!0-9]*) pid="" ;; esac
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf '[%s] LOCKED: another pass (pid %s) is still running; not starting.\n' "$(ts)" "$pid" >> "$log"
      return 75
    fi
    empty="$(mktemp 2>/dev/null || mktemp -t empty)"
    : > "$empty"
    wrote=1
    write_tripwire "$root" "$state" "$runner" \
      "a previous pass ended before containment ran (interrupted, killed, or the machine stopped); the vault's steering surfaces are unverified. $(tr '\n' ' ' < "$marker" 2>/dev/null)" \
      "(none: containment did not run; a pre-pass backup may be in the state directory)" "$empty" && wrote=0
    rm -f "$empty"
    if [ "$wrote" -ne 0 ]; then
      printf '[%s] TRIPWIRE-ERROR: a previous pass never reached containment and no tripwire could be written; the in-flight marker is kept. Refusing to run.\n' "$(ts)" >> "$log"
      return 70
    fi
    clear_inflight "$root" "$state"
    printf '[%s] TRIPWIRE: a previous pass never reached containment; tripwire set, refusing to run.\n' "$(ts)" >> "$log"
    return 78
  fi
  return 0
}

# contain_steering_changes <root> <changed-list> <tarball> <quarantine-dir> <handled-out> <errors-out>
# For each changed steering path: quarantine the current file or symlink, then
# restore the pre-pass copy when one existed and the path is restorable. Writes
# the handled paths and the paths that could not be contained. Returns 0 when at
# least one steering path changed.
contain_steering_changes() {
  local root="$1" changed="$2" tarball="$3" qdir="$4" handled="$5" errors="$6" rel restore rdirs d skip
  : > "$handled"
  : > "$errors"
  steering_filter < "$changed" > "$handled"
  [ -s "$handled" ] || return 1

  restore="$(dirname "$tarball")/restore"
  rdirs="$(dirname "$tarball")/restored-dirs"
  rm -rf "$restore"
  mkdir -p "$restore"
  : > "$rdirs"
  # Extract once, never by member name: bsdtar reads member names as patterns.
  if [ -s "$tarball" ] && ! ( cd "$restore" && tar -xf "$tarball" ) 2>/dev/null; then
    printf '(the pre-pass backup could not be extracted: paths below may not have been restored)\n' >> "$errors"
  fi

  # Paths are sorted, so a symlink that replaced a whole directory (.git/hooks
  # pointing elsewhere) comes before the files that were under it. Restoring the
  # directory restores those files too; they must not then be quarantined again.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    is_restorable_path "$rel" || continue
    skip=0
    while IFS= read -r d; do
      case "$rel" in "$d"/*) skip=1 ;; esac
    done < "$rdirs"
    [ "$skip" -eq 1 ] && continue
    if [ -e "$root/$rel" ] || [ -L "$root/$rel" ]; then
      if ! { mkdir -p "$qdir/$(dirname "$rel")" && mv -f "$root/$rel" "$qdir/$rel"; } 2>/dev/null; then
        if mv -f "$root/$rel" "$root/$rel.runner-quarantined" 2>/dev/null; then
          printf '%s (quarantine unavailable; renamed in place to %s.runner-quarantined)\n' "$rel" "$rel" >> "$errors"
        else
          printf '%s (could not be moved or renamed: still live)\n' "$rel" >> "$errors"
          continue
        fi
      fi
    fi
    if [ -e "$restore/$rel" ] || [ -L "$restore/$rel" ]; then
      [ -d "$restore/$rel" ] && [ ! -L "$restore/$rel" ] && printf '%s\n' "$rel" >> "$rdirs"
      if ! { mkdir -p "$root/$(dirname "$rel")" && mv -f "$restore/$rel" "$root/$rel"; } 2>/dev/null; then
        printf '%s (pre-pass copy could not be restored)\n' "$rel" >> "$errors"
      fi
    elif grep -qxF -- "$rel" "$tarball.list" 2>/dev/null; then
      printf '%s (backed up before the pass, but missing from the extracted backup: not restored)\n' "$rel" >> "$errors"
    fi
  done < "$handled"
  return 0
}

# ---------------------------------------------------------------------------
# Run lock.
#
# Every writer to the vault (both passes now, the retention mover and the
# harvester later) takes one vault-wide lock, so two passes never race each
# other's fences or git's index. The lock is a directory, because mkdir is
# atomic on every platform the runners support, and it lives in .claude/logs/,
# which is gitignored and outside the fence.
#
# Stale locks are judged by AGE, not by whether a pid is alive: a runner killed
# by Task Scheduler runs no trap, and its pid can be reused by an unrelated
# process. A lock is stale when it is older than the longest a run can take and
# either its runner is gone or it is twice that old. A lock marked KILL_FAILED
# (a runner that could not stop its agent) is never stale: that agent may still
# be writing.
#
#   RUN_LOCK_WAIT  seconds to wait for a live lock before exiting 75 (default 1800)
#   RUN_LOCK_POLL  seconds between checks (default 30)

RUN_LOCK_REL=".claude/logs/run.lock"

# lock_field <lock-dir> <key>
lock_field() {
  sed -n "s/^$2=//p" "$1/owner" 2>/dev/null | head -n 1
}

# run_lock_reclaim <lock-dir> <nonce-that-was-judged-stale>
# Moves a stale lock aside atomically. Two runners may judge the same lock stale;
# only one rename succeeds. The winner then checks it moved the lock it judged:
# if another runner had already reclaimed it and taken a fresh lock in between,
# the moved lock carries a different nonce, and it is put back untouched.
# Returns 0 when the stale lock is gone, 1 otherwise.
run_lock_reclaim() {
  local lock="$1" judged="$2" aside moved
  aside="$lock.stale.$$"
  mv "$lock" "$aside" 2>/dev/null || return 1
  moved="$(lock_field "$aside" nonce)"
  if [ "$moved" != "$judged" ]; then
    mv "$aside" "$lock" 2>/dev/null || rm -rf "$aside"
    return 1
  fi
  rm -rf "$aside"
  return 0
}

# run_lock_acquire <root> <runner> <log> <longest-run-seconds>
# Returns 0 holding the lock (RUN_LOCK_NONCE set), or 75 after logging why.
run_lock_acquire() {
  local root="$1" runner="$2" log="$3" longest="$4"
  local lock="$root/$RUN_LOCK_REL" waited=0 wait_max="${RUN_LOCK_WAIT:-1800}" poll="${RUN_LOCK_POLL:-30}"
  local now started age pid nonce winpid holder idx_age
  mkdir -p "$(dirname "$lock")" 2>/dev/null
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      RUN_LOCK_NONCE="$runner-$$-$(date +%s)-${RANDOM:-0}"
      winpid=""
      [ -r "/proc/$$/winpid" ] && winpid="$(cat "/proc/$$/winpid" 2>/dev/null)"
      printf 'runner=%s\npid=%s\nwinpid=%s\nstarted=%s\nnonce=%s\n' \
        "$runner" "$$" "$winpid" "$(date +%s)" "$RUN_LOCK_NONCE" > "$lock/owner.tmp" \
        && mv -f "$lock/owner.tmp" "$lock/owner"
      if [ "$(lock_field "$lock" nonce)" = "$RUN_LOCK_NONCE" ]; then
        # git's own index lock: a fresh one is another git command finishing, an
        # old one is a crashed git that will block every commit until removed.
        if [ -e "$root/.git/index.lock" ]; then
          if [ -n "$(find "$root/.git/index.lock" -mmin +10 2>/dev/null)" ]; then
            run_lock_release "$root"
            printf '[%s] LOCKED: %s is more than 10 minutes old. A git command crashed; remove it once no git process is running.\n' \
              "$(ts)" ".git/index.lock" >> "$log"
            return 75
          fi
          run_lock_release "$root"
        else
          return 0
        fi
      fi
    else
      now="$(date +%s)"
      started="$(lock_field "$lock" started)"
      pid="$(lock_field "$lock" pid)"
      nonce="$(lock_field "$lock" nonce)"
      holder="$(lock_field "$lock" runner)"
      if [ -n "$started" ]; then
        age=$((now - started))
      elif [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
        # A lock directory with no owner file: a runner died between mkdir and
        # writing it. Treat it as ancient.
        age=$((longest * 3))
      else
        age=0
      fi
      if ! grep -q '^KILL_FAILED' "$lock/owner" 2>/dev/null && [ "$age" -gt "$longest" ]; then
        if { [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; } || [ "$age" -gt $((longest * 2)) ]; then
          if run_lock_reclaim "$lock" "$nonce"; then
            printf '[%s] reclaimed a stale run lock (runner %s, pid %s, %ss old)\n' \
              "$(ts)" "${holder:-unknown}" "${pid:-unknown}" "$age" >> "$log"
            continue
          fi
        fi
      fi
    fi
    if [ "$waited" -ge "$wait_max" ]; then
      holder="$(lock_field "$lock" runner)"
      idx_age=""
      [ -e "$root/.git/index.lock" ] && idx_age=" (.git/index.lock is also present)"
      printf '[%s] LOCKED: the run lock is held by %s (pid %s) after waiting %ss%s; not starting.\n' \
        "$(ts)" "${holder:-git}" "$(lock_field "$lock" pid)" "$waited" "$idx_age" >> "$log"
      return 75
    fi
    sleep "$poll"
    waited=$((waited + poll))
  done
}

# run_lock_release <root>
# Removes the lock only when this runner holds it, so a runner whose stale lock
# was reclaimed can never delete the new holder's lock on its way out.
run_lock_release() {
  local lock="$1/$RUN_LOCK_REL"
  [ -n "${RUN_LOCK_NONCE:-}" ] || return 0
  if [ "$(lock_field "$lock" nonce)" = "$RUN_LOCK_NONCE" ]; then
    rm -rf "$lock"
  fi
  RUN_LOCK_NONCE=""
}

# safe_git <empty-hooks-dir> <git args...>
# Git as the runner calls it: no hooks, no fsmonitor, no signature checks, no
# prompts. That removes the ways a changed config or hook directory most
# directly runs code in the runner's shell. It is not a sandbox: a .gitattributes
# filter can still run on commands that read the work tree, which is why the
# runners call git on a vault only while its config is known to be the pre-pass
# one.
safe_git() {
  local hooks="$1"
  shift
  GIT_TERMINAL_PROMPT=0 git -c core.hooksPath="$hooks" -c core.fsmonitor=false \
    -c log.showSignature=false "$@"
}

# head_state <root> <empty-hooks-dir>
# Prints "<symbolic ref or DETACHED> <commit or NONE>" for the vault's HEAD.
head_state() {
  local ref commit
  ref="$(safe_git "$2" -C "$1" symbolic-ref -q HEAD 2>/dev/null)" || ref=DETACHED
  # ^{commit}: --verify alone accepts any well-formed id, even one naming no
  # object, so a branch pointed at nothing would look like a rewrite.
  commit="$(safe_git "$2" -C "$1" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || commit=NONE
  printf '%s %s\n' "${ref:-DETACHED}" "${commit:-NONE}"
}

# head_moved_backwards <root> <empty-hooks-dir> <before-state>
# Prints a reason and returns 0 when HEAD changed in a way a pass or a normal
# commit cannot explain: a different branch, or a commit that does not descend
# from the one before the pass. A fast-forward, or no change, returns 1.
head_moved_backwards() {
  local root="$1" hooks="$2" before="$3" after b_ref b_commit a_ref a_commit
  command -v git >/dev/null 2>&1 || return 1
  after="$(head_state "$root" "$hooks")"
  [ "$after" = "$before" ] && return 1
  b_ref="${before%% *}"; b_commit="${before##* }"
  a_ref="${after%% *}";  a_commit="${after##* }"
  if [ "$a_ref" != "$b_ref" ]; then
    printf 'HEAD moved from %s to %s during the pass\n' "$b_ref" "$a_ref"
    return 0
  fi
  [ "$b_commit" = NONE ] && return 1
  if [ "$a_commit" = NONE ]; then
    printf '%s no longer resolves to a commit (was %s)\n' "$b_ref" "$b_commit"
    return 0
  fi
  if ! safe_git "$hooks" -C "$root" merge-base --is-ancestor "$b_commit" "$a_commit" 2>/dev/null; then
    printf '%s was rewritten: %s does not descend from %s\n' "$b_ref" "$a_commit" "$b_commit"
    return 0
  fi
  return 1
}

# contain_pass <root> <state-dir> <runner> <snap-dir> <log> <head-before>
# The whole post-agent sequence, in the only safe order: contain the fenced
# steering surfaces with no git involved, then, if git's own config was not
# changed outside the vault, ask git whether HEAD was rewound. Sets
# CONTAINED=1 when a tripwire was written. Returns 70 when containment was
# needed but no tripwire could be written, else 0.
contain_pass() {
  local root="$1" state="$2" runner="$3" snap="$4" log="$5" head_before="$6" qdir reason moved
  CONTAINED=0
  qdir="$state/quarantine/$(date +%Y%m%dT%H%M%S)-$runner-$$"
  reason="an unattended pass changed a steering or execution surface"
  if ! contain_steering_changes "$root" "$snap/changed" "$snap/steering.tar" "$qdir" "$snap/contained" "$snap/contain-errors"; then
    : > "$snap/contained"
  fi
  # Git runs only when its own config and hooks are known to be the pre-pass
  # ones: nothing changed under .git-common/ (never restored), and every .git/
  # path that changed was restored without error.
  if ! grep -q '^\.git-common' "$snap/contained" 2>/dev/null \
     && ! grep -q '^\.git' "$snap/contain-errors" 2>/dev/null \
     && moved="$(head_moved_backwards "$root" "$snap/nohooks" "$head_before")"; then
    printf '%s\n' "$moved" >> "$snap/contained"
    reason="$reason, or git history was rewritten"
  fi
  [ -s "$snap/contained" ] || return 0

  if ! write_tripwire "$root" "$state" "$runner" "$reason" "$qdir" "$snap/contained" "$snap/contain-errors"; then
    printf '[%s] TRIPWIRE-ERROR: containment ran but no tripwire could be written; treat the vault as unverified:\n' "$(ts)" >> "$log"
    sed 's/^/    /' "$snap/contained" >> "$log"
    return 70
  fi
  CONTAINED=1
  printf '[%s] VIOLATION: steering or execution surfaces changed during the run; contained, quarantine %s, tripwire set:\n' "$(ts)" "$qdir" >> "$log"
  sed 's/^/    /' "$snap/contained" >> "$log"
  if [ -s "$snap/contain-errors" ]; then
    printf '[%s] CONTAINMENT-ERROR:\n' "$(ts)" >> "$log"
    sed 's/^/    /' "$snap/contain-errors" >> "$log"
  fi
  return 0
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
