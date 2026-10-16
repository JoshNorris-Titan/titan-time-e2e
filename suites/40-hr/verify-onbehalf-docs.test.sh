#!/usr/bin/env bash
# tt-timeout: 20m
# verify-onbehalf-docs.test.sh
#
# HR and the Titan Manager can attach an expense report, receipts and timesheet
# attachments to a consultant's week from Create Timesheet, save them, and submit
# the week for the consultant - and Clear there refills the week with the
# CONSULTANT's projects, not the signed-in user's.
#
# WHY THIS EXISTS. Main.CreateTimesheet (nav "Create Timesheet") is where HR and the
# Titan Manager fill a week on a consultant's behalf: pick the consultant in
# cbCreateForAccount and that consultant's week renders as the same assignment grid
# the consultant sees. Before the on-behalf docs change, each row's docs button
# (btnEntryDocs -> Main.AssignmentAttachment_Upload) was visible to the Consultant
# role only, and the popup refused anyone else, so HR could enter hours for a
# consultant but could never add the expenses and paperwork that go with them. The
# change shows the button to HR and Titan Manager and lets the popup work for them
# on the consultant's editable (Draft / Rejected / never-saved) week. It also fixed
# Clear on that page (bug #8 in lib/_entries.sh: Clear adding the ACTING user's
# assignments), so a cleared week is rebuilt from the consultant's assignments.
#
# UNPROVEN UNTIL DEPLOYED. Written 2026-10-16 against a model change that is not yet
# on cloud dev. On a build without the change, case 1 fails at "no btnEntryDocs on
# any row" - the regression this guards. Nothing here has run green anywhere yet.
#
# WHAT IT ASSERTS (as e2e_hr unless noted, all on E2E Consultant Two's week W)
#   4  CLEAR. After Clear the grid's rows are exactly E2E Consultant Two's seeded
#      projects (FX_ASSIGNMENTS) - one row each, no other row - and, from the data
#      layer, every entry on the week belongs to an assignment of E2E Consultant
#      Two. An entry owned by anyone else (the HR account included) is bug #8.
#   1  EXPENSE REPORT. btnEntryDocs is on the E2E Sandbox row; on the Expense Report
#      tab HR enters an amount and a note and uploads a receipt, Save; re-opening the
#      popup shows the same amount and the receipt, and the note is back either on
#      screen or on the entry's Main.ExpenseReport (data layer). The data layer must
#      also hold at least one Main.ExpenseReportDocuments for the entry.
#   2  TIMESHEET ATTACHMENTS. Same on the Timesheet Attachments tab: a note and a
#      file, Save; re-opening lists the file, the data layer holds an
#      AttachmentDocument for the entry, and the note is stored on one of the entry's
#      Main.AssignmentAttachment rows. (The tab's data source creates a NEW holder on
#      every open - see verify-timesheet-attachment - so a re-opened tab is not
#      expected to show the old note; the data layer is the evidence for it.)
#   5  SUBMIT ON BEHALF. HR fills the Sandbox row, Save Draft, Submit, confirms
#      btnConfirmSubmit on Main.Consultant_OverFortyHours; the Sandbox entry is then
#      AwaitingManagerApproval and the week is no longer Draft.
#   3  TITAN MANAGER (e2e_tm), on a second fresh week W2: btnEntryDocs is visible and
#      the popup opens on an Expense Report tab whose amount box is editable. Nothing
#      is saved.
#
# DRIVING CREATE TIMESHEET. Same as verify-hr-replace-draft-keeps-approved: picking
# a consultant opens Main.HR_ConfirmRewriteTimesheet for the page's CURRENT week, and
# the page opens on today's. So the signer first picks E2E Consultant Three (no
# assignments), closes that popup with Escape WITHOUT confirming, steps the week to
# the one under test, and only then picks E2E Consultant Two and confirms
# btnConfirmReplaceDraft. The week under test is chosen from the data layer before it
# is touched: one where E2E Consultant Two has no timesheet yet, or a Draft one whose
# entries are all Draft - so the replace blanks nothing another spec relies on.
#
# SELECTORS. All .mx-name-*, except the two notes boxes: they are the auto-named
# textArea2 (Expense Report, in dataView3) and textArea1 (Timesheet Attachments, in
# dataView1), which renumber as the page is edited and must not be selected. They
# are found instead as the one visible <textarea> in the open popup (an inactive tab
# pane is display:none, so only the current tab's box is visible). When they are
# named in Studio Pro (say txtExpenseNotes / txtAttachmentNote), select those.
#
# CLEANUP. Everything this writes is on E2E Consultant Two and E2E Consultant Three,
# both in TT_E2E_CONSULTANTS, so the deep bookend clear in 99-teardown removes the
# two weeks, their entries, the expense report, the receipt and the attachment -
# the same arrangement as verify-timesheet-attachment and
# verify-hr-replace-draft-keeps-approved. Popups are closed without saving where
# nothing was meant to be saved.
#
# Consumes: two E2E Consultant Two weeks - W left AwaitingManagerApproval with one
# receipt and one attachment, W2 left Draft and empty - and empty E2E Consultant
# Three timesheets on the weeks the page passes.
#
# Env: TT_BASE_URL, TT_ROLE_PASS, TT_ATTACHMENT_FILE. Optional TT_EVIDENCE_DIR.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_entries.sh"
source "$TT_ROOT/lib/_fixtures.sh"   # FX_ASSIGNMENTS: the consultant's seeded projects
source "$TT_ROOT/lib/_customer_link.sh"   # cl_click_tab, cl_visible

