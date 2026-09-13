#!/usr/bin/env bash
# .claude/hooks/vault-lint.sh
# Non-blocking PostToolUse audit. Checks a just-written vault note for the
# mandatory tier/type frontmatter (see .claude/rules/vault-notes.md and
# .claude/rules/verification.md), and scans for invisible zero-width/bidi
# control codepoints (the "Rules File Backdoor" class of attack, where a
# steering file carries instructions no reviewer can see). ALWAYS exits 0 —
# advisory only, never blocks.
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

INPUT=$(cat)

# jq is NOT bundled with Git for Windows, and without this guard a missing jq
# yields an empty FILE and the hook exits 0 having done nothing at all.
# VAULT_FORCE_NO_JQ=1 takes the no-jq branch even when jq is installed, so the
# fallback can be tested on a machine that has jq (run-tests.sh does exactly that).
if [ -z "${VAULT_FORCE_NO_JQ:-}" ] && command -v jq >/dev/null 2>&1; then
  FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
else
  # Minimal parse without jq: pull the first "file_path":"..." value with sed,
  # then undo JSON string escaping. That second step is not optional - on
  # Windows every separator arrives as a doubled backslash, so skipping it
  # yields C://Users//... , the -f test fails, and the hook lints nothing while
  # still exiting 0. Git for Windows ships no jq, so this is a realistic
  # default configuration, not an edge case.
  # The same two keys the jq branch accepts, in the same order, so the two
  # branches cannot disagree about which input names a file.
  FILE=$(printf '%s' "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [ -z "$FILE" ] && FILE=$(printf '%s' "$INPUT" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  FILE=$(printf '%s' "$FILE" | sed -e 's/\\\\/\\/g' -e 's/\\\//\//g' -e 's/\\"/"/g')
  echo "[$TS] DEGRADED: jq not found — using fallback path parse. Install jq for reliable linting." >> "$LOG"
  echo "vault-lint: jq not found; path parsing is degraded. Install jq." >&2
fi
# The hook is registered for Write|Edit only, and both always name a file. An
# empty path is therefore an anomaly - malformed input or a parse failure - and
# it goes on the record instead of vanishing into a silent exit 0.
if [ -z "$FILE" ]; then
  echo "[$TS] DEGRADED: could not read a file path from the hook input; nothing was linted." >> "$LOG"
  exit 0
fi

# normalize backslashes -> forward slashes for git-bash / MSYS.
# The backslash is written as the octal escape \134: spelled literally, GNU tr
# emits an "unescaped backslash at end of string" warning to stderr on every
# single invocation, which Claude Code surfaces as hook noise on every write.
NORM=$(printf '%s' "$FILE" | tr '\134' '/')

# markdown only, never templates
case "$NORM" in *.md) ;; *) exit 0 ;; esac
case "$NORM" in */templates/*) exit 0 ;; esac

# content tiers: the mandatory tier/type frontmatter check applies here only
IS_CONTENT_TIER=0
case "$NORM" in
  *"/01-inbox/"*|*"/10-daily/"*|*"/20-projects/"*|*"/30-knowledge/"*|*"/31-standards/"*|*"/40-llm-wiki/"*) IS_CONTENT_TIER=1 ;;
  01-inbox/*|10-daily/*|20-projects/*|30-knowledge/*|31-standards/*|40-llm-wiki/*) IS_CONTENT_TIER=1 ;;
esac

# character-scan scope: content tiers PLUS every file that steers the agent -
# .claude/rules/, .claude/agents/, .claude/skills/, and any CLAUDE.md or
# AGENTS.md. The Rules File Backdoor targets exactly these steering files, which
# the tier-scoped frontmatter check above never reaches. CLAUDE.md, AGENTS.md
# and the skills are the ones loaded most eagerly, so leaving them out would
# scan the lazily-loaded files and skip the always-loaded ones. Widen this scan
# only, not the frontmatter check.
IS_CHAR_SCAN_SCOPE=$IS_CONTENT_TIER
case "$NORM" in
  *"/.claude/rules/"*|*"/.claude/agents/"*|*"/.claude/skills/"*) IS_CHAR_SCAN_SCOPE=1 ;;
  .claude/rules/*|.claude/agents/*|.claude/skills/*) IS_CHAR_SCAN_SCOPE=1 ;;
  */CLAUDE.md|CLAUDE.md|*/AGENTS.md|AGENTS.md) IS_CHAR_SCAN_SCOPE=1 ;;
esac

[ "$IS_CONTENT_TIER" = 1 ] || [ "$IS_CHAR_SCAN_SCOPE" = 1 ] || exit 0
if [ ! -f "$NORM" ]; then
  echo "[$TS] DEGRADED: in-scope path does not resolve to a file, nothing was linted: $NORM" >> "$LOG"
  exit 0
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
exit 0
