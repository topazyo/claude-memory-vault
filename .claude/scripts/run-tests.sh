#!/usr/bin/env bash
# .claude/scripts/run-tests.sh
#
# Control suite for this vault's hooks and checkers.
#
# WHY THIS EXISTS, AND WHY IT IS SHAPED THIS WAY:
# Every check in here has BOTH a positive and a negative control. A lint hook
# that silently does nothing produces exactly the same output as a lint hook
# that found nothing wrong - "clean" and "did not run" are indistinguishable
# unless you first prove the instrument can detect a known-bad input.
#
# That is not a hypothetical. The invisible-character scan in vault-lint.sh
# relies on `grep -P`, a GNU extension that BSD grep (macOS) does not have; the
# original version redirected its error to /dev/null and reported every file
# clean on a Mac. The hook now prefers perl and warns when neither tool exists,
# and the positive controls below are what keep that honest.
#
# Usage:  bash .claude/scripts/run-tests.sh
# Exit:   0 = all controls passed, 1 = at least one failed.
# Writes: nothing outside a temporary directory, which is removed on exit.

set -u

# Say up front how long this takes, so a slow run is never mistaken for a hang.
# Every assertion starts fresh bash processes, and process start-up is far
# slower on Windows than on macOS or Linux. Output streams as each check lands.
printf 'run-tests: control suite for the hooks, the checker and the scheduled runners.\n'
printf 'run-tests: about a minute on macOS/Linux; several minutes on Windows. Results print as they complete.\n'

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
HOOK="$ROOT/.claude/hooks/vault-lint.sh"
CHECK="$ROOT/.claude/scripts/vault-check.sh"

pass=0
fail=0

ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# A temp dir with a SPACE in its name, on purpose: a vault living under
# "C:/Users/Some One/" or macOS iCloud's "~/Library/Mobile Documents/" is the
# case that word-splitting bugs break on, while still printing "0 violations".
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t vaultcheck)" || {
  printf 'run-tests: could not create a temporary directory\n' >&2
  exit 1
}
WORK="$TMP/some one/my vault"

