#!/usr/bin/env bash
# verify-current-week-warning.test.sh
#
# Submitting the week you are standing in tells you the week has not ended.
#
# WHY THIS EXISTS. Main.SUB_Timesheet_WarningText builds the text of the submit
# confirm popup. Its first clause used to read
#
#     $Timesheet/StartDate >= [%BeginOfCurrentDay%]
#
# which tests whether the week has STARTED, not whether it has ENDED. Weeks run
# Sunday (StartDate) to Saturday (EndDate = addDays(StartDate, 6)), so the
# sentence "This week has not ended yet" appeared on Sunday and on future weeks
# and was silent Monday through Saturday — the six days consultants actually
# submit. It now reads addDays($Timesheet/StartDate, 6) >= [%BeginOfCurrentDay%].
# Fixed 2026-08-31 under TT-710.
#
# THIS TEST INSISTS ON THE CURRENT WEEK. A future week warned under the old
# expression too, so a test that took whatever fresh week it was handed would
# have passed before the fix and proved nothing. It navigates to the week
# containing today and fails rather than quietly settling for another one.
#
# The full date matrix — final Saturday still warns, a week that ended yesterday
# does not, a future week still does — is asserted in the unit tests
# (Core.UT_SUB_TimesheetWarningText_*, "995. Unit Tests/Timesheet"), which are
# deterministic and cost no fixture week. What can ONLY be proved here is that
# the sentence survives the chain and reaches the consultant's screen:
# ACT_Timesheet_Submit_Start, then SUB_Timesheet_Warnings building the
# TimesheetWarning rows and writing TimesheetHelper/WarningMessage, then the
# Consultant_OverFortyHours popup rendering them in its lstWarnings list view.
#
# ONE POPUP, NOT TWO. The "Are you Sure?" step (Main.Confirmation_timesheet) was
# folded into the same page: btnSubmit now calls Main.ACT_Timesheet_Submit_Start,
# which evaluates the warnings FIRST and opens a single popup — the warning list
# plus "Submit Anyway" when something fired, or a plain "Submit Timesheet?"
# confirm when nothing did. Case A below asserts that merge directly, because a
# regression to the two-popup chain would otherwise still satisfy A's text check.
#
# WHAT IT ASSERTS
#   A. Submitting the current week raises the warning popup FIRST — no "Are you
#      Sure?" step — and the popup TEXT contains "This week has not ended yet".
#   A2. The warning renders as a real list row (lstWarnings / .tt-warning-item),
#      not as a run-on paragraph, and a lone warning carries no "1." number.
#   B. Submit Anyway on that popup still submits the week — the warning is a
#      confirm, not a block.
#
# It asserts on dialog TEXT, not on a widget name: Consultant_OverFortyHours is
# one parameterised page that carries all the warnings, so its presence alone
# says nothing about WHICH warning fired. Under-40 would open the same popup.
#
# Uses e2e_consultant2 / E2E Sandbox, matching the other consultant steps.
# Consumes the current week.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"

CUSER="${TT_CURWEEK_USER:-e2e_consultant2}"
PROJECT="${TT_CURWEEK_PROJECT:-E2E Sandbox}"
WARNING='This week has not ended yet'

note() { echo "  $*"; }

# ---------------------------------------------------------------------- helpers

# cw_dialog_text — text of the LAST VISIBLE dialog, flattened.
#
# Last VISIBLE, not document.querySelector: Mendix leaves closed dialogs in the
# DOM, and reading the first match can return the corpse of an earlier popup
# instead of the live one. tt_clear_dialogs learned this the hard way — see
# lib/_login.sh.
#
# USE _tt_dialog_js, DO NOT REIMPLEMENT THE LOOKUP. This used to run its own
# querySelectorAll over the OUTER dialog wrappers —
#
#     '.mx-window, .mx-dialog, [role=dialog], .modal-dialog'
#         .filter(e => e.offsetParent !== null)
#
# — and that filter can never be true for this popup. Mendix styles the wrapper
# `position: fixed`, and offsetParent is null for ANY fixed element by
# specification, however plainly visible it is. Measured against dev on
# 2026-09-01 the live warning read position:fixed, display:block,
# visibility:visible, opacity:1, 600x284px, one client rect — and offsetParent
# null. So the one real dialog was filtered out, cw_dialog_text returned '', and
# the step failed blaming the first clause of Main.SUB_Timesheet_BuildWarningObjects
# for a microflow that was working correctly the whole time.
#
# _tt_dialog_js selects the INNER content nodes instead (.mx-window-content,
# .mx-dialog-content, .modal-content, [role=dialog]), which are not fixed, so
# offsetParent means what it looks like it means. That is why every other
# dismiss in this suite worked while this step alone saw nothing.
cw_dialog_text() {
  local d; d="$(_tt_dialog_js)"
  playwright-cli eval "() => { const d=$d; return d ? (d.innerText||'').replace(/\s+/g,' ').trim().slice(0,300) : ''; }" 2>/dev/null | _tt_eval_str
}