CNAME="${TT_OB_CONSULTANT:-E2E Consultant Two}"
DECOY="E2E Consultant Three"
PROJECT="${TT_OB_PROJECT:-E2E Sandbox}"
CONFIRM_REPLACE=".mx-name-btnConfirmReplaceDraft"
STAMP="$(date +%s)"
AMOUNT="23.45"
EXP_NOTE="E2E on-behalf expense note $STAMP"
ATT_NOTE="E2E on-behalf attachment note $STAMP"
FIXDIR="$(cd "$TT_ROOT/fixtures" && { pwd -W 2>/dev/null || pwd; })"
FILE="${TT_ATTACHMENT_FILE:-$FIXDIR/attachment-test.png}"
FNAME="$(basename "$FILE")"
[ -f "$FILE" ] || tt_fail "attachment fixture not found: $FILE (set TT_ATTACHMENT_FILE)"

# The consultant's projects, as 00-setup seeds them.
EXPECTED=()
for row in "${FX_ASSIGNMENTS[@]}"; do
  [ "${row%%|*}" = "$CNAME" ] || continue
  p="${row#*|}"; EXPECTED+=("${p%%|*}")
done
[ "${#EXPECTED[@]}" -gt 0 ] || tt_fail "FX_ASSIGNMENTS names no project for '$CNAME' - nothing to compare a cleared week against"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

# ------------------------------------------------------------------ helpers

od_dialog_text() {
  playwright-cli eval "() => { const d=$(_tt_dialog_js); if(!d) return 'NONE'; return (d.innerText||'').replace(/\\s+/g,' ').trim().slice(0,400); }" 2>/dev/null | _tt_eval_str
}

# od_wait_dialog <needle> [secs] — wait for a visible dialog whose text holds
# <needle>. Prints its text, or NONE.
od_wait_dialog() {
  local t="NONE" i
  for i in $(seq 1 "${2:-20}"); do
    t="$(od_dialog_text)"
    case "$t" in *"$1"*) break ;; esac
    sleep 1
  done
  printf '%s' "$t"
}

# od_escape_popup — close the topmost popup without confirming it. Escape first;
# then a visible Close / Cancel caption (never Save, never Discard changes).
od_escape_popup() {
  playwright-cli press Escape >/dev/null 2>&1
  sleep 2
  [ "$(od_dialog_text)" = "NONE" ] && return 0
  playwright-cli eval "() => { const d=$(_tt_dialog_js); if(!d) return 'none'; const b=[...d.querySelectorAll('button')].find(x=>x.offsetParent!==null && /^(close|cancel)\$/i.test((x.innerText||'').trim())); if(b){ b.click(); return 'ok'; } return 'nobutton'; }" >/dev/null 2>&1
  sleep 2
}

