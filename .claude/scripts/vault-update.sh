#!/usr/bin/env bash
# .claude/scripts/vault-update.sh
#
# Tells you which template version this vault came from, what you have changed
# since, and what has moved in a newer copy of the template that you fetched
# yourself.
#
# REPORT ONLY, with one exception. The only file this script ever writes is
# .claude/template-manifest, and only under --adopt and --generate. It never
# replaces a hook, a rule, a doc or a note. Adopting a change is a human act
# here for the same reason resolving a contradiction between two notes is. A
# half-merged hook is worse than a refused one, and this repository already
# holds the rule that a checker reports rather than repairs.
#
# IT NEVER REACHES THE NETWORK, and it never executes anything out of the
# directory you point it at. --from is a folder you obtained yourself, with
# git clone or a browser download, using tools you already trust. This reads
# bytes out of it and hashes them. It does not source it, run it, or evaluate a
# line of it, including that folder's own copy of this script.
#
# Usage:
#   vault-update.sh --status                 what this vault carries, offline
#   vault-update.sh --check --from <dir>     what moved, and what is safe to take
#   vault-update.sh --diff  --from <dir>     the changes themselves
#   vault-update.sh --adopt --from <dir>     record a baseline in a vault with none
#   vault-update.sh --generate               maintainer, rewrites the manifest
#   vault-update.sh --verify-manifest        maintainer and CI, fails on drift
#   vault-update.sh --help
#
# Exit:
#    0  it could look, and there is nothing to adopt
#   10  it could look, and there IS something to adopt, or --status found drift
#    2  it could NOT look, so it is saying nothing about the template
#    1  this vault has a problem. The manifest disagrees with itself, or
#       --verify-manifest found the manifest stale
#   11  refused because of the state of the vault rather than the command line.
#       --adopt where a baseline already exists
#    6  a manifest entry names a path outside the vault
#   64  the command line was wrong
#   75  a scheduled pass is in flight, so nothing was done
#   78  a scheduled pass set the tripwire, so nothing was done
#
# Why 11 and not 3 for a refusal about the state of the vault. The retention
# runner already spends 3 on a partial pass, and docs/reference.md publishes one
# numbering across all four scripts precisely so that a caller reading a code
# does not have to know which of them it ran. Two scripts answering 3 with two
# unrelated meanings is the one thing that numbering exists to prevent, so this
# refusal sits next to the 10 above it, in the range only this script spends.
#
# Why 10 and not 1. vault-check.sh spends twenty lines establishing that 1 means
# the vault has a problem and 2 means the checker could not run, because those
# two want opposite responses, and docs/reference.md publishes it. A template
# release being available is not a problem with your vault, and docs/
# customizing.md actively invites the edits that produce local drift, so a
# correctly customized vault would sit on exit 1 for ever and nobody could put
# this in a gate. Folding it into 0 instead would leave "up to date" and "an
# update exists" sharing one answer, and those are two answers. A number this
# repository does not yet spend keeps all three apart and collides with nothing.
#
# 75 for a pass in flight, because all three runners already use 75 for exactly
# that. The point of the numbering is that a caller reading a code does not have
# to know which of the scripts it called.
#
# Read the counts line rather than matching the wording around it:
#   vault-update: 7 moved upstream, 2 also changed here, 5 safe to take ...

set -u

# Every range in a shell pattern below is meant as ASCII. bash 5 holds them there
# with globasciiranges, which it sets by default, but bash 3.2 predates the option
# and macOS ships 3.2 as /bin/bash. Under a UTF-8 collation there a byte above
# 0x7f can fall inside A-Za-z, so a negated class stops rejecting it, the path is
# written into the manifest, and every downstream vault then refuses the whole
# manifest because the reader's awk does pin the locale. Pinning the locale here
# is what keeps the writer and the reader agreeing about what a path may contain.
#
# LC_ALL rather than LC_COLLATE, which is what this used to set and which was a
# no-op for anyone with LC_ALL exported at all, because LC_ALL overrides every
# individual category. The three runners beside this script each reached that
# conclusion already and each carries a comment saying so, and the case patterns
# this protects are on the WRITER side while the reader's awk pins LC_ALL on
# every invocation. So the half that was unprotected was the half that decides
# what gets shipped. Nothing here reads a translated message, because what it
# parses is paths, digests and version numbers.
LC_ALL=C
export LC_ALL

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
RULES_REL=".claude/manifest-rules"
MANIFEST_REL=".claude/template-manifest"
VERSION_REL="VERSION"
HASH_ALGO="sha256"

# The probe string and its SHA-256, used to ask each candidate hashing tool
# whether it actually works rather than whether it is on PATH. shasum is a perl
# script and can be present and unable to start, and cksum -a sha256 only exists
# in coreutils 9 and later, so the binary being there proves nothing about the
# option. A functional probe is a positive control, which is the discipline the
# rest of this repository already applies to its own instruments.
HASH_PROBE="vault-update probe"
HASH_PROBE_DIGEST="f67809800160c86cb48e4ff916b49e2a050d95689987373cfd9ba9797893b64d"

say()  { printf 'vault-update: %s\n' "$1"; }
warn() { printf 'vault-update: %s\n' "$1" >&2; }

# WHERE THIS TEMPLATE IS ALLOWED TO SHIP MACHINERY. Everything else a manifest
# calls owned is forced back to the owner's, whatever the manifest says.
#
# This is an ALLOWLIST, and it replaced a denylist of the content tiers. The
# denylist answered the wrong question. It asked where the owner's files live,
# which is unbounded and unknowable, so everything outside the tier folders was
# machinery by default and a source manifest could name any path the tiers did
# not cover. The sharpest instance was .github/workflows/pwn.yml, which is not
# under a tier, is not one of the owner's folders, and would have been printed
# in the copy plan under "safe to take" - after which a paste installs a
# workflow that runs unattended on GitHub's runners with that repository's
# secrets. .claude/manifest-rules names that exact outcome as the reason those
# paths are excluded, so the writer refused to generate them while the reader
# accepted them, which is the same asymmetry path_is_writable_to_a_manifest was
# added to close, one artefact along. .vscode/tasks.json and
# .devcontainer/devcontainer.json are the same shape and both auto-execute.
#
# The question an allowlist asks instead is where the TEMPLATE may ship
# machinery, which is short, knowable, and ours to state. A release that adds a
# machinery root an older script has never heard of is narrowed by that older
# script and warned about rather than offered, which is the fail-closed
# direction, and the owner can still copy it by hand.
#
# It also makes the tier names irrelevant to this decision, so a vault that
# renamed a tier is protected without the tool having to learn the new name.
#
# Compared with case folded, because Windows and macOS fold it for you when the
# copy plan is pasted.
MACHINERY_ROOTS=".agents/ .claude/ .codex/ .cursor/ .gemini/ .windsurf/ docs/ .github/hooks/"
MACHINERY_FILES="agents.md changelog.md claude.md license version .aider.conf.yml .cursorignore .geminiignore .gitattributes .gitignore opencode.json"

usage() {
  cat <<'USAGE'
vault-update.sh - which template version this vault carries, and what has moved.

  --status                  What this vault carries and what you have changed.
                            Needs no source folder, no network and no git.
  --check --from <dir>      Compare against a template copy you fetched
                            yourself. Names what moved and what is safe to take.
  --diff --from <dir>       The changes themselves, file by file.
  --adopt --from <dir>      Record a baseline in a vault created before this
                            mechanism existed. Writes only the manifest.
  --generate                Maintainer only. Rewrites the manifest from the
                            rules. Needs VAULT_TEMPLATE_MAINTAINER=1.
  --verify-manifest         Maintainer only. Fails when the manifest has
                            drifted from the tree. Needs
                            VAULT_TEMPLATE_MAINTAINER=1, because it rebuilds
                            from the whole tracked tree and so reads your notes.
  --help                    This text.

Three environment variables, for when a tool this leans on is the problem.
  VAULT_HASH_TOOL=<name>    Force one candidate: sha256sum, shasum, openssl or
                            cksum-sha256. Useful when one of them is broken.
  VAULT_FORCE_NO_SHA=1      Refuse to hash at all, to see the could-not-look
                            answer on purpose.
  VAULT_FORCE_NO_DIFF=1     Take the no-diff-tool path under --diff even where
                            git or diff is installed, for the same reason.

This never reaches the network and never runs anything out of <dir>. Fetch a
template copy with git clone or a browser download, then point --from at it.
USAGE
}

die_usage() {  # die_usage <message>
  warn "$1"
  warn "run vault-update.sh --help for the shapes this accepts."
  exit 64
}

# --------------------------------------------------------------- refusals --

# The tripwire test is re-implemented here rather than borrowed. The runners'
# tripwire_check has side effects, turning a leftover in-flight marker into a
# tripwire, and a read-only checker must never do that. vault-check.sh does the
# same thing for the same reason, and sources the library in a SUBSHELL for one
# pure function so that none of the runners' contract lands in this shell.
STATE_DIR=""
RUNNER_LIB="$(dirname "$0")/lib/runner-common.sh"
if [ -f "$RUNNER_LIB" ]; then
  STATE_DIR="$( . "$RUNNER_LIB" && vault_state_dir "$ROOT" )"
fi
if [ -z "$STATE_DIR" ]; then
  warn "WARNING - the runners' state directory could not be worked out from $RUNNER_LIB, so the copies of the tripwire and the in-flight marker kept there were not checked."
fi

guard_present() {  # guard_present <name-under-.claude/logs>
  local v="$ROOT/.claude/logs/$1" s=""
  [ -n "$STATE_DIR" ] && s="$STATE_DIR/$1"
  # -L as well as -e, because a dangling symlink planted at the path is not -e
  # and must not read as "nothing is there".
  if [ -e "$v" ] || [ -L "$v" ]; then return 0; fi
  if [ -n "$s" ] && { [ -e "$s" ] || [ -L "$s" ]; }; then return 0; fi
  return 1
}

refuse_if_held() {
  if guard_present runner-tripwire; then
    warn "TRIPWIRE - a scheduled pass changed a steering or execution surface, was interrupted before containment, or may have left a process running."
    warn "Read the tripwire and do what it says, then delete it and its copy. Nothing was compared and the source folder was never opened."
    exit 78
  fi
  if guard_present runner-inflight; then
    warn "PASS-IN-FLIGHT - a scheduled pass is running, so this stopped before reading anything. Run it again once the pass has finished."
    exit 75
  fi
}

# ---------------------------------------------------------------- hashing --

HASH_TOOL=""

# The digest is the field that is exactly 64 lower-case hex characters, and only
# when exactly ONE field on the line looks like that. Taking the first match
# would let a future output shape parse to the same non-hash literal on both
# sides of a comparison, every file would then compare equal, and the tool would
# conclude a vault was untouched when it was not. A parse failure must never be
# able to produce "identical".
#
# The length is tested rather than written as an interval, and the hex
# characters are spelled out rather than written as a range, because the awk
# macOS ships has no interval repetition and a range follows whatever collating
# order the ambient locale happens to have.
hex_digest() {
  LC_ALL=C awk '
    {
      sub(/\r$/, "")
      n = 0
      for (i = 1; i <= NF; i++) {
        if (length($i) == 64 && $i ~ /^[0123456789abcdef]*$/) { h = $i; n++ }
      }
      if (n == 1 && !found) { print h; found = 1 }
    }
    END { if (!found) exit 1 }
  '
}

run_hash_tool() {  # run_hash_tool <tool> <file>...
  local tool="$1"
  shift
  case "$tool" in
    sha256sum)    sha256sum "$@" 2>/dev/null ;;
    shasum)       shasum -a 256 "$@" 2>/dev/null ;;
    openssl)      openssl dgst -sha256 "$@" 2>/dev/null ;;
    cksum-sha256) cksum -a sha256 "$@" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

hash_stdin_with() {  # hash_stdin_with <tool>
  case "$1" in
    sha256sum)    sha256sum 2>/dev/null ;;
    shasum)       shasum -a 256 2>/dev/null ;;
    openssl)      openssl dgst -sha256 2>/dev/null ;;
    cksum-sha256) cksum -a sha256 2>/dev/null ;;
    *) return 1 ;;
  esac
}

tool_binary() {  # tool_binary <tool>
  case "$1" in
    sha256sum) printf 'sha256sum' ;;
    shasum) printf 'shasum' ;;
    openssl) printf 'openssl' ;;
    cksum-sha256) printf 'cksum' ;;
  esac
}

