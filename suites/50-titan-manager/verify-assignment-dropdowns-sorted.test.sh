#!/usr/bin/env bash
# Regression test for TT-662 — "Add Assignment" Consultant & Project dropdowns not sorting.
#
# The Add Assignment form is cascading: Project populates after a Customer is
# chosen, and Consultant populates after a Project is chosen. This walks that
# cascade and asserts the Project and Consultant dropdowns are in ascending order.
# Read-only: fills form selections to drive the cascade but does not save.
#
# Requires the widget-naming pass deployed (btnAddAssignment, cbCustomer, cbProject,
# cbConsultant, txtWeeklyHours). Env: TT_BASE_URL, TT_ROLE_PASS.
#
# ALL THREE DROPDOWNS ARE ASSERTED, AND THAT IS A CHANGE. TT-662 covered
# Consultant + Project only, and this file used to carry a note saying the
# Customer dropdown on this form was separately unsorted on dev, "flagged, out of
# scope here". That note is stale: TT-694 - "Add Assignment: Customer dropdown is
# not sorted (inconsistent with New Project)" - closed on 2026-08-18 and fixed
# exactly that, with no test written for it. Customer is asserted first now,
# before the cascade consumes it.
#
# So a failure on the Customer half means TT-694 has regressed, and a failure on
# either of the other two means TT-662 has. They are different tickets against the
# same form and the messages below say which.
set -euo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

tt_login "e2e_tm" "Add Customer"

playwright-cli click ".mx-name-btnAddAssignment" >/dev/null 2>&1

# Wait for the Add Assignment popup.
ok=""
for _ in $(seq 1 15); do
  if playwright-cli eval "() => String(!!document.querySelector('.mx-name-cbCustomer'))" 2>/dev/null | grep -qiw true; then
    ok=1; break
  fi
  sleep 1
done
[ -n "$ok" ] || tt_fail "Add Assignment popup did not open (cbCustomer not found)"

# TT-694: the Customer dropdown itself. Asserted BEFORE anything is selected -
# choosing a customer closes this list and moves the cascade on, so there is no
# second chance at it later in the form.
tt_combobox_sorted ".mx-name-cbCustomer" ".mx-name-txtWeeklyHours" "TT-694 Customer dropdown"

# Pick a customer -> populates the Project dropdown, then assert Project is sorted.
tt_combobox_select_first ".mx-name-cbCustomer"
tt_combobox_sorted ".mx-name-cbProject" ".mx-name-txtWeeklyHours" "TT-662 Project dropdown"

# Pick a project -> populates the Consultant dropdown, then assert Consultant is sorted.
tt_combobox_select_first ".mx-name-cbProject"
tt_combobox_sorted ".mx-name-cbConsultant" ".mx-name-txtWeeklyHours" "TT-662 Consultant dropdown"

echo "PASS: verify-assignment-dropdowns-sorted — Customer (TT-694), Project and Consultant (TT-662) dropdowns all sorted ascending"