# Cleanup must also EXIT on a signal. A cleanup-only trap on INT/TERM deletes
# the fixtures and then lets the script keep running against a directory that
# no longer exists, producing a cascade of failures that reads like a broken
# dependency. And cd out first, or the removal fails with "Device or resource busy".
cleanup() {
  cd / 2>/dev/null || true
  [ -n "${TMP:-}" ] && rm -rf "$TMP" 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

mkdir -p "$WORK/31-standards/templates" "$WORK/10-daily" "$WORK/20-projects/_logs"

# ---------------------------------------------------------------- fixtures --

# Invisible characters: a real U+200B zero-width space and a U+202E bidi override.
{
  printf -- '---\n'
  printf 'title: "probe"\n'
  printf 'tier: long\n'
  printf 'type: standard\n'
  printf -- '---\n\n'
  printf 'zero-width:\342\200\213 bidi:\342\200\256 done\n'
} > "$WORK/31-standards/probe.md"

# Fully conformant note. Must produce NO warning.
{
  printf -- '---\n'
  printf 'title: "clean"\n'
  printf 'tier: long\n'
  printf 'type: standard\n'
  printf 'created: "2026-01-01"\n'
  printf 'last_verified: "2026-02-01"\n'
  printf -- '---\n\n'
  printf 'ordinary text\n'
} > "$WORK/31-standards/clean.md"

# Frontmatter present but missing the two mandatory keys.
printf -- '---\ntitle: "bad"\n---\n\nno keys\n' > "$WORK/31-standards/bad.md"

# No frontmatter fence at all.
printf 'just a body\n' > "$WORK/10-daily/nofm.md"

# last_verified EARLIER than created (C4).
printf -- '---\ntitle: "x"\ntier: long\ntype: standard\ncreated: "2026-05-01"\nlast_verified: "2026-04-01"\n---\n\nbody\n' > "$WORK/31-standards/backwards.md"

# last_verified in the future (C5).
printf -- '---\ntitle: "x"\ntier: long\ntype: standard\ncreated: "2026-01-01"\nlast_verified: "2099-01-01"\n---\n\nbody\n' > "$WORK/31-standards/future.md"

# These two must be PRUNED, never reported, despite being malformed.
printf 'malformed template\n' > "$WORK/31-standards/templates/tpl.md"
printf 'malformed stub\n'     > "$WORK/20-projects/_logs/compaction-abc.md"

# A note whose own FILENAME contains spaces must still be scanned.
printf -- '---\ntitle: "y"\n---\n\nbody\n' > "$WORK/10-daily/a note with spaces.md"

# ------------------------------------------------------ vault-lint.sh tests --

lint() {
  # Backslashes are doubled because the value is interpolated into JSON, where a
  # lone \c is an invalid escape that jq rejects outright.
  local escaped
  escaped=$(printf '%s' "$1" | sed 's|\\|\\\\|g')
  printf '{"tool_input":{"file_path":"%s"}}' "$escaped" \
    | CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" 2>&1
}

# The hook emits a one-line notice when jq is absent - which is the normal state
# on a stock macOS box, since jq is not preinstalled there or in Git for Windows.
# That notice is the hook working as designed, so it must not be read as lint
# output. Strip it before asserting, and assert its presence separately below.
strip_notices() {
  grep -v 'jq not found' || true
}

expect_match() {
  local out; out=$(lint "$2" | strip_notices)
  if printf '%s' "$out" | grep -q "$3"; then ok "$1"
  else bad "$1 -- expected '$3', got: ${out:-<silence>}"; fi
}

expect_silent() {
  local out; out=$(lint "$2" | strip_notices)
  if [ -z "$out" ]; then ok "$1"
  else bad "$1 -- expected silence, got: $out"; fi
}

printf '\n=== vault-lint.sh (PostToolUse advisory lint) ===\n'

if [ ! -f "$HOOK" ]; then
  bad "vault-lint.sh not found at $HOOK"
else
  expect_match  "positive control: zero-width U+200B detected" "$WORK/31-standards/probe.md" "U+200B"
  expect_match  "positive control: bidi override U+202E detected" "$WORK/31-standards/probe.md" "U+202E"
  expect_silent "negative control: conformant note stays silent" "$WORK/31-standards/clean.md"
  expect_match  "missing 'tier' is reported"          "$WORK/31-standards/bad.md"  "missing 'tier'"
  expect_match  "missing 'type' is reported"          "$WORK/31-standards/bad.md"  "missing 'type'"
  expect_match  "absent frontmatter is reported"      "$WORK/10-daily/nofm.md"     "missing YAML frontmatter"

  # Windows-style path must normalise to the same verdict.
  win=$(printf '%s' "$WORK/31-standards/bad.md" | sed 's|/|\\|g')
  expect_match  "Windows backslash path normalises"   "$win" "missing 'tier'"

  # Argument mode: how a git hook, an editor, CI or any other harness calls it.
  lint_args() { CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" "$@" </dev/null 2>&1; }

  out_args=$(lint_args "$WORK/31-standards/bad.md" "$WORK/10-daily/nofm.md" | strip_notices)
  if printf '%s' "$out_args" | grep -q "bad.md.*missing 'tier'" \
     && printf '%s' "$out_args" | grep -q "nofm.md.*missing YAML frontmatter"; then
    ok "argument mode lints every file named on the command line"
  else
    bad "argument mode -- got: ${out_args:-<silence>}"
  fi

  out_args=$(lint_args -- "$WORK/31-standards/clean.md" | strip_notices)
  if [ -z "$out_args" ]; then ok "argument mode: conformant note after -- stays silent"
  else bad "argument mode: conformant note -- expected silence, got: $out_args"; fi

  # With arguments present, stdin must never be read. Feed hook JSON naming a
  # BAD note while the argument names a clean one: any output means stdin won.
  esc_bad=$(printf '%s' "$WORK/31-standards/bad.md" | sed 's|\\|\\\\|g')
  out_args=$(printf '{"tool_input":{"file_path":"%s"}}' "$esc_bad" \
    | CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" "$WORK/31-standards/clean.md" 2>&1 | strip_notices)
  if [ -z "$out_args" ]; then ok "argument mode ignores stdin, so an open stdin cannot hang it"
  else bad "argument mode read stdin -- got: $out_args"; fi

  # A lone -- (an empty file list expanded after it) is still argument mode.
  out_args=$(printf '{"tool_input":{"file_path":"%s"}}' "$esc_bad" \
    | CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" -- 2>&1 | strip_notices)
  if [ -z "$out_args" ]; then ok "a lone -- lints nothing and never falls through to stdin"
  else bad "a lone -- read stdin -- got: $out_args"; fi

  # Hook JSON with the path at the top level, not under tool_input.
  out_top=$(printf '{"file_path":"%s"}' "$esc_bad" | CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" 2>&1 | strip_notices)
  if printf '%s' "$out_top" | grep -q "missing 'tier'"; then ok "hook JSON with a top-level file_path is linted"
  else bad "top-level file_path -- got: ${out_top:-<silence>}"; fi

  if [ -f "$WORK/.claude/logs/vault-lint.log" ]; then
    ok "audit log written to .claude/logs/vault-lint.log"
  else
    bad "no audit log written"
  fi
fi

# ----------------------------------------------------- vault-check.sh tests --

printf '\n=== vault-check.sh (frontmatter invariants C1-C5) ===\n'

if [ ! -f "$CHECK" ]; then
  bad "vault-check.sh not found at $CHECK"
else
  out=$(CLAUDE_PROJECT_DIR="$WORK" bash "$CHECK" 2>&1)
  rc=$?

  present() {
    if printf '%s' "$out" | grep -q "$2"; then ok "$1"; else bad "$1"; fi
  }
  absent() {
    if printf '%s' "$out" | grep -q "$2"; then bad "$1 -- wrongly reported"; else ok "$1"; fi
  }

  present "C1 missing --- fence reported"        "nofm.md"
  present "C2/C3 missing tier+type reported"     "bad.md"
  present "C4 last_verified < created reported"  "backwards.md"
  present "C5 last_verified in future reported"  "future.md"
  present "note with spaces in filename scanned" "a note with spaces.md"
  absent  "conformant note not reported"         "clean.md"
  absent  "templates/ pruned"                    "tpl.md"
  absent  "compaction-*.md pruned"               "compaction-abc"

  # The vacuity guard. "0 violations across 0 files" is not a pass - it means the
  # checker scanned nothing, which is precisely what a path-handling bug produces.
  if printf '%s' "$out" | grep -qE 'across 0 file'; then
    bad "VACUOUS RESULT: scanned zero files (path handling is broken)"
  else
    ok "scanned a non-zero number of files"
  fi

  if [ "$rc" -ne 0 ]; then
    ok "exits non-zero when violations exist"
  else
    bad "exited 0 despite violations"
  fi

  # Two more ways a checker can report clean while establishing nothing.
  DC="$TMP/datecheck"
  mkdir -p "$DC/31-standards" "$DC/10-daily"
  printf -- '---\ntitle: "m"\ntier: long\ntype: standard\ncreated: "2026-01-01"\nlast_verified: "Jan 5"\n---\n\nbody\n' > "$DC/31-standards/malformed.md"
  out_dc=$(CLAUDE_PROJECT_DIR="$DC" bash "$CHECK" 2>&1)
  if printf '%s' "$out_dc" | grep -q "not a YYYY-MM-DD date"; then
    ok "malformed last_verified is reported, not silently skipped"
  else
    bad "malformed last_verified passed silently -- got: $out_dc"
  fi

  EMPTY="$TMP/emptyvault"
  mkdir -p "$EMPTY/31-standards" "$EMPTY/10-daily"
  out_empty=$(CLAUDE_PROJECT_DIR="$EMPTY" bash "$CHECK" 2>&1)
  rc_empty=$?
  if [ "$rc_empty" -ne 0 ] && printf '%s' "$out_empty" | grep -q 'VACUOUS'; then
    ok "a scan of zero notes exits non-zero and says VACUOUS"
  else
    bad "a scan of zero notes exited $rc_empty -- a vacuous result read as a pass"
  fi
fi

# ------------------------------------------------- degraded (no-jq) paths --
#
# VAULT_FORCE_NO_JQ=1 makes the hooks take their no-jq branch even when jq is
# installed. Each assertion below also requires the branch's own notice, which
# is the evidence that the fallback actually ran rather than jq quietly
# answering in its place.

printf '\n=== no-jq fallback (forced) ===\n'

win2=$(printf '%s' "$WORK/31-standards/bad.md" | sed 's|/|\\\\|g')
out_nojq=$(printf '{"tool_input":{"file_path":"%s"}}' "$win2" \
  | VAULT_FORCE_NO_JQ=1 CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" 2>&1)
if printf '%s' "$out_nojq" | grep -q 'jq not found' \
   && printf '%s' "$out_nojq" | grep -q "missing 'tier'"; then
  ok "vault-lint no-jq path parses an escaped Windows path and still lints"
else
  bad "vault-lint no-jq path -- got: ${out_nojq:-<silence>}"
fi

out_nojq=$(printf '{"file_path":"%s"}' "$win2" \
  | VAULT_FORCE_NO_JQ=1 CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" 2>&1)
if printf '%s' "$out_nojq" | grep -q 'jq not found' \
   && printf '%s' "$out_nojq" | grep -q "missing 'tier'"; then
  ok "vault-lint no-jq path also reads a top-level file_path"
else
  bad "vault-lint no-jq top-level file_path -- got: ${out_nojq:-<silence>}"
fi

printf 'steering file with a hidden character:\342\200\213\n' > "$WORK/AGENTS.md"
out_steer=$(lint "$WORK/AGENTS.md" | strip_notices)
if printf '%s' "$out_steer" | grep -q "U+200B"; then
  ok "invisible-char scan covers AGENTS.md, an always-loaded steering file"
else
  bad "AGENTS.md was not scanned -- got: ${out_steer:-<silence>}"
fi

# Other harnesses load their own instruction files at startup; those are
# steering files too. Plain lint(), so this runs on whichever branch jq allows.
printf 'steering file with a hidden character:\342\200\213\n' > "$WORK/GEMINI.md"
mkdir -p "$WORK/.github"
printf 'steering file with a hidden character:\342\200\256\n' > "$WORK/.github/copilot-instructions.md"
out_steer=$(lint "$WORK/GEMINI.md" | strip_notices)
out_steer2=$(lint "$WORK/.github/copilot-instructions.md" | strip_notices)
if printf '%s' "$out_steer" | grep -q "U+200B" && printf '%s' "$out_steer2" | grep -q "U+202E"; then
  ok "invisible-char scan covers GEMINI.md and .github/copilot-instructions.md"
else
  bad "harness instruction files not scanned -- got: ${out_steer:-<silence>} / ${out_steer2:-<silence>}"
fi

# ------------------------------------------------ postcompact-wrap-up.sh --

POSTCOMPACT="$ROOT/.claude/hooks/postcompact-wrap-up.sh"
printf '\n=== postcompact-wrap-up.sh (compaction stubs) ===\n'

if [ ! -f "$POSTCOMPACT" ]; then
  bad "postcompact-wrap-up.sh not found at $POSTCOMPACT"
else
  PC="$TMP/pc"
  mkdir -p "$PC/20-projects/_logs"
  compact() {
    printf '%s' "$1" | CLAUDE_PROJECT_DIR="$PC" ${2:+env "$2"} bash "$POSTCOMPACT" >/dev/null 2>&1
  }
  entries() { awk '/^- /{n++} END{print n+0}' "$1" 2>/dev/null || echo 0; }

  compact '{"session_id":"s-1","trigger":"auto","transcript_path":"/t"}'
  compact '{"session_id":"s-1","trigger":"auto","transcript_path":"/t"}'
  stubs=$(find "$PC/20-projects/_logs" -name 'compaction-*.md' | awk 'END{print NR}')
  if [ "$stubs" -eq 1 ] && [ "$(entries "$PC/20-projects/_logs/compaction-s-1.md")" -eq 2 ]; then
    ok "two compactions of one session append to ONE stub"
  else
    bad "expected 1 stub with 2 entries, found $stubs stub(s)"
  fi

  rm -f "$PC/20-projects/_logs/"compaction-*.md
  compact '{"session_id":"s-2","trigger":"auto","transcript_path":"/t"}' VAULT_FORCE_NO_JQ=1
  compact '{"session_id":"s-2","trigger":"auto","transcript_path":"/t"}' VAULT_FORCE_NO_JQ=1
  if [ -f "$PC/20-projects/_logs/compaction-s-2.md" ] \
     && [ "$(find "$PC/20-projects/_logs" -name 'compaction-*.md' | awk 'END{print NR}')" -eq 1 ]; then
    ok "without jq the session id is still parsed, so the stub stays idempotent"
  else
    bad "without jq, compactions of one session produced $(find "$PC/20-projects/_logs" -name 'compaction-*.md' | awk 'END{print NR}') stub(s)"
  fi

  compact '{"session_id":"../../escape","trigger":"auto","transcript_path":"/t"}'
  if [ -z "$(find "$PC" "$TMP" -maxdepth 1 -name '*escape*' 2>/dev/null)" ] \
     && [ -n "$(find "$PC/20-projects/_logs" -name 'compaction-*escape*.md')" ]; then
    ok "a path-traversal session id is contained inside 20-projects/_logs/"
  else
    bad "a '../' session id wrote outside 20-projects/_logs/"
  fi

  CAP="$PC/20-projects/_logs/compaction-capped.md"
  { printf -- '---\ntitle: "x"\n---\n\n## Compactions\n\n'; i=0; while [ "$i" -lt 50 ]; do printf -- '- entry %s\n' "$i"; i=$((i + 1)); done; } > "$CAP"
  compact '{"session_id":"capped","trigger":"auto","transcript_path":"/t"}'
  compact '{"session_id":"capped","trigger":"auto","transcript_path":"/t"}'
  if [ "$(awk '/CAP REACHED/{n++} END{print n+0}' "$CAP")" -eq 1 ]; then
    ok "at 50 entries the stub records CAP REACHED exactly once"
  else
    bad "cap handling wrong: $(awk '/CAP REACHED/{n++} END{print n+0}' "$CAP") CAP REACHED line(s)"
  fi
fi

# ------------------------------------------------ scheduled runners --------
#
# The runners are exercised end to end against a throwaway vault, with a fake
# `claude` whose behaviour is chosen per test. Every mode is bounded: the one
# that hangs is killed by the runner's own watchdog, with the poll interval and
# grace period shortened so the test takes seconds.

printf '\n=== scheduled runners (fake claude) ===\n'

RV="$TMP/runnervault"
mkdir -p "$RV/.claude/scripts/lib" "$RV/.claude/agents" "$RV/20-projects/_logs" "$RV/31-standards" "$RV/40-llm-wiki/wiki"
cp "$ROOT/.claude/scripts/dream-pass.sh" "$ROOT/.claude/scripts/promotion-pass.sh" "$RV/.claude/scripts/" 2>/dev/null
cp "$ROOT/.claude/scripts/lib/runner-common.sh" "$RV/.claude/scripts/lib/" 2>/dev/null
cp "$ROOT/.claude/agents/dream-agent.md" "$ROOT/.claude/agents/promotion-agent.md" "$RV/.claude/agents/" 2>/dev/null
printf -- '---\ntier: long\ntype: standard\n---\n\nexisting\n' > "$RV/31-standards/existing.md"
printf '# vault\n' > "$RV/CLAUDE.md"

FAKE="$TMP/fake-claude"
cat > "$FAKE" <<'FAKE_EOF'
#!/usr/bin/env bash
# FAKE_RECORD=<path> keeps the evidence of how the agent was started: every
# argument on its own line, and a copy of the prompt file when one was passed.
if [ -n "${FAKE_RECORD:-}" ]; then
  printf '%s\n' "$@" > "$FAKE_RECORD.argv"
  [ -f "${1:-}" ] && cp "$1" "$FAKE_RECORD.prompt"
fi
case "${FAKE_MODE:-nothing}" in
  journal)        printf 'journal\n' >> "20-projects/_logs/dream-$(date +%F).md" ;;
  memory)         printf 'journal\n' >> "20-projects/_logs/dream-$(date +%F).md"
                  mkdir -p 90-auto-memory && printf 'planted\n' >> "90-auto-memory/note.md" ;;
  stray)          printf 'journal\n' >> "20-projects/_logs/dream-$(date +%F).md"
                  printf 'tampered\n' >> "31-standards/existing.md" ;;
  hang)           exec sleep 60 ;;
  summary)        printf 'did the work\nPROMOTION-SUMMARY: promoted=0 pending=1\n' ;;
  errors)         printf 'Error: something failed\n%.0s' $(seq 1 60) ;;
  promote)        printf -- '---\ntier: long\ntype: standard\n---\n\nnew\n' > "31-standards/new.md" ;;
  promote-stray)  printf -- '---\ntier: long\ntype: standard\n---\n\nnew\n' > "31-standards/new2.md"
                  printf 'tampered\n' >> "CLAUDE.md" ;;
  *)              : ;;
