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

RUNNER_UNAME="$(uname -s 2>/dev/null)"

# is_windows_bash
# True under Git Bash, MSYS or Cygwin, where a native Windows process is stopped
# with taskkill rather than a signal.
is_windows_bash() {
  case "$RUNNER_UNAME" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac
}

# file_size <file>
# The size in bytes, or 0 when the file is missing.
file_size() {
  local n
  n="$(wc -c < "$1" 2>/dev/null | tr -d ' ')"
  printf '%s\n' "${n:-0}"
}

# new_uuid
# A random version 4 UUID. It is the session id Claude Code is started with, and
# the nonce that finds the pass's processes after a kill. Falls back to
# checksums of the time, the pid and $RANDOM when /dev/urandom cannot be read.
new_uuid() {
  local hex i
  hex="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')"
  case "$hex" in *[!0-9a-f]*) hex="" ;; esac
  if [ "${#hex}" -ne 32 ]; then
    hex=""
    for i in 1 2 3 4; do
      hex="$hex$(printf '%08x' "$(printf '%s %s %s %s' "$i" "$(date +%s)" "$$" "${RANDOM:-0}${RANDOM:-0}" | cksum | cut -d' ' -f1)")"
    done
  fi
  printf '%s-%s-4%s-%x%s-%s\n' "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" $(( (0x${hex:16:1} & 3) | 8 )) "${hex:17:3}" "${hex:20:12}"
}

# tree_pids <pid>
# Outside Windows, prints the pid, every descendant of it by parent pid, and
# every process in the process group the pid leads, one per line. The list is
# taken before a kill, because a child whose parent has died is re-parented and
# can no longer be found by its parent pid. Returns 1, having printed only the
# pid, when ps gives no process list.
tree_pids() {
  local list
  list="$(ps -A -o pid= -o ppid= -o pgid= 2>/dev/null)"
  if [ -z "$list" ]; then
    printf '%s\n' "$1"
    return 1
  fi
  printf '%s\n' "$list" | awk -v root="$1" '
    { pid[NR] = $1; ppid[NR] = $2; pgid[NR] = $3 }
    END {
      keep[root] = 1
      print root
      for (i = 1; i <= NR; i++) if (pgid[i] == root && !(pid[i] in keep)) { keep[pid[i]] = 1; print pid[i] }
      grew = 1
      while (grew) {
        grew = 0
        for (i = 1; i <= NR; i++) if ((ppid[i] in keep) && !(pid[i] in keep)) { keep[pid[i]] = 1; print pid[i]; grew = 1 }
      }
    }'
}

# pid_alive <pid>
# True when the pid is running and is not a zombie waiting to be reaped.
pid_alive() {
  kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*) return 1 ;; esac
  return 0
}

# group_of <pid>
# The process group id of the pid, digits only, or nothing.
group_of() {
  ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '
}

# win_msys_tree <pid>
# On Git Bash for Windows, prints "<pid> <winpid>" for the pid and each of its
# descendants in the Git Bash process table. That table keeps a child's parent
# even after the Windows process between them has exited, which happens every
# time Git Bash runs a program, so it finds children the Windows parent ids no
# longer link. Returns 1 when ps gives no process list.
win_msys_tree() {
  local list
  list="$(ps -l 2>/dev/null)"
  [ -n "$list" ] || return 1
  printf '%s\n' "$list" | awk -v root="$1" '
    NR > 1 { sub(/^[^0-9]*/, ""); n++; pid[n] = $1; ppid[n] = $2; win[n] = $4 }
    END {
      keep[root] = 1
      for (i = 1; i <= n; i++) if (pid[i] == root) print pid[i], win[i]
      grew = 1
      while (grew) {
        grew = 0
        for (i = 1; i <= n; i++) if ((ppid[i] in keep) && !(pid[i] in keep)) { keep[pid[i]] = 1; print pid[i], win[i]; grew = 1 }
      }
    }'
}

# win_tree_stop <winpid> <nonce> <record-file> [<more winpids> [<listed-epoch>]]
# On Windows, stops the native process tree under <winpid>, every process in the
# space-separated <more winpids>, and every process whose command line carries
# <nonce>, which finds one whose parent in the tree had already exited. Appends
# to <record-file> each process still running afterwards, as
# "alive <id> <name>", "none" when there is none, and "unknown (...)" when
# PowerShell does not finish within WINDOWS_STOP_LIMIT seconds (default 60).
#
# PowerShell takes one process list and works from it. <winpid> and <more
# winpids> count only for a process that started no later than <listed-epoch>,
# the time the caller listed them, and a child only when it started no earlier
# than its parent, because Windows reuses process ids. taskkill runs on the root
# only after that check, and each process is stopped, or reported alive, only
# while its id still belongs to the process in that list. The ids, the nonce and
# the time reach PowerShell in the environment, never on its command line, and
# PowerShell leaves its own process out. Otherwise the sweep would find
# PowerShell itself by the nonce and stop it before it could report.
win_tree_stop() {
  local winpid="$1" nonce="$2" record="$3" more="${4:-}" listed="${5:-}" script limit out ps_pid ps_win waited=0
  is_uint "$winpid" || winpid=0
  is_uint "$listed" || listed=0
  case "$nonce" in *[!A-Za-z0-9-]*) nonce="" ;; esac
  case "$more" in *[!0-9\ ]*) more="" ;; esac
  limit="${WINDOWS_STOP_LIMIT:-60}"
  is_uint "$limit" && [ "$limit" -gt 0 ] || limit=60
  script="\$ProgressPreference = 'SilentlyContinue'
\$root = 0; [void][int]::TryParse([string]\$env:VAULT_STOP_ROOT, [ref]\$root)
\$nonce = [string]\$env:VAULT_STOP_NONCE
\$listed = [DateTime]::MaxValue
\$t = [long]0
if ([long]::TryParse([string]\$env:VAULT_STOP_LISTED, [ref]\$t) -and \$t -gt 0) { \$listed = [DateTimeOffset]::FromUnixTimeSeconds(\$t + 1).LocalDateTime }
\$all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
\$byId = @{}
foreach (\$p in \$all) { \$byId[[int]\$p.ProcessId] = \$p }
\$pick = @{}
if (\$root -gt 0 -and \$byId.ContainsKey(\$root) -and \$byId[\$root].CreationDate -le \$listed) { \$pick[\$root] = \$true }
foreach (\$x in ([string]\$env:VAULT_STOP_IDS).Split(' ')) { \$i = 0; if ([int]::TryParse(\$x, [ref]\$i) -and \$byId.ContainsKey(\$i) -and \$byId[\$i].CreationDate -le \$listed) { \$pick[\$i] = \$true } }
\$grew = \$true
while (\$grew) {
  \$grew = \$false
  foreach (\$p in \$all) {
    \$id = [int]\$p.ProcessId; \$pp = [int]\$p.ParentProcessId
    if (\$pick.ContainsKey(\$pp) -and -not \$pick.ContainsKey(\$id) -and \$byId[\$pp].CreationDate -le \$p.CreationDate) { \$pick[\$id] = \$true; \$grew = \$true }
  }
}
if (\$nonce) { foreach (\$p in \$all) { if (\$p.CommandLine -and \$p.CommandLine.Contains(\$nonce)) { \$pick[[int]\$p.ProcessId] = \$true } } }
\$pick.Remove([int]\$PID)
function Same(\$id) { \$c = Get-CimInstance Win32_Process -Filter ('ProcessId=' + \$id) -ErrorAction SilentlyContinue; if (\$c -and \$c.CreationDate -eq \$byId[\$id].CreationDate) { \$c } }
if (\$pick.ContainsKey(\$root) -and (Same \$root)) { & taskkill.exe /T /F /PID \$root 2>&1 | Out-Null }
foreach (\$id in @(\$pick.Keys)) { if (Same \$id) { Stop-Process -Id \$id -Force -ErrorAction SilentlyContinue } }
Start-Sleep -Seconds 2
\$left = @()
foreach (\$id in @(\$pick.Keys)) { \$c = Same \$id; if (\$c) { \$left += ('alive ' + \$id + ' ' + \$c.Name) } }
if (\$nonce) { foreach (\$p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) { if (\$p.CommandLine -and \$p.CommandLine.Contains(\$nonce) -and [int]\$p.ProcessId -ne \$PID -and -not \$pick.ContainsKey([int]\$p.ProcessId)) { \$left += ('alive ' + \$p.ProcessId + ' ' + \$p.Name) } } }
if (\$left.Count -eq 0) { 'none' } else { \$left }"
  out="$(mktemp 2>/dev/null || mktemp -t winstop)" || out="$record.powershell"
  VAULT_STOP_ROOT="$winpid" VAULT_STOP_NONCE="$nonce" VAULT_STOP_IDS="$more" VAULT_STOP_LISTED="$listed" \
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    powershell.exe -NoProfile -NonInteractive -Command "$script" > "$out" 2>/dev/null &
  ps_pid=$!
  while kill -0 "$ps_pid" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$ps_pid" 2>/dev/null; then
    # A PowerShell that hangs, as one whose process query waits on a wedged
    # WMI service does, is stopped with its children.
    ps_win="$(cat "/proc/$ps_pid/winpid" 2>/dev/null)"
    is_uint "$ps_win" && [ "$ps_win" -gt 0 ] && MSYS_NO_PATHCONV=1 taskkill /T /F /PID "$ps_win" >/dev/null 2>&1
    kill -KILL "$ps_pid" 2>/dev/null
    wait "$ps_pid" 2>/dev/null
    printf 'unknown (PowerShell did not finish within %ss)\n' "$limit" >> "$record"
  else
    wait "$ps_pid" 2>/dev/null
    tr -d '\r' < "$out" | awk '/^(none|alive [0-9]+ .*)$/' >> "$record"
  fi
  rm -f "$out"
}

# stop_tree <pid> <grace-seconds> <record-file> <nonce> <own-group: 0|1>
# Stops the command started by run_with_watchdog and everything it started, and
# records what is still running afterwards in <record-file>, "alive <pid>" per
# process, "unknown (...)" when the processes could not be listed or checked, or
# "none". <own-group> is 1 when the command was started in a process group of
# its own.
#
# Outside Windows the process group is signalled only when the command really
# leads its own group and that group is not the runner's, so a kill never reaches
# the runner itself. Each process of the tree recorded before the kill is
# signalled as well, in every case. TERM comes first, then KILL after the grace
# period. On Windows a native process ignores those signals, so the tree is
# stopped with taskkill and the sweep in win_tree_stop.
stop_tree() {
  local pid="$1" grace="$2" record="$3" nonce="$4" own="$5" members winpid g p group=0 left listed
  : > "$record"
  if is_windows_bash; then
    # The tree is listed and stopped before any signal, while the command's own
    # process still links it to its children. A TERM first would let a Git Bash
    # wrapper exit and leave a child with no parent to be found by, and no
    # nonce on its command line.
    listed="$(date +%s)"
    if ! members="$(win_msys_tree "$pid")"; then
      printf 'unknown (ps gave no process list, so the Git Bash processes of the tree are not known)\n' >> "$record"
    fi
    winpid="$(cat "/proc/$pid/winpid" 2>/dev/null)"
    win_tree_stop "$winpid" "$nonce" "$record" "$(printf '%s\n' "$members" | awk '$2 ~ /^[0-9]+$/ { printf "%s ", $2 }')" "$listed"
    grep -qE '^(none|alive|unknown \(PowerShell)' "$record" || printf 'unknown (PowerShell gave no answer)\n' >> "$record"
    for p in $(printf '%s\n' "$members" | awk '{ print $1 }'); do kill -KILL "$p" 2>/dev/null; done
    kill -KILL "$pid" 2>/dev/null
    sleep 1
    for p in $(printf '%s\n' "$members" | awk '{ print $1 }'); do
      [ "$p" = "$pid" ] && continue
      kill -0 "$p" 2>/dev/null && printf 'alive %s\n' "$p" >> "$record"
    done
    return 0
  fi
  if ! members="$(tree_pids "$pid")"; then
    printf 'unknown (ps gave no process list, so only the command itself could be stopped)\n' >> "$record"
  fi
  if [ "$own" = 1 ] && [ "$(group_of "$pid")" = "$pid" ] && [ "$(group_of "$pid")" != "$(group_of "$$")" ]; then
    group=1
  fi
  if [ "$group" -eq 1 ]; then kill -TERM -- "-$pid" 2>/dev/null; fi
  for p in $members; do kill -TERM "$p" 2>/dev/null; done
  g=0
  while [ "$g" -lt "$grace" ]; do
    left=""
    for p in $members; do pid_alive "$p" && left=1; done
    [ -z "$left" ] && break
    sleep 1
    g=$((g + 1))
  done
  if [ "$group" -eq 1 ]; then kill -KILL -- "-$pid" 2>/dev/null; fi
  for p in $members; do kill -KILL "$p" 2>/dev/null; done
  sleep 1
  for p in $members; do
    [ "$p" = "$pid" ] && continue
    pid_alive "$p" && printf 'alive %s\n' "$p" >> "$record"
  done
  [ -s "$record" ] || printf 'none\n' >> "$record"
  return 0
}

