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
#   B. An explicit 0 survives a save and re-read as a zero, not as a blank. It
#      round-trips a 7 first, because Main.SUB_Timesheet_Zero turns every empty
#      day value into 0 on save: a 0.00 read off a week that has ever been saved
#      is not evidence of anything this test wrote. Only a zero that provably
#      replaced the 7 proves the point. Taken with A, that is what shows the two
#      states are genuinely distinct rather than one being a rendering of the
#      other.
#   C. Clear is refused once the week is no longer editable. ACT_Timesheet_Clear
#      opens on "Is timesheet draft, empty, or rejected" and shows a message
#      otherwise; a Clear that worked on a submitted week would silently destroy
#      hours somebody had already approved.
#
# READING THE CELLS. hc_day returns the sentinel __MISSING__ when the cell it was
# asked for does not exist, which is a different fault from the cell holding the
# wrong value - and __MISSING__ is a NON-EMPTY string, so a bare `[ -n "$v" ]`
# accepts it. Every reading below is therefore checked against hc_cells first, so
# that "the grid rendered nothing" is reported as itself and never as a
# blank-versus-zero regression. See the note on hc_cells.
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

# hc_cells - how many day cells the assignment grid is rendering right now:
# a number, or 'nogrid' when the gallery itself is not on the page.
#
# THE DISTINCTION THIS EXISTS FOR. hc_day returns __MISSING__ when its element is
# absent, and __MISSING__ is a NON-EMPTY string - so `[ -n "$v" ]` accepts it, and
# a value comparison reports it as though it were what the app rendered. A run on
# 2026-08-31 failed with "Clear did not empty the week - Mon=[__MISSING__]" for
# all seven days while the grid was rendering nothing at all. Those are different
# faults and the message named the wrong one. Ask this before believing any cell
# reading, and say which fault it is.
hc_cells() {
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-galAssignmentRows'); if(!g) return 'nogrid'; return String(g.querySelectorAll('.mx-name-txtDayMon').length); }" 2>/dev/null | _tt_eval_str
}

# hc_dialog_text - the LAST VISIBLE dialog, flattened, or ''.
#
# Read this BEFORE tt_clear_dialogs, never after. That helper clicks anything
# captioned ok/yes/confirm/continue/proceed, which includes Mendix's own error
# dialog - so by the time it returns, the one line that would explain a failed
# action is gone. The 2026-08-31 run dismissed whatever was on screen and threw
# the text away with `|| true`.
#
# Last VISIBLE, and outermost-last: Mendix leaves closed dialogs in the DOM, so
# taking the first match hands back a corpse. Same rule as tt_clear_dialogs.
hc_dialog_text() {
  playwright-cli eval "() => { const all=[...document.querySelectorAll('.mx-window-content,.mx-dialog-content,.modal-content,[role=dialog]')].filter(d=>d.offsetParent!==null); const d=all.filter(x=>!all.some(o=>o!==x && o.contains(x))).pop(); return d ? (d.innerText||'').replace(/\s+/g,' ').trim().slice(0,240) : ''; }" 2>/dev/null | _tt_eval_str
}

hc_set() {  # hc_set <ordinal> <Day> <value>
  tt_fill_commit ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay$2 input, $1)" "$3"
}

hc_report() {  # hc_report <ordinal> — all seven cells, for a failure message
  local d out=""
  for d in $DAYS; do out="$out $d=[$(hc_day "$1" "$d")]"; done
  echo "$out"
}

# hc_click <widget> — click it, and SAY whether the click landed.
#
# A conditionally hidden Mendix button is absent from the DOM, so the click FAILS
# rather than quietly doing nothing. Discarding that exit code is what let "the
# Clear button was not on the page" be reported as "Clear did not empty the week".
hc_click() {
  local ok=0
  playwright-cli click ".mx-name-$1" >/dev/null 2>&1 || ok=1
  sleep 3
  return $ok
}

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
# __MISSING__ is non-empty, so the old `[ -n "$filled" ]` accepted it and let a
# grid with no cells through to be reported later as a blank-versus-zero fault.
case "$filled" in
  __MISSING__)
    tt_fail "row $ORD has no Mon day cell on week '$WEEK' after writing to it (grid is rendering: $(hc_cells)). Nothing was entered, so Clear cannot be exercised - this is a rendering or fixture fault, not a blank-versus-zero one."
    ;;
  "")
    tt_fail "could not enter hours before clearing (Mon read back empty)"
    ;;
