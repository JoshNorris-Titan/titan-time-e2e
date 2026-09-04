#!/usr/bin/env bash
# Every row of the consultant's Timesheet History must carry a status pill, and
# that pill must say the same thing as the week badge above the grid.
#
# Why this test exists (2026-09-03): the history list already had a pill
# (txtHistoryStatus, inside the tipHistoryStatus tooltip) but it was hidden by a
# conditional visibility of `$currentObject/Status != empty`. Main.Timesheet.Status
# has NO default value, so a week that was opened but never saved is persisted with
# no status at all and its history row rendered with a blank gap where the pill
# should be. Probed against the running app before the fix: one history row,
# the week label present, .mx-name-tipHistoryStatus present, and ZERO
# .mx-name-txtHistoryStatus. Assertion 2 is that exact case.
#
# The fix also aligned the pill with its sibling txtWeekStatus (see
# verify-week-status-badge.test.sh), which is why the caption table below is the
# week badge's table and not the enum's captions:
#
#     Draft             -> "Draft"           / status-badge badge-draft
#     Awaiting_Approval -> "Submitted"       / status-badge badge-submitted
#     Approved          -> "Approved"        / status-badge badge-approved
#     Rejected          -> "Rejected"        / status-badge badge-rejected
#     Awaiting_Export   -> "Awaiting export" / status-badge badge-awaiting-export
#     (empty)           -> "Draft"           / status-badge badge-draft
#
# The history pill and the week pill are SIX SEPARATE EXPRESSIONS over one enum --
# two on each widget (caption, dynamicClasses) plus the two fall-through branches.
# Nothing in the model couples them. Assertion 4 couples caption to colour within a
# row; assertion 6 couples the history row to the week badge describing the same
# week. Those are the two ways this drifts.
#
# ROW SCOPING. A gallery repeats every .mx-name-* once per row, so an unscoped
# querySelector always reads row 0 and an unscoped count conflates rows. Rows are
# scoped on `.widget-gallery-item`, which is what the rest of the suite already uses
# for THIS gallery -- lib/_seed.sh, lib/_tt692693.sh and
# suites/70-tickets/tt737/verify-tt737-null-startdate-heals.test.sh. Do NOT scope on
# `.gallery-item`: that comes from the gallery's itemClass expression and did not
# appear in the rendered DOM at all when this was probed.
#
# THE TWO WIDGETS INSIDE THE ROW WERE RENAMED FOR THIS TEST. They were text13 and
# image2 -- Studio Pro's auto-generated names, which this suite forbids because they
# renumber whenever the page is edited. They are now txtHistoryWeek (the week's date
# range) and imgHistoryDelete (the trash-can icon). Nothing else in the model, the
# suite or docs/ referenced either name.
#
# THE DELETE ICON NOW DEPENDS ON HOURS AS WELL AS STATUS (2026-09-04, finding T3).
# imgHistoryDelete used to fire a raw client-side Delete with no confirmation and no
# undo, about 20px from the row that OPENS a week. It now calls a microflow that puts
# a confirmation dialog in front of the delete, and its conditional visibility moved
# from an enum condition list on Status to an expression combining that same status
# set with TotalHours = 0 -- so a misclick can only ever destroy a week that holds
# nothing. Assertion 5 below therefore couples the icon to the pill AND to the hours.
#
# A third widget in the row was named for this: txtHistoryHours, the "{1} hrs" text,
# formerly the auto-generated text21. Note WHICH hours it renders -- it is bound to
# Main.TimesheetHelper.TotalHours, summed per row at render time by
# Main.DS_Timesheet_TotalHours, while the icon's visibility expression reads the
# STORED Main.Timesheet.TotalHours. Nothing in the model keeps those two in step.
# Assertion 5 asserts against the number the CONSULTANT CAN SEE, which is the whole
# point: if the stored total ever drifts from the entry sum, this test is what says
# so, by catching a bin offered on a row that reads a non-zero number.
#
# PAGING. galTimesheetHistory is "Load more" with pageSize 25, not virtual scrolling,
# so a consultant with more than 25 weeks has the rest outside the DOM entirely.
# tt_gallery_load_all pages the whole list in first; without it "every row carries a
# pill" would silently mean "every row on page one".
#
# NON-DESTRUCTIVE and idempotent. It pages the history list and reads it, plus the
# week badge; it never types, saves, submits or deletes, and it never touches
# filterStatus / filterStartDate / filterEndDate, so it neither consumes a week from
# the fresh-week pool nor leaves a filter set for whatever runs next.

set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

tt_login "e2e_consultant" "My Timesheets"

tt_wait_for ".mx-name-galTimesheetHistory" "consultant timesheet history gallery"