# run_with_watchdog <timeout-seconds> <output-file> <command> [args...]
#
# Runs the command with stdin at /dev/null (it must never wait for input), its
# output appended to <output-file>, and a watchdog that stops it when the
# timeout elapses, or when RUN_STALL_SECONDS is above 0 and the output has not
# grown for that many seconds. Outside Windows the command starts in a process
# group of its own, and a stop reaches everything it started (stop_tree). Sets
# these globals:
#   RUN_PID          the command's pid, so a signal handler can stop it
#   RUN_RC           the command's exit status (143/137 when the watchdog fired)
#   RUN_TIMED_OUT    1 if the timeout fired, else 0
#   RUN_STALLED      1 if the output stopped growing for RUN_STALL_SECONDS, else 0
#   RUN_KILL_FAILED  1 if a process of the stopped command was still running
#                    afterwards, or its output kept growing, else 0
#   RUN_KILL_REPORT  what stop_tree recorded, one process per line
#
# Optional inputs, set for one call as VAR=value run_with_watchdog ...:
#   RUN_STALL_SECONDS  seconds without output growth before a stop (0 = never)
#   RUN_GAPS_FILE      where each silent stretch the watchdog saw is appended,
#                      in seconds, for stall_threshold to learn from
#   RUN_NONCE          a string in the command's arguments, which the Windows
#                      stop uses to find processes that left the tree
#
# The watchdog polls rather than sleeping for the full timeout, so it exits on
# its own within one poll interval of the command finishing and never outlives
# the run by more than that. It measures time and silence in poll intervals.
# WATCHDOG_POLL and WATCHDOG_GRACE are overridable so the test suite can exercise
# the stop paths in seconds instead of hours.
run_with_watchdog() {
  local timeout="$1" out="$2"
  shift 2
  local poll="${WATCHDOG_POLL:-5}" grace="${WATCHDOG_GRACE:-15}" stall="${RUN_STALL_SECONDS:-0}"
  local gaps="${RUN_GAPS_FILE:-}" nonce="${RUN_NONCE:-}" flag own=0 before_size after_size
  is_uint "$stall" || stall=0
  flag="$(mktemp 2>/dev/null || mktemp -t runner)" || flag="${out}.watchdog"
  rm -f "$flag" "$flag.stalled" "$flag.stopped"

  # A process group of its own, so a stop reaches a child that has left the
  # tree. Job control is switched on only around the launch.
  if ! is_windows_bash; then
    set -m
    own=1
  fi
  "$@" </dev/null >>"$out" 2>&1 &
  local pid=$!
  [ "$own" -eq 1 ] && set +m
  RUN_PID=$pid

  (
    waited=0
    silent=0
    size="$(file_size "$out")"
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$waited" -ge "$timeout" ] || { [ "$stall" -gt 0 ] && [ "$silent" -ge "$stall" ]; }; then
        if [ "$waited" -ge "$timeout" ]; then : >"$flag"; else : >"$flag.stalled"; fi
        stop_tree "$pid" "$grace" "$flag.stopped" "$nonce" "$own"
        exit 0
      fi
      sleep "$poll"
      waited=$((waited + poll))
      now="$(file_size "$out")"
      if [ "$now" != "$size" ]; then
        [ -n "$gaps" ] && printf '%s\n' "$((silent + poll))" >> "$gaps"
        size="$now"
        silent=0
      else
        silent=$((silent + poll))
      fi
    done
  ) &
  local watchdog=$!

  # bash reports a job killed by a signal on stderr, which launchd writes into
  # .claude/logs. RUN_RC carries the status.
  wait "$pid" 2>/dev/null
  RUN_RC=$?
  # The pid is reaped and may be handed to another process, so a signal handler
  # must not stop it any more.
  RUN_PID=""
  # A watchdog that has not begun a stop is only sleeping, so it is ended at
  # once. One that has is left to finish, and a stop cut short when the two met
  # is finished here.
  if [ ! -f "$flag" ] && [ ! -f "$flag.stalled" ]; then
    kill "$watchdog" 2>/dev/null
  fi
  wait "$watchdog" 2>/dev/null
  if { [ -f "$flag" ] || [ -f "$flag.stalled" ]; } && [ ! -s "$flag.stopped" ]; then
    stop_tree "$pid" "$grace" "$flag.stopped" "$nonce" "$own"
  fi

  RUN_TIMED_OUT=0
  RUN_STALLED=0
  RUN_KILL_FAILED=0
  RUN_KILL_REPORT=""
  [ -f "$flag" ] && RUN_TIMED_OUT=1
  [ -f "$flag.stalled" ] && RUN_STALLED=1
  if [ -f "$flag.stopped" ]; then
    RUN_KILL_REPORT="$(cat "$flag.stopped" 2>/dev/null)"
    # A stopped command whose output still grows has a writer left somewhere.
    before_size="$(file_size "$out")"
    sleep 2
    after_size="$(file_size "$out")"
    if [ "$before_size" != "$after_size" ]; then
      RUN_KILL_REPORT="$(printf '%s\noutput still growing after the stop\n' "$RUN_KILL_REPORT")"
    fi
    case "$RUN_KILL_REPORT" in *alive*|*unknown*|*growing*) RUN_KILL_FAILED=1 ;; esac
  fi
  rm -f "$flag" "$flag.stalled" "$flag.stopped"
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
#
# A path with a line break in it is left out. It would print as two lines, and
# the second could name any path, such as .git, which containment would then
# move out of the vault. snapshot_tree sums such paths into one line of their own.
# find matches names in the C locale, byte by byte, because in some UTF-8 locales
# a * does not match a byte that is not valid UTF-8, and such a name would slip
# past the test.
RUNNER_NL='
'
LINE_BREAK_MARKER=".runner-line-break-names"
fence_find() {
  LC_ALL=C find "$@" ! -path "*$RUNNER_NL*" -type f -exec cksum {} + 2>/dev/null
  LC_ALL=C find "$@" ! -path "*$RUNNER_NL*" -type l -print 2>/dev/null | while IFS= read -r link; do
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
# Not fenced: the files the runners and hooks write in .claude/logs/, and in .obsidian/
# everything except what carries or enables code: community-plugins.json and
# the plugins/, themes/ and snippets/ folders. Obsidian rewrites its workspace,
# graph and app settings while open, and none of them runs anything.
# .obsidian/ is not a path Claude Code protects, so the code-bearing part must
# be inside the fence.
#
# A plugin's data.json holds its settings, and many plugins rewrite it during
# normal use, so it is fenced only for the plugins in CODE_PLUGINS, which run
# code or commands named in their settings. A plugin counts as one of them when
# its folder name or the id in its manifest.json is in the list, ignoring case,
# because Obsidian takes the id from the manifest and a plugin can be installed
# under any folder name. Everything else in a plugin folder (main.js,
# manifest.json, styles.css, and any folder, even one named data.json) is fenced
# for every plugin, so a pass that edits a manifest's id is caught by that edit.
#
# Agent memory (.claude/agent-memory*) and 90-auto-memory/ are fenced in every
# mode. Memory loads into later sessions, so an unseen write there would be a
# planted instruction. run_agent turns Claude Code's own auto memory off for the
# pass, which is what makes fencing it in claude mode possible.
#
# In .git/ only the files that make git run code are fenced. They are config,
# config.worktree, commondir (git reads config and hooks from the directory it
# names), hooks/, info/attributes, info/grafts and objects/info/alternates, and
# info/, objects/ and objects/info/ as links when they are symlinks. The same
# files, and every symlink, are fenced in every linked worktree's git directory
# under .git/worktrees/ and every submodule's under .git/modules/, except inside
# the ref folders heads, tags, remotes, prefetch, notes and rewritten. The rest
# of info/ is not, because `git gc --auto` after an ordinary commit rewrites
# info/refs. HEAD and refs are NOT fenced, because a human or a sync plugin may
# commit while a pass runs. A rewound HEAD is caught separately
# (head_moved_backwards). For a worktree vault,
# whose .git is a file, the pointer is fenced and the same files in the common
# git directory appear under the label .git-common/.
#
# A .obsidian or .git that is itself a symlink is fenced as a link, and the files
# above are still fenced through it, so swapping or retargeting it is a change.
#
# Known limit: any other directory symlink that existed before the pass is fenced
# as a link, not by its target's contents, so a write through it is not seen.
CODE_PLUGINS="dataview templater-obsidian obsidian-shellcommands quickadd customjs obsidian-git execute-code terminal"

# code_plugin_dirs
# Run from the vault root. Prints each folder under .obsidian/plugins/ whose
# name, or the id in whose manifest.json, is in CODE_PLUGINS, ignoring ASCII
# case. Two awk processes do the work for every plugin at once, because a
# process per plugin is slow on Git Bash.
code_plugin_dirs() {
  local d
  local -a dirs manifests
  dirs=()
  manifests=()
  for d in .obsidian/plugins/*/ .obsidian/plugins/.[!.]*/; do
    [ -d "$d" ] || continue
    dirs+=("${d%/}")
    # Only readable manifests, because some awk versions stop at one they cannot open.
    [ -f "${d}manifest.json" ] && [ -r "${d}manifest.json" ] && manifests+=("${d}manifest.json")
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  {
    printf 'D\t%s\n' "${dirs[@]}"
    # The first "id" key in each manifest.
    [ "${#manifests[@]}" -gt 0 ] && LC_ALL=C awk '
      FNR == 1 { got = 0 }
      !got && match($0, /"id"[ \t\r]*:[ \t\r]*"[^"]*"/) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^"id"[ \t\r]*:[ \t\r]*"/, "", s)
        sub(/"$/, "", s)
        f = FILENAME
        sub(/\/manifest\.json$/, "", f)
        print "I\t" f "\t" s
        got = 1
      }' "${manifests[@]}" 2>/dev/null
  } | LC_ALL=C awk -F '\t' -v list="$CODE_PLUGINS" '
    BEGIN { n = split(tolower(list), w, " "); for (i = 1; i <= n; i++) code[w[i]] = 1 }
    $1 == "D" { key = $2; sub(/.*\//, "", key); key = tolower(key) }
    $1 == "I" { key = tolower($3) }
    ($1 == "D" || $1 == "I") && (key in code) && !seen[$2]++ { print $2 }'
}

snapshot_tree() {
  local root="$1" out="$2" dirs gd cdir
  (
    cd "$root" || exit 1
    fence_find . \( -path ./.git -o -path ./.claude/logs -o -path ./.obsidian \) -prune -o
    # .claude/logs holds what the runners, the hooks and the launchd jobs in
    # setup.md write while a pass runs, so only those file names are left out of
    # the fence. Any other file there, such as a planted CLAUDE.md, and any
    # symlink, is fenced.
    if [ -L .claude/logs ]; then
      fence_find ./.claude/logs
    elif [ -d .claude/logs ]; then
      fence_find ./.claude/logs \( -type f \( -name '*.log' -o -name dream-pass.git-state.txt -o -name promotion-pass.git-state.txt \
        -o -name dream-pass.prompt.md -o -name promotion-pass.prompt.md -o -name runner-tripwire -o -name runner-inflight \
        -o -name 'runner-tripwire.tmp.*' -o -name 'runner-inflight.tmp.*' \
        -o -name dream-pass.launchd.out -o -name dream-pass.launchd.err \
        -o -name promotion-pass.launchd.out -o -name promotion-pass.launchd.err \) \) -prune -o
    fi
    # Every path with a line break, .claude/logs included, summed by name and
    # content into one line under a name no file has. A change to any of them
    # changes the line, and containment moves them out (move_line_break_names).
    lb="$( { LC_ALL=C find . -path "*$RUNNER_NL*" -print; \
             LC_ALL=C find . -path "*$RUNNER_NL*" -type f -exec cksum {} +; } 2>/dev/null )"
    [ -n "$lb" ] && printf 'N%s 0 ./%s\n' "$(printf '%s' "$lb" | cksum | cut -d' ' -f1)" "$LINE_BREAK_MARKER"
    # The scan above prunes .obsidian by name, so a .obsidian that is a symlink
    # gets its own line here. The files below are still read through it.
    [ -L .obsidian ] && fence_find ./.obsidian
    [ -e .obsidian/community-plugins.json ] && fence_find ./.obsidian/community-plugins.json
    if [ -e .obsidian/plugins ] || [ -L .obsidian/plugins ]; then
      # A plugin's settings file, a FILE named data.json directly in its folder,
      # is pruned from the fence unless the folder is a code plugin's. In find's
      # -path a * also matches /, so the two depth tests pin the file to exactly
      # plugins/<folder>/data.json. Glob characters in a folder name are escaped.
      keep=()
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        keep+=(! -path "./$(printf '%s' "$p" | sed 's/[][\\*?]/\\&/g')/data.json")
      done <<EOF
$(code_plugin_dirs)
EOF
      # The ${keep[@]+...} form, because bash 3.2 treats an empty array as unset
      # under set -u.
      fence_find ./.obsidian/plugins \( -type f -name data.json -path './.obsidian/plugins/*/*' \
        ! -path './.obsidian/plugins/*/*/*' ${keep[@]+"${keep[@]}"} \) -prune -o
    fi
    # The files in a git directory that make git run code, or read config and
    # hooks from somewhere else, and every symlink, because a linked hooks or
    # info folder moves those files where the fence does not look. A ref may be
    # named config or hooks/x, and refs change whenever someone commits or git
    # maintenance prefetches, so the ref folders heads, tags, remotes, prefetch,
    # notes and rewritten under refs/ (and their reflogs under logs/refs) are left
    # out. Only those, because a submodule or worktree may itself be named refs.
    # Callers pass relative paths, so a folder named refs above the git directory
    # changes nothing. Known limit: a submodule whose own path contains one of
    # those pairs, such as vendor/refs/tags/lib, is left out too, because find
    # cannot tell where a submodule's name ends.
    gitdir_code=( \( -type l -o -name config -o -name config.worktree -o -name commondir \
      -o -path '*/info/attributes' -o -path '*/info/grafts' -o -path '*/objects/info/alternates' \
      -o -path '*/hooks/*' \) ! -path '*/refs/heads/*' ! -path '*/refs/tags/*' ! -path '*/refs/remotes/*' \
      ! -path '*/refs/prefetch/*' ! -path '*/refs/notes/*' ! -path '*/refs/rewritten/*' )
    for d in .obsidian/themes .obsidian/snippets; do
      { [ -e "$d" ] || [ -L "$d" ]; } && fence_find "./$d"
    done
    if [ -d .git ]; then
      [ -L .git ] && fence_find ./.git
      for f in .git/config .git/config.worktree .git/commondir .git/objects/info/alternates .git/info/attributes .git/info/grafts; do
        { [ -e "$f" ] || [ -L "$f" ]; } && fence_find "./$f"
      done
      { [ -e .git/hooks ] || [ -L .git/hooks ]; } && fence_find ./.git/hooks
      # A folder that holds a fenced file, replaced by a link, is fenced as the link.
      for d in .git/info .git/objects .git/objects/info; do
        [ -L "$d" ] && fence_find "./$d"
      done
      for d in .git/worktrees .git/modules; do
        [ -d "$d" ] && fence_find "./$d" "${gitdir_code[@]}"
      done
    elif [ -e .git ] || [ -L .git ]; then
      fence_find ./.git
      if dirs="$(git_dirs_of "$root")"; then
        gd="$(printf '%s\n' "$dirs" | sed -n 1p)"
        cdir="$(printf '%s\n' "$dirs" | sed -n 2p)"
        [ -e "$gd/config.worktree" ] && fence_find "$gd/config.worktree" | relabel "$gd" ./.git-common/worktree
        [ -e "$gd/commondir" ] && fence_find "$gd/commondir" | relabel "$gd" ./.git-common/worktree
        for f in config objects/info/alternates info/attributes info/grafts; do
          [ -e "$cdir/$f" ] && fence_find "$cdir/$f" | relabel "$cdir" ./.git-common
        done
        [ -e "$cdir/hooks" ] && fence_find "$cdir/hooks" | relabel "$cdir" ./.git-common
        for d in info objects objects/info; do
          [ -L "$cdir/$d" ] && fence_find "$cdir/$d" | relabel "$cdir" ./.git-common
        done
        for d in worktrees modules; do
          [ -d "$cdir/$d" ] && ( cd "$cdir" && fence_find "./$d" "${gitdir_code[@]}" ) | relabel ./ ./.git-common/
        done
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
# Changes to ordinary notes are not contained. A human may be editing one at the
# same moment, and git already shows the diff, so the fence reports them as
# before. A plugin that runs code from notes or script folders (DataviewJS,
# Templater, QuickAdd, CustomJS) is a documented limit of this choice.

TRIPWIRE_REL=".claude/logs/runner-tripwire"
INFLIGHT_REL=".claude/logs/runner-inflight"

# steering_filter [snapshot...]
# Reads relative paths on stdin and prints the ones that are steering or
# execution surfaces. One awk program, so the fence, the backup and containment
# can never disagree about the set, and matching is case-insensitive (a
# case-insensitive filesystem loads Gemini.md as GEMINI.md). Inside
# .claude/worktrees/<name>/ the same rules apply to the rest of the path, so a
# worktree's own CLAUDE.md or .claude/ counts and its notes do not. The symlink
# entries of the snapshots named as arguments mark which paths are links, because
# a link inside a nested git directory can move its hooks or config elsewhere.
steering_filter() {
  # Every test is a plain anchored pattern: the BWK awk that macOS ships does not
  # reliably treat $ or ^ as anchors inside an alternation group.
  awk '
    function steer(lp, islink) {
      if (lp == ".runner-line-break-names") return 1
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
      # A .git entry below the vault root is a submodule gitlink or an embedded
      # repository, and rewriting it points git at another config and hooks.
      # Inside a nested git directory only the files that run code or redirect
      # git count, and any symlink. Its index, objects, refs and logs change in
      # normal use. A ref may have any name, config included, so the ref folders
      # heads, tags, remotes, prefetch, notes and rewritten are left out, as the
      # fence leaves them out of .git/modules and .git/worktrees.
      if (base == ".git") return 1
      for (i = 1; i < n; i++) {
        if (part[i] != ".git") continue
        for (j = i + 1; j < n - 1; j++) {
          if (part[j] != "refs") continue
          ns = part[j + 1]
          if (ns == "heads" || ns == "tags" || ns == "remotes" || ns == "prefetch" || ns == "notes" || ns == "rewritten") return 0
        }
        if (islink) return 1
        if (base == "config" || base == "config.worktree" || base == "commondir") return 1
        for (j = i + 1; j < n; j++) if (part[j] == "hooks") return 1
        if (part[n - 1] == "info" && (base == "attributes" || base == "grafts")) return 1
        if (n >= 3 && part[n - 2] == "objects" && part[n - 1] == "info" && base == "alternates") return 1
        break
      }
      # Every component, the last included: a symlink named .claude is a harness
      # folder too, wherever it points.
      for (i = 1; i <= n; i++) {
        if (part[i] == ".claude" || part[i] == ".agents" || part[i] == ".codex" || part[i] == ".gemini" || part[i] == ".cursor" || part[i] == ".windsurf" || part[i] == ".opencode" || part[i] == ".github" || part[i] == ".vscode") return 1
      }
      return 0
    }
    # A snapshot line is "checksum size ./path", and a symlink checksum starts with L.
    phase == 1 {
      if ($0 ~ /^L/) {
        p = $0
        sub(/^[^ ]* [^ ]* /, "", p)
        sub(/^\.\//, "", p)
        link[tolower(p)] = 1
      }
      next
    }
    {
      lp = tolower($0)
      islink = (lp in link)
      # In the vault .claude/logs only files the runners, hooks and launchd jobs
      # do not write are fenced, so any change there is a planted file. The
      # names left out are the ones snapshot_tree leaves out. The logs of a
      # worktree belong to its session, and stay out.
      if (lp ~ /^\.claude\/logs\//) {
        n = split(lp, part, "/")
        base = part[n]
        if (base ~ /\.log$/ || base == "dream-pass.git-state.txt" || base == "promotion-pass.git-state.txt" \
            || base == "dream-pass.prompt.md" || base == "promotion-pass.prompt.md" \
            || base == "runner-tripwire" || base == "runner-inflight" \
            || base ~ /^runner-tripwire\.tmp\./ || base ~ /^runner-inflight\.tmp\./ \
            || base == "dream-pass.launchd.out" || base == "dream-pass.launchd.err" \
            || base == "promotion-pass.launchd.out" || base == "promotion-pass.launchd.err") next
        print $0
        next
      }
      if (lp ~ /^\.claude\/worktrees\/[^\/]+\//) {
        sub(/^\.claude\/worktrees\/[^\/]+\//, "", lp)
      } else if (lp == ".claude/worktrees" || lp ~ /^\.claude\/worktrees\/[^\/]*$/) {
        next
      }
      if (steer(lp, islink)) print $0
    }' phase=1 "$@" phase=2 -
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
# Archives every steering file the before-snapshot lists, and every symlink it
# lists, because containment treats any link the pass changes as steering and
# puts the old one back. A link with other listed paths below it, such as a
# .obsidian that is a symlink, is left out: those paths are read through it, and
# extracting the link first would carry them through it. Writes <tarball>.list.
# Returns non-zero, after which the runner must refuse to start, when tar is
# missing or the archive does not hold every listed member. GNU tar exits 1 when
# a file changed while it was read, which is not a failure if the member is
# there, so the archive's own listing is the evidence, not the status.
backup_steering() {
  local root="$1" snap="$2" tarball="$3" want have
  command -v tar >/dev/null 2>&1 || return 1
  {
    snapshot_paths "$snap" | steering_filter "$snap"
    awk '/^L/ { sub(/^[^ ]* [^ ]* /, ""); sub(/^\.\//, ""); print }' "$snap"
  } | grep -v '^\.git-common' | grep -vxF "$LINE_BREAK_MARKER" | LC_ALL=C sort -u | awk '
    # Sorted, so the paths below a path follow it, with only names that start
    # with the same text in between. A path with any path below it is dropped.
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        below = 0
        for (j = i + 1; j <= NR; j++) {
          if (index(lines[j], lines[i] "/") == 1) { below = 1; break }
          if (substr(lines[j], 1, length(lines[i])) != lines[i]) break
        }
        if (!below) print lines[i]
      }
    }' > "$tarball.list"
  if [ ! -s "$tarball.list" ]; then
    : > "$tarball"
    return 0
  fi
  ( cd "$root" && tar -cf "$tarball" -T "$tarball.list" ) 2>/dev/null
  want="$(awk 'END{print NR+0}' "$tarball.list")"
  have="$(tar -tf "$tarball" 2>/dev/null | awk 'END{print NR+0}')"
  [ "$have" -ge "$want" ] && [ "$want" -gt 0 ]
}

# path_key <path>
# The form in which two paths are compared. Repeated slashes are squeezed. On
# Windows the path is first converted to its long Windows form, because Git Bash
# can spell one folder as /tmp/x, /c/Users/.../Temp/x or with 8.3 short names.
# On Windows and macOS, whose file systems ignore case by default, ASCII letters
# are lowercased, in the C locale so that a scheduler's locale and a terminal's
# give the same result.
path_key() {
  case "$RUNNER_UNAME" in
    MINGW*|MSYS*|CYGWIN*)
      { cygpath -m -l "$1" 2>/dev/null || printf '%s' "$1"; } | tr -s '/' | LC_ALL=C tr 'A-Z' 'a-z' ;;
    Darwin*) printf '%s' "$1" | tr -s '/' | LC_ALL=C tr 'A-Z' 'a-z' ;;
    *) printf '%s' "$1" | tr -s '/' ;;
  esac
}

# resolved_path <absolute-path>
# The path with symlinks resolved through its nearest existing ancestor, so a
# directory that does not exist yet is judged by where it would be created.
resolved_path() {
  local p="$1" rest=""
  while [ ! -d "$p" ]; do
    case "$p" in /|"") break ;; esac
    rest="/${p##*/}$rest"
    p="${p%/*}"
    [ -n "$p" ] || p="/"
  done
  printf '%s%s\n' "$(cd "$p" 2>/dev/null && pwd -P)" "$rest"
}

# vault_state_dir <root>
# Per-vault state directory OUTSIDE the vault, so nothing kept there is indexed by
# Obsidian, synced with the vault folder, or reachable by an agent's file tools
# in the vault. VAULT_STATE_DIR overrides it (the test suite uses that). Only an
# absolute path that is not inside the vault is accepted. A Windows path such as
# "C:/Users/Some One/vault-state" is converted first. A rejected value is replaced
# with a directory under the system temp folder, and a warning saying so goes to
# stderr, which the runners append to their log. Set VAULT_STATE_DIR the same way
# for both runners and for any shell that runs vault-check.sh, or they look in
# different places.
#
# The default <id> is a checksum of the vault's resolved path, compared as
# path_key does, so a symlinked, relative, short-name or differently cased
# spelling of the same vault gets the same state directory in every runner and
# in vault-check.sh. A subst or mapped drive letter, and on macOS a differently
# normalized Unicode name, still count as another path.
vault_state_dir() {
  local root="$1" base id dir croot kroot
  croot="$(cd "$root" 2>/dev/null && pwd -P)"
  kroot="$(path_key "${croot:-$root}")"
  id="$(printf '%s' "$kroot" | cksum | cut -d' ' -f1)"
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
  case "$dir" in
    ""|/.local/state/*|*/../*|*/..|"$root"|"$root"/*) dir="" ;;
    /*) case "$(path_key "$(resolved_path "$dir")")" in "$kroot"|"$kroot"/*) dir="" ;; esac ;;
    *) dir="" ;;
  esac
  if [ -z "$dir" ]; then
    dir="${TMPDIR:-/tmp}/claude-memory-vault-state-$id"
    [ -n "${VAULT_STATE_DIR:-}" ] && printf '[%s] WARNING: VAULT_STATE_DIR "%s" is not an absolute path outside the vault. Using %s instead.\n' \
      "$(ts)" "$VAULT_STATE_DIR" "$dir" >&2
  fi
  printf '%s\n' "$dir"
}

# state_dir_ready <dir> <root>
# Creates the state directory, private to this account where the platform
# allows, and prints the path it resolves to. Fails unless it is a directory
# this account owns and can write, that is not world-writable, and that does not
# resolve into the vault. Another account could otherwise plant a forged tripwire
# or marker there, and a symlink planted at the temp-folder fallback could put
# the state back inside the agent's reach. A group-writable directory is
# allowed, because many Linux systems give each user a private group. Git Bash
# reports every file as owned by the current user and its mode bits are not
# ACLs, so on Windows only the check against the vault means anything.
#
# A symlink named as the state directory in a folder every account can write,
# such as the shared temp folder, is refused before anything else, because
# another account may have planted it. Then the path is resolved, every other
# check runs on the resolved path, and the runners use the printed path from then
# on, so pointing a symlink elsewhere after the check changes nothing. A folder
# above the resolved directory that every account can write and that has no
# sticky bit is refused too, because another account could rename the directory
# and put its own in its place. A folder above it that another account owns is
# not checked, so do not put the state directory under one.
#
# Returns 0 when ready, 1 when it could not be created or entered, 2 when this
# account does not own it or cannot write it, 3 when it is world-writable, 4 when
# it resolves into the vault, 5 when it is a symlink in a world-writable folder,
# 6 when find could not check the mode, and 7 when a folder above it is
# world-writable with no sticky bit. state_dir_problem turns the code into words.
state_dir_ready() {
  local name parent real kroot open up
  name="$(printf '%s' "$1" | sed 's|//*$||')"
  parent="${name%/*}"
  [ -n "$parent" ] || parent=/
  if [ -L "$name" ]; then
    # -H, because the folder itself may be a link, as /tmp is on macOS.
    open="$(find -H "$parent" -maxdepth 0 -perm -0002 -print 2>/dev/null)" || return 6
    [ -z "$open" ] || return 5
  fi
  if [ ! -d "$1" ]; then
    ( umask 077 && mkdir -p "$1" ) 2>/dev/null || return 1
  fi
  real="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  [ -n "$real" ] && [ -d "$real" ] || return 1
  [ -O "$real" ] && [ -w "$real" ] || return 2
  open="$(find "$real" -maxdepth 0 -perm -0002 -print 2>/dev/null)" || return 6
  [ -z "$open" ] || return 3
  up="$real"
  while [ "$up" != / ] && [ -n "$up" ]; do
    up="${up%/*}"
    [ -n "$up" ] || up=/
    open="$(find "$up" -maxdepth 0 -perm -0002 ! -perm -1000 -print 2>/dev/null)" || return 6
    [ -z "$open" ] || return 7
  done
  kroot="$(path_key "$(cd "$2" 2>/dev/null && pwd -P)")"
  [ -n "$kroot" ] || return 1
  case "$(path_key "$real")" in "$kroot"|"$kroot"/*) return 4 ;; esac
  printf '%s\n' "$real"
}
state_dir_problem() {
  case "$1" in
    2) printf 'is not owned by this account, or this account cannot write it' ;;
    3) printf 'is writable by every account' ;;
    4) printf 'resolves into the vault' ;;
    5) printf 'is a symlink in a folder every account can write' ;;
    6) printf 'could not be checked for write access by other accounts' ;;
    7) printf 'is inside a folder every account can write that has no sticky bit' ;;
    *) printf 'could not be created, or cannot be entered' ;;
  esac
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
    printf 'backup where one existed. Git HEAD and refs are never rewritten, so check them\n'
    printf "with 'git reflog'. Anything under .git-common/ is outside the vault and was not\n"
    printf 'restored.\n\n'
    printf 'Quarantine: %s\n\n' "$qdir"
    if [ -s "$handled" ]; then
      printf 'Paths:\n'
      sed 's/^/  /' "$handled"
    fi
    if [ -n "$errors" ] && [ -s "$errors" ]; then
      printf '\nCONTAINMENT-ERROR (not quarantined, or not restored. Check these first.)\n'
      sed 's/^/  /' "$errors"
    fi
    printf '\nNo runner, and not vault-check.sh, will run while this file exists.\n'
    printf 'Review the paths above, then delete this file. The runners also keep a copy\n'
    printf 'at %s. Delete that too.\n' "$state/$(basename "$TRIPWIRE_REL")"
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
# place, because the runner must not start the agent without it.
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
#   70  an in-flight marker needed a tripwire and none could be written. The
#       marker is kept, so the next run refuses too
#
# Call it while holding the run lock. No other pass can then be running, so any
# in-flight marker belongs to a pass that died, whatever process now has its pid.
tripwire_check() {
  local root="$1" state="$2" runner="$3" log="$4" marker empty wrote
  if guard_exists "$root" "$state" "$TRIPWIRE_REL"; then
    printf '[%s] TRIPWIRE: refusing to run. A previous pass changed a steering or execution surface. Read %s, then delete it.\n' \
      "$(ts)" "$TRIPWIRE_REL" >> "$log"
    return 78
  fi
  if guard_exists "$root" "$state" "$INFLIGHT_REL"; then
    # Read the state-directory copy first. The agent cannot reach it, while the
    # copy in the vault is a file the pass itself could have rewritten.
    marker="$state/$(basename "$INFLIGHT_REL")"
    [ -f "$marker" ] || marker="$root/$INFLIGHT_REL"
    empty="$(mktemp 2>/dev/null || mktemp -t empty)"
    : > "$empty"
    wrote=1
    write_tripwire "$root" "$state" "$runner" \
      "a previous pass ended before containment ran (interrupted, killed, or the machine stopped), so the vault's steering surfaces are unverified. $(tr '\n' ' ' < "$marker" 2>/dev/null)" \
      "(none, because containment did not run. A pre-pass backup may be in the state directory.)" "$empty" && wrote=0
    rm -f "$empty"
    if [ "$wrote" -ne 0 ]; then
      printf '[%s] TRIPWIRE-ERROR: a previous pass never reached containment and no tripwire could be written. The in-flight marker is kept. Refusing to run.\n' "$(ts)" >> "$log"
      return 70
    fi
    clear_inflight "$root" "$state"
    printf '[%s] TRIPWIRE: a previous pass never reached containment. Tripwire set, refusing to run.\n' "$(ts)" >> "$log"
    return 78
  fi
  return 0
}

# contain_steering_changes <root> <changed-list> <tarball> <quarantine-dir> <handled-out> <errors-out> <before-snapshot> <after-snapshot>
# For each changed steering path: quarantine the current file or symlink, then
# restore the pre-pass copy when one existed and the path is restorable. Writes
# the handled paths and the paths that could not be contained. Returns 0 when at
# least one steering path changed. The snapshots tell steering_filter which
# paths are symlinks.
#
# Every changed path that is a symlink after the pass counts as steering,
# wherever it is. A link the pass made or retargeted, even in an area it may
# write, can point a later session or git at files outside the vault, and a
# folder the pass swapped for a link would carry the quarantine move and the
# restore through it. Those links are handled first, so the paths under them are
# restored into a real folder. After that nothing is moved or restored through a
# symlink unless the link is the same in both snapshots. A link the owner keeps,
# such as a .obsidian shared from elsewhere, is still followed.
contain_steering_changes() {
  local root="$1" changed="$2" tarball="$3" qdir="$4" handled="$5" errors="$6" before="$7" after="$8"
  local rel restore rdirs d skip via
  : > "$handled"
  : > "$errors"
  steering_filter "$before" "$after" < "$changed" > "$handled.direct"
  awk 'phase == 1 { if ($0 ~ /^L/) { p = $0; sub(/^[^ ]* [^ ]* /, "", p); sub(/^\.\//, "", p); link[p] = 1 } next }
    ($0 in link)' phase=1 "$after" phase=2 "$changed" | LC_ALL=C sort -u > "$handled.links"
  {
    cat "$handled.links"
    awk 'phase == 1 { l[$0] = 1; next } !($0 in l)' phase=1 "$handled.links" phase=2 "$handled.direct" | LC_ALL=C sort -u
  } > "$handled"
  rm -f "$handled.direct" "$handled.links"
  [ -s "$handled" ] || return 1
  # The links the pass left as they were, the only ones a path may be reached through.
  LC_ALL=C comm -12 "$before" "$after" | awk '/^L/ { sub(/^[^ ]* [^ ]* /, ""); sub(/^\.\//, ""); print }' > "$handled.kept"

  restore="$(dirname "$tarball")/restore"
  rdirs="$(dirname "$tarball")/restored-dirs"
  rm -rf "$restore"
  mkdir -p "$restore"
  : > "$rdirs"
  # Extract once, never by member name: bsdtar reads member names as patterns.
  if [ -s "$tarball" ] && ! ( cd "$restore" && tar -xf "$tarball" ) 2>/dev/null; then
    printf '(the pre-pass backup could not be extracted, so the paths below may not have been restored)\n' >> "$errors"
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
    # A link still standing above the path, other than one the pass left as it
    # was, is one that could not be quarantined or that appeared after the
    # second snapshot. Following it could move or write files outside the vault.
    via=""
    d="$(dirname "$rel")"
    while [ "$d" != . ] && [ "$d" != / ] && [ -n "$d" ]; do
      if [ -L "$root/$d" ] && ! grep -qxF -- "$d" "$handled.kept"; then via="$d"; fi
      d="$(dirname "$d")"
    done
    if [ -n "$via" ]; then
      printf '%s (the folder %s above it is a symlink the pass made or changed, so it was neither moved nor restored)\n' "$rel" "$via" >> "$errors"
      continue
    fi
    if [ -e "$root/$rel" ] || [ -L "$root/$rel" ]; then
      if ! { mkdir -p "$qdir/$(dirname "$rel")" && mv -f "$root/$rel" "$qdir/$rel"; } 2>/dev/null; then
        if mv -f "$root/$rel" "$root/$rel.runner-quarantined" 2>/dev/null; then
          printf '%s (quarantine unavailable, so renamed in place to %s.runner-quarantined)\n' "$rel" "$rel" >> "$errors"
        else
          printf '%s (could not be moved or renamed, so it is still live)\n' "$rel" >> "$errors"
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
      printf '%s (backed up before the pass, but missing from the extracted backup, so not restored)\n' "$rel" >> "$errors"
    fi
  done < "$handled"
  rm -f "$handled.kept"
  return 0
}

# ---------------------------------------------------------------------------
# Run lock.
#
# One pass at a time per vault, so two passes never race each other's fences or
# git's index. The lock is the directory run.lock in the state directory,
# outside the vault, because a pass that could rewrite the lock's owner file
# could make every later runner wait, or have one reclaim a live lock. mkdir is
# atomic on every platform the runners support.
#
# A lock is stale only when its runner is gone AND the lock is older than the
# longest run that runner declared. "Gone" means no process has the recorded
# pid, or the process that has it is not that runner, because its command line
# does not name the runner's script. A reused pid therefore does not keep a lock
# alive. A runner that is still alive is never reclaimed, however old its lock,
# because wall-clock age includes time the machine spent asleep.
#
# Every owner field is checked before use. Bash evaluates a variable used in
# arithmetic as an expression, and an expression can run a command.
#
#   RUN_LOCK_WAIT  seconds to wait for a held lock before exiting 75 (default 1800)
#   RUN_LOCK_POLL  seconds between checks (default 30)
#
# Known limits. A runner in another pid namespace, such as a container, or on a
# Linux system that hides other users' /proc entries, reads as gone. Runners
# share a lock only when they resolve the same state directory, so a Git Bash
# runner and a WSL runner, or runners under two accounts, do not share one.

RUN_LOCK_NAME="run.lock"

# is_uint <value>
# True for 0 or a string of digits with no leading zero. Bash reads a leading
# zero as octal, so 08 would abort arithmetic and 010 would mean 8.
is_uint() {
  case "$1" in ''|*[!0-9]*|0?*) return 1 ;; *) return 0 ;; esac
}

# is_nonce <value>
# True for a lock nonce as run_lock_acquire writes it.
is_nonce() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac
}

# uint_setting <variable-name> <default> <minimum> <log>
# Prints the variable's value when it is a plain whole number no smaller than
# <minimum> and at most nine digits, so no sum of settings can overflow.
# Otherwise prints <default>, after logging a warning when the variable was set.
uint_setting() {
  local value="${!1:-}"
  if [ -z "$value" ]; then
    printf '%s\n' "$2"
  elif is_uint "$value" && [ "${#value}" -le 9 ] && [ "$value" -ge "$3" ]; then
    printf '%s\n' "$value"
  else
    printf '[%s] WARNING: %s "%s" is not a plain whole number of seconds (digits only, no leading zero, at most nine digits, at least %s). Using %s.\n' \
      "$(ts)" "$1" "$value" "$3" "$2" >> "$4"
    printf '%s\n' "$2"
  fi
}

# owner_field <owner-text> <key>
# One field from an owner file that was read once, so every field comes from
# the same lock.
owner_field() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

# pid_exists <pid>
# True when some process has the pid, whichever account owns it. kill -0 fails
# for another account's process, so /proc and ps are asked as well.
pid_exists() {
  kill -0 "$1" 2>/dev/null && return 0
  [ -d "/proc/$1" ] && return 0
  ps -p "$1" >/dev/null 2>&1
}

# windows_runner_alive <winpid> <lock-started-or-empty>
# On Windows, true when the Windows process with that id is bash or sh and
# started no later than the lock did. Git Bash may not see a runner started in
# another logon session, such as one Task Scheduler runs, but Windows does. A
# bash that started after the lock was taken reuses the id, and is not the
# runner. Only an explicit "none" from PowerShell, or a later start time, reads
# as gone. A missing, blocked, failing or hung PowerShell, or a start time it
# will not give, counts as alive, because waiting is the safe mistake.
#
# The watchdog writes stderr into the same file, so the answer is the first line
# that is exactly none, unknown or a number, read past a byte-order mark and a
# carriage return. A progress record or an error on its own line changes
# nothing. One that ends without a line break just before the answer joins the
# answer's line, and the runner then counts as alive, which is the safe mistake.
windows_runner_alive() {
  local out start
  is_uint "$1" || return 1
  command -v powershell.exe >/dev/null 2>&1 || return 0
  out="$(mktemp 2>/dev/null || mktemp -t winpid)" || return 0
  WATCHDOG_POLL=1 WATCHDOG_GRACE=2 run_with_watchdog 30 "$out" \
    env MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' powershell.exe -NoProfile -NonInteractive -Command \
    "\$ProgressPreference = 'SilentlyContinue'; \$p = Get-Process -Id $1 -ErrorAction SilentlyContinue; if (-not \$p -or \$p.ProcessName -notmatch '^(bash|sh)\$') { 'none' } else { try { [math]::Floor((\$p.StartTime.ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds) } catch { 'unknown' } }"
  start="$(LC_ALL=C awk '{ sub(/\r$/, ""); sub(/^\357\273\277/, ""); if ($0 == "none" || $0 == "unknown" || $0 ~ /^[0-9]+$/) { print; exit } }' "$out" 2>/dev/null)"
  rm -f "$out"
  RUN_PID=""
  [ "$start" = none ] && return 1
  is_uint "$start" || return 0
  [ -z "$2" ] || [ "$start" -le "$2" ]
}

# runner_alive <pid> <runner-name> [winpid] [lock-started]
# True when the pid is running and its command line names <runner-name>.sh, or,
# on Windows, when the recorded Windows process is still that runner.
runner_alive() {
  local pid="$1" name="$2" cmd
  case "$name" in dream-pass|promotion-pass) ;; *) return 1 ;; esac
  if ! is_uint "$pid" || [ "$pid" = "$$" ] || ! pid_exists "$pid"; then
    [ "${3:-}" != "$(cat "/proc/$$/winpid" 2>/dev/null)" ] && windows_runner_alive "${3:-}" "${4:-}" && return 0
    return 1
  fi
  if [ -r "/proc/$pid/cmdline" ]; then
    # A readable command line decides. An empty one is a kernel thread or a
    # zombie, neither of which is the runner.
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    case "$cmd" in *"$name.sh"*) return 0 ;; *) return 1 ;; esac
  fi
  # -ww, because ps otherwise cuts the command at the terminal width, and the
  # script name comes after a long vault path. A command line that cannot be
  # read at all counts as the runner, because waiting is the safe mistake and
  # reclaiming a live lock is not.
  cmd="$(ps -ww -o command= -p "$pid" 2>/dev/null)" || return 0
  case "$cmd" in
    *"$name.sh"*|"") return 0 ;;
    *) return 1 ;;
  esac
}

# git_index_lock_path <root>
# Where git keeps the index lock for this vault, .git/index.lock or, for a
# linked worktree, the one in its own git directory. Prints nothing outside git.
git_index_lock_path() {
  local dirs
  if [ -d "$1/.git" ]; then
    printf '%s\n' "$1/.git/index.lock"
  elif dirs="$(git_dirs_of "$1")"; then
    printf '%s/index.lock\n' "$(printf '%s\n' "$dirs" | sed -n 1p)"
  fi
}

# lock_dir_aged <lock-dir> <minutes> <state-dir>
# True when the lock directory was last changed more than <minutes> ago, or when
# its time is more than two minutes in the future, which means the clock was set
# back after it was made. Its age cannot be known then, so whether its runner is
# gone decides. The margin matters, because writing the owner file inside the
# directory moves its time to now, and now must never read as the future. The
# reference time is written and read in UTC, because a local time in the hour
# repeated when clocks go back could be read an hour off.
lock_dir_aged() {
  local ref="$3/.run.lock.future.$$" later stamp newer
  [ -n "$(find "$1" -maxdepth 0 -mmin +"$2" 2>/dev/null)" ] && return 0
  later=$(( $(date +%s) + 120 ))
  stamp="$(TZ=UTC0 date -d "@$later" +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC0 date -r "$later" +%Y%m%d%H%M.%S 2>/dev/null)"
  [ -n "$stamp" ] || return 1
  TZ=UTC0 touch -t "$stamp" "$ref" 2>/dev/null || return 1
  newer="$(find "$1" -maxdepth 0 -newer "$ref" 2>/dev/null)"
  rm -f "$ref"
  [ -n "$newer" ]
}

# lock_still_judged <lock-dir> <judged-nonce> <state-dir>
# True when the lock still carries the nonce it was judged by. A lock judged with
# no nonce (no usable owner file) must also still be older than two minutes. An
# owner file that exists but cannot be read belongs to a holder.
lock_still_judged() {
  local nonce
  if [ -e "$1/owner" ] && [ ! -r "$1/owner" ]; then
    return 1
  fi
  nonce="$(owner_field "$(cat "$1/owner" 2>/dev/null)" nonce)"
  is_nonce "$nonce" || nonce=""
  [ "$nonce" = "$2" ] || return 1
  [ -n "$2" ] || lock_dir_aged "$1" 2 "$3"
}

# run_lock_reclaim <lock-dir> <nonce-judged-stale> <state-dir> <log>
# Removes a stale lock. A guard directory lets one reclaim run at a time. Inside
# it the lock is judged again, moved aside, and judged once more, so a lock
# another runner has just taken is never removed. Returns 0 when the stale lock
# is gone.
#
# The checks around the move are what keep a live lock safe, and the guard only
# narrows the window. So a guard older than two minutes, left by a runner killed
# during a reclaim, is removed even though that check and the removal are not
# one step.
run_lock_reclaim() {
  local lock="$1" judged="$2" state="$3" log="$4" guard="$1.reclaim" aside rc=1
  if ! mkdir "$guard" 2>/dev/null; then
    [ -n "$(find "$guard" -maxdepth 0 -mmin +2 2>/dev/null)" ] && rmdir "$guard" 2>/dev/null
    return 1
  fi
  if [ -d "$lock" ] && lock_still_judged "$lock" "$judged" "$state"; then
    aside="$lock.stale.$$.$(date +%s)"
    if [ ! -e "$aside" ] && mv "$lock" "$aside" 2>/dev/null; then
      if lock_still_judged "$aside" "$judged" "$state"; then
        rm -rf "$aside"
        rc=0
      else
        # The lock changed between the check and the move, so it belongs to a
        # runner. Put it back while the slot is empty, and never delete it. A
        # directory made in the slot meanwhile would receive it as a subfolder,
        # so that move is undone.
        [ ! -e "$lock" ] && mv "$aside" "$lock" 2>/dev/null
        [ -e "$lock/${aside##*/}" ] && mv "$lock/${aside##*/}" "$aside" 2>/dev/null
        if [ -e "$aside" ] || [ -e "$lock/${aside##*/}" ]; then
          printf '[%s] RUN-LOCK-RACE: the run lock changed while it was being reclaimed. The lock that was moved is kept at %s for review.\n' \
            "$(ts)" "$aside" >> "$log"
        fi
      fi
    fi
  fi
  rmdir "$guard" 2>/dev/null
  return "$rc"
}

# run_lock_acquire <state-dir> <root> <runner> <log> <longest-run-seconds>
# Returns 0 holding the lock, 75 after logging who holds it, or 1 when the lock
# could not be written at all.
run_lock_acquire() {
  local state="$1" root="$2" runner="$3" log="$4" longest="$5" lock="$1/$RUN_LOCK_NAME"
  local wait_max poll deadline now remaining owner o_runner o_pid o_winpid o_started o_longest o_nonce
  local aged holder idx winpid started cur mkdir_misses=0
  wait_max="$(uint_setting RUN_LOCK_WAIT 1800 0 "$log")"
  poll="$(uint_setting RUN_LOCK_POLL 30 1 "$log")"
  is_uint "$longest" || longest=0
  RUN_LOCK_DIR="$lock"
  RUN_LOCK_MADE=0
  mkdir -p "$state" 2>/dev/null
  deadline=$(( $(date +%s) + wait_max ))
  while :; do
    holder=""
    # A new nonce for every attempt, so one nonce only ever names one directory.
    RUN_LOCK_NONCE="$runner-$$-$(date +%s)-${RANDOM:-0}${RANDOM:-0}"
    # The owner fields are read before mkdir, so the temporary owner file is
    # written the moment the directory exists and no fork sits in between.
    winpid=""
    [ -r "/proc/$$/winpid" ] && winpid="$(cat "/proc/$$/winpid" 2>/dev/null)"
    started="$(date +%s)"
    if mkdir "$lock" 2>/dev/null; then
      mkdir_misses=0
      RUN_LOCK_MADE=1
      # The owner file is placed with a hard link, which fails when an owner file
      # is already there. A runner that stalled after its mkdir, and whose
      # directory another runner reclaimed and made again, then finds that
      # runner's owner file instead of writing over it. Where no hard link can be
      # made, the rename is used, and only while no owner file is there.
      if printf 'runner=%s\npid=%s\nwinpid=%s\nstarted=%s\nlongest=%s\nnonce=%s\n' \
        "$runner" "$$" "$winpid" "$started" "$longest" "$RUN_LOCK_NONCE" > "$lock/owner.$RUN_LOCK_NONCE" 2>/dev/null; then
        ln "$lock/owner.$RUN_LOCK_NONCE" "$lock/owner" 2>/dev/null \
          || { [ ! -e "$lock/owner" ] && mv -f "$lock/owner.$RUN_LOCK_NONCE" "$lock/owner" 2>/dev/null; }
      fi
      rm -f "$lock/owner.$RUN_LOCK_NONCE" 2>/dev/null
      cur="$(owner_field "$(cat "$lock/owner" 2>/dev/null)" nonce)"
      if [ "$cur" != "$RUN_LOCK_NONCE" ]; then
        if ! is_nonce "$cur"; then
          run_lock_release
          printf '[%s] ERROR: could not write the run lock'"'"'s owner file in %s. Refusing to run.\n' "$(ts)" "$state" >> "$log"
          return 1
        fi
        # Another runner took the directory before this one's owner file landed.
        # It is that runner's lock now, so wait for it like any other.
        RUN_LOCK_MADE=0
        holder="a runner that took the lock at the same moment"
      else
        # git's own index lock. A fresh one is a git command finishing, and an old
        # one is a crashed git that blocks every commit until someone removes it.
        idx="$(git_index_lock_path "$root")"
        if [ -z "$idx" ] || [ ! -e "$idx" ]; then
          return 0
        fi
        run_lock_release
        if [ -n "$(find "$idx" -mmin +10 2>/dev/null)" ]; then
          printf '[%s] LOCKED: %s is more than 10 minutes old. A git command crashed. Remove it once no git process is running.\n' \
            "$(ts)" "$idx" >> "$log"
          return 75
        fi
        holder="git (its index.lock is present)"
      fi
    elif [ -L "$lock" ] || [ ! -d "$lock" ]; then
      # mkdir failed, yet there is no lock directory. Its holder may have released
      # it a moment ago, antivirus or an indexer may still hold the old folder
      # open, or the state directory cannot take the entry (a full disk, or a file
      # or symlink named run.lock). A symlink to a folder is never read as a lock.
      # Give up at once on a file or symlink in the way, and otherwise after five
      # misses in a row, a second apart.
      mkdir_misses=$((mkdir_misses + 1))
      if [ -e "$lock" ] || [ -L "$lock" ] || [ "$mkdir_misses" -ge 5 ]; then
        printf '[%s] ERROR: could not create the run lock %s. Refusing to run.\n' "$(ts)" "$lock" >> "$log"
        return 1
      fi
      sleep 1
      continue
    elif [ -e "$lock/owner" ] && [ ! -r "$lock/owner" ]; then
      mkdir_misses=0
      holder="a runner whose owner file this account cannot read"
    else
      mkdir_misses=0
      owner="$(cat "$lock/owner" 2>/dev/null)"
      o_runner="$(owner_field "$owner" runner)"
      o_pid="$(owner_field "$owner" pid)"
      o_winpid="$(owner_field "$owner" winpid)"
      o_started="$(owner_field "$owner" started)"
      o_longest="$(owner_field "$owner" longest)"
      o_nonce="$(owner_field "$owner" nonce)"
      case "$o_runner" in dream-pass|promotion-pass) ;; *) o_runner="" ;; esac
      # A number longer than any real value is malformed, so no sum can wrap.
      is_uint "$o_pid" && [ "${#o_pid}" -le 10 ] || o_pid=""
      is_uint "$o_winpid" && [ "${#o_winpid}" -le 10 ] || o_winpid=""
      is_uint "$o_started" && [ "${#o_started}" -le 11 ] || o_started=""
      is_uint "$o_longest" && [ "${#o_longest}" -le 10 ] || o_longest="$longest"
      is_nonce "$o_nonce" || o_nonce=""
      now="$(date +%s)"
      aged=no
      if [ -n "$(owner_field "$owner" kill_failed)" ]; then
        # Never stale. A process of that pass may still be running.
        printf '[%s] LOCKED: the run lock is marked KILL_FAILED by %s (pid %s). A process of that pass may still be running. Check for it, stop it, then delete %s.\n' \
          "$(ts)" "${o_runner:-an unknown runner}" "${o_pid:-unknown}" "$lock" >> "$log"
        return 75
      elif [ -z "$o_nonce" ]; then
        # No usable owner file. Either a runner is between mkdir and its first
        # write, or one died there, and only the second lasts two minutes.
        lock_dir_aged "$lock" 2 "$state" && aged=yes
      elif [ -n "$o_started" ] && [ "$o_started" -le "$now" ]; then
        [ $((now - o_started)) -gt "$o_longest" ] && aged=yes
      else
        # A start time that is missing, malformed or in the future, so the lock
        # directory's own age decides instead.
        lock_dir_aged "$lock" $(( (o_longest + 59) / 60 )) "$state" && aged=yes
      fi
      if [ "$aged" = yes ] && ! runner_alive "$o_pid" "$o_runner" "$o_winpid" "$o_started"; then
        if run_lock_reclaim "$lock" "$o_nonce" "$state" "$log"; then
          printf '[%s] reclaimed a stale run lock (runner %s, pid %s)\n' "$(ts)" "${o_runner:-unknown}" "${o_pid:-unknown}" >> "$log"
          continue
        fi
      fi
      holder="${o_runner:-an unknown runner} (pid ${o_pid:-unknown})"
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      printf '[%s] LOCKED: the run lock is held by %s after waiting %ss. Not starting.\n' \
        "$(ts)" "$holder" "$wait_max" >> "$log"
      return 75
    fi
    remaining=$((deadline - now))
    if [ "$poll" -lt "$remaining" ]; then sleep "$poll"; else sleep "$remaining"; fi
  done
}

