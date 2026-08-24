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
# NOTE: TT-662 covers Consultant + Project. The Customer dropdown on this form is
# separately NOT sorted on dev (unlike the New Project popup) — flagged, out of scope here.
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

# Pick a customer -> populates the Project dropdown, then assert Project is sorted.
tt_combobox_select_first ".mx-name-cbCustomer"
tt_combobox_sorted ".mx-name-cbProject" ".mx-name-txtWeeklyHours" "TT-662 Project dropdown"

# Pick a project -> populates the Consultant dropdown, then assert Consultant is sorted.
tt_combobox_select_first ".mx-name-cbProject"
tt_combobox_sorted ".mx-name-cbConsultant" ".mx-name-txtWeeklyHours" "TT-662 Consultant dropdown"

echo "PASS: verify-assignment-dropdowns-sorted (TT-662) — Project & Consultant dropdowns sorted ascending"