# Page the whole list in before reading it. Non-fatal by design: it echoes 0 rather
# than failing when there is nothing to page, and assertion 1 below is what reports
# an empty list.
LOADED="$(tt_gallery_load_all ".mx-name-galTimesheetHistory" "timesheet history")"

# Read the whole list AND the week badge in ONE eval. Two evals would cost ~2.6s of
# node startup each and could straddle a repaint, which would make assertion 6
# compare a history row against a week that is no longer on screen.
#
# Record format, one row per entry:
#   <date>|<pill-present>|<pill-text>|<pill-classes>|<hours-text>|<delete-icon-present>
# Hours go BEFORE the icon flag so the icon stays the last field the parser splits on.
# with the week badge's caption and the week's date range in the FIRST entry, as
#   WEEK|<week-badge-caption>|<txtWeekRange text>
# Entries are joined with '~~' because _tt_eval_str reads a single line.
REPORT="$(playwright-cli eval "() => {
  const gal = document.querySelector('.mx-name-galTimesheetHistory');
  if (!gal) return 'NO-GALLERY';

  const weekEl  = document.querySelector('.mx-name-txtWeekStatus');
  const rangeEl = document.querySelector('.mx-name-txtWeekRange');
  const lines = ['WEEK|' + (weekEl  ? (weekEl.innerText  || '').trim() : '')
                    + '|' + (rangeEl ? (rangeEl.innerText || '').trim() : '')];

  for (const row of gal.querySelectorAll('.widget-gallery-item')) {
    const d = row.querySelector('.mx-name-txtHistoryWeek');
    const b = row.querySelector('.mx-name-txtHistoryStatus');
    const i = row.querySelector('.mx-name-imgHistoryDelete');
    const h = row.querySelector('.mx-name-txtHistoryHours');
    lines.push([
      d ? (d.innerText || '').trim() : '',
      b ? 'yes' : 'no',
      b ? (b.innerText || '').trim() : '',
      b ? (b.className || '') : '',
      h ? (h.innerText || '').trim() : '',
      i ? 'yes' : 'no'
    ].join('|'));
  }
  return lines.join('~~');
}" 2>/dev/null | _tt_eval_str)"

if [ "$REPORT" = "NO-GALLERY" ]; then
  tt_fail "timesheet history missing: no .mx-name-galTimesheetHistory on the consultant dashboard"
fi

# Split the ~~-joined record back into entries.
OLD_IFS="$IFS"; IFS='~'
# shellcheck disable=SC2206
PARTS=($REPORT)
IFS="$OLD_IFS"

WEEK_TEXT=""
WEEK_RANGE=""
ROWS=0
CHECKED=0
SEEN=""

