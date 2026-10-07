#!/usr/bin/env bash
# The whole self-service password reset, end to end: ask for a link on the sign-in
# page, redeem it from the email, sign in with the new password - and the same link
# is refused the second time.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. verify-forgot-password-link covers the REQUEST half and says in
# its header why it stopped there: the redeem half needs the token, which only
# exists in an email, and exercising it on a shared account would change that
# account's password under every later step. Both are solved now - the suite reads
# mail from the app's Emails Sent page (tt_mail_token), and this step uses an
# account of its OWN (TT_PWRESET_USER), never one of the shared e2e_* role accounts.
#
# The customer-link security change (2026-09-29) also rebuilt the redeem page:
# Core.ResetPassword_FromToken now edits a Core.PasswordResetForm (NewPassword,
# ConfirmPassword) that the link's own microflow creates. Anonymous may read and
# write those two fields and may NOT create the form - otherwise anyone could
# conjure one, point it at an account and post it to Core.ACT_Password_SetFromToken.
# The form's Account association is read-only for the same reason.
#
# WHAT IT ASSERTS
#   0. the fixture account exists, is active, and has the email this step reads
#      mail for (read as the administrator: e2e_tm's Administration.Account
#      read does not include Name or Active on a Consultant's account - measured
#      on dev 2026-09-30, the row comes back with only Email and FullName - so a
#      Name-keyed retrieve as e2e_tm reports a provisioned account as absent);
#   A. Forgot password? on Core.Login, with the account's login, answers with the
#      generic confirmation, and a reset link to that address arrives;
#   B. the link opens the reset page in a fresh session;
#   C. two different passwords are refused with "do not match", and nothing claims
#      success;
#   D. matching passwords are accepted ("Your password has been updated");
#   E. the account signs in with the NEW password, and the session is really its;
#   F. the same link, opened again in a fresh session, is refused ("not valid any
#      more") and offers no password box;
#   G. an anonymous session cannot create a Core.PasswordResetForm;
# and on the way out (always, from an EXIT trap) the administrator sets the
# account's password back to TT_PWRESET_PASS, so a person can still sign in as it.
# Nothing in the next run depends on that password - the reset never asks for the
# old one - so a failed restore is reported as a warning, not as this step's result.
#
# SELECTORS. The reset page is fully named (txtNewPassword, txtConfirmPassword,
# btnSetPassword) and so is btnForgotPassword. The login page's username box is
# txtLoginUsername, reached through TT_LOGIN_USER_SEL (lib/_login_waits.sh) like
# every other login in the suite.
#
# PROVISIONING (once per environment, by hand - no fixture creates accounts): Admin
# Hub -> Accounts Overview -> New local user, login TT_PWRESET_USER, email
# TT_PWRESET_EMAIL, role Consultant (so it lands on "My Timesheets"), then set its
# password to TT_PWRESET_PASS. See README section 4.
#
# RED / UNPROVEN UNTIL THE CHANGE IS DEPLOYED: G, and the reset page's field names.
#
# Consumes: one password reset on its own account. Clears cookies.
# Env: TT_BASE_URL, TT_ROLE_PASS, TT_ADMIN_USER, TT_ADMIN_PASS,
#      TT_PWRESET_USER (default e2e_pwreset), TT_PWRESET_EMAIL,
#      TT_PWRESET_PASS (default TT_ROLE_PASS), TT_PWRESET_LANDING (default My Timesheets)
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"
source "$TT_ROOT/lib/_testdata.sh"   # TT_ADMIN_U / TT_ADMIN_P
source "$TT_ROOT/lib/_accounts.sh"   # acct_admin_login, acct_set_password

PU="${TT_PWRESET_USER:-e2e_pwreset}"
PEMAIL="${TT_PWRESET_EMAIL:-jnorris+ttreset@titanconsulting.net}"
PPASS="${TT_PWRESET_PASS:-${TT_ROLE_PASS:-}}"
PLAND="${TT_PWRESET_LANDING:-My Timesheets}"
NEWPASS="Rst-$(date +%s)-Aa9!"

