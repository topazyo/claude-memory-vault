#!/usr/bin/env bash
# .claude/hooks/vault-lint.sh
# Non-blocking post-write audit. Checks a just-written vault note for the
# mandatory tier/type frontmatter (see .claude/rules/vault-notes.md and
# .claude/rules/verification.md), and scans for invisible zero-width/bidi
# control codepoints (the "Rules File Backdoor" class of attack, where a
# steering file carries instructions no reviewer can see). ALWAYS exits 0 —
# advisory only, never blocks.
#
# Harness-neutral. Two ways in:
#   vault-lint.sh [--] <file>...   lint the named files. For a git hook, an
#                                  editor, CI, or any harness whose post-write
#                                  hook can pass a path. Never reads stdin.
#   <hook JSON> | vault-lint.sh    read the written path from a harness's hook
#                                  input (Claude Code's PostToolUse shape, or
#                                  any JSON with a file_path or path field).
#
# DEGRADE LOUDLY. Every optional dependency below is guarded, and a missing one
# produces a visible warning rather than a silent pass. A security scan that
# cannot run must never be indistinguishable from a security scan that found
# nothing.

# Resolve the vault from this script's own location when CLAUDE_PROJECT_DIR is
# unset, like the other two hooks - never from the current directory, which
# would scatter .claude/logs/ folders wherever the hook happened to be invoked.
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
LOG_DIR="$ROOT/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG="$LOG_DIR/vault-lint.log"
# `date -Iseconds` is GNU-only; BSD/macOS date has no -I. Fall back to an
# explicit ISO-8601 format so the log has ONE shape on every platform.
TS=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date)

# lint_file <path> - the whole check for one file. Returns, never exits, so
# argument mode can lint several files in one call.
lint_file() {
  local FILE="$1" NORM IS_CONTENT_TIER IS_CHAR_SCAN_SCOPE warn FM HITS HITS_FMT HITS_JOINED SCAN_RAN

  # normalize backslashes -> forward slashes for git-bash / MSYS.
  # The backslash is written as the octal escape \134: spelled literally, GNU tr
  # emits an "unescaped backslash at end of string" warning to stderr on every
  # single invocation, which a harness surfaces as hook noise on every write.
  NORM=$(printf '%s' "$FILE" | tr '\134' '/')

  # markdown only, never templates
  case "$NORM" in *.md) ;; *) return 0 ;; esac
  case "$NORM" in */templates/*) return 0 ;; esac

  # content tiers: the mandatory tier/type frontmatter check applies here only
  IS_CONTENT_TIER=0
  case "$NORM" in
    *"/01-inbox/"*|*"/10-daily/"*|*"/20-projects/"*|*"/30-knowledge/"*|*"/31-standards/"*|*"/40-llm-wiki/"*) IS_CONTENT_TIER=1 ;;
    01-inbox/*|10-daily/*|20-projects/*|30-knowledge/*|31-standards/*|40-llm-wiki/*) IS_CONTENT_TIER=1 ;;
  esac

  # character-scan scope: content tiers PLUS every file that steers an agent -
  # .claude/rules/, .claude/agents/, .claude/skills/, and the instruction files
  # the common harnesses load at startup (AGENTS.md, CLAUDE.md, GEMINI.md,
  # .github/copilot-instructions.md). The Rules File Backdoor targets exactly
  # these steering files, which the tier-scoped frontmatter check above never
  # reaches. The instruction files are the ones loaded most eagerly, so leaving
  # them out would scan the lazily-loaded files and skip the always-loaded ones.
  # Widen this scan only, not the frontmatter check.
  IS_CHAR_SCAN_SCOPE=$IS_CONTENT_TIER
  case "$NORM" in
    *"/.claude/rules/"*|*"/.claude/agents/"*|*"/.claude/skills/"*) IS_CHAR_SCAN_SCOPE=1 ;;
    .claude/rules/*|.claude/agents/*|.claude/skills/*) IS_CHAR_SCAN_SCOPE=1 ;;
    */CLAUDE.md|CLAUDE.md|*/AGENTS.md|AGENTS.md|*/GEMINI.md|GEMINI.md) IS_CHAR_SCAN_SCOPE=1 ;;
    */.github/copilot-instructions.md|.github/copilot-instructions.md) IS_CHAR_SCAN_SCOPE=1 ;;
  esac

  [ "$IS_CONTENT_TIER" = 1 ] || [ "$IS_CHAR_SCAN_SCOPE" = 1 ] || return 0
  if [ ! -f "$NORM" ]; then
    echo "[$TS] DEGRADED: in-scope path does not resolve to a file, nothing was linted: $NORM" >> "$LOG"
    return 0
  fi

  warn=""

  if [ "$IS_CONTENT_TIER" = 1 ]; then
    if ! head -n1 "$NORM" | grep -q '^---[[:space:]]*$'; then
      warn="missing YAML frontmatter"
    else
      # Identical to fm_of() in .claude/scripts/vault-check.sh - both fences
      # anchored - so the hook and the checker agree on where frontmatter ends.
      # An unanchored /^---/ would end it at any line merely STARTING with dashes.
      FM=$(awk 'NR==1&&/^---[ \t\r]*$/{f=1;next} f&&/^---[ \t\r]*$/{exit} f{print}' "$NORM")
      printf '%s\n' "$FM" | grep -q '^tier:' || warn="${warn:+$warn; }missing 'tier'"
      printf '%s\n' "$FM" | grep -q '^type:' || warn="${warn:+$warn; }missing 'type'"
    fi
  fi

  # Zero-width (U+200B-200D, U+FEFF) and bidi control (U+202A-202E, U+2066-2069).
  #
  # PORTABILITY: `grep -P` is a GNU extension. BSD grep (macOS) does not have it,
  # and `grep -oP ... 2>/dev/null` there returns EMPTY — reporting every file
  # clean while scanning nothing. Prefer perl, which is present on macOS and in
  # Git for Windows, and whose -CSD flag decodes input as UTF-8 (without it perl
  # uses byte semantics on a file argument and the codepoint classes never match).
  # If neither tool exists, say so; do not imply a clean result.
  HITS_FMT=""
  SCAN_RAN=0
  if command -v perl >/dev/null 2>&1; then
    SCAN_RAN=1
    HITS_FMT=$(perl -CSD -ne 'while (/([\x{200B}-\x{200D}\x{FEFF}\x{202A}-\x{202E}\x{2066}-\x{2069}])/g) { printf "line %d: U+%04X\n", $., ord($1); }' "$NORM" 2>/dev/null | head -n 5)
  elif echo x | grep -qP x 2>/dev/null; then
    SCAN_RAN=1
    HITS=$(grep -noP '[\x{200B}-\x{200D}\x{FEFF}\x{202A}-\x{202E}\x{2066}-\x{2069}]' "$NORM" 2>/dev/null | head -n 5)
    [ -n "$HITS" ] && HITS_FMT=$(printf '%s\n' "$HITS" | sed 's/:.*/: (invisible codepoint)/')
  fi

  if [ "$SCAN_RAN" = 0 ]; then
    warn="${warn:+$warn; }INVISIBLE-CHAR SCAN DID NOT RUN (no perl, no grep -P) — file NOT checked"
  elif [ -n "$HITS_FMT" ]; then
    HITS_JOINED=$(printf '%s' "$HITS_FMT" | paste -sd';' - | sed 's/;/; /g')
    warn="${warn:+$warn; }invisible/bidi chars: $HITS_JOINED"
  fi

  if [ -n "$warn" ]; then
    echo "[$TS] CONFORMANCE: $NORM — $warn" >> "$LOG"
    echo "vault-lint: $NORM — $warn (see .claude/rules/vault-notes.md)" >&2
  else
    echo "[$TS] OK: $NORM" >> "$LOG"
  fi
  return 0
}

