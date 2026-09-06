#!/usr/bin/env bash
# Suite setup: BUILD the structural fixtures the suite needs, after the clear has
# removed them.
#
# tt-timeout: 20m
#
# WHY THIS STEP NEEDS ITS OWN BUDGET. It used to find every fixture already present
# and finish in seconds, because the clear preserved structure. It now builds all of
# it through the Titan Manager UI on every run: 5 projects and 5 assignments, each a
# popup, a combobox chain, a save and a read-back that proves the row landed.
#
# Measured on cloud dev 2026-09-06, the first run after the deep clear went live:
# the default 4m budget expired while creating the FIFTH project, having taken
# roughly 50s each for the first four. Assignments are slower still - more fields,
# two date pickers whose format is load-bearing, and a consultant-popup read-back
# per row. 20m is that measurement with room for a cold Mendix Cloud start, not a
# guess.
#
# Full green runs since, same environment: 638s, then 828s once fx_close_modals
# was added. That +190s is the cost of verifying popups are shut rather than
# sleeping and hoping - fx_view is called dozens of times and each extra
# `playwright-cli eval` is ~2.6s of node startup - so it is real work, not a
# retry. Roughly 70-85s per created object is the number to sanity-check against.
#
# If this step ever runs materially longer than ~900s, look for something
# retrying before raising the budget again: at 10 objects the honest ceiling is
# well under 20m, and a step that creeps toward it is failing repeatedly and
# recovering, not working harder.
#
# Sorts immediately after verify-000-testdata-clear-before, so the order is:
# clear everything -> rebuild structure -> seed transactional rows -> run the
# tests. Nothing else in the suite ever creates the structure, so if this step is
# skipped or fails, every consultant-facing test that follows has no project row
# to work with.
#
# THE ORDER USED TO BE THE OTHER WAY ROUND. This file was verify-00-fixtures and
# ran BEFORE the clear, exploiting LC_ALL=C ('-' 0x2D < '0' 0x30). That worked
# only because the clear deliberately preserved projects and assignments. As of
# 2026-09-06 the bookends drive the deep per-consultant control, which deletes
# assignments and their projects as well, so structure created ahead of the clear
# would simply be thrown away. Renaming this to 001 is what puts it after.
#
# Creating the projects fresh on every run is the point, not a side effect: the
# fixture table below is now the single source of truth for their approval flags.
# Previously a project that already existed with drifted flags passed the name
# check silently — that is how E2E Sandbox sat with the wrong
# ApprovalFromManager for weeks (see the reconciliation note in lib/_fixtures.sh).
# A rebuilt project cannot drift.
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
  echo "PASS: verify-001-fixtures — structural fixtures present on $TT_BASE ($FX_PRESENT present, $FX_CREATED created)"
else
  tt_fail "structural fixtures are missing and could not be created automatically (listed above). Create them, then re-run."
fi
