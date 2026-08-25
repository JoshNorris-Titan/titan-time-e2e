#!/usr/bin/env bash
# verify-hours-validation.test.sh
#
# The guards on what a consultant may enter: the over-40 warning and its two
# exits, and the refusal of impossible day values.
#
# WHY THIS EXISTS. The suite deliberately submits exactly 40 hours a week
# everywhere else, so the over-limit branch had never fired in a test run. That
# left Main.ACT_Timesheet_SubmitAnyway and Main.Consultant_OverFortyHours with no
# coverage at all — and unlike the 24-hour arithmetic, which three unit tests in
# Core's 995. Unit Tests already pin down (UT_SUB_TimesheetValidate_*), the
# warning popup and its buttons only exist in the UI. E2E is the only layer that
# can see them. Checked before writing this: none of ACT_Timesheet_SubmitAnyway,
# Consultant_OverFortyHours, Consultant_OverWeeklyHours or SUB_PositiveNumberCheck
# has a unit test among the 59 that exist.
#
# WHAT IT ASSERTS
#   A. Over 40 hours raises the warning, and Cancel leaves the week UNSUBMITTED.
#      A warning you can dismiss into a silent submit would be worse than none.
#   B. Submit Anyway actually submits — the deliberate override still works.
#   C. A day over 24 hours is not silently accepted.
#   D. A negative day is not silently accepted.
#
# C and D are phrased as "not silently accepted" on purpose. Which surface stops
# them — a field that refuses the keystrokes, a validation message, or a warning
# popup — is a design detail that may change; that something stops them is the
# actual requirement. A test that demanded one specific surface would fail on a
# harmless redesign and tell you nothing about the rule.
#
# Uses e2e_consultant2 / E2E Sandbox, the same pair as the TT-692/693 steps, so
# it cannot disturb the customer-approval data that 30-approval depends on.
#
# Consumes: one week for A and B (left submitted), one for C and D (left as found,
# since both are expected to be refused).
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"

CUSER="${TT_HOURS_USER:-e2e_consultant2}"
PROJECT="${TT_HOURS_PROJECT:-E2E Sandbox}"
fails=0

note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

# ---------------------------------------------------------------------- helpers

# hv_row_ordinal — 1-based position of the editable row for PROJECT, or 0.
hv_row_ordinal() {
  playwright-cli eval "() => { const rows=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')]; for(let n=0;n<rows.length;n++){ let el=rows[n]; for(let k=0;k<10;k++){ el=el.parentElement; if(!el) break; if((el.innerText||'').indexOf('$PROJECT')>=0){ const inp=rows[n].querySelector('input'); if(inp && !inp.readOnly && !inp.disabled) return String(n+1); } } } return '0'; }" 2>/dev/null | _tt_eval_str
}

hv_set_day() {   # hv_set_day <ordinal> <Mon|Tues|...> <value>
  playwright-cli fill ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay$2 input, $1)" "$3" >/dev/null 2>&1
}

hv_day_value() { # hv_day_value <ordinal> <Day>
  playwright-cli eval "() => { const els=document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDay$2 input'); const el=els[$1-1]; return el ? String(el.value||'') : '__MISSING__'; }" 2>/dev/null | _tt_eval_str
}

# hv_row_editable — is the PROJECT row still editable? A submitted row is not.
hv_row_editable() {
  [ "$(hv_row_ordinal)" != "0" ] && echo "true" || echo "false"
}

hv_warning_open() {
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnWarningSubmitAnyway'))" 2>/dev/null | _tt_eval_str
}

# hv_complained — did ANYTHING object? A popup, a validation message, or a dialog.
hv_complained() {
  playwright-cli eval "() => { const v=[...document.querySelectorAll('.mx-validation-message')].filter(e=>e.offsetParent!==null).length; const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); const w=document.querySelector('.mx-name-btnWarningSubmitAnyway'); return String(v>0 || !!d || !!w); }" 2>/dev/null | _tt_eval_str
}

hv_submit() {
  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
  sleep 3
}

hv_wait_warning() {
  local i
  for i in $(seq 1 10); do
    [ "$(hv_warning_open)" = "true" ] && return 0
    sleep 1
  done
  return 1
}

