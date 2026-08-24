#!/usr/bin/env bash
# Tier 0/1 smoke — the consultant's weekly timesheet grid renders.
#
# Logs in as the Consultant role and asserts the timesheet week view shows its
# core columns (Project, Client, the Sun..Sat day columns, Total). Confirms the
# consultant's primary screen loads. Text assertions only (no widget names).
#
# Env: TT_BASE_URL, TT_ROLE_PASS (see tests/lib/_login.sh)
set -euo pipefail
source "$(dirname "$0")/lib/_login.sh"

tt_login "e2e_consultant" "My Timesheets"
tt_assert_all "Consultant timesheet grid" "Project" "Client" "Sun" "Sat" "Total"

echo "PASS: verify-consultant-timesheet — consultant weekly timesheet grid renders"
