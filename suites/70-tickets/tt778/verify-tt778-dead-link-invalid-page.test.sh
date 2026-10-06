#!/usr/bin/env bash
# tt-timeout: 12m
# verify-tt778-dead-link-invalid-page.test.sh
#
# TT-778 #1: a real, unexpired approval link whose approver no longer covers any
# project lands on the invalid-link page - never on the approval page, and never on
# the retired "replaced each time a new approval request is sent" copy.
#
# WHY THIS EXISTS. TT-744 replaced the invalid-link page, but links sent in early
# September still opened something else: the token was valid, so the door let the
# visitor through, and only the customer's actions found out the link covered
# nothing - with the old message TT-744 had removed because it is wrong. TT-778
# (model 73b0683b) moved that check to the door: Main.NAV_Email_RecieveToken sends a
# link that covers no project to Main.Customer_LinkInvalid and records no visit, and
# the four customer actions open the same page instead of the retired message.
#
# verify-anon-bad-token covers a MALFORMED token, which always reached the invalid
# page. This covers the case that did not: a well-formed token from a real email,
# still inside its 7-day lifetime, whose approver's only project is archived - the
# unit test UT_NAV_RecieveToken_LinkCoveringNoProjectRecordsNoVisit pins the flow;
# this pins what a customer actually sees.
#
# ITS OWN DATA. A throwaway project with its own synthetic approver address
# (tt_mail_address, so no real mail and no shared remind gate), assigned to
# 'E2E Consultant Three' - in TT_E2E_CONSULTANTS and driven by no fixture spec - so
# the deep clear in 99-teardown deletes it. The fixture approver and projects are
# never touched, which is why this does not archive E2E Customer Approval the way
# #144's mid-visit spec has to.
#
# WHAT IT ASSERTS
#   A. control (fatal): before the archive, the link opens the approval page and
#      lists Three's pending row - so it is a working link, not a malformed one;
#   B. after HR archives the project, the SAME link, opened cold, shows
#      textLinkInvalidHeading, and neither the approval list (galPendingEntries) nor
#      the "nothing to approve" state (containerNoPendingApprovals);
#   C. the page reads "no longer valid" and does not carry the retired "replaced each
#      time" copy.
#
# WHAT MAKES IT RED. The link check going back to "token valid = let them in" (B
# sees the approval page, or its empty state), or the old copy coming back (C).
#
# Clears cookies (the visitor opens the link signed out); the next step signs in
# again through tt_login, as after every token spec.
# Consumes: one project, one assignment, one submitted week for E2E Consultant
# Three, one customer reminder to a synthetic address.
# Env: TT_BASE_URL, TT_ROLE_PASS, TT_ADMIN_USER, TT_ADMIN_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/lib/_authz.sh"

STAMP="$(date +%s)"
PZ="E2E TT778 Link $STAMP"
APPROVER="$(tt_mail_address "tt778-$STAMP")"
CNAME="E2E Consultant Three"
CUSER="e2e_consultant3"
PROJECT_XP="//Main.Project[Name = '$PZ']"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

# set_archived <true|false> - Main.Project.Archived is a Boolean, so it is set as one
# (tt_authz_write sets a string). Same shape as #144's mid-visit spec.
set_archived() {
  ev "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"$PROJECT_XP\", filter:{amount:2}, callback: o => { if(!o||o.length!==1){ clearTimeout(t); return res(o&&o.length ? 'ERR:ambiguous-'+o.length : 'ERR:notfound'); } try { o[0].set('Archived', $1); } catch(e){ clearTimeout(t); return res('ERR:set-'+e.message); } mx.data.commit({ mxobj:o[0], callback: () => { clearTimeout(t); res('ok'); }, error: e => { clearTimeout(t); res('ERR:commit-'+((e&&e.message)||'refused')); } }); }, error: e => { clearTimeout(t); res('ERR:retrieve-'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })"
}

# archive_all <xpath> - set Archived=true (a Boolean) on every match and commit.
archive_all() {
  ev "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),30000); const commit=x=>new Promise((ok,ko)=>mx.data.commit({ mxobj:x, callback:ok, error:ko })); mx.data.get({ xpath: \"$1\", filter:{amount:20}, callback: async o => { if(!o||!o.length){ clearTimeout(t); return res('ERR:notfound'); } try { for (const x of o) { x.set('Archived', true); await commit(x); } clearTimeout(t); res('ok:'+o.length); } catch(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }, error: e => { clearTimeout(t); res('ERR:retrieve-'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })"
}

# The assignment is archived on exit as well as the project: an unarchived
# assignment on an archived project would still give E2E Consultant Three a gap in
# every past week, which the tt779 Pending-tab spec after this one would count.
cleanup() {
  tt_login "e2e_tm" "Add Customer" >/dev/null 2>&1 || return 0
  archive_all "//Main.Assignment[Main.Assignment_Project/Main.Project/Name = '$PZ']" >/dev/null
  archive_all "$PROJECT_XP" >/dev/null
  echo "  (archived '$PZ' and its assignment; the teardown clear of '$CNAME' deletes them)"
}
trap cleanup EXIT