# mark_kill_failed <log> <report>
# Records in the run lock's owner file that a stopped pass left a process
# running, then logs it. Such a lock is never released by this runner and never
# reclaimed as stale by another, so every later pass exits 75 until a human has
# checked that nothing of the old pass is still running and removed the lock.
mark_kill_failed() {
  local log="$1" report="$2"
  if run_lock_held && printf 'kill_failed=%s\n' "$(date +%s)" >> "$RUN_LOCK_DIR/owner" 2>/dev/null; then
    printf '[%s] KILL_FAILED: a process of the stopped pass may still be running, so the run lock %s is kept and no pass will start. Check for it, stop it, then delete the lock folder. What the stop found:\n' "$(ts)" "$RUN_LOCK_DIR" >> "$log"
  else
    printf '[%s] KILL_FAILED: a process of the stopped pass may still be running, and the run lock could not be marked, so later passes are not held back. Check for it and stop it. What the stop found:\n' "$(ts)" >> "$log"
  fi
  printf '%s\n' "$report" | sed 's/^/    /' >> "$log"
}

# run_lock_held
# True while the lock's owner file still carries this runner's nonce. The hard
# link in run_lock_acquire already keeps a stalled runner from writing its owner
# file over another runner's. Where the rename is used instead, one can still
# land over another between its check and the rename, so the runners check again
# just before they mark a pass in flight. That check only catches a rename that
# lands before it. One that lands later, after a second stall, is not caught, and
# the stalled runner then sees the other pass's in-flight marker and sets a false
# tripwire. That needs a file system without hard links and two stalls, the first
# longer than two minutes.
run_lock_held() {
  [ -n "${RUN_LOCK_DIR:-}" ] && [ -n "${RUN_LOCK_NONCE:-}" ] \
    && [ "$(owner_field "$(cat "$RUN_LOCK_DIR/owner" 2>/dev/null)" nonce)" = "$RUN_LOCK_NONCE" ]
}