esac
exit 0
FAKE_EOF
chmod +x "$FAKE"

runner() {  # runner <script> <mode> [extra env...]
  local script="$1" mode="$2"
  shift 2
  # The harness variables are reset first so an exported VAULT_AGENT on the
  # machine running the suite cannot change which path a test exercises. Extra
  # assignments passed in "$@" come later, and env lets the later one win.
  env CLAUDE_BIN="$FAKE" FAKE_MODE="$mode" WATCHDOG_POLL=1 WATCHDOG_GRACE=2 \
    VAULT_AGENT=claude VAULT_AGENT_CMD= VAULT_ALLOW_UNENFORCED_TOOLS= FAKE_RECORD= "$@" \
    bash "$RV/.claude/scripts/$script" >/dev/null 2>&1
  echo $?
}
expect_rc() {  # expect_rc <label> <expected> <actual>
  if [ "$3" -eq "$2" ]; then ok "$1 (exit $3)"; else bad "$1 -- expected exit $2, got $3"; fi
}

expect_rc "dream-pass: journal written -> OK"                  0   "$(runner dream-pass.sh journal)"
expect_rc "dream-pass: journal already exists, agent idle -> NO-ARTIFACT" 1 "$(runner dream-pass.sh nothing)"
expect_rc "dream-pass: agent touches another note -> VIOLATION" 2  "$(runner dream-pass.sh stray)"
printf -- '---\ntier: long\ntype: standard\n---\n\nexisting\n' > "$RV/31-standards/existing.md"
expect_rc "dream-pass: hung agent is killed by the watchdog -> TIMEOUT" 124 "$(runner dream-pass.sh hang DREAM_PASS_TIMEOUT=2)"

