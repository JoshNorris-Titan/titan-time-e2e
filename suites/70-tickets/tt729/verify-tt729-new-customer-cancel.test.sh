#!/usr/bin/env bash
# TT-729 — cancelling the New Customer popup must leave NO customer behind.
#
# WHY THIS IS A SEPARATE TEST. btnNewCustomerCancel is a CancelChangesClientAction with
# closePage, so Mendix rolls back the uncommitted Main.Customer that
# Main.ACT_Assignment_NewCustomer created a moment earlier. That rollback is the whole
# behaviour: swap the action for a plain Close-page and the popup still shuts, the user
# still sees nothing odd, and a half-named customer is quietly committed to the list.
# The save-path test cannot notice that — only a negative assertion can.
#
# WHY A TIMESTAMPED NAME. The assertion is "this name does not exist anywhere". A fixed
# name would be satisfied by luck the first time and then poisoned forever by any earlier
# run that leaked one. A name minted from this run's epoch has never existed before, so
# if the search finds it, this run created it — which is exactly the bug.
#
# Nothing here is ever committed if the rollback works, so there is nothing to clean up.
# If the rollback is broken the test fails AND names the row it leaked, which is the
# right outcome: a silent cleanup would hide the defect it just found.
#
# Env: TT_BASE_URL, TT_ROLE_PASS.
set -euo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"

COMPANY="E2E TT729 Cancel $(date +%s)"

tt729_close_modals() {
  playwright-cli eval "() => { const b=[...document.querySelectorAll('.modal-content button, .modal-header button')].filter(x=>x.offsetParent!==null); if(b.length) b[0].click(); }" >/dev/null 2>&1
  sleep 2
}

tt_login "e2e_tm" "Add Customer"

# ---------------------------------------------- open the New Customer popup and type
playwright-cli click ".mx-name-btnAddAssignment" >/dev/null 2>&1
sleep 3
tt_wait_for ".mx-name-cbCustomer" "TT-729 New Assignment popup"

playwright-cli click ".mx-name-btnNewCustomer" >/dev/null 2>&1
sleep 3
tt_wait_for ".mx-name-txtCompanyName input" "TT-729 New Customer popup"

# Fill AND commit. An uncommitted field would never have reached the object in the first
# place, so cancelling it would prove nothing — the value has to be on the object for the
# rollback to be the thing under test.
tt_fill ".mx-name-txtCompanyName input" "$COMPANY"

typed="$(playwright-cli eval "() => { const e=document.querySelector('.mx-name-txtCompanyName input'); return e ? (e.value||'') : 'NOWIDGET'; }" 2>/dev/null | _tt_eval_str)"
[ "$typed" = "$COMPANY" ] || tt_fail "TT-729: the company name did not take — txtCompanyName reads '$typed', expected '$COMPANY'"

# --------------------------------------------------------------------------- cancel
playwright-cli click ".mx-name-btnNewCustomerCancel" >/dev/null 2>&1
sleep 4

gone="$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-txtCompanyName'))" 2>/dev/null | _tt_eval_str)"
[ "$gone" = "false" ] || tt_fail "TT-729: the New Customer popup is still open after Cancel"
echo "  ok: Cancel closed the New Customer popup"

# Abandon the assignment too, so the dashboard is as we found it.
playwright-cli click ".mx-name-btnCancel" >/dev/null 2>&1
sleep 3
tt729_close_modals

# ------------------------------------------------------------- THE assertion: no row
#
# Searched through the Customers card rather than the client API on purpose: this is the
# surface a person would look at, and it proves the row is absent from the same query the
# app itself uses ([Archived = false()] included).
fx_view "cardCustomers" "galCustomers" >/dev/null
listed="$(fx_search "txtCustomerSearch" "galCustomers" "$COMPANY")"
case "$listed" in
  *"$COMPANY"*)
    tt_fail "TT-729: cancelling the New Customer popup still left '$COMPANY' in the Customers list — btnNewCustomerCancel is no longer rolling back the uncommitted customer. Remove that row by hand." ;;
esac
echo "  ok: no customer was created by the cancelled popup"

echo "PASS: verify-tt729-new-customer-cancel (TT-729) — cancelling the New Customer popup rolls the customer back and commits nothing"
