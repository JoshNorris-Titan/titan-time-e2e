#!/usr/bin/env bash
# No entry waits for an approval its project does not ask for.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS. Main.SUB_AssignmentEntry_Submit routes a submitted entry from
# the project's two approval flags: manager on -> AwaitingManagerApproval, else
# customer on -> AwaitingCustomerApproval, else straight to ToProcess. Three
# separate gaps in this suite all reduce to the same invariant, and none of them
# is covered:
#
#   * the No|No route (neither approval required) has no test at all. tt647-a3
#     reaches "N/A" through the ZERO-HOURS branch of the same expression, so the
#     genuine no-approval route is unasserted;
#   * ACT_Project_Save guards the CUSTOMER flag - it refuses a save when
#     ApprovalFromCustomer is on and ContactEmail is blank - but has no equivalent
#     for the MANAGER flag, so a project can carry ApprovalFromManager with no
#     project manager set, and its entries then route to AwaitingManagerApproval
#     and appear in nobody's queue, because DS_ApprovalHelper_PM filters on
#     ProjectManager_Account = CurrentUser;
#   * nothing checks that an entry's status is reachable from its own project's
#     configuration at all.
#
# An entry stuck that way is the quietest failure in the app. It is not rejected,
# it is not late, and it is not in anyone's list. It simply never moves, and the
# consultant's hours are never invoiced.
#
# WHAT IT ASSERTS, over every E2E entry:
#   A. AwaitingManagerApproval  => its project has ApprovalFromManager true;
#   B. AwaitingCustomerApproval => its project has ApprovalFromCustomer true;
#   C. an entry awaiting manager approval has a project manager to await - the
#      orphan case above;
#   D. something was actually examined, so an empty sweep is not a pass.
#
# WHY THIS SHAPE. A scenario test would have to submit through each of the four
# flag combinations and wait for each to route, which is four fixtures and a lot
# of clock. The invariant catches the same mis-routing from a read, on whatever
# data the run happens to have produced, and keeps catching it as the data
# changes.
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

OWNED="starts-with(Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName,'E2E ')"

# count <status> <extra-predicate> — entries in <status> whose project ALSO matches.
count_where() {
  tt_authz_count "//Main.AssignmentEntry[$OWNED][Status='$1']$2"
}

tt_login "e2e_hr" "WEEKLY TO PROCESS"
note "session roles: $(tt_authz_roles)"

PROJ="Main.AssignmentEntry_Assignment/Main.Assignment/Main.Assignment_Project/Main.Project"

examined=0

# --------------------------------------------------- A. awaiting manager => flag is on
TOTAL_M="$(count_where AwaitingManagerApproval "")"
BAD_M="$(count_where AwaitingManagerApproval "[$PROJ/ApprovalFromManager = false()]")"
case "$TOTAL_M" in
  ERR:*|''|*[!0-9]*) bad "A: could not count AwaitingManagerApproval entries (read: [$TOTAL_M])" ;;
  0)                 note "A: no entry is awaiting manager approval - nothing to check on this arm" ;;
  *)
    examined=$((examined+TOTAL_M))
    case "$BAD_M" in
      ERR:*|''|*[!0-9]*) bad "A: could not count mis-routed manager entries (read: [$BAD_M])" ;;
      0)                 note "A ok: all $TOTAL_M entry(ies) awaiting manager approval are on projects that require it" ;;
      *)                 bad "A: $BAD_M of $TOTAL_M entry(ies) await MANAGER approval on a project whose ApprovalFromManager is false - they are waiting for an approval nobody was asked for" ;;
    esac ;;
esac

# -------------------------------------------------- B. awaiting customer => flag is on
TOTAL_C="$(count_where AwaitingCustomerApproval "")"
BAD_C="$(count_where AwaitingCustomerApproval "[$PROJ/ApprovalFromCustomer = false()]")"
case "$TOTAL_C" in
  ERR:*|''|*[!0-9]*) bad "B: could not count AwaitingCustomerApproval entries (read: [$TOTAL_C])" ;;
  0)                 note "B: no entry is awaiting customer approval - nothing to check on this arm" ;;
  *)
    examined=$((examined+TOTAL_C))
    case "$BAD_C" in
      ERR:*|''|*[!0-9]*) bad "B: could not count mis-routed customer entries (read: [$BAD_C])" ;;
      0)                 note "B ok: all $TOTAL_C entry(ies) awaiting customer approval are on projects that require it" ;;
      *)                 bad "B: $BAD_C of $TOTAL_C entry(ies) await CUSTOMER approval on a project whose ApprovalFromCustomer is false" ;;
    esac ;;
esac

# --------------------------------------- C. awaiting a manager who does not exist
ORPHAN="$(count_where AwaitingManagerApproval "[not($PROJ/Main.ProjectManager_Account)]")"
case "$ORPHAN" in
  ERR:*|''|*[!0-9]*) note "C: could not count entries whose project has no manager (read: [$ORPHAN])" ;;
  0)                 note "C ok: every entry awaiting manager approval has a project manager to await" ;;
  *)                 bad "C: $ORPHAN entry(ies) await manager approval on a project with NO project manager set. DS_ApprovalHelper_PM filters on ProjectManager_Account = CurrentUser, so these appear in nobody's queue and will never move. ACT_Project_Save guards the customer flag this way but not the manager flag." ;;
esac

# ------------------------------------------------------------------- D. did we look?
[ "$examined" -gt 0 ] \
  || bad "no E2E entry is awaiting any approval, so nothing was examined and this step has no verdict to give. suites/20-consultant and 30-approval produce them; run the suite in order."

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-entry-status-matches-project-config — $fails problem(s); entries are waiting on approvals their project does not ask for."
  exit 1
fi
echo "PASS: verify-entry-status-matches-project-config — $examined awaiting entry(ies) all match their project's approval configuration."