expect_rc "promotion-pass: summary line, no change -> OK"      0   "$(runner promotion-pass.sh summary)"
expect_rc "promotion-pass: new long-tier note -> OK"           0   "$(runner promotion-pass.sh promote)"
expect_rc "promotion-pass: error output only -> NO-ARTIFACT"   1   "$(runner promotion-pass.sh errors)"
expect_rc "promotion-pass: writes CLAUDE.md -> VIOLATION"      2   "$(runner promotion-pass.sh promote-stray)"

# --- which harness runs the agent (VAULT_AGENT) ---
#
# A representative subset, not every mode twice: the fence, the watchdog and the
# artifact checks do not depend on how the agent was started, and each runner
# test costs several process starts on Windows.

printf '\n=== scheduled runners: harness selection ===\n'

REC="$TMP/record"
rm -f "$REC.argv" "$REC.prompt"
expect_rc "claude mode (default): journal written -> OK" 0 "$(runner dream-pass.sh journal FAKE_RECORD="$REC")"
if grep -qx -- '--agent' "$REC.argv" 2>/dev/null && grep -qx 'dream-agent' "$REC.argv" \
   && grep -qx 'acceptEdits' "$REC.argv" && grep -qx -- '-p' "$REC.argv"; then
  ok "claude mode starts claude -p --agent dream-agent --permission-mode acceptEdits"
