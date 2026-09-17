#!/usr/bin/env bash
# Assignment.TotalHoursWorked equals the hours on that assignment's Exported
# entries — no more, no less.
#
# tt-timeout: 8m
#
# WHY THIS INVARIANT IS THE RIGHT ONE TO ASSERT. TotalHoursWorked is maintained by
# addition and subtraction from two directions: Main.SUB_ExportAll adds through
# WFS_Approval_UpdateHours ($OldHours + $NewHours) when an entry is exported, and
# Main.ACT_RejectAfterExport subtracts when one is pulled back. A running total
# kept that way drifts for any of three reasons - an add that ran twice, a
# subtract that did not run, or an entry whose hours changed after export - and
# none of them announces itself.
#
# The model already agrees this is the invariant: Main.SCE_Assignment_VerifyHours
# is a scheduled repair job that RECOMPUTES TotalHoursWorked from the Exported
# entries every month. This asserts the same equality the repair job enforces, but
# on every run instead of monthly, and it says so rather than silently correcting
# it. verify-scheduled-event-config only pins WHEN that job runs, never that its
# subject holds.
#
# WHAT THE EXISTING TESTS COVER, AND WHAT THEY DO NOT.
# verify-hr-reject-after-export asserts the SUBTRACT side for one entry. Nothing
# asserts the add side, and nothing asserts that exporting the same batch twice
# does not add twice - which is what Main.SUB_ExportAll's "GUARD ORDER IS
# LOAD-BEARING - DO NOT REORDER (TT-736)" comment exists to prevent. A regression
# there inflates every assignment's total permanently and invisibly, because no
# screen shows the two numbers side by side.
#
# WHAT IT ASSERTS, per E2E assignment that has at least one Exported entry:
#   TotalHoursWorked == sum(TotalHours of its Exported entries)
#
# Assignments with no Exported entries are reported and skipped - they have
# nothing to reconcile, and failing on them would make this test depend on run
# order. If NO assignment has any, the test says it had no verdict rather than
# passing on an empty sweep.
#
# Reads only. Drives no form and changes nothing.
#
# Consumes: nothing.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

# One round trip each, then reconciled in shell, so a slow environment cannot turn
# this into dozens of sequential retrieves.
assignments() {
  playwright-cli eval "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),20000); mx.data.get({ xpath: \"//Main.Assignment[starts-with(ConsultantName,'E2E ')]\", filter:{amount:200}, callback:function(o){ clearTimeout(t); res((o||[]).map(a=>a.getGuid()+'~'+String(a.get('ConsultantName'))+'~'+String(a.get('TotalHoursWorked'))).join('|')); }, error:function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}
exported_entries() {
  playwright-cli eval "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),20000); mx.data.get({ xpath: \"//Main.AssignmentEntry[starts-with(Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName,'E2E ')][Status='Exported']\", filter:{amount:500}, callback:function(o){ clearTimeout(t); res((o||[]).map(e=>String(e.getReference('Main.AssignmentEntry_Assignment'))+'~'+String(e.get('TotalHours'))).join('|')); }, error:function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

tt_login "e2e_hr" "WEEKLY TO PROCESS"
note "session roles: $(tt_authz_roles)"

A="$(assignments)"
case "$A" in ERR:*) tt_fail "could not read E2E assignments ($A)" ;; esac
[ -n "$A" ] || tt_fail "no E2E assignments exist, so there is nothing to reconcile. suites/00-setup builds them; run the suite in order."

E="$(exported_entries)"
case "$E" in ERR:*) tt_fail "could not read Exported entries ($E)" ;; esac

# Sum exported hours per assignment guid.
SUMS="$(printf '%s' "$E" | tr '|' '\n' | awk -F'~' 'NF==2 { s[$1] += $2 } END { for (g in s) printf "%s %s\n", g, s[g] }')"

checked=0
skipped=0
IFS='|'
for row in $A; do
  unset IFS
  [ -n "$row" ] || { IFS='|'; continue; }
  guid="${row%%~*}"
  rest="${row#*~}"
  who="${rest%%~*}"
  worked="${rest##*~}"

  got="$(printf '%s\n' "$SUMS" | awk -v g="$guid" '$1==g { print $2 }')"
  if [ -z "$got" ]; then
    skipped=$((skipped+1))
    IFS='|'; continue
  fi

  if awk -v a="$worked" -v b="$got" 'BEGIN{ exit ( (a+0) - (b+0) < 0.001 && (b+0) - (a+0) < 0.001 ) ? 0 : 1 }'; then
    note "ok   $who: TotalHoursWorked=$worked matches its Exported entries ($got)"
    checked=$((checked+1))
  else
    bad "$who (assignment $guid): TotalHoursWorked=$worked but its Exported entries sum to $got. An add that ran twice, a subtract that did not, or hours changed after export - SCE_Assignment_VerifyHours would silently repair this monthly."
    checked=$((checked+1))
  fi
  IFS='|'
done
unset IFS

[ "$skipped" -eq 0 ] || note "note: $skipped assignment(s) have no Exported entries and were skipped - nothing to reconcile"
[ "$checked" -gt 0 ] || bad "no E2E assignment has an Exported entry, so nothing was reconciled and this step has no verdict to give"

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-export-hours-invariant — $fails assignment(s) whose running total disagrees with their exported hours."
  exit 1
fi
echo "PASS: verify-export-hours-invariant — $checked assignment(s) reconcile exactly against their Exported entries."