# od_open_page <user> <ready> — sign in and open Create Timesheet.
od_open_page() {
  tt_login "$1" "$2"
  tt_click_text "Create Timesheet" "$1 Create Timesheet nav item"
  sleep 3
  tt_wait_for ".mx-name-cbCreateForAccount" "Create Timesheet consultant picker ($1)"
}

# od_decoy — pick the decoy consultant and close its replace popup unconfirmed, so
# the page's week can be stepped without touching E2E Consultant Two's current week.
od_decoy() {
  tt_combobox_select_text ".mx-name-cbCreateForAccount" "$DECOY" \
    || tt_fail "could not pick '$DECOY' in cbCreateForAccount"
  case "$(od_wait_dialog "replace" 15)" in
    *replace*) od_escape_popup ;;
  esac
  case "$(od_dialog_text)" in
    NONE) ;;
    *) tt_fail "could not close the replace-draft popup for '$DECOY' without confirming it ($(od_dialog_text))" ;;
  esac
  tt_wait_for ".mx-name-txtWeekRange" "Create Timesheet week header"
}

# od_week_is_free <week-key> — 'true' when CNAME has no timesheet that week, or a
# Draft / unset one whose every entry is Draft / unset. Read as the signed-in user.
od_week_is_free() {
  local e f st
  e="$(tt_week_entries "$CNAME" "$1")"
  case "$e" in
    NOWEEK) echo true; return ;;
    ERR:*|'') echo "err:$e"; return ;;
  esac
  local IFS='|'
  for f in $e; do
    st="${f#*=}"
    case "$st" in Draft|'(empty)') ;; *) echo false; return ;; esac
  done
  echo true
}

# od_goto_week <week-key> — step the page's week (either direction) to <week-key>.
od_goto_week() {
  local i
  for i in $(seq 1 30); do
    [ "$(tt_current_week)" = "$1" ] && return 0
    if [ "$i" -le 15 ]; then playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    else playwright-cli click ".mx-name-btnWeekPrev" >/dev/null 2>&1; fi
    sleep 2
  done
  [ "$(tt_current_week)" = "$1" ]
}

# od_pick_consultant — pick CNAME and confirm the replace-draft popup for the
# current week, then wait for the consultant's grid. Fatal on a refusal: the week
# was chosen as free, so "cannot be overwritten" means the choice was wrong.
od_pick_consultant() {
  local t r
  tt_combobox_select_text ".mx-name-cbCreateForAccount" "$CNAME" \
    || tt_fail "could not pick '$CNAME' in cbCreateForAccount"
  t="$(od_wait_dialog "replace" 20)"
  case "$t" in
    *replace*)
      r="$(playwright-cli eval "() => { const d=$(_tt_dialog_js); if(!d) return 'nodialog'; const b=[...d.querySelectorAll('$CONFIRM_REPLACE')].find(x=>x.offsetParent!==null); if(!b) return 'nobutton'; (b.querySelector('button')||b).click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)"
      [ "$r" = "ok" ] || tt_fail "the replace-draft popup for '$CNAME' has no visible $CONFIRM_REPLACE ($r)"
      sleep 4
      t="$(od_wait_dialog "cannot be overwritten" 6)"
      case "$t" in *"cannot be overwritten"*) tt_fail "replace draft refused week $(tt_current_week) for '$CNAME', which the data layer said was free: $t" ;; esac
      tt_clear_dialogs 4 >/dev/null 2>&1
      ;;
    *) note "(picking '$CNAME' opened no replace-draft confirmation - continuing on the grid as shown)" ;;
  esac
  tt_wait_for ".mx-name-galAssignmentRows .mx-name-txtDayMon" "'$CNAME' week grid on Create Timesheet"
}

# od_row_texts — one line per grid row: that row's flattened text. A row is the
# ancestor of its Mon cell that holds exactly one Mon cell (see tt_week_row_of).
od_row_texts() {
  playwright-cli eval "() => { const out=[]; for (const m of document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')) { let el=m, row=m; for(let k=0;k<12;k++){ const p=el.parentElement; if(!p || p.querySelectorAll('.mx-name-txtDayMon').length!==1) break; el=p; row=p; } out.push((row.innerText||'').replace(/\\s+/g,' ').trim()); } return out.join('\\n'); }" 2>/dev/null | _tt_eval_str
}

