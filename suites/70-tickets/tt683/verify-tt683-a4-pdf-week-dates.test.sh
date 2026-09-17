#!/usr/bin/env bash
# TT-683 angle 4 — each week block in an exported PDF prints seven CONSECUTIVE
# days, starting on the Sunday its own column header claims.
#
# tt-timeout: 5m
#
# WHY THIS EXISTS. Main.MonthlyExportPDF builds the weekday date row from seven
# separate Text widgets, each with its own expression of the form
# formatDateTime(addDays($currentObject/StartDate, N), 'MMM dd'). They are
# independent, so nothing in the model makes N run 0..6 -- that is a property of
# six hand-written expressions agreeing with each other, and for months they did
# not. text20/21/22 carried addDays(+2), (+3) and (+4) where they should have
# carried (+1), (+2) and (+3), so every exported timesheet printed a week with
# one day missing and the next one doubled:
#
#     printed    Oct 04  Oct 06  Oct 07  Oct 08  Oct 08  Oct 09  Oct 10
#     correct    Oct 04  Oct 05  Oct 06  Oct 07  Oct 08  Oct 09  Oct 10
#
# The handoff that fixed it (docs/handoffs/monthly-export-pdf-week-dates.md) makes
# the point this test exists to answer: "the document reads as completely normal".
# The grid is the right shape, the totals are right, the filename is right, and
# the hours land in columns that are each labelled with a plausible date. Only
# comparing the dates to each other shows it. a1 checks the archive's shape, a2
# its filenames and a3 that each body matches the consultant and project its name
# claims -- all four of those held throughout, because none of them reads a date.
#
# The fix is in the saved model as of 2026-09-17 and has nothing guarding it. A
# future edit to any one of those seven widgets can reintroduce it silently.
#
# WHAT IT ASSERTS, per PDF in the archive:
#   A. at least one "Week N" row is present. A document with none is a failure,
#      not a skip -- it means the grid did not render, and reporting that as
#      "no dates to check" is exactly the shape of assertion this suite exists
#      to stop shipping.
#   B. each week row carries exactly SEVEN dates. Six or eight is a column
#      that vanished or doubled, which is the same defect class seen from the
#      other side.
#   C. those seven are strictly consecutive calendar days.
#   D. the first of them falls on a SUNDAY, which the row's own column header
#      ("Sun Mon Tues Wed Thu Fri Sat") asserts. C alone would pass on a week
#      shifted wholesale by a day.
#   E. where a PDF holds more than one week row, consecutive rows start exactly
#      seven days apart. C and D are per-row and cannot see a week skipped or
#      repeated between rows.
#
# HOW A DATE IS DATED. The row prints 'MMM dd' with no year, so the year comes
# from the report heading ("October 2026"). A week block may legitimately straddle
# a month end, so a December row under a January report is read as the PREVIOUS
# year and a January row under a December report as the NEXT one; without that a
# year-end export would fail on D for a reason that has nothing to do with the
# model. All date arithmetic is done in UTC so a DST boundary cannot turn a
# 24-hour step into 23 or 25 and read as a missing day.
#
# WHERE THE ARCHIVE COMES FROM. The one verify-tt683-a1 downloaded, whose path it
# parks in TT683_ZIP_STATE -- the same reuse a2 and a3 do, and for the same
# reason: Export All consumes the AwaitingExport batch, so driving a second export
# here would find nothing left and report it as a product failure. Like a3 and
# unlike a2 this does NOT fall back to its own export. If the archive is not there
# the honest answer is that this step could not run.
#
# REQUIRES pdftotext (poppler-utils), and fails rather than skipping without it,
# for the reason a3 gives: a silently-skipped check is indistinguishable from a
# passing one in the summary.
#
# Reads only. Extracts into a temp directory it removes on exit. Drives no
# browser and needs no login.
#
# Consumes: nothing. Works on the archive a1 left on disk.
# Env: none of its own.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt683.sh"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

command -v pdftotext >/dev/null 2>&1 \
  || tt_fail "pdftotext is not installed, so the PDFs cannot be read. This step will not report a pass it did not earn - install poppler-utils, or put this basename in ci-skip.txt if the environment genuinely cannot have it."

ZIPPATH="$(_tt683_zip_path 2>/dev/null)" \
  || tt_fail "no export archive is on disk. verify-tt683-a1 captures it and parks the path in .tt683-zip.path; run the tt683 steps in order. This step deliberately does NOT drive its own export - a1 consumes the AwaitingExport batch, so a second one would find nothing and look like a product bug."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MAP="$(python "$TT683_ZIPREPORT" "$ZIPPATH" extract "$WORK" 2>"$WORK/.err")" || {
  tt_fail "could not extract $ZIPPATH: $(head -1 "$WORK/.err" 2>/dev/null)"
}
[ -n "$MAP" ] || tt_fail "extracting $ZIPPATH produced no entries"

echo "archive: $ZIPPATH"

