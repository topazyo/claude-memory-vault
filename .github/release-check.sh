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
#    1  a release is owed, the tree claims a version it is not, or the
#       repository holds a tag spelled a way this cannot reconcile
#    2  this check could NOT run, so it is saying nothing about the release.
#       No git, no readable VERSION, no readable manifest, no tags in this
#       checkout, a tag whose tree holds no manifest to read the shipped set
#       out of, a shipped set git does not recognise, or a comparison git
#       could not make
#   64  the command line was wrong
#
# The refusal tags, published here for the same reason `docs/reference.md`
# publishes the updater's, so that output can be grepped against a document
# rather than against a memory of it:
#
#   NO-GIT · NO-VERSION · VERSION-SPELLING · TAG-SPELLING · NO-TAGS ·
#   NO-SCRATCH · NO-MANIFEST · TAG-WITHOUT-MANIFEST · VACUOUS ·
#   SHIPPED-UNKNOWN · DIFF-FAILED · UNRELEASED-CHANGES · VERSION-GOES-BACKWARD ·
#   UNTAGGED-VERSION · ALREADY-TAGGED · NO-NOTES · TAG-FAILED
#
# Four of those names also exist in `vault-update.sh` and do not mean the same
# thing there, which is worth knowing before grepping both at once. NO-GIT,
# NO-VERSION and NO-MANIFEST are about this repository here and about a vault
# and its own manifest there, and VACUOUS is about a shipped set with nothing
# in it here and about a scan that matched no notes there.

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
    printf '      1  a release is owed, the tree claims a version it is not, or a tag\n'
    printf '         is spelled a way this cannot reconcile\n'
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

# GIT_DIR AND GIT_WORK_TREE ARE DROPPED BEFORE THE FIRST GIT CALL, and the word
# before matters. An earlier version dropped them seventeen lines further down,
# after `$ROOT` had already been derived from `git rev-parse --show-toplevel`,
# which honours both. With `GIT_DIR` and `GIT_WORK_TREE` exported, that call
# answered with the other repository's work tree, `$ROOT` became it, and
# everything after read VERSION, wrote the tag and ran the rm -rf there, while
# the comment claimed it could not happen. The comment was true about what it
# guarded and the guard was in the wrong place.
#
# `git -C` changes the working directory and does not override either variable,
# and GIT_DIR beats discovery, so nothing later can undo an early read. This is
# not hypothetical plumbing: git exports GIT_DIR to every hook it runs, and this
# repository ships a pre-commit hook, so a release check wired into one would
# meet it.
#
# CDPATH goes too. With it set, `cd` writes the directory it chose to standard
# output, and two command substitutions below capture the output of a `cd`.
unset GIT_DIR GIT_WORK_TREE CDPATH

# CLAUDE_PROJECT_DIR is honoured, and it is worth being plain that it moves
# everything this script then does, including the rm -rf and the tag. It is
# kept because the control suite needs to point the script at a fixture and
# because `vault-check.sh` honours the same variable, so a reader meeting both
# finds one convention rather than two. What it cannot do is widen anything: the
# value has to be a git repository or the next test refuses, and every path is
# derived from it rather than joined to it.
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
# Not a test for a .git DIRECTORY. In a linked worktree .git is a file holding a
# pointer, and this repository's own development happens in linked worktrees, so
# a directory test would refuse exactly the checkouts the maintainer works in.
if [ -z "$ROOT" ] || ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  warn "NO-GIT - [${ROOT:-the working directory}] is not a git repository, so which versions have been released could not be determined."
  exit 2
fi

# Absolute, because a linked worktree's --git-dir comes back relative and this
# is used from a different working directory further down. Captured into a
# variable and checked before the cd, because `cd ""` is a no-op in bash, so an
# empty answer would quietly leave this at $ROOT and point the rm -rf below
# inside the working tree.
gitdir_rel="$(cd "$ROOT" && git rev-parse --git-dir 2>/dev/null)"
GITDIR=''
[ -n "$gitdir_rel" ] && GITDIR="$(cd "$ROOT" && cd "$gitdir_rel" 2>/dev/null && pwd)"
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

