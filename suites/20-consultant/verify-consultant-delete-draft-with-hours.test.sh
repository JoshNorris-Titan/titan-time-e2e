#!/usr/bin/env bash
# A consultant can delete a draft week that already has hours on it.
#
# WHY THIS EXISTS (2026-09-10). Until then a consultant could bin a draft week only
# while it held nothing: imgHistoryDelete's visibility expression on
# Main.ConsultantDashboard required TotalHours = 0, and Main.ACT_Timesheet_Delete_Confirm
# refused server-side if any entry under the week had hours. A consultant who started
# the wrong week was stuck with it once a single hour was on it, and had to zero every
# box by hand. Both halves were relaxed together: the bin now appears on every draft of
# the consultant's own, and the server-side hours guard is lifted.
#
# NOTHING IN THE SUITE DELETED A WEEK BEFORE THIS FILE -- not even the old zero-hour
# delete. verify-history-status-badge.test.sh asserts WHERE the bin appears; it never
# presses it. So the server half of that change had no coverage at all: restore the
# hours guard in the microflow and the bin still shows, the delete is refused with an
# error message, and every other spec stays green. This one presses it.
#
# WHAT IT ASSERTS, on a week it creates for itself:
#   1. after Save Draft the hours persist -- re-fetched from the server, not read
#      back off the input that was just typed into;
#   2. the week's history row reads "Draft", shows non-zero hours, AND offers the bin.
#      This is the assertion the pre-2026-09-10 visibility expression fails;
#   3. the confirmation popup names the right week and states a non-zero hours figure
#      before the consultant commits. That popup is the one safeguard left between a
#      misclick and an irreversible delete, so it is asserted rather than assumed. Note
#      it reads the STORED Main.Timesheet.TotalHours, while the history row's hours are
#      summed at render time -- if Save Draft ever stops keeping the stored total in
#      step, the popup says "0.00 hrs" about a week that has hours, and this fails;
#   4. confirming raises no refusal and closes the popup. This is the assertion the
#      pre-2026-09-10 microflow guard fails;
#   5. the week is gone at the DATA LAYER and from the history list. A positive control
#      is read BEFORE the delete, so that "absent" afterwards is a finding and not a
#      read that could never have seen the week in the first place.
#
# WHAT IT DOES NOT ASSERT, and where that lives instead:
#   - that the week's entries and task rows went with it. That is domain-model delete
#     behaviour and is covered by Core.UT_DomainModel_TimesheetDeleteCascadesAndOrphans
#     in the unit suite. A client-side XPath for orphaned entries would be BLIND here:
#     Mendix answers a query on an object the user cannot read with zero rows and no
#     error, so "no orphans found" would be what it reports whether or not they exist.
#   - that a week carrying an expense report, uploaded documents or approval history is
#     still refused. That guard is unchanged, and a fresh week has none of those.
#
# OWNS ITS DATA. It works on ONE week, $AHEAD weeks after today's, as e2e_consultant.
# 14 sits past every other spec's forward walk -- the longest are 12 -- and inside the
# fixture assignment window (FX_START_DATE..FX_END_DATE in lib/_fixtures.sh,
# 07/01/2026 - 12/31/2027). If this fails after saving and before deleting, it leaves
# one draft with $HOURS hours on that week. That is harmless to every later spec -- a
# draft with hours offers the bin, which is what verify-history-status-badge now
# expects -- and the next run's 00-setup clear removes it.
#
# DELETES FROM THE HISTORY LIST WHILE THE GRID SHOWS TODAY'S WEEK, on purpose. The
# grid's data source creates a week on demand, so the absence check must not run while
# the grid is displaying the very week being deleted -- a re-query there could bring
# it back as a fresh empty draft and fail the check against a product that did what
# it was asked. A reload puts the grid on today's week first.
#
# NEEDS THE 2026-09-10 MODEL CHANGE DEPLOYED. Against an environment that predates it,
# this fails at assertion 2 with a message saying so.

set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

CUSER="e2e_consultant"
AHEAD="${TT_DELETE_WEEKS_AHEAD:-14}"
HOURS="3"
GAL=".mx-name-galTimesheetHistory"
WED=".mx-name-galAssignmentRows .mx-name-txtDayWed input"

tt_login "$CUSER" "My Timesheets"