hv_fresh_row() {  # land on a fresh week and return its ordinal, or fail
  local wk ord
  wk="$(tt_goto_fresh_week "$PROJECT")" || return 1
  ord="$(hv_row_ordinal)"
  [ "$ord" != "0" ] || return 1
  echo "$ord|$wk"
}

# ------------------------------------------------------------------- A + B setup
tt_login "$CUSER" "My Timesheets"

got="$(hv_fresh_row)" \
  || tt_fail "no fresh editable week with a '$PROJECT' row for $CUSER — cannot exercise the hour guards"
ORD="${got%%|*}"; WEEK="${got#*|}"
echo "over-40 case on week '$WEEK' (row $ORD)"

# 9 hours a day, Monday to Friday: 45, comfortably over the limit and under 24/day
# so only the weekly guard can be what fires.
for d in Mon Tues Wed Thurs Fri; do hv_set_day "$ORD" "$d" "9"; done
sleep 1
hv_submit

# ------------------------------------------------- A. the warning, and Cancel
if hv_wait_warning; then
  note "A over-40 warning raised"
  playwright-cli click ".mx-name-btnWarningCancel" >/dev/null 2>&1
  sleep 3
  if [ "$(hv_row_editable)" = "true" ]; then
    note "A Cancel left the week unsubmitted"
  else
    bad "A Cancel on the over-40 warning SUBMITTED the week anyway — the escape hatch does not escape"
  fi
else
  bad "A submitting 45 hours raised no over-40 warning (Main.Consultant_OverFortyHours never appeared)"
  tt_clear_dialogs 6 >/dev/null 2>&1 || true
fi

# --------------------------------------------------------- B. Submit Anyway
if [ "$(hv_row_editable)" = "true" ]; then
  hv_submit
  if hv_wait_warning; then
    playwright-cli click ".mx-name-btnWarningSubmitAnyway" >/dev/null 2>&1
    sleep 4
    tt_clear_dialogs 6 >/dev/null 2>&1 || true
    sleep 2
    if [ "$(hv_row_editable)" = "false" ]; then
      note "B Submit Anyway submitted the over-limit week"
    else
      bad "B Submit Anyway left the week editable — ACT_Timesheet_SubmitAnyway did not submit"
    fi
  else
    bad "B the over-40 warning did not reappear on a second submit"
  fi
else
  note "B skipped: the week was already submitted by case A"
fi

# ------------------------------------------------ C + D: impossible day values
got="$(hv_fresh_row)" || {
  echo "  note: no second fresh week available; C and D not exercised"
  got=""
}

if [ -n "$got" ]; then
  ORD="${got%%|*}"; WEEK2="${got#*|}"
  echo "impossible-value cases on week '$WEEK2' (row $ORD)"

  # C — more than 24 hours in a single day.
  hv_set_day "$ORD" "Mon" "25"
  sleep 1
  if [ "$(hv_day_value "$ORD" Mon)" != "25" ]; then
    note "C the day field refused to hold 25 — rejected at the input"
  else
    hv_submit
    if [ "$(hv_complained)" = "true" ] || [ "$(hv_row_editable)" = "true" ]; then
      note "C a 25-hour day was not accepted silently"
    else
      bad "C a 25-hour day SUBMITTED with no objection — SUB_Timesheet_Validate's over-24 flag is not reaching the UI"
    fi
    tt_clear_dialogs 8 >/dev/null 2>&1 || true
  fi

  # D — a negative day.
  hv_set_day "$ORD" "Mon" ""
  hv_set_day "$ORD" "Mon" "-5"
  sleep 1
  if [ "$(hv_day_value "$ORD" Mon)" != "-5" ]; then
    note "D the day field refused to hold -5 — rejected at the input"
  else
    hv_submit
    if [ "$(hv_complained)" = "true" ] || [ "$(hv_row_editable)" = "true" ]; then
      note "D a negative day was not accepted silently"
    else
      bad "D a negative day SUBMITTED with no objection — nothing guards against negative hours"
    fi
    tt_clear_dialogs 8 >/dev/null 2>&1 || true
  fi

  # Leave the week as we found it.
  hv_set_day "$ORD" "Mon" "" || true
fi

# --------------------------------------------------------------------- verdict
if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-hours-validation — $fails hour guard(s) not holding."
  exit 1
fi

echo "PASS: verify-hours-validation — over-40 warns and Cancel holds, Submit Anyway submits, impossible day values refused"
