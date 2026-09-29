#!/usr/bin/env bash
# CC contacts (Accounts Overview -> CC Contacts): an admin can add one, is stopped
# from adding a bad or duplicate address, can rename one, can move one contact's
# users onto another, and can delete one.
#
# tt-timeout: 12m
#
# WHY THIS EXISTS. Model 771be886 (2026-09-28) added CC contacts: people copied on a
# user's "your timesheet has been processed" email (Main.ACT_Approval_Email). They
# are kept on a tab of Core.Account_Overview (lstCCContacts), edited on
# Core.CCContact_NewEdit, validated by Core.SUB_CCContact_Validate, and replaced or
# deleted through Core.CCContactReplace_Popup. Seven unit tests cover the
# microflows; nothing drove the screens. An address with ';' or ',' in it would be
# split by the mail server into several recipients, which is why the validation
# refuses separators - and that refusal is what an admin actually meets.
#
# WHAT IT ASSERTS
#   A. an address with ';' is refused with "Enter a valid email address", and so is
#      one with ','; neither is created;
#   B. a valid contact saves and is listed with its name and email;
#   C. a second contact with the SAME address is refused with "<first> already has
#      this email address", and not created;
#   D. Edit renames it, and the list shows the new name;
#   E. Replace moves every user of contact 1 onto contact 2 - the popup counts the
#      user it is about to move, and afterwards the account is linked to 2 and no
#      longer to 1 (read from the data layer);
#   F. Delete removes the contact from the list and from the data.
#
# WHAT IT DOES NOT COVER, AND WHY. Attaching a contact to a user through the UI
# needs Core.Account_Edit's Save button, which is still the auto-generated
# saveButton1 (and the row's Edit button is actionButton3), so E links the account
# through the data API as setup instead - Josh must rename those two before the
# picker path (cbCCContacts / btnAddCCContact) can be driven. And the CC on the
# processed-timesheet email itself is not asserted: Emails Sent
# (Main.EmailsSent_Overview) shows only To (txtRowTo), with no CC column.
#
# Consumes: two Core.CCContact rows "E2E CC <epoch> ..." (deleted by F, and by the
# exit trap if F never ran), and a temporary link from e2e_consultant2 to one of
# them (removed on exit). Env: TT_BASE_URL, TT_ADMIN_USER, TT_ADMIN_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_accounts.sh"
source "$TT_ROOT/lib/_authz.sh"

EPOCH="$(date +%s)"
NAME1="E2E CC $EPOCH One"
NAME1B="E2E CC $EPOCH Renamed"
NAME2="E2E CC $EPOCH Two"
MAIL1="jnorris+cc${EPOCH}a@titanconsulting.net"
MAIL2="jnorris+cc${EPOCH}b@titanconsulting.net"
LINKED_LOGIN="e2e_consultant2"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

