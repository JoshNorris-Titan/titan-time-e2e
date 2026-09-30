#!/usr/bin/env bash
# Through the emailed link, the client can open and download the files a consultant
# attached to the week - and a browser that never opened the link cannot.
#
# tt-timeout: 15m
#
# WHY THIS EXISTS. The client's review popup (Main.Customer_ReviewTimesheetEntry)
# has two file surfaces: the Time Sheet Attachments tab (btnAttachmentView,
# btnAttachmentDownload) and the Expense Report tab (btnExpenseDownload - it was the
# auto-named actionButton8 until the customer-link security change named it). No
# spec ever put a file on an entry and then read it back through the link. The
# customer-link security change (2026-09-29) did two things to exactly these
# buttons: the three download microflows now refuse unless this session's visit
# covers the entry (Main.SUB_CustomerVisit_CoversEntry), and Anonymous's read of
# AssignmentAttachment, AttachmentDocument, ExpenseReport and ExpenseReportDocuments
# became visit-scoped. The first can break the customer's only way to see the
# paperwork; the second is the only thing standing between those files and anyone
# with the app's URL.
#
# WHAT IT ASSERTS
#   SETUP  the consultant fills a week on E2E Customer Approval, attaches
#          fixtures/attachment-test.png on the Timesheet Attachments tab and the same
#          file as an expense receipt (with an amount) on the Expense Report tab,
#          then submits; HR reminds the client. HR then reads both documents back by
#          the entry's guid - the CONTROL that says there is something to refuse.
#   A. through the link: the attachment is listed; btnAttachmentDownload saves a
#      file of the fixture's exact size; btnAttachmentView fetches it or opens it
#      (a /file request or a new tab) without showing the refusal;
#   B. through the link: the receipt is listed; btnExpenseDownload saves a file of
#      the fixture's exact size;
#   C. a fresh anonymous session that never opened the link: every one of the four
#      entities reads 0 (or is refused) for this entry although HR sees them; the
#      document's /file URL does not return the file; and the attachment download
#      action, called with the document's guid, saves nothing.
#
# THE UPLOAD POPUP (Main.AssignmentAttachment_Upload) is selected by name: its tabs
# tabTimesheetUpload / tabExpenseUpload and its Save buttons btnAttachmentUploadSave /
# btnExpenseUploadSave (Josh's 2026-09-30 rename; before it they were the auto-named
# tabPage1 / tabPage2 / actionButton7 / actionButton1 and this step used captions).
#
# Consumes: one E2E Consultant week on E2E Customer Approval, left
# AwaitingCustomerApproval with one attachment and one receipt on it.
# Env: TT_BASE_URL, TT_ROLE_PASS, TT_ADMIN_USER, TT_ADMIN_PASS, TT_ATTACHMENT_FILE
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"   # FX_APPROVER_EMAIL: the approver on E2E Customer Approval
source "$TT_ROOT/lib/_authz.sh"
source "$TT_ROOT/lib/_changelog.sh"
source "$TT_ROOT/lib/_tt683.sh"      # _tt683_saved_since: find a file the browser saved
source "$TT_ROOT/lib/_customer_link.sh"

CONSULTANT_NAME="E2E Consultant"
PROJECT="E2E Customer Approval"
APPROVER="$FX_APPROVER_EMAIL"
FIXDIR="$(cd "$TT_ROOT/fixtures" && { pwd -W 2>/dev/null || pwd; })"
FILE="${TT_ATTACHMENT_FILE:-$FIXDIR/attachment-test.png}"
FNAME="$(basename "$FILE")"
[ -f "$FILE" ] || tt_fail "attachment fixture not found: $FILE (set TT_ATTACHMENT_FILE)"
FSIZE="$(wc -c < "$FILE" | tr -d ' ')"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

# ------------------------------------------------------------------ helpers

# dlg_click_name <widget name> — press the visible .mx-name-<name> button. Echoes
# ok | none.
dlg_click_name() {
  playwright-cli eval "() => { const b=[...document.querySelectorAll('.mx-name-$1')].find(x=>x.offsetParent!==null); if(!b) return 'none'; b.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str
}