# --- Step 1: walk to the target week ------------------------------------------
# One eval for the whole walk: every playwright-cli call is a fresh node process
# (~2.6s), so a bash loop of fourteen clicks would spend most of its time starting
# processes. Each click waits for the week caption to change before the next, so a
# slow week cannot be skipped over.
WALK="$(playwright-cli eval "async () => {
  const cap = () => String((document.querySelector('.mx-name-txtWeekRange') || {}).innerText || '').trim();
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  for (let i = 0; i < $AHEAD; i++) {
    const before = cap();
    const b = document.querySelector('.mx-name-btnWeekNext');
    if (!b) return 'NONEXT:' + i;
    b.click();
    let n = 0;
    while (cap() === before && n < 40) { await sleep(250); n++; }
    if (cap() === before) return 'STUCK:' + i + ':' + before;
  }
  await sleep(1500);
  return 'OK:' + cap();
}" 2>/dev/null | _tt_eval_str)"
case "$WALK" in
  OK:*) ;;
  *) tt_fail "could not step $AHEAD weeks ahead of today: $WALK" ;;
esac
WEEK_KEY="$(tt_week_key "${WALK#OK:}")"
[ -n "$WEEK_KEY" ] || tt_fail "could not read a week range from the grid caption '${WALK#OK:}'"
echo "target week: $WEEK_KEY (${WALK#OK:})"

[ "$(tt_week_actionable)" = "true" ] \
  || tt_fail "week $WEEK_KEY has no action buttons, so it is already past Draft (data layer says: $(tt_week_status "$CUSER" "$WEEK_KEY")). This spec expects a fresh week $AHEAD weeks out -- was 00-setup skipped?"

# The first assignment row whose Wednesday is editable. The Line Items row's day cells
# are never editable (they roll up from tasks), so its position is not assumed.
ORD=""
for _ in 1 2 3 4 5; do
  ORD="$(playwright-cli eval "() => { const c = [...document.querySelectorAll('$WED')]; for (let n = 0; n < c.length; n++) { if (!c[n].disabled && !c[n].readOnly) return String(n + 1); } return c.length ? 'NOEDIT' : 'NOROWS'; }" 2>/dev/null | _tt_eval_str)"
  [ "$ORD" = "NOROWS" ] || break
  sleep 2
done
case "$ORD" in
  NOROWS) tt_fail "week $WEEK_KEY rendered no assignment rows for $CUSER -- is it inside the fixture assignment window (lib/_fixtures.sh)?" ;;
  NOEDIT) tt_fail "week $WEEK_KEY has assignment rows but no editable Wednesday cell" ;;
  ''|*[!0-9]*) tt_fail "could not locate an editable row on week $WEEK_KEY (got '$ORD')" ;;
esac

# --- Step 2: put hours on it and prove they were saved -------------------------
tt_fill ":nth-match($WED, $ORD)" "$HOURS"
playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1 \
  || tt_fail "could not press Save Draft on week $WEEK_KEY"
sleep 2
tt_clear_dialogs 4 || tt_fail "Save Draft on week $WEEK_KEY was stopped by a dialog: $TT_DIALOG_BLOCKED"

tt_refetch_week
[ "$(tt_current_week)" = "$WEEK_KEY" ] \
  || tt_fail "re-fetching left the grid on '$(tt_current_week)' instead of $WEEK_KEY"
GOT="$(playwright-cli eval "() => String((document.querySelectorAll('$WED')[$ORD - 1] || {}).value || '')" 2>/dev/null | _tt_eval_str)"
case "$GOT" in
  "$HOURS"|"$HOURS.0"|"$HOURS.00") echo "  saved: row $ORD Wednesday reads $GOT after a re-fetch" ;;
  *) tt_fail "draft did not persist on week $WEEK_KEY (wrote $HOURS, re-fetched '$GOT'), so there is no draft-with-hours to delete" ;;
esac