# cw_wait_dialog — echo the last visible dialog's text once it is non-empty.
cw_wait_dialog() {
  local i t=""
  for i in $(seq 1 12); do
    t="$(cw_dialog_text)"
    [ -n "$t" ] && { printf '%s' "$t"; return 0; }
    sleep 1
  done
  printf '%s' "$t"; return 1
}

# cw_warning_rows — "<rendered warning rows>|<numbered rows>" inside the popup.
#
# Asserts the STRUCTURE, not just the text. The warnings used to be concatenated
# into one string and dropped into a single Dynamic Text, so two warnings ran
# together in one paragraph. They are now Main.TimesheetWarning rows rendered one
# per list item, numbered by a CSS counter that a :only-child rule suppresses when
# there is just one. Counting ::before content is the only way to see that from
# here — the digits are generated, so they are not in innerText.
cw_warning_rows() {
  playwright-cli eval "() => { const items=[...document.querySelectorAll('.mx-name-lstWarnings .tt-warning-item')].filter(e=>e.offsetParent!==null); const numbered=items.filter(e=>{ const c=getComputedStyle(e,'::before').content; return c && c!=='none' && c!=='normal'; }); return items.length + '|' + numbered.length; }" 2>/dev/null | _tt_eval_str
}

# cw_row_ordinal — 1-based position of the EDITABLE row for PROJECT, or 0.
cw_row_ordinal() {
  playwright-cli eval "() => { const rows=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')]; for(let n=0;n<rows.length;n++){ let el=rows[n]; for(let k=0;k<10;k++){ el=el.parentElement; if(!el) break; if((el.innerText||'').indexOf('$PROJECT')>=0){ const inp=rows[n].querySelector('input'); if(inp && !inp.readOnly && !inp.disabled) return String(n+1); } } } return '0'; }" 2>/dev/null | _tt_eval_str
}

# ------------------------------------------------------------- the current week

# The week label renders its days as "Aug 30 - Sep 05", so match on the Sunday.
# %w is 0 on Sunday, which makes "-0 days" today and keeps the boundary right.
DOW="$(date +%w)"
SUNDAY="$(date -d "-${DOW} days" +'%b %d' 2>/dev/null || true)"
[ -n "$SUNDAY" ] \
  || tt_fail "could not compute this week's Sunday with date(1); without it this test cannot tell the current week from any other and would assert nothing the old code did not already satisfy"

tt_login "$CUSER" "My Timesheets"

# The timesheet page opens on today's week, so the first check usually succeeds.
# Scan outward anyway rather than trusting that: a landing-week change would
# otherwise turn this into a test of a DIFFERENT week that still passes.
on_current=""
case "$(tt_week_label)" in *"$SUNDAY"*) on_current=1 ;; esac
if [ -z "$on_current" ]; then
  for _ in $(seq 1 8); do
    playwright-cli click ".mx-name-btnWeekPrev" >/dev/null 2>&1; sleep 2
    case "$(tt_week_label)" in *"$SUNDAY"*) on_current=1; break ;; esac
  done
fi
if [ -z "$on_current" ]; then
  tt_login "$CUSER" "My Timesheets" >/dev/null 2>&1
  for _ in $(seq 1 12); do
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1; sleep 2
    case "$(tt_week_label)" in *"$SUNDAY"*) on_current=1; break ;; esac
  done
fi
[ -n "$on_current" ] \
  || tt_fail "could not reach the week containing today (looking for a label with '$SUNDAY'; ended on '$(tt_week_label)'). A future week warns under BOTH the old and the fixed expression, so asserting on any other week would prove nothing."

WEEK="$(tt_week_label)"
echo "current week: '$WEEK'"

ORD="$(cw_row_ordinal)"
[ "$ORD" != "0" ] \
  || tt_fail "no editable '$PROJECT' row on the current week '$WEEK' (week actionable: $(tt_week_actionable)). The current week has probably already been submitted by an earlier step, or 00-setup's data clear did not run — running a spec directly skips it."

# ------------------------------------------------- A. the warning, and its text
for d in Mon Tues Wed Thurs Fri; do
  tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, ${ORD})" "8"
done
tt_commit_focused
sleep 1

playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
sleep 3

SEEN="$(cw_wait_dialog)"