# epoch_of <MMM> <dd> <yyyy> — UTC epoch seconds, or empty if unparseable.
# LC_ALL=C because the document prints English month abbreviations regardless of
# the runner's locale, and a localised `date` would refuse them.
epoch_of() {
  LC_ALL=C date -u -d "$1 $2 $3" +%s 2>/dev/null
}

# row_year <row-month-abbrev> <report-month-name> <report-year>
# The printed row carries no year. A week may straddle a month end, so December
# under a January report belongs to the year before, and January under a December
# report to the year after.
row_year() {
  case "$1:$2" in
    Dec:January) echo $(( $3 - 1 )) ;;
    Jan:December) echo $(( $3 + 1 )) ;;
    *) echo "$3" ;;
  esac
}

checked_pdfs=0
checked_rows=0

while IFS= read -r line; do
  [ -n "$line" ] || continue
  entry="${line%%~~*}"
  file="${line#*~~}"

  txt="$WORK/$(basename "$entry").txt"
  pdftotext -layout "$file" "$txt" 2>/dev/null || { bad "$entry: pdftotext could not read it"; continue; }
  [ -s "$txt" ] || { bad "$entry: produced no text at all (a blank render is not a pass)"; continue; }

  # The report heading, e.g. "October 2026". Needed to date the rows.
  heading="$(grep -oE '(January|February|March|April|May|June|July|August|September|October|November|December) 20[0-9]{2}' "$txt" | head -1)"
  if [ -z "$heading" ]; then
    bad "$entry: no '<Month> <year>' heading found, so its week rows cannot be dated"
    continue
  fi
  rmonth="${heading%% *}"
  ryear="${heading##* }"

  # Week rows look like: "Week 1  Oct 04  Oct 05  ...  Total"
  rows="$(grep -nE '^[[:space:]]*Week[[:space:]]+[0-9]+' "$txt")"
  if [ -z "$rows" ]; then
    bad "$entry: no 'Week N' row found. The grid did not render, so there are no dates to be right or wrong."
    continue
  fi

  checked_pdfs=$((checked_pdfs+1))
  prev_start=""

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    rowtext="${row#*:}"
    label="$(printf '%s' "$rowtext" | grep -oE 'Week[[:space:]]+[0-9]+' | head -1)"

    # Every 'MMM dd' on the row, in order.
    toks="$(printf '%s' "$rowtext" | grep -oE '[A-Z][a-z][a-z][[:space:]]+[0-9][0-9]')"
    n="$(printf '%s\n' "$toks" | grep -c . )"

    # B — exactly seven.
    if [ "$n" -ne 7 ]; then
      bad "$entry / $label: carries $n date(s), not 7 -> [$(printf '%s' "$toks" | tr '\n' ' ')]"
      continue
    fi

    # Normalise to "MMM dd" with single spaces, and date the first one.
    set --
    while IFS= read -r t; do
      set -- "$@" "$(printf '%s' "$t" | tr -s '[:space:]' ' ')"
    done <<< "$toks"

    first_mon="${1%% *}"
    yr="$(row_year "$first_mon" "$rmonth" "$ryear")"
    start="$(epoch_of "$first_mon" "${1##* }" "$yr")"
    if [ -z "$start" ]; then
      bad "$entry / $label: could not read '$1' as a date"
      continue
    fi

    # D — the first column is Sunday, as the header claims.
    dow="$(LC_ALL=C date -u -d "@$start" +%A)"
    [ "$dow" = "Sunday" ] \
      && note "$entry / $label: starts $1 ($dow)" \
      || bad "$entry / $label: starts $1, which is a $dow, but the column header says Sun"

    # C — the seven are consecutive. Compare against the week the FIRST date
    # implies, so the failure names the day that is wrong rather than a delta.
    i=0
    for got in "$@"; do
      want="$(LC_ALL=C date -u -d "@$(( start + i * 86400 ))" +'%b %d')"
      [ "$got" = "$want" ] \
        || bad "$entry / $label: column $((i+1)) prints '$got' where seven consecutive days from $1 require '$want'"
      i=$((i+1))
    done

    # E — consecutive week rows are seven days apart.
    if [ -n "$prev_start" ]; then
      gap=$(( (start - prev_start) / 86400 ))
      [ "$gap" -eq 7 ] \
        || bad "$entry / $label: starts $gap day(s) after the previous week row, not 7"
    fi
    prev_start="$start"
    checked_rows=$((checked_rows+1))
  done <<< "$rows"
done <<< "$MAP"

# A — something was actually examined. Reaching the end having checked nothing is
# the failure this suite was audited for, not a quiet pass.
[ "$checked_pdfs" -gt 0 ] || bad "no PDF in the archive yielded a week row, so nothing was checked"
[ "$checked_rows" -gt 0 ] || bad "no week row was checked, so this step has no verdict to give"

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-tt683-a4-pdf-week-dates — $fails week-date problem(s) across $checked_pdfs PDF(s)."
  exit 1
fi
echo "PASS: verify-tt683-a4-pdf-week-dates — $checked_rows week row(s) in $checked_pdfs PDF(s) each print seven consecutive days from a Sunday."