pick_hash_tool() {
  local candidate got
  if [ -n "${VAULT_FORCE_NO_SHA:-}" ]; then
    HASH_TOOL=""
    return 1
  fi
  # The override is checked against the four names before it is used, because
  # the loop below has to leave its word unquoted so that the default splits
  # into four candidates, and an unquoted word is also a glob. VAULT_HASH_TOOL
  # set to a star would expand against the working directory and hand whatever
  # it found to command -v, which is a lot of behaviour to reach through a
  # variable whose documented job is to name one of four tools.
  if [ -n "${VAULT_HASH_TOOL:-}" ]; then
    case "$VAULT_HASH_TOOL" in
      sha256sum|shasum|openssl|cksum-sha256) ;;
      *)
        warn "HASH-TOOL-UNKNOWN - VAULT_HASH_TOOL names [$VAULT_HASH_TOOL] and the four this understands are sha256sum, shasum, openssl and cksum-sha256, so nothing was hashed."
        HASH_TOOL=""
        return 1
        ;;
    esac
    candidate="$VAULT_HASH_TOOL"
    if command -v "$(tool_binary "$candidate")" >/dev/null 2>&1; then
      got="$(printf '%s' "$HASH_PROBE" | hash_stdin_with "$candidate" | hex_digest)" || got=""
      if [ "$got" = "$HASH_PROBE_DIGEST" ]; then
        HASH_TOOL="$candidate"
        return 0
      fi
      warn "HASH-PROBE - $candidate did not return the expected digest for a known string, and VAULT_HASH_TOOL named it, so no other candidate was tried."
    fi
    HASH_TOOL=""
    return 1
  fi
  for candidate in sha256sum shasum openssl cksum-sha256; do
    command -v "$(tool_binary "$candidate")" >/dev/null 2>&1 || continue
    got="$(printf '%s' "$HASH_PROBE" | hash_stdin_with "$candidate" | hex_digest)" || got=""
    if [ "$got" = "$HASH_PROBE_DIGEST" ]; then
      HASH_TOOL="$candidate"
      return 0
    fi
    warn "HASH-PROBE - $candidate did not return the expected digest for a known string, so the next candidate was tried."
  done
  HASH_TOOL=""
  return 1
}

# Whether anything here can render a difference. A machine carrying neither git
# nor diff is a real configuration and the refusal below is the answer it gets,
# and there is no way to build that machine inside a test on a runner that has
# both. So the seam is here, around the question "is one available", rather than
# at the refusal, which stays the one the real condition reaches. It is the same
# kind of seam as VAULT_FORCE_NO_SHA and as VAULT_FORCE_NO_JQ in the hooks, and
# it exists because without it that refusal had no control at all. Deleting it
# printed empty sections under headings and called them no change, in the one
# mode people use to decide whether to copy a file.
have_diff_tool() {
  [ -z "${VAULT_FORCE_NO_DIFF:-}" ] || return 1
  command -v git >/dev/null 2>&1 && return 0
  command -v diff >/dev/null 2>&1 && return 0
  return 1
}

need_hash_tool() {
  pick_hash_tool && return 0
  warn "HASH-UNAVAILABLE - none of sha256sum, shasum -a 256, openssl dgst -sha256 or cksum -a sha256 returned the expected digest for a known string, so nothing was hashed and nothing was compared."
  warn "This is saying it could not look. It is not saying the vault is up to date."
  exit 2
}

# existing_paths <root> <list> <out> <unreadable-out>
# The entries of <list> that are readable regular files, filtered in a bash loop
# with no forks. Everything downstream relies on this, because a file that is
# not there would otherwise desynchronise the pairing below.
#
# A path that is there and cannot be read goes to <unreadable-out> and the
# CALLER HAS TO CARRY IT FORWARD, which is the part an earlier version left out.
# Warning about it and then dropping it was not enough: the path then reached
# nothing on the disk side of the comparison, the join fell through to its
# deleted branch, and the report said in as many words that the owner had
# deleted it on purpose while the truth sat on standard error. "The owner
# removed this" is a finding and "this could not be read" is a refusal to
# answer, and keeping those two apart is the whole reason the exit codes here
# are shaped the way they are.
existing_paths() {
  local root="$1" list="$2" out="$3" unread="$4" rel
  : > "$out"
  : > "$unread"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -f "$root/$rel" ] && [ -r "$root/$rel" ]; then
      printf '%s\n' "$rel" >> "$out"
    elif [ -e "$root/$rel" ] || [ -L "$root/$rel" ]; then
      printf '%s\n' "$rel" >> "$unread"
    fi
  done < "$list"
  if [ -s "$unread" ]; then
    warn "UNREADABLE - these are on disk and could not be read, so nothing is known about them: $(name_a_few "$unread")"
  fi
}

# THE MANIFEST STORES THE HASH OF THE CONTENT WITH CARRIAGE RETURNS REMOVED, so
# one commit gives one digest on every platform. That is not tidiness. Measured
# in this repository on 2026-09-21, .gitattributes was checked out holding 38
# carriage returns on Windows and none on Linux, because no rule but the
# catch-all reaches it. Hashing raw bytes would mean the manifest a maintainer
# generated disagreed with the one CI generated from the very same commit.
#
# THERE IS DELIBERATELY NO "DOES THIS FILE HOLD A CARRIAGE RETURN" STEP, and the
# reason is worth writing down because the obvious shape was tried here and is
# silently broken on the one platform that matters. On Git Bash NEITHER grep NOR
# awk can see a trailing carriage return: both consume it as part of the line
# terminator, so `grep -l` over a file that demonstrably holds one reports no
# match, and an awk testing index($0, "\r") finds a carriage return in the middle
# of a line and misses the one at the end. A detection step would therefore have
# been blind exactly where CRLF actually happens, and blind in the reassuring
# direction.
#
# So nothing detects. Generation normalises every file, and comparison uses the
# hash itself as the detector: a raw digest that already matches the manifest
# cannot have held a carriage return, and only the few that disagree are hashed
# again with them removed.

# hash_paths <root> <list-of-relative-paths> <out>
#
# Emits "<hash> <path>" of the RAW bytes, in one call per chunk, because a
# process per file is unusable on Windows. Measured on 2026-09-21 against this
# repository's own tracked files under Git Bash, a tr and a hash process each
# took over 120 seconds where one batched call took 2. Process start-up
# dominates there and the Windows CI job already uses 33 of its 60 minutes.
#
# The output is paired with the input BY LINE ORDER, never by parsing the file
# name back out of it. All four tools print one line per file in argument order,
# and their four output shapes differ in where the name sits and how it is
# escaped, so not reading the name at all is what makes those shapes irrelevant.
# The pairing is exact because the list is filtered to existing regular files
# first, a file that cannot be read writes only to stderr, and a chunk whose
# output line count disagrees with its input count is refused rather than
# mispaired.
# The paths that were on disk and could not be read are left in <out>.unreadable
# for the caller to fold into the comparison. They are not this function's to
# judge, and they must not simply vanish.
hash_paths() {
  local root="$1" list="$2" out="$3" rel n chunk
  : > "$out"
  existing_paths "$root" "$list" "$TMPD/hp.exist" "$out.unreadable"
  n="$(awk 'END { print NR + 0 }' "$TMPD/hp.exist")"
  [ "$n" -gt 0 ] || return 0

  chunk=0
  set --
  while IFS= read -r rel; do
    set -- "$@" "$rel"
    chunk=$((chunk + 1))
    if [ "$chunk" -ge 100 ]; then
      hash_chunk "$root" "$out" "$@" || return 1
      chunk=0
      set --
    fi
  done < "$TMPD/hp.exist"
  if [ "$chunk" -gt 0 ]; then
    hash_chunk "$root" "$out" "$@" || return 1
  fi
  return 0
}

# hash_paths_normalised <root> <list> <out>
# The same, of the content with carriage returns removed. A process per file,
# which is why it is used only where it has to be: generation, which has no
# manifest to compare against and so cannot use the cheap route, and the retry
# over the handful of files whose raw digest already disagreed. Generation is a
# maintainer and CI action, and CI runs it on Linux where forks are cheap.
hash_paths_normalised() {
  local root="$1" list="$2" out="$3" rel h st
  : > "$out"
  existing_paths "$root" "$list" "$TMPD/hpn.exist" "$out.unreadable"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    # pipefail INSIDE the substitution, which is the only thing that works here.
    # A file that cannot be opened makes the redirection fail and hands the hash
    # tool an empty stream, and the digest of nothing is a perfectly well formed
    # digest - it is already in this repository's own manifest six times, for the
    # empty .gitkeep files. So an unreadable file would be recorded as
    # byte-identical to an empty one and nothing downstream could tell them
    # apart. On Windows that is not hypothetical, because -r is a permission test
    # and does not see a file held open by Obsidian or a scanner.
    #
    # Reading PIPESTATUS after the assignment does NOT work, and that was the
    # first attempt at this. The pipeline runs in the subshell the substitution
    # creates, so its PIPESTATUS never reaches this shell, and what is left is
    # the status of the assignment, which is the status of the LAST stage. The
    # failure being guarded against is in the first. Measured 2026-09-21 against
    # a file that is not there: PIPESTATUS[0] was 0 and the digest was the one
    # for an empty stream, so the guard never fired.
    #
    # pipefail was the second attempt and is not right either. It says some stage
    # failed without saying which, and the whole point of the two messages below
    # is that a file that could not be read and a tool that gave no usable answer
    # are different refusals. The read gets its own checked redirection.
    if ! tr -d '\r' < "$root/$rel" > "$TMPD/hpn.one" 2>/dev/null; then
      warn "HASH-READ - $rel could not be read, so no digest was taken for it and nothing was compared."
      return 1
    fi
    h="$(hash_stdin_with "$HASH_TOOL" < "$TMPD/hpn.one" | hex_digest)"
    if [ -z "$h" ]; then
      warn "HASH-PARSE - the hashing tool gave no usable digest for $rel, so nothing was compared."
      return 1
    fi
    printf '%s %s\n' "$h" "$rel" >> "$out"
  done < "$TMPD/hpn.exist"
  return 0
}

hash_chunk() {  # hash_chunk <root> <out> <relative-path>...
  local root="$1" out="$2" want got p
  shift 2
  want=$#
  [ "$want" -gt 0 ] || return 0
  printf '%s\n' "$@" > "$TMPD/hc.paths"
  # Handed to the tool with a ./ in front of every path. A tracked file called
  # -x.md is an ordinary name here and an option to all four tools, and -- is
  # not the way out, because openssl does not accept it and would take the
  # dashes as a file name. The prefix is invisible downstream, because the
  # output is paired with the input by line order and the name in it is never
  # read back.
  set --
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    set -- "$@" "./$p"
  done < "$TMPD/hc.paths"
  ( cd "$root" 2>/dev/null && run_hash_tool "$HASH_TOOL" "$@" ) > "$TMPD/hc.raw" 2>/dev/null
  got="$(awk 'END { print NR + 0 }' "$TMPD/hc.raw")"
  if [ "$got" -ne "$want" ]; then
    warn "HASH-PAIRING - the hashing tool printed $got line(s) for $want file(s), so its answers could not be matched to the files they belong to. Nothing was compared."
    return 1
  fi
  LC_ALL=C awk -v pf="$TMPD/hc.paths" '
    BEGIN { while ((getline line < pf) > 0) { sub(/\r$/, "", line); n++; p[n] = line } }
    {
      sub(/\r$/, "")
      i++
      h = ""; seen = 0
      for (f = 1; f <= NF; f++) {
        if (length($f) == 64 && $f ~ /^[0123456789abcdef]*$/) { h = $f; seen++ }
      }
      if (seen == 1 && i <= n) printf "%s %s\n", h, p[i]
      else bad++
    }
    END { if (bad > 0) exit 1 }
  ' "$TMPD/hc.raw" >> "$out" || {
    warn "HASH-PARSE - a line of the hashing tool's output did not hold exactly one 64-character hex digest, so it was not trusted. Nothing was compared."
    return 1
  }
  return 0
}

