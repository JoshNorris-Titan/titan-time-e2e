#!/usr/bin/env bash
# A customer who opened an approval link reads exactly what that link covers - and
# the moment the session is a new one, nothing at all.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. The customer-link security change (model, 2026-09-29) moved the
# whole anonymous read surface onto one mechanism. Opening an approval link now
# records a Main.ApprovalVisit - this session's own anonymous user, the token, the
# approver's email and the projects the link covers - and every anonymous access
# rule on AssignmentEntry, Timesheet, Assignment, Project, Customer, LineItem,
# AssignmentAttachment, AttachmentDocument, ExpenseReport and ExpenseReportDocuments
# admits a row only when its project is covered by a live visit OF THE CURRENT
# SESSION (token Active and unexpired; entries only AwaitingCustomerApproval).
#
# verify-anon-entity-read-scope proves the no-visit half: a session that never
# opened a link reads nothing. Nothing proved the other half - that a session that
# DID open one reads its own customer's rows and no one else's - and that half is
# the one a mistyped XPath would break quietly. An over-wide rule (a missing
# [Main.ApprovalVisit_User = '[%CurrentUser%]'], say) still passes every no-visit
# check, because this suite's no-visit sessions have no visits for it to leak.
#
# WHAT IT ASSERTS, in the SAME browser session that opened a real emailed link:
#   A. the session is anonymous and the link rendered its pending list;
#   B. it can read AwaitingCustomerApproval entries (at least the one HR just
#      reminded) - otherwise the customer's own page could not work, and every
#      "0" below would be meaningless;
#   C. EVERY entry it can read is on a project whose ContactEmail is this link's
#      approver - asked as two counts that must agree, the unconstrained one and
#      the one constrained to the covered projects;
#   D. it can read no entry in any other status;
#   E. every Project it can read is one of the covered ones;
#   F. the other approver's project ('E2E Dual Approval', its own address in
#      lib/_fixtures.sh) is invisible - the READ half of the cross-approver case,
#      conclusive only when HR can see a pending entry there, and said so when not;
#   G. Administration.Account, Main.ApprovalToken and Main.ApprovalVisit are 0 or
#      refused even WITH a visit;
# and then, after clearing cookies - a fresh anonymous session with no visit:
#   H. every one of those business entities is 0 or refused, although the previous
#      session could read some of them a moment ago. That is the "visit belongs to
#      the session" property, stated as data.
#
# CROSS-APPROVER ACTIONS ARE NOT HERE. Acting (approve/reject) on an entry the
# visit does not cover needs the action called with TWO objects - the entry and the
# page's CustomerApprovalHelper - and lib/_authz.sh can pass one. The refusal would
# then come from the "inputs given?" check, not from the cross-approver rule, so a
# spec built on it would pass for the wrong reason and was not written. The mid-visit
# refusal of a real page action is verify-anon-expired-link-mid-visit.
#
# RED / UNPROVEN UNTIL THE CHANGE IS DEPLOYED. Before it, the anonymous rules are the
# old status-only ones, so C/E/F read other approvers' rows and H reads them with no
# visit at all.
#
# Consumes: nothing - it reminds a pending entry (or submits one when none is
# waiting) and approves nothing. Clears cookies - safe here, in 85-security.
# Env: TT_BASE_URL, TT_ROLE_PASS, TT_ADMIN_USER, TT_ADMIN_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"   # FX_APPROVER_EMAIL: the approver on E2E Customer Approval
source "$TT_ROOT/lib/_authz.sh"
source "$TT_ROOT/lib/_changelog.sh"
source "$TT_ROOT/lib/_customer_link.sh"

fails=0
NUM=""
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

CONSULTANT_NAME="E2E Consultant"
PROJECT="E2E Customer Approval"
APPROVER="$FX_APPROVER_EMAIL"
OTHER_PROJECT="E2E Dual Approval"   # carries its own approver address - see lib/_fixtures.sh

