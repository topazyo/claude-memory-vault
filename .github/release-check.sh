#!/usr/bin/env bash
# .github/release-check.sh
#
# Does the published release keep up with what this template ships?
#
# `vault-update.sh` tells a vault what moved upstream by comparing its manifest
# against a newer copy, and `docs/updating.md` tells the reader to learn that a
# newer copy exists by watching this repository's releases. Both of those rest
# on a release being cut whenever a shipped file changes, and nothing checked
# that until this script existed. The control `tmpl-version-agrees` checks that
# VERSION, the manifest header and the newest changelog entry say the same
# thing. All three are files in the tree, any commit can rewrite all three at
# once, and none of them is the artefact a reader fetches. So a merge that
# edited a shipped file, left VERSION alone and was never tagged produced a
# template whose newest content no vault could discover, while the manifest
# still verified and CI still went green. Version 1.0.0 was itself merged first
# and tagged afterwards by hand, because somebody remembered.
#
# THE TAG IS THE SOURCE OF TRUTH. That is the one design decision here and
# everything else follows from it. A tag is the only statement of a version that
# becomes immutable once it is pushed, and the only one a downstream vault can
# fetch. VERSION, the manifest header and the changelog are claims about a
# release. The tag is the release.
#
# So this asks a single question, answered two ways depending on whether the
# version in the tree has been published yet.
#
#   VERSION names an existing tag. Then every file the template ships has to be
#   byte for byte what that tag holds, because the tree is claiming to BE that
#   release. A shipped file that differs is a change no vault can discover.
#
#   VERSION names no tag. Then a release is in preparation, which is a fine
#   state for a pull request and not a fine state for the branch releases are
#   cut from. On that branch an untagged version is the exact debt this script
#   exists to collect, so --release-branch turns it into a failure.
#
# Together those two mean every merge that changes a shipped file is a release.
# That is a policy rather than a side effect, and it is the right one for a
# template whose only notification channel is a GitHub release. Preparing one
# version across several merges would leave the branch owing a tag for days,
# and a branch that is red for days teaches people to stop reading it.
#
# THE TAG SPELLING IS UNPREFIXED, `1.0.0` and never `v1.0.0`. `CHANGELOG.md`
# heads its entries that way and the clone example in `docs/updating.md` names a
# tag that way, so a prefix would have to move in all three at once. A tag that
# looks like a prefixed version is refused below rather than ignored, because
# ignoring it is how the three would drift apart with nobody seeing it.
#
# This belongs to the template project rather than to a vault, which is why it
# lives beside the workflow that runs it and is classed `excluded` in
# `.claude/manifest-rules`. A vault has no releases to cut.
#
# IT NEVER REACHES THE NETWORK. --tag writes an annotated tag into the local
# repository and prints the two commands that publish it, because pushing and
# publishing are acts a person should take deliberately and read the output of.
#
# Usage:
#   .github/release-check.sh                    verify, from anywhere in the repo
#   .github/release-check.sh --release-branch   verify, on the branch releases
#                                               are cut from, where an untagged
#                                               version is a failure
#   .github/release-check.sh --tag              cut the tag this tree is owed
#   .github/release-check.sh --help
#
# Exit:
#    0  the release keeps up with what this tree ships
#    1  a release is owed, or the tree claims a version it is not
#    2  this check could NOT run, so it is saying nothing about the release.
#       No git, no VERSION, no tags in this checkout, or a tag whose tree holds
#       no manifest to read the shipped set out of
#   64  the command line was wrong

set -u

MODE=verify
RELEASE_BRANCH=0

say()  { printf 'release-check: %s\n' "$1"; }
warn() { printf 'release-check: %s\n' "$1" >&2; }

usage() {  # usage <stream-is-stderr>
  local out=1
  [ "${1:-0}" = 1 ] && out=2
  {
    printf 'Usage: .github/release-check.sh [--release-branch] [--tag]\n'
    printf '\n'
    printf '  (no argument)     verify that the published release keeps up with what\n'
    printf '                    this tree ships\n'
    printf '  --release-branch  the same, on the branch releases are cut from, where a\n'
    printf '                    version naming no tag is a failure rather than a release\n'
    printf '                    in preparation\n'
    printf '  --tag             write the annotated tag this tree is owed, and print the\n'
    printf '                    two commands that publish it\n'
    printf '\n'
    printf 'Exit  0  the release keeps up with what this tree ships\n'
    printf '      1  a release is owed, or the tree claims a version it is not\n'
    printf '      2  this check could not run, so it is saying nothing about the release\n'
    printf '     64  the command line was wrong\n'
  } >&"$out"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --release-branch) RELEASE_BRANCH=1 ;;
    --tag)            MODE=tag ;;
    --help|-h)        usage 0; exit 0 ;;
    *)
      warn "unknown argument [$1]"
      usage 1
      exit 64
      ;;
  esac
  shift
