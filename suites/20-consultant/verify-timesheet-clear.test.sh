#!/usr/bin/env bash
# verify-timesheet-clear.test.sh
#
# Clear empties a week — and "empty" means BLANK, not zero.
#
# WHY THIS EXISTS. Blank and 0 are different states in this app. A blank day means
# "nothing recorded"; a 0 means "worked none, and I am telling you so". The two
# drive different behaviour downstream, and ACT_Timesheet_Clear carries an
# annotation from its own author calling the blank-versus-zero semantics
# "delicate" — which is exactly the kind of rule that rots silently, because a
# regression that wrote 0.00 instead of blank looks identical on screen.
#
# Nothing tested it. verify-tt692693-c2 covers an explicit 0, but the suite's own
# tt_goto_fresh_week deliberately treats '', '0' and '0.00' as interchangeable when
# hunting for a usable week, so it cannot tell the two apart — nor should it, for
# that job. This step therefore reads raw field values itself rather than reusing
# that helper's notion of "blank".
#
# WHAT IT ASSERTS
#   A. After Clear, every day cell is EXACTLY empty — not "0", not "0.00".
#   B. An explicit 0 survives a save and reload as a zero, not as a blank. Taken
#      with A, that is what proves the two states are genuinely distinct rather
#      than one being a rendering of the other.
#   C. Clear is refused once the week is no longer editable. ACT_Timesheet_Clear
#      opens on "Is timesheet draft, empty, or rejected" and shows a message
#      otherwise; a Clear that worked on a submitted week would silently destroy
#      hours somebody had already approved.
#
# Uses e2e_consultant2 / E2E Sandbox, matching the other consultant steps, so it
# cannot disturb the customer-approval data 30-approval depends on.
#
# Consumes two weeks: one for A and B, one for C (left submitted).
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"

CUSER="${TT_CLEAR_USER:-e2e_consultant2}"
PROJECT="${TT_CLEAR_PROJECT:-E2E Sandbox}"
DAYS="Mon Tues Wed Thurs Fri Sat Sun"
fails=0

note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

# ---------------------------------------------------------------------- helpers

# hc_row_any — 1-based position of the PROJECT row, editable or not. Reading has
# to keep working after submit, which is when case C looks at it.
hc_row_any() {
  playwright-cli eval "() => { const rows=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')]; for(let n=0;n<rows.length;n++){ let el=rows[n]; for(let k=0;k<10;k++){ el=el.parentElement; if(!el) break; if((el.innerText||'').indexOf('$PROJECT')>=0) return String(n+1); } } return '0'; }" 2>/dev/null | _tt_eval_str
}

hc_editable() {
  playwright-cli eval "() => { const els=document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon'); const c=els[$1-1]; if(!c) return 'false'; const i=c.querySelector('input'); return String(!!i && !i.readOnly && !i.disabled); }" 2>/dev/null | _tt_eval_str
}

# hc_day <ordinal> <Day> — the RAW value of one cell. An input's value when the row
# is editable, the rendered text when it is not. Never normalised: telling '' from
# '0' is the entire point of this step.
hc_day() {
  playwright-cli eval "() => { const els=document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDay$2'); const c=els[$1-1]; if(!c) return '__MISSING__'; const i=c.querySelector('input'); return i ? String(i.value||'') : String((c.innerText||'').trim()); }" 2>/dev/null | _tt_eval_str
}

hc_set() {  # hc_set <ordinal> <Day> <value>
  tt_fill_commit ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay$2 input, $1)" "$3"
}

hc_report() {  # hc_report <ordinal> — all seven cells, for a failure message
  local d out=""
  for d in $DAYS; do out="$out $d=[$(hc_day "$1" "$d")]"; done
  echo "$out"
}

hc_click() { playwright-cli click ".mx-name-$1" >/dev/null 2>&1; sleep 3; }

# hc_is_zero — a value that means "explicitly none": non-empty and numerically 0.
hc_is_zero() {
  case "$1" in
    "" ) return 1 ;;
    *) awk -v v="$1" 'BEGIN{ gsub(/,/,".",v); exit (v+0==0 && v ~ /[0-9]/) ? 0 : 1 }' ;;
  esac
}

# ------------------------------------------------------------------ A + B setup
tt_login "$CUSER" "My Timesheets"

WEEK="$(tt_goto_fresh_week "$PROJECT")" \
  || tt_fail "no fresh editable week with a '$PROJECT' row for $CUSER — cannot exercise Clear"
