#!/usr/bin/env bash
# tt-timeout: 12m
# verify-hr-reject-after-export-history.test.sh
#
# Rejecting an EXPORTED entry from HR's Sent tab saves an Exported > Rejected row
# (with the comment) in the entry's history, and turns the consultant's week
# Rejected. Bug-reproduction spec (bug #4): RED UNTIL THE MODEL FIX LANDS (the
# history half; the week-status half is green on dev - see B below).
#
# THE BUG (scratchpad bug-verify.md #4 and gate1.md item 5, read live from the model
# on 2026-09-28). Sent row -> btnRejectAfterExport -> Main.AssignmentEntry_RejectPage
# -> Main.NACT_AssignmentEntry_PageReject, which routes an Exported entry to
# Main.ACT_RejectAfterExport. In canvas order that flow:
#   1. changes the entry to Status = Rejected, commit NO;
#   2. calls SUB_AssignmentEntry_UpdateTimesheetStatus - which reads the week's
#      entries over the reverse association, a DATABASE query, so it can still see
#      this entry as Exported and set the week Approved;
#   3. starts the rejection email in the background;
#   4. subtracts the hours from the assignment;
#   5. commits the entry; 6. commits the assignment;
#   7. creates the Exported > Rejected Main.ChangeLog with commit NO - and never
#      commits it; 8. deletes the ApprovalHelper; 9. navigates.
# ACT_ApprovalHelper_Reject does it the other way round (commit, then recompute),
# and commits its log.
#
# Two halves, asserted separately so one cannot hide the other:
#   A. HISTORY (confirmed statically): the entry's history has an Exported >
#      Rejected row carrying the comment HR typed.
#   B. WEEK STATUS (was only "likely" statically): the week that holds the entry
#      reads Rejected. A week with any rejected entry is Rejected
#      (SUB_AssignmentEntry_UpdateTimesheetStatus), whatever its other entries are.
#      The feared failure was the week keeping Approved because step 2 runs before
#      step 5. NOT REPRODUCED on dev 2026-09-29 (run exportbugs-1): the week went
#      Approved -> Rejected, so the recompute does see the uncommitted change. B
#      stays as a green guard on that ordering; only A is red.
#
# Both are read from the data layer as HR (lib/_changelog.sh): the history popup and
# the consultant's badge are views of exactly these objects, and the badge is known
# to repaint late.
#
# Before either assertion the ENTRY itself must read Rejected. If it does not, the
# rejection did not happen and this step says so - that is not bug #4, and it is
# what verify-hr-reject-after-export guards.
#
# DATA. Takes ONE Exported entry of E2E Consultant's from the Sent tab - in a full
# run, one of the two tt683/a1 exported; verify-hr-reject-after-export (which sorts
# after this file) takes the other. Run on its own after 00-setup it makes one:
# processes To Process and exports an all-e2e month (tt683_click_export_all refuses
# a month holding anyone else's rows).
#
# CONSUMES ONE Exported ENTRY.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt683.sh"
source "$TT_ROOT/lib/_rejection.sh"
source "$TT_ROOT/lib/_changelog.sh"

CONSULTANT_NAME="${TT_EXPORT_CONSULTANT:-E2E Consultant}"
COMMENT="E2E bug-repro 4 - rejected after export, history must keep this"

fails=0
bad() { echo "  FAILED: $*"; fails=$((fails+1)); }

# rah_open_sent — HR, Sent tab, with the week holding one of our exported rows the
# only one expanded. Prints the week key; returns 1 when no Sent week holds one.
rah_open_sent() {
  tt_login "e2e_hr" "$TT_HR_READY" >&2
  tt_hr_try_click_tab "Sent" >&2 || return 1
  tt_hr_wait_pane "Sent week groups" >/dev/null
  tt_hr_find_group_for "$CONSULTANT_NAME" all
}

