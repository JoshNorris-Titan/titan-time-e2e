#!/usr/bin/env bash
# Manual environment, step 2 of 3: build the Manual projects and assignments.
#
# tt-timeout: 25m
#
# WHAT IT DOES
# ------------
# Reuses lib/_fixtures.sh unchanged and simply points it at the Manual tables:
# manual_apply_fixture_overrides swaps FX_PROJECTS / FX_CONSULTANTS / FX_ASSIGNMENTS /
# FX_ENTRIES and the manager, customer and approver knobs, then fx_ensure_all does the
# same work it does for the E2E set — verify what is there, create what is not, and
# reconcile the CONFIGURATION of what now exists against the table.
#
# Sharing the builder rather than copying it is the point. Those 800 lines encode a long
# list of things that are true only of this app: the assignment form's customer-gates-
# project ordering, the date picker that ignores a DOM write and needs real keystrokes,
# the MM/dd/yyyy format TT-721 introduced, the popup that must be proven shut before the
# next card click lands. A second copy would start correct and drift the first time one
# of those changes.
#
# WHY THE OVERRIDE HAPPENS AFTER THE SOURCE, NOT BEFORE
# -----------------------------------------------------
# lib/_fixtures.sh assigns FX_PROJECTS and friends unconditionally when it is sourced, so
# an override written first is silently overwritten and this step would build the E2E set
# while reporting Manual names nowhere. manual_apply_fixture_overrides refuses to run
# before _fixtures.sh has been sourced for exactly that reason.
#
# BUDGET. The E2E equivalent (suites/00-setup/verify-001-fixtures) is measured at 638-828s
# for the same 5 projects and 5 assignments, and declares 20m. This declares 25m because a
# FIRST Manual run also pays a cold Mendix Cloud start with nothing cached. A re-run finds
# everything present and finishes in a couple of minutes — if a re-run ever approaches the
# budget, something is retrying, not working harder.
#
# IDEMPOTENT. Re-running this against an already-built Manual environment creates nothing
# and reports "$FX_PRESENT present, 0 created". It is safe to kick off the build workflow
# again after a partial failure.
#
# NOT SEEDED HERE: transactional rows. verify-120 runs the regression-ladder seeder, which
# produces real timesheets across every status — far more than fx_ensure_entries' single
# control row. FX_ENTRIES is still overridden by manual_apply_fixture_overrides so that no
# FX_* array is left pointing at E2E data, but fx_ensure_entries is deliberately not called.
#
# Env:
#   TT_BASE_URL              REQUIRED — this writes data
#   TT_MANUAL_PASS           manual_* password, defaults to TT_ROLE_PASS
#   TT_FIXTURES_READONLY=1   report what is missing, create nothing
#   TT_FIXTURES_ALLOW_DRIFT=1  report configuration drift without failing
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test works
# at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/manual-env/manual.env.sh"

manual_apply_fixture_overrides

manual_log "building the Manual data set on $TT_BASE as '$FX_TM_USER'"
manual_log "customer='$FX_CUSTOMER' manager='$FX_PROJECT_MANAGER' window=$FX_START_DATE..$FX_END_DATE"

if fx_ensure_all; then
  echo "PASS: verify-110-manual-structure — Manual projects and assignments present on $TT_BASE ($FX_PRESENT present, $FX_CREATED created)"
else
  tt_fail "the Manual structural fixtures are missing or drifted (listed above) and could not be created automatically. Fix what is named, then re-run the build."
fi
