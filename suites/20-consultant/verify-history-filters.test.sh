#!/usr/bin/env bash
# The consultant's Timesheet History filters narrow the list to exactly the weeks
# they describe, a filter that matches nothing shows the empty state, and clearing
# a filter brings every week back.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. galTimesheetHistory (Main.ConsultantDashboard) gained three
# filters in its header - filterStatus (a dropdown on Timesheet.Status), and
# filterStartDate / filterEndDate (date filters on StartDate, "on or after", and
# EndDate) - plus an empty state, containerNoTimesheets ("No timesheets to show").
# verify-history-row-layout and verify-history-status-badge read the rows and
# deliberately never touch a filter, so nothing checked that a filter filters.
#
# HOW THE EXPECTATION IS BUILT. From the data layer, as the consultant: their own
# Main.Timesheet rows, with Status and StartDate. Every count below is constrained
# to this consultant - it is their own history list - and every filtered count is
# compared with what the data says that filter should leave, not with a number
# written down here.
#
# WHAT IT ASSERTS (e2e_consultant)
#   A. unfiltered, the list shows one row per week the data holds;
#   B. filtering by a status that some but not all weeks have leaves exactly those
#      weeks, and every remaining pill reads that status;
#   C. clearing the status filter restores every week;
#   D. a start date between two weeks leaves exactly the weeks starting on or
#      after it;
#   E. a start date past every week leaves no rows and shows containerNoTimesheets
#      with its "No timesheets to show" title;
#   F. clearing the date restores every week and the empty state is gone.
#
# If the consultant's weeks all share one status (B would then filter nothing),
# it seeds: a submit on 'E2E Manager Approval' when no week is past Draft, then a
# saved Draft week when none is Draft - see the note at the seeding code.
#
# Leaves every filter cleared, so the next spec reading this list sees all of it.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_rejection.sh"

CUSER="e2e_consultant"
GAL=".mx-name-galTimesheetHistory"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

# The pill caption each status renders with (verify-history-status-badge's table).
pill_of() {
  case "$1" in
    Draft) echo "Draft" ;; Awaiting_Approval) echo "Submitted" ;; Approved) echo "Approved" ;;
    Rejected) echo "Rejected" ;; Awaiting_Export) echo "Awaiting export" ;; *) echo "?" ;;
  esac
}
# The filter's option caption for each status (the enumeration's captions).
option_of() {
  case "$1" in
    Awaiting_Approval) echo "Awaiting Approval" ;; Awaiting_Export) echo "Awaiting Export" ;; *) echo "$1" ;;
  esac
}

# data_weeks - "<status>|<StartDate ms>" per timesheet of this consultant, ~-joined.
data_weeks() {
  ev "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"//Main.Timesheet[Main.Timesheet_Account/Administration.Account/Name = '$CUSER']\", filter:{amount:500}, callback: o => { clearTimeout(t); res(o.map(x=>(x.get('Status')||'')+'|'+Number(x.get('StartDate')||0)).join('~') || 'NONE'); }, error: e => { clearTimeout(t); res('ERR:'+e.message); } }); } catch(e) { res('ERR:'+e.message); } })"
}
# ui_rows - "<pill>|<week text>" per rendered row, ~-joined, after paging it all in.
ui_rows() {
  tt_gallery_load_all "$GAL" "timesheet history" >/dev/null 2>&1
  ev "() => [...document.querySelectorAll('$GAL .widget-gallery-item')].filter(r=>r.querySelector('.mx-name-txtHistoryWeek')).map(r=>((r.querySelector('.mx-name-txtHistoryStatus')||{}).innerText||'').trim()+'|'+((r.querySelector('.mx-name-txtHistoryWeek')||{}).innerText||'').trim()).join('~')"
}
count_of() { [ -z "$1" ] && echo 0 || printf '%s' "$1" | tr '~' '\n' | grep -c .; }
empty_state() { ev "() => { const e=document.querySelector('$GAL .mx-name-containerNoTimesheets'); return e && e.offsetParent!==null ? (e.innerText||'').replace(/\\s+/g,' ').trim() : 'HIDDEN'; }"; }

# settle <expected-count> - wait for the list to show that many rows; echoes the rows.
settle() {
  local want="$1" rows="" i
  for i in $(seq 1 12); do
    rows="$(ui_rows)"
    [ "$(count_of "$rows")" = "$want" ] && break
    sleep 1
  done
  printf '%s' "$rows"
}

