#!/usr/bin/env bash
# tt-timeout: 15m
# verify-tt780-submitted-zero-week-survives-date-move.test.sh
#
# TT-780 #1: a SUBMITTED 0-hour entry is never deleted because its assignment's
# dates moved afterwards.
#
# WHY THIS EXISTS. Every time a consultant's week loads while its timesheet is a
# draft, Main.DS_Timesheet_Get runs Main.SUB_Timesheet_SyncAssignments, which tidies
# the week: an entry whose assignment is no longer active that week is deleted if it
# looks like an empty leftover. Before TT-780 (model cade64ac) "empty" meant only "no
# hours and no line items", so this sequence silently destroyed a submitted entry:
#   1. the consultant submits a week; one project's line is 0 hours (it goes straight
#      to Weekly to process);
#   2. the Titan Manager moves that assignment's start to after the week;
#   3. another line in the same week is rejected, the consultant fixes it and saves
#      a draft - the timesheet is a draft again, so the next load runs the tidy-up;
#   4. the submitted 0-hour entry is gone - from HR's queue, the exports, the reports.
# The fix keeps the delete for entries that are still Draft (or empty) AND were never
# submitted (SubmittedDT empty). Nothing else in the suite moves an assignment's
# dates under a submitted week.
#
# ITS OWN DATA. Two throwaway projects, assigned to 'E2E Consultant Three' - in
# TT_E2E_CONSULTANTS and driven by no fixture spec - so the deep clear in 99-teardown
# deletes them and every entry this makes; the assignments and projects are also
# archived on exit. It works in a week TWO weeks ahead, which the Pending tab (past
# weeks only) never lists and no other spec drives for this consultant.
#   PX "E2E TT780 Zero <epoch>"   no approvals     - the line submitted at 0 h, then moved
#   PY "E2E TT780 Fix <epoch>"    manager approval - the line HR rejects and Three redrafts
#
# WHAT IT ASSERTS
#   setup (fatal): after Three submits, PX is ToProcess at 0.00 h and PY is past
#     Draft; after the move, PX's assignment starts the Sunday after the week; after
#     the reject-and-redraft, PY holds the new 6.00 h and the WEEK is a Draft again -
#     without that the tidy-up never runs and the assertion below could not fail.
#   A. PX's entry still exists in that week, still ToProcess, still 0.00 h.
#
# WHAT MAKES IT RED. Reverting the tidy-up's guard to "no hours, no line items" (or
# any other path that deletes or redrafts a submitted entry on a date move): A then
# reads PX absent, or back at Draft.
#
# Consumes: two projects and two assignments for E2E Consultant Three, one submitted
# week two weeks ahead, one manager rejection. Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/lib/_authz.sh"
source "$TT_ROOT/lib/_entries.sh"
source "$TT_ROOT/lib/_rejection.sh"

STAMP="$(date +%s)"
PX="E2E TT780 Zero $STAMP"
PY="E2E TT780 Fix $STAMP"
CNAME="E2E Consultant Three"
CUSER="e2e_consultant3"
OFFSET=2   # weeks ahead of this one
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

# Weeks start on Sunday (en_US), in Central time like the CI browser.
_wk_sun() {
  local today dow
  today="$(TZ=America/Chicago date +%Y-%m-%d)"
  dow="$(TZ=America/Chicago date +%w)"
  LC_ALL=C date -d "$today $(( 7 * $1 - dow )) days" +%Y-%m-%d
}
wk_key() { local s; s="$(_wk_sun "$1")"; printf '%s - %s' "$(LC_ALL=C date -d "$s" +'%b %d')" "$(LC_ALL=C date -d "$s +6 days" +'%b %d')"; }

W="$(wk_key "$OFFSET")"
NEXT_SUN="$(_wk_sun $(( OFFSET + 1 )))"   # YYYY-MM-DD, the new assignment start
note "week under test: $W; PX's assignment will move to start $NEXT_SUN"

# archive_all <xpath> - set Archived=true on every match, as a Boolean (tt_authz_write
# sets a string), committing one object at a time.
archive_all() {
  ev "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),30000); const commit=x=>new Promise((ok,ko)=>mx.data.commit({ mxobj:x, callback:ok, error:ko })); mx.data.get({ xpath: \"$1\", filter:{amount:20}, callback: async o => { if(!o||!o.length){ clearTimeout(t); return res('ERR:notfound'); } try { for (const x of o) { x.set('Archived', true); await commit(x); } clearTimeout(t); res('ok:'+o.length); } catch(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }, error: e => { clearTimeout(t); res('ERR:retrieve-'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })"
}

cleanup() {
  tt_login "e2e_tm" "Add Customer" >/dev/null 2>&1 || return 0
  local p
  for p in "$PX" "$PY"; do
    archive_all "//Main.Assignment[Main.Assignment_Project/Main.Project/Name = '$p']" >/dev/null
    archive_all "//Main.Project[Name = '$p']" >/dev/null
  done
  echo "  (archived the TT780 projects and assignments; the teardown clear of '$CNAME' deletes them)"
}
trap cleanup EXIT

# goto_week <key> — the consultant grid opens on this week; step FORWARD to <key>.
goto_week() {
  local want="$1" cur i
  for i in $(seq 1 8); do
    cur="$(tt_current_week)"
    [ "$cur" = "$want" ] && return 0
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  tt_fail "could not reach week $want on $CUSER's timesheet (last shown: '${cur:-?}')"
}

set_monday() {
  local ord
  ord="$(tt_week_row_of "$1" editable)"
  case "$ord" in ''|0|*[!0-9]*) tt_fail "no editable '$1' row on $(tt_current_week) (rows: $(tt_rows_text | cut -c1-200))" ;; esac
  tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDayMon input, $ord)" "$2"
  tt_commit_focused
  sleep 1
}

