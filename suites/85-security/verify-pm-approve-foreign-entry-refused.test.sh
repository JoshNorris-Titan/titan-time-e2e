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
#   E. the entry's Status is UNCHANGED, read back as administrator. C and D only say the
#      calls did not report success; this is the one that proves the hours did not
#      move to ToProcess and on towards an invoice.
#
# SCOPE. Only entries on projects whose manager is an E2E PM account, and only
# entries belonging to E2E consultants.
#
# IF C/D/E FAIL this is a project manager approving another project manager's
# work, which is the invoice boundary. It is a finding, not a flaky script.
#
# RED UNTIL MODEL FIX (2026-09-29). Once B could find its entry, C, D and E failed
# on dev in two separate runs: e2e_pm2, who cannot even retrieve the entry (count
# 0), called both actions with success and the entry went AwaitingManagerApproval
# -> ToProcess. Neither ACT_Page_Approve nor ACT_ApprovalHelper_Approve checks that
# the caller is the entry's project manager. The fix belongs in the model.
#
# SELF-SEEDING (2026-09-29). B used to fail with "no E2E entry is awaiting
# 'e2e_pm' approval" on every full run: 76-bulk/verify-pm-approve-all runs just
# before this suite and, by design, empties e2e_pm's whole queue. This step relied
# on 30-approval's leftovers surviving everything in between, so it only ever passed
# in a targeted run. When the queue is empty it now submits one entry on the
# manager-approval project as e2e_consultant - the same seeding block
# verify-pm-reject-action and verify-tt647-a1 use - and waits for it to arrive.
# B is still fatal if that seeding does not produce one.
#
# Consumes: one AwaitingManagerApproval entry (seeding one when there is none),
# left as found unless the app is broken.
# Env: TT_PM_SEED_PROJECT (default 'E2E Manager Approval', whose manager is e2e_pm),
#      TT_PM_SEED_USER (default e2e_consultant).
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
SEED_PROJECT="${TT_PM_SEED_PROJECT:-E2E Manager Approval}"  # managed by e2e_pm
SEED_USER="${TT_PM_SEED_USER:-e2e_consultant}"

PMPATH="Main.AssignmentEntry_Assignment/Main.Assignment/Main.Assignment_Project/Main.Project/Main.ProjectManager_Account/Administration.Account/Name"
OWNED="starts-with(Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName,'E2E ')"
TARGET="//Main.AssignmentEntry[$OWNED][$PMPATH = '$OWNER_PM'][Status = 'AwaitingManagerApproval']"

first_guid() {
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"$1\", filter:{amount:1}, callback:function(o){ clearTimeout(t); res((o&&o.length)?o[0].getGuid():''); }, error:function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

# ------------------------------------------------------------------- B. the control
# control_login - the session every CONTROL read (B and E) is taken in.
#
# ADMINISTRATOR, NOT HR (2026-09-29). TARGET walks Project -> ProjectManager_Account
# -> Account/Name, and taken as e2e_hr that retrieve came back EMPTY on dev while an
# entry on the manager-approval project was sitting in AwaitingManagerApproval (the
# diagnostics below printed both). A constraint through a member the session cannot
# read returns zero rows with no error, so as HR this control could never find
# anything and B failed on every run, full or targeted. verify-pm-approve-wrong-actor
# asks the SAME XPath as administrator for exactly this reason and passes. Only the
# control reads moved; A, C and D still run as the other PM, so what is asserted is
# unchanged.
control_login() { tt_login "${TT_ADMIN_USER:-MxAdmin}" "Welcome to your homepage" "${TT_ADMIN_PASS:-${TT_PASS:-}}"; }

control_login
GUID="$(first_guid "$TARGET")"
if [ -z "$GUID" ]; then
  # Nothing waiting on the owner PM - 76-bulk's Approve All emptied the queue. Make
  # one rather than depending on what earlier suites happened to leave behind.
  note "no entry awaiting '$OWNER_PM' - submitting one on '$SEED_PROJECT' as $SEED_USER"
  tt_login "$SEED_USER" "My Timesheets"
  tt_consultant_submit_project_row "$SEED_PROJECT"
  note "submitted week: ${TT_SUBMITTED_WEEK:-?}"
  # Routing into the approval status is asynchronous; poll rather than look once.
  # About three minutes, the same budget the 30-approval seeders get from six
  # re-logins with a 6 s pause each - this loop re-reads the data layer without
  # re-logging in, so it needs more tries for the same wait.
  control_login
  for _ in $(seq 1 20); do
    GUID="$(first_guid "$TARGET")"
    [ -n "$GUID" ] && break
    sleep 6
  done
  if [ -z "$GUID" ]; then
    # Say where it went instead: any E2E entry awaiting ANY manager, and the PM
    # name on the seeded project, so the failure names a cause.
    note "diagnostic: an E2E entry awaiting any manager: [$(first_guid "//Main.AssignmentEntry[$OWNED][Status = 'AwaitingManagerApproval']")]"
    note "diagnostic: an E2E entry on '$SEED_PROJECT' in any status: [$(first_guid "//Main.AssignmentEntry[$OWNED][Main.AssignmentEntry_Assignment/Main.Assignment/Main.Assignment_Project/Main.Project/Name = '$SEED_PROJECT']")]"
  fi
fi
case "$GUID" in
  ERR:*) tt_fail "the control could not look for an entry awaiting '$OWNER_PM' ($GUID)" ;;
  "")    tt_fail "no E2E entry is awaiting '$OWNER_PM' approval, even after submitting one on '$SEED_PROJECT' as $SEED_USER, so there is nothing for '$OTHER_PM' to wrongly approve and this step has no verdict. Check that '$SEED_PROJECT' still has ApprovalFromManager=Yes and '$OWNER_PM' as its manager (lib/_fixtures.sh)." ;;
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
control_login
AFTER="$(tt_authz_readback "$TARGET" 'Status')"
case "$AFTER" in
  ERR:notfound) bad "E: the entry is no longer awaiting '$OWNER_PM' - it left that status while only '$OTHER_PM' acted on it (entry $GUID now has Status=[$(tt_authz_readback "//Main.AssignmentEntry[id='$GUID']" 'Status')])" ;;
  ERR:*)        bad "E: could not read the entry back ($AFTER), so this step cannot say whether it moved" ;;
  "$BEFORE")    note "E ok: Status is still $AFTER" ;;
  *)            bad "E: Status moved from $BEFORE to $AFTER, approved by a PM it was not awaiting" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-pm-approve-foreign-entry-refused — $fails problem(s). C/D/E are findings about ACT_Page_Approve having no actor check."
  exit 1
fi
echo "PASS: verify-pm-approve-foreign-entry-refused — '$OTHER_PM' could not approve an entry awaiting '$OWNER_PM'; Status still $AFTER."