# Digits and dots, and the same grammar the tag filter below applies, because
# the version and the tag have to be the same string for any of this to mean
# anything. Reading it and never checking it was a real hole with three
# separate consequences, and they are worth naming because each one fails
# quietly in its own way.
#
# A version like 1.2.0-rc1 passes the ordering, because the comparator converts
# each field with awk's numeric coercion and "0-rc1" becomes 0, so --tag writes
# the literal tag 1.2.0-rc1 and git accepts it as a refname. Every later run
# then filters that tag out as not spelling a version, so it is absent from the
# newest-tag calculation and INVISIBLE, which is precisely the failure the
# prefixed-tag refusal further down exists to prevent. Only the v spelling was
# refused.
#
# A trailing space is worse, because it is invisible in a terminal. Git refuses
# a refname ending in a space, so the tag never matches, plain verification
# says "release in preparation" and leaves on 0 for ever, and --tag reports
# that VERSION says 1.2.0 and the changelog heads [1.2.0] - two strings that
# are byte-different and look identical. The carriage return was thought about
# here and the space was not.
#
# And the value reaches git as a REVISION EXPRESSION rather than as a tag name,
# so 1.1.0^ or 1.1.0^{} verifies, orders, and then drives the comparison
# against a commit that is not any release while every message calls it a tag.
case "$V" in
  *[!0-9.]*|.*|*.|*..*|'')
    warn "VERSION-SPELLING - $VERSION_FILE says [$V] and a version here is digits separated by single dots, so nothing could be compared against it."
    warn "This is refused rather than tried because the value reaches git as a revision expression and as a tag name. A version this file accepts and the tag filter does not would be tagged once and then never seen again, which is the same silence a leading letter would cause."
    exit 1
    ;;
esac

# The same numeric comparison `version_older` makes in vault-update.sh, and
# deliberately a second copy of it rather than a shared function. That script is
# shipped into every vault and this one is not, so lifting ten lines of awk into
# a shared place would couple a maintainer's tool into the reader's. The two
# have to agree about one thing, which is that 1.0 and 1.0.0 are the same number
# written two ways.
#
# `tmpl-release-comparators-agree` asserts that of THIS copy, by feeding it 1.0,
# 1.0.0.0 and 01.0.0 against a 1.0.0 tag, and `tmpl-same-version-equivalent`
# asserts it of the other one. This sentence used to claim a control existed
# when none did for this side, which is the shape of claim that teaches a reader
# to stop checking the others, so it now names them.
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
  warn "There are two ways out and neither is free. Delete the tag, which is a published artefact somebody may already have fetched, or move to the prefixed spelling everywhere, which means this filter, the changelog headings and that clone example together. This refuses rather than choosing for you."
  exit 1
fi

# A tag that STARTS like a version and is not one is refused rather than
# filtered away, for the same reason a prefixed one is. `1.2.0-rc1` and `1.2.`
# are tags somebody meant as versions, and dropping them silently leaves them
# out of the newest-version calculation for ever while every message talks
# confidently about an older number. That is the invisibility VERSION-SPELLING
# was added to stop on the VERSION side, and stopping it there and not here
# would have left the same hole one step along.
MALFORMED="$(printf '%s\n' "$ALL_TAGS" | LC_ALL=C awk '
  /^[0-9]/ && !/^[0-9]+(\.[0-9]+)*$/ { printf "%s ", $0 }')"
if [ -n "$MALFORMED" ]; then
  warn "TAG-SPELLING - these tags begin like a version and are not digits separated by single dots, so nothing here can order them: ${MALFORMED% }"
  warn "A tag this cannot read is left out of which version is newest, and every answer after that is about some older number while saying nothing about the tag it ignored. Delete it, or rename it to a version this can order."
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
#
# The word splitting below is deliberate and the filter above is LOAD BEARING
# for it. $TAGS is unquoted so that it splits into one tag per iteration, and an
# unquoted expansion is also a glob, so loosening that numeric filter to admit a
# character a shell pattern reads would turn this loop into a directory listing.
# Anything it lets through now is digits and dots.
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
# EMPTINESS IS ASSERTED, because `mkdir -p` returns 0 for a directory that
# already exists and so cannot tell a failed clear from a clean one. On Git
# Bash `rm -rf` really does fail on an open handle, a read-only attribute or a
# scanner holding a file, in a way it essentially never does on the other two
# platforms. A survivor here is not cosmetic: four of the files written below
# have their redirection status read nowhere, so a stale read-only one would be
# read as this run's data and the run would answer from it.
if [ -n "$(ls -A "$SCRATCH" 2>/dev/null)" ]; then
  warn "NO-SCRATCH - $SCRATCH could not be emptied, so a previous run's files are still in it and nothing here could be trusted to be this run's."
  exit 2
