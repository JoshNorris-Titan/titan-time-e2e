#!/usr/bin/env bash
# Assigning a consultant to a project they are already on is refused.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS, AND WHO ASKED FOR IT. verify-tt732-edit-saves.test.sh names
# this file as its missing half: it proves the edit path SAVES, and says in its
# own header that the negative half - Main.SUB_AssignmentValidation's duplicate
# check - is not covered anywhere. Until now a change that deleted that validation
# outright passed the entire suite.
#
# The validation refuses with "Consultant is already assigned to this project."
#
# THIS NEEDS NO NEW FIXTURE. The obvious way to test a duplicate is to seed two
# consultants on one project, which is a change to FX_ASSIGNMENTS. It is also
# unnecessary: FX_ASSIGNMENTS already puts E2E Consultant on E2E Manager Approval,
# so asking for that same pairing a second time is a duplicate by construction,
# and it is exactly the mistake a real user makes.
#
# WHAT IT ASSERTS
#   A. the pairing really does already exist - read first, and fatal if not,
#      because attempting a "duplicate" that is not one would pass for the wrong
#      reason;
#   B. the form refuses the save and the message names the duplicate rule, not
#      just any validation - a required-field complaint would otherwise satisfy a
#      looser assertion;
#   C. no second assignment was created, counted through the data layer. B reads
#      the screen; only C proves nothing was written.
#
# C matters because this form has a documented habit of looking like it refused
# while committing anyway - fx_create_assignment carries a comment about exactly
# that, and refuses to press Save when a validation message is already showing.
#
# Consumes: opens the assignment form and cancels. Creates nothing when the guard
# works. When the guard is broken it creates one duplicate assignment, which it
# reports loudly and which the bookend clear removes.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/lib/_authz.sh"

CONSULTANT="${TT_DUP_CONSULTANT:-E2E Consultant}"
PROJECT="${TT_DUP_PROJECT:-E2E Manager Approval}"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

DUP_XP="//Main.Assignment[ConsultantName = '$CONSULTANT'][Main.Assignment_Project/Main.Project/Name = '$PROJECT']"

validations() {
  playwright-cli eval "() => [...document.querySelectorAll('.mx-validation-message')].filter(e=>e.offsetParent!==null).map(e=>(e.innerText||'').trim()).filter(Boolean).join(' ~ ')" 2>/dev/null | _tt_eval_str
}
dialog_text() {
  playwright-cli eval "() => { const d=$(_tt_dialog_js); return d ? (d.innerText||'').replace(/\\s+/g,' ').slice(0,300) : ''; }" 2>/dev/null | _tt_eval_str
}

# --------------------------------------------------------- A. the pairing exists already
tt_login "e2e_tm" "Add Customer"
BEFORE="$(tt_authz_count "$DUP_XP")"
case "$BEFORE" in
  ERR:*|''|*[!0-9]*) tt_fail "could not count existing '$CONSULTANT' -> '$PROJECT' assignments (read: [$BEFORE])" ;;
  0) tt_fail "'$CONSULTANT' is not assigned to '$PROJECT', so asking for it again would not be a duplicate and this test would pass for the wrong reason. FX_ASSIGNMENTS should have created it; check 00-setup." ;;
esac
note "A ok: '$CONSULTANT' -> '$PROJECT' already exists ($BEFORE assignment(s))"

# ------------------------------------------------------------ B. ask for it again
CUSTOMER="$(fx_project_customer "$PROJECT")"
case "$CUSTOMER" in
  NOPROJECT|NOCUSTOMER|NOSTATUS|ARCHIVED:*|"")
    tt_fail "could not resolve the customer for '$PROJECT' (got '$CUSTOMER'), so the assignment form cannot be driven" ;;
esac
note "project '$PROJECT' belongs to customer '$CUSTOMER'"

# Straight to the form, the way fx_create_assignment reaches it - there is no
# cardAssignments/galAssignments pair on this dashboard, and inventing one here
# would have failed in a way that read like the guard was missing.
playwright-cli click ".mx-name-btnAddAssignment" >/dev/null 2>&1
sleep 3

tt_combobox_select_text ".mx-name-cbCustomer" "$CUSTOMER"      || bad "B: customer '$CUSTOMER' not selectable on the assignment form"
tt_combobox_select_text ".mx-name-cbProject" "$PROJECT"        || bad "B: project '$PROJECT' not selectable under '$CUSTOMER'"
tt_combobox_select_text ".mx-name-cbConsultant" "$CONSULTANT"  || bad "B: consultant '$CONSULTANT' not selectable"

tt_fill ".mx-name-txtWeeklyHours input"      "40"
tt_fill ".mx-name-txtTotalBudgetHours input" "$FX_BUDGET_HOURS"
fx_fill_date ".mx-name-dpStartDate input" "$FX_START_DATE"
fx_fill_date ".mx-name-dpEndDate input"   "$FX_END_DATE"

playwright-cli click ".mx-name-btnSave" >/dev/null 2>&1
sleep 4

COMPLAINT="$(validations)"
[ -n "$COMPLAINT" ] || COMPLAINT="$(dialog_text)"

case "$COMPLAINT" in
  *"already assigned"*)
    note "B ok: refused with: $COMPLAINT" ;;
  "")
    bad "B: the duplicate save drew no complaint at all" ;;
  *)
    bad "B: something objected, but not with the duplicate-assignment message - a required-field complaint would read like this and would not prove the guard fired. Got: $COMPLAINT" ;;
esac

# --------------------------------------------------------------- C. nothing was written
playwright-cli click ".mx-name-btnCancel" >/dev/null 2>&1
sleep 2
fx_close_modals >/dev/null 2>&1 || note "note: the assignment form did not close cleanly"

AFTER="$(tt_authz_count "$DUP_XP")"
case "$AFTER" in
  ERR:*|''|*[!0-9]*) bad "C: could not re-count assignments (read: [$AFTER])" ;;
  "$BEFORE")         note "C ok: still $AFTER assignment(s) for that pairing" ;;
  *)                 bad "C: the pairing went from $BEFORE to $AFTER assignment(s) - a duplicate was committed despite the form's complaint" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-tt732-guard-still-fires — $fails problem(s) with the duplicate-assignment guard."
  exit 1
fi
echo "PASS: verify-tt732-guard-still-fires — a duplicate '$CONSULTANT' -> '$PROJECT' was refused and nothing was written."