for PART in "${PARTS[@]}"; do
  [ -z "$PART" ] && continue

  case "$PART" in
    WEEK\|*)
      REST="${PART#WEEK|}"
      WEEK_TEXT="${REST%%|*}"
      WEEK_RANGE="${REST#*|}"
      continue
      ;;
  esac

  DATE="${PART%%|*}";    REST="${PART#*|}"
  PRESENT="${REST%%|*}"; REST="${REST#*|}"
  TEXT="${REST%%|*}";    REST="${REST#*|}"
  CLASSES="${REST%%|*}"; REST="${REST#*|}"
  HOURS="${REST%%|*}"
  DEL="${REST##*|}"

  ROWS=$((ROWS+1))

  # --- Assertion 2: the row has a pill at all --------------------------------
  # The regression this file was written for. Before the fix a status-less week
  # rendered the row, the date and the tooltip wrapper but no pill.
  if [ "$PRESENT" != "yes" ]; then
    tt_fail "timesheet history row '$DATE' has no status pill: .mx-name-txtHistoryStatus is absent, which is what a Timesheet with an empty Status used to render"
  fi

  # --- Assertion 3: it is a real, themed pill --------------------------------
  if [ -z "$TEXT" ]; then
    tt_fail "timesheet history row '$DATE' rendered an empty pill: the caption expression produced no text (classes='$CLASSES')"
  fi

  case "$CLASSES" in
    *status-badge*) : ;;
    *) tt_fail "timesheet history row '$DATE' is not using the shared pill: expected 'status-badge' in class list, got '$CLASSES'" ;;
  esac

  # --- Assertion 4: caption and colour agree ---------------------------------
  # Two independent expressions on one widget. Edit one branch, forget the other,
  # and the row reads "Approved" in rejected-red.
  case "$TEXT" in
    "Draft")           WANT="badge-draft" ;;
    "Submitted")       WANT="badge-submitted" ;;
    "Approved")        WANT="badge-approved" ;;
    "Rejected")        WANT="badge-rejected" ;;
    "Awaiting export") WANT="badge-awaiting-export" ;;
    *) tt_fail "timesheet history row '$DATE' shows an unmapped caption '$TEXT' — the caption expression has a branch the badge vocabulary does not (classes='$CLASSES')" ;;
  esac

  case "$CLASSES" in
    *"$WANT"*) : ;;
    *) tt_fail "timesheet history row '$DATE' disagrees with itself: caption '$TEXT' should carry '$WANT' but classes are '$CLASSES'" ;;
  esac

  # --- Assertion 5: the pill and the hours agree with the delete affordance --
  # Independent signals, separate settings. imgHistoryDelete's visibility expression
  # ticks Draft/(empty) status AND a zero total, so the icon must appear on exactly
  # the rows whose pill reads "Draft" and whose hours read zero -- and nowhere else.
  # Three ways this drifts: the pill's fall-through branch stops covering the empty
  # status; the visibility expression loses one of its two halves; or the stored
  # Main.Timesheet.TotalHours drifts from the per-row sum this row displays. All
  # three land here.
  if [ -z "$HOURS" ]; then
    tt_fail "timesheet history row '$DATE' has no hours text: .mx-name-txtHistoryHours is absent, so the delete icon's zero-hours condition cannot be checked (was the widget renamed, or did its data view fail to load?)"
  fi

  # "0.00 hrs" -> "0.00". The template is "{1} hrs" at 2dp, but do not assume the
  # precision: accept any spelling of zero and treat everything else as non-zero.
  HOURS_NUM="${HOURS%% *}"
  case "$HOURS_NUM" in
    0|0.|0.0|0.00|0.000|-0|-0.0|-0.00) ZERO_HOURS="yes" ;;
    *)                                 ZERO_HOURS="no" ;;
  esac

  if [ "$TEXT" = "Draft" ] && [ "$ZERO_HOURS" = "yes" ]; then
    EXPECT_DEL="yes"
  else
    EXPECT_DEL="no"
  fi

  if [ "$DEL" != "$EXPECT_DEL" ]; then
    if [ "$EXPECT_DEL" = "yes" ]; then
      tt_fail "timesheet history row '$DATE' reads 'Draft' and $HOURS but has no delete icon — an empty draft week the consultant is allowed to remove offers no way to remove it"
    elif [ "$TEXT" != "Draft" ]; then
      tt_fail "timesheet history row '$DATE' reads '$TEXT' (a submitted or finished week) but still offers a delete icon — a consultant can delete a week the pill calls finished"
    else
      tt_fail "timesheet history row '$DATE' reads 'Draft' with $HOURS on it but still offers a delete icon — the icon is meant to appear only on weeks totalling zero, so either its visibility expression lost the hours condition or the stored total disagrees with the hours this row displays"
    fi
  fi

  # --- Assertion 6: history agrees with the week badge -----------------------
  # txtWeekRange/txtWeekStatus describe ONE week; if that week is also in the
  # history list, the two pills are describing the same Timesheet row and must say
  # the same word. This is the assertion that keeps the two widgets from drifting.
  # txtWeekRange renders "<FirstName> MMM dd - MMM dd" while the history row renders
  # "MMM dd - MMM dd", so match on the suffix.
  if [ -n "$WEEK_TEXT" ] && [ -n "$DATE" ]; then
    case "$WEEK_RANGE" in
      *"$DATE")
        if [ "$TEXT" != "$WEEK_TEXT" ]; then
          tt_fail "the same week is labelled two different ways: history row '$DATE' says '$TEXT' but the week badge above the grid says '$WEEK_TEXT'"
        fi
        CHECKED=$((CHECKED+1))
        ;;
    esac
  fi

  case "$SEEN" in
    *"[$TEXT]"*) : ;;
    *) SEEN="$SEEN[$TEXT]" ;;
  esac
done

# --- Assertion 1: there was something to check -----------------------------
# Kept last so a genuinely broken row fails with its own message first. Zero rows
# here is almost always a fixture or ordering problem rather than a product bug:
# 00-setup clears the data, so running this spec directly (instead of through
# run-tests.sh) or ahead of whatever seeds e2e_consultant's weeks leaves the list
# empty and every assertion above unreachable.
if [ "$ROWS" -eq 0 ]; then
  tt_fail "timesheet history is empty for e2e_consultant — nothing to assert (tt_gallery_load_all reported ${LOADED:-0} card(s)). Run the suite through run-tests.sh so the seeders run first; if it is still empty, the seed for this account did nothing."
fi

echo "PASS: all $ROWS timesheet-history row(s) carry a themed status pill whose caption, colour and delete affordance agree; $CHECKED row(s) cross-checked against the week badge; captions seen: ${SEEN:-none}"