else
  bad "claude mode argv -- got: $(tr '\n' ' ' < "$REC.argv" 2>/dev/null)"
fi

rm -f "$REC.argv" "$REC.prompt"
expect_rc "command mode without VAULT_ALLOW_UNENFORCED_TOOLS -> REFUSED" 3 \
  "$(runner dream-pass.sh journal VAULT_AGENT=command VAULT_AGENT_CMD="$FAKE" FAKE_RECORD="$REC")"
if [ ! -f "$REC.argv" ]; then ok "a refused run never starts the agent"
else bad "a refused run started the agent anyway"; fi

expect_rc "command mode, opted in: journal written -> OK" 0 \
  "$(runner dream-pass.sh journal VAULT_AGENT=command VAULT_AGENT_CMD="$FAKE" VAULT_ALLOW_UNENFORCED_TOOLS=1 FAKE_RECORD="$REC")"
if [ "$(cat "$REC.argv" 2>/dev/null)" = ".claude/logs/dream-pass.prompt.md" ]; then
  ok "command mode passes exactly one argument, the relative prompt-file path"
else
  bad "command mode argv -- got: $(tr '\n' ' ' < "$REC.argv" 2>/dev/null)"
fi
if grep -q 'READ-AND-PROPOSE ONLY' "$REC.prompt" 2>/dev/null \
   && grep -q "write today's dream journal" "$REC.prompt" \
   && ! grep -q '^tools:' "$REC.prompt"; then
  ok "the prompt file holds the agent's instructions and the task, without frontmatter"
