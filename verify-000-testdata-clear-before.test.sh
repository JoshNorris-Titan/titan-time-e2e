#!/usr/bin/env bash
# Suite bookend: reset e2e test data BEFORE the rest of the suite runs.
#
# `mxcli playwright verify tests/` runs scripts in lexical filename order, so
# "verify-000-…" sorts ahead of every other verify-*.test.sh. This is the suite's
# setup step; verify-zzz-testdata-clear-after.test.sh is the teardown.
#
# Clears each e2e consultant's timesheets, entries, line items, attachments,
# expense reports, PDFs, approval workflows, change logs and approval emails via
# the per-consultant control on Core.TestData_Admin. Projects, assignments,
# customers and accounts survive, and no non-e2e consultant is touched.
#
# Why both ends: clearing first means every downstream test starts from a known
# empty state instead of inheriting rows from a previous run; clearing again at
# the end means a run does not leave its own submissions behind for the next one.
#
# Env: TT_BASE_URL, TT_ADMIN_USER, TT_ADMIN_PASS, TT_E2E_CONSULTANTS
#      (see tests/lib/_testdata.sh)
set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"
source "$(dirname "$0")/lib/_testdata.sh"

tt_clear_e2e_testdata "before"

echo "PASS: verify-000-testdata-clear-before — e2e consultant test data cleared ($TT_E2E_CONSULTANTS)"
