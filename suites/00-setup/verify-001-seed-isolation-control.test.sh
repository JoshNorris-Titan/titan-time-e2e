#!/usr/bin/env bash
# verify-001-seed-isolation-control.test.sh
#
# Seed the transactional data that verify-consultant-data-isolation needs as its
# CONTROL, after the clear has removed it.
#
# WHY THIS IS ITS OWN STEP RATHER THAN PART OF verify-00-fixtures
# ---------------------------------------------------------------
# Run order under the runner's `LC_ALL=C sort` ('-' 0x2D precedes '0' 0x30):
#
#     verify-00-fixtures                 structure: projects, consultants, assignments
#     verify-000-testdata-clear-before   deletes every timesheet row for TT_E2E_CONSULTANTS
#     verify-001-seed-isolation-control  <- this step
#
# The clear deliberately preserves structure, so fixtures can and should run
# ahead of it. AssignmentEntries are exactly what it deletes, so anything
# transactional has to come after. Adding this to fx_ensure_all would seed rows
# the very next step throws away — which is the failure this is fixing, not a
# theoretical one.
#
# WHAT WAS BROKEN
# ---------------
# verify-consultant-data-isolation proves, as administrator, that another
# consultant HAS entries before asking whether our consultant can read them. It
# aborts when that control finds nothing, because a zero against an empty
# database would be a test that passes hardest when there is no data:
#
#   FAIL: no other consultant has entries the administrator can see
#         (tried: 'E2E Consultant Two'=0 'E2E Consultant Three'=0) ...
#
# Nothing created those entries in time. The three steps that give
# 'E2E Consultant Two' timesheet rows — verify-hours-validation,
# verify-timesheet-clear, verify-timesheet-status-rollup — all sort AFTER the
# isolation test, so on a full sorted run the control could never have passed.
#
# The seeding itself lives in lib/_fixtures.sh (FX_ENTRIES / fx_ensure_entries),
# with the reasoning for walking BACKWARD rather than forward. This file is only
# the call site, placed where the run order requires.
#
# Creates timesheet rows for the consultants in FX_ENTRIES. Fills no hours and
# saves nothing: visiting a week is what makes the app create its entries.
#
# Env:
#   TT_BASE_URL              REQUIRED — this writes data
#   TT_ROLE_PASS             e2e_* account password
#   TT_FIXTURES_READONLY=1   report what is missing, seed nothing
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"

[ -n "${TT_BASE_URL:-}" ] || tt_fail "seed: TT_BASE_URL must be set explicitly — this writes data and must never fall back to a default environment"

fx_ensure_entries

if [ -n "$FX_MISSING" ]; then
  printf '  [fixtures] COULD NOT SEED:%b\n' "$FX_MISSING"
  tt_fail "the isolation control could not be seeded (listed above). verify-consultant-data-isolation will abort without it rather than report a meaningless pass."
fi

echo "PASS: verify-001-seed-isolation-control — control data present on $TT_BASE ($FX_PRESENT present, $FX_CREATED created)"
