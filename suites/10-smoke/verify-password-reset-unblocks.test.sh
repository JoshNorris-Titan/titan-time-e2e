#!/usr/bin/env bash
# tt-timeout: 16m
# verify-password-reset-unblocks.test.sh
#
# TT-781: a self-service password reset lifts the failed-login lockout - someone
# who locked themselves out trying their old password signs straight in with the
# new one.
#
# WHY THIS EXISTS. The app blocks an account after three wrong passwords in a row
# (Mendix's own protection: System.User.Blocked, FailedLogins). Before TT-781 the
# "Forgot password?" reset changed only the password, so the person most likely to
# use it - the one who just locked themselves out - set a new password and was
# still refused with "Invalid Credentials". Since model 73b0683b
# Core.ACT_Password_SetFromToken also clears Blocked and FailedLogins. Nothing in the
# suite has ever locked an account out: every other login is a correct one.
#
# A DEDICATED ACCOUNT, NEVER A SHARED ONE. The lockout is real and the password
# really changes, so this uses its own account - TT_PWRESET_USER, the same fixture
# account as suites/10-smoke/verify-password-reset-redeem (PR #144) and provisioned
# the same way: once per environment, by hand, Admin Hub -> Accounts Overview -> New
# local user, login TT_PWRESET_USER, email TT_PWRESET_EMAIL, role Consultant,
# password TT_PWRESET_PASS. It refuses to run against any shared e2e_* account or
# the administrator. On the way out (always, from an EXIT trap) the administrator
# unblocks the account and sets its password back to TT_PWRESET_PASS, so a failure
# half way never leaves it locked or on a password nobody knows.
#
# WHAT IT ASSERTS
#   0. (fatal) the account exists, is active, carries TT_PWRESET_EMAIL, and starts
#      unblocked (it is unblocked first if a previous run left it locked);
#   A. three wrong passwords block it: the data layer reads Blocked=true, and the
#      RIGHT password is now refused too - so the lockout is real, not assumed;
#   B. Forgot password? sends a reset link, and the link sets a new password;
#   C. the account signs in with the new password at once, and the session is its;
#   D. read as the administrator: Blocked=false and FailedLogins=0.
#
# WHAT MAKES IT RED. ACT_Password_SetFromToken going back to changing only the
# password: C is refused ("Invalid Credentials") and D reads Blocked=true.
#
# Consumes: one lockout and one password reset on its own account. Clears cookies.
# Env: TT_BASE_URL, TT_ADMIN_USER, TT_ADMIN_PASS, TT_PWRESET_USER (default
#      e2e_pwreset), TT_PWRESET_EMAIL, TT_PWRESET_PASS (default TT_ROLE_PASS),
#      TT_PWRESET_LANDING (default My Timesheets)
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_testdata.sh"   # TT_ADMIN_U / TT_ADMIN_P
source "$TT_ROOT/lib/_accounts.sh"   # acct_admin_login, acct_unblock, acct_set_password

PU="${TT_PWRESET_USER:-e2e_pwreset}"
PEMAIL="${TT_PWRESET_EMAIL:-jnorris+ttreset@titanconsulting.net}"
PPASS="${TT_PWRESET_PASS:-${TT_ROLE_PASS:-}}"
PLAND="${TT_PWRESET_LANDING:-My Timesheets}"
NEWPASS="Unb-$(date +%s)-Aa9!"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

case "$PU" in
  e2e_consultant|e2e_consultant2|e2e_consultant3|e2e_hr|e2e_pm|e2e_pm2|e2e_tm|MxAdmin|"${TT_ADMIN_USER:-MxAdmin}")
    tt_fail "TT_PWRESET_USER is '$PU', a shared account. This step locks out and resets the account it uses; give it one of its own." ;;
esac
[ -n "$PPASS" ] || tt_fail "TT_PWRESET_PASS (or TT_ROLE_PASS) must be set: it is the password the account is restored to afterwards"

body_has() { ev "() => String(/$1/i.test(document.body ? document.body.innerText : ''))"; }
wait_body() {
  local i
  for i in $(seq 1 "$2"); do [ "$(body_has "$1")" = "true" ] && return 0; sleep 1; done
  return 1
}