PROJ_PATH="Main.AssignmentEntry_Assignment/Main.Assignment/Main.Assignment_Project/Main.Project"
ALL_ENTRIES="//Main.AssignmentEntry"
COVERED_ENTRIES="//Main.AssignmentEntry[$PROJ_PATH/ContactEmail = '$APPROVER']"
OTHER_STATUS="//Main.AssignmentEntry[Status != 'AwaitingCustomerApproval']"
OTHER_ENTRIES="//Main.AssignmentEntry[$PROJ_PATH/Name = '$OTHER_PROJECT'][Status = 'AwaitingCustomerApproval']"
ALL_PROJECTS="//Main.Project"
COVERED_PROJECTS="//Main.Project[ContactEmail = '$APPROVER']"
BUSINESS="Main.AssignmentEntry Main.Timesheet Main.Assignment Main.Project Main.Customer Main.LineItem Main.AssignmentAttachment Main.AttachmentDocument Main.ExpenseReport Main.ExpenseReportDocuments"
NEVER="//Administration.Account //Main.ApprovalToken //Main.ApprovalVisit"

# num_or_bad <label> <answer> — echo <answer> when it is a count. Otherwise record
# why (in THIS shell, so call it outside any command substitution) and echo ''.
num_or_bad() {
  case "$2" in
    ''|*[!0-9]*) bad "$1: the retrieve did not return a count ([$2])"; NUM="" ;;
    *) NUM="$2" ;;
  esac
}

# zero_or_refused <label> <xpath> — pass on ERR: or 0, fail with the count otherwise.
zero_or_refused() {
  local n
  n="$(tt_authz_count "$2")"
  case "$n" in
    ERR:no-mx-client) bad "$1: the Mendix client API was not available, so the data layer was never asked" ;;
    ERR:*)            note "$1: refused outright ($n)" ;;
    0)                note "$1: 0 rows" ;;
    ''|*[!0-9]*)      bad "$1: the retrieve returned something that is not a count: [$n]" ;;
    *)                bad "$1: $n row(s) readable" ;;
  esac
}

# ------------------------------------------------------ 1. a real link, from real mail
cl_fresh_link "$CONSULTANT_NAME" "$PROJECT" "$APPROVER"

# ------------------------------------------------ 2. controls, as HR, before anything
tt_login "e2e_hr" "$TT_HR_READY"
HR_COVERED="$(tt_authz_expect_count "control: pending entries on $APPROVER's projects" "//Main.AssignmentEntry[$PROJ_PATH/ContactEmail = '$APPROVER'][Status = 'AwaitingCustomerApproval']")"
HR_OTHER="$(tt_authz_expect_count "control: pending entries on '$OTHER_PROJECT'" "$OTHER_ENTRIES")"
declare -A HR_N=()
for e in $BUSINESS; do
  HR_N[$e]="$(tt_authz_count "//$e")"
done
for v in "$HR_COVERED" "$HR_OTHER"; do
  case "$v" in ''|*[!0-9]*) tt_fail "an HR control count could not be taken ([$HR_COVERED] / [$HR_OTHER]) - see the line above" ;; esac
done
note "control (HR): $HR_COVERED pending entr(ies) on $APPROVER's projects, $HR_OTHER on '$OTHER_PROJECT'"
[ "$HR_COVERED" -gt 0 ] \
  || tt_fail "HR sees no pending entry on $APPROVER's projects moments after reminding one, so the link has nothing to cover and nothing below could be told apart from an empty table"

# ------------------------------------------- 3. open the link: this RECORDS the visit
cl_open_link_cold "$CL_LINK" \
  || tt_fail "the approval link did not open an approval page in a fresh anonymous session: $CL_LINK"
[ "$(cl_visible '.mx-name-galPendingEntries')" = "true" ] \
  || tt_fail "the link opened on its empty state, not on a pending list, minutes after HR reminded an entry for '$CONSULTANT_NAME' - every read below would be measured against an empty visit"

ROLES="$(tt_authz_roles)"
note "A: session roles with the link open: $ROLES"
case "$ROLES" in
  *Anonymous*) ;;
  *) tt_fail "the session that opened the link does not hold Anonymous ($ROLES)" ;;
esac
for privileged in Consultant ProjectManager HR TitanManager Administrator; do
  case "$ROLES" in
    *"\"$privileged\""*) tt_fail "A: the link session holds $privileged ($ROLES) - every count below would be a staff session's" ;;
  esac
done

