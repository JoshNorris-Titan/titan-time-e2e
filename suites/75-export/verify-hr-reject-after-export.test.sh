#!/usr/bin/env bash
# verify-hr-reject-after-export.test.sh
#
# Rejecting an entry AFTER it has been exported (state transition T19,
# Exported -> Rejected) — and the hours arithmetic that goes with it.
#
# WHY THIS EXISTS. Once a week has been exported it has, in practice, been
# invoiced. ACT_RejectAfterExport is the only route back from there, and it was
# completely untested. Its own annotation states what it must do:
#
#   "Sets an assignment entry status to reject and subtracts the entry's total
#    hours worked from its assignment's total hours worked"
#
# The subtraction is the part worth guarding. If it silently stopped happening the
# entry would still visibly leave the Sent tab, every UI-level check would pass, and
# the assignment would quietly over-report hours worked for the rest of its life.
# So this asserts the exact arithmetic, not just the status change.
#
# WHY IT LIVES IN 75-export. It needs an entry in Exported state, and the only route
# there is Process -> Export All, which exports everything awaiting export across the
# environment. Rather than trigger that from an early folder, this runs AFTER
# suites/70-tickets/tt683/, reusing the entries those tests have already exported.
# The fallback below can still drive the chain itself, and says so loudly when it does.
#
# SELECTORS. btnRejectAfterExport and dataGrid2_1 are real names. The two values read
# out of the UI are anchored on LABEL TEXT rather than on the auto-generated widgets
# that hold them (text27 for the card's hours, and the grid's column position):
# 'TOTAL HOURS' and the 'Total Hours Worked' column header are the stable contract,
# and text27 could not be renamed anyway — it lives in a snippet, which the model
# tooling cannot reach.
#
# Consumes one exported entry.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt683.sh"

CONSULTANT_NAME="${TT_EXPORT_CONSULTANT:-E2E Consultant}"

# ---------------------------------------------------------------------- helpers

# hre_open_reject_tab — land on whichever HR tab exposes the post-export Reject.
# The tab-switch controls were never named, so tabs are selected by their caption;
# which tab carries this button is a model decision, so it is discovered, not assumed.
hre_open_reject_tab() {
  local lbl labels
  tt_login "e2e_hr" "WEEKLY TO PROCESS"
  if [ "$(hre_has_reject_button)" = "true" ]; then echo "(landing tab)"; return 0; fi
  labels="$(tt683_tab_labels)"
  local IFS='|'
  for lbl in $labels; do
    [ -n "$lbl" ] || continue
    unset IFS
    tt_click_text "$lbl" "HR '$lbl' tab" 2>/dev/null || true
    sleep 2
    if [ "$(hre_has_reject_button)" = "true" ]; then echo "$lbl"; return 0; fi
    IFS='|'
  done
  unset IFS
  return 1
}

hre_has_reject_button() {
  playwright-cli eval "() => String([...document.querySelectorAll('.mx-name-btnRejectAfterExport')].some(b => b.offsetParent !== null))" 2>/dev/null | _tt_eval_str
}

# hre_card_facts — find the exported card for our consultant and read PROJECT, WEEK
# and TOTAL HOURS off it. Values are taken as "the line after the label", which is
# how the card stacks its label/value pairs; that survives the widget renumbering
# that auto-generated names do not.
hre_card_facts() {
  playwright-cli eval "() => { const btns=[...document.querySelectorAll('.mx-name-btnRejectAfterExport')].filter(b=>b.offsetParent!==null); for(const b of btns){ let p=b; for(let k=0;k<12;k++){ if(!p.parentElement) break; p=p.parentElement; const t=(p.innerText||''); if(t.length<1500 && t.indexOf('$CONSULTANT_NAME')>=0 && t.toUpperCase().indexOf('TOTAL HOURS')>=0){ const lines=t.split('\\n').map(s=>s.trim()).filter(Boolean); const after=(lbl)=>{ const i=lines.findIndex(x=>x.toUpperCase()===lbl); return (i>=0 && i+1<lines.length) ? lines[i+1] : ''; }; return JSON.stringify({project:after('PROJECT'), week:after('WEEK'), hours:after('TOTAL HOURS')}); } } } return ''; }" 2>/dev/null | _tt_eval_str
}