# --- filter drivers ---------------------------------------------------------
set_status() {  # <option caption, or '' for all statuses>
  local want="$1" r i
  for i in 1 2 3 4; do
    playwright-cli click "$GAL .mx-name-filterStatus" >/dev/null 2>&1
    sleep 1
    r="$(ev "() => { const o=[...document.querySelectorAll('[role=option], [role=menuitem]')].filter(e=>e.offsetParent!==null); const want='$want'; const hit = want ? o.find(e=>(e.innerText||'').trim()===want) : o.find(e=>/all statuses/i.test((e.innerText||'').trim())); if(hit){ hit.click(); return 'PICKED'; } return 'NOMATCH:'+o.map(e=>(e.innerText||'').trim()).join(','); }")"
    [ "$r" = "PICKED" ] && { sleep 2; return 0; }
  done
  tt_fail "status filter: could not pick '${want:-All statuses}' ($r)"
}
set_start_date() {  # <M/d/yyyy or ''>
  local sel="$GAL .mx-name-filterStartDate input"
  playwright-cli fill "$sel" "" >/dev/null 2>&1
  if [ -n "$1" ]; then
    playwright-cli click "$sel" >/dev/null 2>&1
    playwright-cli type "$1" >/dev/null 2>&1
  fi
  playwright-cli press Tab >/dev/null 2>&1
  sleep 2
}
fmt_date() { ev "() => { const d=new Date($1); return (d.getMonth()+1)+'/'+d.getDate()+'/'+d.getFullYear(); }"; }

tt_login "$CUSER" "My Timesheets"
tt_wait_for "$GAL" "the timesheet history gallery"

DATA="$(data_weeks)"
case "$DATA" in ERR:*|''|NONE) tt_fail "could not read $CUSER's timesheets from the data layer ($DATA)" ;; esac

# Make sure there are two statuses to tell apart.
DISTINCT="$(printf '%s' "$DATA" | tr '~' '\n' | cut -d'|' -f1 | grep . | sort -u | wc -l | tr -d ' ')"
ONLY="$(printf '%s' "$DATA" | tr '~' '\n' | cut -d'|' -f1 | grep . | sort -u | head -1)"

# seed_draft_week - walk forward to the first week whose 'E2E Manager Approval' row
# is editable and offers Save Draft, type 2 h on Monday and save it as a draft. A
# Submit would only add another week of the status the history already has (in a
# suite run that is Awaiting_Approval: run 2026-10-06 saw 3 -> 5 Awaiting weeks and
# B still had nothing to exclude), so the second status has to be Draft.
seed_draft_week() {
  local i ord
  for i in $(seq 1 "${TT_SUBMIT_WEEK_HORIZON:-30}"); do
    ord="$(tt_week_row_of "E2E Manager Approval" editable)"
    if [ -n "$ord" ] && [ "$ord" != "0" ] && [ "$(tt_week_actionable)" = "true" ]; then
      tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDayMon input, $ord)" "2"
      tt_commit_focused
      sleep 1
      playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1 || tt_fail "seed: no Save Draft on $(tt_current_week)"
      sleep 3
      tt_clear_dialogs 4 >/dev/null 2>&1
      note "seed: saved $(tt_current_week) as a draft"
      return 0
    fi
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  tt_fail "seed: no editable 'E2E Manager Approval' week with Save Draft within ${TT_SUBMIT_WEEK_HORIZON:-30} weeks"
}

# Seed until the history holds a Draft week AND a week of some other status - the
# two B needs to tell apart. Weeks with NO status (rows the app created just by
# showing a week, never saved) are listed but are not a status B can filter on, so
# they count as neither.
#
# The order matters. Submitting and saving a draft both act on the FIRST actionable
# week with the project's row, so "submit one when everything is Draft" can submit
# the only Draft week and leave the history at one status again (CI runs
# 37524334459 and 37586419168: one Awaiting_Approval week, every other week unset).
# So: when there is no non-Draft week, submit one first; then, if no Draft week is
# left, save one - the submitted week is no longer actionable, so that lands on the
# NEXT week and cannot undo the submit.
statuses()  { printf '%s' "$DATA" | tr '~' '\n' | cut -d'|' -f1 | grep . | sort -u; }
reread() {
  tt_clear_dialogs 4 >/dev/null 2>&1
  tt_login "$CUSER" "My Timesheets"
  tt_wait_for "$GAL" "the timesheet history gallery"
  DATA="$(data_weeks)"
  case "$DATA" in ERR:*|''|NONE) tt_fail "seed: could not re-read $CUSER's timesheets ($DATA)" ;; esac
}
if ! statuses | grep -qvx Draft; then
  note "seed: $CUSER has no week past Draft ($(statuses | tr '\n' ' ')) - submitting one on E2E Manager Approval"
  tt_consultant_submit_project_row "E2E Manager Approval"
  reread
fi
if ! statuses | grep -qx Draft; then
  note "seed: $CUSER has no Draft week ($(statuses | tr '\n' ' ')) - saving one"
  seed_draft_week
  reread
