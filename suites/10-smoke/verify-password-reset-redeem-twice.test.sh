#!/usr/bin/env bash
# A person can reset their password by email TWICE: the second emailed link works
# just like the first, and the first reset's "Password Reset" workflow is closed
# (Aborted) rather than left running or broken.
#
# tt-timeout: 16m
#
# WHY THIS EXISTS (TT-781 follow-up, 2026-10-07). Redeeming an emailed reset link
# starts a "Password Reset" workflow for the account (a 90-day user task). The
# NEXT reset on the same account tries to complete that running task from the
# anonymous reset session, the runtime refuses ("Only named users can complete
# user task"), and the whole reset rolls back: the page shows that error and the
# password does not change. Measured on dev 2026-10-07 on an unblocked account:
# verify-password-reset-redeem passed once, then failed at D on every later run,
# with an InProgress "Password Reset" workflow (started anonymously) whose user
# task targets the account. verify-password-reset-redeem only ever redeems once
# per run, so it could not show this; it only went red on the NEXT run.
#
# WHAT IT ASSERTS (e2e_pwreset, its own account - never a shared one)
#   R1. a first full reset - Forgot password?, the mailed link, a new password,
#       "Your password has been updated", and a sign-in with it - works;
#   R2. a SECOND full reset, straight after, works the same way: the page says the
#       password was updated (not "Only named users can complete user task") and
#       the account signs in with the second new password;
#   W.  read as the administrator, of THIS ACCOUNT'S "Password Reset" workflows
#       started since this step began, the EARLIEST (R1's) is Aborted - not
#       InProgress (left running, which is what breaks the next reset) and not
#       Incompatible.
#
# WHICH WORKFLOWS ARE THIS ACCOUNT'S. Anyone on dev may reset a password while
# this runs, so W must not read every "Password Reset" workflow. The workflow's
# context is a Core.ForceReset (Core.ForceReset_Account -> the account), but the
# client cannot navigate from a System.Workflow to its context object: the model
# has no such association, and the runtime exposes the context only to
# microflows. What the client CAN read is the workflow's user task and the users
# it targets: System.WorkflowUserTask (or, once the workflow has ended,
# System.WorkflowEndedUserTask) -> _TargetUsers, -> _Workflow. Measured on dev
# 2026-10-07, e2e_pwreset's reset task targets e2e_pwreset itself plus two other
# users (presumably administrators); that another account's reset task never
# targets e2e_pwreset is assumed, not measured. So W keeps only the workflows
# whose task, live or ended, targets $PU's own System.User, and fails if it
# cannot resolve that user rather than falling back to every workflow. If the
# model ever gives the workflow a client-readable link to its Core.ForceReset,
# filter on Core.ForceReset_Account instead.
# On the way out (EXIT trap) the administrator sets the password back to
# TT_PWRESET_PASS.
#
# RED ON DEV UNTIL THE FIX THAT ABORTS THE PREVIOUS RESET WORKFLOW DEPLOYS. Today
# R1 itself can fail when an earlier run left a workflow InProgress on the account,
# and R2 fails with "Only named users can complete user task".
#
# Consumes: two password resets on its own account. Clears cookies.
# Env: TT_BASE_URL, TT_ROLE_PASS, TT_ADMIN_USER, TT_ADMIN_PASS,
#      TT_PWRESET_USER (default e2e_pwreset), TT_PWRESET_EMAIL,
#      TT_PWRESET_PASS (default TT_ROLE_PASS), TT_PWRESET_LANDING (default My Timesheets)
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_testdata.sh"   # TT_ADMIN_U / TT_ADMIN_P
source "$TT_ROOT/lib/_accounts.sh"   # acct_admin_login, acct_set_password

PU="${TT_PWRESET_USER:-e2e_pwreset}"
PEMAIL="${TT_PWRESET_EMAIL:-jnorris+ttreset@titanconsulting.net}"
PPASS="${TT_PWRESET_PASS:-${TT_ROLE_PASS:-}}"
PLAND="${TT_PWRESET_LANDING:-My Timesheets}"
T0_MS="$(( $(date +%s) * 1000 - 60000 ))"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

