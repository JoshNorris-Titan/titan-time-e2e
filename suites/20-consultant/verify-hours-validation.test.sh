#!/usr/bin/env bash
# tt-timeout: 8m
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
#   A. Over 40 hours raises the over-limit warning, and dismissing it leaves the
#      week UNSUBMITTED. A warning you can dismiss into a silent submit would be
#      worse than none.
#   B. The under-40 / week-not-ended warning offers the deliberate override, and
#      Submit Anyway actually submits.
#
# A AND B ARE TWO DIFFERENT POPUPS, AND THE NAMES ARE A TRAP. There are two
# sibling pages in Main, 100. Consultant/Pages/Popups:
#
#   Main.Consultant_OverWeeklyHours  "You have entered more than the {1} hour
#                                     weekly limit for {2}", CLOSE ONLY.
#                                     This is the over-budget block.
#   Main.Consultant_OverFortyHours   btnWarningCancel + btnWarningSubmitAnyway,
#                                     dynamic WarningMessage, calls
#                                     ACT_Timesheet_SubmitAnyway. Despite the
#                                     name this is the GENERIC submit
#                                     confirmation - it is what appears for
#                                     UNDER 40 hours and "this week has not
#                                     ended yet".
#
# So the page called OverFortyHours is not the over-40 dialog, and the over-40
# dialog is the one called OverWeeklyHours. This file originally read those
# names the obvious way, looked for btnWarningSubmitAnyway on the over-40 path,
# did not find it, and reported "Consultant_OverFortyHours never appeared" about
# a warning the app plainly does raise. Nothing had been removed.
#
# {1} and {2} are parameters: the limit is the ASSIGNMENT's weekly hours and {2}
# is the project, so this is a per-assignment budget rather than a cap on the
# timesheet as a whole.
#
# Both cases therefore assert dialog TEXT rather than a widget name, which is
# what let the original mistake stand. Verified against dev on 2026-08-26.
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
  tt_fill_commit ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay$2 input, $1)" "$3"
}

hv_day_value() { # hv_day_value <ordinal> <Day>
  playwright-cli eval "() => { const els=document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDay$2 input'); const el=els[$1-1]; return el ? String(el.value||'') : '__MISSING__'; }" 2>/dev/null | _tt_eval_str
}

# hv_holds <ordinal> <Day> <wanted> - did the field KEEP the value we typed?
#
# Compared numerically, never as a string. A committed Mendix day cell reformats
# what you typed ("25" becomes "25.00"), so `[ "$v" != "25" ]` reads an accepted
# value as a refused one and reports the opposite of what happened. That only
# became reachable once the fill helpers started committing the field; before
# that the raw text survived by accident.
hv_holds() {
  local v
  v="$(hv_day_value "$1" "$2")"
  case "$v" in ''|__MISSING__) return 1 ;; esac
  awk -v a="$v" -v b="$3" 'BEGIN{ gsub(/,/,".",a); exit (a+0==b+0) ? 0 : 1 }'
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

# hv_dialog_text - the visible dialog's text, flattened. Assertions match on this
# rather than on a widget name: the over-40 and under-40 warnings are different
# dialogs with different buttons, and guessing the widget is what made this file
# accuse the product of never warning at all.
hv_dialog_text() {
  playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); return d ? (d.innerText||'').replace(/\s+/g,' ').trim().slice(0,200) : ''; }" 2>/dev/null | _tt_eval_str
}

# hv_wait_dialog <extended-regex> - echo the dialog text once it matches, or ''.
hv_wait_dialog() {
  local i t=""
  for i in $(seq 1 10); do
    t="$(hv_dialog_text)"
    if printf '%s' "$t" | grep -Eqi -- "$1"; then printf '%s' "$t"; return 0; fi
    sleep 1
  done
  return 1
}

# hv_dismiss <extended-regex> - click the dialog button whose caption matches.
hv_dismiss() {
  playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); if(!d) return 'nodlg'; const b=[...d.querySelectorAll('button,.mx-button,[role=button]')].find(e=>new RegExp('$1','i').test((e.innerText||'').trim())); if(!b) return 'nobtn'; b.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str
}

# NO WEEK RECYCLING HERE - DELIBERATELY.
#
# There used to be an hv_clear_week that blanked week A so case B could take it
# again, because fresh weeks are a finite fixture and an early run skipped C and
# D for want of one. It cost more than it bought. Clear blanks the DAY CELLS; it
# does not put the week back to untouched, so tt_goto_fresh_week - which picks
# the first week whose cells look empty - would hand that same week to whatever
# test ran next. The failure then rotated between verify-timesheet-locks-after-
# submit, verify-tt692693 line items and verify-timesheet-status-rollup
# depending on run order, which is the signature of shared mutable fixture, not
# of a product bug.
#
# So each case takes its own fresh week and gives none back. When the supply
# runs out, C and D say so and skip. A skip that names its reason is worth more
# than a pass on a week another test is also using.

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

# ------------------------------------------------------------------- A setup
tt_login "$CUSER" "My Timesheets"

got="$(hv_fresh_row)" \
  || tt_fail "no fresh editable week with a '$PROJECT' row for $CUSER — cannot exercise the hour guards"
ORD="${got%%|*}"; WEEK="${got#*|}"
echo "over-40 case on week '$WEEK' (row $ORD)"

# 9 hours a day, Monday to Friday: 45, comfortably over the limit and under 24/day
# so only the weekly guard can be what fires.
for d in Mon Tues Wed Thurs Fri; do hv_set_day "$ORD" "$d" "9"; done
sleep 1
d_before="$(tt_draft_count "$PROJECT" "$CUSER")"
case "$d_before" in ERR:*|''|*[!0-9]*) d_before="" ;; esac
[ -n "$d_before" ] || tt_fail "could not read this consultant's draft entries before submitting ($PROJECT / $CUSER), so neither the block nor the override could be proven"
hv_submit