# run_lock_release
# Removes the lock only while this runner holds it, which means the owner file
# carries this runner's current nonce, or this runner made the directory and no
# owner file landed. A runner whose lock was reclaimed never deletes the new
# holder's. In the second case only this runner's own temporary file is removed,
# and then the directory only if it is empty, because a runner that stalled after
# its mkdir cannot tell its directory from one another runner has just made.
run_lock_release() {
  [ -n "${RUN_LOCK_DIR:-}" ] || return 0
  # A lock marked KILL_FAILED stays, so no pass starts while a process of the
  # stopped one may still be writing.
  if [ -n "${RUN_LOCK_NONCE:-}" ] && run_lock_held \
     && [ -n "$(owner_field "$(cat "$RUN_LOCK_DIR/owner" 2>/dev/null)" kill_failed)" ]; then
    RUN_LOCK_MADE=0
    return 0
  fi
  if [ -n "${RUN_LOCK_NONCE:-}" ] \
     && [ "$(owner_field "$(cat "$RUN_LOCK_DIR/owner" 2>/dev/null)" nonce)" = "$RUN_LOCK_NONCE" ]; then
    rm -rf "$RUN_LOCK_DIR"
  elif [ "${RUN_LOCK_MADE:-0}" -eq 1 ] && [ ! -e "$RUN_LOCK_DIR/owner" ]; then
    rm -f "$RUN_LOCK_DIR/owner.${RUN_LOCK_NONCE:-}" 2>/dev/null
    rmdir "$RUN_LOCK_DIR" 2>/dev/null
  fi
  RUN_LOCK_MADE=0
}