# row_docs_click <ord> — the Exp/Tim button on the <ord>-th week row. A row is the
# ancestor of its Mon cell that holds exactly one Mon cell (see tt_week_row_of).
row_docs_click() {
  playwright-cli eval "() => { const m=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')][$1 - 1]; if(!m) return 'norow'; let el=m, row=null; for(let k=0;k<12;k++){ const p=el.parentElement; if(!p || p.querySelectorAll('.mx-name-txtDayMon').length!==1) { row=el; break; } el=p; } const b=(row||el).querySelector('.mx-name-btnEntryDocs'); if(!b) return 'nobutton'; b.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str
}

# upload_into <uploader widget name> — open the file chooser on that FileUploader's
# drop zone and hand it $FILE, then wait for the name to show.
upload_into() {
  local i
  [ "$(cl_visible ".mx-name-$1 .dropzone")" = "true" ] || { echo "nodropzone"; return 1; }
  playwright-cli click ".mx-name-$1 .dropzone" >/dev/null 2>&1
  sleep 1
  playwright-cli upload "$FILE" >/dev/null 2>&1
  for i in $(seq 1 10); do
    [ "$(playwright-cli eval "() => String(((($(_tt_dialog_js))||document.body).innerText||'').indexOf('$FNAME')>=0)" 2>/dev/null | _tt_eval_str)" = "true" ] && { echo "staged"; return 0; }
    sleep 1
  done
  echo "notstaged"; return 1
}

# file_requests — how many /file? requests the browser has made on this page.
file_requests() {
  playwright-cli requests --static 2>/dev/null | grep -cE '/file\?'
}

# saved_download <marker> — the file saved after <marker>, waited for up to 30 s.
saved_download() {
  local i p
  for i in $(seq 1 30); do
    p="$(_tt683_saved_since "$1")" && { printf '%s' "$p"; return 0; }
    sleep 1
  done
  return 1
}

# click_in_item <gallery> <button> — press <button> inside the <gallery> item whose
# text names $FNAME. Echoes clicked | noitem | nobutton.
click_in_item() {
  playwright-cli eval "() => { const g=[...document.querySelectorAll('.mx-name-$1')].find(e=>e.offsetParent!==null); if(!g) return 'nogallery'; const it=[...g.querySelectorAll('.widget-gallery-item')].find(i=>(i.innerText||'').indexOf('$FNAME')>=0) || ((g.innerText||'').indexOf('$FNAME')>=0 ? g : null); if(!it) return 'noitem'; const b=[...it.querySelectorAll('.mx-name-$2')].find(e=>e.offsetParent!==null); if(!b) return 'nobutton'; b.click(); return 'clicked'; }" 2>/dev/null | _tt_eval_str
}

# ----------------------------------------------- SETUP 1. the consultant's week
tt_login "e2e_consultant" "My Timesheets"
ord=""
for i in $(seq 1 12); do
  ord="$(tt_week_row_of "$PROJECT" editable)"
  if [ -n "$ord" ] && [ "$ord" != "0" ] && [ "$(cl_visible '.mx-name-btnSubmit')" = "true" ]; then break; fi
  ord=""
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
  sleep 2
done
[ -n "$ord" ] || tt_fail "no week with an editable '$PROJECT' row and a Submit button within 12 weeks"
WEEKKEY="$(tt_current_week)"
[ -n "$WEEKKEY" ] || tt_fail "could not read the week the grid is showing"
note "SETUP: '$PROJECT' is row $ord on week $WEEKKEY"

for d in Mon Tues Wed Thurs Fri; do
  tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, ${ord})" "8"
