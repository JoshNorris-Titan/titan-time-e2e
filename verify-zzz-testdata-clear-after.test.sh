#!/usr/bin/env bash
# Suite bookend: reset e2e test data AFTER the rest of the suite has run.
#
# Lexical filename order puts "verify-zzz-…" last, so this is the teardown to
# verify-000-testdata-clear-before.test.sh. It removes the timesheets and
# approval workflows the suite just created, so a run leaves the environment as
# it found it and the next run is not skewed by this one's data.
#
# Deliberately identical in behaviour to the "before" bookend — same helper, same
# scope, same failure modes. If teardown fails the run is marked failed: silently
# leaving data behind is what makes the *next* run's failures hard to read.
#
# Env: TT_BASE_URL, TT_ADMIN_USER, TT_ADMIN_PASS, TT_E2E_CONSULTANTS
#      (see tests/lib/_testdata.sh)
set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"
source "$(dirname "$0")/lib/_testdata.sh"

tt_clear_e2e_testdata "after"

echo "PASS: verify-zzz-testdata-clear-after — e2e consultant test data cleared ($TT_E2E_CONSULTANTS)"
