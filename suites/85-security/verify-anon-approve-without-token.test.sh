#!/usr/bin/env bash
# An unauthenticated session must not be able to approve or reject a timesheet
# entry it holds no token for.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS. Main.ACT_Customer_ApprovePage, ACT_Customer_ApproveHelper and
# ACT_Customer_RejectPage are marked "May be called from the client by:
# Anonymous" - they have to be, the customer never signs in. Before the
# customer-link security change (2026-09-29) their only guard was
# Status = AwaitingCustomerApproval, and Anonymous held an unconstrained read on
# Main.AssignmentEntry narrowed to that status, so the guids those actions need
# were enumerable without logging in and nothing tied an action to a token.
#
# SINCE THAT CHANGE each of them first asks Main.SUB_CustomerToken_CoversEntry
# whether the link THIS SESSION opened covers the entry (a live Main.ApprovalVisit
# for the session's own user, on the entry's project, with an Active unexpired
# token). When it does not, the action shows "This approval link is no longer
# valid..." and ENDS NORMALLY - it is not an error on the wire. And Anonymous may
# now read an entry only through such a visit, so a session that never opened a
# link can enumerate nothing (B).
#
# THAT IS WHY C AND D NO LONGER JUDGE THE ANSWER. They used to pass on ERR: and
# fail on anything else, which is exactly backwards for a correct app: a refusal
# that ends normally comes back 'ok', and an ERR: is what a missing parameter or a
# runtime that never reached the microflow produces too. The answer is now logged
# as evidence only. What decides C and D is E: the entry's Status AND its number
# of Main.ChangeLog rows, read back as HR by guid, must both be unchanged - every
# approve and reject path writes a ChangeLog row, so a count that moved is an
# action that ran even if the Status happened to land back where it was. When the
# refusal dialog does appear it is reported, but it is not required: this caller
# has no page and no visit, so the runtime may refuse before the microflow ever
# runs, and that is a correct outcome too.
#
# NOT COVERED HERE: a caller who HAS a visit, acting on an entry outside it (the
# cross-approver case). The actions take the entry AND the page's
# CustomerApprovalHelper, and lib/_authz.sh can pass one object only
# (tt_authz_action applies to a single selected guid), so the second parameter
# would always be empty and the refusal would come from the "inputs given?" check
# rather than from the cross-approver rule. See the PR that added
# verify-anon-visit-read-scope, which covers the READ half of that case instead.
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
#   C. ACT_Customer_ApprovePage, called on that entry by this visit-less session,
#      changes nothing;
#   D. ACT_Customer_RejectPage likewise;
#   E. the proof for C and D: read back as HR BY GUID, the entry's Status and its
#      Main.ChangeLog row count are both exactly what they were before. The call's
#      own answer ('ok', 'ok:<x>' or ERR:) is logged and never judged - see WHY
#      THIS EXISTS. A refusal dialog, when one renders, is logged as well.
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

# log_count <guid> — Main.ChangeLog rows on one entry, as the CURRENT session (HR).
log_count() {
  tt_authz_count "//Main.ChangeLog[Main.ChangeLog_AssignmentEntry = '$1']"
}

# refusal_shown — the refusal dialog's text if one is on screen, else ''.
refusal_shown() {
  playwright-cli eval "() => { const d=[...document.querySelectorAll('$TT_DIALOG_SEL')].filter(x=>x.offsetParent!==null).pop(); const t=d ? (d.innerText||'').replace(/\s+/g,' ').trim() : ''; return /no longer valid/i.test(t) ? t.slice(0,160) : ''; }" 2>/dev/null | _tt_eval_str
}

# ------------------------------------------------------- control, as an entitled user
tt_login "e2e_hr" "$TT_HR_READY"
note "control session roles: $(tt_authz_roles)"

GUID="$(first_guid "$PENDING")"
case "$GUID" in
  ERR:*) tt_fail "the control could not read AwaitingCustomerApproval entries ($GUID), so nothing below could be attempted" ;;
  "")    tt_fail "no E2E entry is awaiting customer approval, so there is nothing for an anonymous caller to attack and this step has no verdict. suites/30-approval creates one; run the suite in order." ;;