done
tt_commit_focused
sleep 1
playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
sleep 3
tt_clear_dialogs 4 >/dev/null 2>&1
mon="$(playwright-cli eval "() => String((document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon input')[$ord - 1]||{}).value||'')" 2>/dev/null | _tt_eval_str)"
case "$mon" in
  ""|0|0.0|0.00) tt_fail "the '$PROJECT' row's hours did not persist after Save Draft (Monday reads '$mon') - a zero-hour entry skips customer approval entirely" ;;
esac

# ------------------------------------------ SETUP 2. the timesheet attachment
r="$(row_docs_click "$ord")"
[ "$r" = "ok" ] || tt_fail "could not open the documents popup on the '$PROJECT' row ($r)"
sleep 3
[ "$(cl_click_tab tabTimesheetUpload)" = "ok" ] || tt_fail "the documents popup has no .mx-name-tabTimesheetUpload tab"
sleep 2
st="$(upload_into fileUploader2)" || tt_fail "the timesheet attachment did not stage in the uploader ($st)"
[ "$(dlg_click_name btnAttachmentUploadSave)" = "ok" ] || tt_fail "no visible .mx-name-btnAttachmentUploadSave on the Timesheet Attachments tab"
sleep 3
tt_clear_dialogs 4 >/dev/null 2>&1
note "SETUP: attached $FNAME to the week"

# ---------------------------------------------------- SETUP 3. the expense receipt
r="$(row_docs_click "$ord")"
[ "$r" = "ok" ] || tt_fail "could not reopen the documents popup on the '$PROJECT' row ($r)"
sleep 3
[ "$(cl_click_tab tabExpenseUpload)" = "ok" ] || tt_fail "the documents popup has no .mx-name-tabExpenseUpload tab"
sleep 2
tt_fill_commit ".mx-name-txtTotalExpenseAmount input" "12.34"
st="$(upload_into fileUploader1)" || tt_fail "the expense receipt did not stage in the uploader ($st)"
[ "$(dlg_click_name btnExpenseUploadSave)" = "ok" ] || tt_fail "no visible .mx-name-btnExpenseUploadSave on the Expense Report tab"
sleep 4
tt_clear_dialogs 4 >/dev/null 2>&1
note "SETUP: added a 12.34 expense with $FNAME as the receipt"

# ------------------------------------------------------------ SETUP 4. submit
playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
sleep 2
tt_clear_dialogs 8 || tt_fail "submit blocked by a dialog with no way forward: $TT_DIALOG_BLOCKED"
sleep 2

# ------------------------------------------------- SETUP 5. HR's control, then a link
tt_login "e2e_hr" "$TT_HR_READY"
GUID="$(cl_entry_guid "$CONSULTANT_NAME" "$PROJECT" "$WEEKKEY")"
case "$GUID" in
  ERR:*) tt_fail "HR could not read the entry just submitted ($GUID)" ;;
  "")    tt_fail "HR finds no AwaitingCustomerApproval entry for '$CONSULTANT_NAME' / '$PROJECT' in week $WEEKKEY after the submit" ;;
esac
ATT_XP="//Main.AttachmentDocument[Main.AttachmentDocument_AssignmentAttachment/Main.AssignmentAttachment/Main.AssignmentAttachment_AssignmentEntry = '$GUID']"
EXP_XP="//Main.ExpenseReportDocuments[Main.ExpenseReportDocuments_ExpenseReport/Main.ExpenseReport/Main.ExpenseReport_AssignmentEntry = '$GUID']"
AA_XP="//Main.AssignmentAttachment[Main.AssignmentAttachment_AssignmentEntry = '$GUID']"
ER_XP="//Main.ExpenseReport[Main.ExpenseReport_AssignmentEntry = '$GUID']"
declare -A HR_N=()
for xp in "$ATT_XP" "$EXP_XP" "$AA_XP" "$ER_XP"; do
  HR_N[$xp]="$(tt_authz_expect_count "control (HR): $xp" "$xp")"
  case "${HR_N[$xp]}" in ''|*[!0-9]*|0) tt_fail "HR reads [${HR_N[$xp]}] rows of $xp for entry $GUID - the upload did not land, so there is nothing to download or to refuse" ;; esac
done
DOC_GUID="$(playwright-cli eval "() => new Promise(res => { const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"$ATT_XP\", filter:{amount:1}, callback:o=>{ clearTimeout(t); res(o&&o.length?o[0].getGuid():''); }, error:e=>{ clearTimeout(t); res('ERR:'+e.message); } }); })" 2>/dev/null | _tt_eval_str)"
case "$DOC_GUID" in ''|ERR:*) tt_fail "HR could not read the attachment document's guid ($DOC_GUID)" ;; esac
note "SETUP: entry $GUID carries ${HR_N[$ATT_XP]} attachment document(s) and ${HR_N[$EXP_XP]} receipt(s) (HR)"

