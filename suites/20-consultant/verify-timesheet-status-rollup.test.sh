#!/usr/bin/env bash
# verify-timesheet-status-rollup.test.sh
#
# The week's own status keeps up with what happens inside it.
#
# WHY THIS EXISTS. Main.Timesheet carries a Status of its own — Draft, Awaiting
# Approval, Approved, Rejected — rolled up from the entries beneath it. It is what
# a consultant sees when they look at a week rather than a line, and **no step in
# the suite has ever read it**. Every status assertion in the suite is about
# AssignmentEntry. A rollup that stopped updating would leave weeks sitting at
# Draft forever while their entries sailed through approval, and nothing would
# notice.
#
# WHAT IT ASSERTS
#   A. No timesheet is in the dead state. ENUM_TimesheetStatus has five values but
#      Awaiting_Export is referenced nowhere in the model — nothing sets it and
#      nothing reads it. If a week ever turns up in it, something started writing
#      a status that no code understands.
#   B. Submitting a week moves that week's own status to Awaiting Approval. This
#      is the rollup working, observed causally: read before, submit, read after.
#
# It reads the statuses through the app's own client API rather than off the
# screen, because the rollup is a property of the data, and the page a consultant
# sees may show a per-entry status instead. Asking the object directly is both
# more precise and immune to how any particular screen chooses to render it.
#
# Uses e2e_consultant2 / E2E Sandbox, matching the other consultant steps.
# Consumes one week.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"

CUSER="${TT_ROLLUP_USER:-e2e_consultant2}"
PROJECT="${TT_ROLLUP_PROJECT:-E2E Sandbox}"

XPATH="//Main.Timesheet[Main.Timesheet_Account/Administration.Account/Name = '$CUSER']"

# ts_statuses — every one of this consultant's weeks as "<start> <status>", one
# per line, straight from the objects rather than from any page.
ts_statuses() {
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'), 15000); mx.data.get({ xpath: \"$XPATH\", filter: { amount: 300 }, callback: function(objs){ clearTimeout(t); try { res((objs||[]).map(function(o){ var d=o.get('StartDate'); var s=o.get('Status'); return (d? new Date(d).toISOString().slice(0,10) : '?') + ' ' + (s||'?'); }).join('\\n')); } catch(e) { res('ERR:read-'+e.message); } }, error: function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'retrieve-refused')); } }); } catch(e) { res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

ts_count_of() {  # ts_count_of <blob> <status>
  printf '%s\n' "$1" | grep -c " $2\$" || true
}

# ------------------------------------------------------------------ read before
tt_login "$CUSER" "My Timesheets"

before="$(ts_statuses)"
case "$before" in
  ERR:no-mx-client) tt_fail "the Mendix client API was not available, so the week statuses could not be read at all" ;;
  ERR:*)            tt_fail "could not read '$CUSER' timesheets ($before)" ;;
esac

total_before="$(printf '%s\n' "$before" | grep -c . || true)"
if [ "$total_before" -eq 0 ]; then
  tt_fail "'$CUSER' has no timesheets at all, so there is no rollup to observe. Run the consultant steps first."
fi
echo "  '$CUSER' has $total_before week(s) on record"

# ------------------------------------------------ A. nothing sits in the dead state
dead="$(ts_count_of "$before" "Awaiting_Export")"
if [ "$dead" -ne 0 ]; then
  echo "FAIL: verify-timesheet-status-rollup - $dead week(s) are in the Awaiting_Export state."
  echo "      That value exists in ENUM_TimesheetStatus but is referenced nowhere in the"
  echo "      model: nothing sets it and nothing reads it. A week in it is invisible to"
  echo "      every piece of logic that switches on timesheet status."
  printf '%s\n' "$before" | grep " Awaiting_Export\$" | sed 's/^/        /'
  exit 1
fi
echo "  no week is in the dead Awaiting_Export state"

aw_before="$(ts_count_of "$before" "Awaiting_Approval")"
echo "  weeks awaiting approval before: $aw_before"

# ----------------------------------------------------------- B. cause a rollup
WEEK="$(tt_goto_fresh_week "$PROJECT")" \
  || tt_fail "no fresh editable week with a '$PROJECT' row for '$CUSER' — cannot cause a rollup"

ord="$(playwright-cli eval "() => { const rows=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')]; for(let n=0;n<rows.length;n++){ let el=rows[n]; for(let k=0;k<10;k++){ el=el.parentElement; if(!el) break; if((el.innerText||'').indexOf('$PROJECT')>=0){ const inp=rows[n].querySelector('input'); if(inp && !inp.readOnly && !inp.disabled) return String(n+1); } } } return '0'; }" 2>/dev/null | _tt_eval_str)"
[ "$ord" != "0" ] || tt_fail "no editable '$PROJECT' row on week '$WEEK'"

for d in Mon Tues Wed Thurs Fri; do
  tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, ${ord})" "8"
done
tt_commit_focused
sleep 1
playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
sleep 3
tt_clear_dialogs 8 >/dev/null 2>&1 || true
sleep 3
echo "  submitted week '$WEEK' (40 hours)"

# ------------------------------------------------------------------- read after
after=""
aw_after="$aw_before"
for _ in $(seq 1 8); do
  after="$(ts_statuses)"
  case "$after" in ERR:*) sleep 4; continue ;; esac
  aw_after="$(ts_count_of "$after" "Awaiting_Approval")"
  [ "$aw_after" -gt "$aw_before" ] && break
  sleep 4
done

case "$after" in
  ERR:*) tt_fail "could not re-read '$CUSER' timesheets after submitting ($after)" ;;
esac
echo "  weeks awaiting approval after:  $aw_after"

if [ "$aw_after" -le "$aw_before" ]; then
  echo "FAIL: verify-timesheet-status-rollup - submitting week '$WEEK' did not move any week to Awaiting Approval ($aw_before -> $aw_after)."
  echo "      The entry was submitted but the week above it did not follow. A consultant"
  echo "      looking at the week list would still see it as a draft, and any logic that"
  echo "      switches on timesheet status would treat it as unsubmitted."
  echo "      Statuses now:"
  printf '%s\n' "$after" | sed 's/^/        /' | head -12
  exit 1
fi

echo "PASS: verify-timesheet-status-rollup - submitting '$WEEK' rolled a week up to Awaiting Approval ($aw_before -> $aw_after), and no week sits in the dead Awaiting_Export state"
