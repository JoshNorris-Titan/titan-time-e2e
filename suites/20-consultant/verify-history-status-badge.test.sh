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
# THE DELETE ICON DEPENDS ON STATUS ONLY, AND HOURS DO NOT COME INTO IT.
# imgHistoryDelete used to fire a raw client-side Delete with no confirmation and no
# undo, about 20px from the row that OPENS a week. It now calls a microflow that puts
# a confirmation dialog in front of the delete, which is what makes a misclick
# recoverable. Its conditional visibility is an expression on Status alone:
#
#     if $currentObject/Status = 'Draft' then true else $currentObject/Status = empty
#
# so every week whose pill reads "Draft" offers the bin, whether it holds 0 hours or
# 20, and no other week does. Assertion 5 below couples the icon to the pill and to
# nothing else.
#
# THIS FILE ASSERTED THE OPPOSITE UNTIL 2026-09-14, and was wrong rather than early.
# A 2026-09-04 note (finding T3) recorded the rule as "that status set AND
# TotalHours = 0", and the model's own page documentation still says so; the shipped
# expression never had the hours half, or lost it before 2026-09-11. Josh settled it
# on 2026-09-14: "leave it how it is, we want users to be able to delete if there are
# 0 hours or 20." The zero-hours coupling is therefore gone from the assertion. A
# deletable week holding hours is the product working as intended -- the confirmation
# dialog, not an hours check, is what stands between a misclick and a lost week.
#
# txtHistoryHours -- the "{1} hrs" text, formerly the auto-generated text21 -- is still
# read, but only to put the hours in the failure message, where they say WHICH week
# went wrong. It is no longer asserted on, so a row that fails to render it no longer
# fails this spec: verify-history-row-layout is what holds the row's shape.
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
WEEK_RANGE_KEY=""
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
      # Normalised once here rather than per row: the badge names one week, and
      # every row below is asked whether it is that same week.
      WEEK_RANGE_KEY="$(tt_week_key "$WEEK_RANGE")"
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

  # --- Assertion 5: the pill agrees with the delete affordance ---------------
  # imgHistoryDelete's visibility expression ticks Draft or (empty) status and
  # nothing else, and the pill reads "Draft" for both -- so the icon must appear on
  # exactly the rows whose pill reads "Draft", whatever hours they hold, and on no
  # other row. Two ways this drifts: the pill's fall-through branch stops covering
  # the empty status, or the visibility expression gains or loses a condition. Both
  # land here.
  #
  # Hours are NOT part of the rule (see the header). They are carried into the
  # messages below because "which week" is the first thing a reader asks.
  if [ "$TEXT" = "Draft" ]; then
    EXPECT_DEL="yes"
  else
    EXPECT_DEL="no"
  fi

  if [ "$DEL" != "$EXPECT_DEL" ]; then
    if [ "$EXPECT_DEL" = "yes" ]; then
      tt_fail "timesheet history row '$DATE' reads 'Draft'${HOURS:+ with $HOURS} but offers no delete icon — a draft week the consultant is allowed to remove gives them no way to remove it. imgHistoryDelete is visible on Draft or empty status, so either that expression narrowed (an hours condition is the one that has been proposed before) or the pill and the stored Status disagree"
    else
      tt_fail "timesheet history row '$DATE' reads '$TEXT'${HOURS:+ with $HOURS} (a submitted or finished week) but still offers a delete icon — a consultant can delete a week the pill calls finished"
    fi
  fi

  # --- Assertion 6: history agrees with the week badge -----------------------
  # txtWeekRange/txtWeekStatus describe ONE week; if that week is also in the
  # history list, the two pills are describing the same Timesheet row and must say
  # the same word. This is the assertion that keeps the two widgets from drifting.
  #
  # The two widgets word the week differently -- txtWeekRange reads
  # "This week · Sep 7 – 13" (TT-745) while the history row reads "Sep 07 - Sep 12"
  # -- so both go through tt_week_key and the keys are compared. This used to be a
  # SUFFIX match on the raw caption, which the TT-745 caption satisfies for no week
  # at all.
  #
  # NOTHING HERE FAILS WHEN CHECKED STAYS 0, and that is deliberate rather than an
  # oversight: the history gallery's data source is evaluated at page render, so on a
  # freshly cleared database it can legitimately come back without the current week
  # (Main.DS_Timesheet_Get creates that row during the same render -- see
  # seed_materialise_weeks in lib/_seed.sh). A hard assertion here would fail on data
  # state rather than on drift. The diagnostic printed after the loop is what keeps a
  # silent zero legible, which is what a caption change would look like.
  if [ -n "$WEEK_TEXT" ] && [ -n "$DATE" ] && [ -n "$WEEK_RANGE_KEY" ]; then
    if [ "$(tt_week_key "$DATE")" = "$WEEK_RANGE_KEY" ]; then
      if [ "$TEXT" != "$WEEK_TEXT" ]; then
        tt_fail "the same week is labelled two different ways: history row '$DATE' says '$TEXT' but the week badge above the grid says '$WEEK_TEXT'"
      fi
      CHECKED=$((CHECKED+1))
    fi
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

if [ "$CHECKED" = "0" ]; then
  echo "  NOTE: assertion 6 compared nothing -- the week badge names '${WEEK_RANGE_KEY:-?}' (from '${WEEK_RANGE:-}') and no history row resolved to that key."
  echo "        Expected on a freshly cleared database; if the gallery clearly DOES list that week, tt_week_key (lib/_login.sh) has stopped matching one of the two captions."
fi

echo "PASS: all $ROWS timesheet-history row(s) carry a themed status pill whose caption, colour and delete affordance agree; $CHECKED row(s) cross-checked against the week badge; captions seen: ${SEEN:-none}"
