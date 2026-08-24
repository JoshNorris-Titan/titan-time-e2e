#!/usr/bin/env bash
# Tier 0/1 smoke — the HR dashboard renders its workflow-stage summary.
#
# Logs in as the HR role and asserts the HR dashboard shows the approval-stage
# sections (Pending / Manager approval / Client approval / Weekly to process),
# confirming the dashboard's stage aggregation loads. No stable widget names
# required (text assertions on the rendered dashboard).
#
# Env: TT_BASE_URL, TT_ROLE_PASS (see tests/lib/_login.sh)
set -euo pipefail
source "$(dirname "$0")/lib/_login.sh"

tt_login "e2e_hr" "WEEKLY TO PROCESS"
tt_assert_all "HR dashboard summary" "PENDING" "MANAGER APPROVAL" "CLIENT APPROVAL" "WEEKLY TO PROCESS"

echo "PASS: verify-hr-dashboard-summary — HR dashboard shows all workflow-stage sections"
