#!/usr/bin/env bash
# An entry that is no longer awaiting approval must not be rejectable.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. Main.ACT_ApprovalHelper_Reject has exactly one split -
# "Left Comments?" - and no status guard at all. Its approving sibling,
# ACT_ApprovalHelper_Approve, does check that the entry is still awaiting the
# caller. So anything that reaches Reject with a comment present becomes Rejected,
# from ANY status. The only thing keeping it off an already-exported row is that
# one caller, NACT_AssignmentEntry_PageReject, special-cases Exported before
# calling it.
#
# That makes a stale HR dashboard card dangerous: press Reject on a card whose
# entry has since been approved by someone else and the hours are un-approved
# without the compensating unwind that ACT_RejectAfterExport performs. The hours
# are not backed out of Assignment.TotalHoursWorked, because that flow is not the
# one that ran.
#
# verify-hr-process-reject-guard is the closest existing test and covers the
# COMMENT guard - it proves an empty comment is refused. Its header says in as
# many words that it does not test status.
#
# WHAT IT ASSERTS
#   A. a POSITIVE CONTROL: rejecting an entry that IS awaiting approval works.
#      Without it, a refusal below could be the call shape being wrong rather than
#      a guard firing - this runtime returns "Internal server error" for both. The
#      control is what makes B attributable at all;
#   B. calling Reject on an entry already in ToProcess does not move it.
#
# WHAT THIS CONSUMES, SAID PLAINLY. A is a real rejection of a real entry: it
# leaves one E2E entry in Rejected, which is an ordinary state this suite produces
# elsewhere and which the bookend clear removes. There is no way to prove the call
# shape works without making the call work once.
#
# IF B FAILS an approved, possibly exported, entry can be silently un-approved
# from a stale tab, and the hours are not unwound. That is a finding.
#
# Consumes: one AwaitingManagerApproval entry (rejected), and reads one ToProcess
# entry.
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
AWAITING="//Main.AssignmentEntry[$OWNED][Status='AwaitingManagerApproval']"
SETTLED="//Main.AssignmentEntry[$OWNED][Status='ToProcess']"

first_guid() {
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"$1\", filter:{amount:1}, callback:function(o){ clearTimeout(t); res((o&&o.length)?o[0].getGuid():''); }, error:function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}
status_of() {
  playwright-cli eval "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ guid: '$1', callback:function(o){ clearTimeout(t); res(o ? String(o.get('Status')) : 'ERR:gone'); }, error:function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

tt_login "e2e_hr" "WEEKLY TO PROCESS"
note "session roles: $(tt_authz_roles)"

# ------------------------------------------------------------------ A. the control
CTRL_GUID="$(first_guid "$AWAITING")"
case "$CTRL_GUID" in
  ERR:*) tt_fail "could not look for an entry awaiting manager approval ($CTRL_GUID)" ;;
  "")    tt_fail "no E2E entry is awaiting manager approval, so the reject call shape cannot be proven to work and B would be unattributable. suites/30-approval creates one; run the suite in order." ;;
esac
note "control entry $CTRL_GUID (AwaitingManagerApproval)"

# The flow needs a comment present; set it the way the page would before calling.
tt_authz_write "//Main.AssignmentEntry[id='$CTRL_GUID']" 'RejectionComment' 'e2e: proving the reject call shape works' >/dev/null 2>&1
CTRL="$(tt_authz_action 'Main.ACT_ApprovalHelper_Reject' "$CTRL_GUID")"
sleep 2
CTRL_AFTER="$(status_of "$CTRL_GUID")"
if [ "$CTRL_AFTER" = "Rejected" ]; then
  note "A ok: the control entry moved to Rejected, so the call shape works ($CTRL)"
else
  bad "A: the control entry is $CTRL_AFTER after a reject that returned [$CTRL]. The call shape is unproven, so B below cannot distinguish a guard from a bad call - treat B's result as inconclusive."
fi

# ---------------------------------------------------- B. the same call, wrong status
TARGET_GUID="$(first_guid "$SETTLED")"
case "$TARGET_GUID" in
  ERR:*) tt_fail "could not look for a ToProcess entry ($TARGET_GUID)" ;;
  "")    tt_fail "no E2E entry is in ToProcess, so there is nothing settled to attempt a stale reject against. suites/30-approval and 40-hr produce them; run the suite in order." ;;
esac
BEFORE="$(status_of "$TARGET_GUID")"
note "target entry $TARGET_GUID, Status before = $BEFORE"

tt_authz_write "//Main.AssignmentEntry[id='$TARGET_GUID']" 'RejectionComment' 'e2e: stale-card reject attempt' >/dev/null 2>&1
R="$(tt_authz_action 'Main.ACT_ApprovalHelper_Reject' "$TARGET_GUID")"
sleep 2
AFTER="$(status_of "$TARGET_GUID")"

case "$AFTER" in
  ERR:*)     bad "B: could not read the target back ($AFTER), so this step cannot say whether it moved" ;;
  "$BEFORE") note "B ok: the entry is still $AFTER (the call returned $R)" ;;
  Rejected)  bad "B: an entry already in $BEFORE was moved to Rejected by ACT_ApprovalHelper_Reject. There is no status guard on that flow, and the hours are not unwound the way ACT_RejectAfterExport unwinds them." ;;
  *)         bad "B: the entry moved from $BEFORE to $AFTER" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-hr-reject-wrong-status-refused — $fails problem(s). B is a finding about ACT_ApprovalHelper_Reject having no status guard."
  exit 1
fi
echo "PASS: verify-hr-reject-wrong-status-refused — reject works on an awaiting entry and does not move one already in $BEFORE."