fi

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
  # This side is REFUSED when it cannot be read, the way the tag side already
  # is a few lines above. Nothing here sets -e or pipefail, so an unreadable
  # manifest contributed nothing and the union quietly became "whatever the tag
  # shipped". The shipped count stays above zero, so the vacuity guard below
  # does not fire, and a file added since the tag is then in neither list that
  # got read, filtered out of the comparison, and the run says nothing is owed.
  # The manifest is not an entry in itself either, so its own disappearance is
  # not caught anywhere else.
  [ -r "$ROOT/$MANIFEST_REL" ] || {
    warn "NO-MANIFEST - $ROOT/$MANIFEST_REL is not a readable file, so what this tree ships could not be read and nothing was compared."
    exit 2
  }
  # THE PATH IS THE REST OF THE LINE, not the third field. A manifest line is a
  # class, a digest and a path separated by single spaces, and awk's default
  # splitting ends the path at the first space inside it. `docs/my file.md`
  # became `docs/my`, which git's list of tracked files matches nothing in, so
  # the real path was absent from the shipped set and every later change to it
  # was filtered out of the comparison with nothing saying so.
  #
  # SHIPPED-UNKNOWN cannot see it either, because that guard fires only when a
  # whole side overlaps by zero, and one mangled path among ninety leaves the
  # overlap far above zero. So a single shipped file whose name carries a space
  # drops silently out of the release discipline for good. Paths with spaces are
  # ordinary on Windows and macOS, which are two of the four platforms this runs
  # on.
  #
  # The field count is checked in the same pass. A line short of three fields
  # used to contribute an empty path, which inflated every count by one and put
  # a blank line into a set that is compared against git's.
  shipped_paths() {  # shipped_paths, filtering a manifest on standard input
    LC_ALL=C awk '
      { sub(/\r$/, "") }
      ($1 == "owned" || $1 == "seed") && NF >= 3 {
        p = $0
        sub(/^[^ ]+[ ]+[^ ]+[ ]+/, "", p)
        if (length(p)) print p
      }'
  }
  shipped_paths < "$ROOT/$MANIFEST_REL" 2>/dev/null | LC_ALL=C sort -u > "$SCRATCH/shipped.now"
  git -C "$ROOT" show "$V:$MANIFEST_REL" 2>/dev/null \
    | shipped_paths \
    | LC_ALL=C sort -u > "$SCRATCH/shipped.tag"
  LC_ALL=C sort -u "$SCRATCH/shipped.now" "$SCRATCH/shipped.tag" > "$SCRATCH/shipped"
  SHIPPED_N="$(LC_ALL=C awk 'END { print NR + 0 }' "$SCRATCH/shipped")"

  # A COUNT THAT COULD NOT BE TAKEN IS NOT A ZERO, and the difference decides
  # the verdict rather than the wording. Measured on GNU awk 5.4.0: counting a
  # file that is not there prints NOTHING and leaves on 2, because awk never
  # reaches END, while counting a file that exists and is empty prints 0 on 0.
  # Those two have to stay distinguishable, and an unguarded count collapses
  # them.
  #
  # An empty string in a numeric test makes bash print "integer expression
  # expected" and return 2, which an `if` reads as FALSE. So an unmeasured
  # count skips BOTH directions of every guard below - `-eq 0` is not true and
  # `-gt 0` is not true - and the run falls through to the clean line and says
  # this tree is the release and nothing is owed, on exit 0. That is the same
  # fail-open to green this whole file is written against, arrived at through a
  # redirection nobody checked rather than through a command nobody checked.
  #
  # The four files these counts read all come from redirections whose status is
  # not read, so a full disk, a read-only scratch, or the concurrent run that
  # clears this directory between two of them is enough to produce it.
  #
  # DEFAULTING TO ZERO IS THE WRONG REPAIR. Zero is the GREEN answer for the
  # changed count, so `${CHANGED_N:-0}` would turn a failure to measure into
  # "nothing is owed" rather than away from it. The emptiness is tested
  # instead, which is the shape the notes body measurement further down already
  # uses for the same reason.
  if [ -z "$SHIPPED_N" ]; then
    warn "NO-SCRATCH - the shipped set in $SCRATCH could not be counted, so how many files this template ships is unknown and nothing was compared."
    exit 2
  fi

  if [ "$SHIPPED_N" -eq 0 ]; then
    warn "VACUOUS - the $V tag and this tree between them name no shipped file, so nothing was compared and a clean answer here would mean nothing."
    exit 2
  fi

  # The shipped set has to be spelled the way git spells a path, or the
  # comparison below intersects two vocabularies and comes back empty however
  # much has moved. A count above zero is not enough for that, which is why
  # this is a second guard rather than part of the one above.
  #
  # The channels are real even though none of them is open today. A trailing
  # carriage return on manifest lines and not on git's output, a quoted octal
  # escape on one side only, or a leading ./ would each collapse the answer to
  # zero and print "nothing is owed" over a tree that owes a release. The
  # defences are `.gitattributes` pinning these files to one line ending and
  # both sides disabling quotePath, and every one of those lives in another
  # file. This turns "the two sides speak the same language" from something
  # assumed into a number.
  # EACH SIDE SEPARATELY, not the union. Checking only the union was the first
  # attempt and it is too weak to fire on the case that actually happens. The
  # two manifests are read by different routes - this tree's off the disk with
  # whatever line-ending filter git applies on checkout, and the tag's through
  # `git show`, which applies none - so a spelling difference appears on ONE
  # side at a time. The union then still overlaps through the other side, the
  # guard stays quiet, and half the shipped set has silently stopped being
  # comparable. Measured: giving every path in this tree's manifest a leading
  # dot-slash left the union overlapping and the run reporting nothing owed.
  git -C "$ROOT" -c core.quotePath=false ls-files 2>/dev/null \
    | LC_ALL=C sort -u > "$SCRATCH/tracked"
  overlap_of() {  # overlap_of <path-list>
    LC_ALL=C awk 'NR == FNR { s[$0] = 1; next } ($0 in s) { n++ } END { print n + 0 }' \
      "$SCRATCH/tracked" "$1"
  }
  NOW_N="$(LC_ALL=C awk 'END { print NR + 0 }' "$SCRATCH/shipped.now")"
  TAG_SHIPPED_N="$(LC_ALL=C awk 'END { print NR + 0 }' "$SCRATCH/shipped.tag")"
  NOW_OVERLAP="$(overlap_of "$SCRATCH/shipped.now")"
  TAG_OVERLAP="$(overlap_of "$SCRATCH/shipped.tag")"
  # Both sides, for the reason given at the shipped count above. These two are
  # the ones gated on being ABOVE zero, so an unmeasured one disarms its half
  # of the guard rather than firing it, and the half that stayed measurable
  # then reports a clean overlap for a set nobody could count.
  if [ -z "$NOW_N" ] || [ -z "$TAG_SHIPPED_N" ]; then
    warn "NO-SCRATCH - one of the two shipped lists in $SCRATCH could not be counted, so whether the two sides spell paths the same way is unknown and nothing was compared."
    exit 2
  fi
  if { [ "$NOW_N" -gt 0 ] && [ "${NOW_OVERLAP:-0}" -eq 0 ]; } \
     || { [ "$TAG_SHIPPED_N" -gt 0 ] && [ "${TAG_OVERLAP:-0}" -eq 0 ]; }; then
    warn "SHIPPED-UNKNOWN - a manifest names shipped paths that git's own list of tracked files matches none of, so the two sides are spelling paths differently and nothing below could find a change in them."
    warn "This tree's manifest names $NOW_N and git recognises $NOW_OVERLAP. The $V tag's manifest names $TAG_SHIPPED_N and git recognises $TAG_OVERLAP."
    warn "A trailing carriage return on one side, a quoted escape on one side, or a leading dot-slash each look exactly like this. Nothing was compared."
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
  #
  # --no-renames, and this is not tidiness. Rename detection is on by default,
  # and --name-only prints ONE line per renamed pair, the destination. Retire a
  # shipped file by moving it somewhere the manifest does not ship and the only
  # path printed is the new unshipped one, which the filter below drops, so a
  # shipped file vanishes and nothing is owed. With renames off the pair is a
  # delete and an add and both paths are printed.
  #
  # THE EXIT STATUS IS READ. It was not, and that was the sharpest defect in
  # this file, because every way this command can fail leaves an empty file, a
  # changed count of zero, and the words "this tree is the $V release and
  # nothing is owed" on exit 0. A failure of the check was indistinguishable
  # from a clean release, in the one script written against exactly that.
  #
  # NO CAUSE IS NAMED IN THE MESSAGE, and that is deliberate. Two were named
  # here at first, an index lock held by another process and a tag object that
  # was never fetched, and both were then measured and neither produces it.
  # git skips refreshing the index rather than failing on a held lock, and it
  # answered anyway with a tree object of the comparison deleted. Guessing at a
  # cause in the output would send a reader to check something that was never
  # the problem, so git's own complaint is printed instead and the message says
  # only what is certain, which is that the answer is unknown. Stderr is kept
  # for exactly that reason rather than discarded.
  if ! git -C "$ROOT" -c core.quotePath=false diff --no-renames --name-only "$V" -- \
       > "$SCRATCH/diffed" 2> "$SCRATCH/differr"; then
    warn "DIFF-FAILED - git could not compare this tree against the $V tag, so whether a release is owed is unknown."
    LC_ALL=C sed 's/^/  /' "$SCRATCH/differr" >&2
    warn "Whatever git said about it is printed above. Nothing was compared, and this is NOT saying the release is up to date."
    exit 2
  fi
  LC_ALL=C awk '
    NR == FNR { ship[$0] = 1; next }
    ($0 in ship) { print }
  ' "$SCRATCH/shipped" "$SCRATCH/diffed" > "$SCRATCH/changed"
  CHANGED_N="$(LC_ALL=C awk 'END { print NR + 0 }' "$SCRATCH/changed")"
  # THE ONE THAT MATTERS MOST, for the reason given at the shipped count above.
  # This count is the verdict. Unmeasured, it skips the refusal below and lands
  # on the clean line, so the single sentence a reader trusts is printed about
  # a comparison whose result was never read.
  if [ -z "$CHANGED_N" ]; then
    warn "NO-SCRATCH - the changed set in $SCRATCH could not be counted, so whether a release is owed is unknown, and this is NOT saying the release is up to date."
    exit 2
  fi

  if [ "$CHANGED_N" -gt 0 ]; then
    warn "UNRELEASED-CHANGES - $CHANGED_N of the $SHIPPED_N file(s) this template ships differ from the $V tag, and VERSION still says $V, so a vault fetching $V does not get them."
    warn "Changed since $V, and unreachable by anybody downstream:"
    LC_ALL=C sed 's/^/  /' "$SCRATCH/changed" >&2
    warn "Set VERSION to a number above $V, add its CHANGELOG.md entry with an Adopting this note, regenerate the manifest, and cut the release."
    warn "  VAULT_TEMPLATE_MAINTAINER=1 bash .claude/scripts/vault-update.sh --generate"
    warn "  bash .github/release-check.sh --tag"
    exit 1
  fi

  # The clean line is held back under --tag, because that run is about to
  # refuse. Printing "nothing is owed" on standard output and then a refusal on
  # standard error leaves a caller reading one stream told the opposite of what
  # the exit code says.
  if [ "$MODE" = tag ]; then
    warn "ALREADY-TAGGED - $V is already a tag and this tree matches it, so there is nothing to cut. Bump VERSION first."
    exit 1
  fi
  say "0 of $SHIPPED_N shipped file(s) differ from the $V tag, so this tree is the $V release and nothing is owed."
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
  # THE SAME FENCE RULE THE EXTRACTION BELOW USES, and it has to be the same or
  # the two disagree about which line is the newest heading. This guard decides
  # whether the extraction runs at all, and the extraction learned about fenced
  # code blocks while this did not, which left the gate reading one file by one
  # rule and the extractor reading it by another.
  #
  # What that costs is the worst thing in this file. Put a fenced example above
  # the entries, which the comment below says is an ordinary thing to write and
  # this file has done, and head it with a version this tree is about to
  # release. The gate takes the fenced line, agrees it is the version being
  # released, and the fence-aware extraction skips that same line and takes the
  # entry BELOW it. The tag is then written under one version carrying another
  # version's notes, and the line that reports success names the version whose
  # notes are not in it. A pushed tag is the one artefact here that cannot be
  # quietly corrected.
  CL_V="$(LC_ALL=C awk '
    { sub(/\r$/, "") }
    /^```/ { fence = 1 - fence; next }
    !fence && /^## / { print $2; exit }
  ' "$ROOT/$CHANGELOG_REL" 2>/dev/null)"
  if [ "$CL_V" != "$V" ]; then
    warn "NO-NOTES - VERSION says $V and the NEWEST CHANGELOG.md entry heads [${CL_V:-nothing}], so the notes this would tag with are not $V's."
    warn "The newest entry has to be the one being released, because that is the entry this takes the tag message from and the one tmpl-version-agrees holds VERSION against. An entry for $V further down the file is not enough, and an Unreleased section above them reads as the newest entry too."
    warn "Head it '## $V' and give it a '### Adopting this' note. Both strings are matched literally, by this script and by tmpl-changelog-adopting."
    exit 1
  fi
  # Beside the scratch rather than inside it. The scratch is cleared at the top
  # of every run, and the line below hands this path to the reader as the
  # --notes-file for their release, so a verification run between cutting the
  # tag and publishing it would delete the notes out from under them.
  NOTES="$GITDIR/release-notes-$V.md"
  # FENCES ARE TRACKED, because a `## ` at the start of a line inside a fenced
  # code block is not a heading and stopping at one truncates the message with
  # nothing saying so. A changelog that shows an example heading in a code
  # block is an ordinary thing to write, and this file has done it.
  if ! LC_ALL=C awk '
    { sub(/\r$/, "") }
    /^```/ { fence = 1 - fence; if (seen) print; next }
    !fence && /^## / { if (seen) exit; seen = 1; print; next }
    seen { print }
  ' "$ROOT/$CHANGELOG_REL" > "$NOTES" 2>/dev/null; then
    warn "NO-NOTES - $ROOT/$CHANGELOG_REL could not be read, so the notes for $V could not be taken out of it and nothing was cut."
    exit 2
  fi
  # The BODY is counted, not the file. The awk above prints the heading itself
  # before any body, so the file is never empty and `-s` was a refusal that
  # could not fire. An entry with a heading and nothing under it - which is
  # exactly the case this was written for - was tagged with a message
  # consisting of its own version number and nothing else.
  #
  # A FAILURE TO MEASURE LEAVES ON 2, not on 1. Defaulting an unmeasured count
  # to zero and then refusing would print a claim about what the changelog
  # contains when the changelog was never read, which is this file's own
  # doctrine about 1 and 2 inverted.
  NOTES_BODY="$(LC_ALL=C awk 'NR > 1 && NF { n++ } END { print n + 0 }' "$NOTES" 2>/dev/null)"
  if [ -z "$NOTES_BODY" ]; then
    warn "NO-NOTES - the notes taken out of CHANGELOG.md for $V could not be measured, so whether there are any is unknown and nothing was cut."
    exit 2
  fi
  if [ "$NOTES_BODY" -lt 1 ]; then
    warn "NO-NOTES - the $V entry in CHANGELOG.md is a heading with nothing under it, so the only thing there is to tag $V with is its own number."
    warn "The notes are the only part of a release that can carry a meaning rather than bytes, so a release with none is worth stopping for."
    exit 1
  fi
  # --cleanup=verbatim, and this one was found by running it rather than by
  # reading it. git's default for a tag message is to strip every line that
  # begins with a hash, because a hash starts a comment in the editor it would
  # otherwise open. A changelog entry is markdown, so that default removes the
  # version heading AND every sub-heading, including `### Adopting this`, which
  # CHANGELOG.md itself calls the only part of a release that can carry a
  # meaning rather than bytes. Measured: an entry of a heading, a body line,
  # `### Added`, a bullet and `### Adopting this` was stored as four lines of
  # body with no structure at all.
  git -C "$ROOT" tag -a "$V" --cleanup=verbatim -F "$NOTES" 2> "$SCRATCH/tagerr" || {
    warn "TAG-FAILED - git would not write the $V tag, so nothing was cut."
    LC_ALL=C sed 's/^/  /' "$SCRATCH/tagerr" >&2
    warn "An annotated tag carries a tagger, so the commonest cause is a checkout with no user.name and user.email set. This does not set them for you, because whose name goes on a release is not a script's decision."
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