# od_docs_click <ordinal> — press btnEntryDocs on that row. ok | norow | nobutton.
od_docs_click() {
  playwright-cli eval "() => { const m=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')][$1 - 1]; if(!m) return 'norow'; let el=m, row=m; for(let k=0;k<12;k++){ const p=el.parentElement; if(!p || p.querySelectorAll('.mx-name-txtDayMon').length!==1) break; el=p; row=p; } const b=row.querySelector('.mx-name-btnEntryDocs'); if(!b || b.offsetParent===null) return 'nobutton'; b.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str
}

# od_open_docs <tab widget> — open the PROJECT row's docs popup on that tab. Fatal.
od_open_docs() {
  local ord r
  ord="$(tt_week_row_of "$PROJECT" editable)"
  [ "$ord" != "0" ] || tt_fail "no editable '$PROJECT' row on week $(tt_current_week) for '$CNAME'"
  r="$(od_docs_click "$ord")"
  case "$r" in
    ok) ;;
    nobutton) tt_fail "the '$PROJECT' row (row $ord) shows no .mx-name-btnEntryDocs to $SIGNER - before the on-behalf docs change it was Consultant-only; that is the regression this guards" ;;
    *) tt_fail "could not press btnEntryDocs on row $ord ($r)" ;;
  esac
  sleep 3
  [ "$(cl_click_tab "$1")" = "ok" ] || tt_fail "the docs popup opened for $SIGNER has no .mx-name-$1 tab (popup: $(od_dialog_text))"
  sleep 2
}

# od_tag_note — tag the one visible <textarea> in the open popup as
# [data-od-note='1']. ok | count:<n>.
od_tag_note() {
  playwright-cli eval "() => { document.querySelectorAll('[data-od-note]').forEach(e=>e.removeAttribute('data-od-note')); const d=$(_tt_dialog_js); if(!d) return 'count:nodialog'; const t=[...d.querySelectorAll('textarea')].filter(x=>x.offsetParent!==null); if(t.length!==1) return 'count:'+t.length; t[0].setAttribute('data-od-note','1'); return 'ok'; }" 2>/dev/null | _tt_eval_str
}

od_note_value() {
  playwright-cli eval "() => { const e=document.querySelector('[data-od-note]'); return e ? String(e.value||'') : '__MISSING__'; }" 2>/dev/null | _tt_eval_str
}

# od_upload <uploader widget> — hand FILE to that FileUploader and wait for its name.
od_upload() {
  local i
  [ "$(cl_visible ".mx-name-$1 .dropzone")" = "true" ] || { echo "nodropzone"; return 1; }
  playwright-cli click ".mx-name-$1 .dropzone" >/dev/null 2>&1
  sleep 1
  playwright-cli upload "$FILE" >/dev/null 2>&1
  for i in $(seq 1 10); do
    od_shows_file && { echo "staged"; return 0; }
    sleep 1
  done
  echo "notstaged"; return 1
}

od_shows_file() {
  [ "$(playwright-cli eval "() => String(((($(_tt_dialog_js))||document.body).innerText||'').indexOf('$FNAME')>=0)" 2>/dev/null | _tt_eval_str)" = "true" ]
}

# od_click_visible <widget> — press the visible .mx-name-<widget>. ok | none.
od_click_visible() {
  playwright-cli eval "() => { const b=[...document.querySelectorAll('.mx-name-$1')].find(x=>x.offsetParent!==null); if(!b) return 'none'; (b.matches('button') ? b : (b.querySelector('button')||b)).click(); return 'ok'; }" 2>/dev/null | _tt_eval_str
}

# od_amount_state — the amount box: "<value>|<editable true/false>" or MISSING.
od_amount_state() {
  playwright-cli eval "() => { const i=[...document.querySelectorAll('.mx-name-txtTotalExpenseAmount input')].find(x=>x.offsetParent!==null); if(!i) return 'MISSING'; return String(i.value||'')+'|'+String(!i.readOnly && !i.disabled); }" 2>/dev/null | _tt_eval_str
}

