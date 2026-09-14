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
# info/refs. HEAD and refs are NOT fenced, because a pass may commit (the
# promotion agent takes a snapshot) and a human may commit while it runs. A
# rewound HEAD is caught separately (head_moved_backwards). For a worktree vault,
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
  } | grep -v '^\.git-common' | LC_ALL=C sort -u | awk '
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
RUNNER_UNAME="$(uname -s 2>/dev/null)"
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
      if [ -z "$o_nonce" ]; then
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

# ---------------------------------------------------------------------------
# Runner commits.
#
# The runner commits a pass's output itself, and only the exact files the
# snapshot diff says the pass changed in the areas it owns. It never stages
# everything. A file that already had uncommitted changes before the pass
# belongs to whoever was editing it, so a pass that changes one commits nothing.
# Every other dirty or staged file is left as it was. The commit runs the vault's
# own hooks, which containment has just shown to be the pre-pass ones, under a
# watchdog, because a signing prompt or a hung hook must not stall a scheduled
# run.

# git_preflight <root> <empty-hooks-dir> <log>
# Sets VAULT_GIT to 1 when the vault is inside a git work tree, else to 0.
# Returns 75 after logging when a merge, rebase, cherry-pick, revert or bisect
# is in progress, or HEAD is detached, because a commit would then land where the
# owner did not choose.
git_preflight() {
  local root="$1" hooks="$2" log="$3" gd op
  VAULT_GIT=0
  command -v git >/dev/null 2>&1 || return 0
  [ "$(safe_git "$hooks" -C "$root" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || return 0
  VAULT_GIT=1
  gd="$(safe_git "$hooks" -C "$root" rev-parse --absolute-git-dir 2>/dev/null)"
  if [ -z "$gd" ]; then
    printf '[%s] LOCKED: git did not name this vault'"'"'s git directory, so a git operation in progress cannot be ruled out. Not starting.\n' "$(ts)" >> "$log"
    return 75
  fi
  for op in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
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
# Writes the vault-relative path of every file git reports as modified, staged,
# untracked or conflicted, and both sides of a rename or copy, sorted. Returns 1
# when git status fails, because an unknown dirty set could let a pass commit
# over someone's edit.
git_dirty_paths() {
  local root="$1" hooks="$2" out="$3" prefix
  prefix="$(safe_git "$hooks" -C "$root" rev-parse --show-prefix 2>/dev/null)" || return 1
  if ! safe_git "$hooks" -C "$root" status --porcelain -z --untracked-files=all > "$out.raw" 2>/dev/null; then
    rm -f "$out.raw"
    return 1
  fi
  # Porcelain paths are relative to the top of the repository, which is above
  # the vault when the vault is a folder inside a larger repository.
  tr '\0' '\n' < "$out.raw" | awk -v pre="$prefix" '
    function emit(p) {
      if (pre == "") print p
      else if (substr(p, 1, length(pre)) == pre) print substr(p, length(pre) + 1)
    }
    from { from = 0; emit($0); next }
    {
      emit(substr($0, 4))
      if (substr($0, 1, 2) ~ /[RC]/) from = 1
    }' | LC_ALL=C sort -u > "$out"
  rm -f "$out.raw"
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
  printf '[%s] VIOLATION: the pass changed files that already had uncommitted changes before it started. Nothing was committed, and the files are left as they are:\n' "$(ts)" >> "$4"
  sed 's/^/    /' "$3/owned-predirty" >> "$4"
  return 2
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
# and then confirms each blob is what HEAD holds. Returns 0 when they were
# committed or there was nothing to commit (not a git vault, nothing owned, or
# every path ignored by git), 2 when a path was dirty before the pass or is not a
# regular file, 5 when vault-check rejects a note, and 4 when staging or the
# commit failed, after taking the paths back out of the index. The agent's
# RUN_RC and RUN_TIMED_OUT are kept, because the git steps run under the same
# watchdog.
commit_owned() {
  local root="$1" pass="$2" owned="$3" predirty="$4" snap="$5" log="$6"
  local hooks="$5/nohooks" agent_rc="${RUN_RC:-0}" agent_timed_out="${RUN_TIMED_OUT:-0}" p blob got timeout step idx rc=0
  local -a paths
  paths=()
  [ -s "$owned" ] || return 0
  if [ "${VAULT_GIT:-0}" -ne 1 ]; then
    printf '[%s] NOTE: the vault is not a git repository, so the pass'"'"'s files were not committed.\n' "$(ts)" >> "$log"
    return 0
  fi
  owned_predirty "$owned" "$predirty" "$snap" "$log" || return 2
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -L "$root/$p" ] || [ ! -f "$root/$p" ]; then
      printf '[%s] VIOLATION: %s is not a regular file after the pass (removed, or replaced by a link or a folder), so nothing was committed.\n' "$(ts)" "$p" >> "$log"
      return 2
    fi
    if safe_git "$hooks" -C "$root" check-ignore -q -- "$p" 2>/dev/null; then
      printf '[%s] NOTE: %s is ignored by git, so it was not committed.\n' "$(ts)" "$p" >> "$log"
      continue
    fi
    paths+=("$p")
  done < "$owned"
  [ "${#paths[@]}" -gt 0 ] || return 0

  # The gate reads exactly the files about to be committed.
  if ! CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/vault-check.sh" -- "${paths[@]}" > "$snap/check.out" 2>&1; then
    printf '[%s] CHECK-FAILED: vault-check rejected the pass'"'"'s files, so they were not committed. They are left in place for review:\n' "$(ts)" >> "$log"
    sed 's/^/    /' "$snap/check.out" >> "$log"
    return 5
  fi

  timeout="$(uint_setting RUNNER_GIT_TIMEOUT 120 1 "$log")"
  : > "$snap/git.out"
  for step in add commit; do
    if [ "$step" = add ]; then
      run_with_watchdog "$timeout" "$snap/git.out" env GIT_TERMINAL_PROMPT=0 \
        git -C "$root" -c core.fsmonitor=false add -- "${paths[@]}"
    else
      {
        printf '%s pass: %s\n\nVault-Pass: %s\n' "$pass" "${paths[*]}" "$pass"
        for p in "${paths[@]}"; do
          blob="$(index_blob "$root" "" "$p")"
          [ -n "$blob" ] || blob=unknown
          printf 'Vault-Pass-Blob: %s %s\n' "$blob" "$p"
        done
      } > "$snap/commit-msg"
      run_with_watchdog "$timeout" "$snap/git.out" env GIT_TERMINAL_PROMPT=0 \
        git -C "$root" -c core.fsmonitor=false commit -q --only -F "$snap/commit-msg" -- "${paths[@]}"
    fi
    if [ "$RUN_TIMED_OUT" -eq 1 ] || [ "$RUN_RC" -ne 0 ]; then
      if [ "$RUN_TIMED_OUT" -eq 1 ]; then
        printf '[%s] COMMIT-FAILED: git %s did not finish within %ss (RUNNER_GIT_TIMEOUT) and was stopped. The pass'"'"'s files are left uncommitted and unstaged:\n' "$(ts)" "$step" "$timeout" >> "$log"
      else
        printf '[%s] COMMIT-FAILED: git %s exited %s. The pass'"'"'s files are left uncommitted and unstaged:\n' "$(ts)" "$step" "$RUN_RC" >> "$log"
      fi
      printf '    %s\n' "${paths[@]}" >> "$log"
      sed 's/^/    git: /' "$snap/git.out" >> "$log"
      unstage_paths "$root" "$hooks" "${paths[@]}"
      idx="$(git_index_lock_path "$root")"
      if [ -n "$idx" ] && [ -e "$idx" ]; then
        printf '[%s] WARNING: %s was left behind by the stopped git command. Remove it once no git process is running.\n' "$(ts)" "$idx" >> "$log"
      fi
      rc=4
      break
    fi
  done
  RUN_PID=""
  if [ "$rc" -eq 0 ]; then
    grep '^Vault-Pass-Blob: ' "$snap/commit-msg" | while IFS=' ' read -r step blob p; do
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
  return "$rc"
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
