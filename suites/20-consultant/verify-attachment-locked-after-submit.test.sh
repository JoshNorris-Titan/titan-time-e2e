#!/usr/bin/env bash
# Once a week is submitted, its expense report and attachments are read-only for the
# consultant: the docs popup says so, offers no uploader and no Save, and shows the
# files as a read-only list. On a Draft week the same popup is fully editable.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. Before the attachments-and-expenses change (Gate 2 approved
# 2026-10-07, option 2a) a consultant could keep uploading receipts, changing the
# expense amount and deleting attachments on a week that a manager had already
# approved or HR had exported. The change keeps the Exp/Tim button on every row
# (D2) and makes Main.AssignmentAttachment_Upload read-only on a submitted entry,
# using the same rule as the hours (Draft, Rejected or empty = editable):
#   - txtLockedNotice - a notice at the top, shown only when locked;
#   - each File Uploader becomes two (D3): the editable one (fileUploader1 on the
#     Expense Report tab, fileUploader2 on Timesheet Attachments) and a read-only
#     twin (fileExpenseReceiptsView, fileAttachmentsView), each shown by the
#     editable condition or its negation;
#   - the expense amount (txtTotalExpenseAmount) is read-only;
#   - btnExpenseUploadSave, btnAttachmentUploadSave and Discard changes are hidden.
# A conditionally hidden Mendix widget is not in the DOM at all, so "absent" below
# means "no element with that name".
#
# DISCARD IS AUTO-NAMED. Its widget name is actionButton8, which this suite
# otherwise forbids because auto names renumber when a page is edited. It is used
# here because the change did not rename it; rename it in Studio Pro (for example
# btnUploadDiscard) and update DISCARD below.
#
# WHAT IT ASSERTS (e2e_consultant)
#   LOCKED - a row whose day cells are read-only on a week that offers no actions
#   (submitted: AwaitingManagerApproval or later; one is submitted on
#   'E2E Manager Approval' when none exists):
#     L1. txtLockedNotice is visible;
#     L2. fileUploader1, fileUploader2, btnExpenseUploadSave, btnAttachmentUploadSave
#         and Discard (actionButton8) are absent, on both tabs;
#     L3. fileExpenseReceiptsView is present on the Expense Report tab and
#         fileAttachmentsView on the Timesheet Attachments tab;
#     L4. the expense amount input is read-only (or not an input at all).
#   EDITABLE (control) - a row with editable day cells on a week that still offers
#   its actions:
#     E1. no txtLockedNotice; E2. both uploaders, both Saves and Discard present;
#     E3. neither read-only twin present; E4. the amount input is editable.
# The control is what makes the locked half mean something: the same selectors
# must find the editable widgets on an editable week.
#
# RED ON DEV UNTIL THE CHANGE IS DEPLOYED (model saved 2026-10-07, not committed
# or deployed): the locked half fails L1-L4 there (no notice, uploaders shown, no
# read-only twins). Expected green after the deploy.
#
# Consumes: possibly one submitted week on 'E2E Manager Approval'. Opening the
# popup on an editable week can create an empty expense report for that entry,
# which the app already did before this change. Uploads nothing; every popup is
# closed without saving.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

CUSER="${TT_LOCKED_USER:-e2e_consultant}"
SEED_PROJECT="${TT_LOCKED_SEED_PROJECT:-E2E Manager Approval}"
DISCARD="actionButton8"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

# pick_row <locked|editable> - tag the first assignment row of the week on screen
# whose Monday cell is read-only (locked) or editable (editable) and that has a docs
# button: data-tt-docs="1". Echoes ok / none.
pick_row() {
  ev "() => { document.querySelectorAll('[data-tt-docs]').forEach(e=>e.removeAttribute('data-tt-docs')); const want='$1'; for (const it of document.querySelectorAll('.mx-name-galAssignmentRows .widget-gallery-item')) { const inp=it.querySelector('.mx-name-txtDayMon input'); const b=it.querySelector('.mx-name-btnEntryDocs'); if(!inp||!b) continue; const ed=!inp.readOnly && !inp.disabled; if((want==='editable')===ed){ it.setAttribute('data-tt-docs','1'); return 'ok'; } } return 'none'; }"
}

# find_week <locked|editable> <direction btnWeekNext|btnWeekPrev> - step until a week
# matches (locked: no action buttons and a locked row; editable: actions and an
# editable row). Echoes the week or ''.
find_week() {
  local i act
  for i in $(seq 1 16); do
    act="$(tt_week_actionable)"
    if { [ "$1" = locked ] && [ "$act" = "false" ]; } || { [ "$1" = editable ] && [ "$act" = "true" ]; }; then
      [ "$(pick_row "$1")" = "ok" ] && { tt_current_week; return 0; }
    fi
    playwright-cli click ".mx-name-$2" >/dev/null 2>&1
    sleep 2
  done
  echo ""
}

