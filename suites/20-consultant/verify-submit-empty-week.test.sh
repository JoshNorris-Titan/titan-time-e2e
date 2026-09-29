#!/usr/bin/env bash
# Submitting a week with no hours sends every entry straight to ToProcess,
# bypassing manager and customer approval.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. Main.ACT_Timesheet_Submit routes an entry whose TotalHours is 0
# to ToProcess regardless of the project's ApprovalFromManager and
# ApprovalFromCustomer flags. That is deliberate - nobody should have to approve a
# blank week - but it means a blank week reaches HR marked as approved work
# without a human ever looking at it, and the behaviour is load-bearing enough
# that a change to it should be noticed.
#
# tt692693-c2 is the only test that touches zero hours, and it reaches the
# behaviour through the REJECTED-entry Review & Edit popup, which is a different
# microflow (Main.SUB_AssignmentEntry_Submit). The ordinary weekly grid path
# through ACT_Timesheet_Submit has never been exercised with an empty week.
#
# WHAT IT ASSERTS
#   A. the week really is empty before submitting - every day cell blank or zero.
#      Without this the test could pass on a week that had hours and was approved
#      normally, which is the wrong behaviour passing for the right reason;
#   B. the submit is accepted: the "Timesheet submitted" receipt opens, its OK
#      returns to the same week, and that week no longer offers Submit;
#   C. every entry THIS SUBMIT touched is ToProcess, read from the DATA LAYER
#      rather than from a badge - the badge is a rollup and would read "Awaiting
#      Approval" identically whether the entries went to ToProcess or to
#      AwaitingManagerApproval - and there is one such entry per row on the grid;
#   D. specifically, none of them is AwaitingManagerApproval or
#      AwaitingCustomerApproval.
#
# C is the assertion that distinguishes this from a plain submit test. B alone
# passes whatever status the entries ended in.
#
# SCOPED TO THIS SUBMIT (2026-09-29). C and D used to count every entry the
# consultant owns, in every week. By the time this runs, verify-current-week-warning
# has submitted E2E Consultant Two's current week with 40 hours on E2E Sandbox (a
# manager-approval project), so two AwaitingManagerApproval entries from ANOTHER
# week failed D on every full run. "This submit" is the entries whose SubmittedDT
# is no older than the moment the spec started (less a minute of clock slack), the
# same window verify-submit-receipt uses.
#
# THE RECEIPT (2026-09-29). Submitting now ends on Main.Consultant_TimesheetSubmitted.
# B used to read the week's status from the history list with no week argument,
# which read nothing and passed on an empty string ("the week now reads ").
#
# Consumes: one fresh week, which it submits and leaves in ToProcess.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_rejection.sh"
source "$TT_ROOT/lib/_authz.sh"

CUSER="${TT_EMPTY_SUBMIT_USER:-e2e_consultant2}"
CNAME="${TT_EMPTY_SUBMIT_NAME:-E2E Consultant Two}"
PROJECT="${TT_EMPTY_SUBMIT_PROJECT:-E2E Sandbox}"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

T0_MS="$(( $(date +%s) * 1000 - 60000 ))"
ev() { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

# submitted_statuses - the Status of every entry of $CNAME submitted since T0_MS,
# comma-separated, or ERR:<why>.
submitted_statuses() {
  local xp="//Main.AssignmentEntry[Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName = '$CNAME'][SubmittedDT != empty]"
  ev "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"$xp\", filter:{ amount: 200 }, callback: function(o){ clearTimeout(t); res((o||[]).filter(e => Number(e.get('SubmittedDT')) >= $T0_MS).map(e => String(e.get('Status'))).join(',')); }, error: function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e) { res('ERR:'+e.message); } })"
}

nonzero_cells() {
  playwright-cli eval "() => { const els=[...document.querySelectorAll('.mx-name-galAssignmentRows input')]; return String(els.filter(e => { const v=String(e.value||'').trim().replace(',','.'); return v !== '' && parseFloat(v) > 0; }).length); }" 2>/dev/null | _tt_eval_str
}

tt_login "$CUSER" "My Timesheets"
tt_goto_fresh_week "$PROJECT" || tt_fail "no fresh week with an editable '$PROJECT' row was reachable"
WEEK="$(tt_week_label)"
note "week $WEEK"

# ------------------------------------------------------------------- A. really empty
NZ="$(nonzero_cells)"
case "$NZ" in
  ''|*[!0-9]*) tt_fail "could not count filled day cells in week $WEEK (read: [$NZ])" ;;
  0)           note "A ok: every day cell is blank or zero" ;;
  *)           tt_fail "week $WEEK already carries $NZ non-zero day cell(s), so this would test an ordinary submit, not an empty one. tt_goto_fresh_week is supposed to land on an untouched week." ;;