# binary_files <root> <list> <out>
# The paths in <list> that hold a NUL byte, found with one grep per chunk rather
# than one process per file, for the same reason hash_paths batches.
#
# grep -I is what decides, because in the C locale it calls a file binary on
# finding a NUL and that is exactly the question. An EMPTY file is text and grep
# would not list it, so empty files are filtered out before the question is put
# rather than being counted as binary - and this template ships six empty
# .gitkeep files, so getting that wrong would fail generation on a clean tree.
#
# THE LIMIT, STATED RATHER THAN HIDDEN. Binary detection happens per buffer and
# -l stops at the first matching line, so what grep actually reads is the first
# buffer, which is a few tens of kilobytes. A file whose opening is ordinary
# text and which turns binary later is therefore listed as text and hashed as
# text, and this will not name it. Counting every line instead would read the
# whole file, and it was tried and rejected: BSD grep skips an ignored file
# entirely rather than reporting a count of zero for it, so the answers could no
# longer be matched to the files they belong to on macOS. Every file this
# template ships is a short text file, so the limit costs nothing here and is
# written down because the next person to add a large file deserves to know it.
#
# Paths go to grep with a ./ in front for the same reason they do to the hashing
# tools: a tracked file called -x.md is an ordinary name and an option. The
# prefix is taken off again where grep's answer is read.
binary_files() {
  local root="$1" list="$2" out="$3" rel chunk=0 p
  : > "$out"
  : > "$TMPD/bf.nonempty"
  : > "$TMPD/bf.unreadable"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -s "$root/$rel" ] || continue
    # READABILITY IS TESTED HERE, and it has to be, because the decision below
    # is made by ABSENCE from grep's output. grep does not list a file it could
    # not open, its complaint goes to a discarded stderr, and the file would
    # therefore be reported as holding a NUL byte - a confident finding, with a
    # reason that is not the reason. On Windows that is not hypothetical, since
    # a file held open by Obsidian or a scanner is exactly this case.
    if [ -r "$root/$rel" ]; then
      printf '%s\n' "$rel" >> "$TMPD/bf.nonempty"
    else
      printf '%s\n' "$rel" >> "$TMPD/bf.unreadable"
    fi
  done < "$list"
  if [ -s "$TMPD/bf.unreadable" ]; then
    warn "UNREADABLE - these are tracked and could not be read, so whether they are text could not be decided: $(name_a_few "$TMPD/bf.unreadable")"
    return 1
  fi
  [ -s "$TMPD/bf.nonempty" ] || return 0

  : > "$TMPD/bf.text"
  : > "$TMPD/bf.chunk"
  while IFS= read -r rel; do
    printf '%s\n' "$rel" >> "$TMPD/bf.chunk"
    chunk=$((chunk + 1))
    if [ "$chunk" -ge 100 ]; then
      binary_chunk "$root" "$TMPD/bf.chunk" "$TMPD/bf.text"
      : > "$TMPD/bf.chunk"
      chunk=0
    fi
  done < "$TMPD/bf.nonempty"
  if [ "$chunk" -gt 0 ]; then
    binary_chunk "$root" "$TMPD/bf.chunk" "$TMPD/bf.text"
  fi

  LC_ALL=C awk -v tf="$TMPD/bf.text" '
    BEGIN { while ((getline l < tf) > 0) { sub(/\r$/, "", l); sub(/^\.\//, "", l); t[l] = 1 } }
    { sub(/\r$/, ""); if (!($0 in t)) print }
  ' "$TMPD/bf.nonempty" > "$out"
  return 0
}

binary_chunk() {  # binary_chunk <root> <path-list> <append-to>
  local root="$1" list="$2" out="$3" p
  set --
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    set -- "$@" "./$p"
  done < "$list"
  [ "$#" -gt 0 ] || return 0
  ( cd "$root" 2>/dev/null && LC_ALL=C grep -I -l -e '' "$@" ) >> "$out" 2>/dev/null
  return 0
}

# ------------------------------------------------------------- manifests --

# read_manifest <file> <tag> <out> <meta>
#
# Emits "<tag> <class> <hash> <path>" per entry and records what it could not
# accept in <meta>, which the caller turns into a refusal.
#
# THE COMPILED-IN NARROWING. A path under a content tier or under .obsidian is
# forced to seed whatever the manifest says, unless it is one of the two shapes
# this script itself knows to be machinery. An incoming manifest can therefore
# only ever narrow what this treats as the template's, never widen it, so a
# hostile copy that reclassifies one of your notes as template machinery is
# refused rather than obeyed. The refusal lives in the running script, not in
# data somebody else controls.
read_manifest() {
  local file="$1" tag="$2" out="$3" meta="$4"
  [ -f "$file" ] && [ -r "$file" ] || return 1
  : > "$meta"
  LC_ALL=C awk -v tag="$tag" -v meta="$meta" -v roots="$MACHINERY_ROOTS" -v topfiles="$MACHINERY_FILES" '
    # May this path be template machinery at all. Everything this answers no to
    # is forced back to the owner and kept out of the copy plan, whatever class
    # the manifest gave it. The list is compiled in, so an incoming manifest can
    # only ever narrow what this treats as the template, never widen it.
    #
    # Everything is compared with case folded, because Windows and macOS fold it
    # for you when the copy plan is pasted, so 31-Standards/evil.md would
    # otherwise miss a case-sensitive test and land in the real folder.
    function may_be_machinery(p,   lp, i, nr, part, r) {
      lp = tolower(p)
      # THE FIVE EXACT PATHS the template ships as machinery inside a content
      # tier, matched whole. These used to be a predicate asking whether any
      # component was called templates, which is a WIDENING test evaluated
      # against text the other side chooses, and it was a hole: a manifest
      # claiming 31-standards/templates/house-style.md passed it and was then
      # printed with a copy command for a folder every agent is told to mirror.
      # Five strings cannot be widened by anything a manifest says, and a tier
      # templates FOLDER is deliberately not a root below for the same reason.
      if (lp == "30-knowledge/moc/vault-index.md" \
       || lp == "10-daily/templates/short-term-daily.md" \
       || lp == "20-projects/_logs/templates/medium-term-project-log.md" \
       || lp == "31-standards/templates/long-term-standard.md" \
       || lp == "40-llm-wiki/wiki/templates/llm-wiki-entity.md") return 1
      # A top-level file the template ships, matched whole.
      if (index(lp, "/") == 0) return (index(" " topfiles " ", " " lp " ") > 0)
      # A path under a folder the template ships machinery in. The trailing
      # slash is part of the token on both sides, so .github/hooks/ cannot be
      # satisfied by .github/hooksomething/x.
      nr = split(roots, part, " ")
      for (i = 1; i <= nr; i++) {
        r = tolower(part[i])
        if (length(r) && substr(lp, 1, length(r)) == r) return 1
      }
      return 0
    }
    { sub(/\r$/, "") }
    /^#/ { next }
    /^[ \t]*$/ { next }
    # The version is filtered as strictly as a path, and for a sharper reason
    # than tidiness. It is printed by --status, by the counts line, by --adopt
    # and by vault-check.sh on every full scan, which is the most-run command
    # here. A field with no whitespace can still carry escape bytes, so an
    # unfiltered version lets a manifest repaint or erase the very NARROWED and
    # PATH-BLOCKED lines the reader is told to read.
    $1 == "version" {
      if ($2 ~ /^[0-9][0-9.]*$/ && index($2, "..") == 0 && substr($2, length($2)) != ".") {
        print "version " $2 >> meta
      } else {
        print "badversion " NR >> meta
      }
      next
    }
    $1 == "hash"    { print "algo " $2 >> meta; next }
    NF != 3 { print "malformed line-" NR >> meta; next }
    {
      cls = $1; h = $2; path = $3
      if (cls != "owned" && cls != "seed") { print "badclass " path >> meta; next }
      if (length(h) != 64 || h !~ /^[0123456789abcdef]*$/) { print "badhash " path >> meta; next }
      if (substr(path, 1, 1) == "/" || path ~ /^[A-Za-z]:/ || index(path, "\\") > 0) { print "escape " path >> meta; next }
      if (path == ".." || substr(path, 1, 3) == "../" || index(path, "/../") > 0 \
          || (length(path) >= 3 && substr(path, length(path) - 2) == "/..")) { print "escape " path >> meta; next }
      # A single dot component, and a component ending in one. `./31-standards/x`
      # puts a "." where the tier name belongs, so the tier test misses it and
      # the entry stays template machinery while the copy still lands in the
      # real folder. `31-standards./x` does the same on Windows, which strips a
      # trailing dot. One index() catches a leading "./", an interior "/./" and
      # any component ending in a dot, because all three spell "./".
      if (path == "." || index(path, "./") > 0 || substr(path, length(path)) == ".") { print "escape " path >> meta; next }
      if (path ~ /[^-A-Za-z0-9._\/]/) { print "badchar " path >> meta; next }
      if (cls == "owned" && !may_be_machinery(path)) {
        print "narrowed " path >> meta
        cls = "seed"
      }
      printf "%s %s %s %s\n", tag, cls, h, path
    }
  ' "$file" > "$out"
  return 0
}

# The first few of a list, and HOW MANY THERE WERE.
#
# Every one of these lists used to be `head -n 3`, which is fine until a source
# manifest claims five hundred paths and the reader is told about three and
# never told there were five hundred. This repository's whole reporting
# doctrine is that a reader should be able to read the numbers, so a truncated
# list that does not say it is truncated is the wrong shape for it.
name_a_few() {  # name_a_few <list-file>
  local n
  n="$(awk 'END { print NR + 0 }' "$1")"
  if [ "$n" -le 3 ]; then
    tr '\n' ' ' < "$1"
  else
    printf '%s and %s more' "$(head -n 3 "$1" | tr '\n' ' ')" "$((n - 3))"
  fi
}

load_manifest() {  # load_manifest <file> <tag> <out> <meta>
  local file="$1" tag="$2" out="$3" meta="$4" bad
  read_manifest "$file" "$tag" "$out" "$meta" || return 1
  LC_ALL=C awk '$1 == "escape" { print $2 }' "$meta" > "$TMPD/lm.list"
  bad="$(name_a_few "$TMPD/lm.list")"
  if [ -n "$bad" ]; then
    warn "PATH-BLOCKED - $file names a path that resolves outside the vault: $bad"
    warn "Nothing was compared. A manifest is only ever allowed to name paths inside the vault it describes."
    exit 6
  fi
  LC_ALL=C awk '$1 == "malformed" || $1 == "badclass" || $1 == "badhash" || $1 == "badchar" || $1 == "badversion" { print $1 "=" $2 }' "$meta" > "$TMPD/lm.list"
  bad="$(name_a_few "$TMPD/lm.list")"
  if [ -n "$bad" ]; then
    warn "MANIFEST-MALFORMED - $file holds entries this cannot read: $bad"
    warn "Nothing was compared, because a manifest that cannot be parsed says nothing about the vault."
    exit 1
  fi
  LC_ALL=C awk '$1 == "narrowed" { print $2 }' "$meta" > "$TMPD/lm.list"
  bad="$(name_a_few "$TMPD/lm.list")"
  if [ -n "$bad" ]; then
    warn "NARROWED - $file classes these paths as template machinery and they are not places this template ships machinery, so they were treated as yours instead: $bad"
    warn "The list of places a template may ship machinery is compiled into this script, so a manifest can only ever narrow what it reaches and never widen it. A release that adds a new one is narrowed by an older copy of this script rather than offered, and you can still take it by hand."
  fi
  return 0
}

read_version() {
  [ -f "$ROOT/$VERSION_REL" ] || { printf 'unknown'; return; }
  LC_ALL=C awk '{ sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if (length($0)) { print; exit } }' "$ROOT/$VERSION_REL"
}

# The version as it may be WRITTEN into a manifest header, or nothing.
#
# read_version above answers for a reader and says the word unknown when there
# is no VERSION file. That word must never reach a manifest, and an earlier
# version of this let it: generation wrote "version unknown" into the header,
# read_manifest refuses that as badversion, and the shipped manifest was
# therefore refused as MANIFEST-MALFORMED in every vault that adopted it, while
# --verify-manifest agreed with itself perfectly because both sides build the
# same bytes. That is the same asymmetry path_is_writable_to_a_manifest exists
# to close, one field along.
#
# The grammar is the reader's grammar. A line reading "1.0.0 extra" is refused
# here rather than written, because the reader takes the second field and would
# silently record 1.0.0, so the file and the manifest would state two different
# versions and nothing would say so.
version_for_manifest() {
  local v
  [ -f "$ROOT/$VERSION_REL" ] && [ -r "$ROOT/$VERSION_REL" ] || return 1
  v="$(LC_ALL=C awk '{ sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if (length($0)) { print; exit } }' "$ROOT/$VERSION_REL")"
  [ -n "$v" ] || return 1
  case "$v" in
    *[!0-9.]*) return 1 ;;
    .*|*.) return 1 ;;
    *..*) return 1 ;;
  esac
  printf '%s' "$v"
}

# ----------------------------------------------------------------- rules --

RULES_CLASS=""
RULES_LINE=""
RULE_N=0
RULE_CLASS=()
RULE_PAT=()
RULE_LINE=()
RULE_HITS=()

# The rules are read into arrays ONCE rather than re-read per path, and the tab
# that separates a class from its pattern is built once rather than inside the
# read. Written the obvious way, `while IFS="$(printf '\t')" read` runs that
# command substitution on every line of every file, which came to 4400 forks for
# this repository alone and turned generation from instant into minutes on
# Windows. Process start-up is the cost that matters on that platform and it is
# easy to pay it without noticing.
classify() {  # classify <path>
  local path="$1" i=1
  RULES_CLASS=""
  RULES_LINE=""
  while [ "$i" -le "$RULE_N" ]; do
    # shellcheck disable=SC2254
    case "$path" in
      ${RULE_PAT[$i]})
        RULES_CLASS="${RULE_CLASS[$i]}"
        RULES_LINE="${RULE_LINE[$i]}"
        RULE_HITS[$i]=$(( ${RULE_HITS[$i]} + 1 ))
        return 0
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# Rules that classified nothing, reported after a generation rather than
# refused. A rule matching no path is usually a string left behind by a file
# that was renamed or retired, and the manifest it produces is perfectly
# self-consistent without it, so nothing else here would ever mention it. It is
# a warning and not a failure because a template may legitimately ship a rule
# for a folder that is empty in the tree it is generated from.
report_unused_rules() {
  local i=1 idle=""
  while [ "$i" -le "$RULE_N" ]; do
    if [ "${RULE_HITS[$i]}" -eq 0 ]; then
      idle="$idle line ${RULE_LINE[$i]} [${RULE_CLASS[$i]} ${RULE_PAT[$i]}],"
    fi
    i=$((i + 1))
  done
  [ -n "$idle" ] || return 0
  warn "RULE-IDLE - these rules in $RULES_REL matched no tracked file, so they classify nothing and are most likely left over from a path that was renamed or retired:${idle%,}"
}