cc_count() { local n; n="$(tt_authz_count "//Core.CCContact[$1]")"; case "$n" in ERR:*|''|*[!0-9]*) echo "ERR:$n" ;; *) echo "$n" ;; esac; }
# linked <email> - how many accounts named $LINKED_LOGIN that contact is linked to.
linked() { cc_count "Email = '$1'][Core.CCContact_Account/Administration.Account/Name = '$LINKED_LOGIN'"; }

cleanup() {
  # Remove anything this run left, whichever step it stopped at. Deleting the contact
  # drops its links with it.
  ev "() => new Promise(res => { try { mx.data.get({ xpath: \"//Core.CCContact[starts-with(FullName, 'E2E CC $EPOCH')]\", callback: o => { if(!o.length) return res('none'); mx.data.remove({ guids: o.map(x=>x.getGuid()), callback: () => res('removed:'+o.length), error: e => res('ERR:'+e.message) }); }, error: e => res('ERR:'+e.message) }); } catch(e) { res('ERR:'+e.message); } })" \
    | sed 's/^/  (cleanup: /; s/$/)/'
}
trap cleanup EXIT

validations() { ev "() => [...document.querySelectorAll('.mx-validation-message, .alert-danger')].filter(e=>e.offsetParent!==null).map(e=>(e.innerText||'').trim()).filter(Boolean).join(' ~ ')"; }

open_cc_tab() {
  acct_overview_open || tt_fail "$ACCT_LAST_ERROR"
  for _ in 1 2 3 4 5; do
    playwright-cli click ".mx-name-tabCCContacts" >/dev/null 2>&1 || tt_try_click_text "CC Contacts" >/dev/null 2>&1 || true
    sleep 2
    [ "$(ev "() => String(!!document.querySelector('.mx-name-btnNewCCContact') && document.querySelector('.mx-name-btnNewCCContact').offsetParent!==null)")" = "true" ] && return 0
  done
  tt_fail "the CC Contacts tab (tabCCContacts / btnNewCCContact) did not open on Accounts Overview"
}

# cc_rows - "name|email" per listed contact, ~-joined.
cc_rows() { ev "() => [...document.querySelectorAll('.mx-name-lstCCContacts .mx-name-cntCCContactRow')].map(r=>((r.querySelector('.mx-name-txtRowCCFullName')||{}).innerText||'').trim()+'|'+((r.querySelector('.mx-name-txtRowCCEmail')||{}).innerText||'').trim()).join('~')"; }
# cc_row_click <email> <button> - press a row action on the row showing <email>.
cc_row_click() {
  local r; r="$(ev "() => { const row=[...document.querySelectorAll('.mx-name-lstCCContacts .mx-name-cntCCContactRow')].find(r=>((r.querySelector('.mx-name-txtRowCCEmail')||{}).innerText||'').trim()==='$1'); if(!row) return 'NOROW'; const b=row.querySelector('.mx-name-$2'); if(!b) return 'NOBUTTON'; b.click(); return 'ok'; }")"
  [ "$r" = "ok" ] || tt_fail "row action $2 on '$1': $r"
  sleep 3
}

# new_contact <name> <email> - open New, fill, Save. Leaves the form open if refused.
new_contact() {
  playwright-cli click ".mx-name-btnNewCCContact" >/dev/null 2>&1
  tt_wait_for ".mx-name-txtCCContactFullName input" "the New CC contact form"
  tt_fill ".mx-name-txtCCContactFullName input" "$1"
  tt_fill ".mx-name-txtCCContactEmail input" "$2"
  playwright-cli click ".mx-name-btnCCContactSave" >/dev/null 2>&1
  sleep 3
}
form_open()   { ev "() => String(!!document.querySelector('.mx-name-btnCCContactSave'))"; }
cancel_form() { playwright-cli click ".mx-name-btnCCContactCancel" >/dev/null 2>&1; sleep 2; }

acct_admin_login "${TT_ADMIN_USER:-MxAdmin}" "${TT_ADMIN_PASS:-${TT_PASS:-}}"
open_cc_tab

# ------------------------------------------------------------------ A. separators refused
for sep in ";" ","; do
  BADMAIL="jnorris+cc${EPOCH}a@titanconsulting.net${sep}other@titanconsulting.net"
  new_contact "$NAME1" "$BADMAIL"
  V="$(validations)"
  N="$(cc_count "starts-with(FullName, 'E2E CC $EPOCH')")"
  if [ "$(form_open)" = "true" ] && [ "${V#*Enter a valid email address}" != "$V" ] && [ "$N" = "0" ]; then
    note "A ok: '$sep' in the address refused ($V)"
  else
    bad "A: an address containing '$sep' - form open=$(form_open), validation [$V], contacts created [$N] (expected true / 'Enter a valid email address' / 0)"
  fi
  cancel_form
done

# ------------------------------------------------------------------ B. valid saves, listed
new_contact "$NAME1" "$MAIL1"
[ "$(form_open)" = "false" ] || bad "B: the form is still open after a valid Save: [$(validations)]"
ROWS="$(cc_rows)"
case "~$ROWS~" in
  *"~$NAME1|$MAIL1~"*) note "B ok: '$NAME1' <$MAIL1> is listed" ;;
  *) bad "B: '$NAME1|$MAIL1' is not in the list: ${ROWS:0:400}" ;;
esac
[ "$(cc_count "Email = '$MAIL1'")" = "1" ] || bad "B: the data layer does not hold exactly one contact with $MAIL1"

# ------------------------------------------------------------------ C. duplicate refused
new_contact "$NAME2" "$MAIL1"
V="$(validations)"
N="$(cc_count "Email = '$MAIL1'")"
if [ "$(form_open)" = "true" ] && [ "${V#*$NAME1 already has this email address}" != "$V" ] && [ "$N" = "1" ]; then
  note "C ok: duplicate address refused ($V)"
else
  bad "C: a second contact with $MAIL1 - form open=$(form_open), validation [$V], contacts with it [$N] (expected true / '$NAME1 already has this email address' / 1)"
fi
cancel_form