else
  bad "prompt file content is wrong or missing"
fi
if grep -q 'WARNING: command mode' "$RV/.claude/logs/dream-agent.log" 2>/dev/null; then
  ok "an opted-in command run logs that the tool allowlist is not enforced"
else
  bad "no allowlist warning in dream-agent.log"
fi

expect_rc "command mode: agent touches another note -> VIOLATION" 2 \
  "$(runner dream-pass.sh stray VAULT_AGENT=command VAULT_AGENT_CMD="$FAKE" VAULT_ALLOW_UNENFORCED_TOOLS=1)"
printf -- '---\ntier: long\ntype: standard\n---\n\nexisting\n' > "$RV/31-standards/existing.md"

# Machine-managed memory is pruned from the fence for Claude Code, which may
# legitimately update it mid-run. A wrapper has no such reason, and memory is
# loaded into later sessions, so in command mode a write there is a violation.
expect_rc "command mode: agent writes into 90-auto-memory -> VIOLATION" 2 \
  "$(runner dream-pass.sh memory VAULT_AGENT=command VAULT_AGENT_CMD="$FAKE" VAULT_ALLOW_UNENFORCED_TOOLS=1)"
rm -rf "$RV/90-auto-memory"
expect_rc "claude mode: a write into 90-auto-memory stays outside the fence -> OK" 0 \
  "$(runner dream-pass.sh memory)"
