#!/usr/bin/env bash
# READ-ONLY: what the Manual data set holds on the target right now.
#   bash manual-env/probe-state.sh [username ...]
# For each Manual consultant: their assignments (project, window, budget, worked) and
# their weeks (start date, timesheet status, entry statuses, hours). Changes nothing.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/manual-env/manual.env.sh"
[ -n "${TT_BASE_URL:-}" ] || { echo "set TT_BASE_URL" >&2; exit 1; }

# q <xpath> <js expression over o> — one line per object, sorted.
q() {
  playwright-cli eval "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),25000); mx.data.get({ xpath: \"$1\", filter:{amount:2000}, callback: function(objs){ clearTimeout(t); const d=function(v){ return v ? new Date(v).toISOString().slice(0,10) : '-'; }; res((objs||[]).map(function(o){ return $2; }).sort().join('\\n')); }, error: function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e) { res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

ROWS=("manual_consultant|Manual Consultant" "manual_consultant2|Manual Consultant Two" "manual_consultant3|Manual Consultant Three")
[ $# -gt 0 ] && { ROWS=(); for u in "$@"; do for r in "manual_consultant|Manual Consultant" "manual_consultant2|Manual Consultant Two" "manual_consultant3|Manual Consultant Three"; do [ "${r%%|*}" = "$u" ] && ROWS+=("$r"); done; done; }

for row in "${ROWS[@]}"; do
  u="${row%%|*}"; n="${row#*|}"
  echo "=== $u ($n)"
  (
    playwright-cli close >/dev/null 2>&1; playwright-cli open "$TT_BASE_URL/" >/dev/null 2>&1
    tt_login "$u" "My Timesheets"
    sleep 2
    echo "-- assignments (window | budget | worked | weekly)"
    q "//Main.Assignment[ConsultantName = '$n']" "d(o.get('StartDate'))+'..'+d(o.get('EndDate'))+' | budget '+o.get('TotalBudgetHours')+' | worked '+o.get('TotalHoursWorked')+' | weekly '+o.get('WeeklyHours')+' | '+o.getGuid()"
    echo "-- projects of those assignments"
    q "//Main.Project[Main.Assignment_Project/Main.Assignment/ConsultantName = '$n']" "o.get('Name')+' | mgr='+o.get('ApprovalFromManager')+' cust='+o.get('ApprovalFromCustomer')+' lines='+o.get('NeedsLineItems')+' | '+o.get('ContactEmail')"
    echo "-- weeks (start | timesheet status | hours)"
    q "//Main.Timesheet[Main.AssignmentEntry_Timesheet/Main.AssignmentEntry/Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName = '$n']" "d(o.get('StartDate'))+' | '+o.get('Status')+' | '+o.get('TotalHours')"
    echo "-- entry status spread: $(manual_status_spread "$n")"
  ) 2>&1
done
playwright-cli close >/dev/null 2>&1