# od_entry_guid <week-key> <project> — the guid of CNAME's entry on <project> that
# week, read as the signed-in user ('' when absent, ERR:<why> on a failed read).
od_entry_guid() {
  local key="$1" proj="$2" mon day js
  mon="${key%% *}"; day="${key#* }"; day="${day%% *}"; day="$((10#$day))"
  js="$(cat <<'EOF'
() => new Promise(res => {
  const guard = setTimeout(() => res('ERR:timeout'), 30000);
  const done = r => { clearTimeout(guard); res(r); };
  try {
    const get = o => new Promise((ok, ko) => mx.data.get(Object.assign({ callback: ok, error: e => ko(e) }, o)));
    const M = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    (async () => {
      const ts = await get({ xpath: "//Main.Timesheet[Main.Timesheet_Account/Administration.Account/FullName = '__USER__']", filter: { amount: 400 } });
      const wk = (ts || []).find(o => { const d = o.get('StartDate'); if (!d) return false; const dt = new Date(d); return M[dt.getMonth()] === '__MON__' && dt.getDate() === __DAY__; });
      if (!wk) return '';
      const es = await get({ xpath: "//Main.AssignmentEntry[Main.AssignmentEntry_Timesheet = '" + wk.getGuid() + "']", filter: { amount: 200 } });
      for (const e of (es || [])) {
        const ag = e.get('Main.AssignmentEntry_Assignment'); if (!ag) continue;
        const a = (await get({ guids: [ag] }))[0]; if (!a) continue;
        const pg = a.get('Main.Assignment_Project'); if (!pg) continue;
        const p = (await get({ guids: [pg] }))[0];
        if (p && p.get('Name') === '__PROJ__') return e.getGuid();
      }
      return '';
    })().then(done, e => done('ERR:' + ((e && e.message) || e)));
  } catch (e) { done('ERR:' + e.message); }
})
EOF
)"
  js="${js//__USER__/$CNAME}"; js="${js//__MON__/$mon}"; js="${js//__DAY__/$day}"; js="${js//__PROJ__/$proj}"
  playwright-cli eval "$js" 2>/dev/null | _tt_eval_str
}

# od_scan <xpath> [needle] — "<rows>:<any row has an attribute holding needle>",
# or ERR:<why>. Scans every attribute, so it does not depend on what the notes
# attribute is called.
od_scan() {
  playwright-cli eval "() => new Promise(res => { const t=setTimeout(()=>res('ERR:timeout'),15000); try { mx.data.get({ xpath: \"$1\", filter:{amount:50}, callback: o => { clearTimeout(t); const n='${2:-}'; const hit = !!n && (o||[]).some(x => x.getAttributes().some(a => String(x.get(a)).indexOf(n) >= 0)); res(String((o||[]).length)+':'+String(hit)); }, error: e => { clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e) { clearTimeout(t); res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

# od_num_eq <a> <b> — numerically equal after stripping currency and separators.
od_num_eq() {
  awk -v a="$1" -v b="$2" 'BEGIN { gsub(/[^0-9.]/,"",a); gsub(/[^0-9.]/,"",b); exit (a != "" && a+0 == b+0) ? 0 : 1 }'
}

# ---------------------------------------------- SETUP: HR, a free week for CNAME
SIGNER="e2e_hr"
od_open_page e2e_hr "$TT_HR_READY"
od_decoy

# Step off today's week first (other specs write it), then take the first two free
# weeks: W for HR, W2 for the Titan Manager.
W="" W2=""
for i in $(seq 1 20); do
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
  sleep 2
  k="$(tt_current_week)"
  [ -n "$k" ] || continue
  free="$(od_week_is_free "$k")"
  case "$free" in err:*) tt_fail "HR could not read $CNAME's week $k from the data layer (${free#err:}) - cannot pick a week that is safe to replace" ;; esac
  [ "$free" = "true" ] || continue
  if [ -z "$W" ]; then W="$k"; else W2="$k"; break; fi
