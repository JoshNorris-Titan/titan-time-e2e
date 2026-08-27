#!/usr/bin/env bash
# Test-data reset helpers for the Titan Time E2E suite.
# Source AFTER lib/_login.sh:
#   source "$(dirname "$0")/lib/_login.sh"
#   source "$(dirname "$0")/lib/_testdata.sh"
#
# Drives the "Clean Test Data" card on the Administrator dashboard
# (Core.TestData_Admin, Core/996. Test Utilities).
#
# Uses the PER-CONSULTANT clear (btnClearConsultantTestData), NOT the
# "Clear out all data" button. That matters on a shared dev environment: the
# per-consultant flow deletes only the named consultant's timesheets, entries,
# line items, attachments, expense reports, PDFs, approval workflows, change
# logs and approval emails. Projects, assignments, customers and accounts are
# kept, and nobody else's data is touched.
#
# Everything on that page is gated on the Core.CONST_IsTestEnv constant. If the
# constant is false the card and buttons do not render, and these helpers FAIL
# loudly rather than reporting a green run against uncleaned data.
#
# Env:
#   TT_ADMIN_USER        admin login with the Core.Administrator role (default MxAdmin)
#   TT_ADMIN_PASS        password for it (default AdminPassword1!)
#   TT_E2E_CONSULTANTS   pipe-separated consultant FullNames to clear
#                        (default "E2E Consultant|E2E Consultant Two|E2E Consultant Three")
#
# Only Consultant-role accounts appear in the list — Core.DS_TestData_Consultants
# filters on UserRoles/Name = 'Consultant'. The e2e PM/HR/TM accounts own no
# timesheets, so clearing the consultants clears all e2e timesheet data.
#
# 'E2E Consultant Three' is in the default because all three seeders --
# seed-regression-ladder.sh, seed-shakedown.sh and seed-toprocess-entries.sh --
# write timesheets for e2e_consultant3. It was absent until 2026-08-27, so that
# consultant's rows survived BOTH bookends indefinitely: seeded data was never
# cleared by the run that followed it, and the leak was invisible because no
# assertion counts that consultant.
#
# The list is a promise that these accounts EXIST as Consultant-role users:
# tt_clear_consultant_testdata fails when it cannot find a consultant's Clear
# control, and both bookends run it. That is deliberate -- an environment
# missing an account the seeders write to should say so loudly, once, rather
# than leak rows quietly forever -- but it does mean adding a name here without
# also adding it to FX_CONSULTANTS in lib/_fixtures.sh moves the complaint to
# the wrong step. Keep the two lists in step.
#
# KNOWN UNCOVERED, both deliberate:
#
#  1. The GLOBAL "Clear out all data" control (Core.ACT_TestData_ClearAll via
#     Core.NAV_TestData_ClearConfirm / Core.TestData_ClearConfirm) is never
#     exercised. It deletes EVERY consultant's timesheets, not just the e2e
#     ones, so running it on the shared dev environment would destroy other
#     people's work in progress. The per-consultant flow below covers the same
#     eight delete subflows on a safe scope.
#
#  2. The Core.CONST_IsTestEnv = false REFUSAL is never asserted. The helpers
#     below treat that state as a failure signal ("this environment is not a
#     test env") rather than a thing to prove, because the constant is set per
#     environment at deploy time — a test cannot flip it and flip it back. To
#     prove the guard, deploy once with the constant false and confirm both that
#     the card does not render and that Core.ACT_TestDataConsultant_ClearAll
#     refuses with "Clearing test data is disabled".

TT_ADMIN_U="${TT_ADMIN_USER:-MxAdmin}"
TT_ADMIN_P="${TT_ADMIN_PASS:-AdminPassword1!}"
TT_E2E_CONSULTANTS="${TT_E2E_CONSULTANTS:-E2E Consultant|E2E Consultant Two|E2E Consultant Three}"