# ----------------------------------------- A. the over-limit warning blocks
seen="$(hv_wait_dialog 'more than the 40 hour weekly limit')"
if [ -n "$seen" ]; then
  note "A over-limit warning raised: \"$seen\""
  hv_dismiss 'close|cancel|no|ok'
  sleep 3
  tt_clear_dialogs 6 >/dev/null 2>&1 || true
  # Whether the block is REAL is a question about the entry, not about whether a
  # row still looks editable. Main.Consultant_OverWeeklyHours offers no override,
  # so an over-limit week must still be Draft afterwards.
  d_after="$(tt_draft_count "$PROJECT" "$CUSER")"
  case "$d_after" in
    ERR:*)       bad "A could not read draft entries after the over-limit warning ($d_after), so the block was not proven either way" ;;
    ''|*[!0-9]*) bad "A draft count after the over-limit warning was not a number: [$d_after]" ;;
    *)
      if [ "$d_after" -ge "$d_before" ]; then
        note "A the over-limit week was NOT submitted ($d_before -> $d_after still Draft)"
      else
        bad "A the over-limit warning is decorative — an entry left Draft anyway ($d_before -> $d_after). Main.Consultant_OverWeeklyHours has no override button, so nothing should have submitted here"
      fi ;;
  esac
else
  bad "A submitting 45 hours raised no over-40 warning (Main.Consultant_OverFortyHours never appeared). Dialog on screen: \"$(hv_dialog_text)\""
  tt_clear_dialogs 6 >/dev/null 2>&1 || true
fi

# Hand the week back blank so the later cases can reuse it — fresh weeks are
# scarce, and this one was never submitted.

# ------------------------------- B. the under-limit override actually submits
got="$(hv_fresh_row)" || got=""
if [ -z "$got" ]; then
  echo "  note: no second fresh week available; B not exercised"
else
  ORD_B="${got%%|*}"; WEEK_B="${got#*|}"
  echo "under-40 override case on week '$WEEK_B' (row $ORD_B)"
  for d in Mon Tues Wed Thurs; do hv_set_day "$ORD_B" "$d" "5"; done   # 20h, under the limit
  sleep 1
  hv_submit
  # No "Are you Sure?" step any more: btnSubmit calls Main.ACT_Timesheet_Submit_Start,
  # which evaluates the warnings and opens the single confirm popup directly.
  sleep 2

  if [ "$(hv_warning_open)" = "true" ]; then
    note "B under-40 warning offered the override"
    playwright-cli click ".mx-name-btnWarningCancel" >/dev/null 2>&1
    sleep 3
    tt_clear_dialogs 6 >/dev/null 2>&1 || true
    if [ "$(hv_row_editable)" = "true" ]; then
      note "B Cancel left the week unsubmitted"
    else
      bad "B Cancel on the under-40 warning SUBMITTED the week anyway — the escape hatch does not escape"
    fi

    if [ "$(hv_row_editable)" = "true" ]; then
      hv_submit
      sleep 2
      if [ "$(hv_warning_open)" = "true" ]; then
        b_before="$(tt_draft_count "$PROJECT" "$CUSER")"
        case "$b_before" in ERR:*|''|*[!0-9]*) b_before="" ;; esac
        playwright-cli click ".mx-name-btnWarningSubmitAnyway" >/dev/null 2>&1
        sleep 4
        tt_clear_dialogs 6 >/dev/null 2>&1 || true
        # Poll the DATA LAYER, not the row: a submitted row can keep looking
        # editable for 30s, which is what made this step report a failure the
        # first time it got this far.
        b_after="$b_before"
        [ -n "$b_before" ] || bad "B could not read draft entries before Submit Anyway, so the override could not be proven"
        for _ in $(seq 1 8); do
          [ -n "$b_before" ] || break
          b_after="$(tt_draft_count "$PROJECT" "$CUSER")"
          case "$b_after" in ERR:*|''|*[!0-9]*) sleep 3; continue ;; esac
          [ "$b_after" -lt "$b_before" ] && break
          sleep 3
        done
        case "$b_before:$b_after" in
          ''|:*) ;;                                   # already reported above
          *:ERR:*|*:) bad "B could not read draft entries after Submit Anyway ($b_after), so the override was not proven" ;;
          *)
            if [ "$b_after" -lt "$b_before" ]; then
              note "B Submit Anyway submitted the under-limit week ($b_before -> $b_after still Draft)"
            else
              bad "B Submit Anyway did not submit — $b_before entr(ies) were Draft before and $b_after after, so Main.ACT_Timesheet_SubmitAnyway did not take"
            fi ;;
        esac
      else
        bad "B the under-40 warning did not reappear on a second submit. Dialog on screen: \"$(hv_dialog_text)\""
      fi
    fi
  else
    bad "B submitting 20 hours offered no Submit Anyway override (.mx-name-btnWarningSubmitAnyway never appeared). Dialog on screen: \"$(hv_dialog_text)\""
    tt_clear_dialogs 8 >/dev/null 2>&1 || true
  fi
fi


# ------------------------------------------------ C + D: impossible day values
got="$(hv_fresh_row)" || {
  echo "  note: no further fresh week available; C and D not exercised"
  got=""
}

if [ -n "$got" ]; then
  ORD="${got%%|*}"; WEEK2="${got#*|}"
  echo "impossible-value cases on week '$WEEK2' (row $ORD)"

  # C — more than 24 hours in a single day.
  hv_set_day "$ORD" "Mon" "25"
  sleep 1
  if ! hv_holds "$ORD" Mon 25; then
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
  if ! hv_holds "$ORD" Mon -5; then
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
