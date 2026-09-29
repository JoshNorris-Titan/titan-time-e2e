#!/usr/bin/env bash
# tt-timeout: 12m
# verify-rejected-week-save-keeps-others.test.sh
#
# Saving a week that holds ONE rejected entry must leave that week's OTHER entries
# where they are. Bug-reproduction spec: RED UNTIL THE MODEL FIX LANDS.
#
# THE BUG (bug-verify.md #1, confirmed statically on the 2026-09-28 16:03 build).
# A week turns Rejected as soon as ANY of its entries is rejected
# (SUB_AssignmentEntry_UpdateTimesheetStatus), and on a Rejected week the consultant's
# Save Draft / Submit / Clear buttons are all visible. Save Draft runs
# Main.ACT_Timesheet_Draft, whose split "Set to draft?" is the literal `true`
# (step 1.0), and whose loop runs over EVERY entry on the timesheet
# ([Main.AssignmentEntry_Timesheet = $Timesheet]): each one is changed to
# Status = Draft with a <old> -> Draft change log, and the list is committed.
# Main.ACT_Timesheet_Submit runs ACT_Timesheet_Draft first, so its own
# `_IsEditable` filter then passes everything too, and every entry - approved,
# awaiting a customer, even exported - is routed through approval again.
#
# The documented intent says otherwise - main/docs/reference/Submit Timesheet
# Workflow.md: "the consultant can edit and save only the rejected entries ...
# workflows will only be created for [entries] which are not either approved or
# currently in the approval process."
#
# THE SCENARIO. e2e_consultant2 is assigned to two manager-approval projects
# (E2E Sandbox and E2E Manager Approval - lib/_fixtures.sh), so one week can hold
# two entries that the SAME project manager decides on:
#   1. Consultant: a fresh week, hours on both rows, Submit.
#      Both entries -> AwaitingManagerApproval.
#   2. PM: APPROVE the Manager Approval entry (-> ToProcess) and REJECT the Sandbox
#      entry with a comment. The week is now Rejected.
#   3. Consultant: open that week and press Save Draft, touching nothing.
#   4. ASSERT, from the data layer: the Manager Approval entry is still ToProcess.
#      Buggy: it reads Draft (and its change history gains a ToProcess -> Draft row).
#
# Only Save Draft is pressed, never Submit: Save Draft is enough to show the reset,
# and Submit would re-send approval mail for entries that were already decided.
#
# Env: TT_BASE_URL, TT_ROLE_PASS. Optional TT_EVIDENCE_DIR for screenshots.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_rejection.sh"
source "$TT_ROOT/lib/_entries.sh"

CUSER="${TT_BR1_USER:-e2e_consultant2}"
CNAME="${TT_BR1_NAME:-E2E Consultant Two}"
PM="${TT_BR1_PM:-e2e_pm}"
KEEP="E2E Manager Approval"     # approved by the PM; must survive the save
REJ="E2E Sandbox"               # rejected by the PM; the reason the week is Rejected
COMMENT="E2E bug-repro #1 - rejected so the week turns Rejected"

# ------------------------------------------------------------------ helpers

# br1_week_is_fresh — 'true' when the grid shows an actionable week whose rows all
# read empty/zero and both projects have an editable row.
br1_week_is_fresh() {
  playwright-cli eval "() => { if(!document.querySelector('.mx-name-btnSubmit')) return 'false'; const ins=[...document.querySelectorAll('.mx-name-galAssignmentRows [class*=mx-name-txtDay] input')]; if(!ins.length) return 'false'; const hours=ins.some(i=>{ const v=parseFloat((i.value||'').replace(',','.')); return !isNaN(v) && v!==0; }); return String(!hours); }" 2>/dev/null | _tt_eval_str
}

# br1_fill_row <ordinal> <hours> — Mon..Fri on one row, committed.
br1_fill_row() {
  local d
  for d in Mon Tues Wed Thurs Fri; do
    tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, $1)" "$2"
  done
  tt_commit_focused
  sleep 1
}

# br1_pm_row_js <project> <action> — JS that finds the ONE pending row for
# $CNAME / <project> / $WEEK in the PM gallery and either reports it ('find') or
# clicks the row to open its review page ('open'). A row is the gallery item
# (.widget-gallery-item, "E2E Consultant Two E2E Sandbox Approve Sep 27 - Oct 03
# 20.00 hrs" on dev); its on-click sits on the item's [role=button] child. Do NOT
# climb from btnPMApprove "while the parent still holds one button": with a single
# pending row that climb reaches <html>, whose text names every project on the page.
br1_pm_row_js() {
  printf "%s" "() => { const out=[]; for (const it of document.querySelectorAll('.mx-name-galPMPendingEntries .widget-gallery-item')) { if (!it.querySelector('.mx-name-btnPMApprove')) continue; const t=(it.innerText||'').replace(/\s+/g,' '); if (t.indexOf('$CNAME')>=0 && t.indexOf('$1')>=0 && ($WEEKMATCH)) out.push(it); } if ('$2'==='find') return String(out.length); if (out.length!==1) return 'ambiguous:'+out.length; const c=out[0].querySelector(':scope > [role=button]') || out[0]; c.click(); return 'opened'; }"
}