# page_state - what the link's page shows: INVALID, LIST:<rows>, EMPTY or WAIT.
page_state() {
  ev "() => { const q=n=>document.querySelector('.mx-name-'+n); if(q('textLinkInvalidHeading')) return 'INVALID'; const g=q('galPendingEntries'); if(g){ const rows=[...g.querySelectorAll('.widget-gallery-item')].map(r=>(r.innerText||'').replace(/\\s+/g,' ').trim()); return 'LIST:'+rows.join(' / '); } if(q('containerNoPendingApprovals')) return 'EMPTY'; return 'WAIT'; }"
}

open_cold() {
  local s i
  playwright-cli cookie-clear >/dev/null 2>&1
  playwright-cli goto "$1" >/dev/null 2>&1
  for i in $(seq 1 25); do
    s="$(page_state)"
    # 'LIST:' with no rows is the gallery painted before its items arrived (the
    # first dev run read exactly that), so keep polling it like WAIT.
    case "$s" in WAIT|''|LIST:) sleep 1 ;; *) break ;; esac
  done
  printf '%s' "$s"
}

# ------------------------------------------------------------------ 1. own data
tt_login "e2e_tm" "Add Customer"
fx_view "cardProjects" "galProjects"
fx_create_project "$PZ" "No" "Yes" "No" "$APPROVER"
fx_create_assignment "$CNAME" "$PZ" 40 "$FX_CUSTOMER"

tt_login "$CUSER" "My Timesheets"
tt_consultant_submit_project_row "$PZ"
WEEK="${TT_SUBMITTED_WEEK:-}"
[ -n "$WEEK" ] || tt_fail "setup: could not tell which week was submitted on '$PZ'"
note "submitted '$PZ' for week $WEEK"
sleep 5

# ------------------------------------------------------------------ 2. a real link
tt_login "e2e_hr" "$TT_HR_READY"
tt_hr_click_tab "Client approval"
sleep 2
REMINDED=""
for i in 1 2 3 4; do
  if REMINDED="$(tt_hr_remind_e2e_entry "$CNAME" "$PZ")"; then break; fi
  REMINDED=""
  sleep 8
  tt_hr_click_tab "Client approval"
done
[ -n "$REMINDED" ] || tt_fail "setup: no remindable '$CNAME' / '$PZ' card on Client approval for week $WEEK"
tt_clear_dialogs 3 >/dev/null 2>&1   # TT-768's "Reminder sent to ..." message

LINK=""
started="$(date +%s)"
while [ -z "$LINK" ]; do
  LINK="$(tt_mail_links_to "$APPROVER" customer-approval 1)"
  case "$LINK" in NOGRID|NOFILTER|*" "*) LINK="" ;; esac
  [ -n "$LINK" ] && break
  [ $(( $(date +%s) - started )) -ge 240 ] && tt_fail "setup: no approval email to '$APPROVER' within 240 s of the Remind"
  sleep 10
done
note "link: $LINK"

# ------------------------------------------------------------------ A. control
S="$(open_cold "$LINK")"
case "$S" in
  LIST:*"$CNAME"*) note "A ok: before the archive the link opens the approval page and lists $CNAME" ;;
  *) tt_fail "A: before anything was withdrawn the link shows [$S], not an approval page listing $CNAME - nothing below could be attributed to the archive" ;;
esac

# ------------------------------------------------------------------ withdraw coverage
tt_login "e2e_hr" "$TT_HR_READY"
R="$(set_archived true)"
[ "$R" = "ok" ] || tt_fail "HR could not archive '$PZ' ($R)"
[ "$(tt_authz_readback "$PROJECT_XP" Archived)" = "true" ] || tt_fail "'$PZ' did not read back Archived=true"
note "archived '$PZ' - its approver now covers no project"

# ------------------------------------------------------------------ B/C. the same link
S="$(open_cold "$LINK")"
case "$S" in
  INVALID) note "B ok: the link now lands on the invalid-link page" ;;
  LIST:*)  bad "B: the dead link still opened the approval LIST [$S]" ;;
  EMPTY)   bad "B: the dead link opened the approval page's 'nothing to approve' state instead of the invalid-link page" ;;
  *)       bad "B: the dead link showed [$S]; expected the invalid-link page (textLinkInvalidHeading)" ;;
esac
# The retired copy is the in-place "replaced each time a new approval request is
# sent" message. "The link in your most recent approval email should still work"
# is NOT retired: it is the current body of Main.Customer_LinkInvalid (TT-744; read
# on dev 2026-10-06 and in the model), so it must not be asserted against.
BODY="$(ev "() => (document.body ? document.body.innerText : '').replace(/\\s+/g,' ')")"
case "$BODY" in
  *"replaced each time"*)
    bad "C: the page carries the retired copy: [$(printf '%s' "$BODY" | cut -c1-300)]" ;;
  *"no longer valid"*) note "C ok: the current invalid-link copy, no retired 'replaced each time' text" ;;
  *) bad "C: the invalid-link page does not read 'no longer valid': [$(printf '%s' "$BODY" | cut -c1-300)]" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-tt778-dead-link-invalid-page - $fails problem(s): a live-looking link that covers no project does not land on the invalid-link page."
  exit 1
fi
echo "PASS: verify-tt778-dead-link-invalid-page - a valid link whose only project is archived lands on the invalid-link page with the current copy."