# rah_row — "<project>~~<hours>" of the first expanded Sent row of ours that has a
# Reject, preferring one with hours.
rah_row() {
  playwright-cli eval "() => { $(_tt_hr_grp_js) if (HG.kind !== 'Sent') return ''; const c = (r, n) => ((r.querySelector('.mx-name-txtSent' + n) || {}).innerText || '').replace(/\s+/g, ' ').trim(); const num = s => parseFloat(String(s).replace(/[^0-9.-]/g, '')) || 0; const out = []; for (const x of HG.groups().filter(y => y.open)) for (const r of HG.rows(x.g)) { if (c(r, 'Consultant') !== '$CONSULTANT_NAME') continue; if (!r.querySelector('$TT_HR_BTN_REJECT_AFTER_EXPORT')) continue; out.push(c(r, 'Project') + '~~' + c(r, 'TotalHours')); } if (!out.length) return ''; return out.find(l => num(l.split('~~')[1]) > 0) || out[0]; }" 2>/dev/null | _tt_eval_str | grep -v '^null$'
}

# rah_confirm_popup <comment> — fill Main.AssignmentEntry_RejectPage's comment and
# press its Reject (the footer button is auto-named, so it is pressed by caption).
# 1 = no popup, 2 = no comment box, 3 = could not confirm. The box is blurred after
# typing: a Mendix text area hands its value to the object on blur.
rah_confirm_popup() {
  local r
  r="$(playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); if(!d) return 'nopopup'; const ta=d.querySelector('.mx-name-txtRejectionComment textarea') || d.querySelector('textarea'); if(!ta) return 'nofield'; const set=Object.getOwnPropertyDescriptor(ta.__proto__,'value').set; set.call(ta,'$1'); ta.dispatchEvent(new Event('input',{bubbles:true})); ta.dispatchEvent(new Event('change',{bubbles:true})); ta.blur(); return 'typed'; }" 2>/dev/null | _tt_eval_str)"
  case "$r" in
    typed)   : ;;
    nopopup) return 1 ;;
    *)       return 2 ;;
  esac
  sleep 1
  tt_click_button_exact "reject" popup || return 3
  sleep 4
  tt_dismiss_dialogs >/dev/null
  return 0
}

# ------------------------------------------------ 1. find an exported entry of ours
WEEK="$(rah_open_sent)"
if [ -z "$WEEK" ]; then
  echo "no exported entry for '$CONSULTANT_NAME' on Sent - processing To Process and exporting an all-e2e month to make one"
  ( tt683_process_all_toprocess 6 ) >/dev/null
  if ( tt683_open_export_tab >/dev/null && tt683_click_export_all ); then
    sleep 5
    tt_clear_dialogs 8 >/dev/null
  else
    echo "  (the export step did not complete)"
  fi
  WEEK="$(rah_open_sent)"
  [ -n "$WEEK" ] || tt_fail "no Sent week holds an exported entry of '$CONSULTANT_NAME', and processing + exporting an all-e2e month did not produce one - nothing to reject after export. suites/70-tickets/tt683/verify-tt683-a0/-a1 supply these in a full run."
fi
ROW="$(rah_row)"
PROJECT="${ROW%%~~*}"
[ -n "$ROW" ] && [ -n "$PROJECT" ] || tt_fail "Sent week '$WEEK' holds '$CONSULTANT_NAME' but no row of theirs offers Reject (.mx-name-btnRejectAfterExport)"
echo "exported entry on Sent: $CONSULTANT_NAME / $PROJECT / week $WEEK (hours ${ROW#*~~})"

# The same entry in the data layer: ours, on that project, Exported, in that week.
MATCH="$(tt_cl_entries "$(tt_cl_e2e_constraint Exported)[Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName = '$CONSULTANT_NAME'][Main.AssignmentEntry_Assignment/Main.Assignment/Main.Assignment_Project/Main.Project/Name = '$PROJECT']")"
case "$MATCH" in ERR:*) tt_fail "could not read the exported entry as HR ($MATCH)" ;; esac
# Matched on the week's START: the group key's end day and the timesheet's stored
# EndDate need not be the same calendar day, the start always is.
MATCH="$(printf '%s\n' "$MATCH" | awk -F'~' -v w="${WEEK%% - *}" 'index($4, w " - ") == 1')"
[ "$(printf '%s\n' "$MATCH" | grep -c .)" = "1" ] \
  || tt_fail "expected exactly one Exported '$PROJECT' entry of '$CONSULTANT_NAME' in week '$WEEK' in the data layer, found: ${MATCH:-none}"