load_rules() {
  local file="$ROOT/$RULES_REL" bad cls pat tab lineno=0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    warn "NO-RULES - $RULES_REL is not a readable file, so nothing could be classified."
    exit 2
  fi
  LC_ALL=C awk '{ sub(/\r$/, ""); print }' "$file" > "$TMPD/rules.clean"

  # THE VALIDATORS AND THE PARSER HAVE TO AGREE ABOUT WHICH LINES ARE RULES, and
  # they did not. The validators selected with /^[a-z]/ and split on tabs with
  # -F, while the parse loop below skips only a blank line and a comment and
  # reads with `IFS=<tab> read -r cls pat`, which puts THE WHOLE REMAINDER of
  # the line into pat. Two lines slipped through every check and were then used:
  #
  #   Owned<TAB>docs/*            a class no validator looked at, because the
  #                               line does not begin with a lower-case letter.
  #                               It reached the manifest, where every
  #                               downstream vault refuses the whole file as
  #                               badclass - loud, but only after release.
  #   owned<TAB>docs/*<TAB>junk   a third field the validators never see,
  #                               because they only ever inspect $2.
  #
  # So the selection here is now the same one the parser uses, a line that is
  # neither blank nor a comment, and the field count is checked rather than
  # assumed.
  bad="$(LC_ALL=C awk -F'\t' '!/^#/ && NF > 0 && length($1) && NF != 2 { print "line-" NR }' "$TMPD/rules.clean" | head -n 3 | tr '\n' ' ')"
  if [ -n "$bad" ]; then
    warn "RULE-FIELDS - a rule is exactly two tab-separated fields, a class and a pattern, and these lines are not: $bad"
    warn "A third field would be read as part of the pattern and would then match nothing. Nothing was classified."
    exit 1
  fi
  bad="$(LC_ALL=C awk -F'\t' '!/^#/ && length($1) && index($2, "**") > 0 { print $2 }' "$TMPD/rules.clean" | head -n 3 | tr '\n' ' ')"
  if [ -n "$bad" ]; then
    warn "RULE-DOUBLE-STAR - these patterns hold a double star, and here a single star already crosses a slash, so the two would read differently to a person and the same to the matcher: $bad"
    exit 1
  fi
  bad="$(LC_ALL=C awk -F'\t' '!/^#/ && length($1) && $1 != "owned" && $1 != "seed" && $1 != "excluded" { print $1 }' "$TMPD/rules.clean" | head -n 3 | tr '\n' ' ')"
  if [ -n "$bad" ]; then
    warn "RULE-CLASS - these are not classes this understands: $bad"
    exit 1
  fi
  # A pattern is expanded unquoted into a case statement, which it has to be or
  # it would stop being a pattern.
  #
  # AN EARLIER VERSION OF THIS COMMENT CALLED THAT AN EXECUTION SURFACE, AND
  # THAT WAS WRONG. A reviewer asserted it, a canary in the control contradicted
  # them, and the question was then settled by measurement rather than by
  # argument. On bash 5.3 on 2026-09-21:
  #
  #   a command substitution written literally in the pattern text   runs
  #   the same text arriving through a variable                      does NOT run
  #   a value holding two words                                      is one pattern holding a space
  #
  # Expansion is not recursive. What the array holds is matched as a pattern and
  # never expanded a second time, so neither the command substitution nor the
  # split into two patterns is reachable from this file. Leaving the old reason
  # in place would have been the same defect as publishing a refusal that cannot
  # fire, one level up.
  #
  # The check stays for the smaller reason it can actually carry. A rule is only
  # useful when it names paths a manifest could hold, so a pattern outside that
  # character set classifies nothing whatever it matches, and it is far more
  # likely to be a typed quote, a stray tab or a Windows backslash than an
  # intention. Refusing it by name beats leaving it in the file matching nothing.
  bad="$(LC_ALL=C awk -F'\t' '!/^#/ && length($1) && length($2) && $2 ~ /[^-A-Za-z0-9._\/*?]/ { print $2 }' "$TMPD/rules.clean" | head -n 3 | tr '\n' ' ')"
  if [ -n "$bad" ]; then
    warn "RULE-CHARACTER - these patterns hold a character a pattern may not hold, and a pattern may hold only the characters a manifest path may hold plus a star and a question mark: $bad"
    warn "A rule can only usefully name paths a manifest can carry, so a pattern outside that set would classify nothing whatever it matched. Nothing was classified."
    exit 1
  fi

  tab="$(printf '\t')"
  RULE_N=0
  while IFS="$tab" read -r cls pat; do
    lineno=$((lineno + 1))
    case "$cls" in ''|'#'*) continue ;; esac
    [ -n "$pat" ] || continue
    RULE_N=$((RULE_N + 1))
    RULE_CLASS[$RULE_N]="$cls"
    RULE_PAT[$RULE_N]="$pat"
    RULE_LINE[$RULE_N]="$lineno"
    RULE_HITS[$RULE_N]=0
  done < "$TMPD/rules.clean"
  if [ "$RULE_N" -eq 0 ]; then
    warn "NO-RULES - $RULES_REL holds no rules, so every file would be unclassified."
    exit 2
  fi
}

# -------------------------------------------------------- build manifest --

tracked_files() {
  if ! command -v git >/dev/null 2>&1; then
    warn "NO-GIT - the manifest is built from the tracked file list, and git is not installed, so it could not be built."
    return 1
  fi
  # core.quotepath off, because it defaults on and turns a non-ASCII name into a
  # quoted octal escape. The path would then be reported missing from disk,
  # which is loud but names a reason that is not the reason.
  ( cd "$ROOT" && GIT_TERMINAL_PROMPT=0 git -c core.quotepath=false ls-files 2>/dev/null ) \
    | LC_ALL=C awk '{ sub(/\r$/, ""); if (length($0)) print }' | LC_ALL=C sort
}