br1_pm_dump() {
  playwright-cli eval "() => [...document.querySelectorAll('.mx-name-galPMPendingEntries .widget-gallery-item, .mx-name-galPMPendingEntries li')].map(e=>(e.innerText||'').replace(/\\s+/g,' ').trim().slice(0,160)).join('  ||  ')" 2>/dev/null | _tt_eval_str
}

# br1_pm_act <project> approve|reject — open the review page for that row and press
# Approve, or Reject with a comment. The review page (Main.ReviewTimesheetEntry) is
# where both live; the dashboard's own btnPMApprove would also approve, but going
# through one page for both keeps the two actions symmetrical.
br1_pm_act() {
  local proj="$1" act="$2" n r
  for _ in 1 2 3 4 5 6 7 8; do
    tt_login "$PM" "Project Manager Dashboard"
    tt_gallery_load_all ".mx-name-galPMPendingEntries" "PM pending queue" >/dev/null 2>&1 || true
    n="$(playwright-cli eval "$(br1_pm_row_js "$proj" find)" 2>/dev/null | _tt_eval_str)"
    [ "$n" = "1" ] && break
    sleep 6
  done
  [ "$n" = "1" ] || tt_fail "PM queue: expected exactly one '$CNAME' / '$proj' row for week $WEEK, found [$n]. Rows: $(br1_pm_dump)"
  r="$(playwright-cli eval "$(br1_pm_row_js "$proj" open)" 2>/dev/null | _tt_eval_str)"
  [ "$r" = "opened" ] || tt_fail "could not open the review page for '$proj' ($r)"
  sleep 4
  tt_wait_for ".mx-name-btnReject" "PM review page for '$proj'"
  if [ "$act" = "reject" ]; then
    local k
    k="$(playwright-cli eval "() => { const all=[...document.querySelectorAll('.mx-name-txtRejectionComment textarea')]; let k=0; all.forEach((t,i)=>{ if(t.offsetParent!==null) k=i+1; }); return String(k); }" 2>/dev/null | _tt_eval_str)"
    case "$k" in ''|*[!0-9]*|0) tt_fail "the review page shows no rejection comment box" ;; esac
    playwright-cli fill ":nth-match(.mx-name-txtRejectionComment textarea, $k)" "$COMMENT" >/dev/null 2>&1
    tt_commit_focused
    sleep 1
    playwright-cli eval "() => { const bs=[...document.querySelectorAll('.mx-name-btnReject')].filter(e=>e.offsetParent!==null); bs[bs.length-1].click(); return 'ok'; }" >/dev/null 2>&1
    sleep 4
    tt_clear_dialogs 6 "Reject" >/dev/null 2>&1 || true
  else
    playwright-cli eval "() => { const bs=[...document.querySelectorAll('.mx-name-btnApprove')].filter(e=>e.offsetParent!==null); if(!bs.length) return 'none'; bs[bs.length-1].click(); return 'ok'; }" >/dev/null 2>&1
    sleep 4
    tt_clear_dialogs 6 "Approve" >/dev/null 2>&1 || true
  fi
}

# br1_goto_week — as the consultant, step the grid to $WEEK.
br1_goto_week() {
  local i
  for i in $(seq 1 16); do
    [ "$(tt_current_week)" = "$WEEK" ] && return 0
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  return 1
}

# ------------------------------------------ 1. consultant: submit a two-entry week
tt_login "$CUSER" "My Timesheets"
fresh=""
for i in $(seq 1 14); do
  if [ "$(br1_week_is_fresh)" = "true" ] \
     && [ "$(tt_week_row_of "$KEEP" editable)" != "0" ] \
     && [ "$(tt_week_row_of "$REJ" editable)" != "0" ]; then
    fresh=1; break
  fi
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
  sleep 2
done
[ -n "$fresh" ] || tt_fail "no fresh week (actionable, no hours, editable '$KEEP' and '$REJ' rows) in the next 14 weeks for $CUSER"
WEEK="$(tt_current_week)"
[ -n "$WEEK" ] || tt_fail "could not read the week caption"
echo "  week under test: $WEEK"