# lock_state - "<Active>~<Blocked>~<FailedLogins>~<Email>" for $PU, read as the
# CURRENT session (the administrator), or ABSENT / ERR:<why>.
lock_state() {
  ev "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"//Administration.Account[Name = '$PU']\", filter:{amount:2}, callback: o => { clearTimeout(t); if(!o||!o.length) return res('ABSENT'); const a=o[0]; res([a.get('Active'), a.get('Blocked'), a.get('FailedLogins'), a.get('Email')||''].map(String).join('~')); }, error: e => { clearTimeout(t); res('ERR:'+e.message); } }); } catch(e){ res('ERR:'+e.message); } })"
}

# sign_in <password> - one attempt on the app's own Core.Login page, from a fresh
# session. Echoes in | refused | reset | stuck (lib/_login_waits.sh's 0/1/2/3).
sign_in() {
  local v rc
  playwright-cli cookie-clear >/dev/null 2>&1
  playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
  v="$(_tt_login_form_variant 30)"
  [ "$v" = "new" ] || { echo "noform"; return 0; }
  _tt_login_submit new "$PU" "$1" "$PLAND"; rc=$?
  case "$rc" in 0) echo in ;; 1) echo refused ;; 2) echo reset ;; *) echo stuck ;; esac
}

RESTORE=""
restore() {
  [ -n "$RESTORE" ] || return 0
  echo "  restoring $PU: unblock, password back to TT_PWRESET_PASS"
  acct_admin_login "$TT_ADMIN_U" "$TT_ADMIN_P"
  acct_unblock "$PU" || echo "  WARNING: could not unblock $PU ($ACCT_LAST_ERROR) - unblock it by hand (Accounts Overview -> Edit)." >&2
  acct_set_password "$PU" "$PPASS" \
    || echo "  WARNING: could not restore $PU's password ($ACCT_LAST_ERROR). Nothing in the suite depends on it." >&2
  return 0
}
trap restore EXIT

# ------------------------------------------------------------------ 0. the account
acct_admin_login "$TT_ADMIN_U" "$TT_ADMIN_P"
S="$(lock_state)"
case "$S" in
  ABSENT) tt_fail "there is no account '$PU' on $TT_BASE. Provision it once by hand (this file's header): Accounts Overview -> New local user, email $PEMAIL, role Consultant, password TT_PWRESET_PASS." ;;
  ERR:*)  tt_fail "could not read Administration.Account as the administrator ($S)" ;;
  true~*) ;;
  *)      tt_fail "account '$PU' is not active ($S) - a reset link is refused for an inactive account by design" ;;
esac
got_email="$(printf '%s' "${S##*~}" | tr '[:upper:]' '[:lower:]')"
[ "$got_email" = "$(printf '%s' "$PEMAIL" | tr '[:upper:]' '[:lower:]')" ] \
  || tt_fail "account '$PU' has email '${S##*~}', not TT_PWRESET_EMAIL '$PEMAIL' - the reset mail would go somewhere this step does not read"
RESTORE=1
case "$S" in
  true~true~*) note "a previous run left $PU blocked; clearing it first"
               acct_unblock "$PU" || tt_fail "could not unblock $PU before starting ($ACCT_LAST_ERROR)" ;;
esac
acct_set_password "$PU" "$PPASS" || tt_fail "could not put $PU on TT_PWRESET_PASS before starting ($ACCT_LAST_ERROR)"
note "0: $PU is active, unblocked, on TT_PWRESET_PASS, email $PEMAIL"

# ------------------------------------------------------------------ A. lock it out
for n in 1 2 3; do
  r="$(sign_in "wrong-$n-$(date +%s)")"
  [ "$r" = "refused" ] || tt_fail "A: wrong password #$n was not refused ($r)"
done
acct_admin_login "$TT_ADMIN_U" "$TT_ADMIN_P"
S="$(lock_state)"
case "$S" in
  true~true~*) note "A: three wrong passwords blocked $PU ($S)" ;;
  *) tt_fail "A: three wrong passwords did not block $PU (state $S) - there is no lockout for the reset to lift, so C and D would prove nothing" ;;
