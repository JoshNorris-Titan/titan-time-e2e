#!/usr/bin/env bash
# A customer's approval page that is ALREADY OPEN stops being able to approve the
# moment its link stops covering the entry - the page does not carry the
# permission it was opened with.
#
# tt-timeout: 12m
#
# WHY THIS EXISTS. Every action on the customer's review popup (Approve, Reject,
# View, the per-row Approve, the downloads) now re-asks, at the moment it runs,
# whether the link this session opened still covers the entry
# (Main.SUB_CustomerToken_CoversEntry: a live visit for this session's user, a token
# still Active and unexpired, and the entry's project still covered and not
# archived). Before the customer-link security change (2026-09-29) the only check
# was the entry's status, so a page opened while a link was good kept working
# after the link was withdrawn, for as long as the tab stayed open. The other token
# specs all start from a FRESH page load, which only proves the check at the door;
# this one proves it at the button.
#
# HOW THE LINK IS WITHDRAWN, AND WHY NOT BY EXPIRING THE TOKEN. The obvious lever -
# expire or revoke the token from an admin session - does not exist, by design:
# Main.ApprovalToken has NO access rule for any role, Administrator included
# (verify-role-token-denial asserts exactly that), and no page or action lets staff
# expire one; a token ends only at its own ExpiresAt. Granting a rule so that this
# step could reach it would weaken the thing under test. So coverage is withdrawn
# the one way staff legitimately can: HR ARCHIVES THE PROJECT (Main.Project.Archived
# is writable by HR, TitanManager and Administrator). SUB_CustomerToken_CoversEntry
# requires [Archived = false()] on the covered project, so this takes the same
# "Link covers entry?" = false branch an expired or revoked token takes, and shows
# the same refusal. The literally-expired case needs a model-side test hook (the
# same Test Data action verify-approval-token-invariants is waiting for) and is
# left to the unit tests in Core's "995. Unit Tests" until one exists.
#
# TWO BROWSERS. The visitor's page must stay open while HR acts, and this suite
# otherwise runs in one shared browser whose cookies a staff sign-in would replace.
# HR works in a second, named playwright-cli session (lib/_customer_link.sh,
# cl_staff_*), which an EXIT trap always closes - and the same trap un-archives the
# project, so a failure half way cannot leave the suite's customer-approval
# project archived for every step after this one.
#
# WHAT IT ASSERTS
#   A. the link opens and the review popup for OUR entry (consultant + week, and the
#      popup names the project) shows an Approve button;
#   B. HR archives the project, and reads Archived back as true;
#   C. pressing Approve on the page that was already open shows the refusal
#      ("This approval link is no longer valid...");
#   D. read back as HR by guid: Status is still AwaitingCustomerApproval and the
#      entry's change-log row count is unchanged - C's dialog alone could sit on
#      top of an approval that went through.
#
# RED / UNPROVEN UNTIL THE CHANGE IS DEPLOYED: before it, C approves the entry.
#
# Consumes: nothing when the app is right (the entry is left pending and the
# project un-archived). If the app is wrong it approves one E2E Consultant entry on
# E2E Customer Approval - which is the finding. Clears cookies - safe in 85-security.
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

CONSULTANT_NAME="E2E Consultant"
PROJECT="E2E Customer Approval"
APPROVER="$FX_APPROVER_EMAIL"
PROJECT_XP="//Main.Project[Name = '$PROJECT']"

ARCHIVED_BY_US=""
STAFF_OPEN=""

# set_archived <true|false> — write Main.Project.Archived on $PROJECT and commit, as
# the CURRENT session (run it through cl_staff). Echoes ok, ERR:notfound or ERR:<why>.
# Not tt_authz_write: that helper sets every value as a STRING, and Archived is a
# Boolean - the client would refuse or coerce "false" in a way nobody has measured.
set_archived() {
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"$PROJECT_XP\", filter:{amount:2}, callback:function(o){ if(!o||o.length!==1){ clearTimeout(t); return res(o&&o.length ? 'ERR:ambiguous-'+o.length : 'ERR:notfound'); } try { o[0].set('Archived', $1); } catch(e){ clearTimeout(t); return res('ERR:set-'+e.message); } mx.data.commit({ mxobj:o[0], callback:function(){ clearTimeout(t); res('ok'); }, error:function(e){ clearTimeout(t); res('ERR:commit-'+((e&&e.message)||'refused')); } }); }, error:function(e){ clearTimeout(t); res('ERR:retrieve-'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

# restore — un-archive the project if this step archived it, and close the second
# browser. Runs on EVERY exit, including tt_fail's.
restore() {
  local r
  if [ -n "$ARCHIVED_BY_US" ]; then
    r="$(cl_staff set_archived false)"
    if [ "$r" = "ok" ]; then
      echo "  restored: '$PROJECT' is un-archived"
    else
      echo "  WARNING: could not un-archive '$PROJECT' ($r). Every later step that needs it will fail until it is un-archived by hand (TM dashboard -> Projects)." >&2
    fi
  fi
  [ -n "$STAFF_OPEN" ] && cl_staff_close
  return 0
}
trap restore EXIT

# --------------------------------------------------------- 1. a live link, from mail
cl_fresh_link "$CONSULTANT_NAME" "$PROJECT" "$APPROVER"
WEEKKEY="$(tt_week_key "$CL_WEEK")"
[ -n "$WEEKKEY" ] || tt_fail "could not read a week range out of HR's week label '$CL_WEEK'"

# --------------------------------------------- 2. the staff browser, and the control
cl_staff_open
STAFF_OPEN=1
cl_staff tt_login "e2e_hr" "$TT_HR_READY"
GUID="$(cl_staff cl_entry_guid "$CONSULTANT_NAME" "$PROJECT" "$WEEKKEY")"
case "$GUID" in
  ERR:*) tt_fail "HR could not read the entry under test ($GUID)" ;;
  "")    tt_fail "HR finds no AwaitingCustomerApproval entry for '$CONSULTANT_NAME' / '$PROJECT' in week '$WEEKKEY' - the one it just reminded" ;;