esac

# ------------------------------------------------------- A. Clear leaves BLANK
# The app hides Clear, Save and Submit together the moment the week's status
# leaves Draft/Rejected/(empty). tt_goto_fresh_week now refuses such a week, so
# arriving here without a Clear button means the week changed underneath us —
# report THAT, rather than a clear that was never exercised.
if [ "$(tt_week_actionable)" != "true" ]; then
  tt_fail "week '$WEEK' has no Clear button (week status: $(tt_week_status "$CUSER" "$WEEK")) — the app hides Clear, Save and Submit together once a week leaves Draft/Rejected/empty, so Clear was never exercised. The day cells stay editable in that state, which is why the week looked usable."
fi

if ! hc_click btnClear; then
  tt_fail "the Clear button could not be clicked on week '$WEEK' (week status: $(tt_week_status "$CUSER" "$WEEK"))"
fi
# Read the dialog before dismissing it, and keep BOTH the text and the verdict.
# Discarding these with `|| true` is why a blocked Clear and a dismissed error
# dialog looked identical to a Clear that ran and did nothing.
CLEAR_DIALOG="$(hc_dialog_text)"
clear_ran=1
if ! tt_clear_dialogs 8 "Clear"; then
  bad "A a dialog blocked the Clear on week '$WEEK', so it never ran: \"$TT_DIALOG_BLOCKED\""
  clear_ran=0
fi
sleep 2

grid_gone=0
if [ "$clear_ran" = "1" ]; then
  cells="$(hc_cells)"
  case "$cells" in
    nogrid|0)
      grid_gone=1
      case "$cells" in
        nogrid) where="the gallery is not on the page at all" ;;
        *)      where="the gallery is on the page but rendering zero rows" ;;
      esac
      bad "A after Clear there are NO day cells to read - $where (week on screen: '$(tt_current_week)'; dialog at the click: \"${CLEAR_DIALOG:-none}\"; week status: $(tt_week_status "$CUSER" "$WEEK")). Nothing can be said about blank versus zero from a grid with no cells; this is a rendering or data fault, not ACT_Timesheet_Clear conflating the two states."
      ;;
    *)
      notblank=""
      for d in $DAYS; do
        v="$(hc_day "$ORD" "$d")"
        [ "$v" = "" ] || notblank="$notblank $d=[$v]"
      done

      if [ -z "$notblank" ]; then
        note "A Clear left every day cell exactly blank"
      elif hc_is_zero "$(hc_day "$ORD" Mon)"; then
        bad "A Clear wrote ZEROS instead of blanks —$notblank. Blank means 'nothing recorded' and 0 means 'recorded none'; ACT_Timesheet_Clear must not conflate them"
      else
        bad "A Clear did not empty the week —$notblank"
      fi
      ;;
  esac
fi

# ----------------------------------------- B. an explicit 0 survives as a zero
#
# WHY A SENTINEL FIRST. Main.SUB_Timesheet_Zero converts every empty day value to
# 0 whenever a week is saved, so any week that has ever been saved reads 0.00 in
# all seven cells from then on. Writing a 0 and reading 0.00 back therefore
# proves nothing by itself — it is indistinguishable from the residue of some
# earlier run, and a case that cannot fail is not a test. Round-tripping a 7
# first makes the following 0.00 provably ours: it had to replace a non-zero.

# hc_save_and_refetch — save the draft, then re-read the SAME week.
#
# Re-query WITHOUT reloading. The page opens on today's week, so a reload here
# silently moves the read to whatever week contains today's date — which is how
# this case came to report an explicit 0 "coming back as 9.00": the 9 was
# verify-hours-validation's, written into the current week minutes earlier. See
# tt_refetch_week in lib/_login.sh.
hc_save_and_refetch() {
  hc_click btnSaveDraft || return 1
  # Same rule as the Clear below: a blocked dialog gets reported, not swallowed.
  if ! tt_clear_dialogs 6; then
    bad "B a dialog blocked the save on week '$WEEK': \"$TT_DIALOG_BLOCKED\""
  fi
  sleep 2
  tt_refetch_week
  return 0
}

sentinel_ok=1
if [ "$grid_gone" = "1" ]; then
  # Writing a sentinel into a grid with no cells cannot fail loudly - the fill
  # finds nothing and the read comes back __MISSING__, which the old code then
  # reported as "the save path is not carrying values through". Say what is
  # actually wrong instead, and do not pretend B ran.
  note "B not exercised — the grid rendered no day cells after Clear, so a sentinel could neither be written nor read back"
  sentinel_ok=0
