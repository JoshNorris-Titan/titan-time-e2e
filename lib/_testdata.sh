#!/usr/bin/env bash
# Test-data reset helpers for the Titan Time E2E suite.
# Source AFTER lib/_login.sh:
#   source "$(dirname "$0")/lib/_login.sh"
#   source "$(dirname "$0")/lib/_testdata.sh"
#
# Drives the "Clean Test Data" card on the Administrator dashboard
# (Core.TestData_Admin, Core/996. Test Utilities).
#
# THE PAGE OFFERS FOUR CONTROLS, ON TWO AXES
# ------------------------------------------
# Scope (whole environment / one consultant) crossed with depth (transactional
# only / transactional plus structure):
#
#   Clear out all data                  whole env,      transactional
#   Clear out consultant data           one consultant, transactional
#   Clear out all data and structure    whole env,      + projects and assignments
#   Clear data + structure              one consultant, + projects and assignments
#
# This suite uses the PER-CONSULTANT controls only, never the whole-environment
# ones. That matters on a shared dev environment: the per-consultant flows touch
# only the named consultant, so nobody else's work in progress is destroyed.
#
# THE DEFAULT IS NOW THE DEEP PER-CONSULTANT CLEAR
# ------------------------------------------------
# TT_E2E_CLEAR_DEPTH=deep (the default) drives
# Core.ACT_TestDataConsultant_ClearAllAndStructure, which deletes everything the
# shallow flow does AND the consultant's assignments plus the projects those
# assignments were on. A run therefore starts from no structure at all, and
# suites/00-setup/verify-001-fixtures.test.sh rebuilds every project and
# assignment the suite needs. Run order is:
#
#   verify-000-testdata-clear-before   deep clear: transactional AND structure
#   verify-001-fixtures                recreate projects + assignments
#   verify-002-seed-isolation-control  seed the transactional control rows
#
# That is the REVERSE of the order used before 2026-09-06, when the clear
# preserved structure and the fixture step deliberately ran ahead of it. Any
# comment anywhere in this suite still claiming structure survives the clear is
# stale - the clear is now the first thing that runs, and it takes structure with
# it.
#
# WHY DELETING PROJECTS REACHES PAST THE NAMED CONSULTANT
# -------------------------------------------------------
# A project is not owned by a consultant, so "this consultant's projects" can only
# mean the projects their assignments point at - and Main.Assignment_Project
# cascades, so deleting one also removes OTHER consultants' assignments and entries
# on it. Josh's decision, 2026-09-06, taken knowingly: this is a test environment
# and the fixture step rebuilds what it needs. It does mean an e2e consultant
# accidentally assigned to a real project would take that project with them, which
# is an argument for keeping the e2e accounts assigned only to E2E projects (see
# FX_ASSIGNMENTS in lib/_fixtures.sh).
#
# Set TT_E2E_CLEAR_DEPTH=shallow to fall back to the old transactional-only
# behaviour. Nothing selects that automatically - see the missing-control failure
# in tt_clear_consultant_testdata for why.
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
#   TT_E2E_CLEAR_DEPTH   deep (default) | shallow
#
# Only Consultant-role accounts appear in the list - Core.DS_TestData_Consultants
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
#  1. The two GLOBAL controls (Core.ACT_TestData_ClearAll and
#     Core.ACT_TestData_ClearAllAndStructure) are never exercised. They delete
#     EVERY consultant's data, not just the e2e ones, so running either against
#     the shared dev environment would destroy other people's work in progress.
#     The per-consultant flows call the same delete subflows on a safe scope.
#
#  2. The Core.CONST_IsTestEnv = false REFUSAL is never asserted. The helpers
#     below treat that state as a failure signal ("this environment is not a
#     test env") rather than a thing to prove, because the constant is set per
#     environment at deploy time - a test cannot flip it and flip it back. To
#     prove the guard, deploy once with the constant false and confirm both that
#     the card does not render and that the clear microflows refuse with
#     "Clearing test data is disabled".

TT_ADMIN_U="${TT_ADMIN_USER:-MxAdmin}"
TT_ADMIN_P="${TT_ADMIN_PASS:-AdminPassword1!}"
TT_E2E_CONSULTANTS="${TT_E2E_CONSULTANTS:-E2E Consultant|E2E Consultant Two|E2E Consultant Three}"
TT_E2E_CLEAR_DEPTH="${TT_E2E_CLEAR_DEPTH:-deep}"

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