done

command -v git >/dev/null 2>&1 || {
  warn "NO-GIT - git is not installed, so which versions have been released could not be determined."
  exit 2
}

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
# Not a test for a .git DIRECTORY. In a linked worktree .git is a file holding a
# pointer, and this repository's own development happens in linked worktrees, so
# a directory test would refuse exactly the checkouts the maintainer works in.
if [ -z "$ROOT" ] || ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  warn "NO-GIT - [${ROOT:-the working directory}] is not a git repository, so which versions have been released could not be determined."
  exit 2
fi

# Absolute, because a linked worktree's --git-dir comes back relative and this
# is used from a different working directory further down.
GITDIR="$(cd "$ROOT" && cd "$(git rev-parse --git-dir)" && pwd)"
[ -n "$GITDIR" ] && [ -d "$GITDIR" ] || {
  warn "NO-GIT - the git directory for $ROOT could not be resolved, so nothing was compared."
  exit 2
}

MANIFEST_REL=".claude/template-manifest"
CHANGELOG_REL="CHANGELOG.md"

# The first non-empty line with any carriage return taken off, which is how
# every other reader in this repository reads this file. A clone taken on
# Windows carries the CR, and a version compared with one attached matches
# nothing at all while looking perfectly ordinary in a terminal.
VERSION_FILE="$ROOT/VERSION"
[ -f "$VERSION_FILE" ] || {
  warn "NO-VERSION - $VERSION_FILE is not a readable file, so this tree does not say which version it is."
  exit 2
}
V="$(LC_ALL=C awk '{ sub(/\r$/, ""); if (length($0)) { print; exit } }' "$VERSION_FILE" 2>/dev/null)"
[ -n "$V" ] || {
  warn "NO-VERSION - $VERSION_FILE holds no version, so this tree does not say which version it is."
  exit 2
}

# The same numeric comparison `version_older` makes in vault-update.sh, and
# deliberately a second copy of it rather than a shared function. That script is
# shipped into every vault and this one is not, so lifting ten lines of awk into
# a shared place would couple a maintainer's tool into the reader's. The two
# have to agree about one thing, which is that 1.0 and 1.0.0 are the same number
# written two ways, and a control asserts that rather than trusting this comment.
version_cmp() {  # version_cmp <a> <b>, prints -1, 0 or 1
  LC_ALL=C awk -v a="$1" -v b="$2" '
    BEGIN {
      na = split(a, x, "."); nb = split(b, y, ".")
      n = (na > nb) ? na : nb
      for (i = 1; i <= n; i++) {
        xi = (i <= na) ? x[i] + 0 : 0
        yi = (i <= nb) ? y[i] + 0 : 0
        if (xi < yi) { print "-1"; exit }
        if (xi > yi) { print "1";  exit }
      }
      print "0"
    }'
}

# A tag that looks like a PREFIXED version is refused rather than skipped by the
# filter below, because a silently unseen `v1.1.0` is how the tag, the changelog
# and the clone example would come to disagree with nobody noticing.
ALL_TAGS="$(git -C "$ROOT" tag -l 2>/dev/null)"
PREFIXED="$(printf '%s\n' "$ALL_TAGS" | LC_ALL=C awk '/^[vV][0-9]/ { printf "%s ", $0 }')"
if [ -n "$PREFIXED" ]; then
  warn "TAG-SPELLING - these tags spell a version with a leading letter and this template spells one without: ${PREFIXED% }"
  warn "CHANGELOG.md heads its entries unprefixed and the clone example in docs/updating.md names an unprefixed tag, so a prefix has to move in all three at once or a reader is told two names for one release."
  exit 1
fi