case "$PU" in
  e2e_consultant|e2e_consultant2|e2e_consultant3|e2e_hr|e2e_pm|e2e_pm2|e2e_tm|MxAdmin|"${TT_ADMIN_USER:-MxAdmin}")
    tt_fail "TT_PWRESET_USER is '$PU', a shared account. This step changes the password of the account it uses; give it one of its own." ;;
esac
[ -n "$PPASS" ] || tt_fail "TT_PWRESET_PASS (or TT_ROLE_PASS) must be set: it is the password the account is restored to afterwards"

body_has()  { ev "() => String(/$1/i.test(document.body ? document.body.innerText : ''))"; }
wait_body() { local i; for i in $(seq 1 "$2"); do [ "$(body_has "$1")" = "true" ] && return 0; sleep 1; done; return 1; }
page_text() { ev "() => (document.body ? document.body.innerText : '').replace(/\\s+/g,' ').slice(0,400)"; }

CHANGED=""
restore() {
  [ -n "$CHANGED" ] || return 0
  echo "  restoring $PU's password to TT_PWRESET_PASS"
  acct_admin_login "$TT_ADMIN_U" "$TT_ADMIN_P"
  acct_set_password "$PU" "$PPASS" \
    || echo "  WARNING: could not restore $PU's password ($ACCT_LAST_ERROR) - set it by hand before signing in as $PU." >&2
  return 0
}
trap restore EXIT

# reset_once <label> <new password> - one full emailed reset. Echoes nothing;
# records a failure with bad() and returns 1 when any step does not happen.
reset_once() {
  local L="$1" NP="$2" TS LINK who
  tt_mail_prepare
  TS=$(date +%s%3N)
  playwright-cli cookie-clear >/dev/null 2>&1
  playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
  [ "$(_tt_login_form_variant)" = "new" ] || { bad "$L: the anonymous home page did not render Core.Login"; return 1; }
  tt_fill_commit "$TT_LOGIN_USER_SEL" "$PU"
  playwright-cli click ".mx-name-btnForgotPassword" >/dev/null 2>&1
  wait_body "reset link has been sent" 20 || { bad "$L: Forgot password? for '$PU' produced no confirmation"; return 1; }
  tt_clear_dialogs 4 >/dev/null 2>&1
  LINK="$(tt_mail_token "$TS" "reset-password" "$PEMAIL")" || { bad "$L: no password reset link to $PEMAIL arrived"; return 1; }
  case "$LINK" in *"/p/reset-password/"*) ;; *) bad "$L: the mail's link is not a reset-password link: $LINK"; return 1 ;; esac
  playwright-cli cookie-clear >/dev/null 2>&1
  playwright-cli goto "$LINK" >/dev/null 2>&1
  tt_wait_for ".mx-name-txtNewPassword input" "the new-password box on the reset page ($L)"
  tt_fill_commit ".mx-name-txtNewPassword input" "$NP"
  tt_fill_commit ".mx-name-txtConfirmPassword input" "$NP"
  playwright-cli click ".mx-name-btnSetPassword" >/dev/null 2>&1
  CHANGED=1
  if ! wait_body "password has been updated" 20; then
    bad "$L: the new password was not accepted (no 'Your password has been updated'). The page says: $(page_text)"
    return 1
  fi
  tt_clear_dialogs 4 >/dev/null 2>&1
  TT_AUTH_CACHE=0 tt_login "$PU" "$PLAND" "$NP"
  who="$(ev "() => { try { return mx.session.userObject.jsonData.attributes.Name.value; } catch(e) { return ''; } }")"
  [ "$who" = "$PU" ] || { bad "$L: signed in with the new password but the session belongs to '${who:-nobody}'"; return 1; }
  note "$L ok: reset by email and signed in with the new password"
}