# hre_click_reject <project> — press Reject on the card for our consultant + project.
hre_click_reject() {
  playwright-cli eval "() => { const btns=[...document.querySelectorAll('.mx-name-btnRejectAfterExport')].filter(b=>b.offsetParent!==null); for(const b of btns){ let p=b; for(let k=0;k<12;k++){ if(!p.parentElement) break; p=p.parentElement; const t=(p.innerText||''); if(t.length<1500 && t.indexOf('$CONSULTANT_NAME')>=0 && t.indexOf('$1')>=0){ b.click(); return 'clicked'; } } } return 'nf'; }" 2>/dev/null | _tt_eval_str
}

# hre_assignment_hours <project> — the assignment's Total Hours Worked, as Titan
# Manager. The column is located by its HEADER TEXT, so reordering columns does not
# silently make this read the wrong number.
hre_assignment_hours() {
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-dataGrid2_1'); if(!g) return 'NOGRID'; const heads=[...g.querySelectorAll('[role=columnheader], th')].map(e=>(e.innerText||'').trim()); const ci=heads.findIndex(h=>/total\\s*hours\\s*worked/i.test(h)); if(ci<0) return 'NOCOL:'+heads.join('/'); const rows=[...g.querySelectorAll('[role=row], tr')]; for(const r of rows){ const t=(r.innerText||''); if(t.indexOf('$CONSULTANT_NAME')>=0 && t.indexOf('$1')>=0){ const cells=[...r.querySelectorAll('[role=gridcell], td')]; if(cells[ci]) return (cells[ci].innerText||'').trim(); } } return 'NOROW'; }" 2>/dev/null | _tt_eval_str
}

# hre_open_assignment_grid — land on the Titan Manager assignment overview. The TM
# landing page is identified by "Add Customer" (as the 50-titan-manager tests do);
# the assignment grid may be on it or one navigation step away, so this checks
# before clicking rather than assuming either shape.
hre_open_assignment_grid() {
  local lbl
  tt_login "e2e_tm" "Add Customer"
  [ "$(hre_has_grid)" = "true" ] && return 0
  for lbl in "Assignments" "Assignment Overview" "ASSIGNMENTS"; do
    tt_click_text "$lbl" "TM '$lbl' navigation" 2>/dev/null || continue
    sleep 2
    [ "$(hre_has_grid)" = "true" ] && return 0
  done
  tt_fail "could not reach the assignment overview grid (.mx-name-dataGrid2_1) as Titan Manager"
}

hre_has_grid() {
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-dataGrid2_1'))" 2>/dev/null | _tt_eval_str
}

hre_num() {  # strip anything that is not part of a decimal number
  printf '%s' "$1" | tr -d ' ,' | grep -oE '^-?[0-9]+(\.[0-9]+)?' || true
}

# --------------------------------------------------------- 1. find an exported entry
TAB="$(hre_open_reject_tab)" \
  || tt_fail "no HR dashboard tab exposes .mx-name-btnRejectAfterExport — post-export rejection is unreachable in the UI"
echo "post-export reject lives on tab: $TAB"

FACTS="$(hre_card_facts)"
if [ -z "$FACTS" ]; then
  echo "no exported entry for '$CONSULTANT_NAME' — driving Process + Export All to create one"
  echo "  NOTE: Export All exports EVERY entry awaiting export on this environment."
  tt683_open_toprocess_tab >/dev/null 2>&1 || true
  tt683_process_all_toprocess >/dev/null 2>&1 || true
  tt683_open_export_tab >/dev/null 2>&1 && tt683_click_export_all >/dev/null 2>&1 || true
  sleep 5
  tt_clear_dialogs 8 >/dev/null 2>&1 || true
  TAB="$(hre_open_reject_tab)" || tt_fail "post-export reject tab vanished after the export chain"
  FACTS="$(hre_card_facts)"
fi
[ -n "$FACTS" ] \
  || tt_fail "no exported entry for '$CONSULTANT_NAME' on tab '$TAB', and the Process/Export chain did not produce one. Run suites/70-tickets/tt683/verify-tt683-a0-seed-awaiting-export.test.sh first."