# --- Step 3: positive control at the data layer --------------------------------
# tt_week_statuses prints "<Mon> <D> <status>" per week, read from the objects.
MON="${WEEK_KEY%% *}"
DAY="${WEEK_KEY#* }"; DAY="${DAY%% *}"; DAY="$((10#$DAY))"
week_state() {
  local all
  all="$(tt_week_statuses "$CUSER")"
  case "$all" in ERR:*) echo "$all"; return 0 ;; esac
  printf '%s\n' "$all" | awk -v m="$MON" -v d="$DAY" '$1==m && $2+0==d { print $3; f=1; exit } END { if (!f) print "ABSENT" }'
}
BEFORE="$(week_state)"
case "$BEFORE" in
  Draft|'?') echo "  positive control: week $WEEK_KEY is in the data as '$BEFORE'" ;;
  ERR:*)     tt_fail "could not read $CUSER's weeks from the data layer ($BEFORE), so an absence after the delete would prove nothing" ;;
  ABSENT)    tt_fail "positive control failed: week $WEEK_KEY was saved, yet the data-layer read cannot see it -- its absence after the delete would prove nothing" ;;
  *)         tt_fail "week $WEEK_KEY reads '$BEFORE' in the data, not Draft -- the bin is only offered on drafts" ;;
esac

# --- Step 4: the history row offers the bin ------------------------------------
# Reload lands the grid on TODAY's week -- see the header for why that matters.
read_history() {
  playwright-cli eval "() => {
    const g = document.querySelector('$GAL');
    if (!g) return 'NO-GALLERY';
    return [...g.querySelectorAll('.widget-gallery-item')].map(row => {
      const t = s => { const e = row.querySelector(s); return e ? (e.innerText || '').replace(/\\s+/g, ' ').trim() : ''; };
      return [t('.mx-name-txtHistoryWeek'), t('.mx-name-txtHistoryStatus'), t('.mx-name-txtHistoryHours'), row.querySelector('.mx-name-imgHistoryDelete') ? 'bin' : 'nobin'].join('|');
    }).join('~~');
  }" 2>/dev/null | _tt_eval_str
}

playwright-cli reload >/dev/null 2>&1
sleep 4
tt_wait_for "$GAL" "the timesheet history gallery"
tt_gallery_load_all "$GAL" "timesheet history" >/dev/null
HIST="$(read_history)"
[ "$HIST" != "NO-GALLERY" ] || tt_fail "no $GAL on the consultant dashboard after reload"

# Split the ~~-joined rows. Count bins as we go: the one on OUR row is clicked by its
# ordinal among all bins in this gallery, which is only right if rows are walked in
# document order -- they are.
OLD_IFS="$IFS"; IFS='~'
# shellcheck disable=SC2206
PARTS=($HIST)
IFS="$OLD_IFS"
MINE=""; BINS=0; BIN_ORD=0
for p in "${PARTS[@]}"; do
  [ -n "$p" ] || continue
  IFS='|' read -r h_wk h_st h_hrs h_bin <<< "$p"
  [ "$h_bin" = "bin" ] && BINS=$((BINS + 1))
  if [ -z "$MINE" ] && [ "$(tt_week_key "$h_wk")" = "$WEEK_KEY" ]; then
    MINE="$p"
    [ "$h_bin" = "bin" ] && BIN_ORD=$BINS
  fi
done
[ -n "$MINE" ] || tt_fail "week $WEEK_KEY is not in the timesheet history after being saved. Rows: $(tt_gallery_titles "$GAL")"
IFS='|' read -r M_WK M_ST M_HRS M_BIN <<< "$MINE"
echo "  history row: '$M_WK' | '$M_ST' | '$M_HRS' | $M_BIN"

[ "$M_ST" = "Draft" ] \
  || tt_fail "history row for $WEEK_KEY reads '$M_ST', not Draft"
case "${M_HRS%% *}" in
  ''|0|0.|0.0|0.00) tt_fail "history row for $WEEK_KEY reads '$M_HRS' -- the hours this spec saved are not showing, so it would not be testing a draft WITH hours" ;;
esac
[ "$M_BIN" = "bin" ] \
  || tt_fail "history row for $WEEK_KEY reads Draft with $M_HRS but offers no delete icon. imgHistoryDelete's visibility still requires zero hours -- the rule before 2026-09-10 -- or that change has not reached this environment"

# --- Step 5: open the confirmation and check what it says ----------------------
playwright-cli click ":nth-match($GAL .mx-name-imgHistoryDelete, $BIN_ORD)" >/dev/null 2>&1 \
  || tt_fail "could not click the delete icon on week $WEEK_KEY (bin #$BIN_ORD of $BINS)"