esac
# Every readback from here on is BY GUID. It used to re-run the PENDING query and
# read the first match, which after a successful attack would silently be a
# DIFFERENT entry - one still pending - and E would have reported "unchanged".
ONE="//Main.AssignmentEntry[id = '$GUID']"
BEFORE="$(tt_authz_readback "$ONE" 'Status')"
LOGS_BEFORE="$(log_count "$GUID")"
note "target entry $GUID, Status before = $BEFORE, change-log rows before = $LOGS_BEFORE"
[ "$BEFORE" = "AwaitingCustomerApproval" ]   || tt_fail "the control read Status='$BEFORE' for an entry selected on Status='AwaitingCustomerApproval' - the readback is not reading what this test thinks it is"
case "$LOGS_BEFORE" in
  ''|*[!0-9]*) tt_fail "the control could not count the entry's change-log rows ([$LOGS_BEFORE]), so E could not tell an action that ran from one that did not" ;;
esac
[ "$LOGS_BEFORE" -gt 0 ]   || tt_fail "an entry awaiting customer approval has NO change-log rows as HR reads it - its submit wrote one - so the count cannot be what this test thinks it is"

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
  *)     bad "B: anonymous retrieved $N AwaitingCustomerApproval entr(ies) without opening any approval link - every guid an approve call needs is enumerable" ;;
esac

# ------------------------------------------------------ C/D. call the actions anyway
# The answers are EVIDENCE, not verdicts - E decides. See the header.
APPROVE="$(tt_authz_action 'Main.ACT_Customer_ApprovePage' "$GUID")"
note "C: ACT_Customer_ApprovePage answered [$APPROVE]"
MSG="$(refusal_shown)"
if [ -n "$MSG" ]; then note "C: the refusal was shown: $MSG"; else note "C: no refusal dialog rendered (expected when the runtime refuses before the microflow runs)"; fi
tt_clear_dialogs 4 >/dev/null 2>&1

REJECT="$(tt_authz_action 'Main.ACT_Customer_RejectPage' "$GUID")"
note "D: ACT_Customer_RejectPage answered [$REJECT]"
MSG="$(refusal_shown)"
if [ -n "$MSG" ]; then note "D: the refusal was shown: $MSG"; else note "D: no refusal dialog rendered"; fi
tt_clear_dialogs 4 >/dev/null 2>&1

# ------------------------------------------------- E. the only assertion that proves it
tt_login "e2e_hr" "$TT_HR_READY"
AFTER="$(tt_authz_readback "$ONE" 'Status')"
LOGS_AFTER="$(log_count "$GUID")"
case "$AFTER" in
  ERR:*) bad "E: could not read the entry back after the attempt ($AFTER), so this step cannot say whether anything moved" ;;
  "$BEFORE") note "E ok: Status is still $AFTER" ;;
  *)     bad "E: Status moved from $BEFORE to $AFTER while only an ANONYMOUS session with no approval link acted on it (C answered [$APPROVE], D answered [$REJECT])" ;;
esac
case "$LOGS_AFTER" in
  ''|*[!0-9]*) bad "E: could not count the entry's change-log rows after the attempt ([$LOGS_AFTER])" ;;
  "$LOGS_BEFORE") note "E ok: the entry still has $LOGS_AFTER change-log row(s)" ;;
  *)     bad "E: the entry's change-log rows went from $LOGS_BEFORE to $LOGS_AFTER - an approve or reject RAN for a session that never opened a link (C answered [$APPROVE], D answered [$REJECT])" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-anon-approve-without-token — $fails problem(s). Read B and E before treating this as a test defect."
  exit 1
fi
echo "PASS: verify-anon-approve-without-token — an anonymous session with no approval link could not approve or reject entry $GUID: Status is still $AFTER and its change log still holds $LOGS_AFTER row(s)."
