#!/usr/bin/env bash
# Who may reject an entry, and when: HR at any status (by design), a project
# manager only while it awaits them.
#
# tt-timeout: 10m
#
# WHAT THE RULE IS (Josh, 2026-10-06; read from the 2026-10-06 build of
# Main.ACT_ApprovalHelper_Reject). Reject has two guards and NO status guard, on
# purpose:
#   1. "Left Comments?" - a RejectionComment must be present;
#   2. "May act on it?" - Main.SUB_AssignmentEntry_CanActOn: HR and Titan Manager
#      may always act (they reject at ToProcess / AwaitingExport by design); anyone
#      else only on an entry that is AwaitingManagerApproval on a project THEY
#      manage. Otherwise: "This entry is waiting on someone else's approval.
#      Refresh and try again."
# This spec used to assert that HR could NOT reject a ToProcess entry. That was the
# spec being wrong, not the app.
#
# WHAT IT ASSERTS
#   A. CONTROL: HR rejects an AwaitingManagerApproval entry and it reads Rejected -
#      proves the call shape, so C's refusal is attributable to the guard;
#   C. the project manager (e2e_pm, who manages 'E2E Manager Approval') calling the
#      same Reject on a ToProcess entry is refused with the CanActOn message and the
#      entry does not move - a PM's right ends once the entry leaves their queue;
#   B. HR calling Reject on that ToProcess entry moves it to Rejected - HR's
#      by-design right to send a processed week back.
# C runs before B so both act on the same ToProcess entry.
#
# WHAT MAKES IT RED. CanActOn letting a PM act outside AwaitingManagerApproval
# (C sees Rejected), or a status guard added that stops HR (B stays ToProcess).
#
# WHAT THIS CONSUMES. Two real rejections (the control and B) of E2E entries; the
# bookend clear removes them.
#
# THE CALL SHAPE (2026-10-06). Both calls used to hand ACT_ApprovalHelper_Reject
# an AssignmentEntry guid. Its parameter is a Main.ApprovalHelper, and the flow
# reaches the entry through ApprovalHelper_AssignmentEntry, so it never saw the
# entry at all: A failed on every run ("the control entry is AwaitingManagerApproval
# after a reject that returned [ok]", run 37409110184) and B could not fail. Both now
# build a (non-persistent) ApprovalHelper on the client pointing at the entry - the
# way DS_EntriesForTab and verify-pm-approve-foreign-entry-refused's D do - and call
# the action on the helper. The comment stays on the ENTRY: "Left Comments?" reads
# $AssignmentEntry/RejectionComment. Any message the flow shows (a refusal, "Please
# leave a comment") is read back and printed, because a refusal ends normally and
# returns [ok] exactly like a success.
#
# Consumes: one AwaitingManagerApproval and one ToProcess entry (both rejected).
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

