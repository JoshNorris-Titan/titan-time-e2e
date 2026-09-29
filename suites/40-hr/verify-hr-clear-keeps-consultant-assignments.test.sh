#!/usr/bin/env bash
# tt-timeout: 12m
# verify-hr-clear-keeps-consultant-assignments.test.sh
#
# When HR presses Clear on a consultant's week in Create Timesheet, the week must be
# rebuilt from THAT CONSULTANT's assignments - never from the HR user's own.
# Bug-reproduction spec: RED UNTIL THE MODEL FIX LANDS.
#
# THE BUG (bug-verify.md #8, confirmed statically on the 2026-09-28 16:03 build).
# Main.CreateTimesheet shows the week of the consultant picked in cbCreateForAccount
# (dvTimesheet's data source is mapped to the picked Account). Its btnClear runs
# Main.ACT_Timesheet_Clear, which re-adds missing rows from
#   retrieveFirst(Administration.Account [id = $currentUser])
#     -> Main.Assignment_Account -> SUB_Assignment_FilterActive
#     -> listSubtract(ActiveAssignments, AssignmentsOnSheet)
# and creates a Draft AssignmentEntry on THIS timesheet for each one. $currentUser
# is the HR user, not the consultant: every other step on the page
# (DS_Timesheet_Get, SUB_Timesheet_SyncAssignments) takes the picked account.
# It only shows when the acting HR user has an active assignment of their own that
# the consultant does not share - otherwise the subtraction is empty.
#
# THE SCENARIO
#   1. As e2e_tm, give e2e_hr an active assignment on E2E Sandbox (unless it has one).
#      E2E Consultant (e2e_consultant) is not on E2E Sandbox (lib/_fixtures.sh).
#   2. As e2e_hr, open Create Timesheet, step to a future week, THEN pick E2E Consultant
#      (confirming the "Replace Existing Draft" prompt); retry further weeks until one
#      offers Clear.
#   3. Press Clear.
#   4. ASSERT from the data layer: no entry on E2E Consultant's week belongs to an
#      assignment of e2e_hr. Buggy: an 'E2E Sandbox' entry owned by e2e_hr appears.
#
# FIXTURE SCOPE. The HR assignment is created HERE rather than in FX_ASSIGNMENTS so
# no other step runs with it. It is not deleted afterwards: the teardown's deep clear
# deletes E2E Consultant Two's projects, E2E Sandbox among them, and a project delete
# cascades into every assignment on it (lib/_testdata.sh), so the next run starts
# without it. Between here and the teardown, e2e_hr holds one extra assignment on
# E2E Sandbox; no later step reads e2e_hr's assignments.
#
# Env: TT_BASE_URL, TT_ROLE_PASS. Optional TT_EVIDENCE_DIR.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/lib/_tt647.sh"
source "$TT_ROOT/lib/_entries.sh"

HR_USER="${TT_BR8_HR:-e2e_hr}"
C_USER="e2e_consultant"
C_NAME="E2E Consultant"
P="E2E Sandbox"