# tt_clear_consultant_testdata <full-name> [depth]
# Clears one consultant's test data from the already-open Test Data page.
# depth defaults to $TT_E2E_CLEAR_DEPTH; pass it explicitly only to override.
#
# Matches the row on an EXACT name equality — "E2E Consultant" is a prefix of
# "E2E Consultant Two", so substring matching would hit the wrong row.
#
# The two depths differ in three coupled strings - row button, confirm button and
# success message - so they are resolved once here rather than sprinkled through
# the function. The success messages are deliberately not prefixes of one another
# ("Test data cleared for X" vs "Test data and structure cleared for X"), so
# waiting on the wrong one cannot pass by accident.
tt_clear_consultant_testdata() {
  local who="$1" depth="${2:-$TT_E2E_CLEAR_DEPTH}" i
  local rowbtn confirmbtn donemsg waits

  case "$depth" in
    deep)
      rowbtn="mx-name-btnClearConsultantAndStructureTestData"
      confirmbtn="mx-name-btnConfirmClearConsultantAndStructure"
      donemsg="Test data and structure cleared for $who"
      waits=60 ;;
    shallow)
      rowbtn="mx-name-btnClearConsultantTestData"
      confirmbtn="mx-name-btnConfirmClearConsultant"
      donemsg="Test data cleared for $who"
      waits=45 ;;
    *)
      tt_fail "unknown TT_E2E_CLEAR_DEPTH '$depth' (expected 'deep' or 'shallow')" ;;
  esac

  # A missing DEEP control almost always means the environment predates the model
  # change rather than that the account is missing, and those two want very
  # different fixes. Say which it is instead of falling back quietly: a silent
  # downgrade to the shallow clear would leave structure in place and still report
  # a green run, which is exactly the class of failure this suite keeps hitting.
  if [ "$depth" = "deep" ] \
     && ! playwright-cli eval "() => String(!!document.querySelector('.$rowbtn'))" 2>/dev/null | grep -qiw true; then
    tt_fail "no 'Clear data + structure' control on the Test Data page — this environment predates Core.ACT_TestDataConsultant_ClearAllAndStructure. Deploy the model change, or set TT_E2E_CLEAR_DEPTH=shallow to deliberately run the old transactional-only clear."
  fi

  playwright-cli eval "() => { const rows=[...document.querySelectorAll('.mx-name-containerConsultantRow')]; for (const r of rows) { const n=r.querySelector('.mx-name-txtConsultantRowName'); const b=r.querySelector('.$rowbtn'); if (n && b && (n.innerText||'').trim()==='$who') { b.click(); return 'ok'; } } return 'none'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok \
    || tt_fail "no '$depth' Clear control for consultant '$who' on the Test Data page (is the account missing, or not in the Consultant user role?)"
  sleep 2

  tt_wait_for ".$confirmbtn" "clear-confirm popup for '$who' ($depth)"
  playwright-cli click ".$confirmbtn" >/dev/null 2>&1

  # The delete walks workflows and file documents, so give it room. The deep
  # variant additionally cascades through projects, their assignments and every
  # entry hanging off those, hence the longer wait. The flow ends with `close
  # page` plus an Information message naming the consultant.
  local done=""
  for i in $(seq 1 "$waits"); do
    if playwright-cli eval "() => String(document.body.innerText.indexOf('Clearing test data is disabled') >= 0)" 2>/dev/null | grep -qiw true; then
      tt_fail "clear for '$who' was refused: Core.CONST_IsTestEnv is false in this environment"
    fi
    if playwright-cli eval "() => String(document.body.innerText.indexOf('$donemsg') >= 0)" 2>/dev/null | grep -qiw true; then
      done=1; break
    fi
    sleep 2
  done
  [ -n "$done" ] || tt_fail "clear for '$who' did not confirm within ~$((waits * 2))s (no '$donemsg' message)"

  tt_dismiss_dialog
  sleep 1
  tt_wait_for ".mx-name-lvTestDataConsultants" "Test Data page after clearing '$who'"
}

# tt_clear_e2e_testdata <label>
# Full reset: opens the Test Data page as admin and clears every consultant in
# TT_E2E_CONSULTANTS at TT_E2E_CLEAR_DEPTH. Fails on the first one that cannot be
# cleared — a partial reset is worse than an obvious failure, because later
# assertions would run against stale rows.
tt_clear_e2e_testdata() {
  local label="${1:-reset}" name
  tt_open_testdata_admin
  local IFS='|'
  for name in $TT_E2E_CONSULTANTS; do
    [ -n "$name" ] || continue
    unset IFS
    echo "  [$label] clearing test data for '$name' ($TT_E2E_CLEAR_DEPTH)"
    tt_clear_consultant_testdata "$name"
    IFS='|'
  done
  unset IFS
}
