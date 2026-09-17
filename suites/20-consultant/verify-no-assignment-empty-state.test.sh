#!/usr/bin/env bash
# A consultant with no assignments gets the empty state, not a submittable grid.
#
# tt-timeout: 6m
#
# WHY THIS EXISTS. ConsultantDashboard declares containerNoAssignments,
# txtNoAssignmentsTitle and containerNoTimesheets, and nothing in this suite has
# ever rendered them. verify-week-status-badge asserts only that the two containers
# are not showing at the same time - and it runs as a consultant who always has
# rows, so the empty half of that assertion is never exercised. It would pass
# identically if the empty state were broken, or absent.
#
# This is a new hire's first login. It is also the state every consultant is in
# immediately after the bookend clear, which makes it the single most common
# uncovered state in the whole app.
#
# E2E Consultant Three is the right account for it: lib/_fixtures.sh gives it no
# FX_ASSIGNMENTS row on purpose ("here for the CLEAR, not for any test"), so it is
# permanently assignment-free by design rather than by accident.
#
# WHAT IT ASSERTS
#   A. the account really has no assignments - established through the data layer
#      first, and fatal if it does, because every assertion below would then be
#      testing the wrong state while still passing;
#   B. containerNoAssignments is rendered;
#   C. no editable day cells exist;
#   D. neither btnSubmit nor btnClear is offered - there is nothing to submit, and
#      offering it is how a consultant submits an empty week by accident.
#
# Consumes: reads only.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"

CUSER="${TT_EMPTY_USER:-e2e_consultant3}"
CNAME="${TT_EMPTY_NAME:-E2E Consultant Three}"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

present() { playwright-cli eval "() => String(!!document.querySelector('.mx-name-$1'))" 2>/dev/null | _tt_eval_str; }
count_of() { playwright-cli eval "() => String(document.querySelectorAll('$1').length)" 2>/dev/null | _tt_eval_str; }

# -------------------------------------------------------------- A. really no assignments
tt_login "e2e_hr" "WEEKLY TO PROCESS"
NA="$(tt_authz_count "//Main.Assignment[ConsultantName = '$CNAME']")"
case "$NA" in
  ERR:*)       note "A: could not confirm through the data layer ($NA); relying on the fixture contract that '$CNAME' has no assignments" ;;
  0)           note "A ok: '$CNAME' has 0 assignments" ;;
  ''|*[!0-9]*) note "A: assignment count unreadable [$NA]" ;;
  *)           tt_fail "'$CNAME' has $NA assignment(s), so this account is no longer assignment-free and every assertion below would test the wrong state while still passing. Either clear them or point TT_EMPTY_USER/TT_EMPTY_NAME at an account that has none." ;;
esac

# ------------------------------------------------------------------- B/C/D. the page
tt_login "$CUSER" "My Timesheets"
sleep 2

[ "$(present containerNoAssignments)" = "true" ] \
  && note "B ok: containerNoAssignments is rendered" \
  || bad "B: containerNoAssignments is not rendered for a consultant with no assignments"

[ "$(present txtNoAssignmentsTitle)" = "true" ] \
  && note "B ok: txtNoAssignmentsTitle is rendered" \
  || note "note: txtNoAssignmentsTitle is absent although the container is present"

CELLS="$(count_of '.mx-name-galAssignmentRows input')"
case "$CELLS" in
  0)           note "C ok: no editable day cells" ;;
  ''|*[!0-9]*) bad "C: could not count day cells (read: [$CELLS])" ;;
  *)           bad "C: $CELLS day cell(s) are editable for a consultant with no assignments" ;;
esac

for b in btnSubmit btnClear; do
  if [ "$(present $b)" = "true" ]; then
    bad "D: $b is offered to a consultant with nothing to submit"
  else
    note "D ok: $b is not offered"
  fi
done

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-no-assignment-empty-state — $fails problem(s) with the no-assignment state."
  exit 1
fi
echo "PASS: verify-no-assignment-empty-state — '$CNAME' sees the empty state, no editable cells and no submit."
