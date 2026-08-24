#!/usr/bin/env bash
# Tier 0 smoke test — each role lands on its own dashboard.
#
# Logs in (forms login, /login.html) as each of the four E2E role accounts and
# asserts the role-specific landing dashboard. Cookies are cleared between roles
# so each login is clean regardless of order. Portable across environments via
# env vars (localhost defaults for a local run).
#
# Environment:
#   TT_BASE_URL   app origin (no trailing slash)
#   TT_ROLE_PASS  shared password for the e2e_* role accounts (default E2ETest123!)
#
# Requires the four seeded role accounts to exist and log in WITHOUT a forced
# password reset: e2e_consultant / e2e_pm / e2e_hr / e2e_tm.
set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"

# login_role <username> <expected-text-on-dashboard> <label>
# Delegates to the shared tt_login, which handles both the legacy /login.html
# form and the current custom Core.Login page, and logs out any prior session.
login_role() {
  local user="$1" expect="$2" label="$3"
  tt_login "$user" "$expect"
  echo "  PASS: $label ($user) -> dashboard shows '$expect'"
}

login_role "e2e_consultant" "My Timesheets"             "Consultant"
login_role "e2e_pm"         "Project Manager Dashboard" "ProjectManager"
login_role "e2e_hr"         "WEEKLY TO PROCESS"         "HR"
login_role "e2e_tm"         "Add Customer"              "TitanManager"

echo "PASS: verify-role-dashboards — all four roles landed on their dashboards"