done
[ -n "$W" ] && [ -n "$W2" ] || tt_fail "fewer than two free weeks for '$CNAME' in the next 20 (W='$W' W2='$W2') - was 00-setup skipped?"
note "SETUP: HR works on week $W, the Titan Manager on $W2"
od_goto_week "$W" || tt_fail "Create Timesheet could not step back to week $W (shows '$(tt_current_week)')"
od_pick_consultant
[ "$(tt_current_week)" = "$W" ] || tt_fail "after picking '$CNAME' the grid shows week '$(tt_current_week)', not $W"
tt_evidence "onbehalf-hr-grid"

# ---------------------------------------------------------------- 4. CLEAR
[ "$(tt_week_actionable)" = "true" ] || tt_fail "week $W for '$CNAME' offers no Clear button on Create Timesheet (status: $(tt_week_entries "$CNAME" "$W"))"
# Put hours on the first row so Clear has something to undo.
tt_fill_commit ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDayMon input, 1)" "5"
sleep 1
playwright-cli click ".mx-name-btnClear" >/dev/null 2>&1 || tt_fail "the Clear button could not be pressed on week $W"
sleep 3
tt_clear_dialogs 8 "Clear" || bad "4 a dialog blocked Clear on week $W: \"$TT_DIALOG_BLOCKED\""
sleep 3
[ "$(tt_current_week)" = "$W" ] || tt_fail "after Clear the grid shows week '$(tt_current_week)', not $W"

ROWS="$(od_row_texts)"
nrows=0; foreign=""
while IFS= read -r r; do
  [ -n "$r" ] || continue
  nrows=$((nrows+1))
  hit=""
  for p in "${EXPECTED[@]}"; do case "$r" in *"$p"*) hit=1 ;; esac; done
  [ -n "$hit" ] || foreign="$foreign [$r]"
done <<< "$ROWS"
[ -z "$foreign" ] || bad "4 after Clear the grid holds rows that are not $CNAME's projects (${EXPECTED[*]}):$foreign - Clear refilled the week from someone else's assignments (bug #8)"
for p in "${EXPECTED[@]}"; do
  c="$(printf '%s\n' "$ROWS" | grep -cF "$p")"
  [ "$c" = "1" ] || bad "4 after Clear '$p' (a seeded assignment of '$CNAME') shows on $c rows, not 1"
done
[ "$nrows" = "${#EXPECTED[@]}" ] || bad "4 after Clear the grid shows $nrows rows, '$CNAME' has ${#EXPECTED[@]} seeded projects"

ENT="$(tt_week_entries "$CNAME" "$W")"
case "$ENT" in
  ERR:*|NOWEEK|'') bad "4 HR could not read week $W back after Clear ($ENT)" ;;
  *)
    owners_bad=""
    IFS='|' read -r -a parts <<< "$ENT"
    for f in "${parts[@]}"; do
      case "$f" in WEEK=*) continue ;; esac
      lhs="${f%%=*}"
      [ "${lhs#*~}" = "$CNAME" ] || owners_bad="$owners_bad [$lhs]"
    done
    [ -z "$owners_bad" ] || bad "4 after Clear week $W holds entries on assignments that are not $CNAME's:$owners_bad (entries: $ENT) - bug #8, Clear adding the acting user's assignments"
    ;;
esac
[ "$fails" -eq 0 ] && note "4 Clear left exactly $CNAME's ${#EXPECTED[@]} project row(s) and no one else's ($ENT)"

# ------------------------------------------------------- 1. EXPENSE REPORT (HR)
od_open_docs tabExpenseUpload
st="$(od_amount_state)"
case "$st" in
  MISSING) tt_fail "1 the Expense Report tab opened for HR has no .mx-name-txtTotalExpenseAmount" ;;
  *"|false") tt_fail "1 the expense amount box is read-only for HR on $CNAME's editable week $W ($st)" ;;