rm -rf "$RV/90-auto-memory"

expect_rc "command mode with no VAULT_AGENT_CMD -> 127" 127 \
  "$(runner dream-pass.sh journal VAULT_AGENT=command VAULT_ALLOW_UNENFORCED_TOOLS=1)"
expect_rc "claude mode with a missing claude binary -> 127" 127 \
  "$(runner dream-pass.sh journal CLAUDE_BIN="$TMP/no-such-claude")"

# CLAUDE_BIN still names the working fake here, so an unknown kind that fell
# through to claude mode would start it and leave a record behind.
rm -f "$REC.argv" "$REC.prompt"
expect_rc "unknown VAULT_AGENT -> 64" 64 "$(runner dream-pass.sh journal VAULT_AGENT=bogus FAKE_RECORD="$REC")"
if [ ! -f "$REC.argv" ]; then ok "an unknown VAULT_AGENT never starts the agent"
else bad "an unknown VAULT_AGENT started the agent anyway"; fi

rm -f "$REC.argv" "$REC.prompt"
expect_rc "promotion-pass command mode, opted in: summary line -> OK" 0 \
  "$(runner promotion-pass.sh summary VAULT_AGENT=command VAULT_AGENT_CMD="$FAKE" VAULT_ALLOW_UNENFORCED_TOOLS=1 FAKE_RECORD="$REC")"