# br8_hr_assignments — '<project>~<start>~<end>' per assignment of $HR_NAME, from the
# data layer (the signed-in user must be able to read Main.Assignment - e2e_tm can).
# Matched on FullName: e2e_tm cannot read the inherited System.User.Name, and an
# XPath on a member the user cannot read returns zero rows silently.
br8_hr_assignments() {
  playwright-cli eval "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),20000); mx.data.get({ xpath: \"//Main.Assignment[Main.Assignment_Account/Administration.Account/FullName = '$HR_NAME']\", filter:{amount:50}, callback:function(as){ const pg=[...new Set((as||[]).map(a=>a.get('Main.Assignment_Project')).filter(Boolean))]; const fin=(pn)=>{ clearTimeout(t); res((as||[]).map(a=>(pn[a.get('Main.Assignment_Project')]||'?')+'~'+a.get('StartDate')+'~'+a.get('EndDate')).join('|') || 'NONE'); }; if(!pg.length) return fin({}); mx.data.get({ guids: pg, callback:function(ps){ const pn={}; (ps||[]).forEach(p=>pn[p.getGuid()]=p.get('Name')); fin(pn); }, error:function(e){ fin({}); } }); }, error:function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

# br8_pick_exact <combobox> <text> — pick the option whose text EQUALS <text>.
# tt_combobox_select_text matches a prefix, and "E2E Consultant" is a prefix of
# "E2E Consultant Two" and "... Three".
br8_pick_exact() {
  local cb="$1" want="$2" r i
  for i in 1 2 3 4 5 6; do
    if [ "$(playwright-cli eval "() => String(document.querySelectorAll('[role=option]').length)" 2>/dev/null | _tt_eval_str)" = "0" ]; then
      playwright-cli click "$cb" >/dev/null 2>&1
      sleep 1
    fi
    r="$(playwright-cli eval "() => { const os=[...document.querySelectorAll('[role=option]')]; const o=os.find(e=>(e.innerText||'').trim()==='$want'); if(o){o.click(); return 'PICKED';} return 'NOMATCH:'+os.map(e=>(e.innerText||'').trim()).join(','); }" 2>/dev/null | _tt_eval_str)"
    [ "$r" = "PICKED" ] && { sleep 2; return 0; }
    sleep 1
  done
  echo "  [combobox] '$want' not in $cb ($r)" >&2
  return 1
}

# ------------------------------------------ 1. e2e_hr needs an assignment of its own
tt_login "e2e_hr" "$TT_HR_READY"
HR_NAME="$(tt647_session_fullname)"
[ -n "$HR_NAME" ] || tt_fail "could not read the HR user's full name from the session"
echo "  acting HR user: $HR_USER ($HR_NAME)"

tt_login "e2e_tm" "Add Customer"
HA="$(br8_hr_assignments)"
echo "  $HR_USER assignments before: $HA"
case "$HA" in ERR:*) tt_fail "could not read $HR_USER's assignments as e2e_tm ($HA)" ;; esac
case "|$HA" in
  *"|$P~"*) echo "  $HR_USER already has an assignment on '$P'" ;;
  *)
    fx_log "giving '$HR_NAME' an assignment on '$P'"
    fx_view "cardConsultants" "galConsultants" >/dev/null
    playwright-cli click ".mx-name-btnAddAssignment" >/dev/null 2>&1
    tt_wait_for ".mx-name-cbCustomer" "Add Assignment popup"
    tt_combobox_select_text ".mx-name-cbCustomer" "$FX_CUSTOMER" \
      || tt_fail "customer '$FX_CUSTOMER' not selectable on the assignment form"
    tt_combobox_select_text ".mx-name-cbProject" "$P" \
      || tt_fail "project '$P' not selectable under '$FX_CUSTOMER'"
    br8_pick_exact ".mx-name-cbConsultant" "$HR_NAME" \
      || tt_fail "BLOCKED: the assignment form's consultant picker does not offer the HR user '$HR_NAME', so e2e_hr cannot be given an assignment of its own through the app. Bug #8 needs an HR or Titan Manager account that holds an active assignment."
    tt_fill ".mx-name-txtWeeklyHours input"      "40"
    tt_fill ".mx-name-txtTotalBudgetHours input" "$FX_BUDGET_HOURS"
    fx_fill_date ".mx-name-dpStartDate input" "$FX_START_DATE"
    fx_fill_date ".mx-name-dpEndDate input"   "$FX_END_DATE"
    playwright-cli click ".mx-name-btnSave" >/dev/null 2>&1
    sleep 4
    tt_clear_dialogs 4 >/dev/null 2>&1 || true
    HA="$(br8_hr_assignments)"
    echo "  $HR_USER assignments after: $HA"
    case "|$HA" in
      *"|$P~"*) ;;
      *) tt_fail "saved an assignment '$HR_NAME' -> '$P' but it is not there afterwards ($HA)" ;;
    esac ;;
esac

# ---------------------------------- 2. HR: Create Timesheet, pick the consultant
#
# THE WEEK IS CHOSEN BEFORE THE CONSULTANT. The week navigator lives inside the grid,
# and once a consultant is picked the grid is not rendered at all when that week is
# already submitted or approved (txtCreateTimesheetHelp: "If nothing appears below,
# this consultant's timesheet for this week is already submitted or approved"), so
# there is nothing left to step forward with. Verified on dev 2026-09-28. The week
# the page is on survives the pick, so: open the page, step N weeks ahead, pick,
# and try the next N if that week is not usable.
br8_open_week() {
  local n="$1" k
  tt_login "e2e_hr" "$TT_HR_READY"
  tt_click_text "Create Timesheet" "HR Create Timesheet nav item"
  sleep 3
  tt_wait_for ".mx-name-btnWeekNext" "Create Timesheet week navigator"
  for k in $(seq 1 "$n"); do
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  br8_pick_exact ".mx-name-cbCreateForAccount" "$C_NAME"     || tt_fail "'$C_NAME' is not offered by the Create Timesheet picker"
  sleep 2
  # Main.HR_ConfirmRewriteTimesheet ("Replace Existing Draft") opens on every pick.
  tt_clear_dialogs 6 "Replace Draft"     || tt_fail "the Replace Existing Draft prompt could not be confirmed: ${TT_DIALOG_BLOCKED:-unknown}"
  sleep 4
}

