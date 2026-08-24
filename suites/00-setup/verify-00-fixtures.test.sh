#!/usr/bin/env bash
# Suite preflight: make sure the STRUCTURAL fixtures exist before anything runs.
#
# Sorts ahead of verify-000-testdata-clear-before (LC_ALL=C: '-' < '0'), so the
# order is: ensure structure -> clear transactional data -> run the tests. That
# matters, because the clear step deliberately preserves projects, assignments,
# customers and accounts; it only wipes timesheet data. Nothing else in the suite
# ever creates the structure.
#
# This exists because the first cloud CI run failed with
#     "no assignment for project 'E2E Dual Approval' is visible to e2e_consultant"
# which reads like a product bug and was in fact one missing project row on dev.
# A preflight that names the missing fixture turns an hour of debugging into a line
# of output.
#
# Verifies + CREATES: projects (with their approval flags) and consultant->project
# assignments. The assignment half matters most: a project with no assignment is
# invisible to the consultant, which is exactly how verify-tt647-a5 failed.
# Verifies + REPORTS: consultants/accounts — creating a login is a deliberate act,
# not a test side effect, so a missing one fails loudly with its name.
#
# Env:
#   TT_BASE_URL              REQUIRED — this writes data
#   TT_ROLE_PASS             e2e_* account password
#   TT_FIXTURES_READONLY=1   report what is missing, create nothing
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"

# Exercising the Titan Manager UI here is setup, not a login test, so the cached
# session is fine and desirable.
if fx_ensure_all; then
  echo "PASS: verify-00-fixtures — structural fixtures present on $TT_BASE ($FX_PRESENT present, $FX_CREATED created)"
else
  tt_fail "structural fixtures are missing and could not be created automatically (listed above). Create them, then re-run."
fi
