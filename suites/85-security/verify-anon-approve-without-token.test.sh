#!/usr/bin/env bash
# An unauthenticated session must not be able to approve or reject a timesheet
# entry it holds no token for.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS. Main.ACT_Customer_ApprovePage, ACT_Customer_ApproveHelper and
# ACT_Customer_RejectPage are all marked "May be called from the client by:
# Anonymous", and their only guard is Status = AwaitingCustomerApproval. No token
# is passed to them, read by them, or checked by them. The token gates which PAGE
# a client can open; it does not gate the ACTION. Separately, Anonymous holds an
# unconstrained read on Main.AssignmentEntry narrowed to exactly that status
# (docs/reference/SECURITY-FINDING-anonymous-grants.md), so the guids those
# actions need are enumerable without logging in.
#
# Every existing token test drives the PAGE: verify-anon-bad-token and
# verify-anon-token-value-gate prove a forged token does not render it, and
# verify-token-replay-refused proves a consumed one does not either. All three
# assert what rendered. None of them calls the action, so all three would stay
# green while this hole was open.
#
# THIS ALSO ANSWERS AN OPEN QUESTION. The security-finding doc records that it is
# not known whether Mendix Strict Mode is enabled on this app, which decides
# whether those client grants are reachable at all. This test settles it either
# way, and the answer determines how much of the rest of 85-security is real.
#
# WHAT IT ASSERTS
#   A. the anonymous session really is anonymous (no privileged module role), so
#      a later refusal cannot be a signed-in session being refused for some other
#      reason;
#   B. what anonymous can ENUMERATE of AwaitingCustomerApproval entries, reported
#      as a count and failed on if it is non-zero;
#   C. ACT_Customer_ApprovePage is refused for an entry anonymous holds no token
#      for;
#   D. ACT_Customer_RejectPage likewise;
#   E. and - the assertion that actually matters - the entry's Status is
#      UNCHANGED afterwards, read back as an entitled user. C and D assert that
#      the call did not visibly succeed; only E proves nothing happened. A
#      refused create and a call to a microflow that does not exist both return
#      "Internal server error" from this runtime, so the error string alone is
#      never evidence about access (see lib/_authz.sh, THE WRITE SIDE).
#
# SCOPE. Only entries belonging to consultants whose name starts "E2E " are
# touched, so this never acts on the Manual review data or on anyone's real work,
# and never asserts on a count it does not own.
#
# IF THIS TEST FAILS ON C, D OR E it is not a test defect. It means an
# unauthenticated caller can approve timesheets company-wide, and it belongs in
# front of Josh before anything else in this suite is looked at.
#
# Consumes: one AwaitingCustomerApproval entry, which it leaves as it found it
# unless the app is broken. Clears cookies, so it must not run between a login
# and an assertion that depends on it - 85-security is where that is safe.
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
PENDING="//Main.AssignmentEntry[$OWNED][Status='AwaitingCustomerApproval']"

# first_guid <xpath> — the guid of the first match, '' for none, ERR:<why>.
first_guid() {
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"$1\", filter:{amount:1}, callback:function(o){ clearTimeout(t); res((o&&o.length)?o[0].getGuid():''); }, error:function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

# ------------------------------------------------------- control, as an entitled user
tt_login "e2e_hr" "WEEKLY TO PROCESS"
note "control session roles: $(tt_authz_roles)"

GUID="$(first_guid "$PENDING")"
case "$GUID" in
  ERR:*) tt_fail "the control could not read AwaitingCustomerApproval entries ($GUID), so nothing below could be attempted" ;;
  "")    tt_fail "no E2E entry is awaiting customer approval, so there is nothing for an anonymous caller to attack and this step has no verdict. suites/30-approval creates one; run the suite in order." ;;
esac
BEFORE="$(tt_authz_readback "$PENDING" 'Status')"
note "target entry $GUID, Status before = $BEFORE"
[ "$BEFORE" = "AwaitingCustomerApproval" ] \
  || tt_fail "the control read Status='$BEFORE' for an entry selected on Status='AwaitingCustomerApproval' - the readback is not reading what this test thinks it is"

# --------------------------------------------------------------- A. become anonymous
ROLES="$(tt_authz_anonymous)"
note "anonymous session roles: $ROLES"
for privileged in Consultant ProjectManager HR TitanManager Administrator; do
  case "$ROLES" in
    *"\"$privileged\""*) bad "A: the 'anonymous' session still holds $privileged ($ROLES) - nothing below would mean anything" ;;
  esac
done

# --------------------------------------------------------------- B. what it can see
N="$(tt_authz_count "$PENDING")"
case "$N" in
  ERR:*) note "B ok: anonymous enumeration of AwaitingCustomerApproval was refused ($N)" ;;
  0)     note "B ok: anonymous retrieved 0 AwaitingCustomerApproval entries" ;;
  ''|*[!0-9]*) bad "B: the anonymous retrieve returned something that is not a count: [$N]" ;;
  *)     bad "B: anonymous retrieved $N AwaitingCustomerApproval entr(ies) without logging in - every guid an approve call needs is enumerable" ;;
esac

# ------------------------------------------------------ C/D. call the actions anyway
APPROVE="$(tt_authz_action 'Main.ACT_Customer_ApprovePage' "$GUID")"
case "$APPROVE" in
  ERR:*) note "C ok: ACT_Customer_ApprovePage did not visibly succeed ($APPROVE)" ;;
  *)     bad "C: ACT_Customer_ApprovePage returned [$APPROVE] to an anonymous caller holding no token" ;;
esac

REJECT="$(tt_authz_action 'Main.ACT_Customer_RejectPage' "$GUID")"
case "$REJECT" in
  ERR:*) note "D ok: ACT_Customer_RejectPage did not visibly succeed ($REJECT)" ;;
  *)     bad "D: ACT_Customer_RejectPage returned [$REJECT] to an anonymous caller holding no token" ;;
esac

# ------------------------------------------------- E. the only assertion that proves it
tt_login "e2e_hr" "WEEKLY TO PROCESS"
AFTER="$(tt_authz_readback "$PENDING" 'Status')"
case "$AFTER" in
  ERR:*) bad "E: could not read the entry back after the attempt ($AFTER), so this step cannot say whether anything moved" ;;
  "$BEFORE") note "E ok: Status is still $AFTER" ;;
  *)     bad "E: Status moved from $BEFORE to $AFTER while only an ANONYMOUS session acted on it" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-anon-approve-without-token — $fails problem(s). Read C/D/E before treating this as a test defect."
  exit 1
fi
echo "PASS: verify-anon-approve-without-token — anonymous could not approve or reject entry $GUID, and its Status is still $AFTER."