fi
DISTINCT="$(statuses | wc -l | tr -d ' ')"
[ "$DISTINCT" -ge 2 ] || tt_fail "seed: $CUSER's weeks still share one status after seeding (data: $DATA)"
N_ALL="$(count_of "$DATA")"

# ------------------------------------------------------------------ A. unfiltered
ALL_ROWS="$(settle "$N_ALL")"
if [ "$(count_of "$ALL_ROWS")" = "$N_ALL" ]; then
  note "A ok: $N_ALL weeks in the data, $N_ALL rows in the list"
else
  bad "A: the data holds $N_ALL weeks for $CUSER, the unfiltered list shows $(count_of "$ALL_ROWS")"
fi

# ------------------------------------------------------------------ B. status
PICKED=""
for s in Awaiting_Approval Approved Rejected Awaiting_Export Draft; do
  n="$(printf '%s' "$DATA" | tr '~' '\n' | grep -c "^$s|")"
  if [ "$n" -gt 0 ] && [ "$n" -lt "$N_ALL" ]; then PICKED="$s"; N_S="$n"; break; fi
done
[ -n "$PICKED" ] || tt_fail "B: no status covers some but not all of $CUSER's $N_ALL weeks (data: $DATA)"
set_status "$(option_of "$PICKED")"
ROWS="$(settle "$N_S")"
WRONG="$(printf '%s' "$ROWS" | tr '~' '\n' | grep . | grep -v "^$(pill_of "$PICKED")|" | head -3 | tr '\n' ';')"
if [ "$(count_of "$ROWS")" = "$N_S" ] && [ -z "$WRONG" ]; then
  note "B ok: '$(option_of "$PICKED")' leaves the $N_S matching weeks, every pill '$(pill_of "$PICKED")'"
else
  bad "B: filtered to '$(option_of "$PICKED")' the list shows $(count_of "$ROWS") rows (data: $N_S), rows with another pill: [${WRONG}]"
fi

# ------------------------------------------------------------------ C. clear status
set_status ""
ROWS="$(settle "$N_ALL")"
[ "$(count_of "$ROWS")" = "$N_ALL" ] && note "C ok: all $N_ALL weeks back" || bad "C: after clearing the status filter the list shows $(count_of "$ROWS") of $N_ALL weeks"

# ------------------------------------------------------------------ D. start date
# The day after the middle week's start: strictly between two weekly starts, so
# no timezone reading of a date-only filter can move a week across it.
STARTS="$(printf '%s' "$DATA" | tr '~' '\n' | cut -d'|' -f2 | grep -v '^0$' | sort -n)"
MID="$(printf '%s\n' "$STARTS" | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')"
CUT=$(( MID + 86400000 ))
N_D="$(printf '%s\n' "$STARTS" | awk -v c="$CUT" '$1>=c' | grep -c .)"
if [ "$N_D" -gt 0 ] && [ "$N_D" -lt "$N_ALL" ]; then
  CUT_TXT="$(fmt_date "$CUT")"
  set_start_date "$CUT_TXT"
  ROWS="$(settle "$N_D")"
  [ "$(count_of "$ROWS")" = "$N_D" ] && note "D ok: from $CUT_TXT leaves the $N_D later weeks" \
    || bad "D: start date $CUT_TXT leaves $(count_of "$ROWS") rows; the data has $N_D weeks starting on or after it"
else
  bad "D: cannot place a start date strictly inside $CUSER's $N_ALL weeks (data: $DATA)"
fi

# ------------------------------------------------------------------ E. nothing matches
set_start_date "1/1/2099"
ROWS="$(settle 0)"
ES="$(empty_state)"
if [ "$(count_of "$ROWS")" = "0" ] && [ "${ES#*No timesheets to show}" != "$ES" ]; then
  note "E ok: no rows, empty state reads '$ES'"
else
  bad "E: a start date of 1/1/2099 leaves $(count_of "$ROWS") rows and the empty state reads [$ES]"
fi

# ------------------------------------------------------------------ F. clear date
set_start_date ""
ROWS="$(settle "$N_ALL")"
ES="$(empty_state)"
if [ "$(count_of "$ROWS")" = "$N_ALL" ] && [ "$ES" = "HIDDEN" ]; then
  note "F ok: all $N_ALL weeks back, empty state gone"
else
  bad "F: after clearing the date the list shows $(count_of "$ROWS") of $N_ALL weeks, empty state [$ES]"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-history-filters - $fails problem(s) with the timesheet history filters."
  exit 1
fi
echo "PASS: verify-history-filters - status and start-date filters leave exactly the weeks the data says, and the empty state shows when nothing matches."