# The merge, asserted BEFORE the text check. The warning must be the first thing
# on screen after Submit. If the "Are you Sure?" step ever comes back, the text
# check below would still pass once something clicked through it, so a regression
# to the two-popup chain has to be caught here or not at all.
case "$SEEN" in
  *"Are you Sure"*)
    tt_fail "Submit on '$WEEK' opened the old 'Are you Sure?' popup instead of the warning. Main.ConsultantDashboard's btnSubmit should call Main.ACT_Timesheet_Submit_Start, which evaluates the warnings and opens ONE popup - it should never show Main.Confirmation_timesheet. Dialog read: \"$SEEN\"" ;;
esac

printf '%s' "$SEEN" | grep -Fq -- "$WARNING" \
  || tt_fail "submitting the CURRENT week '$WEEK' did not warn that the week has not ended. Expected the popup to contain \"$WARNING\"; it read: \"$SEEN\". This is exactly what the pre-2026-08-31 clause did - it tested \$Timesheet/StartDate, so it stayed silent every day of the week except Sunday. Check the first clause of Main.SUB_Timesheet_BuildWarningObjects."
note "A warning shown first, with no 'Are you Sure?' step: \"$SEEN\""

# ------------------------------------------- A2. one warning per row, unnumbered
ROWS="$(cw_warning_rows)"
ITEMS="${ROWS%%|*}"; NUMBERED="${ROWS#*|}"
case "$ITEMS" in
  ''|*[!0-9]*) tt_fail "could not count warning rows in the popup (read '$ROWS'). Main.Consultant_OverFortyHours should render Main.TimesheetWarning rows through its lstWarnings list view; if it went back to one concatenated Dynamic Text, several warnings run together in a single paragraph again." ;;
esac
[ "$ITEMS" -ge 1 ] \
  || tt_fail "the warning text reached the popup on '$WEEK' but no .tt-warning-item row rendered inside .mx-name-lstWarnings. The sentence is being shown as loose text rather than as a warning row, so a second warning would run on into the first."
# 40h exactly is neither over nor under 40, so the not-ended warning should be
# alone - and a lone warning must NOT be numbered.
if [ "$ITEMS" = "1" ]; then
  [ "$NUMBERED" = "0" ] \
    || tt_fail "the popup showed a single warning on '$WEEK' but numbered it. A lone warning is not a list - the 'li:only-child .tt-warning-item::before { content: none }' rule in themesource/titan_theme/web/custom.scss should suppress the number. It must match on the bare li - this Mendix version emits no .mx-listview-item class, so a rule written against that name matches nothing and every lone warning keeps its '1.'."
  note "A2 one warning row, correctly unnumbered"
else
  [ "$NUMBERED" = "$ITEMS" ] \
    || tt_fail "the popup showed $ITEMS warning rows on '$WEEK' but numbered only $NUMBERED of them. With more than one warning every row should carry its CSS counter, otherwise the reader cannot tell there is more than one."
  note "A2 $ITEMS warning rows, all numbered"
fi

# ------------------------------- A3. the confirm state is NOT showing as well
#
# Both halves of the merged popup live on the same page, switched by conditional
# visibility on $TimesheetHelper/WarningMessage. A broken condition would render
# BOTH - the warning list AND the "are you sure" confirm with its plain Submit
# button - which still passes every check above. This is the only assertion that
# would notice.
CLEAN_SHOWING="$(playwright-cli eval "() => { const vis=s=>{const e=document.querySelector(s); return !!(e && e.offsetParent!==null);}; return String(vis('.mx-name-btnConfirmSubmit') || vis('.mx-name-txtConfirmBody')); }" 2>/dev/null | _tt_eval_str)"
[ "$CLEAN_SHOWING" != "true" ] \
  || tt_fail "the warning popup on '$WEEK' ALSO rendered the no-warning confirm (btnConfirmSubmit / txtConfirmBody are visible). The two states are switched by conditional visibility on \$TimesheetHelper/WarningMessage in Main.Consultant_OverFortyHours - a warned week should show the warning list and Submit Anyway only."
note "A3 the no-warning confirm state is correctly hidden"

# ------------------------------------------------ B. Submit Anyway still submits
playwright-cli click ".mx-name-btnWarningSubmitAnyway" >/dev/null 2>&1
sleep 4
tt_clear_dialogs 6 >/dev/null 2>&1 || true

submitted=""
for _ in $(seq 1 8); do
  [ "$(cw_row_ordinal)" = "0" ] && { submitted=1; break; }
  sleep 3
done
[ -n "$submitted" ] \
  || tt_fail "Submit Anyway on the not-ended warning left '$PROJECT' still editable on '$WEEK', so the week was never submitted. The warning is a confirm, not a block — Main.ACT_Timesheet_SubmitAnyway should close the popup and run ACT_Timesheet_Submit."
note "B Submit Anyway submitted the current week"

echo "PASS: verify-current-week-warning — the current week warns that it has not ended, and Submit Anyway still submits ($WEEK)"