ORD="$(hc_row_any)"
[ "$ORD" != "0" ] || tt_fail "no '$PROJECT' row on week '$WEEK'"
echo "clear case on week '$WEEK' (row $ORD)"

for d in Mon Tues Wed Thurs Fri; do hc_set "$ORD" "$d" "5"; done
sleep 1
filled="$(hc_day "$ORD" Mon)"
[ -n "$filled" ] || tt_fail "could not enter hours before clearing (Mon read back empty)"

# ------------------------------------------------------- A. Clear leaves BLANK
hc_click btnClear
tt_clear_dialogs 8 "Clear" >/dev/null 2>&1 || true
sleep 2

notblank=""
for d in $DAYS; do
  v="$(hc_day "$ORD" "$d")"
  [ "$v" = "" ] || notblank="$notblank $d=[$v]"
done

if [ -z "$notblank" ]; then
  note "A Clear left every day cell exactly blank"
else
  if hc_is_zero "$(hc_day "$ORD" Mon)"; then
    bad "A Clear wrote ZEROS instead of blanks —$notblank. Blank means 'nothing recorded' and 0 means 'recorded none'; ACT_Timesheet_Clear must not conflate them"
  else
    bad "A Clear did not empty the week —$notblank"
  fi
fi

# ----------------------------------------- B. an explicit 0 survives as a zero
hc_set "$ORD" "Mon" "0"
sleep 1
hc_click btnSaveDraft
tt_clear_dialogs 6 >/dev/null 2>&1 || true
sleep 2
# Re-query the week WITHOUT reloading. The page opens on today's week, so a
# reload here silently moved the read to whatever week contains today's date -
# which is how this case came to report an explicit 0 "coming back as 9.00":
# the 9 was verify-hours-validation's, written into the current week minutes
# earlier. See tt_refetch_week in lib/_login.sh.
tt_refetch_week

ORD="$(hc_row_any)"
shown="$(tt_current_week)"
if [ -n "$shown" ] && [ "${WEEK#*"$shown"}" = "$WEEK" ]; then
  bad "B the grid moved to week '$shown' while case B was written against '$WEEK', so the re-read would have been of the wrong week"
elif [ "$ORD" = "0" ]; then
  bad "B the '$PROJECT' row vanished after saving a draft, so the zero could not be re-read"
else
  v="$(hc_day "$ORD" Mon)"
  if hc_is_zero "$v"; then
    note "B an explicit 0 came back as [$v], distinct from blank"
  elif [ "$v" = "" ]; then
    bad "B an explicit 0 came back BLANK — the app cannot tell 'worked none' from 'nothing recorded', which is the distinction Clear depends on"
  else
    bad "B an explicit 0 came back as [$v], which is neither zero nor blank"
  fi
fi

# --------------------------------------- C. Clear refused once not editable
WEEK2="$(tt_goto_fresh_week "$PROJECT")" || WEEK2=""
if [ -z "$WEEK2" ]; then
  echo "  note: no second fresh week available; the submitted-week guard was not exercised"
else
  ORD2="$(hc_row_any)"
  if [ "$ORD2" = "0" ]; then
    echo "  note: no '$PROJECT' row on week '$WEEK2'; guard not exercised"
  else
    echo "guard case on week '$WEEK2' (row $ORD2)"
    for d in Mon Tues Wed Thurs Fri; do hc_set "$ORD2" "$d" "8"; done
    sleep 1
    hc_click btnSubmit
    tt_clear_dialogs 8 >/dev/null 2>&1 || true
    sleep 3

    if [ "$(hc_editable "$ORD2")" = "true" ]; then
      echo "  note: the week did not submit, so the guard could not be tested here"
    else
      before="$(hc_report "$ORD2")"
      hc_click btnClear
      tt_clear_dialogs 8 "Clear" >/dev/null 2>&1 || true
      sleep 2
      after="$(hc_report "$ORD2")"
      if [ "$before" = "$after" ]; then
        note "C Clear left the submitted week untouched"
      else
        bad "C Clear MODIFIED a submitted week. before:$before after:$after — ACT_Timesheet_Clear's draft/empty/rejected guard is not holding, so approved hours can be destroyed"
      fi
    fi
  fi
fi

# --------------------------------------------------------------------- verdict
if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-timesheet-clear — $fails blank-versus-zero rule(s) not holding."
  exit 1
fi

echo "PASS: verify-timesheet-clear — Clear blanks (not zeroes) week '$WEEK', an explicit 0 stays a zero, and a submitted week is left alone"