# reject_via_helper <entryGuid> - call ACT_ApprovalHelper_Reject the way the HR
# dashboard does: on an ApprovalHelper whose ApprovalHelper_AssignmentEntry is the
# entry. Echoes ok, or ERR:create-/set-<why> when the helper could not be built (the
# question was never put), or ERR:action-<why> when the flow raised.
reject_via_helper() {
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),20000); mx.data.create({ entity: 'Main.ApprovalHelper', callback: function(h){ try { h.set('Main.ApprovalHelper_AssignmentEntry', '$1'); } catch(e){ clearTimeout(t); return res('ERR:set-'+e.message); } mx.data.action({ params: { applyto: 'selection', actionname: 'Main.ACT_ApprovalHelper_Reject', guids: [h.getGuid()] }, callback: function(r){ clearTimeout(t); res('ok'); }, error: function(e){ clearTimeout(t); res('ERR:action-'+((e&&e.message)||'refused')); } }); }, error: function(e){ clearTimeout(t); res('ERR:create-'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

# dialog_text_dismiss - the topmost visible dialog's text (empty when none came up
# within ~5 s), then its OK/Close, so the next call is not behind a modal.
dialog_text_dismiss() {
  local d t _
  d="$(_tt_dialog_js)"
  for _ in $(seq 1 5); do
    t="$(playwright-cli eval "() => { const d=$d; return d ? (d.innerText||'').replace(/\s+/g,' ').trim() : ''; }" 2>/dev/null | _tt_eval_str)"
    [ -n "$t" ] && break
    sleep 1
  done
  [ -n "$t" ] && playwright-cli eval "() => { const d=$d; if(!d) return 'none'; const b=[...d.querySelectorAll('button')].filter(x=>x.offsetParent!==null).find(x=>/^(ok|close)\$/i.test((x.innerText||'').trim())); if(b){ b.click(); return 'clicked'; } return 'nobutton'; }" >/dev/null 2>&1
  sleep 1
  printf '%s' "$t"
}

tt_login "e2e_hr" "$TT_HR_READY"
note "session roles: $(tt_authz_roles)"

# ------------------------------------------------------------------ A. the control
CTRL_GUID="$(first_guid "$AWAITING")"
case "$CTRL_GUID" in
  ERR:*) tt_fail "could not look for an entry awaiting manager approval ($CTRL_GUID)" ;;
  "")    tt_fail "no E2E entry is awaiting manager approval, so the reject call shape cannot be proven to work and B would be unattributable. suites/30-approval creates one; run the suite in order." ;;
esac
note "control entry $CTRL_GUID (AwaitingManagerApproval)"

# The flow needs a comment present; set it the way the page would before calling.
W="$(tt_authz_write "//Main.AssignmentEntry[id='$CTRL_GUID']" 'RejectionComment' 'e2e: proving the reject call shape works')"
[ "$W" = "ok" ] || tt_fail "could not set RejectionComment on the control entry as HR ($W), so the reject would stop at 'Left Comments?' and A has no verdict"
CTRL="$(reject_via_helper "$CTRL_GUID")"
CTRL_MSG="$(dialog_text_dismiss)"
[ -n "$CTRL_MSG" ] && note "A: the flow showed: '$CTRL_MSG'"
sleep 2
CTRL_AFTER="$(status_of "$CTRL_GUID")"
if [ "$CTRL_AFTER" = "Rejected" ]; then
  note "A ok: the control entry moved to Rejected, so the call shape works ($CTRL)"
else
  bad "A: the control entry is $CTRL_AFTER after a reject that returned [$CTRL] (dialog: '${CTRL_MSG:-none}'). The call shape is unproven, so B below cannot distinguish a guard from a bad call - treat B's result as inconclusive."
fi

# ---------------------------------------------- the ToProcess target (as HR)
PM_USER="${TT_REJECT_PM:-e2e_pm}"
PM_PROJECT="${TT_REJECT_PM_PROJECT:-E2E Manager Approval}"
TARGET_GUID="$(first_guid "//Main.AssignmentEntry[$OWNED][Status='ToProcess'][Main.AssignmentEntry_Assignment/Main.Assignment/Main.Assignment_Project/Main.Project/Name='$PM_PROJECT']")"
case "$TARGET_GUID" in
  ERR:*) tt_fail "could not look for a ToProcess entry ($TARGET_GUID)" ;;
  "")    TARGET_GUID="$(first_guid "$SETTLED")"
         note "(no ToProcess entry on '$PM_PROJECT'; using another E2E ToProcess entry - C then shows the not-your-project half of the rule)" ;;
esac
case "$TARGET_GUID" in
  ERR:*|"") tt_fail "no E2E entry is in ToProcess ($TARGET_GUID), so there is nothing to reject at that status. suites/30-approval and 40-hr produce them; run the suite in order." ;;
esac
BEFORE="$(status_of "$TARGET_GUID")"
[ "$BEFORE" = "ToProcess" ] || tt_fail "the target reads [$BEFORE], not ToProcess"
note "target entry $TARGET_GUID, Status before = $BEFORE"
W="$(tt_authz_write "//Main.AssignmentEntry[id='$TARGET_GUID']" 'RejectionComment' 'e2e: reject at ToProcess')"
[ "$W" = "ok" ] || tt_fail "could not set RejectionComment on the target as HR ($W), so a refusal below would be 'Left Comments?' - no verdict"

# ------------------------------------------------- C. the PM, outside their queue
tt_login "$PM_USER" "Project Manager Dashboard"
note "PM session roles: $(tt_authz_roles)"
R="$(reject_via_helper "$TARGET_GUID")"
R_MSG="$(dialog_text_dismiss)"
sleep 2
tt_login "e2e_hr" "$TT_HR_READY"
AFTER="$(status_of "$TARGET_GUID")"
case "$AFTER" in
  ToProcess)
    case "$R_MSG" in
      *"waiting on someone else"*) note "C ok: $PM_USER was refused ('$R_MSG') and the entry is still ToProcess" ;;
      *) bad "C: the entry did not move, but the refusal was not CanActOn's ([$R] dialog: '${R_MSG:-none}') - the guard is unproven" ;;
    esac ;;
  *) bad "C: $PM_USER, a project manager, moved a ToProcess entry to $AFTER - CanActOn should limit a PM to AwaitingManagerApproval on their own projects ([$R] '${R_MSG:-none}')" ;;
esac

# ------------------------------------------------- B. HR, at ToProcess (by design)
R="$(reject_via_helper "$TARGET_GUID")"
R_MSG="$(dialog_text_dismiss)"
[ -n "$R_MSG" ] && note "B: the flow showed: '$R_MSG'"
sleep 2
AFTER="$(status_of "$TARGET_GUID")"
case "$AFTER" in
  Rejected) note "B ok: HR rejected the ToProcess entry, as designed (the call returned $R)" ;;
  *) bad "B: HR's Reject left the ToProcess entry at [$AFTER] ([$R] '${R_MSG:-none}') - HR is meant to be able to send a processed week back" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-hr-reject-wrong-status-refused — $fails problem(s) with who may reject an entry, and when."
  exit 1
fi
echo "PASS: verify-hr-reject-wrong-status-refused — HR rejects at AwaitingManagerApproval and at ToProcess; the project manager is refused once the entry has left their queue."