cl_remind_link "$CONSULTANT_NAME" "$PROJECT" "$APPROVER" \
  || tt_fail "HR has nothing to remind for '$CONSULTANT_NAME' / '$PROJECT' moments after it was submitted"

# ---------------------------------------------- A. the attachment, through the link
cl_open_link_cold "$CL_LINK" || tt_fail "the approval link did not open an approval page: $CL_LINK"
# Our week's leading "Mon DD", in both spellings the pages have used for a day < 10.
FRAG="${WEEKKEY%% - *}"
FRAG2="$(printf '%s' "$FRAG" | sed -E 's/ 0([0-9])$/ \1/')"
opened="$(tt_token_open_row "$CONSULTANT_NAME" "$FRAG")"
[ "$opened" = "nomatch" ] && [ "$FRAG2" != "$FRAG" ] && opened="$(tt_token_open_row "$CONSULTANT_NAME" "$FRAG2")"
case "$opened" in
  hit) ;;
  nomatch) tt_token_log_rows "$CONSULTANT_NAME"; tt_fail "the link lists entries but none for '$CONSULTANT_NAME' in week $WEEKKEY" ;;
  *) tt_fail "the link lists no pending entries at all" ;;
esac
tt_wait_for ".mx-name-btnCustomerApprove" "the review popup"
POPUP="$(tt_token_popup_text)"
case "$POPUP" in
  *"$PROJECT"*) ;;
  *) tt_fail "the opened entry is not on '$PROJECT': $POPUP" ;;
esac

[ "$(cl_click_tab tabAttachments)" = "ok" ] || tt_fail "no .mx-name-tabAttachments on the review popup"
listed=""
for _ in $(seq 1 10); do
  [ "$(playwright-cli eval "() => String([...document.querySelectorAll('.mx-name-gallery2')].some(g=>g.offsetParent!==null && (g.innerText||'').indexOf('$FNAME')>=0))" 2>/dev/null | _tt_eval_str)" = "true" ] && { listed=1; break; }
  sleep 1
done
if [ -z "$listed" ]; then
  bad "A: the Time Sheet Attachments tab does not list $FNAME, which HR reads on the entry"
else
  MARK="$(mktemp)"; sleep 1
  r="$(click_in_item gallery2 btnAttachmentDownload)"
  if [ "$r" != "clicked" ]; then
    bad "A: could not press btnAttachmentDownload on the $FNAME item ($r)"
  elif P="$(saved_download "$MARK")"; then
    got="$(wc -c < "$P" | tr -d ' ')"
    [ "$got" = "$FSIZE" ] && note "A: btnAttachmentDownload saved $got bytes - the fixture's exact size" \
      || bad "A: btnAttachmentDownload saved $got bytes, the fixture is $FSIZE ($P)"
  else
    bad "A: btnAttachmentDownload saved no file within 30 s. Dialog: $(cl_dialog_text)"
  fi
  rm -f "$MARK"
  cl_dismiss_refusal >/dev/null

  before_req="$(file_requests)"; before_tabs="$(playwright-cli tab-list 2>/dev/null | grep -c .)"
  r="$(click_in_item gallery2 btnAttachmentView)"
  if [ "$r" != "clicked" ]; then
    bad "A: could not press btnAttachmentView on the $FNAME item ($r)"
  else
    sleep 5
    refusal="$(cl_dialog_text)"
    after_req="$(file_requests)"; after_tabs="$(playwright-cli tab-list 2>/dev/null | grep -c .)"
    if printf '%s' "$refusal" | grep -qi "$CL_REFUSAL_RE"; then
      bad "A: btnAttachmentView was refused for the customer whose link covers the entry: $refusal"
    elif [ "$after_req" -gt "$before_req" ] || [ "$after_tabs" -gt "$before_tabs" ]; then
      note "A: btnAttachmentView fetched the document (/file requests $before_req -> $after_req, tab-list lines $before_tabs -> $after_tabs)"
    else
      bad "A: btnAttachmentView neither requested /file nor opened a tab (requests $before_req -> $after_req, tabs $before_tabs -> $after_tabs)"
    fi
    if [ "$after_tabs" -gt "$before_tabs" ]; then
      playwright-cli tab-close >/dev/null 2>&1
      playwright-cli tab-select 0 >/dev/null 2>&1
    fi
  fi