PROJECT="$(printf '%s' "$FACTS" | sed -n 's/.*"project":"\([^"]*\)".*/\1/p')"
WEEK="$(printf '%s' "$FACTS"    | sed -n 's/.*"week":"\([^"]*\)".*/\1/p')"
HOURS_RAW="$(printf '%s' "$FACTS" | sed -n 's/.*"hours":"\([^"]*\)".*/\1/p')"
HOURS="$(hre_num "$HOURS_RAW")"

[ -n "$PROJECT" ] || tt_fail "could not read PROJECT off the exported card: $FACTS"
[ -n "$HOURS" ]   || tt_fail "could not read a numeric TOTAL HOURS off the exported card (got '$HOURS_RAW'): $FACTS"
echo "exported entry: project='$PROJECT' week='$WEEK' hours=$HOURS"

# ------------------------------------------- 2. the assignment total, before
hre_open_assignment_grid
BEFORE_RAW="$(hre_assignment_hours "$PROJECT")"
case "$BEFORE_RAW" in
  NOGRID) tt_fail "assignment overview grid not found as Titan Manager" ;;
  NOCOL:*) tt_fail "no 'Total Hours Worked' column on the assignment grid; headers were: ${BEFORE_RAW#NOCOL:}" ;;
  NOROW)  tt_fail "no assignment row for '$CONSULTANT_NAME' / '$PROJECT' on the visible page of the grid" ;;
esac
BEFORE="$(hre_num "$BEFORE_RAW")"
[ -n "$BEFORE" ] || tt_fail "assignment Total Hours Worked is not numeric before the reject (got '$BEFORE_RAW')"
echo "assignment total hours worked, before: $BEFORE"

# -------------------------------------------------------- 3. reject after export
TAB="$(hre_open_reject_tab)" || tt_fail "could not return to the post-export reject tab"
rc="$(hre_click_reject "$PROJECT")"
[ "$rc" = "clicked" ] \
  || tt_fail "could not press Reject on the exported card for '$PROJECT' (state: $rc)"
tt_clear_dialogs 8 "Reject" \
  || tt_fail "post-export rejection confirmation was not dismissed: ${TT_DIALOG_BLOCKED:-unknown dialog}"
sleep 4

# The card must leave the tab. Poll — the flow commits and refreshes every tab.
gone=""
for _ in $(seq 1 10); do
  [ -z "$(hre_card_facts)" ] && { gone=1; break; }
  sleep 3
done
[ -n "$gone" ] \
  || tt_fail "the exported entry for '$PROJECT' is still on tab '$TAB' after Reject — ACT_RejectAfterExport's 'Exported?' guard may have refused it"

# ---------------------------------------- 4. the arithmetic, which is the point
hre_open_assignment_grid

AFTER=""
EXPECTED="$(awk -v b="$BEFORE" -v h="$HOURS" 'BEGIN{printf "%.2f", b-h}')"
for _ in $(seq 1 8); do
  AFTER="$(hre_num "$(hre_assignment_hours "$PROJECT")")"
  [ -n "$AFTER" ] && [ "$(awk -v a="$AFTER" -v e="$EXPECTED" 'BEGIN{print (a-e<0.005 && e-a<0.005) ? "y" : "n"}')" = "y" ] && break
  sleep 4
  playwright-cli reload >/dev/null 2>&1
  sleep 3
done
[ -n "$AFTER" ] || tt_fail "could not read the assignment total after the reject"

same="$(awk -v a="$AFTER" -v e="$EXPECTED" 'BEGIN{print (a-e<0.005 && e-a<0.005) ? "y" : "n"}')"
if [ "$same" != "y" ]; then
  unchanged="$(awk -v a="$AFTER" -v b="$BEFORE" 'BEGIN{print (a-b<0.005 && b-a<0.005) ? "y" : "n"}')"
  if [ "$unchanged" = "y" ]; then
    tt_fail "the entry was rejected but the assignment total stayed at $BEFORE — the hours subtraction in ACT_RejectAfterExport did not happen, so '$PROJECT' now over-reports $HOURS hours"
  fi
  tt_fail "assignment total went $BEFORE -> $AFTER after rejecting a $HOURS-hour entry; expected $EXPECTED"
fi

echo "PASS: verify-hr-reject-after-export — exported entry for '$PROJECT' ($WEEK, ${HOURS}h) rejected; assignment total $BEFORE -> $AFTER as expected"