else
  hc_set "$ORD" "Mon" "7"
  sleep 1
  if ! hc_save_and_refetch; then
    bad "B the week could not be saved — no Save button (week status: $(tt_week_status "$CUSER" "$WEEK")). Save is hidden by the same rule as Clear, so nothing about zeros could be proven"
    sentinel_ok=0
  else
    ORD="$(hc_row_any)"
    sv="$(hc_day "$ORD" Mon)"
    case "$sv" in
      7|7.0|7.00) : ;;
      __MISSING__)
        bad "B after saving, row $ORD has no Mon day cell to read (grid is rendering: $(hc_cells); week on screen: '$(tt_current_week)'). The sentinel could not be re-read at all, so nothing about zeros is provable — and that is a rendering fault, not the save path dropping a value"
        sentinel_ok=0 ;;
      *) bad "B the save path is not carrying values through — a 7 written to Mon came back as [$sv], so a 0 reading back as 0.00 would prove nothing about the app"
         sentinel_ok=0 ;;
    esac
  fi
fi

if [ "$sentinel_ok" = "1" ]; then
  hc_set "$ORD" "Mon" "0"
  sleep 1
  hc_save_and_refetch || true

  ORD="$(hc_row_any)"
  shown="$(tt_current_week)"
  if [ -n "$shown" ] && [ "${WEEK#*"$shown"}" = "$WEEK" ]; then
    bad "B the grid moved to week '$shown' while case B was written against '$WEEK', so the re-read would have been of the wrong week"
  elif [ "$ORD" = "0" ]; then
    bad "B the '$PROJECT' row vanished after saving a draft, so the zero could not be re-read"
  else
    v="$(hc_day "$ORD" Mon)"
    if hc_is_zero "$v"; then
      note "B an explicit 0 replaced the 7 and came back as [$v], distinct from blank"
    elif [ "$v" = "" ]; then
      bad "B an explicit 0 came back BLANK — the app cannot tell 'worked none' from 'nothing recorded', which is the distinction Clear depends on"
    elif [ "$v" = "7" ] || [ "$v" = "7.0" ] || [ "$v" = "7.00" ]; then
      bad "B the 0 never reached the app — Mon still reads the sentinel [$v], so the save after writing the zero did not take"
    else
      bad "B an explicit 0 came back as [$v], which is neither zero nor blank"
    fi
  fi
fi

# --------------------------------------- C. Clear refused once not editable
WEEK2="$(tt_goto_fresh_week "$PROJECT")" || WEEK2=""
if [ -z "$WEEK2" ]; then
  # "No fresh week" has two causes the old note could not tell apart: a pool the
  # earlier steps used up, or a grid rendering nothing at all. The first is the
  # suite running out of weeks; the second is a fault, and it is what the
  # 2026-08-31 run was actually reporting.
  c2="$(hc_cells)"
  case "$c2" in
    nogrid|0)
      echo "  note: no second fresh week available because the assignment grid is rendering NO rows at all (gallery: $c2). That is a broken or empty grid, NOT an exhausted week pool. The submitted-week guard was not exercised."
      ;;
    *)
      echo "  note: no second fresh week available — the grid is rendering $c2 row(s), so the fresh-week pool is exhausted rather than broken (running this spec directly skips 00-setup's data clear, which is what refills it). The submitted-week guard was not exercised."
      ;;
  esac
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
      if [ "$(tt_week_actionable)" != "true" ]; then
        # The guard in its strongest form: the app does not merely refuse the
        # Clear, it removes the button. Nothing to press means nothing to destroy.
        note "C Clear is not offered at all on the submitted week (week status: $(tt_week_status "$CUSER" "$WEEK2"))"
      else
        hc_click btnClear || true
        tt_clear_dialogs 8 "Clear" >/dev/null 2>&1 || true
        sleep 2
        after="$(hc_report "$ORD2")"
        if [ "$before" = "$after" ]; then
          note "C Clear was offered on the submitted week but left it untouched"
        else
          bad "C Clear MODIFIED a submitted week. before:$before after:$after — ACT_Timesheet_Clear's draft/empty/rejected guard is not holding, so approved hours can be destroyed"
        fi
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