# tt_dismiss_dialog — click the affirmative/OK button on any open Mendix dialog.
# Mendix renders show-message popups as .mx-dialog / .mx-window, not [role=dialog].
tt_dismiss_dialog() {
  local i
  for i in 1 2 3 4 5; do
    if playwright-cli eval "() => { const d=document.querySelector('.mx-dialog,.mx-window,[role=dialog],[class*=modal]'); if(!d) return 'none'; const b=[...d.querySelectorAll('button')].find(x=>/^(ok|close|yes|confirm)$/i.test((x.innerText||'').trim())); if(b){b.click(); return 'clicked';} return 'stuck'; }" 2>/dev/null | sed -n '2p' | grep -qiw none; then
      return 0
    fi
    sleep 1
  done
  return 0
}

# tt_open_testdata_admin — log in as the admin and open the Test Data page.
# Leaves the browser on Core.TestData_Admin with the consultant list rendered.
tt_open_testdata_admin() {
  tt_login "$TT_ADMIN_U" "Accounts Overview" "$TT_ADMIN_P"

  # The "Clean Test Data" card is a container (not a named button), gated on
  # Core.CONST_IsTestEnv. Its absence means this environment is not a test env.
  if ! playwright-cli eval "() => String(!!document.querySelector('.mx-name-containerTestDataCard'))" 2>/dev/null | grep -qiw true; then
    tt_fail "Administrator dashboard has no 'Clean Test Data' card — Core.CONST_IsTestEnv is false in this environment, so e2e data cannot be reset"
  fi

  playwright-cli click ".mx-name-containerTestDataCard" >/dev/null 2>&1
  sleep 2
  tt_wait_for ".mx-name-lvTestDataConsultants" "Test Data page consultant list"
}

# tt_clear_consultant_testdata <full-name>
# Clears one consultant's test data from the already-open Test Data page.
# Matches the row on an EXACT name equality — "E2E Consultant" is a prefix of
# "E2E Consultant Two", so substring matching would hit the wrong row.
tt_clear_consultant_testdata() {
  local who="$1" i

  playwright-cli eval "() => { const rows=[...document.querySelectorAll('.mx-name-containerConsultantRow')]; for (const r of rows) { const n=r.querySelector('.mx-name-txtConsultantRowName'); const b=r.querySelector('.mx-name-btnClearConsultantTestData'); if (n && b && (n.innerText||'').trim()==='$who') { b.click(); return 'ok'; } } return 'none'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok \
    || tt_fail "no 'Clear' control for consultant '$who' on the Test Data page (is the account missing, or not in the Consultant user role?)"
  sleep 2

  tt_wait_for ".mx-name-btnConfirmClearConsultant" "clear-confirm popup for '$who'"
  playwright-cli click ".mx-name-btnConfirmClearConsultant" >/dev/null 2>&1

  # The delete walks workflows and file documents, so give it room. The flow ends
  # with `close page` + an Information message naming the consultant.
  local done=""
  for i in $(seq 1 45); do
    if playwright-cli eval "() => String(document.body.innerText.indexOf('Clearing test data is disabled') >= 0)" 2>/dev/null | grep -qiw true; then
      tt_fail "clear for '$who' was refused: Core.CONST_IsTestEnv is false in this environment"
    fi
    if playwright-cli eval "() => String(document.body.innerText.indexOf('Test data cleared for $who') >= 0)" 2>/dev/null | grep -qiw true; then
      done=1; break
    fi
    sleep 2
  done
  [ -n "$done" ] || tt_fail "clear for '$who' did not confirm within ~90s (no 'Test data cleared for $who' message)"

  tt_dismiss_dialog
  sleep 1
  tt_wait_for ".mx-name-lvTestDataConsultants" "Test Data page after clearing '$who'"
}

# tt_clear_e2e_testdata <label>
# Full reset: opens the Test Data page as admin and clears every consultant in
# TT_E2E_CONSULTANTS. Fails on the first one that cannot be cleared — a partial
# reset is worse than an obvious failure, because later assertions would run
# against stale rows.
tt_clear_e2e_testdata() {
  local label="${1:-reset}" name
  tt_open_testdata_admin
  local IFS='|'
  for name in $TT_E2E_CONSULTANTS; do
    [ -n "$name" ] || continue
    unset IFS
    echo "  [$label] clearing test data for '$name'"
    tt_clear_consultant_testdata "$name"
    IFS='|'
  done
  unset IFS
}
