#!/usr/bin/env bash
# tt-timeout: 10m
# verify-tt815-username-must-be-email.test.sh
#
# TT-815: an account's username must be an email address. The new-account form
# refuses one that is not, and so does the edit form when the username is CHANGED to
# one that is not. Nothing is created and nothing is renamed.
#
# WHY THIS EXISTS. Production usernames are a mix of formats and people cannot
# remember which one is theirs (TT-810). The rule is server-side, in the two save
# microflows, so a form that merely looked right could still save the account.
#
# WHAT IT ASSERTS
#   A. New local user with username e2e-tt815-<epoch> (not an address), a valid
#      email and an employment status: Save shows "must be an email address" on the
#      Username box, and no account with that login exists afterwards.
#   B. Edit e2e_consultant2, change its username to e2e_consultant2_tt815 (not an
#      address): Save shows the same message on the Username box, and the account is
#      still called e2e_consultant2.
# The message appearing on the right box is the control: it proves the form saved
# through the new rule, not that Save silently did nothing.
#
# SELECTORS. The two forms' fields were named for this spec (TT-815 follow-up):
# txtUsername, txtEmail, txtFullName, cbEmploymentStatus, btnSave.
#
# CLEANUP. If A ever creates the account, or B ever renames e2e_consultant2, that is
# a failure, and B renames the account back before exiting so the rest of the run
# keeps its fixture. A leaked A account is named in the failure for deletion by hand.
#
# Env: TT_BASE_URL, TT_ADMIN_USER, TT_ADMIN_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_accounts.sh"

EPOCH="$(date +%s)"
NEW_LOGIN="e2e-tt815-$EPOCH"
NEW_MAIL="jnorris+tt815${EPOCH}@titanconsulting.net"
EDIT_LOGIN="e2e_consultant2"
EDIT_BAD="e2e_consultant2_tt815"
MSG="must be an email address"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

# The visible validation message inside the LAST copy of .mx-name-<widget> (stale
# copies of these popups stay in the DOM -- see lib/_accounts.sh).
field_message() {
  acct_ev "() => { const w=[...document.querySelectorAll('.mx-name-$1')].filter(e=>e.offsetParent!==null).pop(); if(!w) return 'NOFIELD'; const m=w.querySelector('.mx-validation-message'); return m ? (m.innerText||'').trim() : ''; }"
}

# wait_for <widget> -- until a visible .mx-name-<widget> is on screen (12s).
wait_for() {
  local i
  for i in $(seq 1 12); do
    [ "$(acct_ev "() => String([...document.querySelectorAll('.mx-name-$1')].some(e=>e.offsetParent!==null))")" = "true" ] && return 0
    sleep 1
  done
  return 1
}

# click_last <widget> -- click the last visible .mx-name-<widget>.
click_last() {
  acct_ev "() => { const b=[...document.querySelectorAll('.mx-name-$1')].filter(e=>e.offsetParent!==null).pop(); if(!b) return 'NONE'; b.click(); return 'ok'; }"
}

# message_on <widget> -- poll up to 10s for a validation message on that widget.
message_on() {
  local i m=""
  for i in $(seq 1 10); do
    m="$(field_message "$1")"
    [ -n "$m" ] && [ "$m" != "NOFIELD" ] && { printf '%s' "$m"; return 0; }
    sleep 1
  done
  printf '%s' "$m"
}

restore_edit_login() {
  case "$(acct_state "$EDIT_BAD")" in
    ABSENT|ERR:*) return 0 ;;
  esac
  note "restoring $EDIT_BAD -> $EDIT_LOGIN"
  acct_open_edit "$EDIT_BAD" || { bad "could not reopen $EDIT_BAD to rename it back ($ACCT_LAST_ERROR) -- rename it to $EDIT_LOGIN by hand"; return 1; }
  acct_fill_field "mx-name-txtUsername" "$EDIT_LOGIN"
  click_last "btnSave" >/dev/null
  sleep 5
  tt_clear_dialogs 4 >/dev/null 2>&1
  [ "$(acct_state "$EDIT_LOGIN")" = "ABSENT" ] && bad "rename back to $EDIT_LOGIN did not take -- rename $EDIT_BAD by hand"
}
trap restore_edit_login EXIT

acct_admin_login "${TT_ADMIN_USER:-MxAdmin}" "${TT_ADMIN_PASS:-${TT_PASS:-}}"

# ---------------------------------------------------------------- A. new account
acct_overview_open || tt_fail "$ACCT_LAST_ERROR"
r="$(acct_click_caption "new local user")"
[ "$r" = "ok" ] || tt_fail "no 'New local user' button on Account Overview ($r)"
wait_for "txtUsername" || tt_fail "the New Account form never showed .mx-name-txtUsername -- is the TT-815 widget naming deployed?"

acct_fill_field "mx-name-txtFullName" "E2E TT815 $EPOCH" || tt_fail "$ACCT_LAST_ERROR"
acct_fill_field "mx-name-txtUsername" "$NEW_LOGIN"       || tt_fail "$ACCT_LAST_ERROR"
acct_fill_field "mx-name-txtEmail" "$NEW_MAIL"           || tt_fail "$ACCT_LAST_ERROR"
# Employment status is checked BEFORE the email rule, so it must be set or the form
# is refused for the wrong reason.
tt_combobox_select_first ".mx-name-cbEmploymentStatus"
click_last "btnSave" >/dev/null

M="$(message_on "txtUsername")"
case "$M" in
  *"$MSG"*) note "A: Username box says: $M" ;;
  *)        bad "A: expected '$MSG' on the Username box, got '${M:-nothing}' (all messages: $(acct_validation))" ;;
esac
acct_click_caption "cancel" >/dev/null
sleep 2
tt_clear_dialogs 4 >/dev/null 2>&1
S="$(acct_state "$NEW_LOGIN")"
[ "$S" = "ABSENT" ] || bad "A: an account '$NEW_LOGIN' exists after a refused save ($S) -- delete it by hand"

# ---------------------------------------------------------------- B. edit account
acct_open_edit "$EDIT_LOGIN" || tt_fail "$ACCT_LAST_ERROR"
acct_fill_field "mx-name-txtUsername" "$EDIT_BAD" || tt_fail "$ACCT_LAST_ERROR"
click_last "btnSave" >/dev/null

M="$(message_on "txtUsername")"
case "$M" in
  *"$MSG"*) note "B: Username box says: $M" ;;
  *)        bad "B: expected '$MSG' on the Username box, got '${M:-nothing}' (all messages: $(acct_validation))" ;;
esac
acct_click_caption "cancel" >/dev/null
sleep 2
tt_clear_dialogs 4 >/dev/null 2>&1
[ "$(acct_state "$EDIT_BAD")" = "ABSENT" ] || bad "B: $EDIT_LOGIN was renamed to $EDIT_BAD by a save that should have been refused"

[ "$fails" -eq 0 ] || tt_fail "$fails check(s) failed"
echo "PASS: verify-tt815-username-must-be-email — both account forms refuse a username that is not an email address"