if grep -q 'The promotion bar' "$REC.prompt" 2>/dev/null && grep -q 'PROMOTION-SUMMARY:' "$REC.prompt"; then
  ok "promotion-pass prompt file holds the promotion-agent's instructions and the summary contract"
else
  bad "promotion-pass prompt file content is wrong or missing"
fi

# The runners resolve the vault from their own location and nothing else. A
# CLAUDE_PROJECT_DIR exported by a harness session, or a stale VAULT_ROOT in a
# scheduler, must not redirect an unattended pass - or this suite - into
# another vault, where the fence would then be checking the wrong tree.
DECOY="$TMP/decoy"
mkdir -p "$DECOY/20-projects/_logs" "$DECOY/31-standards"
expect_rc "runner with CLAUDE_PROJECT_DIR and VAULT_ROOT set to a decoy -> OK" 0 \
  "$(runner dream-pass.sh journal CLAUDE_PROJECT_DIR="$DECOY" VAULT_ROOT="$DECOY")"
if [ -z "$(find "$DECOY" -type f 2>/dev/null)" ]; then
  ok "the decoy vault is untouched: runners ignore inherited root variables"
else
  bad "a runner wrote into the decoy vault: $(find "$DECOY" -type f | tr '\n' ' ')"
fi

# ---------------------------------------------- githooks/pre-commit ---------

printf '\n=== githooks/pre-commit (opt-in commit gate) ===\n'

PRE="$ROOT/.claude/githooks/pre-commit"
if [ ! -f "$PRE" ]; then
  bad "pre-commit not found at $PRE"
else
  GV="$TMP/gatevault"
  mkdir -p "$GV/.claude/scripts" "$GV/.claude/githooks" "$GV/31-standards"
  cp "$CHECK" "$GV/.claude/scripts/"
  cp "$PRE" "$GV/.claude/githooks/"
  printf -- '---\ntier: long\ntype: standard\n---\n\nfine\n' > "$GV/31-standards/fine.md"

  # $WORK is full of violations. Pointing the inherited variable at it proves
  # the hook judges its own vault, not whatever CLAUDE_PROJECT_DIR names.
  CLAUDE_PROJECT_DIR="$WORK" bash "$GV/.claude/githooks/pre-commit" >/dev/null 2>&1
  rc_gate=$?
  expect_rc "pre-commit on a conformant vault allows the commit" 0 "$rc_gate"

  printf 'no frontmatter\n' > "$GV/31-standards/broken.md"
  bash "$GV/.claude/githooks/pre-commit" >/dev/null 2>&1
  rc_gate=$?
  expect_rc "pre-commit on a vault with a violation refuses the commit" 1 "$rc_gate"
fi

# ------------------------------------------------------------ dependencies --

printf '\n=== dependencies on this machine (informational) ===\n'
if command -v jq >/dev/null 2>&1; then
  printf '  present  jq      (reliable hook input parsing)\n'
else
  printf '  MISSING  jq      -- expected on stock macOS and Git for Windows; the hooks fall back and say so.\n'
fi
if command -v perl >/dev/null 2>&1; then
  printf '  present  perl    (invisible-character scan)\n'
elif echo x | grep -qP x 2>/dev/null; then
  printf '  present  grep -P (invisible-character scan fallback)\n'
else
  printf '  MISSING  perl and grep -P -- the invisible-character scan CANNOT RUN and will say so.\n'
fi

printf '\n=== %s passed, %s failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
