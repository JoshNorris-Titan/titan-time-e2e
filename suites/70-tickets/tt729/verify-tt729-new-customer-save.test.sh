#!/usr/bin/env bash
# TT-729 — creating a customer from inside the New Assignment popup, and having it
# land back on the assignment's Customer picker.
#
# WHAT SHIPPED. Main.Assignment_NewEdit gained a "New Customer" button (btnNewCustomer)
# beside cbCustomer. It calls Main.ACT_Assignment_NewCustomer, which creates a
# Main.Customer and opens Main.Assignment_NewCustomer as a popup (txtCompanyName, with
# btnNewCustomerCancel / btnNewCustomerSave in the footer). Save runs
# Main.ACT_Assignment_SaveNewCustomer: commit the customer, point the in-edit
# Assignment at it, clear Assignment_Project, close.
#
# WHY THIS EXISTS. The ticket's own closing note says the button had never been
# exercised in a browser. Every claim below is therefore a first check, not a
# regression guard on something already proven.
#
# WHAT EACH ASSERTION PINS
#   1. btnNewCustomer opens the popup while the assignment form is still EMPTY. That
#      only works because the button carries formValidations "None"; with "All" the
#      empty required fields behind it would block the navigation and the popup would
#      never appear. So this doubles as the check on that setting.
#   2. cbCustomer shows the new company afterwards — pins the Change activity that sets
#      Assignment_Customer. Read as the picker's own text, not merely "non-empty", so an
#      unset dropdown cannot pass it.
#   3. The customer is listed on the TM dashboard Customers card — pins the Commit. A
#      client-side echo would satisfy assertion 2 but not this one.
#
# CLEANUP. Main.Customer has an Archived flag (cbCustomer's own constraint is
# [Archived = false()]) but no delete or archive control on any TM popup, and the
# 00-setup/99-teardown bookends only reset consultant timesheet data — they never touch
# Main.Customer. So this test archives the row it made through the client API at the end.
# The company name carries the run's epoch, so a failed cleanup leaves one identifiable
# row rather than colliding with the next run.
#
# tt-timeout: 6m
# Env: TT_BASE_URL, TT_ROLE_PASS.
set -euo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"

COMPANY="E2E TT729 $(date +%s)"

tt729_close_modals() {
  playwright-cli eval "() => { const b=[...document.querySelectorAll('.modal-content button, .modal-header button')].filter(x=>x.offsetParent!==null); if(b.length) b[0].click(); }" >/dev/null 2>&1
  sleep 2
}

# tt729_archive_customer <name> — best-effort cleanup through the client API.
# Never fatal: a leaked row is worth reporting, not worth failing a green test over.
tt729_archive_customer() {
  local name="$1" r
  r="$(playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"//Main.Customer[CompanyName='$name']\", filter:{amount:5}, callback: function(objs){ if(!objs || !objs.length){ clearTimeout(t); return res('ERR:not-found'); } objs[0].set('Archived', true); mx.data.commit({ mxobj: objs[0], callback: function(){ clearTimeout(t); res('ok'); }, error: function(e){ clearTimeout(t); res('ERR:commit-'+((e&&e.message)||'refused')); } }); }, error: function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'retrieve-refused')); } }); } catch(e) { res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str)"
  if [ "$r" = "ok" ]; then
    echo "  cleanup: archived customer '$name'"
  else
    echo "  WARN: could not archive customer '$name' ($r) — it is left in the Customers list and needs removing by hand" >&2
  fi
}

tt_login "e2e_tm" "Add Customer"

# ------------------------------------------------- open a NEW assignment, untouched
playwright-cli click ".mx-name-btnAddAssignment" >/dev/null 2>&1
sleep 3
tt_wait_for ".mx-name-cbCustomer" "TT-729 New Assignment popup"

# ASSERTION 1 — the button reaches the popup from an empty form.
#
# Deliberately nothing is filled in first. If btnNewCustomer's formValidations were
# ever changed back from "None" to "All", the empty assignment form would block here and
# txtCompanyName would never render, so tt_wait_for below goes red.
present="$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnNewCustomer'))" 2>/dev/null | _tt_eval_str)"
[ "$present" = "true" ] || tt_fail "TT-729: no New Customer button (.mx-name-btnNewCustomer) beside the Customer picker on Assignment_NewEdit"

playwright-cli click ".mx-name-btnNewCustomer" >/dev/null 2>&1
sleep 3
tt_wait_for ".mx-name-txtCompanyName input" "TT-729 New Customer popup (is btnNewCustomer still formValidations=None?)"
echo "  ok: New Customer popup opened from an untouched assignment form"

# ---------------------------------------------------------------- name it and save
tt_fill ".mx-name-txtCompanyName input" "$COMPANY"
playwright-cli click ".mx-name-btnNewCustomerSave" >/dev/null 2>&1
sleep 4

gone="$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-txtCompanyName'))" 2>/dev/null | _tt_eval_str)"
[ "$gone" = "false" ] || tt_fail "TT-729: the New Customer popup is still open after Save — ACT_Assignment_SaveNewCustomer did not close it"

# ASSERTION 2 — the new customer is now selected on the assignment.
#
# Reads the picker's rendered text. Asserting merely "not empty" would pass on a
# leftover selection, so this compares against the name this run generated.
picked="$(playwright-cli eval "() => { const e=document.querySelector('.mx-name-cbCustomer'); return e ? (e.innerText||'').replace(/\\s+/g,' ').trim() : 'NOWIDGET'; }" 2>/dev/null | _tt_eval_str)"
[ "$picked" != "NOWIDGET" ] || tt_fail "TT-729: cbCustomer disappeared after saving the new customer"
case "$picked" in
  *"$COMPANY"*) : ;;
  *) tt_fail "TT-729: after saving, the assignment's Customer picker reads '$picked', expected it to contain '$COMPANY' — the Change activity that sets Assignment_Customer did not take" ;;
esac
echo "  ok: the new customer is selected on the assignment ($COMPANY)"

# Abandon the assignment itself — this test is about the customer, and leaving a
# half-built assignment behind would pollute the TM dashboard for later tests.
playwright-cli click ".mx-name-btnCancel" >/dev/null 2>&1
sleep 3
tt729_close_modals

# ASSERTION 3 — it was really committed, not just held in the client.
listed="$(fx_search "txtCustomerSearch" "galCustomers" "$COMPANY" 2>/dev/null || true)"
if [ -z "$listed" ]; then
  fx_view "cardCustomers" "galCustomers" >/dev/null
  listed="$(fx_search "txtCustomerSearch" "galCustomers" "$COMPANY")"
fi
case "$listed" in
  *"$COMPANY"*) : ;;
  *) tt729_archive_customer "$COMPANY"
     tt_fail "TT-729: '$COMPANY' is not in the TM Customers list after Save — the customer was never committed. Card text: ${listed:0:200}" ;;
esac
echo "  ok: the new customer is committed and listed on the TM dashboard"

tt729_archive_customer "$COMPANY"

echo "PASS: verify-tt729-new-customer-save (TT-729) — a customer created from the New Assignment popup commits and lands on the assignment's Customer picker"