fi

# ------------------------------------------------ B. the receipt, through the link
[ "$(cl_click_tab tabExpenseReport)" = "ok" ] || tt_fail "no .mx-name-tabExpenseReport on the review popup"
listed=""
for _ in $(seq 1 10); do
  [ "$(playwright-cli eval "() => String([...document.querySelectorAll('.mx-name-galExpenseAttachments')].some(g=>g.offsetParent!==null && (g.innerText||'').indexOf('$FNAME')>=0))" 2>/dev/null | _tt_eval_str)" = "true" ] && { listed=1; break; }
  sleep 1
done
if [ -z "$listed" ]; then
  bad "B: the Expense Report tab does not list the receipt $FNAME, which HR reads on the entry"
else
  MARK="$(mktemp)"; sleep 1
  r="$(click_in_item galExpenseAttachments btnExpenseDownload)"
  if [ "$r" != "clicked" ]; then
    bad "B: could not press btnExpenseDownload on the receipt ($r) - before the customer-link security change it was the auto-named actionButton8"
  elif P="$(saved_download "$MARK")"; then
    got="$(wc -c < "$P" | tr -d ' ')"
    [ "$got" = "$FSIZE" ] && note "B: btnExpenseDownload saved $got bytes - the fixture's exact size" \
      || bad "B: btnExpenseDownload saved $got bytes, the fixture is $FSIZE ($P)"
  else
    bad "B: btnExpenseDownload saved no file within 30 s. Dialog: $(cl_dialog_text)"
  fi
  rm -f "$MARK"
fi
tt_token_popup_close >/dev/null

# ------------------------------------------ C. a session that never opened the link
ROLES="$(tt_authz_anonymous)"
case "$ROLES" in *Anonymous*) ;; *) tt_fail "after clearing cookies the session does not hold Anonymous ($ROLES)" ;; esac
for xp in "$ATT_XP" "$EXP_XP" "$AA_XP" "$ER_XP"; do
  n="$(tt_authz_count "$xp")"
  case "$n" in
    ERR:no-mx-client) bad "C: the Mendix client API was not available for $xp" ;;
    ERR:*) note "C: $xp refused outright ($n); HR reads ${HR_N[$xp]}" ;;
    0)     note "C: $xp 0 rows; HR reads ${HR_N[$xp]}" ;;
    ''|*[!0-9]*) bad "C: $xp - not a count: [$n]" ;;
    *)     bad "C: a session that never opened the link reads $n row(s) of $xp" ;;
  esac
done

FETCH="$(playwright-cli eval "() => fetch('/file?guid=$DOC_GUID', { credentials: 'same-origin' }).then(r => r.arrayBuffer().then(b => r.status + ':' + b.byteLength)).catch(e => 'ERR:' + e.message)" 2>/dev/null | _tt_eval_str)"
case "$FETCH" in
  "200:$FSIZE") bad "C: GET /file?guid=<the attachment> returned the whole file ($FSIZE bytes) to a session that never opened the link" ;;
  *)            note "C: GET /file?guid=<the attachment> did not return the file ($FETCH)" ;;
esac

MARK="$(mktemp)"; sleep 1
ANS="$(tt_authz_action 'Main.SUB_downladAttachment' "$DOC_GUID")"
sleep 8
if P="$(_tt683_saved_since "$MARK")"; then
  bad "C: calling the attachment download for a session with no visit SAVED a file ($P, $(wc -c < "$P" | tr -d ' ') bytes); the call answered [$ANS]"
else
  note "C: the attachment download, called with no visit, saved nothing (it answered [$ANS])"
fi
rm -f "$MARK"

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-customer-attachment-download — $fails problem(s)."
  exit 1
fi
echo "PASS: verify-customer-attachment-download — through the link the customer downloaded the attachment and the receipt ($FSIZE bytes each) and opened the attachment; a session that never opened the link read none of the four and got no file"