save_draft() {
  playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1 || tt_fail "no Save Draft button on $(tt_current_week)"
  sleep 3
  tt_clear_dialogs 4 >/dev/null 2>&1
}

ledger_as_hr() {
  tt_login "e2e_hr" "$TT_HR_READY" >/dev/null 2>&1
  tt_week_ledger "$CNAME" "$W"
}

# ------------------------------------------------------------------ 1. own data
tt_login "e2e_tm" "Add Customer"
fx_view "cardProjects" "galProjects"
fx_create_project "$PX" "No" "No" "No"
fx_create_project "$PY" "Yes" "No" "No"
fx_create_assignment "$CNAME" "$PX" 40 "$FX_CUSTOMER"
fx_create_assignment "$CNAME" "$PY" 40 "$FX_CUSTOMER"

# ------------------------------------------------------------------ 2. submit, PX at 0 h
tt_login "$CUSER" "My Timesheets"
goto_week "$W"
set_monday "$PY" 8
save_draft
playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1 || tt_fail "no Submit button on $W"
sleep 2
tt_clear_dialogs 8 || tt_fail "submitting $W was blocked by a dialog: $TT_DIALOG_BLOCKED"
sleep 3

L0="$(ledger_as_hr)"
note "submitted: [$L0]"
[ "$(tt_ledger_status "$L0" "$PX")" = "ToProcess" ] && [ "$(tt_ledger_hours "$L0" "$PX")" = "0.00" ] \
  || tt_fail "setup: '$PX' did not submit as a 0-hour ToProcess entry [$L0]"
case "$(tt_ledger_status "$L0" "$PY")" in
  Draft|'(empty)'|'') tt_fail "setup: '$PY' was not submitted [$L0]" ;;
esac

# ------------------------------------------------------------------ 3. move PX's start
# Written through the data layer as the Titan Manager, keeping whatever time-of-day
# convention the stored value already uses (a midnight-UTC date stays midnight UTC,
# a local midnight stays local), so the move is exactly whole days.
tt_login "e2e_tm" "Add Customer"
IFS=- read -r NY NM ND <<< "$NEXT_SUN"
MOVED="$(ev "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"//Main.Assignment[Main.Assignment_Project/Main.Project/Name = '$PX']\", filter:{amount:1}, callback: objs => { if(!objs||!objs.length){ clearTimeout(t); return res('ERR:notfound'); } const a=objs[0]; const old=new Date(a.get('StartDate')); let nd; if(old.getUTCHours()===0 && old.getUTCMinutes()===0){ nd=Date.UTC($NY, $((10#$NM)) - 1, $((10#$ND))); } else { const d=new Date(old.getTime()); d.setFullYear($NY, $((10#$NM)) - 1, $((10#$ND))); nd=d.getTime(); } try { a.set('StartDate', nd); } catch(e){ clearTimeout(t); return res('ERR:set-'+e.message); } mx.data.commit({ mxobj:a, callback: () => { clearTimeout(t); res('ok:'+old.toISOString()+'->'+new Date(nd).toISOString()); }, error: e => { clearTimeout(t); res('ERR:commit-'+((e&&e.message)||'refused')); } }); }, error: e => { clearTimeout(t); res('ERR:retrieve-'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })")"
case "$MOVED" in
  ok:*) note "moved PX's assignment start: ${MOVED#ok:}" ;;
  *) tt_fail "setup: could not move '$PX''s assignment start as the Titan Manager ($MOVED)" ;;
esac

# ------------------------------------------------------------------ 4. reject PY, redraft it
TT_REJECT_WEEK="$W" tt_hr_reject_project "$CNAME" "$PY" "Manager approval" "E2E TT-780 reject to reopen the week" \
  || tt_fail "setup: could not reject '$PY' for $CNAME in $W"

tt_login "$CUSER" "My Timesheets"
goto_week "$W"
set_monday "$PY" 6
save_draft
# The tidy-up runs when the week LOADS as a draft, not on the save itself.
tt_refetch_week
sleep 2
tt_refetch_week

L1="$(ledger_as_hr)"
note "after the redraft: [$L1]"
[ "$(tt_ledger_hours "$L1" "$PY")" = "6.00" ] \
  || tt_fail "setup: '$PY' does not hold the redrafted 6.00 h, so the save never reached the server and nothing below was exercised [$L1]"
case "$(tt_ledger_status "$L1" WEEK)" in
  Draft|'(empty)') ;;
  *) tt_fail "setup: the week's timesheet is [$(tt_ledger_status "$L1" WEEK)], not Draft, so SUB_Timesheet_SyncAssignments never ran and A could not fail [$L1]" ;;
esac

# ------------------------------------------------------------------ A. PX survived
S="$(tt_ledger_status "$L1" "$PX")"; H="$(tt_ledger_hours "$L1" "$PX")"
if [ "$S" = "ToProcess" ] && [ "$H" = "0.00" ]; then
  note "A ok: the submitted 0-hour '$PX' entry is still there, ToProcess at 0.00 h"
elif [ -z "$S" ]; then
  bad "A: the submitted 0-hour '$PX' entry was DELETED from $W after its assignment moved - the TT-780 bug"
else
  bad "A: the submitted 0-hour '$PX' entry is now [$S] at [$H] h; expected ToProcess at 0.00"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-tt780-submitted-zero-week-survives-date-move - a submitted 0-hour entry did not survive its assignment's date move."
  exit 1
fi
echo "PASS: verify-tt780-submitted-zero-week-survives-date-move - the submitted 0-hour entry outlived the date move and the week's redraft."