# ------------------------------------------------------------------ 0. the account
acct_admin_login "$TT_ADMIN_U" "$TT_ADMIN_P"
ACC="$(ev "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"//Administration.Account[Name = '$PU']\", filter:{amount:2}, callback:o=>{ clearTimeout(t); if(!o||!o.length) return res('ABSENT'); res(String(o[0].get('Active'))+'~'+String(o[0].get('Blocked'))+'~'+String(o[0].get('Email')||'')); }, error:e=>{ clearTimeout(t); res('ERR:'+e.message); } }); } catch(e){ res('ERR:'+e.message); } })")"
case "$ACC" in
  ABSENT) tt_fail "there is no account '$PU' on $TT_BASE (see verify-password-reset-redeem's header for provisioning)" ;;
  ERR:*)  tt_fail "could not read Administration.Account as the administrator ($ACC)" ;;
  true~false~*) note "0: $PU is active and not blocked (${ACC##*~})" ;;
  *)      tt_fail "account '$PU' is not active and unblocked ($ACC) - this step is about a SECOND reset, not a lockout" ;;
esac

# ------------------------------------------------------------------ R1, R2
reset_once "R1" "Tw1-$(date +%s)-Aa9!" || note "(R1 failed: an earlier run may have left a Password Reset workflow running on $PU - the very fault R2 is about)"
reset_once "R2" "Tw2-$(date +%s)-Aa9!"

# ------------------------------------------------------------------ W. the first workflow
acct_admin_login "$TT_ADMIN_U" "$TT_ADMIN_P"
WF="$(ev "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),30000); const get=(xp)=>new Promise((ok,ko)=>mx.data.get({ xpath: xp, filter:{amount:500}, callback: ok, error: ko }));
  (async () => {
    const u = await get(\"//System.User[Name = '$PU']\"); if (!u.length) { clearTimeout(t); return res('ERR:no System.User named $PU'); }
    const ug = u[0].getGuid();
    const live = await get(\"//System.WorkflowUserTask[System.WorkflowUserTask_TargetUsers = '\"+ug+\"']\");
    const ended = await get(\"//System.WorkflowEndedUserTask[System.WorkflowEndedUserTask_TargetUsers = '\"+ug+\"']\");
    const ids = new Set([...live.map(x=>x.get('System.WorkflowUserTask_Workflow')), ...ended.map(x=>x.get('System.WorkflowEndedUserTask_Workflow'))].filter(Boolean));
    const wf = await get(\"//System.Workflow[Name = 'Password Reset']\");
    const r = wf.filter(x=>ids.has(x.getGuid()) && Number(x.get('StartTime'))>=$T0_MS).sort((a,b)=>Number(a.get('StartTime'))-Number(b.get('StartTime'))).map(x=>new Date(Number(x.get('StartTime'))).toISOString()+'='+x.get('State'));
    clearTimeout(t); res(r.join(';') || 'NONE');
  })().catch(e => { clearTimeout(t); res('ERR:'+((e&&e.message)||e)); }); } catch(e){ res('ERR:'+e.message); } })")"
note "$PU's Password Reset workflows started during this step: $WF"
case "$WF" in
  ERR:*) bad "W: the administrator could not read System.Workflow ($WF)" ;;
  NONE)  bad "W: no 'Password Reset' workflow of $PU's was started during this step, so the first reset's workflow cannot be checked" ;;
  *)
    FIRST="${WF%%;*}"
    case "${FIRST#*=}" in
      Aborted) note "W ok: the first reset's workflow (${FIRST%%=*}) is Aborted" ;;
      *)       bad "W: the first reset's workflow (${FIRST%%=*}) is ${FIRST#*=}, not Aborted - a workflow left behind is what breaks the next reset" ;;
    esac ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-password-reset-redeem-twice - $fails problem(s) with a second emailed reset on the same account."
  exit 1
fi
echo "PASS: verify-password-reset-redeem-twice - $PU reset its password by email twice, and the first reset's workflow was aborted."