# ---------------------------------------------- 4. B-G: what THIS session may read
num_or_bad "B" "$(tt_authz_count "$ALL_ENTRIES")";     N_ALL="$NUM"
num_or_bad "C" "$(tt_authz_count "$COVERED_ENTRIES")"; N_COV="$NUM"
if [ -n "$N_ALL" ]; then
  if [ "$N_ALL" -gt 0 ]; then
    note "B ok: the link session reads $N_ALL pending entr(ies) (HR sees $HR_COVERED on this approver's projects)"
  else
    bad "B: the session that opened the link reads NO entries - the customer's own page could not show anything, and the zeros below prove nothing"
  fi
  [ "$N_ALL" -le "$HR_COVERED" ] \
    || bad "B: the link session reads $N_ALL entries, more than the $HR_COVERED HR can see on this approver's projects"
fi
if [ -n "$N_ALL" ] && [ -n "$N_COV" ]; then
  [ "$N_ALL" = "$N_COV" ] \
    && note "C ok: all $N_ALL readable entr(ies) are on a project whose contact is $APPROVER" \
    || bad "C: the link session reads $N_ALL entries but only $N_COV are on $APPROVER's projects - $(( N_ALL - N_COV )) belong to a project this link does not cover"
fi

zero_or_refused "D: entries in any status but AwaitingCustomerApproval" "$OTHER_STATUS"

num_or_bad "E" "$(tt_authz_count "$ALL_PROJECTS")";     P_ALL="$NUM"
num_or_bad "E" "$(tt_authz_count "$COVERED_PROJECTS")"; P_COV="$NUM"
if [ -n "$P_ALL" ] && [ -n "$P_COV" ]; then
  if [ "$P_ALL" = "$P_COV" ] && [ "$P_ALL" -gt 0 ]; then
    note "E ok: the link session reads $P_ALL project(s), all with contact $APPROVER"
  elif [ "$P_ALL" = "$P_COV" ]; then
    bad "E: the link session reads no project at all, though it reads $N_ALL entr(ies) on one - the review popup names the project from exactly this read"
  else
    bad "E: the link session reads $P_ALL project(s), of which only $P_COV have contact $APPROVER"
  fi
fi

if [ "$HR_OTHER" -gt 0 ]; then
  zero_or_refused "F: '$OTHER_PROJECT' pending entries (HR sees $HR_OTHER; another approver's link)" "$OTHER_ENTRIES"
else
  note "F not conclusive: HR sees no pending entry on '$OTHER_PROJECT' right now, so reading 0 of them proves nothing (C still stands)"
  zero_or_refused "F: '$OTHER_PROJECT' pending entries" "$OTHER_ENTRIES"
fi

for xp in $NEVER; do
  zero_or_refused "G: $xp with a visit" "$xp"
done

# ------------------------------------------- 5. H: a fresh session has no visit
ROLES2="$(tt_authz_anonymous)"
note "H: fresh session roles: $ROLES2"
case "$ROLES2" in
  *Anonymous*) ;;
  *) tt_fail "after clearing cookies the session does not hold Anonymous ($ROLES2)" ;;
esac
conclusive=0
for e in $BUSINESS; do
  n="$(tt_authz_count "//$e")"
  c="${HR_N[$e]}"
  case "$n" in
    ERR:no-mx-client) bad "H: $e - the Mendix client API was not available" ;;
    ERR:*)            note "H: $e refused outright ($n); HR saw $c"; conclusive=$((conclusive+1)) ;;
    0)
      case "$c" in
        ''|*[!0-9]*|0) note "H: $e 0 rows, but HR's control was [$c] - not conclusive for this entity" ;;
        *)             note "H: $e 0 rows (HR sees $c)"; conclusive=$((conclusive+1)) ;;
      esac ;;
    ''|*[!0-9]*)      bad "H: $e - the retrieve returned something that is not a count: [$n]" ;;
    *)                bad "H: a fresh session that opened NO link reads $n row(s) of $e - the visit is not scoped to the session that recorded it, or an anonymous rule does not use it" ;;
  esac
done
[ "$conclusive" -gt 0 ] || bad "H: no entity gave a conclusive answer, so the fresh-session half has no verdict"

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-anon-visit-read-scope — $fails problem(s) with what an approval-link session may read."
  exit 1
fi
echo "PASS: verify-anon-visit-read-scope — the link session read $N_ALL pending entr(ies) and $P_ALL project(s), all its approver's, none of '$OTHER_PROJECT', no other status, no accounts/tokens/visits; a fresh session read nothing ($conclusive entit(y/ies) conclusive)"