# The same rules read_manifest applies when it reads a manifest, applied here
# when one is written. Without this the two halves disagree, and the failure is
# asymmetric in the worst direction: a tracked file whose name holds a space
# writes a four-field line that generation accepts and verification accepts,
# because both sides build the same line and neither parses it, while every
# downstream vault refuses the whole manifest as malformed. The artefact that
# breaks is the shipped one, and it breaks after release.
# The character class does the work. It already rejects a tab, a space, a
# backslash and a colon, so the separate clauses that used to test those are gone
# along with the command substitution one of them ran once per tracked file -
# which is the fork cost load_rules carries a comment about paying by accident.
# Only the shapes the class cannot see are tested on their own.
path_is_writable_to_a_manifest() {  # path_is_writable_to_a_manifest <path>
  case "$1" in
    /*) return 1 ;;
    ..|../*|*/../*|*/..) return 1 ;;
    .|./*|*/./*|*/.) return 1 ;;
    # A component that ends in a dot, anywhere, and a path that does. The reader
    # rejects both, through one index() for "./" plus a trailing-dot test, and
    # the writer has to reject exactly what the reader rejects or a manifest
    # ships that every vault refuses whole.
    *./*|*.) return 1 ;;
    *[!-A-Za-z0-9._/]*) return 1 ;;
  esac
  return 0
}

# The folder named by --from, which until now was the one value from outside that
# reached standard output unfiltered. It is interpolated into the copy plan, and
# that plan is a command a person is told to paste, so a folder whose name holds
# a single quote closes the quoting the plan puts around it and the rest of the
# line becomes shell syntax of somebody else's choosing. Control bytes there can
# also repaint the very refusal lines the reader is told to read. A path is
# accepted here on the same terms a manifest path is, plus the separators a real
# folder needs.
# Written as a REFUSAL of the two shapes that do harm rather than as an allowed
# set of characters, which is how it started and which refused a great many
# ordinary folders. C:\Program Files (x86)\ has parentheses, a folder Windows
# has duplicated ends in (1), and every accented or non-Latin path on earth is
# outside ASCII word characters. None of those can hurt anything: the plan puts
# single quotes on both sides of this value, and inside single quotes every one
# of them is literal.
#
# What is not literal inside single quotes is a single quote, which closes the
# quoting and hands the rest of the line to the shell. Control bytes are the
# other one, because they can repaint the very refusal lines the reader is told
# to read. Those two are refused and nothing else is.
from_is_printable() {  # from_is_printable <dir>
  case "$1" in
    *"'"*) return 1 ;;
  esac
  # One fork, on a path that runs once per invocation, rather than a range
  # inside a case pattern. A range there is the very construct the locale pin
  # at the top of this script exists to protect, so using one here to defend
  # against bad bytes would rest the defence on the thing being defended.
  [ "$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]' | wc -c)" \
    -eq "$(printf '%s' "$1" | wc -c)" ] || return 1
  return 0
}

# build_manifest <out>
# The whole of generation, writing nowhere but <out>. --generate copies it into
# place and --verify-manifest compares against it, so verification can never
# touch the checked-in file.
build_manifest() {
  local out="$1" path cls line missing=0 unclassified=0 binary=0 unwritable=0 dupe

  load_rules
  GEN_VERSION="$(version_for_manifest)" || {
    warn "NO-VERSION - $VERSION_REL is missing, empty, or is not digits separated by dots, and the header of the manifest carries that version into every vault that adopts it."
    warn "A header this could not read back is refused as malformed there while agreeing with itself perfectly here, so it is refused where it would be written instead. Nothing was written."
    return 1
  }
  need_hash_tool
  tracked_files > "$TMPD/gen.tracked" || return 2

  : > "$TMPD/gen.hashme"
  : > "$TMPD/gen.class"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # A file in the index that is not on disk is a failure, never a skip.
    # Skipping would drop an entry silently and the next comparison would call
    # it new.
    if [ ! -f "$ROOT/$path" ]; then
      warn "MISSING-TRACKED - $path is in the index and not on disk, so its hash could not be taken."
      missing=$((missing + 1))
      continue
    fi
    if ! path_is_writable_to_a_manifest "$path"; then
      warn "UNWRITABLE-PATH - $path cannot be written to a manifest, because a manifest entry is three whitespace-separated fields of printable ASCII and this name would not survive being read back."
      unwritable=$((unwritable + 1))
      continue
    fi
    if ! classify "$path"; then
      warn "UNCLASSIFIED - $path matches no rule in $RULES_REL, so nobody has decided what happens to it in somebody else's vault."
      unclassified=$((unclassified + 1))
      continue
    fi
    cls="$RULES_CLASS"
    line="$RULES_LINE"
    printf '%s %s %s\n' "$cls" "$line" "$path" >> "$TMPD/gen.class"
    [ "$cls" = excluded ] && continue
    printf '%s\n' "$path" >> "$TMPD/gen.hashme"
  done < "$TMPD/gen.tracked"
  report_unused_rules

  # Removing carriage returns before hashing is only meaningful for text, so a
  # byte-for-byte file is refused rather than quietly mishandled. Asked once for
  # the whole set rather than once per file, because process start-up on Windows
  # is what makes the naive shape unusable.
  # A non-zero return means it could not decide rather than that it decided
  # binary, and the two want different answers, so it leaves by the could-not-
  # look door rather than being folded into the tally below.
  binary_files "$ROOT" "$TMPD/gen.hashme" "$TMPD/gen.binary" || return 2
  if [ -s "$TMPD/gen.binary" ]; then
    while IFS= read -r path; do
      warn "BINARY - $path holds a NUL byte and this hashes text. Class it excluded, or keep binaries out of the template."
      binary=$((binary + 1))
    done < "$TMPD/gen.binary"
  fi

  # Two entries differing only in case collide into one destination on macOS and
  # on Windows, so they are refused where they are made rather than where they
  # would land.
  dupe="$(LC_ALL=C tr 'A-Z' 'a-z' < "$TMPD/gen.hashme" | LC_ALL=C sort | LC_ALL=C uniq -d | head -n 3 | tr '\n' ' ')"
  if [ -n "$dupe" ]; then
    warn "CASE-COLLISION - these paths differ only in case and would collide on macOS and on Windows: $dupe"
    return 1
  fi

  if [ "$missing" -gt 0 ] || [ "$unclassified" -gt 0 ] || [ "$binary" -gt 0 ] || [ "$unwritable" -gt 0 ]; then
    warn "Nothing was written. $unclassified unclassified, $missing in the index but not on disk, $binary binary, $unwritable with a name a manifest cannot carry."
    return 1
  fi

  hash_paths_normalised "$ROOT" "$TMPD/gen.hashme" "$TMPD/gen.hashes" || return 2

  # One digest per file that was asked for, or nothing is written. A dropped
  # entry is the one way the no-catch-all rule can be bypassed without anybody
  # noticing: the file was classified, it just never reached the manifest, and
  # from then on "absent from this file are yours and are never read" applies to
  # a file the template ships. Verification would agree, because it builds the
  # same manifest the same way.
  local want have
  want="$(awk 'END { print NR + 0 }' "$TMPD/gen.hashme")"
  have="$(awk 'END { print NR + 0 }' "$TMPD/gen.hashes")"
  if [ "$want" -ne "$have" ]; then
    warn "HASH-COUNT - $want file(s) were to be hashed and $have digest(s) came back, so an entry would have been dropped. Nothing was written."
    return 2
  fi

  {
    printf '%s\n' "# .claude/template-manifest"
    printf '%s\n' "#"
    printf '%s\n' "# Generated by .claude/scripts/vault-update.sh --generate. Do not hand edit."
    printf '%s\n' "#"
    printf '%s\n' "# This records what the template shipped at the version named below. It is"
    printf '%s\n' "# NOT a claim about what is on this disk now. That distinction is the whole"
    printf '%s\n' "# point, because the difference between the two is exactly what you have"
    printf '%s\n' "# changed. A hash edited here to make a report go quiet clears the alarm"
    printf '%s\n' "# without establishing anything, which is the unearned verification stamp"
    printf '%s\n' "# this vault's own rules warn about."
    printf '%s\n' "#"
    printf '%s\n' '# Each entry is "<class> <sha256> <path>". owned is template machinery and'
    printf '%s\n' "# seed was shipped once and is yours now. Paths absent from this file are"
    printf '%s\n' "# yours and are never read."
    printf 'version %s\n' "$GEN_VERSION"
    printf 'hash %s\n' "$HASH_ALGO"
    LC_ALL=C awk -v cf="$TMPD/gen.class" '
      BEGIN { while ((getline l < cf) > 0) { sub(/\r$/, "", l); split(l, a, " "); c[a[3]] = a[1] } }
      { sub(/\r$/, ""); if ($2 in c) printf "%s %s %s\n", c[$2], $1, $2 }
    ' "$TMPD/gen.hashes" | LC_ALL=C sort -k3,3
  } > "$out"
  return 0
}

do_generate() {
  local rc=0
  # The one mode that writes unconditionally, so it is the one that most needs
  # the refusals. Leaving it out meant every read-only mode honoured a tripwire
  # while the writing mode did not, and rewriting the provenance record while a
  # pass is mid-commit is exactly what 75 exists to prevent.
  refuse_if_held
  if [ "${VAULT_TEMPLATE_MAINTAINER:-}" != "1" ]; then
    warn "NOT-THE-TEMPLATE - --generate rewrites the record of what the template shipped, from whatever happens to be on this disk right now."
    warn "Run in a vault it would take your notes in as template entries and restamp every hash from your current files, after which every file reads as untouched and the record of what you had changed is gone."
    warn "If you really are working on the template itself, set VAULT_TEMPLATE_MAINTAINER=1 and run it again. Nothing was written."
    exit 64
  fi
  build_manifest "$TMPD/gen.manifest" || rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  cp "$TMPD/gen.manifest" "$ROOT/$MANIFEST_REL" || {
    warn "could not write $MANIFEST_REL"
    exit 1
  }
  say "wrote $MANIFEST_REL for version $GEN_VERSION: $(LC_ALL=C awk '$1 == "owned" { n++ } END { print n + 0 }' "$ROOT/$MANIFEST_REL") owned, $(LC_ALL=C awk '$1 == "seed" { n++ } END { print n + 0 }' "$ROOT/$MANIFEST_REL") seed, $(LC_ALL=C awk '$1 == "excluded" { n++ } END { print n + 0 }' "$TMPD/gen.class") excluded."
  return 0
}

do_verify_manifest() {
  local rc=0
  # This one takes the refusals as well, even though it writes nothing itself.
  # It asks git for the tracked file list, and a scheduled pass mid-commit is
  # exactly the moment that list is a snapshot of something in motion, so a
  # verification run there would be comparing the manifest against a tree that
  # is half of two states. --generate was given these for the same reason.
  refuse_if_held
  # The same guard --generate takes, and for a reason that is not obvious from
  # the fact that this one writes nothing.
  #
  # It runs the SAME build_manifest, which asks git for every tracked file in
  # the tree. In a vault that still has the rules file on disk - and being
  # excluded from the manifest is not the same as being absent from the tree -
  # that means the owner's own notes are classified, hashed, and then printed
  # by name in the stale-manifest diff, which breaches the one boundary this
  # tool is built around. Worse, it then prints the regenerate command, which
  # is exactly the command --generate's guard exists to keep out of reach, so a
  # user following the tool's own advice destroys their provenance record.
  if [ "${VAULT_TEMPLATE_MAINTAINER:-}" != "1" ]; then
    warn "NOT-THE-TEMPLATE - --verify-manifest rebuilds the manifest from the whole tracked tree to compare against, so in a vault it reads and names your own notes, and what it prints next is the command that rewrites your provenance record."
    warn "It answers for the template project rather than for a vault. If you really are working on the template itself, set VAULT_TEMPLATE_MAINTAINER=1 and run it again. To see what this vault carries, run --status instead."
    exit 64
  fi
  if [ ! -f "$ROOT/$MANIFEST_REL" ]; then
    warn "NO-MANIFEST - $MANIFEST_REL is not there, so there was nothing to verify."
    exit 2
  fi
  build_manifest "$TMPD/gen.manifest" || rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  if LC_ALL=C diff -u "$ROOT/$MANIFEST_REL" "$TMPD/gen.manifest" > "$TMPD/verify.diff" 2>/dev/null; then
    say "the manifest matches the tree at version $GEN_VERSION."
    return 0
  fi
  warn "MANIFEST-STALE - $MANIFEST_REL does not match what the rules and the tree produce now."
  LC_ALL=C awk '
    /^\+\+\+/ { next }
    /^---/ { next }
    /^@@/ { next }
    /^\+/ { sub(/^\+/, ""); if (length($0) && substr($0, 1, 1) != "#") print "  the tree has: " $0 }
    /^-/  { sub(/^-/, "");  if (length($0) && substr($0, 1, 1) != "#") print "  the manifest has: " $0 }
  ' "$TMPD/verify.diff" | head -n 40 >&2
  warn "Regenerate it with: VAULT_TEMPLATE_MAINTAINER=1 bash .claude/scripts/vault-update.sh --generate"
  return 1
}

# ---------------------------------------------------------------- report --

# join_state <have-source> <tagged-input>...
# One awk program over one tagged stream. The lines are tagged BY THE PRODUCER
# and never by FNR == 1, because an empty input never reaches FNR == 1, the
# phase counter never advances, and every later line is attributed to the wrong
# input with no error at all. That defect was in this design's first prototype.
join_state() {
  local have="$1"
  shift
  LC_ALL=C awk -v haveSource="$have" '
    { sub(/\r$/, "") }
    $1 == "L" { lcls[$4] = $2; lh[$4] = $3; seen[$4] = 1; next }
    $1 == "S" { scls[$4] = $2; sh[$4] = $3; seen[$4] = 1; next }
    $1 == "N" { nh[$3] = $2; disk[$3] = 1; next }
    $1 == "M" { mh[$3] = $2; next }
    $1 == "U" { unread[$2] = 1; next }
    END {
      for (p in seen) {
        inl = (p in lh); ins = (p in sh)
        cls = inl ? lcls[p] : scls[p]
        if (!inl && ins) { out[++k] = "new " cls " " p; continue }
        if (inl && !ins && haveSource == "yes") { out[++k] = "retired " cls " " p; continue }
        # AHEAD OF DELETED, and that order is the whole point of this verdict.
        # A file that is on the disk and cannot be opened reaches nothing on the
        # disk side, so without this it falls into the branch below and the
        # report states that the owner deleted it, which is a confident finding
        # about something nothing looked at.
        if (p in unread) { out[++k] = "unreadable " cls " " p; continue }
        if (!(p in disk)) { out[++k] = "deleted " cls " " p; continue }
        drift = (nh[p] != lh[p])
        # A raw digest that disagrees may be nothing but the line endings this
        # checkout was given, so the file is hashed again with carriage returns
        # removed and compared against the record on its own terms. When that
        # matches, the owner changed nothing and there is nothing to report.
        if (drift && (p in mh) && mh[p] == lh[p]) drift = 0
        moved = (ins && sh[p] != lh[p])
        # Already carrying what the source carries. Somebody acted on an earlier
        # report and copied the file across, so both flags are set and there is
        # nothing left to merge. Calling that a merge would list it for a human
        # decision on every run for ever, because nothing here rewrites the
        # record, and a report that keeps asking about a settled question is how
        # people stop reading reports.
        #
        # The normalised digest counts here too. The record and the source both
        # hold the digest of the content with carriage returns removed, while nh
        # is the raw bytes on this disk, so a file that WAS taken from upstream
        # and then checked out again on a machine that writes CRLF has a raw
        # digest matching neither. Comparing only the raw one dropped it through
        # to merge, and it was then asked about on every run for ever, which is
        # precisely the outcome this branch exists to prevent.
        if (moved && drift && (nh[p] == sh[p] || ((p in mh) && mh[p] == sh[p]))) { out[++k] = "converged " cls " " p; continue }
        if (moved && drift)  { out[++k] = "merge " cls " " p; continue }
        if (moved && !drift) { out[++k] = "take " cls " " p; continue }
        if (drift)           { out[++k] = "drifted " cls " " p; continue }
        out[++k] = "same " cls " " p
      }
      # Never emitted from for (k in a). That order is implementation defined and
      # differs between the awks in this repository CI matrix, which would make
      # every assertion on this output order-flaky.
      for (i = 1; i <= k; i++) print out[i]
    }
  ' "$@" | LC_ALL=C sort
}

verdict_count() {  # verdict_count <state-file> <verdict> [<class>]
  if [ -n "${3:-}" ]; then
    LC_ALL=C awk -v v="$2" -v c="$3" '$1 == v && $2 == c { n++ } END { print n + 0 }' "$1"
  else
    LC_ALL=C awk -v v="$2" '$1 == v { n++ } END { print n + 0 }' "$1"
  fi
}

list_paths() {  # list_paths <state-file> <verdict> <class>
  LC_ALL=C awk -v v="$2" -v c="$3" '$1 == v && $2 == c { print $3 }' "$1"
}

# mark_collisions <state-file> <out>
# A path the source ships and this vault's manifest has never heard of is new,
# and new normally means safe to take. Not when something is already sitting
# there. The user wrote that file, it is absent from the local manifest so it
# can never be seen as locally modified, and without this it would be listed as
# safe to take and the printed copy plan would tell them to overwrite their own
# work. This is the one data-loss path in a read-only tool, because the thing
# that does the writing is the person reading the plan.
#
# It reads one file and writes another. The earlier shape copied its result back
# over the very file the loop had just read, which worked only because the
# redirection's descriptor was closed by the time the copy ran. That is a fact
# about when bash closes a file, not about this function, and it is not the sort
# of thing a later edit is expected to keep in mind.
mark_collisions() {
  local st="$1" out="$2" verdict cls path
  : > "$out"
  while read -r verdict cls path; do
    if [ "$verdict" = new ] && { [ -e "$ROOT/$path" ] || [ -L "$ROOT/$path" ]; }; then
      printf 'collision %s %s\n' "$cls" "$path" >> "$out"
    else
      printf '%s %s %s\n' "$verdict" "$cls" "$path" >> "$out"
    fi
  done < "$st"
}

# add_normalised <state-file> <out>
# The retry. Only the paths whose raw digest disagreed are hashed again with
# carriage returns removed, so the cost is a process per disagreeing file rather
# than per file, and on a tree with nothing wrong it is no cost at all.
add_normalised() {  # add_normalised <state-file> <out>
  local out="$2"
  : > "$out"
  LC_ALL=C awk '$1 == "drifted" || $1 == "merge" { print $3 }' "$1" > "$TMPD/norm.list"
  [ -s "$TMPD/norm.list" ] || return 0
  # The failure is passed on rather than swallowed. Returning 0 here would turn
  # a file that could not be read into one that simply stays reported as
  # changed, which is the reassuring direction.
  hash_paths_normalised "$ROOT" "$TMPD/norm.list" "$TMPD/norm.hashes" || return 1
  LC_ALL=C awk '{ print "M " $1 " " $2 }' "$TMPD/norm.hashes" > "$out"
  return 0
}

load_local_manifest() {
  if [ ! -f "$ROOT/$MANIFEST_REL" ]; then
    warn "NO-MANIFEST - this vault has no $MANIFEST_REL, so which template version it came from is unknown."
    warn "A vault created before this mechanism existed can record a baseline with --adopt --from <dir>. This is saying it could not look. It is not saying the vault is up to date."
    exit 2
  fi
  load_manifest "$ROOT/$MANIFEST_REL" L "$TMPD/local.entries" "$TMPD/local.meta" || {
    warn "NO-MANIFEST - $MANIFEST_REL could not be read."
    exit 2
  }
  LOCAL_VERSION="$(LC_ALL=C awk '$1 == "version" { print $2; exit }' "$TMPD/local.meta")"
  LOCAL_ALGO="$(LC_ALL=C awk '$1 == "algo" { print $2; exit }' "$TMPD/local.meta")"
  [ -n "$LOCAL_VERSION" ] || LOCAL_VERSION="unknown"
  if [ -n "$LOCAL_ALGO" ] && [ "$LOCAL_ALGO" != "$HASH_ALGO" ]; then
    warn "UNKNOWN-ALGORITHM - $MANIFEST_REL says its hashes are $LOCAL_ALGO and this understands $HASH_ALGO only, so nothing was compared."
    exit 2
  fi
  if [ "$(awk 'END { print NR + 0 }' "$TMPD/local.entries")" -eq 0 ]; then
    warn "VACUOUS - $MANIFEST_REL holds no entries, so nothing was compared and this says nothing about whether the template moved."
    exit 2
  fi
}

report_local() {  # report_local <state-file> <unreadable-list>
  local st="$1" unread="$2" drifted deleted unreadable seed_drift

  drifted="$(verdict_count "$st" drifted owned)"
  deleted="$(verdict_count "$st" deleted owned)"
  # Counted from the LIST rather than from the verdict, and that is the fix for
  # two separate holes. A path the source no longer ships is judged retired
  # before the unreadable test can see it, so under --check it never carried the
  # verdict at all, and a seed path that could not be opened carried it with the
  # wrong class and was swept into the seed summary, whose sentence says
  # "changed, been deleted, or moved upstream" and can express none of them.
  # Whether a file could be opened is a fact about the instrument rather than
  # about who owns the file, so it is counted once, for every class.
  unreadable="$(awk 'END { print NR + 0 }' "$unread" 2>/dev/null)"
  [ -n "$unreadable" ] || unreadable=0
  # EVERY seed verdict, not the four that happened to be thought of first. A
  # release that adds an example note, retires one, or lands one where the owner
  # already has a file produced no number and no line anywhere, so the run said
  # nothing had moved and left on exit 0 while the sentence just below promised
  # the opposite. The rule for this sum is that it is every verdict except same,
  # because same is the only one that means nothing happened.
  seed_drift=$(( $(verdict_count "$st" drifted seed) + $(verdict_count "$st" merge seed) \
               + $(verdict_count "$st" deleted seed) + $(verdict_count "$st" take seed) \
               + $(verdict_count "$st" new seed) + $(verdict_count "$st" retired seed) \
               + $(verdict_count "$st" collision seed) + $(verdict_count "$st" converged seed) ))

  if [ "$drifted" -gt 0 ]; then
    printf '\nTemplate files you have changed (%s):\n' "$drifted"
    list_paths "$st" drifted owned | LC_ALL=C sed 's/^/  /'
  fi
  if [ "$deleted" -gt 0 ]; then
    printf '\nTemplate files you have deleted (%s). Deleting one is a normal thing to do and they are not put back:\n' "$deleted"
    list_paths "$st" deleted owned | LC_ALL=C sed 's/^/  /'
  fi
  # Its own section, above the exit code that goes with it. These are not a
  # finding about the vault, they are the tool saying which files it could not
  # open, and the run leaves on 2 because of them.
  if [ "$unreadable" -gt 0 ]; then
    printf '\nFiles that are on the disk and could not be read (%s). Nothing is known about these, and nothing above counts them as changed, deleted or matching:\n' "$unreadable"
    LC_ALL=C sed 's/^/  /' "$unread"
  fi
  # Summarised rather than listed. Obsidian rewrites its own config whenever the
  # interface changes and the docs tell you to delete the example notes, so every
  # vault drifts here, and listing it on every run is how a report teaches people
  # to stop reading it.
  if [ "$seed_drift" -gt 0 ]; then
    printf '\n%s file(s) that were shipped once and are yours now have changed, been deleted, or moved upstream. That is expected and is not listed.\n' "$seed_drift"
  fi
}

# ---------------------------------------------------------------- status --

do_status() {
  local owned same drifted deleted unreadable
  refuse_if_held
  need_hash_tool
  load_local_manifest

  LC_ALL=C awk '{ print $4 }' "$TMPD/local.entries" > "$TMPD/st.paths"
  hash_paths "$ROOT" "$TMPD/st.paths" "$TMPD/st.hashes" || exit 2
  LC_ALL=C awk '{ print "N " $1 " " $2 }' "$TMPD/st.hashes" > "$TMPD/st.now"
  LC_ALL=C awk '{ print "U " $0 }' "$TMPD/st.hashes.unreadable" > "$TMPD/st.unread"
  join_state no "$TMPD/local.entries" "$TMPD/st.now" "$TMPD/st.unread" > "$TMPD/st.state0"
  add_normalised "$TMPD/st.state0" "$TMPD/st.norm" || exit 2
  join_state no "$TMPD/local.entries" "$TMPD/st.now" "$TMPD/st.unread" "$TMPD/st.norm" > "$TMPD/st.state"

  owned="$(LC_ALL=C awk '$2 == "owned" { n++ } END { print n + 0 }' "$TMPD/st.state")"
  same="$(verdict_count "$TMPD/st.state" same owned)"
  drifted="$(verdict_count "$TMPD/st.state" drifted owned)"
  deleted="$(verdict_count "$TMPD/st.state" deleted owned)"
  unreadable="$(awk 'END { print NR + 0 }' "$TMPD/st.hashes.unreadable")"

  say "this vault records template version $LOCAL_VERSION."
  say "$same of $owned template file(s) match that record, $drifted changed here, $deleted deleted, $unreadable could not be read."
  say "That record is what the template shipped at $LOCAL_VERSION. It is not a claim about what the template holds now. Fetch a newer copy and run --check --from <dir> to learn that."
  # Said here because the shape of this mode makes it unavoidable and a reader
  # would otherwise take the count personally. With no source there is nothing
  # for a file to have moved towards, so a file you took from a newer template
  # on somebody's advice is a file that differs from the record, and it is
  # counted above as one you changed. It stays counted that way until a newer
  # baseline is recorded, and --check against the copy you took it from is what
  # tells the two apart.
  say "Taking a file from a newer template copy also shows up here as one you changed, because this mode has nothing to compare against but the record."
  report_local "$TMPD/st.state" "$TMPD/st.hashes.unreadable"

  # Ahead of the 10, because a file that could not be opened is this saying it
  # could not look, and that has to outrank a finding drawn from the files it
  # could.
  if [ "$unreadable" -gt 0 ]; then
    warn "Some of what this vault records could not be read, so the counts above describe only the rest of it."
    return 2
  fi
  if [ "$drifted" -gt 0 ] || [ "$deleted" -gt 0 ]; then
    return 10
  fi
  return 0
}

# ----------------------------------------------------------------- check --

load_source() {  # load_source <dir>
  local dir="$1"
  if [ ! -d "$dir" ]; then
    warn "NO-SOURCE - $dir is not a directory, so there was nothing to compare against."
    exit 2
  fi
  if [ ! -f "$dir/$MANIFEST_REL" ]; then
    warn "NOT-A-TEMPLATE - $dir holds no $MANIFEST_REL, so it is not a copy of this template, or it predates this mechanism."
    exit 2
  fi
  load_manifest "$dir/$MANIFEST_REL" S "$TMPD/src.entries" "$TMPD/src.meta" || {
    warn "NOT-A-TEMPLATE - $dir/$MANIFEST_REL could not be read."
    exit 2
  }
  SOURCE_VERSION="$(LC_ALL=C awk '$1 == "version" { print $2; exit }' "$TMPD/src.meta")"
  SOURCE_ALGO="$(LC_ALL=C awk '$1 == "algo" { print $2; exit }' "$TMPD/src.meta")"
  [ -n "$SOURCE_VERSION" ] || SOURCE_VERSION="unknown"
  if [ -n "$SOURCE_ALGO" ] && [ "$SOURCE_ALGO" != "$HASH_ALGO" ]; then
    warn "UNKNOWN-ALGORITHM - $dir/$MANIFEST_REL says its hashes are $SOURCE_ALGO and this understands $HASH_ALGO only, so nothing was compared."
    exit 2
  fi
  # The same refusal the local side gets, and for a sharper reason. A truncated
  # or header-only source manifest parses cleanly and leaves no entries, and
  # every local path then looks retired upstream. A vault pointed at one would
  # be shown its entire template listed as no longer shipped, under a counts
  # line reading zero, and told that nothing had moved. On exit 0. This is the
  # input the reader controls least, so it gets the guard that exists for
  # exactly this.
  if [ "$(awk 'END { print NR + 0 }' "$TMPD/src.entries")" -eq 0 ]; then
    warn "SOURCE-VACUOUS - $dir/$MANIFEST_REL holds no entries, so there is nothing there to compare against and this says nothing about whether the template moved."
    exit 2
  fi
  # Ordered on purpose, cheapest refusal first. verify_source hashes every file
  # the source ships, and both guards below can turn the folder away outright,
  # so asking them first means an older or a hostile copy is refused before its
  # whole tree is read. --diff in particular used to hash the lot and only then
  # be told the pair could not be ordered.
  guard_versions "$dir"
  verify_source "$dir" || exit 2
}

# Whether two versions this understands are the same version.
#
# Asked through the comparator rather than with a string test, because the two
# were answering different questions. The read-time grammar accepts 1.0 and
# 1.0.0, which are the same number and different text, so the string test said
# they differed while version_older said neither was older, and the run went on
# to print a copy plan for a pair it had no ordering for. 1.01 against 1.1 is
# the same trick with one field. Equal is the comparator's own answer for it,
# which is neither one being older than the other.
versions_equal() {  # versions_equal <a> <b>
  version_older "$1" "$2" && return 1
  version_older "$2" "$1" && return 1
  return 0
}

# The version guard, in one place, so that --diff cannot answer a question
# --check has already refused. A reader who is told the two copies cannot be
# compared and then gets a confident diff from the same pair has been told two
# things.
#
# There is deliberately no branch here for a version this cannot parse. There
# used to be, and it was unreachable: read_manifest applies this same grammar to
# the header and refuses anything else as MANIFEST-MALFORMED long before either
# value arrives here, so the only shapes that reach this are the word unknown
# and digits separated by dots. A refusal that cannot fire is not a safeguard,
# it is a claim that there is one.
guard_versions() {  # guard_versions <dir>
  local dir="$1"
  [ "$LOCAL_VERSION" = unknown ] && return 0
  [ "$SOURCE_VERSION" = unknown ] && return 0
  if version_older "$SOURCE_VERSION" "$LOCAL_VERSION"; then
    warn "SOURCE-IS-OLDER - this vault records $LOCAL_VERSION and $dir is $SOURCE_VERSION, so there is nothing newer there and nothing was compared."
    exit 2
  fi
  return 0
}

# verify_source <dir>
# Checks that the folder holds what its own manifest says it holds.
#
# Without this, "safe to take" is the SOURCE'S CLAIM about the source, and the
# copy plan then tells a person to copy bytes that nothing in the run ever
# looked at. The enumeration and the thing being copied have to be the same
# object, or the promise that the exposure is shown before it happens is not
# kept.
#
# It is a coherence check, not a defence. Somebody who can rewrite a file in
# that folder can rewrite its manifest line too. What it does buy is that the
# manifest becomes the single artefact worth reading, and that a half-finished
# download or a partial clone is caught rather than presented as an update.
verify_source() {  # verify_source <dir>
  local dir="$1" missing differing rel walk rest
  LC_ALL=C awk '{ print $4 }' "$TMPD/src.entries" > "$TMPD/vs.paths"

  # A symlinked entry is refused outright, before anything is hashed or offered.
  # Every test here is -f or -r, and all of those follow a link, so a source
  # could ship .claude/hooks/h.sh as a link to anything readable on the machine
  # doing the checking, have it verify perfectly against its own manifest, and
  # have the printed copy plan copy the target's bytes into the vault. What the
  # reader was shown and what the plan moves would then both be a file the
  # source never contained. A template ships regular files.
  #
  # EVERY COMPONENT, not only the leaf. This used to be a single test of
  # `$dir/$rel`, which is false when the link is a DIRECTORY on the way to the
  # file - `[ -L "$dir/docs/a.md" ]` says nothing at all about `$dir/docs`. A
  # source could therefore ship one link named `docs` and walk every entry
  # under it past a check whose whole job was to stop exactly that, while
  # verifying against its own manifest perfectly. The walk is written with
  # parameter expansion rather than a command substitution per component
  # because this runs once per manifest entry and a fork there is what made an
  # earlier version of the hashing unusable on Windows.
  : > "$TMPD/vs.links"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    walk="$dir"
    rest="$rel"
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) walk="$walk/${rest%%/*}"; rest="${rest#*/}" ;;
        *)   walk="$walk/$rest";       rest='' ;;
      esac
      if [ -L "$walk" ]; then
        printf '%s\n' "$rel" >> "$TMPD/vs.links"
        break
      fi
    done
  done < "$TMPD/vs.paths"
  if [ -s "$TMPD/vs.links" ]; then
    warn "SOURCE-SYMLINK - $dir reaches these through a symbolic link rather than holding them as files, so what was hashed and what a copy would move is whatever it points at: $(name_a_few "$TMPD/vs.links")"
    warn "A template ships regular files. Nothing was compared."
    return 1
  fi

  hash_paths "$dir" "$TMPD/vs.paths" "$TMPD/vs.raw" || return 1
  # An entry the source names and cannot open is a refusal, not a shrug. This
  # used to fall through, because the check below only ever refused on drifted
  # and deleted, so a dangling link or an unreadable file was warned about on
  # standard error and the folder was then accepted as a trustworthy update.
  if [ -s "$TMPD/vs.raw.unreadable" ]; then
    warn "SOURCE-UNREADABLE - $dir names these in its own manifest and they could not be read, so whether it holds what it says it holds is unknown: $(name_a_few "$TMPD/vs.raw.unreadable")"
    warn "A half-finished download and a dangling link both look like this. Fetch it again. Nothing was compared."
    return 1
  fi
  LC_ALL=C awk '{ print "N " $1 " " $2 }' "$TMPD/vs.raw" > "$TMPD/vs.now"
  # Retagged to L, and this is load bearing rather than tidy. Here the source's
  # own manifest IS the record being compared against, so it has to arrive on
  # the side join_state treats as the record. Left tagged S it lands on the
  # upstream side with nothing opposite it, every path comes back as new, and
  # the check reports nothing whatever the folder holds. The control for this
  # caught it.
  LC_ALL=C sed 's/^S /L /' "$TMPD/src.entries" > "$TMPD/vs.entries"
  # Standard error is NOT discarded here. It used to be, on the one input the
  # reader controls least, and join_state writes nothing to it in normal
  # operation, so the only thing the redirection could ever hide was awk failing
  # on a source manifest somebody else wrote.
  join_state no "$TMPD/vs.entries" "$TMPD/vs.now" > "$TMPD/vs.state0"

  # The same carriage-return retry the local side gets, so a source cloned on a
  # machine that checks out CRLF is not reported as corrupt.
  LC_ALL=C awk '$1 == "drifted" { print $3 }' "$TMPD/vs.state0" > "$TMPD/vs.normlist"
  : > "$TMPD/vs.norm"
  if [ -s "$TMPD/vs.normlist" ]; then
    hash_paths_normalised "$dir" "$TMPD/vs.normlist" "$TMPD/vs.normhash" || return 1
    LC_ALL=C awk '{ print "M " $1 " " $2 }' "$TMPD/vs.normhash" > "$TMPD/vs.norm"
  fi
  join_state no "$TMPD/vs.entries" "$TMPD/vs.now" "$TMPD/vs.norm" > "$TMPD/vs.state"

  # Through name_a_few rather than head, so a source manifest claiming five
  # hundred paths tells the reader there were five hundred rather than naming
  # three and leaving the rest unmentioned. These were the last three lists in
  # this script still truncating silently.
  LC_ALL=C awk '$1 == "drifted" { print $3 }' "$TMPD/vs.state" > "$TMPD/vs.differing"
  LC_ALL=C awk '$1 == "deleted" { print $3 }' "$TMPD/vs.state" > "$TMPD/vs.missing"
  differing="$(name_a_few "$TMPD/vs.differing")"
  missing="$(name_a_few "$TMPD/vs.missing")"
  if [ -n "$differing" ] || [ -n "$missing" ]; then
    warn "SOURCE-DISAGREES - $dir does not hold what its own manifest says it holds, so nothing there can be trusted as an update."
    [ -n "$differing" ] && warn "Different from its own record: $differing"
    [ -n "$missing" ] && warn "Named by its record and not on its disk: $missing"
    warn "A half-finished download or a partial clone looks like this. Fetch it again. Nothing was compared."
    return 1
  fi
  return 0
}

