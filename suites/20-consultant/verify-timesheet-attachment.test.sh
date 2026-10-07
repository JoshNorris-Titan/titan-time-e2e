#!/usr/bin/env bash
# Attachment upload — a consultant can attach a supporting file to an AssignmentEntry
# while filling a timesheet, and it persists across a reopen.
#
# Flow: consultant timesheet → per-row "Exp/Tim" button (.mx-name-btnEntryDocs →
# Main.ACT_AssignmentEntry_Docs) → Main.AssignmentAttachment_Upload page → the
# "Timesheet Attachments" tab (tabTimesheetUpload; FileUploader `fileUploader2`, whose dataview
# source is Main.ACT_CreateTimeSheetAttachment) → upload a file → Save (save_changes +
# close_page) → reopen → the file is still listed.
#
# THE DATA SOURCE (attachments-and-expenses change, 2026-10-07). It creates only the
# Main.AssignmentAttachment holder, and COMMITS it only when the entry is the
# consultant's own and still Draft, Rejected or unset; on a submitted entry the page
# is read-only (verify-attachment-locked-after-submit). So this step must work on an
# entry that can still be changed: it walks to the first week that still offers its
# action buttons and opens the docs of a row whose day cells are editable - never
# simply the first row, which may belong to a week that is already submitted and
# would then fail for the right reason.
#
# playwright-cli file upload needs a LIVE filechooser: click the FileUploader dropzone to
# open the OS file dialog, THEN `playwright-cli upload <absolute-path>` fills it.
#
# NOTE: additive — adds one attachment to the entry per run (non-destructive).
#
# Environment:
#   TT_BASE_URL         app origin (no trailing slash)
#   TT_ROLE_PASS        e2e_* password (default E2ETest123!)
#   TT_ATTACH_USER      consultant account (default e2e_consultant — must have an assignment)
#   TT_ATTACHMENT_FILE  absolute path to the file to upload
#                       (default tests/fixtures/attachment-test.png; playwright-cli wants a
#                        forward-slash Windows path like C:/path/file.png)

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_rejection.sh"

CUSER="${TT_ATTACH_USER:-e2e_consultant}"
FIXDIR="$(cd "$TT_ROOT/fixtures" && { pwd -W 2>/dev/null || pwd; })"
ATTACH_FILE="${TT_ATTACHMENT_FILE:-$FIXDIR/attachment-test.png}"
FNAME="$(basename "$ATTACH_FILE")"

[ -f "$ATTACH_FILE" ] || tt_fail "attachment file not found: $ATTACH_FILE (set TT_ATTACHMENT_FILE)"

# pick_row - tag the first assignment row of the week on screen whose Monday cell is
# editable AND that has a docs button (data-tt-attach="1"); echoes ok / none. Editable
# day cells follow the entry's _IsEditable, which is what a Draft or Rejected (or not
# yet saved) entry has and a submitted one does not.
pick_row() {
  playwright-cli eval "() => { document.querySelectorAll('[data-tt-attach]').forEach(e=>e.removeAttribute('data-tt-attach')); const items=[...document.querySelectorAll('.mx-name-galAssignmentRows .widget-gallery-item')]; for (const it of items) { const inp=it.querySelector('.mx-name-txtDayMon input'); const b=it.querySelector('.mx-name-btnEntryDocs'); if (inp && !inp.readOnly && !inp.disabled && b) { it.setAttribute('data-tt-attach','1'); return 'ok'; } } return 'none'; }" 2>/dev/null | _tt_eval_str
}

# Opens the PICKED entry's docs page and switches to the Timesheet Attachments tab.
open_docs_timesheet_tab() {
  playwright-cli click "[data-tt-attach='1'] .mx-name-btnEntryDocs" >/dev/null 2>&1     || tt_fail "could not click the docs button of the picked row on $(tt_current_week)"
  sleep 3
  # By name (tabTimesheetUpload, Josh's 2026-09-30 rename).
  local r
  r="$(playwright-cli eval "() => { const n=document.querySelector('.mx-name-tabTimesheetUpload'); const t=n && (n.querySelector('a,[role=tab]')||n); if(t){t.click(); return 'ok';} return 'no-tab'; }" 2>/dev/null | _tt_eval_str)"
  [ "$r" = "ok" ] || tt_fail "the docs page has no .mx-name-tabTimesheetUpload tab ($r)"
  sleep 2
}