GUID="$(tt_cl_field "$MATCH" 1)"
TS_BEFORE="$(tt_cl_field "$MATCH" 7)"
echo "  entry $GUID; week status before: $TS_BEFORE; history before: $(tt_cl_field "$MATCH" 8)"

# ------------------------------------------------------------------- 2. reject it
tt_hr_select_week "$WEEK" || tt_fail "could not re-open Sent week '$WEEK'"
r="$(tt_hr_row_click "$CONSULTANT_NAME" "$PROJECT" "$TT_HR_BTN_REJECT_AFTER_EXPORT")"
[ "$r" = "ok" ] || tt_fail "could not press Reject on the '$PROJECT' row of week '$WEEK' ($r)"
sleep 4
rah_confirm_popup "$COMMENT"
case "$?" in
  1) tt_fail "Reject on the Sent row opened no comment popup (Main.AssignmentEntry_RejectPage)" ;;
  2) tt_fail "the reject popup has no comment box (.mx-name-txtRejectionComment)" ;;
  3) tt_fail "the comment was typed but the popup's Reject could not be pressed" ;;
esac

# ------------------------------------------------------- 3. read it back, as HR
LINE=""
for _ in $(seq 1 10); do
  LINE="$(tt_cl_entries "[id = '$GUID']")"
  case "$LINE" in ERR:*) : ;; *) [ "$(tt_cl_field "$LINE" 5)" = "Rejected" ] && break ;; esac
  sleep 3
done
case "$LINE" in ERR:*|'') tt_fail "could not read entry $GUID back after the reject (${LINE:-no row})" ;; esac
STATUS="$(tt_cl_field "$LINE" 5)"
TS_AFTER="$(tt_cl_field "$LINE" 7)"
TRAIL="$(tt_cl_field "$LINE" 8)"
echo "  after: entry=$STATUS week=$TS_AFTER history=$TRAIL"

[ "$STATUS" = "Rejected" ] \
  || tt_fail "the entry still reads '$STATUS' 30 s after Reject was confirmed - the rejection itself did not happen, so neither half of bug #4 can be judged (verify-hr-reject-after-export owns that route)"

# A. the history row
if tt_cl_trail_has "$TRAIL" "Exported" "Rejected"; then
  case "$TRAIL" in
    *"${COMMENT:0:40}"*) echo "  ok   A: history has Exported > Rejected with the comment" ;;
    *) bad "A: history has an Exported > Rejected row but not the comment HR typed ('$COMMENT'): $TRAIL" ;;
  esac
else
  bad "A: the entry is Rejected but its history has no Exported > Rejected row (bug #4: Main.ACT_RejectAfterExport creates the ChangeLog with commit No and never commits it). History reads: ${TRAIL:-<empty>}"
fi

# B. the week status
if [ "$TS_AFTER" = "Rejected" ]; then
  echo "  ok   B: the week reads Rejected"
else
  bad "B: the entry is Rejected but its week reads '$TS_AFTER' (was '$TS_BEFORE') - the consultant is not shown a rejected week (bug #4: SUB_AssignmentEntry_UpdateTimesheetStatus runs before the entry is committed and reads it as Exported)"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-hr-reject-after-export-history - $fails of 2 checks failed for $CONSULTANT_NAME / $PROJECT / $WEEK"
  exit 1
fi
echo "PASS: verify-hr-reject-after-export-history - $CONSULTANT_NAME / $PROJECT / $WEEK: history records Exported > Rejected with the comment, and the week reads Rejected"