tt_wait_for ".mx-name-btnDeleteConfirm" "the Delete week confirmation (Main.Consultant_DeleteWeek)"

cancel_delete() { playwright-cli click ".mx-name-btnDeleteCancel" >/dev/null 2>&1; sleep 2; }

POP_WEEK="$(playwright-cli eval "() => String((document.querySelector('.mx-name-txtDeleteWeek') || {}).innerText || '').trim()" 2>/dev/null | _tt_eval_str)"
if [ "$(tt_week_key "$POP_WEEK")" != "$WEEK_KEY" ]; then
  cancel_delete
  tt_fail "the delete confirmation is for '$POP_WEEK', not $WEEK_KEY -- the wrong row's bin was clicked, so the delete was cancelled rather than risk someone else's week"
fi

DETAIL="$(playwright-cli eval "() => String((document.querySelector('.mx-name-txtDeleteDetail') || {}).innerText || '').replace(/\\s+/g, ' ').trim()" 2>/dev/null | _tt_eval_str)"
POP_HRS="$(printf '%s' "$DETAIL" | sed -n 's/.*has \([0-9][0-9.,]*\) hrs.*/\1/p')"
case "$POP_HRS" in
  ''|0|0.|0.0|0.00)
    cancel_delete
    tt_fail "the delete confirmation does not state the week's hours before deleting it (read: '$DETAIL'). It is the one safeguard left between the bin and an irreversible delete, and it reads the STORED Main.Timesheet.TotalHours -- check that Save Draft still keeps it in step" ;;
esac
echo "  confirmation: '$DETAIL'"

# --- Step 6: confirm, and nothing may refuse it --------------------------------
playwright-cli click ".mx-name-btnDeleteConfirm" >/dev/null 2>&1 \
  || tt_fail "could not press Delete week on the confirmation"

# Poll in-page until no dialog is up. A refusal from the microflow is a BLOCKING
# message, so it stays up and is reported with its own text; a popup that is merely
# slow to close is given ten seconds before it counts.
LEFT="$(playwright-cli eval "async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const top = () => { const vis = [...document.querySelectorAll('$TT_DIALOG_SEL')].filter(d => d.offsetParent !== null); const outer = vis.filter(d => !vis.some(o => o !== d && o.contains(d))); return outer[outer.length - 1] || null; };
  for (let i = 0; i < 20; i++) { if (!top()) return 'NONE'; await sleep(500); }
  const d = top();
  return d ? (d.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 200) : 'NONE';
}" 2>/dev/null | _tt_eval_str)"
[ "$LEFT" = "NONE" ] \
  || tt_fail "confirming the delete of week $WEEK_KEY left a dialog up: '$LEFT'. If it says the week still has hours recorded, Main.ACT_Timesheet_Delete_Confirm's hours guard is back, or this environment predates 2026-09-10"

# --- Step 7: the week is gone ---------------------------------------------------
AFTER="$(week_state)"
case "$AFTER" in
  ABSENT) echo "  deleted: week $WEEK_KEY is no longer in the data" ;;
  ERR:*)  tt_fail "could not re-read $CUSER's weeks after the delete ($AFTER)" ;;
  *)      tt_fail "week $WEEK_KEY is still in the data after its delete was confirmed (status '$AFTER')" ;;
esac

playwright-cli reload >/dev/null 2>&1
sleep 4
tt_wait_for "$GAL" "the timesheet history gallery"
tt_gallery_load_all "$GAL" "timesheet history" >/dev/null
HIST="$(read_history)"
OLD_IFS="$IFS"; IFS='~'
# shellcheck disable=SC2206
PARTS=($HIST)
IFS="$OLD_IFS"
for p in "${PARTS[@]}"; do
  [ -n "$p" ] || continue
  h_wk="${p%%|*}"
  [ "$(tt_week_key "$h_wk")" != "$WEEK_KEY" ] \
    || tt_fail "week $WEEK_KEY is gone from the data but its history row is still listed after a reload: '$p'"
done
echo "  history list no longer shows $WEEK_KEY"

echo "PASS: $CUSER deleted draft week $WEEK_KEY with $POP_HRS hours on it -- bin offered, hours stated, no refusal, week gone"