# The PM gallery words dates its own way; accept the key's start as "Mmm DD" or
# "Mmm D" or the MM/DD form.
M1="${WEEK%% *}"; D1="${WEEK#* }"; D1="${D1%% *}"
MNUM="$(( $(echo "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec" | tr ' ' '\n' | grep -n "^$M1\$" | cut -d: -f1) ))"
WEEKMATCH="t.indexOf('$M1 $D1')>=0 || t.indexOf('$M1 $((10#$D1))')>=0 || t.indexOf('$(printf '%02d/%02d/' "$MNUM" "$((10#$D1))")')>=0 || t.indexOf('$MNUM/$((10#$D1))/')>=0"

ROW_KEEP="$(tt_week_row_of "$KEEP" editable)"
ROW_REJ="$(tt_week_row_of "$REJ" editable)"
br1_fill_row "$ROW_KEEP" 4
br1_fill_row "$ROW_REJ" 4
playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
sleep 3
tt_clear_dialogs 4 >/dev/null 2>&1 || true
tt_refetch_week
[ "$(tt_current_week)" = "$WEEK" ] || tt_fail "the grid left week $WEEK while re-reading it"
for r in "$ROW_KEEP" "$ROW_REJ"; do
  mon="$(playwright-cli eval "() => String((document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon input')[$r - 1]||{}).value||'')" 2>/dev/null | _tt_eval_str)"
  case "$mon" in ""|0|0.00|0.0) tt_fail "hours did not persist on row $r (Monday reads '$mon') - a zero-hour entry skips approval and the scenario would not be the one under test" ;; esac
done
playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
sleep 2
tt_clear_dialogs 8 || tt_fail "submit blocked by a dialog: $TT_DIALOG_BLOCKED"
sleep 3

S0="$(tt_week_entries "$CUSER" "$WEEK")"
echo "  after submit: $S0"
[ "$(tt_entry_status_of "$S0" "$KEEP")" = "AwaitingManagerApproval" ] \
  || tt_fail "precondition: '$KEEP' should be AwaitingManagerApproval after submit, read [$(tt_entry_status_of "$S0" "$KEEP")] ($S0)"
[ "$(tt_entry_status_of "$S0" "$REJ")" = "AwaitingManagerApproval" ] \
  || tt_fail "precondition: '$REJ' should be AwaitingManagerApproval after submit, read [$(tt_entry_status_of "$S0" "$REJ")] ($S0)"

# ------------------------------------------- 2. PM: approve one, reject the other
br1_pm_act "$KEEP" approve
br1_pm_act "$REJ" reject

tt_login "$CUSER" "My Timesheets"
S1="$(tt_week_entries "$CUSER" "$WEEK")"
echo "  after PM decisions: $S1"
KEEP_BEFORE="$(tt_entry_status_of "$S1" "$KEEP")"
case "$KEEP_BEFORE" in
  ToProcess|AwaitingExport|Exported) ;;
  *) tt_fail "precondition: the PM approval did not move '$KEEP' on (reads [$KEEP_BEFORE]; $S1)" ;;
esac
[ "$(tt_entry_status_of "$S1" "$REJ")" = "Rejected" ] \
  || tt_fail "precondition: the PM rejection did not land on '$REJ' (reads [$(tt_entry_status_of "$S1" "$REJ")]; $S1)"
case "$S1" in
  WEEK=Rejected\|*) ;;
  *) tt_fail "precondition: the week did not turn Rejected after the rejection ($S1)" ;;
esac

# ---------------------------------------- 3. consultant: Save Draft, touching nothing
br1_goto_week || tt_fail "could not step the consultant grid back to week $WEEK"
tt_evidence "br1-before-save"
[ "$(tt_week_actionable)" = "true" ] \
  || tt_fail "the Rejected week $WEEK shows no Save/Submit/Clear buttons - the scenario assumes they are visible on a Rejected week (bug-verify.md #1 'Reachability')"
playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
sleep 4
tt_clear_dialogs 4 >/dev/null 2>&1 || true
tt_evidence "br1-after-save"

# ------------------------------------------------------------- 4. the assertion
S2=""
for _ in 1 2 3; do
  S2="$(tt_week_entries "$CUSER" "$WEEK")"
  case "$S2" in ERR:*|NOWEEK|'') sleep 3 ;; *) break ;; esac
done
echo "  after Save Draft: $S2"
case "$S2" in ERR:*|NOWEEK|'') tt_fail "could not read week $WEEK back after Save Draft ($S2) - NOT evidence either way" ;; esac
KEEP_AFTER="$(tt_entry_status_of "$S2" "$KEEP")"

if [ "$KEEP_AFTER" != "$KEEP_BEFORE" ]; then
  echo "FAIL: Save Draft on a Rejected week moved the '$KEEP' entry, which the PM had already approved,"
  echo "      from $KEEP_BEFORE to ${KEEP_AFTER:-<missing>}. Only the rejected '$REJ' entry was the consultant's to"
  echo "      change. Main.ACT_Timesheet_Draft sets EVERY entry on the timesheet to Draft (its split"
  echo "      'Set to draft?' is the literal true); a later Submit would then send the approved entry"
  echo "      back through approval. Week $WEEK before: $S1"
  echo "      Week $WEEK after:  $S2"
  exit 1
fi

echo "PASS: verify-rejected-week-save-keeps-others - Save Draft on Rejected week $WEEK left the approved '$KEEP' entry at $KEEP_AFTER"
