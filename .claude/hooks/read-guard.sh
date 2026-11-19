#!/usr/bin/env bash
# .claude/hooks/read-guard.sh
# Pre-read guard for harnesses whose read hook can block with exit code 2
# (Windsurf / Devin Desktop pre_read_code). It gives those harnesses the same
# Read deny that .claude/settings.json gives Claude Code: .env, .env.* and
# anything under a secrets/ folder, per .claude/rules/security.md.
#
#   read-guard.sh [--] <path>...   check the named paths
#   <hook JSON> | read-guard.sh    read the path from the harness's hook input
#
# Exit 2 with a reason on stderr blocks the read. Exit 0 lets it through.
#
# FAIL-CLOSED, LOUDLY. A pre-read hook always names the file being read, so
# hook input with no readable path means the wiring is broken - on Windows, most
# likely a PowerShell entry that did not pass stdin through. The guard then
# blocks the read and logs DEGRADED. A broken setup refuses every read, which
# someone notices at once; failing open would leave every read quietly
# unchecked. It cannot fail closed if the harness never manages to start it;
# docs/harnesses/windsurf.md has the check that proves it runs. Like the
# settings.json deny, it does not stop a shell command such as `cat`.

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
LOG_DIR="$ROOT/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG="$LOG_DIR/read-guard.log"
TS=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date)

# is_secret <path> - true for .env, .env.<anything>, and any path with a
# secrets/ component, at any depth, with either separator, in any letter case.
# Case matters because Windows and macOS file systems ignore it: .ENV and
# Secrets/ open the same files. A directory read (Windsurf reports those too) of
# secrets/ itself counts.
#
# Windows also opens ".env " and ".env." and ".env::$DATA" as .env, and
# "secrets./x" as secrets/x, so each part of the path loses an NTFS stream
# suffix (from the first colon) and then its trailing dots and spaces before it
# is compared, as the Pi and omp guards do (C10, 1.7.1). A colon in a name on
# another system cuts the part short as well, which can only refuse more.
is_secret() {
  local p base raw
  raw=$(printf '%s' "$1" | tr '\134' '/' | tr '[:upper:]' '[:lower:]')
  # The same for tr, one step earlier (round 3 of the 1.7.1 review).
  if [ -n "$1" ] && [ -z "$raw" ]; then
    echo "[$TS] DEGRADED: tr could not normalise the path, so the read is refused: $1" >> "$LOG"
    return 0
  fi
  # An awk that fails or answers nothing would leave nothing to compare, and
  # nothing matches no secret, so the read is refused and logged instead
  # (round 2 of the 1.7.1 review). Only a path of dots, spaces and slashes
  # normalises to nothing on its own.
  if ! p=$(printf '%s\n' "$raw" | LC_ALL=C awk -F/ '{
    for (i = 1; i <= NF; i++) {
      part = $i
      # A drive-relative first part, c:.env, names .env in the current folder
      # of that drive, so the drive is taken off before the stream suffix is.
      if (i == 1 && part ~ /^[abcdefghijklmnopqrstuvwxyz]:./) part = substr(part, 3)
      sub(/:.*$/, "", part)
      sub(/[. ]+$/, "", part)
      printf "%s%s", (i > 1 ? "/" : ""), part
    }
  }'); then
    echo "[$TS] DEGRADED: awk could not normalise the path, so the read is refused: $1" >> "$LOG"
    return 0
  fi
  if [ -z "$p" ]; then
    case "$raw" in
      *[!./\ ]*)
        echo "[$TS] DEGRADED: the path normalised to nothing, so the read is refused: $1" >> "$LOG"
        return 0 ;;
    esac
  fi
  base="${p##*/}"
  # env~1, or env~1.loc, is the 8.3 short name Windows gives .env or
  # .env.local on a volume that keeps short names, and it opens the same file.
  # Once more than four names in a folder share that stem, Windows names the
  # rest with two letters and four hex digits, en1a2b~1.
  case "$base" in
    .env|.env.*|env~[0123456789]*) return 0 ;;
    en[0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef]~[0123456789]*) return 0 ;;
  esac
  case "/$p/" in
    */secrets/*) return 0 ;;
  esac
  return 1
}

check() {
  if is_secret "$1"; then
    echo "[$TS] BLOCKED: $1" >> "$LOG"
    echo "read-guard: reading $1 is denied by .claude/rules/security.md (.env, .env.*, secrets/)." >&2
    exit 2
  fi
}

[ "${1:-}" = "--" ] && shift
if [ "$#" -gt 0 ]; then
  for f in "$@"; do
    check "$f"
  done
  exit 0
fi

if [ -t 0 ]; then
  echo "read-guard: no path given. Usage: read-guard.sh <path>...  or pipe a harness's hook JSON on stdin." >&2
  exit 0
fi

INPUT=$(cat)

if [ -z "${VAULT_FORCE_NO_JQ:-}" ] && command -v jq >/dev/null 2>&1; then
  FILE=$(printf '%s' "$INPUT" | jq -r '
    def obj: if type == "object" then . elif type == "string" then (fromjson? // {}) else {} end;
    [ (.tool_info | obj | .file_path),
      (.tool_input | obj | .file_path), (.tool_input | obj | .path),
      .file_path, .path ]
    | map(select(type == "string" and length > 0)) | .[0] // empty' 2>/dev/null)
else
  FILE=$(printf '%s' "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [ -z "$FILE" ] && FILE=$(printf '%s' "$INPUT" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  FILE=$(printf '%s' "$FILE" | sed -e 's/\\\\/\\/g' -e 's/\\\//\//g' -e 's/\\"/"/g')
  echo "[$TS] DEGRADED: jq not found — using fallback path parse." >> "$LOG"
fi

if [ -z "$FILE" ]; then
  echo "[$TS] DEGRADED: no path in the hook input; the read was BLOCKED because it could not be checked." >> "$LOG"
  echo "read-guard: could not read a path from the hook input, so the read was blocked. See docs/harnesses/windsurf.md." >&2
  exit 2
fi

check "$FILE"
exit 0
