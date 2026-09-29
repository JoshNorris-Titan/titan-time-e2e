#!/usr/bin/env bash
# An entry that is built from line items adds up to them.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS. On a project with NeedsLineItems, the day cells are not typed
# directly - the hours come from the task breakdown, and Main.SUB_Timesheet_RecalcAll
# rolls the LineItem hours up into the AssignmentEntry. Two numbers, maintained in
# one direction, with nothing comparing them afterwards.
#
# The suite's existing line-item coverage stops short of this on purpose:
# verify-consultant-line-items asserts only the per-task line total and
# deliberately DISMISSES the row-rollup error dialog (TT-692), so a permanently
# broken assignment-row rollup is invisible there. tt692693-b1 asserts the row
# rollup for one entry in one scenario. Neither reconciles the two afterwards, and
# neither would notice a rollup that drifts once the popup is closed.
#
# It matters because the entry's TotalHours is what reaches the week total, the
# approval queue, the exported PDF and the invoice. The line items are what the
# consultant actually filled in. If those disagree, everything downstream is
# working faithfully from the wrong number.
#
# WHAT IT ASSERTS, over E2E entries that HAVE line items:
#   A. the entry's TotalHours equals the sum of its line items' hours - each line
#      item's seven day values (Main.LineItem.Sunday..Saturday), which are what
#      the consultant typed and what SUB_LineItem_Calc rolls up. (This read a
#      'Hours' attribute until 2026-09-29; Main.LineItem has none, so every line
#      item summed to 0 - it had simply never met a line item to find out.);
#   B. no line item is nameless - tt_assert_no_unnamed_tasks enforces that before a
#      submit, but nothing checks it afterwards, and a nameless task on an exported
#      PDF is a line the client cannot account for;
#   C. something was examined;
#   E. the task this step seeded kept its hours and its entry was among those
#      reconciled in A.
#
# Entries with no line items are skipped and counted: most projects do not use them,
# and failing on those would make this test depend on which fixtures ran.
#
# IT SEEDS ITS OWN LINE ITEM (2026-09-29). It used to read only, relying on
# "suites/20-consultant and tt692693" to have left a line item behind. Neither
# does by the time it runs: verify-consultant-line-items deletes every task it
# adds (its cleanup is an assertion), verify-timesheet-clear-keeps-tasks runs
# AFTER this file, and tt692693 is in 70-tickets. So on every full run it found
# no line item at all and failed on its precondition. It now adds one named task
# with known hours to a fresh 'E2E Line Items' week of e2e_consultant and saves
# the draft, which is the path that rolls line items up into the entry
# (Main.ACT_Timesheet_Draft -> SUB_Timesheet_RecalcAll). A-C then run over every
# E2E entry with line items, and E requires the seeded entry itself to have been
# reconciled - so the step can never pass by examining nothing new.
#
# Consumes: one fresh 'E2E Line Items' week of e2e_consultant, left in Draft with
# one task on it (the bookend clear removes it).
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"
source "$TT_ROOT/lib/_tt654.sh"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

OWNED="starts-with(Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName,'E2E ')"

entries() {
  playwright-cli eval "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),20000); mx.data.get({ xpath: \"//Main.AssignmentEntry[$OWNED]\", filter:{amount:300}, callback:function(o){ clearTimeout(t); res((o||[]).map(e=>e.getGuid()+'~'+String(e.get('TotalHours'))).join('|')); }, error:function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}
lineitems() {
  playwright-cli eval "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),20000); mx.data.get({ xpath: \"//Main.LineItem[starts-with(Main.LineItem_AssignmentEntry/Main.AssignmentEntry/Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName,'E2E ')]\", filter:{amount:500}, callback:function(o){ clearTimeout(t); res((o||[]).map(l=>String(l.getReference('Main.LineItem_AssignmentEntry'))+'~'+String(['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'].reduce((a,d)=>a+(parseFloat(String(l.get(d)))||0),0))+'~'+String(l.get('Name')||'')).join('|')); }, error:function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

# ------------------------------------------------------------------ seed one task
SEED_PROJECT="$TT654_PROJECT_LINEITEMS"
SEED_TASK="E2E Rollup Task"
SEED_DAY=3            # Mon-Fri -> 15 hours on the task, and so on the entry
SEED_TOTAL=15
tt_login "$TT654_CONSULTANT" "My Timesheets"
tt654_find_editable_row "$SEED_PROJECT"
note "seeding '$SEED_TASK' ($SEED_DAY h x 5) on '$SEED_PROJECT', week $TT654_WEEK"
tt654_add_task "$TT654_ORD" "$SEED_TASK" "$SEED_DAY" >/dev/null
tt_assert_no_unnamed_tasks "$TT654_ROWS"
tt654_save_draft

tt_login "e2e_hr" "$TT_HR_READY"
note "session roles: $(tt_authz_roles)"

E="$(entries)"
case "$E" in ERR:*) tt_fail "could not read E2E assignment entries ($E)" ;; esac
[ -n "$E" ] || tt_fail "no E2E assignment entry exists, so nothing could be reconciled. Run the suite in order."

L="$(lineitems)"
case "$L" in ERR:*) tt_fail "could not read line items ($L)" ;; esac
if [ -z "$L" ]; then
  tt_fail "no line item exists for any E2E consultant, although this step has just added '$SEED_TASK' on '$SEED_PROJECT' and saved the draft - the task did not persist, so there is nothing to reconcile."