TAGS="$(printf '%s\n' "$ALL_TAGS" | LC_ALL=C awk '/^[0-9]+(\.[0-9]+)*$/ { print }')"
TAG_N="$(printf '%s\n' "$TAGS" | LC_ALL=C awk 'length($0) { n++ } END { print n + 0 }')"
if [ "$TAG_N" -eq 0 ]; then
  warn "NO-TAGS - this checkout holds no tag naming a version, so whether $V has been released could not be determined."
  warn "A shallow checkout has no tags either, and that looks exactly like a repository that has never released one. Fetch them with git fetch --tags --force, and in a workflow set fetch-depth 0 on the checkout step."
  exit 2
fi

# The greatest tag by number rather than by text, because 1.10.0 sorts before
# 1.9.0 as text and after it as a version.
NEWEST=''
for t in $TAGS; do
  if [ -z "$NEWEST" ] || [ "$(version_cmp "$t" "$NEWEST")" = 1 ]; then
    NEWEST="$t"
  fi
done

# Scratch under the git directory rather than under TMPDIR. It is always
# present, always writable by whoever can run git here, never tracked, and
# reachable by a name this script can print when something goes wrong.
SCRATCH="$GITDIR/release-check"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH" || {
  warn "NO-SCRATCH - $SCRATCH could not be created, so nothing was compared."
  exit 2
}

# -------------------------------------------------------------- the answer --

if git -C "$ROOT" rev-parse -q --verify "refs/tags/$V" >/dev/null 2>&1; then
  # Claiming a version that is not the newest one is its own failure with its
  # own wording. Everything below would otherwise report it as an ordinary
  # drift and send the reader to fix the wrong thing.
  if [ "$(version_cmp "$V" "$NEWEST")" = -1 ]; then
    warn "VERSION-GOES-BACKWARD - VERSION says $V and the newest released version is $NEWEST, so this tree claims to be a release that has already been superseded."
    warn "Set VERSION to a number above $NEWEST and add its changelog entry."
    exit 1
  fi

  git -C "$ROOT" cat-file -e "$V:$MANIFEST_REL" 2>/dev/null || {
    warn "TAG-WITHOUT-MANIFEST - the $V tag holds no $MANIFEST_REL, so which files it shipped could not be read and this check is saying nothing about the release."
    warn "Version 1.0.0 is the first that ships a manifest. A tag older than that cannot be compared against, and a person has to decide what such a comparison should mean."
    exit 2
  }

  # Every path the template ships, as the union of what it ships NOW and what
  # the tag shipped. The union rather than either alone, because a file deleted
  # since the tag is absent from the current manifest and a file added since
  # the tag is absent from the tag's, and both of those are changes a reader
  # has to be told about.
  {
    LC_ALL=C awk '{ sub(/\r$/, "") } $1 == "owned" || $1 == "seed" { print $3 }' \
      "$ROOT/$MANIFEST_REL" 2>/dev/null
    git -C "$ROOT" show "$V:$MANIFEST_REL" 2>/dev/null \
      | LC_ALL=C awk '{ sub(/\r$/, "") } $1 == "owned" || $1 == "seed" { print $3 }'
  } | LC_ALL=C sort -u > "$SCRATCH/shipped"
  SHIPPED_N="$(LC_ALL=C awk 'END { print NR + 0 }' "$SCRATCH/shipped")"

  if [ "$SHIPPED_N" -eq 0 ]; then
    warn "VACUOUS - the $V tag and this tree between them name no shipped file, so nothing was compared and a clean answer here would mean nothing."
    exit 2
  fi

  # One `git diff` over the whole tree and then a filter, rather than a diff
  # narrowed by ninety pathspecs. The narrowed form is the obvious one and it
  # runs into the command line length limit on Windows at a size this
  # repository is already near.
  #
  # The tag against the WORKING TREE rather than against HEAD, so a releaser
  # running this locally with an uncommitted edit to a shipped file is told
  # about it. Inside a workflow the two are the same thing.
  #
  # core.quotePath off, because git otherwise escapes a non-ASCII name into a
  # spelling that matches no manifest path and the file would be filtered out
  # of its own report.
  git -C "$ROOT" -c core.quotePath=false diff --name-only "$V" -- > "$SCRATCH/diffed" 2>/dev/null
  LC_ALL=C awk '
    NR == FNR { ship[$0] = 1; next }
    ($0 in ship) { print }
  ' "$SCRATCH/shipped" "$SCRATCH/diffed" > "$SCRATCH/changed"
  CHANGED_N="$(LC_ALL=C awk 'END { print NR + 0 }' "$SCRATCH/changed")"

  if [ "$CHANGED_N" -gt 0 ]; then
    warn "UNRELEASED-CHANGES - $CHANGED_N of the $SHIPPED_N file(s) this template ships differ from the $V tag, and VERSION still says $V, so a vault fetching $V does not get them."
    warn "Changed since $V, and unreachable by anybody downstream:"
    LC_ALL=C sed 's/^/  /' "$SCRATCH/changed" >&2
    warn "Set VERSION to a number above $V, add its CHANGELOG.md entry with an Adopting this note, regenerate the manifest, and cut the release."
    warn "  VAULT_TEMPLATE_MAINTAINER=1 bash .claude/scripts/vault-update.sh --generate"
    warn "  bash .github/release-check.sh --tag"
    exit 1
  fi

  say "0 of $SHIPPED_N shipped file(s) differ from the $V tag, so this tree is the $V release and nothing is owed."

  if [ "$MODE" = tag ]; then
    warn "ALREADY-TAGGED - $V is already a tag and this tree matches it, so there is nothing to cut. Bump VERSION first."
    exit 1
  fi
  exit 0