version_older() {  # version_older <a> <b>, true when a is older than b
  LC_ALL=C awk -v a="$1" -v b="$2" '
    BEGIN {
      na = split(a, x, "."); nb = split(b, y, ".")
      n = (na > nb) ? na : nb
      for (i = 1; i <= n; i++) {
        xi = (i <= na) ? x[i] + 0 : 0
        yi = (i <= nb) ? y[i] + 0 : 0
        if (xi < yi) exit 0
        if (xi > yi) exit 1
      }
      exit 1
    }'
}

do_check() {  # do_check <dir>
  local dir="$1" take merge new retired differing collision converged unreadable plan_digests
  refuse_if_held
  need_hash_tool
  load_local_manifest
  load_source "$dir"

  LC_ALL=C awk '{ print $4 }' "$TMPD/local.entries" > "$TMPD/ck.paths"
  hash_paths "$ROOT" "$TMPD/ck.paths" "$TMPD/ck.hashes" || exit 2
  LC_ALL=C awk '{ print "N " $1 " " $2 }' "$TMPD/ck.hashes" > "$TMPD/ck.now"
  LC_ALL=C awk '{ print "U " $0 }' "$TMPD/ck.hashes.unreadable" > "$TMPD/ck.unread"
  join_state yes "$TMPD/local.entries" "$TMPD/src.entries" "$TMPD/ck.now" "$TMPD/ck.unread" > "$TMPD/ck.state0"
  add_normalised "$TMPD/ck.state0" "$TMPD/ck.norm" || exit 2
  join_state yes "$TMPD/local.entries" "$TMPD/src.entries" "$TMPD/ck.now" "$TMPD/ck.unread" "$TMPD/ck.norm" > "$TMPD/ck.joined"
  mark_collisions "$TMPD/ck.joined" "$TMPD/ck.state"

  # Two copies claiming one version and disagreeing. "Use this template" copies
  # the default branch at that moment, which is routinely ahead of the last
  # release, so a vault can carry 1.0.0 with content from after 1.0.0. Comparing
  # two such copies by their version numbers gives a confident wrong answer.
  #
  # Sameness is the comparator's answer and not a string test, because the two
  # disagreed about 1.0 against 1.0.0 and about 1.01 against 1.1. Those pairs
  # are equal to version_older and different to a string test, so the guard let
  # them past and the run printed a copy plan for a pair it could not order.
  if [ "$LOCAL_VERSION" != unknown ] && [ "$SOURCE_VERSION" != unknown ] \
     && versions_equal "$LOCAL_VERSION" "$SOURCE_VERSION"; then
    # Collisions are counted here too. They are new files under another name,
    # and leaving them out would let two copies that disagree only about files
    # the user already occupies be compared by their version numbers anyway.
    # deleted counts here too. It is a manifest disagreement like any other, and
    # leaving it out let two copies that both claim one version and differ only
    # about files the owner had deleted walk past this guard and be compared by
    # their version numbers anyway.
    differing="$(LC_ALL=C awk '$1 != "same" { n++ } END { print n + 0 }' "$TMPD/ck.state")"
    if [ "$differing" -gt 0 ]; then
      warn "SAME-VERSION-DISAGREES - this vault and $dir both say they are $SOURCE_VERSION and their manifests differ in $differing file(s), so their version numbers cannot be compared."
      warn "One of them is most likely a copy of the default branch taken between releases. Nothing was concluded about which is newer."
      exit 2
    fi
  fi

  take="$(verdict_count "$TMPD/ck.state" take owned)"
  merge="$(verdict_count "$TMPD/ck.state" merge owned)"
  new="$(verdict_count "$TMPD/ck.state" new owned)"
  retired="$(verdict_count "$TMPD/ck.state" retired owned)"
  collision="$(verdict_count "$TMPD/ck.state" collision owned)"
  converged="$(verdict_count "$TMPD/ck.state" converged owned)"
  unreadable="$(awk 'END { print NR + 0 }' "$TMPD/ck.hashes.unreadable")"

  # Four numbers, because three left one of the sections below with no number
  # above it. A run whose only finding was converged printed nothing moved
  # upstream, nothing changed here and nothing safe to take, directly above a
  # section listing files that had moved upstream. Converged is deliberately not
  # folded into the first number instead, because the exit code hangs off that
  # number and there is genuinely nothing to do about a file already taken.
  say "$(( take + merge + new + collision )) moved upstream, $(( merge + collision )) also changed here, $(( take + new )) safe to take, $converged already taken (recorded $LOCAL_VERSION, source $SOURCE_VERSION)."

  if [ "$(( take + new ))" -gt 0 ]; then
    # The digest beside each path is the one this run measured out of the source
    # folder, from vs.raw, and not the one the source manifest claims. The two
    # are equal by the time anything is printed, because verify_source refuses
    # the whole folder when they are not, so the choice is only about which
    # question the number answers. What a reader can check with sha256sum is
    # the bytes, so the number printed is the one taken from the bytes.
    #
    # This closes the one gap nothing in the script can close on its own.
    # Between the moment these digests were taken and the moment somebody
    # pastes the copy plan below there is a person reading, and nothing
    # re-reads the folder across that gap. Printing the digest turns "trust
    # that it has not changed" into something the reader can settle in one
    # command.
    printf '\nSafe to take (%s). You have not touched these, so copying them loses nothing. The digest beside each one is what this run hashed out of %s, so you can check that what you copy is what was read:\n' "$(( take + new ))" "$dir"
    # Named into a variable with its absence handled, rather than handed to awk
    # and hoped for. verify_source always writes this file before anything here
    # runs, and if that ever stops being true awk would fail to open it, print
    # nothing at all, and empty the one list a reader acts on. A list that
    # vanished would read as nothing being safe to take, which is the quiet
    # direction.
    plan_digests="$TMPD/vs.raw"
    [ -f "$plan_digests" ] || plan_digests=/dev/null
    { list_paths "$TMPD/ck.state" take owned; list_paths "$TMPD/ck.state" new owned; } \
      | LC_ALL=C sort \
      | LC_ALL=C awk '
          NR == FNR { h[$2] = $1; next }
          { printf "  %s  %s\n", (($0 in h) ? h[$0] : "digest-unknown"), $0 }
        ' "$plan_digests" -
  fi
  if [ "$merge" -gt 0 ]; then
    printf '\nMoved upstream and changed here (%s). Nothing will overwrite these. Read each one with --diff and merge it yourself:\n' "$merge"
    list_paths "$TMPD/ck.state" merge owned | LC_ALL=C sed 's/^/  /'
  fi
  if [ "$collision" -gt 0 ]; then
    printf '\nThe template now ships a file where you already have one (%s). These are NOT safe to take, because the record of what the template shipped has never held them and nothing here can tell your file from an old copy of theirs. Look at each one yourself:\n' "$collision"
    list_paths "$TMPD/ck.state" collision owned | LC_ALL=C sed 's/^/  /'
  fi
  if [ "$retired" -gt 0 ]; then
    printf '\nNo longer shipped by the template (%s). They are left exactly where they are, because this never deletes:\n' "$retired"
    list_paths "$TMPD/ck.state" retired owned | LC_ALL=C sed 's/^/  /'
  fi
  if [ "$converged" -gt 0 ]; then
    printf '\nAlready carrying the newer copy (%s). You took these at some point, so there is nothing to do and nothing to merge. Until a newer baseline is recorded they still differ from the record, so --status counts them among the files you changed:\n' "$converged"
    list_paths "$TMPD/ck.state" converged owned | LC_ALL=C sed 's/^/  /'
  fi

  report_local "$TMPD/ck.state" "$TMPD/ck.hashes.unreadable"

  if [ "$(( take + new ))" -gt 0 ]; then
    # The preamble says what the plan is a statement ABOUT. It describes the
    # folder as it was when this run read it, and nothing re-reads it between
    # then and whenever somebody pastes the commands. That gap is a person
    # reading rather than a race inside the script, so it cannot be closed in
    # code, and a plan that did not say so would be read as a promise about the
    # folder now.
    printf '\nTo take the safe ones, read them first and then run these from the vault root. This plan describes %s as it was when this run hashed it, and nothing re-reads that folder between now and whenever you paste, so run --check again if it may have moved since:\n' "$dir"
    # Both sides quoted, and the destination prefixed with ./ . Manifest paths
    # cannot hold whitespace or a shell metacharacter, so that side was already
    # safe, but the source folder comes from --from and is not filtered at all.
    # A vault under a path with a space in it is ordinary on Windows, and the
    # unquoted form turned one copy into a three-operand command. The ./ prefix
    # stops a path that begins with a dash presenting itself as an option.
    { list_paths "$TMPD/ck.state" take owned; list_paths "$TMPD/ck.state" new owned; } \
      | LC_ALL=C sort \
      | vu_from="$dir" LC_ALL=C awk '
          # The folder comes in through the ENVIRONMENT rather than through
          # -v, and that is not a style choice. POSIX requires a -v assignment
          # to undergo string-literal escape processing, and every awk in this
          # matrix does it, so a perfectly ordinary Windows path like
          # C:\temp\new has its \t and \n turned into a tab and a newline
          # before the plan is printed. Worse, \047 is octal for a single
          # quote, and from_is_printable allows a backslash and digits on
          # purpose for Windows paths, so a crafted --from could close the very
          # quoting that function exists to apply. ENVIRON values are not
          # escape-processed.
          BEGIN { q = sprintf("%c", 39); d = ENVIRON["vu_from"] }
          {
            p = $0
            n = split(p, part, "/")
            if (n > 1) {
              # Cut by length rather than by building a regex out of the file
              # name. sub() would read the dots in that name as wildcards, and
              # it would match the LAST place the pattern happened to fit,
              # which is the same place only by luck.
              p = substr(p, 1, length(p) - length(part[n]) - 1)
              printf "  mkdir -p %s./%s%s && cp %s%s/%s%s %s./%s%s\n", \
                q, p, q, q, d, $0, q, q, $0, q
            } else {
              printf "  cp %s%s/%s%s %s./%s%s\n", q, d, $0, q, q, $0, q
            }
          }'
    printf '\nCopying a file out of %s puts whoever wrote it in charge of what your harness runs. Read the diff first.\n' "$dir"
  fi

  # The could-not-look answer outranks both of the others, for the same reason
  # it does under --status. A file that could not be opened is missing from
  # every count above, so those counts describe part of the vault and the exit
  # code has to say so.
  if [ "$unreadable" -gt 0 ]; then
    warn "Some of what this vault records could not be read, so the counts above describe only the rest of it."
    return 2
  fi
  if [ "$(( take + merge + new + collision ))" -gt 0 ]; then
    return 10
  fi
  say "nothing has moved upstream that this vault does not already have."
  return 0
}

