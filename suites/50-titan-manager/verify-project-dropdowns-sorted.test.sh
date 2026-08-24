#!/usr/bin/env bash
# Regression test for TT-660 — New Project popup dropdowns not sorting.
#
# Opens the "New Project" popup (from the Titan Manager dashboard) and asserts the
# Customer and Project Manager dropdowns render their options in ascending order.
# Read-only: opens the form, checks dropdowns, does not save.
#
# Requires the widget-naming pass deployed to dev (btnAddProject, cbCustomer,
# cbProjectManager, txtProjectName). Env: TT_BASE_URL, TT_ROLE_PASS.
set -euo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

tt_login "e2e_tm" "Add Customer"

playwright-cli click ".mx-name-btnAddProject" >/dev/null 2>&1

# Wait for the New Project popup to render.
ok=""
for _ in $(seq 1 15); do
  if playwright-cli eval "() => String(!!document.querySelector('.mx-name-cbCustomer'))" 2>/dev/null | grep -qiw true; then
    ok=1; break
  fi
  sleep 1
done
[ -n "$ok" ] || tt_fail "New Project popup did not open (cbCustomer not found)"

tt_combobox_sorted ".mx-name-cbCustomer"       ".mx-name-txtProjectName" "TT-660 Customer dropdown"
tt_combobox_sorted ".mx-name-cbProjectManager" ".mx-name-txtProjectName" "TT-660 Project Manager dropdown"

echo "PASS: verify-project-dropdowns-sorted (TT-660) — Customer & Project Manager dropdowns sorted ascending"