fi

# The entry the seeded task belongs to (a task name is unique to this step).
SEED_GUID="$(printf '%s' "$L" | tr '|' '
' | awk -F'~' -v n="$SEED_TASK" '$3==n { print $1; exit }')"
[ -n "$SEED_GUID" ] || tt_fail "the seeded task '$SEED_TASK' is not among the E2E line items read back, so its save did not persist"

# Sum hours per entry guid, and collect nameless ones.
SUMS="$(printf '%s' "$L" | tr '|' '\n' | awk -F'~' 'NF>=2 { s[$1] += $2 } END { for (g in s) printf "%s %s\n", g, s[g] }')"
NAMELESS="$(printf '%s' "$L" | tr '|' '\n' | awk -F'~' 'NF>=3 && ($3=="" || $3=="null") { print $1 }' | sort -u)"

# ---------------------------------------------------------------------- B. named tasks
if [ -n "$NAMELESS" ]; then
  n="$(printf '%s\n' "$NAMELESS" | grep -c .)"
  bad "B: $n entry(ies) carry a line item with no Name. tt_assert_no_unnamed_tasks enforces this before a submit; nothing checks it afterwards, and a nameless task on an exported PDF is a line the client cannot account for."
else
  note "B ok: every line item has a name"
fi

# ------------------------------------------------------------------- A. the rollup
checked=0
skipped=0
IFS='|'
for row in $E; do
  unset IFS
  [ -n "$row" ] || { IFS='|'; continue; }
  guid="${row%%~*}"
  total="${row##*~}"

  got="$(printf '%s\n' "$SUMS" | awk -v g="$guid" '$1==g { print $2 }')"
  if [ -z "$got" ]; then
    skipped=$((skipped+1)); IFS='|'; continue
  fi
  checked=$((checked+1))

  if awk -v a="$total" -v b="$got" 'BEGIN{ d=(a+0)-(b+0); if(d<0) d=-d; exit (d < 0.001) ? 0 : 1 }'; then
    note "ok   entry $guid: TotalHours=$total matches its line items ($got)"
  else
    bad "A: entry $guid has TotalHours=$total but its line items sum to $got. The entry's number is the one that reaches the week total, the approval queue, the PDF and the invoice; the line items are what the consultant filled in."
  fi
  IFS='|'
done
unset IFS

[ "$skipped" -eq 0 ] || note "note: $skipped entry(ies) have no line items and were skipped"

# ------------------------------------------------------------------- C. did we look?
[ "$checked" -gt 0 ] || bad "C: no entry with line items was reconciled, so this step has no verdict to give"

# ---------------------------------------------------------------- E. the seeded one
# A has already compared this entry's TotalHours with its line items. E proves A
# really looked at the task this run put there, with the hours it was given - so a
# pass cannot come from older entries alone, or from a task whose hours never
# committed (0 = 0 would reconcile perfectly).
SEED_HRS="$(printf '%s' "$L" | tr '|' '
' | awk -F'~' -v n="$SEED_TASK" '$3==n { print $2; exit }')"
SEED_ROW="$(printf '%s' "$E" | tr '|' '
' | awk -F'~' -v g="$SEED_GUID" '$1==g { print $2; exit }')"
if ! awk -v a="$SEED_HRS" -v b="$SEED_TOTAL" 'BEGIN{ d=(a+0)-(b+0); if(d<0) d=-d; exit (d < 0.001) ? 0 : 1 }'; then
  bad "E: the seeded task '$SEED_TASK' reads $SEED_HRS hour(s), not the $SEED_TOTAL entered - its day cells did not commit"
elif [ -z "$SEED_ROW" ]; then
  bad "E: the seeded task's entry ($SEED_GUID) was not among the E2E entries read, so A never reconciled it"
else
  note "E ok: the seeded task carries $SEED_TOTAL hours and its entry (TotalHours=$SEED_ROW) was reconciled above"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-lineitem-rollup-invariant — $fails problem(s) across $checked entry(ies) with line items."
  exit 1
fi
echo "PASS: verify-lineitem-rollup-invariant — $checked entry(ies) add up exactly to their line items, all of them named."
