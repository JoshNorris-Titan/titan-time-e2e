#!/usr/bin/env bash
# The assignment form moves a start date back to its Sunday and an end date forward
# to its Saturday, instead of refusing a mid-week date.
#
# tt-timeout: 10m
#
# WHAT SHIPPED (TT-789). Main.NOCH_Assignment_SnapToWeek runs as the On change of
# dpStartDate and dpEndDate on Main.Assignment_NewEdit (and on Main.Report_OnProject's
# inline edit). Timesheet weeks run Sunday to Saturday, so an assignment now always
# covers whole weeks. The form's two "start before end" checks compare the snapped
# dates, so a start and end in the same week are never refused.
#
# WHAT IT ASSERTS, on the Titan Manager's Add Assignment form
#   A. a Wednesday start (10/14/2026) reads back as that week's Sunday (10/11/2026);
#   B. a Wednesday end (12/02/2026) reads back as that week's Saturday (12/05/2026);
#   C. a date already on the right day is left alone (start Sunday 10/18/2026);
#   D. the same Saturday typed as end and then start reads back 10/11 - 10/17, with no
#      start/end complaint on the form. NOTE: D's "no complaint" half proves something
#      only if Mendix shows a widget validation on change rather than on save; the
#      read-back half holds either way;
#   E. nothing was written - the form is cancelled, and the pairing's assignment count
#      is the same before and after.
# Every date is TYPED (fx_fill_date): the picker parses keystrokes, and the On change
# runs when the field loses focus.
#
# Consumes: opens the assignment form for a pairing that already exists and cancels.
# Creates nothing.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/lib/_authz.sh"

CONSULTANT="${TT_SNAP_CONSULTANT:-E2E Consultant}"
PROJECT="${TT_SNAP_PROJECT:-E2E Manager Approval}"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

XP="//Main.Assignment[ConsultantName = '$CONSULTANT'][Main.Assignment_Project/Main.Project/Name = '$PROJECT']"

value_of() {
  playwright-cli eval "() => { const e=document.querySelector('$1'); return e ? (e.value||'') : 'NOWIDGET'; }" 2>/dev/null | _tt_eval_str
}
date_complaints() {
  playwright-cli eval "() => [...document.querySelectorAll('.mx-name-dpStartDate .mx-validation-message, .mx-name-dpEndDate .mx-validation-message')].filter(e=>e.offsetParent!==null).map(e=>(e.innerText||'').trim()).filter(Boolean).join(' ~ ')" 2>/dev/null | _tt_eval_str
}
expect_date() { # <label> <selector> <typed> <expected>
  fx_fill_date "$2" "$3"
  local got; got="$(value_of "$2")"
  if [ "$got" = "$4" ]; then note "$1 ok: typed $3, reads $got"; else bad "$1: typed $3, expected $4, reads '$got'"; fi
}

START=".mx-name-dpStartDate input"
END=".mx-name-dpEndDate input"

tt_login "e2e_tm" "Add Customer"
BEFORE="$(tt_authz_count "$XP")"
case "$BEFORE" in
  ERR:*|''|*[!0-9]*) tt_fail "could not count existing '$CONSULTANT' -> '$PROJECT' assignments (read: [$BEFORE])" ;;
esac

CUSTOMER="$(fx_project_customer "$PROJECT")"
case "$CUSTOMER" in
  NOPROJECT|NOCUSTOMER|NOSTATUS|ARCHIVED:*|"")
    tt_fail "could not resolve the customer for '$PROJECT' (got '$CUSTOMER'), so the assignment form cannot be driven" ;;
esac

# The dates are editable only once a customer and a project are picked.
playwright-cli click ".mx-name-btnAddAssignment" >/dev/null 2>&1
sleep 3
tt_combobox_select_text ".mx-name-cbCustomer" "$CUSTOMER"     || tt_fail "customer '$CUSTOMER' not selectable on the assignment form"
tt_combobox_select_text ".mx-name-cbProject" "$PROJECT"       || tt_fail "project '$PROJECT' not selectable under '$CUSTOMER'"
tt_combobox_select_text ".mx-name-cbConsultant" "$CONSULTANT" || tt_fail "consultant '$CONSULTANT' not selectable"
tt_wait_for "$START" "TT-789 assignment form date picker"

expect_date "A" "$START" "10/14/2026" "10/11/2026"
expect_date "B" "$END"   "12/02/2026" "12/05/2026"
expect_date "C" "$START" "10/18/2026" "10/18/2026"

expect_date "D (end)"   "$END"   "10/17/2026" "10/17/2026"
expect_date "D (start)" "$START" "10/17/2026" "10/11/2026"
COMPLAINT="$(date_complaints)"
[ -z "$COMPLAINT" ] && note "D ok: no start/end complaint for a same-week range" || bad "D: a same-week range drew a complaint: $COMPLAINT"

playwright-cli click ".mx-name-btnCancel" >/dev/null 2>&1
sleep 2
fx_close_modals >/dev/null 2>&1 || note "note: the assignment form did not close cleanly"

AFTER="$(tt_authz_count "$XP")"
case "$AFTER" in
  ERR:*|''|*[!0-9]*) bad "E: could not re-count assignments (read: [$AFTER])" ;;
  "$BEFORE")         note "E ok: still $AFTER assignment(s) for that pairing" ;;
  *)                 bad "E: the pairing went from $BEFORE to $AFTER assignment(s) - cancelling the form committed something" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-tt789-assignment-week-snap — $fails problem(s) with the assignment form's whole-week dates."
  exit 1
fi
echo "PASS: verify-tt789-assignment-week-snap — mid-week dates snap to Sunday / Saturday and a same-week range is accepted."
