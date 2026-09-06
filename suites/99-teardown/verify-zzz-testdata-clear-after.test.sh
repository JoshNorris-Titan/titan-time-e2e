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
# WHAT "AS IT FOUND IT" MEANS SINCE 2026-09-06. Both bookends now run the DEEP
# clear, so this one also deletes the E2E projects and assignments that
# verify-001-fixtures built at the start of the run. A finished run therefore
# leaves the environment with NO E2E structure at all, not with the structure it
# started with. That is intended — the next run rebuilds it in 001 — but it means
# the environment between runs is emptier than it used to be, and anyone opening
# dev by hand after a nightly will find no E2E projects until the next run or a
# manual `./run-tests.sh suites/00-setup`.
#
# Env: TT_BASE_URL, TT_ADMIN_USER, TT_ADMIN_PASS, TT_E2E_CONSULTANTS,
#      TT_E2E_CLEAR_DEPTH (see tests/lib/_testdata.sh)
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_testdata.sh"

tt_clear_e2e_testdata "after"

echo "PASS: verify-zzz-testdata-clear-after — e2e consultant test data cleared, depth=$TT_E2E_CLEAR_DEPTH ($TT_E2E_CONSULTANTS)"