# ------------------------------------------------------------ argument mode --
# Paths on the command line mean the caller is not a JSON-speaking hook, so
# stdin is never read: a git hook or an editor leaves stdin open, and a `cat`
# here would wait on it until the caller's timeout killed the lint.
# A lone `--` is still argument mode: a caller expanding an empty file list,
# such as `vault-lint.sh -- $(git diff --cached --name-only)` with nothing
# staged, must lint nothing and exit, not fall through to reading stdin.
ARG_MODE=0
if [ "${1:-}" = "--" ]; then
  ARG_MODE=1
  shift
fi
[ "$#" -gt 0 ] && ARG_MODE=1
if [ "$ARG_MODE" = 1 ]; then
  for f in "$@"; do
    lint_file "$f"
  done
  exit 0
fi

# ---------------------------------------------------------------- hook mode --
# No arguments and a terminal on stdin means someone ran the script by hand.
# Reading stdin would hang waiting for JSON that is never typed, so say how to
# call it instead - on stderr, and still exit 0, because this is advisory.
if [ -t 0 ]; then
  echo "vault-lint: no file given. Usage: vault-lint.sh <file>...  or pipe a harness's hook JSON on stdin." >&2
  exit 0
fi

INPUT=$(cat)

# jq is NOT bundled with Git for Windows, and without this guard a missing jq
# yields an empty FILE and the hook exits 0 having done nothing at all.
# VAULT_FORCE_NO_JQ=1 takes the no-jq branch even when jq is installed, so the
# fallback can be tested on a machine that has jq (run-tests.sh does exactly that).
if [ -z "${VAULT_FORCE_NO_JQ:-}" ] && command -v jq >/dev/null 2>&1; then
  # Claude Code nests the path under tool_input; other harnesses may put it at
  # the top level. file_path is preferred over path at either depth, which is
  # the same precedence the sed fallback below applies.
  FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .file_path // .tool_input.path // .path // empty' 2>/dev/null)
else
  # Minimal parse without jq: pull the first "file_path":"..." value with sed,
  # then undo JSON string escaping. That second step is not optional - on
  # Windows every separator arrives as a doubled backslash, so skipping it
  # yields C://Users//... , the -f test fails, and the hook lints nothing while
  # still exiting 0. Git for Windows ships no jq, so this is a realistic
  # default configuration, not an edge case.
  # file_path first, then path, at any depth - the same precedence as the jq
  # branch, so the two branches agree about which input names a file.
  FILE=$(printf '%s' "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [ -z "$FILE" ] && FILE=$(printf '%s' "$INPUT" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  FILE=$(printf '%s' "$FILE" | sed -e 's/\\\\/\\/g' -e 's/\\\//\//g' -e 's/\\"/"/g')
  echo "[$TS] DEGRADED: jq not found — using fallback path parse. Install jq for reliable linting." >> "$LOG"
  echo "vault-lint: jq not found; path parsing is degraded. Install jq." >&2
fi
# A post-write hook always names a file. An empty path is therefore an anomaly -
# malformed input or a parse failure - and it goes on the record instead of
# vanishing into a silent exit 0.
if [ -z "$FILE" ]; then
  echo "[$TS] DEGRADED: could not read a file path from the hook input; nothing was linted." >> "$LOG"
  exit 0
fi

lint_file "$FILE"
exit 0