# safe_git <empty-hooks-dir> <git args...>
# Git as the runner calls it: no hooks, no fsmonitor, no signature checks, no
# prompts. That removes the ways a changed config or hook directory most
# directly runs code in the runner's shell. It is not a sandbox: a .gitattributes
# filter can still run on commands that read the work tree, which is why the
# runners call git on a vault only while its config is known to be the pre-pass
# one.
#
# Every path is taken literally (GIT_LITERAL_PATHSPECS). Git otherwise reads a
# path after -- as a pattern as well, so a note a pass named [e]xisting.md would
# also stage, commit or restore someone's existing.md. The other pathspec
# settings are turned off, because git refuses to combine any of them with the
# literal one, and a scheduler's environment could carry them.
LITERAL_PATHS="GIT_LITERAL_PATHSPECS=1 GIT_GLOB_PATHSPECS=0 GIT_NOGLOB_PATHSPECS=0 GIT_ICASE_PATHSPECS=0"
safe_git() {
  local hooks="$1"
  shift
  # $LITERAL_PATHS is unquoted on purpose, so env gets one assignment per word.
  # Stdin is /dev/null, so nothing git starts can wait on input.
  env GIT_TERMINAL_PROMPT=0 $LITERAL_PATHS git -c core.hooksPath="$hooks" -c core.fsmonitor=false \
    -c log.showSignature=false "$@" </dev/null
}

