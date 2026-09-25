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
LOG="$LOG_DIR/vault-lint.log"

# The timestamp and the log folder each cost a process, and both used to be
# spent at startup on every call. A call whose path is not Markdown, or not in
# scope, never writes a line, so both are done on first use instead. The date
# is read once and reused, so a call linting several files still spends one.
#
# `date -Iseconds` is GNU-only; BSD/macOS date has no -I. Fall back to an
# explicit ISO-8601 format so the log has ONE shape on every platform.
TS=""
# log_line <text> - one line in the lint log, timestamped. The text is passed
# whole and printed verbatim, so every DEGRADED, CONFORMANCE and OK line reads
# exactly as it did when the timestamp was taken at startup.
log_line() {
  [ -n "$TS" ] || TS=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date)
  [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null
  printf '[%s] %s\n' "$TS" "$1" >> "$LOG"
}

# lint_file <path> - the whole check for one file. Returns, never exits, so
# argument mode can lint several files in one call.
lint_file() {
  local FILE="$1" NORM MATCHN IS_CONTENT_TIER IS_CHAR_SCAN_SCOPE warn FMV HITS HITS_FMT HITS_JOINED SCAN_RAN

  # normalize backslashes -> forward slashes for git-bash / MSYS.
  # Bash parameter expansion, not `printf | tr`. The old form cost a process on
  # every call, including every call whose path is not Markdown at all, and
  # those now return below having started nothing. The reason the old one wrote
  # the backslash as the octal escape \134 is worth keeping on the record:
  # spelled literally, GNU tr warns "unescaped backslash at end of string" to
  # stderr on every single invocation, which a harness surfaces as hook noise
  # on every write.
  NORM="${FILE//\\//}"

  # A patch header, or a harness, may give a path relative to the agent's
  # session directory while the hook runs from somewhere else. When the path
  # does not name a file from the current directory, try the session's cwd
  # from the hook input (a session can start in a vault subfolder), then the
  # vault root.
  # The drive letter is spelled out rather than given as a range. A range in a
  # shell pattern follows the locale's collating order, which sorts an accented
  # letter beside the letter it is built from and so inside the range, and this
  # hook carries no locale pin of its own because every harness calls it
  # directly. Four defects of this family have already reached main here.
  case "$NORM" in
    /*|[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz]:/*) ;;
    *)
      if [ ! -e "$NORM" ]; then
        local base_cwd
        base_cwd="${HOOK_CWD:-}"
        base_cwd="${base_cwd//\\//}"
        if [ -n "$base_cwd" ] && [ -e "$base_cwd/$NORM" ]; then
          NORM="$base_cwd/$NORM"
        elif [ -e "$ROOT/$NORM" ]; then
          NORM="$ROOT/$NORM"
        fi
      fi
      ;;
  esac

  # The name the scope tests are decided on, which is not always the name on
  # the command line.
  #
  # Win32 strips a trailing dot or space from a name, so a write to
  # `.claude/rules/evil.md.` arrives at `.claude/rules/evil.md` while this hook
  # is handed a name that does not end in .md, returns immediately, and logs
  # nothing. One character, aimed at the directory the character scan exists to
  # protect. Stripped on a copy, because the real name is still what gets read
  # and what the log has to show.
  #
  # Every iteration removes one character, so a name that is only dots and
  # spaces ends up empty and fails the .md test, which is the right answer.
  MATCHN="$NORM"
  while :; do
    case "$MATCHN" in
      *.|*' ') MATCHN="${MATCHN%?}" ;;
      *) break ;;
    esac
  done

  # markdown only, never templates.
  #
  # The extension is matched without regard to case. NTFS and default APFS are
  # not case sensitive, so CLAUDE.MD is CLAUDE.md there -- the most eagerly
  # loaded steering file in the repository, reaching the vault unscanned
  # because the test that gates everything else rejected it first. Restored
  # immediately after, so nothing below inherits it by accident.
  shopt -s nocasematch
  case "$MATCHN" in *.md) ;; *) shopt -u nocasematch; return 0 ;; esac
  shopt -u nocasematch
  # templates stays case sensitive on purpose. This test SKIPS a file, so
  # matching more here would scan less, and a directory really named Templates
  # on a case-sensitive filesystem is not the pruned one.
  case "$MATCHN" in */templates/*) return 0 ;; esac

  # content tiers: the mandatory tier/type frontmatter check applies here only
  #
  # Case sensitive, deliberately. A differently cased folder is the same
  # directory on Windows and a genuinely different one on Linux, and this test
  # decides whether a file is WARNED about for its frontmatter. Matching
  # loosely here would start reporting notes in a folder that is not a tier at
  # all on the platforms where it is not one.
  IS_CONTENT_TIER=0
  case "$MATCHN" in
    *"/01-inbox/"*|*"/10-daily/"*|*"/20-projects/"*|*"/30-knowledge/"*|*"/31-standards/"*|*"/40-llm-wiki/"*) IS_CONTENT_TIER=1 ;;
    01-inbox/*|10-daily/*|20-projects/*|30-knowledge/*|31-standards/*|40-llm-wiki/*) IS_CONTENT_TIER=1 ;;
  esac

  # character-scan scope: content tiers PLUS every file that steers an agent -
  # .claude/rules/, .claude/agents/, .claude/skills/, .agents/skills/, and the
  # instruction files the shipped harnesses load (AGENTS.md, AGENTS.override.md,
  # CLAUDE.md, GEMINI.md, .github/copilot-instructions.md, .hermes.md, and Pi's
  # .pi/SYSTEM.md, .pi/APPEND_SYSTEM.md, .pi/skills/ and .pi/prompts/), which
  # docs/reference.md section 3.1 lists in full. The Rules File Backdoor targets
  # exactly these steering files, which the tier-scoped frontmatter check above
  # never reaches. The instruction files are the ones loaded most eagerly, so leaving
  # them out would scan the lazily-loaded files and skip the always-loaded ones.
  # Widen this scan only, not the frontmatter check.
  #
  # Matched without regard to case, and that includes the tier folders again,
  # which the frontmatter test above deliberately did not. The asymmetry is the
  # point: matching loosely here only ever scans MORE files, which is the safe
  # direction for a security control, while matching loosely there would warn
  # about files that are not notes. On NTFS and default APFS `/31-STANDARDS/`
  # and `.claude/Rules/` are the same directories as their lower-case spellings
  # and a steering file dropped in either must not slip past.
  IS_CHAR_SCAN_SCOPE=$IS_CONTENT_TIER
  shopt -s nocasematch
  case "$MATCHN" in
    *"/01-inbox/"*|*"/10-daily/"*|*"/20-projects/"*|*"/30-knowledge/"*|*"/31-standards/"*|*"/40-llm-wiki/"*) IS_CHAR_SCAN_SCOPE=1 ;;
    01-inbox/*|10-daily/*|20-projects/*|30-knowledge/*|31-standards/*|40-llm-wiki/*) IS_CHAR_SCAN_SCOPE=1 ;;
  esac
  case "$MATCHN" in
    *"/.claude/rules/"*|*"/.claude/agents/"*|*"/.claude/skills/"*) IS_CHAR_SCAN_SCOPE=1 ;;
    .claude/rules/*|.claude/agents/*|.claude/skills/*) IS_CHAR_SCAN_SCOPE=1 ;;
    */CLAUDE.md|CLAUDE.md|*/AGENTS.md|AGENTS.md|*/GEMINI.md|GEMINI.md) IS_CHAR_SCAN_SCOPE=1 ;;
    */AGENTS.override.md|AGENTS.override.md) IS_CHAR_SCAN_SCOPE=1 ;;
    */.github/copilot-instructions.md|.github/copilot-instructions.md) IS_CHAR_SCAN_SCOPE=1 ;;
    */.hermes.md|.hermes.md) IS_CHAR_SCAN_SCOPE=1 ;;
    *"/.agents/skills/"*|.agents/skills/*) IS_CHAR_SCAN_SCOPE=1 ;;
    */.pi/SYSTEM.md|.pi/SYSTEM.md|*/.pi/APPEND_SYSTEM.md|.pi/APPEND_SYSTEM.md) IS_CHAR_SCAN_SCOPE=1 ;;
    *"/.pi/skills/"*|.pi/skills/*|*"/.pi/prompts/"*|.pi/prompts/*) IS_CHAR_SCAN_SCOPE=1 ;;
  esac
  shopt -u nocasematch

  [ "$IS_CONTENT_TIER" = 1 ] || [ "$IS_CHAR_SCAN_SCOPE" = 1 ] || return 0
  if [ ! -f "$NORM" ]; then
    log_line "DEGRADED: in-scope path does not resolve to a file, nothing was linted: $NORM"
    return 0
  fi
  # Readable, not merely present, and this is load bearing.
  #
  # An unreadable file used to reach `head -n1 | grep`, which matched nothing
  # and so reported "missing YAML frontmatter" - wrong, but loud. The single
  # awk that replaced those five processes returns an empty string instead,
  # which matches no case below, leaves warn empty, and logs the file OK. That
  # is this hook reporting clean on a check that never ran, which is the one
  # thing AGENTS.md says it must never do.
  #
  # perl is no help either: it exits 0 on a file it cannot open, measured, so
  # the invisible-character scan would have called such a file clean too. That
  # half was already true before this change and is fixed by the same guard.
  if [ ! -r "$NORM" ]; then
    log_line "DEGRADED: in-scope file could not be read, nothing was checked: $NORM"
    printf 'vault-lint: %s could not be read, so nothing was checked.\n' "$NORM" >&2
    return 0
  fi

  warn=""

  if [ "$IS_CONTENT_TIER" = 1 ]; then
    # ONE awk pass where there were five processes: a head, a grep, the
    # frontmatter awk and two more greps. It answers the same three questions
    # and prints zero or more of nofence, notier and notype. The warnings below
    # are worded and ordered exactly as they were.
    #
    # Both fences stay anchored and both match fm_of() in
    # .claude/scripts/vault-check.sh, so the hook and the checker agree on
    # where frontmatter ends. An unanchored /^---/ would end it at any line
    # merely STARTING with dashes.
    #
    # The opening fence now uses the same [ \t\r] as fm_of. It used to be
    # tested by a grep for [[:space:]] while the awk beside it used [ \t\r], so
    # an opening fence padded with a vertical tab was accepted by one and
    # rejected by the other, and the file was reported as missing both keys
    # rather than as missing its frontmatter. One class, one answer, and the
    # answer is the checker's.
    # awk's status is kept, not dropped. The -r test above catches the ordinary
    # unreadable file, but it is a test at one moment and the read happens at
    # another, and an I/O error part way through is not a permissions problem
    # at all. Either way an empty answer must not read as a clean note.
    if FMV=$(awk '
      NR == 1 && /^---[ \t\r]*$/ { f = 1; next }
      NR == 1 { print "nofence"; bad = 1; exit }
      f && /^---[ \t\r]*$/ { exit }
      f && /^tier:/ { t = 1 }
      f && /^type:/ { y = 1 }
      END {
        if (bad) { exit }
        if (!f) { print "nofence"; exit }
        if (!t) { print "notier" }
        if (!y) { print "notype" }
      }' "$NORM" 2>/dev/null); then
      case "$FMV" in
        *nofence*)
          warn="missing YAML frontmatter"
          ;;
        *)
          case "$FMV" in *notier*) warn="${warn:+$warn; }missing 'tier'" ;; esac
          case "$FMV" in *notype*) warn="${warn:+$warn; }missing 'type'" ;; esac
          ;;
      esac
    else
      warn="${warn:+$warn; }FRONTMATTER CHECK DID NOT RUN (the file could not be read)"
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
  # SCAN_RAN used to mean "a scanner exists on this machine", and was then read
  # as though it meant "a scanner read this file". Those are different claims
  # and the gap between them is this hook's worst failure: a file the scanner
  # never opened is logged OK, which is a security control reporting clean on
  # something it did not look at.
  #
  # perl cannot report it through its exit status, measured: it exits 0 on a
  # file it cannot open. So perl opens the file itself and says so, and only an
  # open that succeeded can produce exit 0 here. The -r test above is a cheap
  # early-out and NOT a substitute: on Git Bash the mount is noacl, so
  # access(R_OK) answers from the DOS read-only attribute alone and returns
  # true for a file another process holds under a sharing violation, which on
  # Windows is the routine case rather than the exotic one - an open note, a
  # sync client, a virus scanner.
  HITS_FMT=""
  SCAN_RAN=0
  if command -v perl >/dev/null 2>&1; then
    # perl stops itself after the fifth hit, which is what `| head -n 5` used
    # to do at the cost of another process. The first five are all the warning
    # ever showed.
    if HITS_FMT=$(perl -CSD -e '
        open(my $h, "<:utf8", $ARGV[0]) or exit 3;
        my $n = 0;
        while (my $line = <$h>) {
          while ($line =~ /([\x{200B}-\x{200D}\x{FEFF}\x{202A}-\x{202E}\x{2066}-\x{2069}])/g) {
            printf "line %d: U+%04X\n", $., ord($1);
            exit 0 if ++$n >= 5;
          }
        }
        exit 0;' "$NORM" 2>/dev/null); then
      SCAN_RAN=1
    else
      SCAN_RAN=2
    fi
  elif echo x | grep -qP x 2>/dev/null; then
    # The pipeline's status is grep's only because head cannot fail here, so
    # the read is tested by asking whether the file opens at all. grep -P is
    # the fallback for a machine with no perl, and it gets the weaker check.
    if HITS=$(grep -noP '[\x{200B}-\x{200D}\x{FEFF}\x{202A}-\x{202E}\x{2066}-\x{2069}]' "$NORM" 2>/dev/null; [ "$?" -le 1 ] || exit 1) \
       && { : < "$NORM"; } 2>/dev/null; then
      SCAN_RAN=1
      HITS=$(printf '%s' "$HITS" | head -n 5)
      [ -n "$HITS" ] && HITS_FMT=$(printf '%s\n' "$HITS" | sed 's/:.*/: (invisible codepoint)/')
    else
      SCAN_RAN=2
    fi
  fi

  if [ "$SCAN_RAN" = 2 ]; then
    warn="${warn:+$warn; }INVISIBLE-CHAR SCAN COULD NOT READ THIS FILE — file NOT checked"
  elif [ "$SCAN_RAN" = 0 ]; then
    warn="${warn:+$warn; }INVISIBLE-CHAR SCAN DID NOT RUN (no perl, no grep -P) — file NOT checked"
  elif [ -n "$HITS_FMT" ]; then
    HITS_JOINED=$(printf '%s' "$HITS_FMT" | paste -sd';' - | sed 's/;/; /g')
    warn="${warn:+$warn; }invisible/bidi chars: $HITS_JOINED"
  fi

  if [ -n "$warn" ]; then
    log_line "CONFORMANCE: $NORM — $warn"
    echo "vault-lint: $NORM — $warn (see .claude/rules/vault-notes.md)" >&2
  else
    log_line "OK: $NORM"
  fi
  return 0
}