esac
S_BEFORE="$(cl_staff cl_entry_status "$GUID")"
L_BEFORE="$(cl_staff cl_log_count "$GUID")"
echo "  entry $GUID: Status $S_BEFORE, $L_BEFORE change-log row(s)"
[ "$S_BEFORE" = "AwaitingCustomerApproval" ] || tt_fail "the entry under test reads Status '$S_BEFORE' before anything was done"
case "$L_BEFORE" in ''|*[!0-9]*) tt_fail "could not count the entry's change-log rows ([$L_BEFORE])" ;; esac
ARCH_BEFORE="$(cl_staff tt_authz_readback "$PROJECT_XP" 'Archived')"
[ "$ARCH_BEFORE" = "false" ] || tt_fail "'$PROJECT' reads Archived='$ARCH_BEFORE' before this step touched it - the fixture is not in the state every customer-approval step needs"

# ------------------------------------ 3. A: the visitor opens the link and the entry
cl_open_link_cold "$CL_LINK" || tt_fail "the approval link did not open an approval page: $CL_LINK"
opened="$(tt_token_open_row "$CONSULTANT_NAME" "$CL_WEEKFRAG")"
case "$opened" in
  hit) ;;
  nomatch) tt_token_log_rows "$CONSULTANT_NAME"; tt_fail "the link lists entries but none for '$CONSULTANT_NAME' in week '$CL_WEEK'" ;;
  *) tt_fail "the link lists no pending entries at all" ;;
esac
tt_wait_for ".mx-name-btnCustomerApprove" "the client Approve button on the review popup"
POPUP="$(tt_token_popup_text)"
case "$POPUP" in
  *"$PROJECT"*) echo "  A: review popup open on '$PROJECT', Approve offered" ;;
  *) tt_fail "the opened entry is not on '$PROJECT' - refusing to go further: $POPUP" ;;
esac

# ------------------------------------------- 4. B: HR withdraws the link's coverage
r="$(cl_staff set_archived true)"
[ "$r" = "ok" ] || tt_fail "HR could not archive '$PROJECT' ($r), so the link's coverage was never withdrawn and C would prove nothing"
ARCHIVED_BY_US=1
[ "$(cl_staff tt_authz_readback "$PROJECT_XP" 'Archived')" = "true" ] \
  || tt_fail "HR's archive of '$PROJECT' did not read back as true"
echo "  B: '$PROJECT' archived by HR while the visitor's popup stays open"

# ------------------------------------------ 5. C: Approve on the page already open
clicked="$(playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnCustomerApprove'); if(!b) return 'missing'; if(b.disabled) return 'disabled'; b.click(); return 'clicked'; }" 2>/dev/null | _tt_eval_str)"
[ "$clicked" = "clicked" ] || tt_fail "could not press Approve on the open popup (state: $clicked)"
fails=0
if MSG="$(cl_await_refusal 20 "Approve")"; then
  echo "  C: the open page refused: $MSG"
else
  echo "  FAILED: C: pressing Approve on the already-open page did not show the refusal. Last dialog: $MSG"
  fails=$((fails+1))
fi
cl_dismiss_refusal >/dev/null

# ------------------------------------------------ 6. D: nothing moved, read as HR
S_AFTER="$(cl_staff cl_entry_status "$GUID")"
L_AFTER="$(cl_staff cl_log_count "$GUID")"
if [ "$S_AFTER" != "$S_BEFORE" ]; then
  echo "  FAILED: D: the entry's Status moved from $S_BEFORE to $S_AFTER after Approve was pressed on a page whose link no longer covers it"
  fails=$((fails+1))
fi
if [ "$L_AFTER" != "$L_BEFORE" ]; then
  echo "  FAILED: D: the entry's change-log rows went from $L_BEFORE to $L_AFTER - the approval ran"
  fails=$((fails+1))
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-anon-expired-link-mid-visit — $fails problem(s): an approval page left open outlives the link that opened it."
  exit 1
fi
echo "PASS: verify-anon-expired-link-mid-visit — once HR archived '$PROJECT', Approve on the page already open was refused, and entry $GUID is still $S_AFTER with $L_AFTER change-log row(s)"