# git_ignores <root> <empty-hooks-dir> <relative-path>
# True when git ignores the path. check-ignore refuses GIT_LITERAL_PATHSPECS and
# exits 128, which would read as "not ignored", so it runs with every pathspec
# setting off. It needs none, because it tests each argument as one path and
# never expands it.
git_ignores() {
  env GIT_TERMINAL_PROMPT=0 GIT_LITERAL_PATHSPECS=0 GIT_GLOB_PATHSPECS=0 GIT_NOGLOB_PATHSPECS=0 GIT_ICASE_PATHSPECS=0 \
    git -c core.hooksPath="$2" -c core.fsmonitor=false -C "$1" check-ignore -q -- "$3" 2>/dev/null
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

# ---------------------------------------------------------------------------
# Runner commits.
#
# The runner commits a pass's output itself, and only the exact files the
# snapshot diff says the pass changed in the areas it owns. It never stages
# everything. A file that already had uncommitted changes before the pass
# belongs to whoever was editing it, so a pass that changes one commits nothing.
# Every other dirty or staged file is left as it was. The commit runs like every
# other runner git command, with no hooks and no fsmonitor, because hook
# managers keep their configuration in ordinary files a pass can write, and it
# runs under a watchdog, because a signing prompt must not stall a scheduled run.
# vault-check on the committed files takes the place of a commit gate.
#
# Only a vault that is the top of its own repository is committed. A vault that
# is a folder inside a larger repository, such as a home folder kept in git, is
# noted and left alone, because that repository's config and hooks are outside
# the fence.

# git_preflight <root> <empty-hooks-dir> <log>
# Sets VAULT_GIT to 1 when the vault is the top of a git work tree, else to 0
# with the reason in VAULT_GIT_NOTE. Returns 1 after logging when the vault has a
# .git entry, or git reports anything but "not a git repository", and git still
# cannot read it, because a real repository must not pass as none. Returns 75
# after logging when a merge, rebase, cherry-pick, revert or bisect is in
# progress, or HEAD is detached, because a commit would then land where the owner
# did not choose.
git_preflight() {
  local root="$1" hooks="$2" log="$3" gd op top err="$2.rev-parse.err"
  VAULT_GIT=0
  VAULT_GIT_NOTE="the vault is not a git repository"
  if ! command -v git >/dev/null 2>&1; then
    VAULT_GIT_NOTE="git is not installed"
    return 0
  fi
  if [ "$(LC_ALL=C LANGUAGE='' safe_git "$hooks" -C "$root" rev-parse --is-inside-work-tree 2>"$err")" != true ]; then
    if [ ! -e "$root/.git" ] && [ ! -L "$root/.git" ] && grep -q 'not a git repository' "$err" 2>/dev/null; then
      return 0
    fi
    printf '[%s] ERROR: git could not read this vault'"'"'s repository, so its work could not be committed. Refusing to run. git said: %s\n' \
      "$(ts)" "$(head -n 1 "$err" 2>/dev/null)" >> "$log"
    return 1
  fi
  top="$(safe_git "$hooks" -C "$root" rev-parse --show-toplevel 2>/dev/null)"
  if [ -z "$top" ] || [ "$(path_key "$(cd "$top" 2>/dev/null && pwd -P)")" != "$(path_key "$(cd "$root" 2>/dev/null && pwd -P)")" ]; then
    VAULT_GIT_NOTE="the vault is a folder inside the larger repository at ${top:-an unknown place}, not a repository of its own"
    return 0
  fi
  VAULT_GIT=1
  VAULT_GIT_NOTE=""
  gd="$(safe_git "$hooks" -C "$root" rev-parse --absolute-git-dir 2>/dev/null)"
  if [ -z "$gd" ]; then
    printf '[%s] LOCKED: git did not name this vault'"'"'s git directory, so a git operation in progress cannot be ruled out. Not starting.\n' "$(ts)" >> "$log"
    return 75
  fi
  for op in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG sequencer; do
    if [ -e "$gd/$op" ]; then
      printf '[%s] LOCKED: a git operation is in progress in this vault (%s exists). Finish or abort it, then run again.\n' "$(ts)" "$gd/$op" >> "$log"
      return 75
    fi
  done
  if ! safe_git "$hooks" -C "$root" symbolic-ref -q HEAD >/dev/null 2>&1; then
    printf '[%s] LOCKED: HEAD is detached, so a commit would land on no branch. Check out a branch, then run again.\n' "$(ts)" >> "$log"
    return 75
  fi
  return 0
}

# git_dirty_paths <root> <empty-hooks-dir> <out>
# Writes the path of every file git reports as modified, staged, untracked or
# conflicted, and both sides of a rename or copy, sorted. The vault is the top of
# its repository (git_preflight), so porcelain paths are vault paths. Returns 1
# when git status fails, because an unknown dirty set could let a pass commit
# over someone's edit.
git_dirty_paths() {
  local root="$1" hooks="$2" out="$3"
  if ! safe_git "$hooks" -C "$root" status --porcelain -z --untracked-files=all > "$out.raw" 2>/dev/null; then
    rm -f "$out.raw"
    return 1
  fi
  # A rename or copy record is followed by a second record holding the old path.
  tr '\0' '\n' < "$out.raw" | awk '
    from { from = 0; print; next }
    {
      print substr($0, 4)
      if (substr($0, 1, 2) ~ /[RC]/) from = 1
    }' | LC_ALL=C sort -u > "$out"
  rm -f "$out.raw"
}

# record_uncommitted <root> <empty-hooks-dir> <state-dir> <runner> <path-list> [<log>]
# Records the byte-for-byte blob id of each listed file that is still
# uncommitted, in the state directory, so the next run can tell a journal this
# runner left behind from one someone has edited since. Each line is the blob
# id, a tab, and the path, read back as a whole line, so a name that ends in a
# space stays its own name. A record that cannot be written in full is logged,
# and the earlier record is kept.
RUNNER_TAB="$(printf '\t')"
record_uncommitted() {
  local root="$1" hooks="$2" list="$3/$4.uncommitted" log="${6:-/dev/null}" p blob failed=0
  if ! : > "$list.new" 2>/dev/null; then
    printf '[%s] WARNING: could not record the files this pass left uncommitted in %s, so the next run will take them for someone'"'"'s edit.\n' "$(ts)" "$3" >> "$log"
    return 0
  fi
  while IFS= read -r p; do
    [ -n "$p" ] && [ -f "$root/$p" ] && [ ! -L "$root/$p" ] || continue
    [ -n "$(safe_git "$hooks" -C "$root" status --porcelain -- "$p" 2>/dev/null)" ] || continue
    blob="$(safe_git "$hooks" -C "$root" hash-object --no-filters -- "$p" 2>/dev/null)" || continue
    if [ -n "$blob" ] && ! printf '%s\t%s\n' "$blob" "$p" >> "$list.new" 2>/dev/null; then
      failed=1
    fi
  done < "$5"
  if [ "$failed" -eq 1 ] || ! mv -f "$list.new" "$list" 2>/dev/null; then
    rm -f "$list.new" 2>/dev/null
    printf '[%s] WARNING: could not record the files this pass left uncommitted in %s, so the next run will take them for someone'"'"'s edit.\n' "$(ts)" "$3" >> "$log"
  fi
}

# adopt_uncommitted <root> <empty-hooks-dir> <state-dir> <runner> <dirty-list>
# Takes off the dirty list each file on it that this runner recorded as left
# uncommitted and that still has exactly those bytes, and lists those files in
# <dirty-list>.adopted, which own_adopted later adds to the pass's own files. A
# file that differs was edited since, and stays on the dirty list. The record
# stays until a run commits or puts back its files (forget_uncommitted) or
# records its own leftovers over it, so a run that stops before then loses
# nothing.
adopt_uncommitted() {
  local root="$1" hooks="$2" list="$3/$4.uncommitted" dirty="$5" line blob p now
  : > "$dirty.adopted"
  [ -f "$list" ] || return 0
  while IFS= read -r line; do
    # A line with no tab, such as one an older runner wrote, is not trusted.
    case "$line" in *"$RUNNER_TAB"*) ;; *) continue ;; esac
    blob="${line%%"$RUNNER_TAB"*}"
    p="${line#*"$RUNNER_TAB"}"
    [ -n "$p" ] && [ -f "$root/$p" ] && [ ! -L "$root/$p" ] || continue
    grep -qxF -- "$p" "$dirty" || continue
    now="$(safe_git "$hooks" -C "$root" hash-object --no-filters -- "$p" 2>/dev/null)"
    [ -n "$now" ] && [ "$now" = "$blob" ] && printf '%s\n' "$p" >> "$dirty.adopted"
  done < "$list"
  awk 'FILENAME == ARGV[1] { adopted[$0] = 1; next } !($0 in adopted)' "$dirty.adopted" "$dirty" > "$dirty.kept"
  mv -f "$dirty.kept" "$dirty"
}

# own_adopted <snap-dir> <owned-pattern>
# Adds each adopted leftover in <snap-dir>/predirty.adopted whose path matches the
# extended regular expression to <snap-dir>/owned, so it is checked and then
# committed or put back with the files this pass changed.
own_adopted() {
  [ -s "$1/predirty.adopted" ] || return 0
  { grep -E -- "$2" "$1/predirty.adopted"; cat "$1/owned"; } | LC_ALL=C sort -u > "$1/owned.new"
  mv -f "$1/owned.new" "$1/owned"
}

# forget_uncommitted <state-dir> <runner>
# Removes the record of files left uncommitted, once a run has committed them or
# put them back.
forget_uncommitted() {
  rm -f "$1/$2.uncommitted" 2>/dev/null
}

# record_leftovers <root> <empty-hooks-dir> <state-dir> <runner> <snap-dir> [<log>]
# After a pass that wrote only where it may (<snap-dir>/outside is empty) but
# whose files were not committed, because it timed out, failed, or its commit
# failed, records the files in <snap-dir>/owned for adopt_uncommitted. A file that
# was already dirty before this pass is not recorded, because it holds someone
# else's edit too.
record_leftovers() {
  local snap="$5" log="${6:-/dev/null}" p was
  [ "${VAULT_GIT:-0}" -eq 1 ] || return 0
  [ -s "$snap/outside" ] && return 0
  awk 'FILENAME == ARGV[1] { dirty[$0] = 1; next } !($0 in dirty)' "$snap/predirty" "$snap/owned" > "$snap/leftover"
  # A file that changed while the commit checked it holds another writer's
  # bytes, so it is not recorded as this runner's own.
  if [ -s "$snap/commit-mismatch" ]; then
    awk 'FILENAME == ARGV[1] { changed[$0] = 1; next } !($0 in changed)' "$snap/commit-mismatch" "$snap/leftover" > "$snap/leftover.kept"
    mv -f "$snap/leftover.kept" "$snap/leftover"
  fi
  # So does a file that is no longer as the second snapshot saw it, such as a
  # note someone edited while a slow commit step ran.
  : > "$snap/leftover.kept"
  : > "$snap/leftover.changed"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    was="$(P="./$p" awk '{ line = $0; sub(/^[^ ]* [^ ]* /, "", line) } line == ENVIRON["P"] { print $1 " " $2; exit }' "$snap/after")"
    if [ "$(path_state "$1" "$p")" = "$was" ]; then
      printf '%s\n' "$p" >> "$snap/leftover.kept"
    else
      printf '%s\n' "$p" >> "$snap/leftover.changed"
    fi
  done < "$snap/leftover"
  mv -f "$snap/leftover.kept" "$snap/leftover"
  if [ -s "$snap/leftover.changed" ]; then
    printf '[%s] NOT-RECORDED: these files changed after the pass ended, so the next run will take them for someone'"'"'s edit:\n' "$(ts)" >> "$log"
    sed 's/^/    /' "$snap/leftover.changed" >> "$log"
  fi
  record_uncommitted "$1" "$2" "$3" "$4" "$snap/leftover" "${6:-}"
}

# check_leftovers <root> <snap-dir> <head-commit-or-NONE> <quarantine-dir> <log> <put-back: 0|1>
# Runs vault-check on each adopted leftover in <snap-dir>/predirty.adopted on its
# own, before the agent starts, and drops every one that fails from that list,
# so it cannot make this pass's own files fail with it. With <put-back> 1 a
# failing leftover is put back now, as revert_owned does. With 0 it is left in
# place for review, and from then on counts as someone's file.
check_leftovers() {
  local root="$1" snap="$2" head="$3" qdir="$4" log="$5" putback="$6" p pre="$2/leftover-check"
  [ -s "$snap/predirty.adopted" ] || return 0
  rm -rf "$pre"
  mkdir -p "$pre"
  : > "$pre/failed"
  : > "$pre/after"
  : > "$pre/check.out"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/vault-check.sh" -- "$p" </dev/null >"$pre/check.one" 2>&1 && continue
    printf '%s\n' "$p" >> "$pre/failed"
    printf '%s ./%s\n' "$(path_state "$root" "$p")" "$p" >> "$pre/after"
    cat "$pre/check.one" >> "$pre/check.out"
  done < "$snap/predirty.adopted"
  [ -s "$pre/failed" ] || return 0
  awk 'FILENAME == ARGV[1] { failed[$0] = 1; next } !($0 in failed)' "$pre/failed" "$snap/predirty.adopted" > "$snap/predirty.adopted.kept"
  if [ "$putback" = 1 ]; then
    cp "$pre/after" "$pre/before"
    cp "$snap/predirty.adopted" "$pre/predirty.adopted"
    printf '[%s] LEFTOVER-REJECTED: files an earlier run left uncommitted fail vault-check, so they are put back before this pass starts:\n' "$(ts)" >> "$log"
    sed 's/^/    vault-check: /' "$pre/check.out" >> "$log"
    if ! revert_owned "$root" "$snap/nohooks" "$pre" "$pre/failed" "$head" "$qdir" "$log"; then
      printf '[%s] ERROR: some of those files could not be put back, as listed above. Review them.\n' "$(ts)" >> "$log"
    fi
  else
    printf '[%s] LEFTOVER-REJECTED: files an earlier run left uncommitted fail vault-check, so they are left in place for review and not committed:\n' "$(ts)" >> "$log"
    sed 's/^/    vault-check: /' "$pre/check.out" >> "$log"
    sed 's/^/    /' "$pre/failed" >> "$log"
    # Back on the dirty list, so this pass may not write them either.
    cat "$pre/failed" "$snap/predirty" | LC_ALL=C sort -u > "$snap/predirty.new"
    mv -f "$snap/predirty.new" "$snap/predirty"
  fi
  mv -f "$snap/predirty.adopted.kept" "$snap/predirty.adopted"
}

# path_state <root> <relative-path>
# What a snapshot line records for the path, "<checksum> <size>" for a file and
# "L<checksum> 0" for a symlink, "other" for anything else that exists, such as
# a folder, and nothing when the path is missing.
path_state() {
  if [ -L "$1/$2" ]; then
    ( cd "$1" && fence_find "./$2" ) | cut -d' ' -f1,2
  elif [ -f "$1/$2" ]; then
    ( cd "$1" && cksum "./$2" 2>/dev/null ) | cut -d' ' -f1,2
  elif [ -e "$1/$2" ]; then
    printf 'other\n'
  fi
}

# revert_owned <root> <empty-hooks-dir> <snap-dir> <path-list> <commit-before-or-NONE> <quarantine-dir> <log>
# Puts back the pre-pass state of every file in <path-list>, after the runner
# rejected the pass's notes. None of them was dirty before the pass, except a
# leftover of this runner that adopt_uncommitted took off the dirty list, so the
# commit HEAD pointed at before the pass holds their pre-pass bytes.
#
#   - A path that is not exactly as the second snapshot saw it (changed, removed,
#     or now a folder or a link) is someone else's since, and is left alone.
#   - A path whose blob in HEAD differs from the one in the commit before the
#     pass was committed while the pass ran. Restoring it would undo that commit
#     in the work tree, so it is left alone.
#   - A file in the commit before the pass is copied to the quarantine outside
#     the vault, because its bytes may include someone's edit made during the
#     pass, and then restored from that commit. A symlink there is moved to the
#     quarantine instead. When the copy fails the file is not restored.
#   - A file in no commit is moved to the quarantine when the pass created it or
#     it is an adopted leftover, and any folder left empty below the top folder
#     is removed, unless it held files before the pass. One that existed before
#     the pass because git ignores it has no earlier bytes to go back to, so it
#     is left in place.
#
# Every path left alone is listed in the log. Returns 1 when any path in the
# list could not be put back.
REVERT_KEEP_DIRS="31-standards 40-llm-wiki 40-llm-wiki/wiki 20-projects 20-projects/_logs"
revert_owned() {
  local root="$1" hooks="$2" snap="$3" plist="$4" before="$5" qdir="$6" log="$7" p rc=0 pass list
  [ -s "$plist" ] || return 0
  : > "$plist.deferred"
  # A path is read from a snapshot through the environment, never awk -v, which
  # would turn a backslash in a name into an escape.
  for pass in 1 2; do
    list="$plist"
    [ "$pass" = 2 ] && list="$plist.deferred"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      revert_path "$pass"
    done < "$list"
  done
  rm -f "$plist.deferred"
  return "$rc"
}