# A shared role account here would change the password every later step signs in
# with. Refuse before anything is sent.
case "$PU" in
  e2e_consultant|e2e_consultant2|e2e_consultant3|e2e_hr|e2e_pm|e2e_pm2|e2e_tm|MxAdmin|"${TT_ADMIN_USER:-MxAdmin}")
    tt_fail "TT_PWRESET_USER is '$PU', a shared account. This step changes the password of the account it uses; give it one of its own." ;;
esac
[ -n "$PPASS" ] || tt_fail "TT_PWRESET_PASS (or TT_ROLE_PASS) must be set: it is the password the account is restored to afterwards"

# body_has <js-regex> — 'true' when the page text matches (case-insensitive).
body_has() {
  playwright-cli eval "() => String(/$1/i.test(document.body ? document.body.innerText : ''))" 2>/dev/null | _tt_eval_str
}

# wait_body <js-regex> <seconds>
wait_body() {
  local i
  for i in $(seq 1 "$2"); do
    [ "$(body_has "$1")" = "true" ] && return 0
    sleep 1
  done
  return 1
}

CHANGED=""
restore() {
  [ -n "$CHANGED" ] || return 0
  echo "  restoring $PU's password to TT_PWRESET_PASS"
  acct_admin_login "$TT_ADMIN_U" "$TT_ADMIN_P"
  acct_set_password "$PU" "$PPASS"
  case $? in
    0) echo "  restored" ;;
    *) echo "  WARNING: could not restore $PU's password ($ACCT_LAST_ERROR). Nothing in the suite depends on it; set it by hand before signing in as $PU manually." >&2 ;;
  esac
  return 0
}
trap restore EXIT

# ----------------------------------------------------- 0. the fixture account
acct_admin_login "$TT_ADMIN_U" "$TT_ADMIN_P"
ACC="$(playwright-cli eval "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"//Administration.Account[Name = '$PU']\", filter:{amount:2}, callback:o=>{ clearTimeout(t); if(!o||!o.length) return res('ABSENT'); res(String(o[0].get('Active'))+'~'+String(o[0].get('Email')||'')); }, error:e=>{ clearTimeout(t); res('ERR:'+e.message); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str)"
case "$ACC" in
  ABSENT) tt_fail "there is no account '$PU' on $TT_BASE. Provision it once by hand (see this file's header, and README section 4): Accounts Overview -> New local user, email $PEMAIL, role Consultant, password TT_PWRESET_PASS." ;;
  ERR:*)  tt_fail "could not read Administration.Account as the administrator ($ACC)" ;;
  true~*) ;;
  *)      tt_fail "account '$PU' is not active ($ACC) - the request flow silently sends nothing for an inactive account" ;;
esac
got_email="$(printf '%s' "${ACC#*~}" | tr '[:upper:]' '[:lower:]')"
[ "$got_email" = "$(printf '%s' "$PEMAIL" | tr '[:upper:]' '[:lower:]')" ] \
  || tt_fail "account '$PU' has email '${ACC#*~}', not TT_PWRESET_EMAIL '$PEMAIL' - the reset mail would go somewhere this step does not read"
echo "  0: account $PU is active, email $PEMAIL"

# ---------------------------------------------------- A. request, and the mail
tt_mail_prepare
TS=$(date +%s%3N)
playwright-cli cookie-clear >/dev/null 2>&1
playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
[ "$(_tt_login_form_variant)" = "new" ] || tt_fail "the anonymous home page did not render Core.Login, which is the only page with btnForgotPassword"
tt_fill_commit "$TT_LOGIN_USER_SEL" "$PU"
playwright-cli click ".mx-name-btnForgotPassword" >/dev/null 2>&1
wait_body "reset link has been sent" 20 || tt_fail "A: Forgot password? for '$PU' produced no confirmation"
tt_clear_dialogs 4 >/dev/null 2>&1
LINK="$(tt_mail_token "$TS" "reset-password" "$PEMAIL")" || tt_fail "A: no password reset link to $PEMAIL arrived"
case "$LINK" in
  *"/p/reset-password/"*) echo "  A: a reset link to $PEMAIL arrived" ;;
  *) tt_fail "A: the mail's link is not a reset-password link: $LINK" ;;
