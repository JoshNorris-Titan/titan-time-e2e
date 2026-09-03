#!/usr/bin/env bash
# Tier 0/1 smoke — the consultant's weekly timesheet grid renders.
#
# Logs in as the Consultant role and asserts the timesheet week view shows its
# core columns (Project, the Sun..Sat day columns, Total). Confirms the
# consultant's primary screen loads. Text assertions only (no widget names).
#
# "Client" WAS IN THIS LIST AND IS NOT ANY MORE. The grid's Client column header
# was dropped from Main.ConsultantDashboard on 2026-09-02; the customer name is
# still bound in the row (Project_Customer/Customer/CompanyName), only the literal
# column heading went. Keeping the needle would have been worse than a plain
# failure: several E2E fixture customers are named "E2E ClientApproval ...", so
# the assertion would pass or fail depending on which projects the signed-in
# consultant happens to be assigned to that week.
#
# Env: TT_BASE_URL, TT_ROLE_PASS (see tests/lib/_login.sh)
set -euo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

tt_login "e2e_consultant" "My Timesheets"
tt_assert_all "Consultant timesheet grid" "Project" "Sun" "Sat" "Total"

echo "PASS: verify-consultant-timesheet — consultant weekly timesheet grid renders"