esac
r="$(sign_in "$PPASS")"
[ "$r" = "refused" ] || tt_fail "A: while blocked, the RIGHT password was not refused ($r) - the lockout is not real"
note "A: while blocked, even the right password is refused"

# ------------------------------------------------------------------ B. reset
tt_mail_prepare
TS=$(date +%s%3N)
playwright-cli cookie-clear >/dev/null 2>&1
playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
[ "$(_tt_login_form_variant 30)" = "new" ] || tt_fail "B: the anonymous home page did not render Core.Login, the only page with btnForgotPassword"
tt_fill_commit "$TT_LOGIN_USER_SEL" "$PU"
playwright-cli click ".mx-name-btnForgotPassword" >/dev/null 2>&1
wait_body "reset link has been sent" 20 || tt_fail "B: Forgot password? for '$PU' produced no confirmation"
tt_clear_dialogs 4 >/dev/null 2>&1
LINK="$(tt_mail_token "$TS" "reset-password" "$PEMAIL")" || tt_fail "B: no password reset link to $PEMAIL arrived"
case "$LINK" in *"/p/reset-password/"*) ;; *) tt_fail "B: the mail's link is not a reset-password link: $LINK" ;; esac
# STILL BLOCKED, right before the redeem. Waiting for the mail can take minutes, and a
# lockout that lapsed on its own in that time would let C pass without the reset
# having lifted anything.
acct_admin_login "$TT_ADMIN_U" "$TT_ADMIN_P"
S="$(lock_state)"
case "$S" in
  true~true~*) ;;
  *) tt_fail "B: $PU is no longer blocked just before the reset ($S) - the lockout lapsed on its own while the mail was awaited, so C could not tell the reset's effect from that" ;;
esac
playwright-cli cookie-clear >/dev/null 2>&1
playwright-cli goto "$LINK" >/dev/null 2>&1
tt_wait_for ".mx-name-txtNewPassword input" "the new-password box on the reset page"
tt_fill_commit ".mx-name-txtNewPassword input" "$NEWPASS"
tt_fill_commit ".mx-name-txtConfirmPassword input" "$NEWPASS"
playwright-cli click ".mx-name-btnSetPassword" >/dev/null 2>&1
wait_body "password has been updated" 20 || tt_fail "B: the new password was not accepted (no 'Your password has been updated')"
tt_clear_dialogs 4 >/dev/null 2>&1
note "B: reset to a new password through the mailed link"

# ------------------------------------------------------------------ C. sign straight in
r="$(sign_in "$NEWPASS")"
if [ "$r" = "in" ]; then
  who="$(ev "() => { try { return mx.session.userObject.jsonData.attributes.Name.value; } catch(e) { return ''; } }")"
  if [ "$who" = "$PU" ]; then note "C ok: $PU signed straight in with the new password"
  else bad "C: signed in with the new password but the session belongs to '${who:-nobody}', not $PU"; fi
else
  bad "C: $PU could not sign in with the new password ($r) - the reset left the account locked out (TT-781)"
fi

# ------------------------------------------------------------------ D. the flags
acct_admin_login "$TT_ADMIN_U" "$TT_ADMIN_P"
S="$(lock_state)"
IFS='~' read -r S_ACTIVE S_BLOCKED S_FAILED _ <<< "$S"
if [ "$S_BLOCKED" = "false" ] && [ "$S_FAILED" = "0" ]; then
  note "D ok: Blocked=false, FailedLogins=0 (active=$S_ACTIVE)"
else
  bad "D: after the reset the account reads Blocked=$S_BLOCKED FailedLogins=$S_FAILED; expected false / 0"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-password-reset-unblocks - $fails problem(s): a password reset does not lift the failed-login lockout."
  exit 1
fi
echo "PASS: verify-password-reset-unblocks - locked out by three wrong passwords, $PU reset the password and signed straight in; Blocked=false, FailedLogins=0."