# ------------------------------------------------------------------ diff --

do_diff() {  # do_diff <dir>
  local dir="$1" p trouble=0 rc local_side
  refuse_if_held
  need_hash_tool
  load_local_manifest
  load_source "$dir"

  LC_ALL=C awk '{ print $4 }' "$TMPD/local.entries" > "$TMPD/df.paths"
  hash_paths "$ROOT" "$TMPD/df.paths" "$TMPD/df.hashes" || exit 2
  LC_ALL=C awk '{ print "N " $1 " " $2 }' "$TMPD/df.hashes" > "$TMPD/df.now"
  LC_ALL=C awk '{ print "U " $0 }' "$TMPD/df.hashes.unreadable" > "$TMPD/df.unread"
  join_state yes "$TMPD/local.entries" "$TMPD/src.entries" "$TMPD/df.now" "$TMPD/df.unread" > "$TMPD/df.state0"
  add_normalised "$TMPD/df.state0" "$TMPD/df.norm" || exit 2
  join_state yes "$TMPD/local.entries" "$TMPD/src.entries" "$TMPD/df.now" "$TMPD/df.unread" "$TMPD/df.norm" > "$TMPD/df.joined"
  mark_collisions "$TMPD/df.joined" "$TMPD/df.state"

  # The same could-not-look answer the other two modes give, and it was missing
  # here. --diff built the unreadable stream exactly like them and then read it
  # nowhere, so a vault whose one interesting template file could not be opened
  # was told there was nothing to show, on exit 0, while --status on the same
  # vault said it could not look and left on 2.
  df_unreadable="$(awk 'END { print NR + 0 }' "$TMPD/df.hashes.unreadable")"
  if [ "$df_unreadable" -gt 0 ]; then
    warn "UNREADABLE - these are on disk and could not be read, so what follows is not the whole answer: $(name_a_few "$TMPD/df.hashes.unreadable")"
  fi

  LC_ALL=C awk '($1 == "take" || $1 == "merge" || $1 == "new" || $1 == "collision") && $2 == "owned" { print $3 }' "$TMPD/df.state" > "$TMPD/df.list"
  if [ ! -s "$TMPD/df.list" ]; then
    if [ "$df_unreadable" -gt 0 ]; then
      warn "Nothing could be shown for the files above, so this is not saying the two copies agree."
      return 2
    fi
    # Worded against what this actually established, which is not what it used
    # to claim. A run where every moved file is one the reader already took
    # reaches here, and the template side does differ from the RECORD in every
    # one of those cases. What it does not differ from is the disk.
    say "nothing to show, because nothing the template ships differs from what this vault already carries."
    return 0
  fi

  if ! have_diff_tool; then
    warn "NO-DIFF-TOOL - neither git nor diff could be used to show the changes, so they were not shown. --check still names the files."
    exit 2
  fi

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # A file the template has started shipping has no copy on this side, and
    # diffing a path that is not there prints nothing at all. An empty section
    # under a heading reads as "no change" for exactly the files worth reading
    # hardest, so the missing side is spelled as an empty file and the heading
    # says which case it is.
    local_side="$ROOT/$p"
    if [ ! -f "$local_side" ]; then
      local_side="/dev/null"
      printf '\n=== %s (new in the template, you have no copy) ===\n' "$p"
    else
      printf '\n=== %s ===\n' "$p"
    fi
    if command -v git >/dev/null 2>&1; then
      # --no-ext-diff and --no-textconv, and an empty attributes file, are the
      # whole reason this stays safe. git diff otherwise honours diff.external
      # and per-attribute textconv filters, and BOTH of those RUN A COMMAND
      # named in configuration, which would be a way for the folder this
      # promises never to execute to get a command run out of it anyway.
      GIT_TERMINAL_PROMPT=0 git -c core.attributesFile=/dev/null -c core.fsmonitor=false \
        -c diff.external= diff --no-index --no-ext-diff --no-textconv \
        -- "$local_side" "$dir/$p" 2>/dev/null
      rc=$?
      # git diff exits 1 when the two differ, which is the ordinary case here,
      # and 128 when it could not read one of them. Swallowing that would print
      # an empty section under a heading and call it no change, which is the
      # same "reported that it could not look as though it had looked" the
      # fallback below already guards against. The doctrine has to hold on the
      # branch almost everybody takes, not only on the one that runs when git is
      # missing.
      [ "$rc" -ge 2 ] && trouble=1
    else
      diff -u -- "$local_side" "$dir/$p" 2>/dev/null
      rc=$?
      # diff exits 1 for a difference and 2 or more for trouble. Only trouble is
      # trouble, and folding the two together is how a comparison tool reports
      # that it could not look as though it had looked.
      [ "$rc" -ge 2 ] && trouble=1
    fi
  done < "$TMPD/df.list"

  if [ "$trouble" -eq 1 ]; then
    warn "DIFF-TROUBLE - diff could not read one or more of the pairs above, so what it printed is not the whole answer."
    exit 2
  fi
  if [ "$df_unreadable" -gt 0 ]; then
    warn "What was printed leaves out the files above that could not be read, so it is not the whole answer."
    return 2
  fi
  return 10
}

