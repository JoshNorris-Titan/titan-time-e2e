#!/usr/bin/env bash
# TT-735 — HR's manual-entry consultant picker: labelled "Consultant", sorted, usable.
#
# THE BUG. Main.CreateTimesheet's picker (cbCreateForAccount) was labelled "Account",
# placeheld "Select Account", and sorted by Administration.Account.LastName DESCENDING.
# Titan never writes FirstName or LastName anywhere, so that sort key is blank on every
# row: HR got an unlabelled-looking dropdown in effectively arbitrary order.
#
# THE FIX. Label "Consultant", placeholder "Select Consultant", sorted on
# Administration.Account.FullName ASCENDING, and constrained to [Active].
#
# WHAT THIS ASSERTS
#   1. The picker renders and its own text says "Consultant", not "Account". Both the
#      label and the empty-option placeholder changed, and this reads the widget's whole
#      rendered text, so either one regressing is caught. The negative half matters as
#      much as the positive: "Account" must be GONE, or a picker still labelled the old
#      way but with a stray "Consultant" elsewhere in it would pass.
#   2. Options come back sorted ascending, via the shared tt_combobox_sorted helper —
#      the same one verify-hr-sent-consultant-sorted.test.sh uses for the Sent-tab
#      picker, which the CreateTimesheet page's own documentation names as the template
#      for this test.
#
# KNOWN LIMIT, stated rather than hidden. tt_combobox_sorted proves the rendered order is
# ascending; it cannot prove WHICH attribute produced that order. Reverting the sort to
# the blank LastName field leaves every key equal, and a stable sort over equal keys can
# still come back looking ordered on a small enough account list. The same caveat applies
# to the TT-667 test this is modelled on. It is a real check, not a complete one.
#
# NOT ASSERTED: the [Active] constraint. Proving it needs a deactivated account to exist,
# and the 00-setup fixtures do not create one — inventing a deactivated account here would
# write user data the bookend clear does not know how to undo.
#
# Read-only: opens the dropdown, dismisses it, submits nothing.
# Env: TT_BASE_URL, TT_ROLE_PASS.
set -euo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

tt_login "e2e_hr" "WEEKLY TO PROCESS"

# Main.CreateTimesheet is reachable from the navigation ("Create Timesheet"), and its
# allowedRoles are [Main.HR], so this is the account that can open it.
tt_click_text "Create Timesheet" "HR Create Timesheet nav item"
sleep 3
tt_wait_for ".mx-name-cbCreateForAccount" "TT-735 Create Timesheet consultant picker"

# ------------------------------------------------------- 1. what the picker calls itself
picker="$(playwright-cli eval "() => { const e=document.querySelector('.mx-name-cbCreateForAccount'); return e ? (e.innerText||'').replace(/\\s+/g,' ').trim() : 'NOWIDGET'; }" 2>/dev/null | _tt_eval_str)"
[ "$picker" != "NOWIDGET" ] || tt_fail "TT-735: cbCreateForAccount not found on Create Timesheet"

case "$picker" in
  *Consultant*) : ;;
  *) tt_fail "TT-735: the Create Timesheet picker does not say 'Consultant' anywhere — reads '$picker'. Label and placeholder should both have moved off 'Account'." ;;
esac

case "$picker" in
  *Account*)
    tt_fail "TT-735: the Create Timesheet picker still says 'Account' — reads '$picker'. The label/placeholder revert is exactly the regression this guards." ;;
esac
echo "  ok: picker reads '$picker' — 'Consultant', with no 'Account' left"

# --------------------------------------------------------------- 2. ordering
#
# Dismissed against the picker's own label rather than a page-level element: clicking
# somewhere arbitrary on this page could start creating a timesheet.
tt_combobox_sorted ".mx-name-cbCreateForAccount" ".mx-name-cbCreateForAccount" "TT-735 Create Timesheet consultant picker"
echo "  ok: consultant options come back sorted ascending"

echo "PASS: verify-tt735-consultant-picker (TT-735) — HR's manual-entry picker is labelled Consultant and sorted ascending"