esac

ROWS="$(ev "() => String(document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon').length)")"
case "$ROWS" in ''|*[!0-9]*|0) tt_fail "could not count the rows on week $WEEK (read: [$ROWS])" ;; esac
note "week $WEEK has $ROWS row(s)"

# ---------------------------------------------------------------------- B. submit it
playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
tt_wait_for ".mx-name-btnConfirmSubmit" "the Submit timesheet? confirmation (btnConfirmSubmit)"
playwright-cli click ".mx-name-btnConfirmSubmit" >/dev/null 2>&1

up=""
for _ in $(seq 1 20); do
  up="$(ev "() => String(!!document.querySelector('.mx-name-containerReceipt'))")"
  [ "$up" = "true" ] && break
  sleep 1
done
if [ "$up" = "true" ]; then
  note "B ok: the submitted receipt opened"
  playwright-cli click ".mx-name-btnReceiptOk" >/dev/null 2>&1
  sleep 3
else
  bad "B: no receipt (containerReceipt) within 20s of confirming the submit. Dialog on screen: $(ev "() => { const d=$(_tt_dialog_js); return d ? (d.innerText||'').replace(/\s+/g,' ').slice(0,160) : '(none)'; }")"
  tt_dismiss_dialogs >/dev/null 2>&1 || note "note: a dialog is still blocking: $TT_DIALOG_BLOCKED"
fi

AFTER_WEEK="$(tt_week_label)"
ACTIONABLE="$(tt_week_actionable)"
if [ "$AFTER_WEEK" = "$WEEK" ] && [ "$ACTIONABLE" = "false" ]; then
  note "B ok: back on week $AFTER_WEEK, which no longer offers Submit"
else
  bad "B: after the submit the grid shows '$AFTER_WEEK' (submitted: $WEEK) with actionable=$ACTIONABLE - expected the same week, no longer actionable"
fi

# ------------------------------------------------------- C/D. where did the entries go
tt_login "e2e_hr" "$TT_HR_READY"
ST="$(submitted_statuses)"
case "$ST" in ERR:*) tt_fail "could not read the entries this submit touched ($ST)" ;; esac
N=0; TOPROCESS=0; AWAIT_M=0; AWAIT_C=0; OTHER=""
IFS=','
for s in $ST; do
  [ -n "$s" ] || continue
  N=$((N+1))
  case "$s" in
    ToProcess)                TOPROCESS=$((TOPROCESS+1)) ;;
    AwaitingManagerApproval)  AWAIT_M=$((AWAIT_M+1)) ;;
    AwaitingCustomerApproval) AWAIT_C=$((AWAIT_C+1)) ;;
    *)                        OTHER="$OTHER $s" ;;
  esac
done
unset IFS
note "for $CNAME, submitted by this run: $N entr(ies) - ToProcess=$TOPROCESS AwaitingManager=$AWAIT_M AwaitingCustomer=$AWAIT_C${OTHER:+ other:$OTHER}"

if [ "$N" -eq 0 ]; then
  bad "C: no entry for $CNAME carries a SubmittedDT from this run, so the empty submit reached nothing"
elif [ "$N" -ne "$ROWS" ]; then
  bad "C: this submit touched $N entr(ies), but week $WEEK showed $ROWS row(s)"
elif [ "$TOPROCESS" -ne "$N" ]; then
  bad "C: only $TOPROCESS of the $N entr(ies) this submit touched are ToProcess"
else
  note "C ok: all $N entr(ies) this submit touched are ToProcess, one per row"
fi

for pair in "AwaitingManagerApproval:$AWAIT_M" "AwaitingCustomerApproval:$AWAIT_C"; do
  s="${pair%%:*}"; n="${pair#*:}"
  if [ "$n" -eq 0 ]; then
    note "D ok: nothing this submit touched is waiting in $s"
  else
    bad "D: $n entr(ies) this submit touched are in $s - an empty week should bypass approval entirely"
  fi
done

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-submit-empty-week — $fails problem(s) with the zero-hours route."
  exit 1
fi
echo "PASS: verify-submit-empty-week — week $WEEK submitted empty and its entries went straight to ToProcess."