# ----------------------------------------------------------------- adopt --

do_adopt() {  # do_adopt <dir>
  local dir="$1" adopt_absent arel
  refuse_if_held
  # A hash tool is required even though adopting writes one file, because
  # a baseline that cannot then be compared against is not worth recording, and
  # finding that out now is kinder than finding it out on the first --status.
  need_hash_tool
  if [ -f "$ROOT/$MANIFEST_REL" ]; then
    warn "ALREADY-ADOPTED - this vault already has $MANIFEST_REL, so there is a baseline to compare against and --adopt would replace it."
    warn "Run --status to see what it says. To adopt a different baseline on purpose, delete $MANIFEST_REL first and run this again. Nothing was written."
    # 11 rather than 64, because the command line was perfectly well formed and
    # this is a refusal about the state of the vault. A caller reading 64 would
    # be told to check its arguments, which is the wrong thing to check. And 11
    # rather than 3, because the retention runner already answers 3 for a
    # partial pass and docs/reference.md publishes one numbering across all four
    # scripts so that a caller need not know which it ran.
    exit 11
  fi
  load_source "$dir"

  # The manifest is REBUILT from the entries this run validated, rather than
  # copied byte for byte out of the source.
  #
  # The bytes were never verified and could not have been. verify_source hashes
  # the ENTRIES of the source manifest, and the manifest is excluded from every
  # manifest by design, so it is the one file in that folder no hash of this
  # run ever reaches. Copying it made those unverified bytes into this vault's
  # permanent provenance record, which every later --status and every
  # vault-check.sh full scan then reads. Writing the parsed entries back out
  # means what is recorded is exactly what this run accepted, after the path
  # validation and after the narrowing, and a line this run would have refused
  # cannot be in the file.
  {
    printf '%s\n' "# .claude/template-manifest"
    printf '%s\n' "#"
    printf '%s\n' "# Recorded by .claude/scripts/vault-update.sh --adopt as this vault's"
    printf '%s\n' "# baseline. Do not hand edit."
    printf '%s\n' "#"
    printf '%s\n' "# This records what the template shipped at the version named below. It is"
    printf '%s\n' "# NOT a claim about what is on this disk now."
    printf '%s\n' "#"
    printf '%s\n' '# Each entry is "<class> <sha256> <path>". owned is template machinery and'
    printf '%s\n' "# seed was shipped once and is yours now. Paths absent from this file are"
    printf '%s\n' "# yours and are never read."
    # Omitted rather than written as the word unknown when the source names no
    # version. read_manifest refuses that word as a malformed header, so writing
    # it would produce a baseline this vault could never read back.
    [ "$SOURCE_VERSION" = unknown ] || printf 'version %s\n' "$SOURCE_VERSION"
    printf 'hash %s\n' "$HASH_ALGO"
    LC_ALL=C awk '{ print $2 " " $3 " " $4 }' "$TMPD/src.entries" | LC_ALL=C sort -k3,3
  } > "$TMPD/adopt.manifest"
  cp "$TMPD/adopt.manifest" "$ROOT/$MANIFEST_REL" || {
    warn "could not write $MANIFEST_REL"
    exit 1
  }

  # VERSION is deliberately NOT copied, even though a vault that predates all of
  # this has none. Six places in this repository say the manifest is the only
  # file this ever writes, and one of them is the line printed immediately
  # below, so a second write would make that line false at the moment it is
  # read. Nothing needs VERSION either: the version this tool reports comes from
  # the manifest's own header, and so does the line vault-check.sh prints.
  # Writing one is a person's job and takes one command.
  #
  # What that costs has to be said out loud, and it was not. Every owned entry
  # naming a file this vault does not have reads as deleted from the next
  # --status onwards, and VERSION is the one almost every pre-manifest vault is
  # missing precisely because this refuses to write it. A count nobody was
  # warned about is a report that looks like a finding.
  LC_ALL=C awk '$2 == "owned" { print $4 }' "$TMPD/src.entries" > "$TMPD/adopt.owned"
  adopt_absent=0
  while IFS= read -r arel; do
    [ -n "$arel" ] || continue
    [ -e "$ROOT/$arel" ] || adopt_absent=$((adopt_absent + 1))
  done < "$TMPD/adopt.owned"

  say "recorded $SOURCE_VERSION as this vault's baseline, from $dir. Only the manifest was written and no other file was touched."
  say "READ THIS. Every template file you had already changed before now is recorded as though the template shipped it that way, so from here on it reads as untouched."
  if [ "$adopt_absent" -gt 0 ]; then
    say "$adopt_absent template file(s) named by that baseline are not in this vault, so --status will report them as deleted until you either add them or accept the count. VERSION is normally one of them, because this does not write it for you."
  fi
  say "Adopt against the oldest release you might have started from, then run --status to see what the baseline now claims."
  return 0
}

# ------------------------------------------------------------------ main --

TMPD="$(mktemp -d 2>/dev/null || mktemp -d -t vaultupdate)" || {
  warn "could not create a temporary directory"
  exit 2
}
# Asserted once, because a backslash here would be silent and would fail in the
# reassuring direction. Several awk programs receive a temporary file's path
# through -v, and a -v assignment is escape processed, so a Windows-form TMPDIR
# would have awk write its findings to a mangled path. Every later read of that
# file then comes back empty, and the escape, malformed, badhash and narrowed
# refusals all go quiet at once while the run reports success. mktemp gives a
# forward-slash path on all five platforms, so this never fires in practice,
# which is exactly why it would not be noticed if it did.
case "$TMPD" in
  *\\*)
    warn "TMPDIR-BACKSLASH - the temporary directory is [$TMPD] and a backslash there is read as an escape by the tools this hands it to, so findings would be written somewhere nothing reads them back."
    warn "Set TMPDIR to a path written with forward slashes and run this again. Nothing was compared."
    exit 2
    ;;
esac
cleanup() {
  cd / 2>/dev/null || true
  [ -n "${TMPD:-}" ] && rm -rf "$TMPD" 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

MODE=""
FROM=""
# unknown rather than empty, because guard_versions reads it and --adopt runs
# with no local manifest at all. Empty made that guard compare the source
# against nothing and refuse the one mode whose whole purpose is to run in a
# vault that has no baseline yet.
LOCAL_VERSION="unknown"
LOCAL_ALGO=""
SOURCE_VERSION="unknown"
SOURCE_ALGO=""
GEN_VERSION=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --status|--check|--diff|--adopt|--generate|--verify-manifest|--help)
      [ -n "$MODE" ] && die_usage "name one mode, not both $MODE and $1."
      MODE="$1"
      ;;
    --from)
      shift
      [ "$#" -gt 0 ] || die_usage "--from needs a directory after it."
      FROM="$1"
      ;;
    --from=*) FROM="${1#--from=}" ;;
    -h) MODE="--help" ;;
    *) die_usage "unknown argument $1." ;;
  esac
  shift
done

[ -n "$MODE" ] || MODE="--help"

case "$MODE" in
  --help) usage; exit 0 ;;
  --status) do_status; exit $? ;;
  --generate) do_generate; exit $? ;;
  --verify-manifest) do_verify_manifest; exit $? ;;
  --check|--diff|--adopt)
    [ -n "$FROM" ] || die_usage "$MODE needs --from <dir>, a template copy you fetched yourself."
    from_is_printable "$FROM" || die_usage "the folder named by --from holds a character this will not print. A quote or a control byte there would land in the copy commands this prints for you to run, so move the folder somewhere plainly named and try again."
    case "$MODE" in
      --check) do_check "$FROM"; exit $? ;;
      --diff)  do_diff  "$FROM"; exit $? ;;
      --adopt) do_adopt "$FROM"; exit $? ;;
    esac
    ;;
esac
exit 64
