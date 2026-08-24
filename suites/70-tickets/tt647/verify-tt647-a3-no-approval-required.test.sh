#!/usr/bin/env bash
# TT-647 angle 3 — an entry that reached ToProcess with NO approval step reads
# "No approval required", not the consultant's own name.
#
# Main.ACT_AssignmentEntry_Submit routes a zero-hour entry straight to ToProcess
# (Status = if TotalHours = 0 then ToProcess ...) and logs it with
# ChangeMethod=Consultant_Solo. Main.SUB_ApprovalHelper_SetApprovalLines finds no
# genuine approval row for that cycle, so line 1 must read "No approval required".
#
# This is the case that would otherwise render "Approved by <the consultant
# themselves>", which is the misleading output Josh explicitly ruled out.
#
# Seeds a zero-hour week for e2e_consultant2 on the sandbox project if the To
# Process tab has no such card yet. Env: TT_BASE_URL, TT_ROLE_PASS.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt647.sh"

CUSER="${TT_A3_USER:-e2e_consultant2}"
CNAME="${TT_A3_NAME:-E2E Consultant Two}"
EXPECT="No approval required"

# Seed: step to an editable week, force every day box to 0, submit.
# Zeroing uses the native value setter (a plain fill does not always commit a
# Mendix decimal box) — same technique as the TT-692/693 zero-hours test.
seed_zero_hour_week() {
  local i
  tt_login "$CUSER" "My Timesheets"
  for i in $(seq 1 10); do
    if playwright-cli eval "() => { const dm=document.querySelector('.mx-name-txtDayMon input'); return String(!!dm && !dm.disabled && !dm.readOnly && !!document.querySelector('.mx-name-btnSubmit')); }" 2>/dev/null | grep -qiw true; then
      break
    fi
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnSubmit'))" 2>/dev/null | grep -qiw true \
    || tt_fail "$CUSER: no editable week with a Submit button found to seed a zero-hour entry"

  playwright-cli eval "() => { const ins=[...document.querySelectorAll('.mx-name-galAssignmentRows input')].filter(i=>i.offsetParent!==null && !i.readOnly && !i.disabled); const set=(t,v)=>{ t.focus(); Object.getOwnPropertyDescriptor(t.__proto__,'value').set.call(t,v); t.dispatchEvent(new Event('input',{bubbles:true})); t.dispatchEvent(new Event('change',{bubbles:true})); }; ins.forEach(i=>set(i,'0')); return String(ins.length); }" >/dev/null 2>&1
  sleep 2
  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
  sleep 2
  # Confirmation chain: "Are you Sure? yes", then "Submit Anyway" for the <40h warning.
  for i in 1 2 3 4 5 6; do
    if playwright-cli eval "() => { const d=document.querySelector('.mx-dialog,.mx-window,[role=dialog],.modal-dialog,[class*=modal]'); if(!d) return 'none'; const b=[...d.querySelectorAll('button')].find(x=>/^(yes|submit anyway|confirm|continue|proceed|ok)$/i.test((x.innerText||'').trim())); if(b){b.click(); return 'clicked';} return 'stuck'; }" 2>/dev/null | grep -qiw none; then
      break
    fi
    sleep 3
  done
  sleep 3
}

# 1) Look for an existing no-approval card, otherwise seed one.
tt647_hr_open_tab "$TT647_TAB_TOPROCESS"
if ! tt647_select_week_with "$CNAME" >/dev/null; then
  echo "no To Process entry for '$CNAME' — seeding a zero-hour week"
  seed_zero_hour_week
  tt647_hr_open_tab "$TT647_TAB_TOPROCESS"
  tt647_select_week_with "$CNAME" >/dev/null \
    || tt_fail "zero-hour entry for '$CNAME' did not reach the To Process tab"
fi

tt647_require_widgets "To Process tab"

LINES="$(tt647_card_lines "$CNAME")"
L1="${LINES%%~~*}"
L2="${LINES#*~~}"
echo "line1: '$L1'"
echo "line2: '$L2'"

[ "$L1" = "$EXPECT" ] \
  || tt_fail "expected line 1 to read '$EXPECT' for an entry with no approval step, got: '$L1'"

# "No approval required" is a whole-line replacement — there is no second line.
[ -z "$L2" ] || tt_fail "line 2 should be empty when no approval was required, got: '$L2'"

# Guard the specific wrong output this scenario exists to prevent.
case "$L1" in
  *"Approved by $CNAME"*) tt_fail "the consultant is being credited as their own approver: '$L1'" ;;
esac

echo "PASS: verify-tt647-a3-no-approval-required — no-approval entry renders '$L1'"
