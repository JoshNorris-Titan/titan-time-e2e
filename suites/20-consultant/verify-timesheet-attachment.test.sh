#!/usr/bin/env bash
# Attachment upload — a consultant can attach a supporting file to an AssignmentEntry
# while filling a timesheet, and it persists across a reopen.
#
# Flow: consultant timesheet → per-row "Exp/Tim" button (.mx-name-btnEntryDocs →
# Main.ACT_AssignmentEntry_Docs) → Main.AssignmentAttachment_Upload page → the
# "Timesheet Attachments" tab (FileUploader `fileUploader2`, whose dataview source is
# Main.ACT_CreateTimeSheetAttachment → Main.AssignmentAttachment + Main.AttachmentDocument)
# → upload a file → Save (save_changes + close_page) → reopen → the file is still listed.
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
source "$TT_ROOT/lib/_tt692693.sh"

CUSER="${TT_ATTACH_USER:-e2e_consultant}"
FIXDIR="$(cd "$TT_ROOT/fixtures" && { pwd -W 2>/dev/null || pwd; })"
ATTACH_FILE="${TT_ATTACHMENT_FILE:-$FIXDIR/attachment-test.png}"
FNAME="$(basename "$ATTACH_FILE")"

[ -f "$ATTACH_FILE" ] || tt_fail "attachment file not found: $ATTACH_FILE (set TT_ATTACHMENT_FILE)"

# Opens the first entry's docs page and switches to the Timesheet Attachments tab.
open_docs_timesheet_tab() {
  playwright-cli click ":nth-match(.mx-name-btnEntryDocs, 1)" >/dev/null 2>&1; sleep 3
  playwright-cli eval "() => { const t=[...document.querySelectorAll('a,li,button,[role=tab]')].find(e=>/Timesheet Attachments/i.test((e.innerText||'').trim())); if(t){t.click(); return 'ok';} return 'no-tab'; }" >/dev/null 2>&1
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
playwright-cli eval "() => { const p=document.querySelector('.mx-dialog,.mx-window,[class*=modal]')||document; const b=[...p.querySelectorAll('button')].find(x=>/^\s*save\s*$/i.test(x.innerText||'') && x.offsetParent!==null); if(b){b.click(); return 'saved';} return 'no-save'; }" >/dev/null 2>&1
sleep 3
tt_dismiss_dialogs >/dev/null 2>&1
sleep 2

# 5) Reopen the docs page — the attachment must persist (proves it was committed to the entry).
open_docs_timesheet_tab
shows_file || tt_fail "'$FNAME' did not persist after Save + reopen — attachment was not saved to the AssignmentEntry"

# cleanup: close the popup
playwright-cli eval "() => { const p=document.querySelector('.mx-dialog,.mx-window,[class*=modal]'); if(p){const b=[...p.querySelectorAll('button')].find(x=>/^(cancel|close)$/i.test((x.innerText||'').trim())&&x.offsetParent!==null); if(b)b.click();} return 'ok'; }" >/dev/null 2>&1

echo "PASS: timesheet attachment — uploaded '$FNAME' to an AssignmentEntry and it persisted across reopen"