# revert_path <pass: 1|2>
# One path of revert_owned, which it reads from the caller's p, root, hooks,
# snap, before, qdir and log, and whose rc it sets to 1 when the path could not
# be put back. A path that is now a folder, and that the second snapshot saw
# as no file, is a note the pass replaced with a folder. An empty one is removed
# and the note restored. On the first pass one holding files the second
# snapshot saw is set aside in <plist>.deferred, so the files in it are moved
# out first and the path can then be restored. One still holding anything after
# that is left.
revert_path() {
  local now was b_blob h_blob d
  now="$(path_state "$root" "$p")"
  was="$(P="./$p" awk '{ line = $0; sub(/^[^ ]* [^ ]* /, "", line) } line == ENVIRON["P"] { print $1 " " $2; exit }' "$snap/after")"
  if [ "$now" = other ] && [ -z "$was" ] && [ -d "$root/$p" ] && [ ! -L "$root/$p" ]; then
    if rmdir "$root/$p" 2>/dev/null; then
      now=""
    elif [ "$1" = 2 ]; then
      printf '    %s (replaced by a folder that is still not empty, so it was not restored)\n' "$p" >> "$log"
      rc=1
      return 0
    elif P="./$p/" awk '{ line = $0; sub(/^[^ ]* [^ ]* /, "", line) } index(line, ENVIRON["P"]) == 1 { found = 1; exit } END { exit found ? 0 : 1 }' "$snap/after"; then
      printf '%s\n' "$p" >> "$plist.deferred"
      return 0
    fi
  fi
  if [ "$now" != "$was" ]; then
    printf '    %s (changed after the pass ended, so it was left as it is)\n' "$p" >> "$log"
    rc=1
    return 0
  fi
  b_blob=""
  [ "$before" != NONE ] && b_blob="$(index_blob "$root" "$before" "$p")"
  h_blob="$(index_blob "$root" HEAD "$p")"
  if [ "$h_blob" != "$b_blob" ]; then
    printf '    %s (committed while the pass ran, so it was left as it is)\n' "$p" >> "$log"
    rc=1
    return 0
  fi
  if [ -n "$b_blob" ]; then
    if [ -L "$root/$p" ]; then
      if ! { mkdir -p "$qdir/$(dirname "$p")" && mv -f "$root/$p" "$qdir/$p"; } 2>/dev/null; then
        printf '    %s (a link that could not be moved to the quarantine, so it was not restored)\n' "$p" >> "$log"
        rc=1
        return 0
      fi
      d="moved to $qdir/$p, then "
    elif [ -f "$root/$p" ]; then
      if ! { mkdir -p "$qdir/$(dirname "$p")" && cp -p "$root/$p" "$qdir/$p"; } 2>/dev/null; then
        printf '    %s (could not be copied to the quarantine, so it was not restored)\n' "$p" >> "$log"
        rc=1
        return 0
      fi
      d="copied to $qdir/$p, then "
    else
      d=""
    fi
    if safe_git "$hooks" -C "$root" restore --source="$before" --worktree -- "$p" 2>/dev/null; then
      printf '    %s (%srestored from %s)\n' "$p" "$d" "$before" >> "$log"
    else
      printf '    %s (%scould not be restored from %s)\n' "$p" "$d" "$before" >> "$log"
      rc=1
    fi
  elif [ -e "$root/$p" ] || [ -L "$root/$p" ]; then
    if P="./$p" awk '{ line = $0; sub(/^[^ ]* [^ ]* /, "", line) } line == ENVIRON["P"] { found = 1; exit } END { exit found ? 0 : 1 }' "$snap/before" \
       && ! grep -qxF -- "$p" "$snap/predirty.adopted" 2>/dev/null; then
      printf '    %s (existed before the pass but is in no commit, so it could not be put back and was left as the pass wrote it)\n' "$p" >> "$log"
      rc=1
    elif mkdir -p "$qdir/$(dirname "$p")" 2>/dev/null && mv -f "$root/$p" "$qdir/$p" 2>/dev/null; then
      printf '    %s (new, moved to %s)\n' "$p" "$qdir/$p" >> "$log"
      # Folders the move left empty go too, below the tier folders and unless a
      # file other than this one was in them before the pass.
      d="$(dirname "$p")"
      while case "$d" in */*) true ;; *) false ;; esac; do
        case " $REVERT_KEEP_DIRS " in *" $d "*) break ;; esac
        P="./$d/" SELF="./$p" awk '{ line = $0; sub(/^[^ ]* [^ ]* /, "", line) } index(line, ENVIRON["P"]) == 1 && line != ENVIRON["SELF"] { found = 1; exit } END { exit found ? 0 : 1 }' "$snap/before" && break
        rmdir "$root/$d" 2>/dev/null || break
        d="$(dirname "$d")"
      done
    else
      printf '    %s (new, and could not be moved to the quarantine)\n' "$p" >> "$log"
      rc=1
    fi
  fi
}

# paths_in_both <list-a> <list-b>
# Prints the lines of <list-b> that are also in <list-a>. The first list is told
# apart by FILENAME, not by NR == FNR, which an empty first list would make true
# for every line of the second.
paths_in_both() {
  awk 'FILENAME == ARGV[1] { seen[$0] = 1; next } ($0 in seen)' "$1" "$2"
}

# owned_predirty <owned-list> <predirty-list> <snap-dir> <log>
# Returns 2 after logging when a path the pass owns and changed already had
# uncommitted changes before the pass, else 0.
owned_predirty() {
  paths_in_both "$2" "$1" > "$3/owned-predirty"
  [ -s "$3/owned-predirty" ] || return 0
  printf '[%s] VIOLATION: the pass changed files that already had uncommitted changes before it started. The runner commits none of them and leaves them as they are:\n' "$(ts)" >> "$4"
  sed 's/^/    /' "$3/owned-predirty" >> "$4"
  return 2
}

# check_owned <root> <owned-list> <predirty-list> <snap-dir> <log>
# Returns 2 after logging when a path the pass owns and changed already had
# uncommitted changes before the pass (owned_predirty), or is no longer a regular
# file because the pass removed it or put a link or a folder in its place. Such a
# pass is put back rather than committed or recorded. Returns 0 otherwise.
check_owned() {
  local root="$1" owned="$2" p
  owned_predirty "$owned" "$3" "$4" "$5" || return 2
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -L "$root/$p" ] || [ ! -f "$root/$p" ]; then
      printf '[%s] VIOLATION: %s is not a regular file after the pass (removed, or replaced by a link or a folder), so nothing was committed.\n' "$(ts)" "$p" >> "$5"
      return 2
    fi
  done < "$owned"
  return 0
}

# unstage_paths <root> <empty-hooks-dir> <path...>
# Takes the paths back out of the index, also in a repository with no commit yet.
unstage_paths() {
  local root="$1" hooks="$2"
  shift 2
  if safe_git "$hooks" -C "$root" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    safe_git "$hooks" -C "$root" reset -q -- "$@" >/dev/null 2>&1
  else
    safe_git "$hooks" -C "$root" rm -q --cached --ignore-unmatch -- "$@" >/dev/null 2>&1
  fi
}

# index_blob <root> <rev-or-empty> <path>
# The blob id of a path in the index (empty rev) or in a commit. The revision is
# given relative to the vault folder, from inside it, and with MSYS path
# conversion off, because Git Bash would otherwise rewrite the argument.
index_blob() {
  ( cd "$1" && MSYS_NO_PATHCONV=1 GIT_TERMINAL_PROMPT=0 git rev-parse -q --verify "$2:./$3" 2>/dev/null )
}

# commit_owned <root> <pass-name> <owned-list> <predirty-list> <snap-dir> <log>
# Checks and commits the files a pass owns, with the trailers
#   Vault-Pass: <pass-name>
#   Vault-Pass-Blob: <blob id> <path>
# and then confirms each blob is what HEAD holds. The blob ids are taken before
# vault-check reads the files, and the staged content must match them, so a file
# that changes while it is checked is not committed. Returns 0 when they were
# committed or there was nothing to commit (not a repository of its own, nothing
# owned, every path ignored by git, or HEAD already holding them), 2 when a path
# was dirty before the pass or is not a regular file, 5 when vault-check rejects
# a note, and 4 when staging or the commit failed, which is logged with whether
# the paths could be taken back out of the index, or when a commit was made but
# HEAD does not hold the checked content. The agent's RUN_RC, RUN_TIMED_OUT,
# RUN_STALLED and RUN_KILL_FAILED are kept, because the git steps run under the
# same watchdog.
commit_owned() {
  local root="$1" pass="$2" owned="$3" predirty="$4" snap="$5" log="$6"
  local hooks="$5/nohooks" agent_rc="${RUN_RC:-0}" agent_timed_out="${RUN_TIMED_OUT:-0}" p blob got timeout step idx rc=0
  local agent_stalled="${RUN_STALLED:-0}" agent_kill_failed="${RUN_KILL_FAILED:-0}"
  local -a paths
  paths=()
  [ -s "$owned" ] || return 0
  if [ "${VAULT_GIT:-0}" -ne 1 ]; then
    printf '[%s] NOTE: %s, so the pass'"'"'s files were not committed.\n' "$(ts)" "${VAULT_GIT_NOTE:-the vault is not a git repository}" >> "$log"
    return 0
  fi
  check_owned "$root" "$owned" "$predirty" "$snap" "$log" || return 2
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if git_ignores "$root" "$hooks" "$p"; then
      printf '[%s] NOTE: %s is ignored by git, so it was not committed.\n' "$(ts)" "$p" >> "$log"
      continue
    fi
    paths+=("$p")
  done < "$owned"
  [ "${#paths[@]}" -gt 0 ] || return 0

  # The blob ids of the bytes about to be checked. Staging must produce the same
  # ones, or the file changed after it was checked.
  : > "$snap/commit-blobs"
  for p in "${paths[@]}"; do
    blob="$(safe_git "$hooks" -C "$root" hash-object -- "$p" 2>/dev/null)"
    [ -n "$blob" ] || blob=unknown
    printf 'Vault-Pass-Blob: %s %s\n' "$blob" "$p" >> "$snap/commit-blobs"
  done

  # The gate reads exactly the files about to be committed.
  if ! CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/vault-check.sh" -- "${paths[@]}" > "$snap/check.out" 2>&1; then
    printf '[%s] CHECK-FAILED: vault-check rejected the pass'"'"'s files, so none of them was committed:\n' "$(ts)" >> "$log"
    sed 's/^/    /' "$snap/check.out" >> "$log"
    return 5
  fi

  timeout="$(uint_setting RUNNER_GIT_TIMEOUT 120 1 "$log")"
  : > "$snap/git.out"
  printf '%s pass: %s\n\nVault-Pass: %s\n' "$pass" "${paths[*]}" "$pass" > "$snap/commit-msg"
  cat "$snap/commit-blobs" >> "$snap/commit-msg"
  for step in add commit; do
    if [ "$step" = add ]; then
      run_with_watchdog "$timeout" "$snap/git.out" env GIT_TERMINAL_PROMPT=0 $LITERAL_PATHS \
        git -C "$root" -c core.hooksPath="$hooks" -c core.fsmonitor=false add -- "${paths[@]}"
    else
      run_with_watchdog "$timeout" "$snap/git.out" env GIT_TERMINAL_PROMPT=0 $LITERAL_PATHS \
        git -C "$root" -c core.hooksPath="$hooks" -c core.fsmonitor=false commit -q --only --cleanup=verbatim -F "$snap/commit-msg" -- "${paths[@]}"
    fi
    RUN_PID=""
    if [ "$RUN_TIMED_OUT" -eq 1 ] || [ "$RUN_RC" -ne 0 ]; then
      if [ "$RUN_TIMED_OUT" -eq 1 ]; then
        printf '[%s] COMMIT-FAILED: git %s did not finish within %ss (RUNNER_GIT_TIMEOUT) and was stopped. The pass'"'"'s files are left uncommitted:\n' "$(ts)" "$step" "$timeout" >> "$log"
      else
        printf '[%s] COMMIT-FAILED: git %s exited %s. The pass'"'"'s files are left uncommitted:\n' "$(ts)" "$step" "$RUN_RC" >> "$log"
      fi
      printf '    %s\n' "${paths[@]}" >> "$log"
      sed 's/^/    git: /' "$snap/git.out" >> "$log"
      # A stopped git step that may still be running holds the lock like a
      # stopped pass, so the next pass cannot race it.
      [ "${RUN_KILL_FAILED:-0}" -eq 1 ] && mark_kill_failed "$log" "$RUN_KILL_REPORT"
      rc=4
    elif [ "$step" = add ]; then
      # Whole lines, so a name that ends in a space keeps it.
      while IFS= read -r got; do
        got="${got#Vault-Pass-Blob: }"
        blob="${got%% *}"
        p="${got#* }"
        [ "$blob" != unknown ] && [ "$(index_blob "$root" "" "$p")" = "$blob" ] || printf '%s\n' "$p"
      done < "$snap/commit-blobs" > "$snap/commit-mismatch"
      if [ -s "$snap/commit-mismatch" ]; then
        printf '[%s] COMMIT-FAILED: these files changed after vault-check read them, so they were not committed:\n' "$(ts)" >> "$log"
        sed 's/^/    /' "$snap/commit-mismatch" >> "$log"
        rc=4
      elif safe_git "$hooks" -C "$root" rev-parse -q --verify HEAD >/dev/null 2>&1 \
           && safe_git "$hooks" -C "$root" diff --cached --quiet -- "${paths[@]}" 2>/dev/null; then
        # HEAD already holds these files, for example after a sync plugin
        # committed them during the pass.
        printf '[%s] NOTE: HEAD already holds %s, so there was nothing to commit.\n' "$(ts)" "${paths[*]}" >> "$log"
        RUN_RC="$agent_rc"
        RUN_TIMED_OUT="$agent_timed_out"
        return 0
      fi
    fi
    if [ "$rc" -ne 0 ]; then
      unstage_paths "$root" "$hooks" "${paths[@]}"
      if [ -n "$(safe_git "$hooks" -C "$root" diff --cached --name-only -- "${paths[@]}" 2>/dev/null)" ]; then
        printf '[%s] WARNING: the files could not be taken back out of the index, so a plain git commit would include them. Run git reset -- on them once no git process is running.\n' "$(ts)" >> "$log"
      fi
      idx="$(git_index_lock_path "$root")"
      if [ -n "$idx" ] && [ -e "$idx" ]; then
        printf '[%s] WARNING: %s was left behind by the stopped git command. Remove it once no git process is running.\n' "$(ts)" "$idx" >> "$log"
      fi
      break
    fi
  done
  if [ "$rc" -eq 0 ]; then
    grep '^Vault-Pass-Blob: ' "$snap/commit-msg" | while IFS= read -r step; do
      step="${step#Vault-Pass-Blob: }"
      blob="${step%% *}"
      p="${step#* }"
      got="$(index_blob "$root" HEAD "$p")"
      if [ "$blob" = unknown ] || [ "$got" != "$blob" ]; then
        printf '%s\n' "$p"
      fi
    done > "$snap/commit-mismatch"
    if [ -s "$snap/commit-mismatch" ]; then
      printf '[%s] COMMIT-FAILED: the commit was made, but HEAD does not hold the checked content of these files, so its Vault-Pass-Blob trailers are wrong:\n' "$(ts)" >> "$log"
      sed 's/^/    /' "$snap/commit-mismatch" >> "$log"
      rc=4
    else
      printf '[%s] COMMITTED: %s\n' "$(ts)" "${paths[*]}" >> "$log"
    fi
  fi
  RUN_RC="$agent_rc"
  RUN_TIMED_OUT="$agent_timed_out"
  RUN_STALLED="$agent_stalled"
  RUN_KILL_FAILED="$agent_kill_failed"
  return "$rc"
}

# move_line_break_names <root> <quarantine-dir> <errors-out>
# Moves every path with a line break in its name to the quarantine as
# line-break-name-<n>, the outermost one of a nested set only, and lists each
# original path, quoted by printf %q, in names.txt beside them.
#
# They go into a folder made here with mkdir, which fails on anything already
# at that name, never into one that may exist. Containment has already moved
# the pass's planted links into the quarantine under their vault paths, and a
# link there named like the destination would carry the move out of it. find
# runs from inside the vault, so a vault reached through a symlinked path is
# searched too, and hands the names over NUL-separated, so no line is ever read
# as a path.
move_line_break_names() {
  local root="$1" qdir="$2" errors="$3" lbq i=0
  mkdir -p "$qdir" 2>/dev/null
  lbq="$qdir/line-break-names"
  while ! mkdir "$lbq" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 20 ]; then
      printf '%s (no new quarantine folder could be made for file names with a line break, so they are still in the vault)\n' "$LINE_BREAK_MARKER" >> "$errors"
      return 0
    fi
    lbq="$qdir/line-break-names.$i"
  done
  ( cd "$root" && LC_ALL=C find . -path "*$RUNNER_NL*" -prune -print0 2>/dev/null ) | {
    n=0
    while IFS= read -r -d '' f; do
      n=$((n + 1))
      if mv -f "$root/${f#./}" "$lbq/line-break-name-$n" 2>/dev/null; then
        printf 'line-break-name-%s %q\n' "$n" "${f#./}" >> "$lbq/names.txt"
      else
        printf '%s (a file name with a line break could not be moved to the quarantine, so it is still in the vault)\n' "$LINE_BREAK_MARKER" >> "$errors"
      fi
    done
  }
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
  if ! contain_steering_changes "$root" "$snap/changed" "$snap/steering.tar" "$qdir" "$snap/contained" "$snap/contain-errors" \
       "$snap/before" "$snap/after"; then
    : > "$snap/contained"
  fi
  if grep -qxF "$LINE_BREAK_MARKER" "$snap/contained" 2>/dev/null; then
    move_line_break_names "$root" "$qdir" "$snap/contain-errors"
    reason="$reason, including a file name with a line break"
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
    printf '[%s] TRIPWIRE-ERROR: containment ran but no tripwire could be written. Treat the vault as unverified. The contained paths follow.\n' "$(ts)" >> "$log"
    sed 's/^/    /' "$snap/contained" >> "$log"
    return 70
  fi
  CONTAINED=1
  printf '[%s] VIOLATION: steering or execution surfaces changed during the run. They were contained (quarantine %s) and the tripwire is set. The paths follow.\n' "$(ts)" "$qdir" >> "$log"
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
#                        A stop reaches the wrapper's children too (stop_tree),
#                        but `exec` the harness anyway. On Windows a harness
#                        that starts its own detached processes is found only
#                        when they carry VAULT_RUN_NONCE on their command line.
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
        printf '[%s] REFUSED: VAULT_AGENT=command cannot enforce the agent'"'"'s tool allowlist. Sandbox the wrapper (no shell, no network), then set VAULT_ALLOW_UNENFORCED_TOOLS=1.\n' \
          "$(ts)" >> "$log"
        return 3
      fi
      AGENT_BIN="${VAULT_AGENT_CMD:-}"
      if [ -z "$AGENT_BIN" ] || ! command -v "$AGENT_BIN" >/dev/null 2>&1; then
        printf '[%s] ERROR: VAULT_AGENT=command but VAULT_AGENT_CMD is unset or not an executable (got "%s").\n' \
          "$(ts)" "$AGENT_BIN" >> "$log"
        return 127
      fi
      printf '[%s] WARNING: command mode (%s). The tool allowlist is NOT enforced by this runner, which relies on the wrapper'"'"'s sandbox and the snapshot fence.\n' \
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

# ---------------------------------------------------------------------------
# Progress watchdog.
#
# A pass that hangs without exiting holds the run lock until its wall-clock
# timeout, which is hours. In claude mode the agent streams one JSON event per
# line, so a pass that is working keeps its output growing, and one whose output
# stops growing for the stall threshold is stopped early with exit 125.
#
# The threshold is the floor (RUNNER_STALL_FLOOR, 10 minutes) until the runner
# has measured at least STALL_MIN_RUNS passes that ended OK. From then on it is
# 1.5 times the 99th percentile of those passes' longest silent stretches, and
# never below the floor. Each start logs the threshold and where it came from.
# RUNNER_STALL_SECONDS sets it outright, and 0 turns stall detection off. In
# command mode the harness's output is unknown, so stall detection is off unless
# RUNNER_STALL_SECONDS is set.

STALL_MIN_RUNS=3

# stall_plan <state-dir> <runner> <log>
# Sets AGENT_STALL_SECONDS and AGENT_STALL_NOTE, the threshold and a phrase
# saying where it came from.
stall_plan() {
  local state="$1" runner="$2" log="$3" floor file runs n p99 t
  floor="$(uint_setting RUNNER_STALL_FLOOR 600 1 "$log")"
  if [ -n "${RUNNER_STALL_SECONDS:-}" ]; then
    if AGENT_STALL_SECONDS="$(uint_setting RUNNER_STALL_SECONDS "" 0 /dev/null)" && [ -n "$AGENT_STALL_SECONDS" ]; then
      AGENT_STALL_NOTE="set by RUNNER_STALL_SECONDS"
      [ "$AGENT_STALL_SECONDS" -eq 0 ] && AGENT_STALL_NOTE="off, because RUNNER_STALL_SECONDS is 0"
      return 0
    fi
    # A value that is not a whole number counts as unset, so command mode stays
    # off and claude mode keeps its measured threshold.
    printf '[%s] WARNING: RUNNER_STALL_SECONDS="%s" is not a whole number of seconds, so it is ignored.\n' "$(ts)" "$RUNNER_STALL_SECONDS" >> "$log"
  fi
  if [ "${AGENT_KIND:-claude}" != claude ]; then
    AGENT_STALL_SECONDS=0
    AGENT_STALL_NOTE="off in command mode unless RUNNER_STALL_SECONDS is set"
    return 0
  fi
  file="$state/$runner.stream-gaps"
  runs="$(awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { seen[$1] = 1 } END { n = 0; for (k in seen) n++; print n }' "$file" 2>/dev/null)"
  is_uint "${runs:-}" || runs=0
  if [ "$runs" -lt "$STALL_MIN_RUNS" ]; then
    AGENT_STALL_SECONDS="$floor"
    AGENT_STALL_NOTE="the floor, because $runs of the $STALL_MIN_RUNS passes needed to measure one are recorded"
    return 0
  fi
  # Each pass counts once, by its longest silence, so the many short gaps of a
  # streaming pass cannot hide the long ones. An older record with a line per
  # gap reduces to the same thing.
  awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && length($2) <= 9 { if (!($1 in m) || $2 + 0 > m[$1] + 0) m[$1] = $2 }
    END { for (r in m) print m[r] }' "$file" | LC_ALL=C sort -n > "$file.longest.$$" 2>/dev/null
  n="$(awk 'END { print NR }' "$file.longest.$$" 2>/dev/null)"
  p99="$(awk -v n="${n:-0}" 'BEGIN { k = int((n * 99 + 99) / 100); if (k < 1) k = 1 } NR == k { print; exit }' "$file.longest.$$" 2>/dev/null)"
  rm -f "$file.longest.$$"
  is_uint "${p99:-}" && [ "${#p99}" -le 9 ] || p99=0
  t=$(( (p99 * 3 + 1) / 2 ))
  if [ "$t" -lt "$floor" ]; then
    AGENT_STALL_SECONDS="$floor"
    AGENT_STALL_NOTE="the floor, above 1.5 times the p99 of each pass's longest silence, ${p99}s over $runs recorded passes"
  else
    AGENT_STALL_SECONDS="$t"
    AGENT_STALL_NOTE="1.5 times the p99 of each pass's longest silence, ${p99}s over $runs recorded passes"
  fi
}

# record_stream_gaps <state-dir> <runner> <gaps-file>
# Adds the longest silent stretch of a pass that ended OK to the runner's record,
# one line per pass, which keeps the latest 5000 passes.
record_stream_gaps() {
  local file="$1/$2.stream-gaps" run longest
  [ -s "$3" ] || return 0
  longest="$(awk '/^[0-9]+$/ && length($0) <= 9 { if ($0 + 0 > m + 0) m = $0 } END { if (m != "") print m }' "$3")"
  is_uint "${longest:-}" || return 0
  run="$(date +%s)"
  printf '%s %s\n' "$run" "$longest" >> "$file" 2>/dev/null || return 0
  tail -n 5000 "$file" > "$file.new" 2>/dev/null && mv -f "$file.new" "$file" 2>/dev/null
}

# record_runner_session <state-dir> <runner> <output-file> <offset> <session-id> <log>
# Appends "<time> <runner> <session id> <confirmed|unconfirmed|differs:<id>>",
# tab-separated, to runner-sessions.tsv in the state directory, so a later
# capture of Claude Code sessions can leave out the runners' own. The id is the
# one the runner chose, and the stream's init event after <offset> bytes of the
# output confirms it. A missing or different id is logged.
record_runner_session() {
  local state="$1" runner="$2" out="$3" offset="$4" id="$5" log="$6" seen status
  is_uint "$offset" || offset=0
  seen="$(tail -c +"$((offset + 1))" "$out" 2>/dev/null | grep '"subtype":"init"' | grep '"type":"system"' \
    | sed -n 's/.*"session_id":"\([0-9A-Fa-f-]*\)".*/\1/p' | head -n 1)"
  if [ -z "$seen" ]; then
    status=unconfirmed
    printf '[%s] WARNING: the stream has no init event naming the session, so session %s is recorded unconfirmed.\n' "$(ts)" "$id" >> "$log"
  elif [ "$seen" = "$id" ]; then
    status=confirmed
  else
    status="differs:$seen"
    printf '[%s] WARNING: the stream names session %s, not the %s the runner chose. Both are recorded.\n' "$(ts)" "$seen" "$id" >> "$log"
  fi
  printf '%s\t%s\t%s\t%s\n' "$(ts)" "$runner" "$id" "$status" >> "$state/runner-sessions.tsv" 2>/dev/null \
    || printf '[%s] WARNING: could not record session %s in %s.\n' "$(ts)" "$id" "$state/runner-sessions.tsv" >> "$log"
}

