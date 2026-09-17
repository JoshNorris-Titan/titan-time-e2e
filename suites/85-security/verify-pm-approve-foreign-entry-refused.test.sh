#!/usr/bin/env bash
# A project manager must not be able to approve an entry that is awaiting a
# DIFFERENT project manager's approval.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS. Main.ACT_Page_Approve is callable from the client by HR,
# ProjectManager and TitanManager, and its only guard is the entry's Status. There
# is no actor check anywhere in it. The scoping that makes the PM dashboard look
# safe lives in DS_ApprovalHelper_PM's XPath - in the DATASOURCE that feeds the
# page, not in the action - so it constrains what a PM is SHOWN, not what a PM can
# CALL.
#
# suites/30-approval/verify-pm-approve-wrong-actor.test.sh is the closest existing
# test and it stops exactly where this one starts: it counts what PM B can
# RETRIEVE, never attempts the approval, and says in its own failure text that
# "the fix belongs on the access rule". Counting a datasource proves the page is
# scoped. It cannot prove the action is.
#
# WHAT IT ASSERTS
#   A. the session holds ProjectManager and is the PM who does NOT own the entry;
#   B. an entry exists that is awaiting the OTHER PM's approval - established as a
#      control, and fatal if absent, because everything below is vacuous without
#      it;
#   C. ACT_Page_Approve does not visibly succeed for the foreign PM;
#   D. ACT_ApprovalHelper_Approve likewise - the sibling that the dashboard button
#      actually routes through;
#   E. the entry's Status is UNCHANGED, read back as HR. C and D only say the
#      calls did not report success; this is the one that proves the hours did not
#      move to ToProcess and on towards an invoice.
#
# SCOPE. Only entries on projects whose manager is an E2E PM account, and only
# entries belonging to E2E consultants.
#
# IF C/D/E FAIL this is a project manager approving another project manager's
# work, which is the invoice boundary. It is a finding, not a flaky script.
#
# Consumes: one AwaitingManagerApproval entry, left as found unless the app is
# broken.
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

OWNER_PM="${TT_PM_OWNER:-e2e_pm}"      # the PM the entry is waiting on
OTHER_PM="${TT_PM_OTHER:-e2e_pm2}"     # the PM who must not be able to approve it

PMPATH="Main.AssignmentEntry_Assignment/Main.Assignment/Main.Assignment_Project/Main.Project/Main.ProjectManager_Account/Administration.Account/Name"
OWNED="starts-with(Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName,'E2E ')"
TARGET="//Main.AssignmentEntry[$OWNED][$PMPATH = '$OWNER_PM'][Status = 'AwaitingManagerApproval']"

first_guid() {
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"$1\", filter:{amount:1}, callback:function(o){ clearTimeout(t); res((o&&o.length)?o[0].getGuid():''); }, error:function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

# ------------------------------------------------------------------- B. the control
tt_login "e2e_hr" "WEEKLY TO PROCESS"
GUID="$(first_guid "$TARGET")"
case "$GUID" in
  ERR:*) tt_fail "the control could not look for an entry awaiting '$OWNER_PM' ($GUID)" ;;
  "")    tt_fail "no E2E entry is awaiting '$OWNER_PM' approval, so there is nothing for '$OTHER_PM' to wrongly approve and this step has no verdict. suites/30-approval creates one; run the suite in order." ;;
esac
BEFORE="$(tt_authz_readback "$TARGET" 'Status')"
note "target $GUID awaiting $OWNER_PM, Status before = $BEFORE"
[ "$BEFORE" = "AwaitingManagerApproval" ] \
  || tt_fail "readback says Status='$BEFORE' for an entry selected on AwaitingManagerApproval - the readback is not reading what this test thinks it is"

# --------------------------------------------------------------- A. be the other PM
tt_login "$OTHER_PM" "Project Manager Dashboard"
ROLES="$(tt_authz_roles)"
note "session roles: $ROLES"
case "$ROLES" in
  *'"ProjectManager"'*) : ;;
  *) bad "A: '$OTHER_PM' does not hold ProjectManager ($ROLES)" ;;
esac
case "$ROLES" in
  *'"HR"'*|*'"TitanManager"'*|*'"Administrator"'*)
    bad "A: '$OTHER_PM' also holds an elevated role ($ROLES), so a success below would not prove the PM grant is too wide" ;;
esac

# A PM who can already SEE it would be a different finding; say which world we are in.
SEEN="$(tt_authz_count "$TARGET")"
note "entries awaiting $OWNER_PM that $OTHER_PM can retrieve: $SEEN"

# ----------------------------------------------------------- C/D. call the actions
A1="$(tt_authz_action 'Main.ACT_Page_Approve' "$GUID")"
case "$A1" in
  ERR:*) note "C ok: ACT_Page_Approve did not visibly succeed for $OTHER_PM ($A1)" ;;
  *)     bad "C: ACT_Page_Approve returned [$A1] for '$OTHER_PM' on an entry awaiting '$OWNER_PM'" ;;
esac

A2="$(tt_authz_action 'Main.ACT_ApprovalHelper_Approve' "$GUID")"
case "$A2" in
  ERR:*) note "D ok: ACT_ApprovalHelper_Approve did not visibly succeed for $OTHER_PM ($A2)" ;;
  *)     bad "D: ACT_ApprovalHelper_Approve returned [$A2] for '$OTHER_PM' on an entry awaiting '$OWNER_PM'" ;;
esac

# ------------------------------------------------------------------ E. did it move?
tt_login "e2e_hr" "WEEKLY TO PROCESS"
AFTER="$(tt_authz_readback "$TARGET" 'Status')"
case "$AFTER" in
  ERR:notfound) bad "E: the entry is no longer awaiting '$OWNER_PM' - it left that status while only '$OTHER_PM' acted on it" ;;
  ERR:*)        bad "E: could not read the entry back ($AFTER), so this step cannot say whether it moved" ;;
  "$BEFORE")    note "E ok: Status is still $AFTER" ;;
  *)            bad "E: Status moved from $BEFORE to $AFTER, approved by a PM it was not awaiting" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-pm-approve-foreign-entry-refused — $fails problem(s). C/D/E are findings about ACT_Page_Approve having no actor check."
  exit 1
fi
echo "PASS: verify-pm-approve-foreign-entry-refused — '$OTHER_PM' could not approve an entry awaiting '$OWNER_PM'; Status still $AFTER."