esac

# ---------------------------------------------------------------- B. open it
playwright-cli cookie-clear >/dev/null 2>&1
playwright-cli goto "$LINK" >/dev/null 2>&1
tt_wait_for ".mx-name-txtNewPassword input" "the new-password box on the reset page"
tt_wait_for ".mx-name-btnSetPassword" "the Set new password button"
echo "  B: the link opened the reset page"

# ------------------------------------------------------------- C. mismatch
tt_fill_commit ".mx-name-txtNewPassword input" "$NEWPASS"
tt_fill_commit ".mx-name-txtConfirmPassword input" "${NEWPASS}x"
playwright-cli click ".mx-name-btnSetPassword" >/dev/null 2>&1
wait_body "do not match" 15 || tt_fail "C: two different passwords were not refused with 'The passwords do not match'"
[ "$(body_has "password has been updated")" = "false" ] || tt_fail "C: two different passwords were refused AND the page says the password was updated"
[ "$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-txtNewPassword input'))" 2>/dev/null | _tt_eval_str)" = "true" ] \
  || tt_fail "C: after the mismatch the reset page is gone - the form should stay for a second try"
echo "  C: mismatched passwords were refused"

# --------------------------------------------------------------- D. set it
tt_fill_commit ".mx-name-txtConfirmPassword input" "$NEWPASS"
playwright-cli click ".mx-name-btnSetPassword" >/dev/null 2>&1
CHANGED=1
wait_body "password has been updated" 20 || tt_fail "D: matching passwords were not accepted (no 'Your password has been updated')"
tt_clear_dialogs 4 >/dev/null 2>&1
echo "  D: the new password was accepted"

# --------------------------------------------------- E. sign in with it
TT_AUTH_CACHE=0 tt_login "$PU" "$PLAND" "$NEWPASS"
who="$(playwright-cli eval "() => { try { return mx.session.userObject.jsonData.attributes.Name.value; } catch(e) { return ''; } }" 2>/dev/null | _tt_eval_str)"
[ "$who" = "$PU" ] || tt_fail "E: signed in with the new password but the session belongs to '${who:-nobody}', not $PU"
echo "  E: $PU signed in with the new password"

# ----------------------------------------------- F. the link a second time
playwright-cli cookie-clear >/dev/null 2>&1
playwright-cli goto "$LINK" >/dev/null 2>&1
wait_body "not valid any more" 20 || tt_fail "F: reopening a used reset link did not say it is no longer valid"
sleep 2
[ "$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-txtNewPassword input'))" 2>/dev/null | _tt_eval_str)" = "false" ] \
  || tt_fail "F: a used reset link still offers a new-password box"
tt_clear_dialogs 4 >/dev/null 2>&1
echo "  F: the used link was refused"

# ------------------------------------ G. no anonymous PasswordResetForm of its own
ROLES="$(tt_authz_anonymous)"
case "$ROLES" in *Anonymous*) ;; *) tt_fail "G: the session does not hold Anonymous ($ROLES)" ;; esac
G="$(tt_authz_create "Core.PasswordResetForm")"
tt_authz_expect_refused "G: anonymous create of Core.PasswordResetForm" "$G" >/dev/null
echo "  G: an anonymous session cannot create a Core.PasswordResetForm ($G)"

echo "PASS: verify-password-reset-redeem — $PU requested a reset, redeemed the mailed link (a mismatch refused first), signed in with the new password, the link was refused a second time, and Anonymous cannot create a reset form"