esac
tt_fill_commit ".mx-name-txtTotalExpenseAmount input" "$AMOUNT"
r="$(od_tag_note)"; [ "$r" = "ok" ] || tt_fail "1 expected one visible notes box on the Expense Report tab, found ${r#count:}"
tt_fill_commit "[data-od-note='1']" "$EXP_NOTE"
st="$(od_upload fileUploader1)" || tt_fail "1 the receipt did not stage in the Expense Report uploader ($st)"
tt_evidence "onbehalf-hr-expense-filled"
[ "$(od_click_visible btnExpenseUploadSave)" = "ok" ] || tt_fail "1 no visible .mx-name-btnExpenseUploadSave"
sleep 4
tt_clear_dialogs 4 >/dev/null 2>&1
[ "$(od_dialog_text)" = "NONE" ] || bad "1 the popup is still open after Save: $(od_dialog_text)"
[ "$(tt_current_week)" = "$W" ] || tt_fail "after the expense Save the grid shows week '$(tt_current_week)', not $W"

od_open_docs tabExpenseUpload
st="$(od_amount_state)"
od_num_eq "${st%%|*}" "$AMOUNT" || bad "1 after Save + reopen the expense amount reads [${st%%|*}], not $AMOUNT"
od_shows_file || bad "1 after Save + reopen the receipt '$FNAME' is not listed on the Expense Report tab"
ui_note="$( [ "$(od_tag_note)" = "ok" ] && od_note_value )"
GUID="$(od_entry_guid "$W" "$PROJECT")"
case "$GUID" in ''|ERR:*) tt_fail "1 HR could not find $CNAME's '$PROJECT' entry on week $W ($GUID)" ;; esac
ER="$(od_scan "//Main.ExpenseReport[Main.ExpenseReport_AssignmentEntry = '$GUID']" "$EXP_NOTE")"
ERD="$(od_scan "//Main.ExpenseReportDocuments[Main.ExpenseReportDocuments_ExpenseReport/Main.ExpenseReport/Main.ExpenseReport_AssignmentEntry = '$GUID']")"
if [ "$ui_note" != "$EXP_NOTE" ] && [ "${ER#*:}" != "true" ]; then
  bad "1 the expense note did not persist: the reopened box reads [$ui_note] and no ExpenseReport on entry $GUID holds it ($ER)"
fi
case "${ERD%%:*}" in ''|ERR*|0|*[!0-9]*) bad "1 entry $GUID has no ExpenseReportDocuments after Save ($ERD) - the receipt was not stored" ;; esac
tt_evidence "onbehalf-hr-expense-reopened"
od_escape_popup
note "1 expense: amount [${st%%|*}], note on screen [$ui_note], ExpenseReport $ER, receipts $ERD"

# ------------------------------------------------- 2. TIMESHEET ATTACHMENTS (HR)
od_open_docs tabTimesheetUpload
r="$(od_tag_note)"; [ "$r" = "ok" ] || tt_fail "2 expected one visible note box on the Timesheet Attachments tab, found ${r#count:}"
tt_fill_commit "[data-od-note='1']" "$ATT_NOTE"
st="$(od_upload fileUploader2)" || tt_fail "2 the attachment did not stage in the Timesheet Attachments uploader ($st)"
[ "$(od_click_visible btnAttachmentUploadSave)" = "ok" ] || tt_fail "2 no visible .mx-name-btnAttachmentUploadSave"
sleep 4
tt_clear_dialogs 4 >/dev/null 2>&1
[ "$(tt_current_week)" = "$W" ] || tt_fail "after the attachment Save the grid shows week '$(tt_current_week)', not $W"

od_open_docs tabTimesheetUpload
od_shows_file || bad "2 after Save + reopen '$FNAME' is not listed on the Timesheet Attachments tab"
AA="$(od_scan "//Main.AssignmentAttachment[Main.AssignmentAttachment_AssignmentEntry = '$GUID']" "$ATT_NOTE")"
AD="$(od_scan "//Main.AttachmentDocument[Main.AttachmentDocument_AssignmentAttachment/Main.AssignmentAttachment/Main.AssignmentAttachment_AssignmentEntry = '$GUID']")"
[ "${AA#*:}" = "true" ] || bad "2 no AssignmentAttachment on entry $GUID holds the note '$ATT_NOTE' ($AA)"
case "${AD%%:*}" in ''|ERR*|0|*[!0-9]*) bad "2 entry $GUID has no AttachmentDocument after Save ($AD) - the file was not stored" ;; esac
tt_evidence "onbehalf-hr-attachment-reopened"
od_escape_popup
note "2 attachment: AssignmentAttachment $AA, documents $AD"