fi

# ------------------------------------------- VERSION names no tag from here --

if [ "$(version_cmp "$V" "$NEWEST")" != 1 ]; then
  warn "VERSION-GOES-BACKWARD - VERSION says $V, no tag names it, and the newest released version is $NEWEST, so this tree would publish a release nobody could order against the ones before it."
  warn "Set VERSION to a number above $NEWEST."
  exit 1
fi

if [ "$MODE" = tag ]; then
  # Read only under --tag, and deliberately not under plain verification. That
  # VERSION and the newest changelog heading agree is `tmpl-version-agrees`'s
  # rule and it lives there. What this needs the entry for is the tag message,
  # which is this script's own business.
  CL_V="$(LC_ALL=C awk '{ sub(/\r$/, "") } /^## / { print $2; exit }' "$ROOT/$CHANGELOG_REL" 2>/dev/null)"
  if [ "$CL_V" != "$V" ]; then
    warn "NO-NOTES - VERSION says $V and the newest CHANGELOG.md entry heads [${CL_V:-nothing}], so there are no notes to tag $V with."
    warn "Add a ## $V entry with an Adopting this note. The control tmpl-changelog-adopting says what that note has to carry."
    exit 1
  fi
  # Beside the scratch rather than inside it. The scratch is cleared at the top
  # of every run, and the line below hands this path to the reader as the
  # --notes-file for their release, so a verification run between cutting the
  # tag and publishing it would delete the notes out from under them.
  NOTES="$GITDIR/release-notes-$V.md"
  LC_ALL=C awk '
    { sub(/\r$/, "") }
    /^## / { if (seen) exit; seen = 1; print; next }
    seen { print }
  ' "$ROOT/$CHANGELOG_REL" > "$NOTES" 2>/dev/null
  if [ ! -s "$NOTES" ]; then
    warn "NO-NOTES - the $V entry in CHANGELOG.md is empty, so there are no notes to tag $V with."
    exit 1
  fi
  git -C "$ROOT" tag -a "$V" -F "$NOTES" || {
    warn "TAG-FAILED - git would not write the $V tag, so nothing was cut."
    exit 1
  }
  say "Annotated tag $V written into this repository, with the CHANGELOG.md $V entry as its message."
  say "Publish it with these two, which are the only steps in cutting a release that reach the network."
  say "  git push origin $V"
  say "  gh release create $V --title $V --notes-file $NOTES"
  say "Then re-run the hygiene job on the release branch, because an untagged version is what has been holding it red."
  exit 0
fi

if [ "$RELEASE_BRANCH" = 1 ]; then
  warn "UNTAGGED-VERSION - VERSION says $V, no tag names it, and this is the branch releases are cut from, so what this branch ships is content no vault can discover."
  warn "Cut it with this, which writes the tag into this repository and prints the two commands that publish it."
  warn "  bash .github/release-check.sh --tag"
  exit 1
fi

say "VERSION says $V, which is above the newest released version $NEWEST and names no tag yet, so this is a release in preparation and nothing is owed until it reaches the branch releases are cut from."
exit 0