# True if the currently-open dialog/page text mentions the uploaded filename.
shows_file() {
  playwright-cli eval "() => String(((document.querySelector('.mx-dialog,.mx-window,[class*=modal]')||document.body).innerText||'').indexOf('$FNAME') >= 0)" 2>/dev/null | sed -n '2p' | grep -qiw true
}

# 1) Land on the consultant timesheet; need at least one assignment row with a docs button.
tt_login "$CUSER" "My Timesheets"
DOCS=$(playwright-cli eval "() => String(document.querySelectorAll('.mx-name-btnEntryDocs').length)" 2>/dev/null | sed -n '2p' | tr -d '"')
[ "${DOCS:-0}" != "0" ] || tt_fail "no assignment rows with an Exp/Tim docs button for $CUSER (needs an assignment)"

# 1b) Walk forward to a week that still offers its actions and has an editable row.
PICK=none
for _ in $(seq 1 12); do
  if [ "$(tt_week_actionable)" = "true" ]; then PICK="$(pick_row)"; [ "$PICK" = "ok" ] && break; fi
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
  sleep 2
done
[ "$PICK" = "ok" ] || tt_fail "no week within 12 of today has an editable (Draft/Rejected/unsaved) row with a docs button for $CUSER - was 00-setup skipped?"
WEEK="$(tt_current_week)"
echo "using an editable row on week $WEEK"

# 2) Open docs → Timesheet Attachments tab → upload the file into the FileUploader.
open_docs_timesheet_tab
playwright-cli eval "() => String(!!document.querySelector('.mx-name-fileUploader2 .dropzone'))" 2>/dev/null | sed -n '2p' | grep -qiw true \
  || tt_fail "FileUploader dropzone not found on the Timesheet Attachments tab"
playwright-cli click ".mx-name-fileUploader2 .dropzone" >/dev/null 2>&1   # opens the filechooser
sleep 1
playwright-cli upload "$ATTACH_FILE" >/dev/null 2>&1                      # fills it
sleep 2

# 3) The file must be staged in the uploader.
shows_file || tt_fail "'$FNAME' did not stage in the uploader after upload"
echo "staged $FNAME in the uploader"

# 4) Save (commits the AttachmentDocument + closes the page).
# By name (btnAttachmentUploadSave, the 2026-09-30 rename).
r="$(playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnAttachmentUploadSave'); if(b){b.click(); return 'saved';} return 'no-save'; }" 2>/dev/null | _tt_eval_str)"
[ "$r" = "saved" ] || tt_fail "no .mx-name-btnAttachmentUploadSave on the Timesheet Attachments tab ($r)"
sleep 3
tt_dismiss_dialogs >/dev/null 2>&1
sleep 2

# 5) Reopen the SAME row's docs page — the attachment must persist (proves it was
# committed to the entry). Closing the popup re-renders the grid, so re-tag the row.
[ "$(tt_current_week)" = "$WEEK" ] || tt_fail "after Save the grid shows week '$(tt_current_week)', not '$WEEK'"
[ "$(pick_row)" = "ok" ] || tt_fail "after Save, week $WEEK no longer has an editable row with a docs button"
open_docs_timesheet_tab
shows_file || tt_fail "'$FNAME' did not persist after Save + reopen — attachment was not saved to the AssignmentEntry"

# cleanup: close the popup
playwright-cli eval "() => { const p=document.querySelector('.mx-dialog,.mx-window,[class*=modal]'); if(p){const b=[...p.querySelectorAll('button')].find(x=>/^(cancel|close)$/i.test((x.innerText||'').trim())&&x.offsetParent!==null); if(b)b.click();} return 'ok'; }" >/dev/null 2>&1

echo "PASS: timesheet attachment — uploaded '$FNAME' to an AssignmentEntry and it persisted across reopen"