# ------------------------------------------------------ 5. SUBMIT ON BEHALF (HR)
ord="$(tt_week_row_of "$PROJECT" editable)"
[ "$ord" != "0" ] || tt_fail "5 no editable '$PROJECT' row on week $W to submit"
for d in Mon Tues Wed Thurs Fri; do
  tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, ${ord})" "8"
done
tt_commit_focused
sleep 1
playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
sleep 3
tt_clear_dialogs 4 >/dev/null 2>&1
playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1 || tt_fail "5 the Submit button could not be pressed on week $W"
ok=""
for _ in $(seq 1 15); do
  [ "$(cl_visible '.mx-name-btnConfirmSubmit')" = "true" ] && { ok=1; break; }
  sleep 1
done
if [ -z "$ok" ]; then
  bad "5 Submit opened no Main.Consultant_OverFortyHours confirmation with btnConfirmSubmit (dialog: $(od_dialog_text))"
else
  [ "$(od_click_visible btnConfirmSubmit)" = "ok" ] || bad "5 could not press btnConfirmSubmit"
  sleep 4
  tt_clear_dialogs 6 >/dev/null 2>&1
  sleep 2
  L=""
  for _ in 1 2 3; do
    L="$(tt_week_ledger "$CNAME" "$W")"
    [ "$(tt_ledger_status "$L" "$PROJECT")" = "AwaitingManagerApproval" ] && break
    sleep 3
  done
  [ "$(tt_ledger_status "$L" "$PROJECT")" = "AwaitingManagerApproval" ] \
    || bad "5 after HR's submit '$PROJECT' on week $W is [$(tt_ledger_status "$L" "$PROJECT")], not AwaitingManagerApproval ($L)"
  case "$(tt_ledger_status "$L" WEEK)" in
    Draft|'(empty)'|'') bad "5 after HR's submit week $W is still [$(tt_ledger_status "$L" WEEK)] ($L)" ;;
  esac
  note "5 submitted on behalf: $L"
fi

# ------------------------------------------------------------ 3. TITAN MANAGER
SIGNER="e2e_tm"
od_open_page e2e_tm "Add Customer"
od_decoy
free="$(od_week_is_free "$W2")"
[ "$free" = "true" ] || tt_fail "3 week $W2 is no longer free for '$CNAME' when the Titan Manager reaches it ($free; $(tt_week_entries "$CNAME" "$W2"))"
od_goto_week "$W2" || tt_fail "3 Create Timesheet (Titan Manager) could not step to week $W2 (shows '$(tt_current_week)')"
od_pick_consultant
[ "$(tt_current_week)" = "$W2" ] || tt_fail "3 after picking '$CNAME' the Titan Manager's grid shows '$(tt_current_week)', not $W2"
n="$(playwright-cli eval "() => String([...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-btnEntryDocs')].filter(b=>b.offsetParent!==null).length)" 2>/dev/null | _tt_eval_str)"
case "$n" in ''|0|*[!0-9]*) bad "3 the Titan Manager sees no btnEntryDocs on $CNAME's week $W2 (count: [$n])" ;; esac
case "$n" in ""|0|*[!0-9]*) ;; *)
  od_open_docs tabExpenseUpload
  st="$(od_amount_state)"
  case "$st" in
    MISSING) bad "3 the docs popup opened for the Titan Manager has no .mx-name-txtTotalExpenseAmount" ;;
    *"|true") note "3 the Titan Manager sees btnEntryDocs on $n row(s) and an editable expense amount box" ;;
    *) bad "3 the expense amount box is read-only for the Titan Manager on $CNAME's editable week $W2 ($st)" ;;
  esac
  tt_evidence "onbehalf-tm-expense"
  od_escape_popup
  ;;
esac

# --------------------------------------------------------------------- verdict
if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-onbehalf-docs - $fails assertion(s) failed ('$CNAME', weeks $W and $W2)"
  exit 1
fi
echo "PASS: verify-onbehalf-docs - on Create Timesheet HR cleared $CNAME's week $W back to their own projects, saved an expense report with a receipt and a timesheet attachment, and submitted it; the Titan Manager can open the same docs on $W2"
