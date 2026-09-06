#!/usr/bin/env bash
# Suite bookend: reset e2e test data BEFORE the rest of the suite runs.
#
# The runner sorts by full path, so "verify-000-…" is the first step in
# suites/00-setup and therefore the first step of the whole run;
# verify-zzz-testdata-clear-after.test.sh is the teardown.
#
# THIS IS NOW THE FIRST STEP, NOT THE SECOND. Until 2026-09-06 the fixture
# preflight ran ahead of this one, because the clear preserved structure and the
# fixtures had to exist before it. The clear now removes structure too, so that
# order is inverted:
#
#   verify-000-testdata-clear-before   <- this step: delete everything
#   verify-001-fixtures                   rebuild projects + assignments
#   verify-002-seed-isolation-control     seed the transactional control rows
#
# Clears each e2e consultant's timesheets, entries, line items, attachments,
# expense reports, PDFs, approval workflows, change logs and approval emails,
# AND their assignments plus the projects those assignments were on, via the
# per-consultant "Clear data + structure" control on Core.TestData_Admin.
# Customers and accounts survive, and no non-e2e consultant is cleared directly
# — though note that deleting a project does cascade into any other consultant's
# assignments on it (see lib/_testdata.sh for why that is accepted).
#
# Why both ends: clearing first means every downstream test starts from a known
# empty state instead of inheriting rows from a previous run; clearing again at
# the end means a run does not leave its own submissions behind for the next one.
#
# Env: TT_BASE_URL, TT_ADMIN_USER, TT_ADMIN_PASS, TT_E2E_CONSULTANTS,
#      TT_E2E_CLEAR_DEPTH (see tests/lib/_testdata.sh)
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_testdata.sh"

tt_clear_e2e_testdata "before"

echo "PASS: verify-000-testdata-clear-before — e2e consultant test data cleared, depth=$TT_E2E_CLEAR_DEPTH ($TT_E2E_CONSULTANTS)"
