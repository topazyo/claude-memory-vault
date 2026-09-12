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

LOG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG="$LOG_DIR/vault-lint.log"
TS=$(date -Iseconds 2>/dev/null || date)

INPUT=$(cat)

# jq is NOT bundled with Git for Windows, and without this guard a missing jq
# yields an empty FILE and the hook exits 0 having done nothing at all.
if command -v jq >/dev/null 2>&1; then
  FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
else
  # Minimal fallback parse: pull the first "file_path":"..." value with sed.
  FILE=$(printf '%s' "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  echo "[$TS] DEGRADED: jq not found — using fallback path parse. Install jq for reliable linting." >> "$LOG"
  echo "vault-lint: jq not found; path parsing is degraded. Install jq." >&2
fi
[ -z "$FILE" ] && exit 0

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

# character-scan scope: content tiers PLUS .claude/rules/ and .claude/agents/.
# The Rules File Backdoor targets exactly these steering files, which the
# tier-scoped frontmatter check above never reaches — widen this scan only,
# not the frontmatter check.
IS_CHAR_SCAN_SCOPE=$IS_CONTENT_TIER
case "$NORM" in
  *"/.claude/rules/"*|*"/.claude/agents/"*|.claude/rules/*|.claude/agents/*) IS_CHAR_SCAN_SCOPE=1 ;;
esac

[ "$IS_CONTENT_TIER" = 1 ] || [ "$IS_CHAR_SCAN_SCOPE" = 1 ] || exit 0
[ -f "$NORM" ] || exit 0

warn=""

if [ "$IS_CONTENT_TIER" = 1 ]; then
  if ! head -n1 "$NORM" | grep -q '^---[[:space:]]*$'; then
    warn="missing YAML frontmatter"
  else
    FM=$(awk 'NR==1&&/^---/{f=1;next} f&&/^---/{exit} f{print}' "$NORM")
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
