#!/usr/bin/env bash
# verify-week-key-contract.test.sh
#
# tt_week_key (lib/_login.sh) is the single place that knows how this app names a
# week. Six comparisons in this suite identify a week by running two differently
# worded labels through it and comparing the results, so a hole in it does not
# error -- it silently stops matching, and the assertions built on it quietly
# compare nothing.
#
# That is not hypothetical. Before TT-745 the normaliser was a sed requiring
# "Mmm DD - Mmm DD" verbatim. TT-745 changed the consultant caption to
# "This week - Sep 7 - 13": no trailing month, no zero padding, en dash. Every
# call would have returned '' and, in verify-history-status-badge, assertion 6
# would have cross-checked zero rows and still printed PASS.
#
# So the shapes are pinned here, table-driven, INCLUDING the inputs that must
# yield nothing. A normaliser that matches anything is worse than a red test.
#
# Nothing here drives a browser or needs the app. It is a static contract check
# and runs in about a second.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
# shellcheck disable=SC1091
source "$TT_ROOT/lib/_login.sh" >/dev/null 2>&1

fails=0
checked=0

# expect <input> <expected-key> <why>
expect() {
  local got
  got="$(tt_week_key "$1")"
  checked=$((checked + 1))
  if [ "$got" != "$2" ]; then
    echo "  FAILED: tt_week_key '$1' gave '$got', expected '$2'  ($3)"
    fails=$((fails + 1))
  fi
}

# ------------------------------------------------------- 1. the four live shapes
# One row per surface that names a week. Each of these is matched against one of
# the others somewhere in this suite; see the tt_week_key comment for the map.
expect "This week $(printf '\xc2\xb7') Sep 7 $(printf '\xe2\x80\x93') 13"       "Sep 07 - Sep 13" "TT-745 consultant caption, same month"
expect "Last week $(printf '\xc2\xb7') Aug 31 $(printf '\xe2\x80\x93') Sep 6"  "Aug 31 - Sep 06" "TT-745 caption crossing a month boundary"
expect "E2E Sep 06 - Sep 12"                                                    "Sep 06 - Sep 12" "pre-TT-745 caption, first-name prefix"
expect "Sep 06 - Sep 12"                                                        "Sep 06 - Sep 12" "galTimesheetHistory row"
expect "Oct 04 - Oct 10, 2026"                                                  "Oct 04 - Oct 10" "HR week picker, trailing year"

# --------------------------------------------------- 2. the rest of the caption
# The relative label is unbounded and the range can cross a year, so the prefix
# must never be mistaken for the range.
expect "3 weeks ago $(printf '\xc2\xb7') Aug 17 $(printf '\xe2\x80\x93') 23"    "Aug 17 - Aug 23" "N weeks ago"
expect "In 34 weeks $(printf '\xc2\xb7') May 3 $(printf '\xe2\x80\x93') 9"      "May 03 - May 09" "In N weeks, single-digit days"
expect "Next week $(printf '\xc2\xb7') Dec 28 $(printf '\xe2\x80\x93') Jan 3"   "Dec 28 - Jan 03" "week crossing new year"
expect "Sep 06 $(printf '\xe2\x80\x94') Sep 12"                                 "Sep 06 - Sep 12" "em dash separator"

# ------------------------------------------------------ 3. what it must REJECT
# The whole point of a normaliser is lost if it guesses. Every one of these must
# come back empty so callers fall back or fail loudly instead of comparing junk.
expect ""                        "" "empty string"
expect "This week"               "" "relative label with no range at all"
expect "Sep 7"                   "" "half a range is not a week"
expect "no week here"            "" "arbitrary text"
expect "Projects: 0  40.00 hrs"  "" "a history row's tail, with no date"

# ------------------------------------------- 4. it must return 0, never non-zero
# One caller (suites/20-consultant/verify-consultant-timesheet.test.sh and
# friends) runs under `set -euo pipefail`, where a non-zero return from a command
# substitution aborts the whole spec. The no-match path must be silent, not
# unsuccessful.
if ! tt_week_key "nothing in here" >/dev/null 2>&1; then
  echo "  FAILED: tt_week_key returned non-zero on a no-match input; a spec under 'set -e' would abort"
  fails=$((fails + 1))
fi
checked=$((checked + 1))

# ------------------------------------------------------------------------ report
echo "  $checked week-key case(s) checked"
if [ "$fails" -gt 0 ]; then
  echo "FAIL: $fails week-key contract violation(s)"
  exit 1
fi
echo "PASS: tt_week_key normalises every week label this suite meets, and rejects every partial one"