# ------------------------------------------------------------ argument mode --
# Paths on the command line mean the caller is not a JSON-speaking hook, so
# stdin is never read: a git hook or an editor leaves stdin open, and a `cat`
# here would wait on it until the caller's timeout killed the lint.
# --ack-json prints {} on stdout before exiting. Hermes reads a hook's stdout
# back as JSON, while Gemini CLI and the rest want it empty, so it is opt-in.
ACK_JSON=0
if [ "${1:-}" = "--ack-json" ]; then
  ACK_JSON=1
  shift
fi
finish() {
  [ "$ACK_JSON" = 1 ] && printf '{}\n'
  exit 0
}

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
  finish
fi

# ---------------------------------------------------------------- hook mode --
# No arguments and a terminal on stdin means someone ran the script by hand.
# Reading stdin would hang waiting for JSON that is never typed, so say how to
# call it instead - on stderr, and still exit 0, because this is advisory.
if [ -t 0 ]; then
  echo "vault-lint: no file given. Usage: vault-lint.sh [--ack-json] <file>...  or pipe a harness's hook JSON on stdin." >&2
  finish
fi

INPUT=$(cat)

# Harnesses name the written file in different places:
#   tool_input.file_path | tool_input.path   Claude Code, Gemini CLI, Copilot (PascalCase events), Hermes
#   file_path | path                          Cursor (afterFileEdit)
#   tool_info.file_path                       Windsurf / Devin Desktop (post_write_code)
#   toolArgs.path | toolArgs.file_path        Copilot (camelCase events); toolArgs may be a JSON string
# Codex, OpenCode and Hermes can also edit through a patch tool whose input is
# patch text, not a path. Every "*** Add File:" and "*** Update File:" header in
# that text names a written file, so each of those is linted as well.
#
# jq is NOT bundled with Git for Windows, and without this guard a missing jq
# yields no path and the hook exits 0 having done nothing at all.
# VAULT_FORCE_NO_JQ=1 takes the no-jq branch even when jq is installed, so the
# fallback can be tested on a machine that has jq (run-tests.sh does exactly that).
if [ -z "${VAULT_FORCE_NO_JQ:-}" ] && command -v jq >/dev/null 2>&1; then
  # ONE jq call where there were three, and it also does the patch-header parse
  # that cost a tr and a sed after them. Line one is the written path, line two
  # the session cwd, and every line after that is a file a patch header names.
  # Nothing below starts a process to take the answer apart.
  #
  # startswith and ltrimstr rather than a regex, so this still works on a jq
  # built without the regex module. ltrimstr strips only a real prefix, so
  # chaining the three is safe. "Move to:" follows an "Update File:" whose file
  # is renamed, and the new name is the file that now holds the content.
  # One line per field, and the fields are read by position, so a value that
  # spans two lines would be read as two fields. The three separate jq calls
  # this replaced could not do that, because each had its own command
  # substitution, and that property has to be put back deliberately.
  #
  # Two ways it can happen. `.cwd` is not necessarily a string, and `jq -r`
  # prints a non-string as JSON, which for an object is several lines. And a
  # written path may itself hold a line break, in which case its tail lands in
  # the cwd slot -- which is the directory every relative path in this call is
  # then resolved against, so the input would be choosing where the hook looks.
  # Both were reproduced before this guard was written.
  #
  # So cwd is type-guarded, and jq reports on its own first line whether either
  # field holds a line break. index() rather than a regex, to stay off the
  # regex module.
  JQ_OUT=$(printf '%s' "$INPUT" | jq -r '
    def obj: if type == "object" then . elif type == "string" then (fromjson? // {}) else {} end;
    def patchtext: [ (.tool_input | obj | .command), (.tool_input | obj | .patch),
                     (.tool_input | obj | .patchText), (.toolArgs | obj | .patch) ]
                   | map(select(type == "string")) | join("\n");
    def pathv: [ (.tool_input | obj | .file_path), (.tool_input | obj | .path),
                 .file_path, .path,
                 (.tool_info | obj | .file_path),
                 (.toolArgs | obj | .path), (.toolArgs | obj | .file_path) ]
               | map(select(type == "string" and length > 0)) | .[0] // "";
    def cwdv: (.cwd | if type == "string" then . else "" end);
    (if (pathv | index("\n")) != null or (cwdv | index("\n")) != null
     then "BADFIELD" else "OK" end),
    pathv,
    cwdv,
    (patchtext | split("\n") | map(rtrimstr("\r"))
     | map(select(startswith("*** Add File: ") or startswith("*** Update File: ")
                  or startswith("*** Move to: ")))
     | map(ltrimstr("*** Add File: ") | ltrimstr("*** Update File: ")
           | ltrimstr("*** Move to: "))
     | .[])' 2>/dev/null)
  JQ_STATUS=""
  PATHS=""
  HOOK_CWD=""
  PATCHED=""
  # A group with a here-document, not a pipe, because bash 3.2 runs the body of
  # a pipeline in a subshell and these have to survive it.
  { IFS= read -r JQ_STATUS
    IFS= read -r PATHS
    IFS= read -r HOOK_CWD
    while IFS= read -r _hp; do
      _hp="${_hp%$'\r'}"
      [ -n "$_hp" ] || continue
      PATCHED="${PATCHED:+$PATCHED
}$_hp"
    done
  } <<EOF
$JQ_OUT
EOF
  # jq on Windows writes CRLF, so every field arrives with a carriage return on
  # the end, and this has to be taken off deliberately.
  #
  # It used to come off by accident. The dedupe awk that ran after these values
  # were read drops a CR silently, because gawk on Git Bash reads its input in
  # text mode -- two Windows behaviours cancelling each other out, jq adding
  # the character and gawk removing it. Skipping that awk when no patch named
  # anything, to save a process, removed the accident along with the process
  # and left the CR on the path. The cwd never went through that awk at all, so
  # its carriage return was never removed and the session directory has been
  # quietly failing to resolve on Windows for as long as both existed.
  JQ_STATUS="${JQ_STATUS%$'\r'}"
  PATHS="${PATHS%$'\r'}"
  HOOK_CWD="${HOOK_CWD%$'\r'}"
  # Requires OK rather than refusing one known-bad value. A status this program
  # cannot currently emit, or an empty one because jq failed outright, must not
  # read as permission to carry on with fields that may have shifted.
  if [ "$JQ_STATUS" != OK ]; then
    log_line "DEGRADED: the hook input could not be read into separate fields, so nothing was linted. The parse said [${JQ_STATUS:-nothing}], which is what a line break inside the written path or the session directory looks like."
    printf 'vault-lint: the hook input could not be parsed into fields; nothing was linted.\n' >&2
    finish
  fi
else
  # Minimal parse without jq: pull the first "file_path":"..." value with sed,
  # then undo JSON string escaping. That second step is not optional - on
  # Windows every separator arrives as a doubled backslash, so skipping it
  # yields C://Users//... , the -f test fails, and the hook lints nothing while
  # still exiting 0. Git for Windows ships no jq, so this is a realistic
  # default configuration, not an edge case.
  # file_path first, then path, at any depth, so the Windsurf and Copilot
  # shapes above are found too - the same precedence as the jq branch.
  PATHS=$(printf '%s' "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [ -z "$PATHS" ] && PATHS=$(printf '%s' "$INPUT" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  PATHS=$(printf '%s' "$PATHS" | sed -e 's/\\\\/\\/g' -e 's/\\\//\//g' -e 's/\\"/"/g')
  # Patch headers inside a JSON string end at the escaped newline (\n), so
  # stop the match at a backslash or a quote.
  PATCHED=$(printf '%s' "$INPUT" | grep -oE '\*\*\* (Add File|Update File|Move to): [^"\\]+' 2>/dev/null \
    | sed -e 's/^\*\*\* Add File: //' -e 's/^\*\*\* Update File: //' -e 's/^\*\*\* Move to: //')
  HOOK_CWD=$(printf '%s' "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 \
    | sed -e 's/\\\\/\\/g' -e 's/\\\//\//g')
  log_line "DEGRADED: jq not found — using fallback path parse. Install jq for reliable linting."
  echo "vault-lint: jq not found; path parsing is degraded. Install jq." >&2
fi
# The dedupe is only needed when a patch named files as well, and a Claude Code
# Write or Edit names none, so the common call no longer starts an awk for it.
if [ -n "$PATCHED" ]; then
  PATHS=$(printf '%s\n%s\n' "$PATHS" "$PATCHED" | awk 'NF && !seen[$0]++')
fi

# A post-write hook always names a file. An empty path is therefore an anomaly -
# malformed input or a parse failure - and it goes on the record instead of
# vanishing into a silent exit 0.
if [ -z "$PATHS" ]; then
  log_line "DEGRADED: could not read a file path from the hook input; nothing was linted."
  finish
fi

# A here-document, not a pipe into `while`: bash 3.2 runs the loop body of a
# pipeline in a subshell, and nothing here needs that.
while IFS= read -r p; do
  [ -n "$p" ] && lint_file "$p"
done <<EOF
$PATHS
EOF
finish