# append_run_log <run-file> <run-log> <log>
# Adds a pass's output, which the runner kept outside the vault while the pass
# ran, to the pass's run log in .claude/logs. Called after containment, because
# the pass may have put a link or something other than a file where the run log
# was. It writes only to a regular file or a new one, never through a link, and
# cuts a run log larger than RUNNER_RUN_LOG_MAX_BYTES (default 10000000) to its
# newest part, because the stream holds every event of every pass.
append_run_log() {
  local run="$1" out="$2" log="$3" max size
  [ ! -L "$out" ] && { [ -f "$out" ] || [ ! -e "$out" ]; } || return 0
  cat "$run" >> "$out" 2>/dev/null || return 0
  max="$(uint_setting RUNNER_RUN_LOG_MAX_BYTES 10000000 1000 "$log")"
  size="$(file_size "$out")"
  if [ "$size" -gt "$max" ]; then
    tail -c "$max" "$out" > "$out.tmp.$$" 2>/dev/null && mv -f "$out.tmp.$$" "$out" 2>/dev/null
    rm -f "$out.tmp.$$" 2>/dev/null
  fi
  return 0
}

# report_stop <log> <what> <root> <state-dir> <runner>
# After the watchdog stopped a pass, logs a leftover index.lock. When a process
# of the pass may still be running, it marks the run lock and sets the tripwire,
# because that process can write after containment has checked the vault.
report_stop() {
  local log="$1" what="$2" root="$3" state="$4" runner="$5" idx list
  idx="$(git_index_lock_path "$root")"
  if [ -n "$idx" ] && [ -e "$idx" ]; then
    printf '[%s] WARNING: %s was left behind by the stopped %s. Remove it once no git process is running.\n' "$(ts)" "$idx" "$what" >> "$log"
  fi
  if [ "${RUN_KILL_FAILED:-0}" -eq 1 ]; then
    mark_kill_failed "$log" "$RUN_KILL_REPORT"
    list="$(mktemp 2>/dev/null || mktemp -t killfailed)" || list=""
    if [ -n "$list" ]; then
      printf '%s\n' "$RUN_KILL_REPORT" > "$list"
      if [ -f "$root/$TRIPWIRE_REL" ] || [ -f "$state/$(basename "$TRIPWIRE_REL")" ]; then
        # Containment set the tripwire already. Its list stays, and this is added.
        for idx in "$root/$TRIPWIRE_REL" "$state/$(basename "$TRIPWIRE_REL")"; do
          [ -f "$idx" ] && [ ! -L "$idx" ] || continue
          { printf '\nAlso, a process of the stopped %s may still be running, so what it writes after containment is unchecked. End it, then review the vault. What the stop found:\n' "$what"
            sed 's/^/  /' "$list"; } >> "$idx" 2>/dev/null
        done
      elif ! write_tripwire "$root" "$state" "$runner" \
           "a process of the stopped $what may still be running, so what it writes after containment is unchecked. End it, then review the vault" \
           "(none moved)" "$list"; then
        printf '[%s] TRIPWIRE-ERROR: no tripwire could be written for the KILL_FAILED stop. The run lock is still marked.\n' "$(ts)" >> "$log"
      fi
      rm -f "$list"
    fi
  fi
}

# run_agent <timeout> <output-file> <agent-name> <task> <prompt-file-relative>
#
# Starts the agent chosen by agent_preflight under the watchdog, with
# AGENT_STALL_SECONDS as its stall threshold, AGENT_GAPS_FILE collecting its
# silent stretches, and AGENT_SESSION_ID as its session id and kill nonce. The
# prompt file path is RELATIVE to the vault root, which is the working
# directory: an absolute Git Bash path such as /c/Users/... would reach a
# Windows wrapper only if MSYS path conversion happened to rewrite it.
run_agent() {
  local timeout="$1" out="$2" agent="$3" task="$4" prompt_rel="$5"
  local stall="${AGENT_STALL_SECONDS:-0}" gaps="${AGENT_GAPS_FILE:-}" nonce="${AGENT_SESSION_ID:-}"
  [ -n "$nonce" ] || nonce="$(new_uuid)"
  AGENT_SESSION_ID="$nonce"
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
      #
      # Neither agent's allowlist names a tool that runs commands. --disallowedTools
      # denies Bash, PowerShell (which Claude Code offers on Windows) and Monitor
      # (which runs a command in the background) again on the command line, so a
      # definition edited to add one still gets no shell. Claude Code accepts a
      # name it does not offer, so the same list works on every platform. It
      # comes last because it takes a list, which would otherwise swallow the
      # prompt.
      #
      # The stream flags make progress visible to the watchdog. Claude Code
      # 2.1.272 refuses stream-json under -p without --verbose. The session id is
      # chosen here, so it is known even when the stream never names it, and it
      # is on the command line where the Windows stop can find the process.
      export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1
      RUN_STALL_SECONDS="$stall" RUN_GAPS_FILE="$gaps" RUN_NONCE="$nonce" run_with_watchdog "$timeout" "$out" \
        "$AGENT_BIN" -p "$task" --agent "$agent" --permission-mode acceptEdits \
        --output-format stream-json --verbose --include-partial-messages --session-id "$nonce" \
        --disallowedTools Bash PowerShell Monitor
      ;;
    command)
      # The wrapper gets the nonce in its environment. Only a process that puts
      # it on its own command line can be found by the Windows sweep.
      VAULT_RUN_NONCE="$nonce" RUN_STALL_SECONDS="$stall" RUN_GAPS_FILE="$gaps" RUN_NONCE="$nonce" \
        run_with_watchdog "$timeout" "$out" "$AGENT_BIN" "$prompt_rel"
      ;;
    *)
      # agent_preflight rejects any other kind first. Set the globals anyway,
      # so a future caller that skips it fails with a status, not set -u.
      RUN_RC=64
      RUN_TIMED_OUT=0
      RUN_STALLED=0
      RUN_KILL_FAILED=0
      RUN_KILL_REPORT=""
      ;;
  esac
}
