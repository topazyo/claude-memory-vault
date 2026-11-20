# Reads required-controls.txt, the control ids CI requires to run, for ci.yml.
# POSIX awk only: the bash 3.2 job runs macOS's own awk.
#
#   awk -v want=<ubuntu|macos|windows> -f required-controls.awk required-controls.txt
#       prints that platform's ids on one line, space-separated
#   awk -v want=lists -f required-controls.awk required-controls.txt
#       prints the four lists the hygiene steps compare, one line each:
#       list1 windows-latest, list2 ubuntu-latest, list3 macos-latest and
#       list4 the bash 3.2 job, which runs on the macos-latest image and so
#       requires exactly the macos ids
#
# A malformed file is refused with exit 2 and a line on stderr, never read in
# part: an id that is not lower-case letters, digits and hyphens, a line with
# no platform, an unknown or repeated platform, an id on two lines, and a file
# with no id at all. A blank line and a line starting with # are skipped.
BEGIN {
  if (want != "ubuntu" && want != "macos" && want != "windows" && want != "lists") {
    print "required-controls.awk: want must be ubuntu, macos, windows or lists, not \"" want "\"" > "/dev/stderr"
    bad = 1; exit 2
  }
}
{ sub(/\r$/, "") }
/^[ \t]*$/ || /^[ \t]*#/ { next }
{
  if ($1 !~ /^[a-z0-9][a-z0-9-]*$/) fail("not a control id: " $1)
  if (NF < 2) fail($1 " names no platform")
  if ($1 in seen) fail($1 " is listed twice, on lines " seen[$1] " and " FNR)
  seen[$1] = FNR
  split("", on)
  for (i = 2; i <= NF; i++) {
    if ($i != "ubuntu" && $i != "macos" && $i != "windows") fail($1 " names an unknown platform: " $i)
    if ($i in on) fail($1 " names " $i " twice")
    on[$i] = 1
  }
  n++
  if ("windows" in on) w = w " " $1
  if ("ubuntu" in on) u = u " " $1
  if ("macos" in on) m = m " " $1
}
END {
  if (bad) exit 2
  if (n == 0) { print "required-controls.awk: " FILENAME " lists no control id" > "/dev/stderr"; exit 2 }
  if (want == "lists") {
    print "list1" w; print "list2" u; print "list3" m; print "list4" m
  } else {
    s = (want == "windows") ? w : (want == "ubuntu") ? u : m
    sub(/^ /, "", s)
    print s
  }
}
function fail(msg) {
  print "required-controls.awk: line " FNR ": " msg > "/dev/stderr"
  bad = 1; exit 2
}