open_docs() {
  playwright-cli click "[data-tt-docs='1'] .mx-name-btnEntryDocs" >/dev/null 2>&1 || tt_fail "could not click the picked row's docs button on $(tt_current_week)"
  tt_wait_for ".mx-name-tabExpenseUpload, .mx-name-tabTimesheetUpload" "the docs popup (AssignmentAttachment_Upload)"
  sleep 2
}
tab() {  # <tabExpenseUpload|tabTimesheetUpload>
  ev "() => { const n=document.querySelector('.mx-name-$1'); const t=n && (n.querySelector('a,[role=tab]')||n); if(t){ t.click(); return 'ok'; } return 'no-tab'; }" >/dev/null
  sleep 2
}
present() { ev "() => { const e=document.querySelector('.mx-name-$1'); return String(!!e && e.offsetParent!==null); }"; }
exists()  { ev "() => String(!!document.querySelector('.mx-name-$1'))"; }
amount_state() { ev "() => { const w=document.querySelector('.mx-name-txtTotalExpenseAmount'); if(!w) return 'absent'; const i=w.querySelector('input'); if(!i) return 'readonly'; return (i.readOnly||i.disabled) ? 'readonly' : 'editable'; }"; }
close_popup() { playwright-cli press Escape >/dev/null 2>&1; sleep 1; tt_dismiss_dialogs >/dev/null 2>&1; sleep 1; }

tt_login "$CUSER" "My Timesheets"

# ------------------------------------------------------------------ LOCKED
WL="$(find_week locked btnWeekPrev)"
if [ -z "$WL" ]; then
  note "no submitted week with a locked row near today - submitting one on '$SEED_PROJECT'"
  tt_consultant_submit_project_row "$SEED_PROJECT" >/dev/null
  tt_clear_dialogs 4 >/dev/null 2>&1
  tt_login "$CUSER" "My Timesheets"
  WL="$(find_week locked btnWeekNext)"
fi
[ -n "$WL" ] || tt_fail "setup: no week with a locked (submitted) row and a docs button could be found or made for $CUSER"
note "locked: week $WL (data layer: $(tt_week_status "$CUSER" "$WL"))"
open_docs
[ "$(present txtLockedNotice)" = "true" ] && note "L1 ok: txtLockedNotice is shown" || bad "L1: no visible txtLockedNotice on a submitted week's docs popup"
for t in tabExpenseUpload tabTimesheetUpload; do
  tab "$t"
  for w in fileUploader1 fileUploader2 btnExpenseUploadSave btnAttachmentUploadSave "$DISCARD"; do
    [ "$(exists "$w")" = "false" ] || bad "L2: $w is on the page ($t) of a submitted week"
  done
  case "$t" in
    tabExpenseUpload)   [ "$(exists fileExpenseReceiptsView)" = "true" ] && note "L3 ok: fileExpenseReceiptsView on the Expense Report tab" || bad "L3: no fileExpenseReceiptsView on the Expense Report tab"
                        A="$(amount_state)"; [ "$A" = "readonly" ] && note "L4 ok: the expense amount is read-only" || bad "L4: the expense amount is [$A] on a submitted week" ;;
    tabTimesheetUpload) [ "$(exists fileAttachmentsView)" = "true" ] && note "L3 ok: fileAttachmentsView on the Timesheet Attachments tab" || bad "L3: no fileAttachmentsView on the Timesheet Attachments tab" ;;
  esac
done
close_popup

# ------------------------------------------------------------------ EDITABLE (control)
tt_login "$CUSER" "My Timesheets"
WE="$(find_week editable btnWeekNext)"
[ -n "$WE" ] || tt_fail "control: no week with actions and an editable row within 16 weeks of today for $CUSER - was 00-setup skipped?"
note "editable: week $WE"
open_docs
[ "$(present txtLockedNotice)" = "false" ] && note "E1 ok: no locked notice" || bad "E1: txtLockedNotice is shown on an editable week"
tab tabExpenseUpload
for w in fileUploader1 btnExpenseUploadSave "$DISCARD"; do [ "$(exists "$w")" = "true" ] || bad "E2: $w is missing on the Expense Report tab of an editable week"; done
[ "$(exists fileExpenseReceiptsView)" = "false" ] || bad "E3: the read-only fileExpenseReceiptsView is shown on an editable week"
A="$(amount_state)"; [ "$A" = "editable" ] && note "E4 ok: the expense amount is editable" || bad "E4: the expense amount is [$A] on an editable week"
tab tabTimesheetUpload
for w in fileUploader2 btnAttachmentUploadSave; do [ "$(exists "$w")" = "true" ] || bad "E2: $w is missing on the Timesheet Attachments tab of an editable week"; done
[ "$(exists fileAttachmentsView)" = "false" ] || bad "E3: the read-only fileAttachmentsView is shown on an editable week"
close_popup

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-attachment-locked-after-submit - $fails problem(s) with the docs popup's locked/editable states."
  exit 1
fi
echo "PASS: verify-attachment-locked-after-submit - a submitted week's docs are read-only, an editable week's are not."