# ------------------------------------------------------------------ D. rename
cc_row_click "$MAIL1" btnEditCCContact
tt_wait_for ".mx-name-txtCCContactFullName input" "the Edit CC contact form"
tt_fill ".mx-name-txtCCContactFullName input" "$NAME1B"
playwright-cli click ".mx-name-btnCCContactSave" >/dev/null 2>&1
sleep 3
ROWS="$(cc_rows)"
case "~$ROWS~" in
  *"~$NAME1B|$MAIL1~"*) note "D ok: renamed to '$NAME1B'" ;;
  *) bad "D: after Edit the list does not show '$NAME1B|$MAIL1': ${ROWS:0:400}" ;;
esac

# ------------------------------------------------------------------ E. replace moves users
new_contact "$NAME2" "$MAIL2"
[ "$(form_open)" = "false" ] || tt_fail "E: could not create the second contact: [$(validations)]"
# Setup through the data API - see WHAT IT DOES NOT COVER.
LINK="$(ev "() => new Promise(res => { try { mx.data.get({ xpath: \"//Administration.Account[Name = '$LINKED_LOGIN']\", filter:{amount:1}, callback: a => { if(!a.length) return res('ERR:no-account'); mx.data.get({ xpath: \"//Core.CCContact[Email = '$MAIL1']\", filter:{amount:1}, callback: c => { if(!c.length) return res('ERR:no-contact'); c[0].addReferences('Core.CCContact_Account', [a[0].getGuid()]); mx.data.commit({ mxobj: c[0], callback: () => res('ok'), error: e => res('ERR:commit-'+e.message) }); }, error: e => res('ERR:'+e.message) }); }, error: e => res('ERR:'+e.message) }); } catch(e) { res('ERR:'+e.message); } })")"
[ "$LINK" = "ok" ] || tt_fail "E: could not link $LINKED_LOGIN to contact 1 as setup ($LINK)"
[ "$(linked "$MAIL1")" = "1" ] || tt_fail "E: setup link did not land ($LINKED_LOGIN is not linked to $MAIL1)"

open_cc_tab
cc_row_click "$MAIL1" btnReplaceCCContact
tt_wait_for ".mx-name-cbReplaceWith" "the Replace popup (cbReplaceWith)"
USERS="$(ev "() => ((document.querySelector('.mx-name-txtReplaceUsers')||{}).innerText||'').replace(/\\s+/g,' ').trim()")"
case "$USERS" in
  *" 1 user"*) note "E ok: the popup says: $USERS" ;;
  *)           bad "E: the Replace popup should count the 1 linked user, it reads [$USERS]" ;;
esac
tt_combobox_select_text ".mx-name-cbReplaceWith" "$NAME2" || tt_fail "E: '$NAME2' is not offered as a replacement"
playwright-cli click ".mx-name-btnReplaceApply" >/dev/null 2>&1
sleep 3
tt_clear_dialogs 3 >/dev/null 2>&1 || true
L1="$(linked "$MAIL1")"; L2="$(linked "$MAIL2")"
if [ "$L1" = "0" ] && [ "$L2" = "1" ]; then
  note "E ok: $LINKED_LOGIN moved from contact 1 to contact 2"
else
  bad "E: after Replace, $LINKED_LOGIN is linked to contact 1 [$L1] and contact 2 [$L2] (expected 0 and 1)"
fi

# ------------------------------------------------------------------ F. delete
open_cc_tab
for m in "$MAIL1" "$MAIL2"; do
  cc_row_click "$m" btnDeleteCCContact
  tt_wait_for ".mx-name-btnDelete" "the Delete confirmation (btnDelete)"
  playwright-cli click ".mx-name-btnDelete" >/dev/null 2>&1
  sleep 3
  tt_clear_dialogs 3 >/dev/null 2>&1 || true
done
ROWS="$(cc_rows)"
N="$(cc_count "starts-with(FullName, 'E2E CC $EPOCH')")"
case "~$ROWS~" in
  *"$MAIL1"*|*"$MAIL2"*) bad "F: a deleted contact is still listed: ${ROWS:0:400}" ;;
  *) [ "$N" = "0" ] && note "F ok: both contacts deleted" || bad "F: the list no longer shows them but the data layer still holds [$N]" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-admin-cc-contacts - $fails problem(s) with CC contact administration."
  exit 1
fi
echo "PASS: verify-admin-cc-contacts - bad and duplicate addresses refused; add, rename, replace-on-every-user and delete all work."
