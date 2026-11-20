# shellcheck shell=bash
# Sourced by ci.yml's steps that check every tracked file of a kind. bash only.
#
# tracked [-s] <pathspec>... writes the matching index entries, NUL-separated,
# to $RUNNER_TEMP/files (with -s, each as "<mode> <object> <stage><TAB><name>").
# A step reads them on descriptor 3:
#
#   tracked '*.json'
#   while IFS= read -r -d '' -u 3 f; do ...; done 3< "$RUNNER_TEMP/files"
#
# so a name with a space is one file, and a command in the loop that reads its
# input cannot eat the names still to come.
#
# Any one pathspec that matches nothing fails the step in the template repository
# (TEMPLATE_REPO=true), since after a rename or a typo the step would otherwise
# pass having checked nothing. These steps also run in a vault made from the
# template, which may well have removed a harness's files, so there it is a
# notice and the loop reads an empty list.
tracked() {
  local opt=""
  if [ "${1:-}" = -s ]; then opt=-s; shift; fi
  [ -n "${RUNNER_TEMP:-}" ] || { echo "::error::RUNNER_TEMP is not set"; exit 1; }
  git ls-files -z $opt -- "$@" > "$RUNNER_TEMP/files" || { echo "::error::git ls-files failed"; exit 1; }
  # Each pathspec on its own: the files of one would otherwise hide that
  # another, renamed or emptied, now matches nothing.
  local p empty=""
  for p in "$@"; do
    [ -n "$(git ls-files -- "$p" | head -n 1)" ] || empty="$empty $p"
  done
  if [ -z "$empty" ]; then return 0; fi
  if [ "${TEMPLATE_REPO:-}" = true ]; then
    echo "::error title=Nothing was checked::no tracked file matches$empty"
    exit 1
  fi
  echo "::notice title=Nothing to check::no tracked file matches$empty, as in a vault that removed them"
}
