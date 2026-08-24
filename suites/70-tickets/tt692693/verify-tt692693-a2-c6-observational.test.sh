#!/usr/bin/env bash
# A2 + C6 — OBSERVATIONAL. These two cases are "report what you see", not strict
# pass/fail, so this script always exits 0 and prints findings for the human report.
#
# A2 — browsing weeks must not flood the history with empty Draft weeks. The cleanup
#      is a SCHEDULED job, so same-session rows may still be present. Only a hard
#      signal ("every browsed week immediately appears as a Draft") is flagged.
# C6 — the resubmit should record a transition to the NEW status
#      (e.g. Rejected -> AwaitingManagerApproval), not a no-op Rejected -> Rejected.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"

CUSER="${TT_A2_USER:-e2e_consultant2}"
BROWSE="${TT_A2_WEEKS:-5}"

history_text() {
  playwright-cli eval "() => { const b=document.body.innerText||''; const i=b.indexOf('Timesheets'); return i<0?b.slice(0,600):b.slice(i,i+700).replace(/\n+/g,' | '); }" 2>/dev/null | sed -n '2p'
}
draft_count() {
  playwright-cli eval "() => { const b=document.body.innerText||''; const m=b.match(/Draft/g); return String(m?m.length:0); }" 2>/dev/null | sed -n '2p' | tr -d '"'
}

echo "=============== A2 — empty drafts on week browsing ==============="
tt_login "$CUSER" "My Timesheets"
D0="$(draft_count)"; H0="$(history_text)"
echo "drafts before browsing: $D0"
echo "history before: $H0"

START="$(tt_week_label)"
echo "browsing forward $BROWSE weeks from $START WITHOUT entering anything..."
for i in $(seq 1 "$BROWSE"); do
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1; sleep 2
done
for i in $(seq 1 "$BROWSE"); do
  playwright-cli click ".mx-name-btnWeekPrev" >/dev/null 2>&1; sleep 2
done
echo "back at: $(tt_week_label)"

tt_login "$CUSER" "My Timesheets" >/dev/null 2>&1
D1="$(draft_count)"; H1="$(history_text)"
echo "drafts after browsing: $D1"
echo "history after: $H1"

DELTA=$(( ${D1:-0} - ${D0:-0} ))
echo "--- A2 RESULT: draft delta = $DELTA after browsing $BROWSE weeks each way ---"
if [ "$DELTA" -ge "$BROWSE" ]; then
  echo "A2 FLAG: every browsed week appears to have produced a Draft (delta $DELTA >= $BROWSE browsed)."
  echo "         Report this; the scheduled cleanup may not be running or drafts are created eagerly."
else
  echo "A2 OK-ish: browsing did not create one Draft per week (scheduled cleanup may still be pending)."
fi

echo
echo "=============== C6 — audit trail on resubmit ==============="
# Look for any visible change/status history on the consultant's entry.
tt_login "$CUSER" "My Timesheets" >/dev/null 2>&1
if [ "$(tt_rejected_count)" != "0" ] && tt_open_review_edit; then
  echo "popup text (look for a history/changelog section):"
  tt_popup_text
  playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); if(!d) return 'nopopup'; const t=(d.innerText||''); return JSON.stringify({mentionsHistory:/history|change ?log|audit|status/i.test(t)}); }" 2>/dev/null | sed -n '2p'
  tt_click_button_exact "cancel" popup >/dev/null 2>&1
else
  echo "no rejected entry available to inspect (run a C-case first, or the entry was consumed)"
fi
echo "C6 NOTE: the ChangeLog is not exposed on the consultant UI here. To verify the"
echo "         transition was recorded as Rejected -> AwaitingManagerApproval (not a"
echo "         no-op Rejected -> Rejected), check the entry's ChangeLog in the DB/admin"
echo "         view after a C1 run, or ask the author to expose it."

echo
echo "OBSERVATIONAL COMPLETE (always exit 0) — fold these notes into the report."
exit 0
