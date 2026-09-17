#!/usr/bin/env bash
# A week's badge agrees with the entries underneath it.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS. Main.SUB_AssignmentEntry_UpdateTimesheetStatus rolls a
# Timesheet's Status up from its entries, and the rule is exact:
#
#   every entry in {ToProcess, AwaitingExport, Exported}  -> Approved
#   otherwise, ANY entry Rejected                         -> Rejected
#   otherwise                                             -> Awaiting_Approval
#
# verify-timesheet-status-rollup only proves Draft -> Awaiting_Approval on submit.
# It never approves or rejects anything, so the two branches that decide what a
# consultant sees after somebody acts on their week are untested - and the
# mixed-week case, where one project is approved and another rejected, is the one
# most likely to be got wrong.
#
# It matters because the badge is not decoration. verify-week-status-badge keys
# the visibility of the Submit button off it, so a week stuck on the wrong badge
# either hides an action the consultant needs or offers one that will fail.
#
# WHY AN INVARIANT RATHER THAN A SCENARIO. The scenario version has to drive two
# projects through two different approval paths in one week and wait for both -
# several minutes, two actors, and a fixture that guarantees a consultant with two
# projects in the same week. This asserts the same rule by reading, on whatever
# the run happened to produce, and keeps asserting it as the data changes.
#
# WHAT IT ASSERTS, over E2E timesheets that are NOT Draft (the rollup only runs
# once a week has been submitted, so a Draft week has no rollup to be right or
# wrong about):
#   A. no timesheet holds a Rejected entry while showing anything but Rejected -
#      this is the mixed-week case;
#   B. no timesheet shows Approved while holding an entry that is not
#      ToProcess, AwaitingExport or Exported;
#   C. no timesheet shows Rejected without holding a Rejected entry;
#   D. something was examined, so an empty sweep is not a pass.
#
# Reads only. Changes nothing.
#
# Consumes: nothing.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

OWNED="starts-with(Main.Timesheet_Account/Administration.Account/FullName,'E2E ')"
NOTDRAFT="[Status != 'Draft']"
ENTRY="Main.AssignmentEntry_Timesheet/Main.AssignmentEntry"

n_of() {
  local n; n="$(tt_authz_count "$1")"
  case "$n" in ERR:*|''|*[!0-9]*) printf 'ERR' ;; *) printf '%s' "$n" ;; esac
}

tt_login "e2e_hr" "WEEKLY TO PROCESS"
note "session roles: $(tt_authz_roles)"

TOTAL="$(n_of "//Main.Timesheet[$OWNED]$NOTDRAFT")"
[ "$TOTAL" != "ERR" ] || tt_fail "could not count E2E timesheets, so nothing could be reconciled"
note "examining $TOTAL non-Draft E2E timesheet(s)"

# ----------------------------------------------- A. a Rejected entry, a non-Rejected week
A="$(n_of "//Main.Timesheet[$OWNED]$NOTDRAFT[$ENTRY/Status = 'Rejected'][Status != 'Rejected']")"
case "$A" in
  ERR) bad "A: could not count timesheets holding a Rejected entry" ;;
  0)   note "A ok: every week holding a Rejected entry reads Rejected" ;;
  *)   bad "A: $A week(s) hold a Rejected entry while showing something else. That is the mixed week - one project approved, another rejected - and the consultant is told the week is fine when part of it was sent back." ;;
esac

# ------------------------------------------------- B. Approved with an unsettled entry
B="$(n_of "//Main.Timesheet[$OWNED][Status = 'Approved'][$ENTRY/Status != 'ToProcess'][$ENTRY/Status != 'AwaitingExport'][$ENTRY/Status != 'Exported']")"
case "$B" in
  ERR) bad "B: could not count Approved timesheets with unsettled entries" ;;
  0)   note "B ok: every Approved week has only settled entries beneath it" ;;
  *)   bad "B: $B week(s) read Approved while holding an entry that is not ToProcess, AwaitingExport or Exported - the badge is ahead of the work" ;;
esac

# ---------------------------------------------------- C. Rejected with nothing rejected
C_TOTAL="$(n_of "//Main.Timesheet[$OWNED][Status = 'Rejected']")"
C_WITH="$(n_of "//Main.Timesheet[$OWNED][Status = 'Rejected'][$ENTRY/Status = 'Rejected']")"
if [ "$C_TOTAL" = "ERR" ] || [ "$C_WITH" = "ERR" ]; then
  bad "C: could not count Rejected timesheets"
elif [ "$C_TOTAL" -eq 0 ]; then
  note "C: no week currently reads Rejected - nothing to check on this arm"
elif [ "$C_TOTAL" -eq "$C_WITH" ]; then
  note "C ok: all $C_TOTAL Rejected week(s) hold at least one Rejected entry"
else
  bad "C: $((C_TOTAL - C_WITH)) week(s) read Rejected with no Rejected entry beneath them - the consultant is asked to fix something that is not there"
fi

# ------------------------------------------------------------------- D. did we look?
if [ "$TOTAL" = "ERR" ] || [ "$TOTAL" -eq 0 ]; then
  bad "D: no non-Draft E2E timesheet exists, so nothing was reconciled and this step has no verdict to give. suites/20-consultant and 30-approval produce them; run the suite in order."
else
  note "D ok: $TOTAL week(s) examined"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-timesheet-rollup-invariant — $fails problem(s); a week badge disagrees with its entries."
  exit 1
fi
echo "PASS: verify-timesheet-rollup-invariant — $TOTAL non-Draft week(s) all agree with the entries beneath them."