ok=""
for n in 1 2 3 4 5 6 7 8; do
  br8_open_week "$n"
  if [ "$(tt_week_actionable)" = "true" ]      && [ "$(playwright-cli eval "() => String(document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon').length)" 2>/dev/null | _tt_eval_str)" != "0" ]      && [ "$(tt_week_row_of "$P")" = "0" ]; then
    ok=1; break
  fi
  echo "  week +$n not usable for '$C_NAME' (no grid, no Clear, or a '$P' row already)"
done
[ -n "$ok" ] || tt_fail "no week in the next 8 where Clear is offered on '$C_NAME' with no '$P' row already showing"
WEEK="$(tt_current_week)"
[ -n "$WEEK" ] || tt_fail "could not read the week caption on Create Timesheet"
ROWS_BEFORE="$(tt_rows_text 2>/dev/null | head -c 400)"
echo "  week under test: $WEEK"

S0="$(tt_week_entries "$C_NAME" "$WEEK")"
echo "  before Clear: $S0"
case "$S0" in
  ERR:*) tt_fail "HR could not read $C_NAME's week $WEEK from the data layer ($S0)" ;;
esac
[ -z "$(tt_entry_status_of "$S0" "$P" "$HR_NAME")" ] \
  || tt_fail "precondition: $C_NAME's week $WEEK already holds an entry on $HR_USER's '$P' assignment before Clear ($S0) - left by an earlier run?"
tt_evidence "br8-before-clear"

# ------------------------------------------------------------------- 3. Clear
#
# PROVE CLEAR RAN. With nothing on the week, "no new row" is also what a Clear that
# never executed looks like. So put 1 hour on row 1's Monday and save it first; Clear
# zeroes every editable row, so that hour reading 0 afterwards is the proof it ran.
br8_mon1() { playwright-cli eval "() => String((document.querySelector('.mx-name-galAssignmentRows .mx-name-txtDayMon input')||{}).value||'')" 2>/dev/null | _tt_eval_str; }
tt_fill_commit ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDayMon input, 1)" "1"
sleep 1
playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
sleep 3
# Save Draft answers with an "Information: Draft saved." message. Do NOT re-read the
# week with tt_refetch_week here: stepping the navigator on this page re-runs the
# picked consultant's rewrite and left the grid off the week under test on dev.
tt_clear_dialogs 4 >/dev/null 2>&1 || true
sleep 1
case "$(br8_mon1)" in
  1|1.0|1.00) ;;
  *) tt_fail "could not save the 1-hour marker on row 1 (Monday reads '$(br8_mon1)') - without it a Clear that never ran is indistinguishable from a correct one" ;;
esac

playwright-cli click ".mx-name-btnClear" >/dev/null 2>&1 || tt_fail "the Clear button could not be clicked"
sleep 2
tt_clear_dialogs 8 "Clear" || tt_fail "the Clear confirmation could not be passed: ${TT_DIALOG_BLOCKED:-unknown}"
sleep 4
[ "$(tt_current_week)" = "$WEEK" ] || tt_fail "the grid left week $WEEK after Clear"
tt_evidence "br8-after-clear"
case "$(br8_mon1)" in
  ''|0|0.0|0.00) echo "  Clear ran (row 1 Monday 1 -> 0)" ;;
  *) tt_fail "Clear did not run: row 1 Monday still reads '$(br8_mon1)' - NOT evidence either way about bug #8" ;;
esac
GRID_P="$(tt_week_row_of "$P")"

# ------------------------------------------------------------- 4. the assertion
S1=""
for _ in 1 2 3; do
  S1="$(tt_week_entries "$C_NAME" "$WEEK")"
  case "$S1" in ERR:*|NOWEEK|'') sleep 3 ;; *) break ;; esac
done
echo "  after Clear: $S1"
case "$S1" in ERR:*|NOWEEK|'') tt_fail "could not read $C_NAME's week $WEEK back after Clear ($S1) - NOT evidence either way" ;; esac

FOREIGN="$(tt_entry_status_of "$S1" "$P" "$HR_NAME")"
if [ -n "$FOREIGN" ] || [ "$GRID_P" != "0" ]; then
  echo "FAIL: HR ($HR_USER) pressed Clear on $C_NAME's week $WEEK and the week gained an entry on"
  echo "      $HR_USER's OWN '$P' assignment (entry status: ${FOREIGN:-<not in data>}; grid row: $GRID_P)."
  echo "      Main.ACT_Timesheet_Clear rebuilds missing rows from the assignments of \$currentUser"
  echo "      - the HR user - instead of the account the week belongs to."
  echo "      Week before Clear: $S0"
  echo "      Week after Clear:  $S1"
  exit 1
fi

echo "PASS: verify-hr-clear-keeps-consultant-assignments - Clear on $C_NAME's week $WEEK added nothing from $HR_USER's own assignments"
