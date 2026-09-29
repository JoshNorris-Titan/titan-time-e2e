#!/usr/bin/env bash
# The assignment form refuses an empty save and names every field it needs.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. Main.SUB_AssignmentValidation refuses a save that is missing
# any of Company, Project, Consultant, StartDate, EndDate, TotalBudgetHours or
# WeeklyHours - "Company is required!", "Project is required!" and "Consultant is
# required!", and "This is required!" on each of the four date and number members.
#
# TWO CHANNELS, READ BOTH. The three association checks are Show message
# activities (one "Warning" popup each, stacked over the form), while the four
# member checks are validation feedback rendered under the fields. This spec used
# to read .mx-validation-message only, so it could never see the popups and
# reported "does not include 'Company is required'" while the app was showing it
# (CI run 36553422511; confirmed on dev 2026-09-29: three Warning popups, four
# field messages).
#
# Nothing exercises it. verify-assignment-dropdowns-sorted opens the very same
# form and only reads the order of a combobox; it never presses Save. The whole
# 50-titan-manager folder has no negative test, so the entire master-data WRITE
# surface is covered by two cancel-rollback cases in tt729 and nothing else.
#
# This matters more than an ordinary required-field check because of what a
# half-built assignment does downstream: RULE_Assignment_Active decides which
# weeks a consultant can bill against from StartDate and EndDate, and
# SUB_Assignment_FilterActive materialises entries from it. An assignment saved
# without dates does not fail loudly - it silently renders no rows, and the
# consultant simply cannot log time with no error to explain why.
#
# WHAT IT ASSERTS
#   A. saving an empty form is refused;
#   B. the complaint names the fields rather than merely existing - at least
#      Company and Consultant by name, plus the four "This is required!" members,
#      so a single unrelated validation cannot satisfy this test;
#   C. the form does NOT close - a refused save that closes the form has lost the
#      user's input, and is a different bug worth catching here;
#   D. no assignment was created, counted through the data layer before and after.
#
# D is the one that would catch the failure mode fx_create_assignment guards
# against in its own code: this form has looked refused while committing.
#
# Consumes: opens the assignment form and cancels. Creates nothing.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/lib/_authz.sh"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

validations() {
  playwright-cli eval "() => [...document.querySelectorAll('.mx-validation-message')].filter(e=>e.offsetParent!==null).map(e=>(e.innerText||'').trim()).filter(Boolean).join(' ~ ')" 2>/dev/null | _tt_eval_str
}
# warnings - the text of every visible Warning popup, ' ~ '-joined. Mendix keeps
# closed dialogs in the DOM, so visibility is by layout box, not offsetParent
# (a dialog is position:fixed, whose offsetParent is always null).
warnings() {
  playwright-cli eval "() => [...document.querySelectorAll('.modal-dialog, .mx-dialog, [role=dialog]')].filter(d=>getComputedStyle(d).display!=='none' && d.getClientRects().length>0).map(d=>(d.innerText||'').replace(/\s+/g,' ').trim()).filter(t=>/^(×\s*)?Warning\b/.test(t)).join(' ~ ')" 2>/dev/null | _tt_eval_str
}
# dismiss_warnings - click OK on each visible Warning popup, leaving the form below.
dismiss_warnings() {
  local i r
  for i in 1 2 3 4 5 6; do
    r="$(playwright-cli eval "() => { const d=[...document.querySelectorAll('.modal-dialog, .mx-dialog, [role=dialog]')].filter(d=>getComputedStyle(d).display!=='none' && d.getClientRects().length>0).reverse().find(d=>/^(×\s*)?Warning\b/.test((d.innerText||'').trim())); if(!d) return 'NONE'; const b=[...d.querySelectorAll('button')].find(x=>/^ok\$/i.test((x.innerText||'').trim())); if(!b) return 'NOOK'; b.click(); return 'OK'; }" 2>/dev/null | _tt_eval_str)"
    [ "$r" = "OK" ] || return 0
    sleep 1
  done
}
form_open() {
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-txtWeeklyHours'))" 2>/dev/null | _tt_eval_str
}

tt_login "e2e_tm" "Add Customer"

BEFORE="$(tt_authz_count "//Main.Assignment")"
case "$BEFORE" in
  ERR:*|''|*[!0-9]*) tt_fail "could not count assignments before the attempt (read: [$BEFORE])" ;;
esac
note "assignments before: $BEFORE"

# ---------------------------------------------------------------- A. save it empty
playwright-cli click ".mx-name-btnAddAssignment" >/dev/null 2>&1
sleep 3
[ "$(form_open)" = "true" ] || tt_fail "the assignment form did not open, so nothing could be attempted"

playwright-cli click ".mx-name-btnSave" >/dev/null 2>&1
sleep 3

FIELD_MSG="$(validations)"
POPUP_MSG="$(warnings)"
MSG="$FIELD_MSG ~ $POPUP_MSG"
note "field messages: ${FIELD_MSG:-none}"
note "warning popups: ${POPUP_MSG:-none}"
if [ -n "$FIELD_MSG$POPUP_MSG" ]; then
  note "A ok: refused with: $MSG"
else
  bad "A: an entirely empty assignment form saved with no complaint at all"
fi

# ------------------------------------------------------------- B. it names the fields
for want in "Company is required" "Project is required" "Consultant is required"; do
  case "$POPUP_MSG" in
    *"$want"*) note "B ok: names '$want'" ;;
    *)         bad "B: the complaint does not include '$want' - got: ${MSG:-nothing}" ;;
  esac
done

REQ_COUNT="$(printf '%s' "$FIELD_MSG" | grep -o "This is required!" | grep -c . )"
if [ "${REQ_COUNT:-0}" -ge 4 ]; then
  note "B ok: $REQ_COUNT 'This is required!' message(s) for the date and number members"
else
  bad "B: only ${REQ_COUNT:-0} 'This is required!' message(s); StartDate, EndDate, TotalBudgetHours and WeeklyHours should each raise one"
fi

# --------------------------------------------------------------- C. the form stayed up
# The Warning popups sit over the form; clear them with OK so what is left is the
# form itself (or nothing, if the refused save closed it).
dismiss_warnings
if [ "$(form_open)" = "true" ]; then
  note "C ok: the form is still open"
else
  bad "C: the form closed on a refused save, so whatever the user had typed is gone"
fi

# ------------------------------------------------------------- D. nothing was written
playwright-cli click ".mx-name-btnCancel" >/dev/null 2>&1
sleep 2
fx_close_modals >/dev/null 2>&1 || note "note: the assignment form did not close cleanly"

AFTER="$(tt_authz_count "//Main.Assignment")"
case "$AFTER" in
  ERR:*|''|*[!0-9]*) bad "D: could not re-count assignments (read: [$AFTER])" ;;
  "$BEFORE")         note "D ok: still $AFTER assignment(s)" ;;
  *)                 bad "D: assignments went from $BEFORE to $AFTER across a save the form refused" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-assignment-required-fields — $fails problem(s) with the required-field guards."
  exit 1
fi
echo "PASS: verify-assignment-required-fields — an empty save was refused, named its fields, kept the form open and wrote nothing."
