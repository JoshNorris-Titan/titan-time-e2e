#!/usr/bin/env bash
# TT-779 — HR can close a week whose only outstanding item is a Draft.
#
# WHY THIS EXISTS. Until TT-779, HR's "Submit 0-hour entries" on the Pending tab only
# CREATED entries for assignments the consultant had never touched. A consultant who
# opened a week, typed something and walked away left a Draft behind, and that week
# could never be closed by HR: the Pending row still counted the Draft as outstanding,
# but Main.HRDashboard showed btnSubmitZeroHours only on MissingEntryCount > 0, so the
# row offered the greyed look-alike (tipSubmitZeroBlocked) instead. TT-779 made
# Main.ACT_Pending_SubmitZeroHours zero-submit Draft and empty-status entries too,
# taught Main.SUB_Pending_GapsForWeek to put DraftEntryCount / DraftProjectNames on
# the row, moved the button's visibility to MissingEntryCount + DraftEntryCount > 0,
# and gave Main.HR_ConfirmZeroHours a txtConfirmZeroDrafts paragraph naming the drafts
# (with "(N h)" after any that carry typed hours, because those hours are about to be
# replaced with zero).
#
# WHAT IT ASSERTS, on a week it prepares for itself:
#   1. the consultant's Pending row for that week offers the LIVE btnSubmitZeroHours
#      and NOT tipSubmitZeroBlocked. Against the pre-TT-779 model this is red: a
#      Draft-only week had MissingEntryCount = 0, so the button was hidden and the
#      look-alike shown;
#   2. pressing it opens Main.HR_ConfirmZeroHours with txtConfirmZeroDrafts visible
#      and naming a draft with "(3 h)" -- the hours this spec typed. Red before
#      TT-779 too: the widget did not exist;
#   3. txtConfirmZeroMissing is ABSENT. This is the precondition made visible, not a
#      decoration: it renders only when MissingProjectNames is non-empty, so its
#      absence is what proves the row really was a drafts-only week. Without it, 1
#      and 2 would also pass on a week that simply had a missing entry as well;
#   4. Cancel closes the popup and the row is still there with its live button --
#      nothing was submitted.
#
# NON-DESTRUCTIVE ON THE HR SIDE: it opens the confirmation and CANCELS. It never
# presses btnConfirmZeroSubmit, so no entry is zeroed or sent to processing. The
# zero-submit itself (hours replaced, line items zeroed and kept, the ChangeLog
# snapshot) is server logic with no UI surface beyond the To Process card; it belongs
# in the unit suite, not here.
#
# THE DATA IT DOES WRITE, and why that is within the suite's conventions. A drafts-only
# week does not exist after 00-setup -- the clear leaves every week empty, and an
# empty week on Pending is "missing", not "draft". So the spec makes one the way a
# consultant would: as e2e_consultant2 it opens a week $BACK weeks before today's
# (which creates the timesheet and an entry for every active assignment, so nothing is
# missing), types $HOURS hours into one editable Wednesday cell and presses Save
# Draft. That leaves one Draft week for that consultant, which 99-teardown's clear and
# the next run's 00-setup clear both remove, exactly like the drafts the 20-consultant
# specs leave.
#
# WHY BACKWARDS, AND WHY $BACK. HR's Pending tab only lists weeks from LAST week back
# (Main.SUB_Pending_BuildWeeksWithGaps, Core.CONST_PendingLookbackWeeks = 26), so the
# forward fresh-week pool the other specs share is useless here. Backwards, the
# fixture's own seed (FX_ENTRIES) uses 3 weeks back for this consultant, so this
# starts at 8 and, if that week is not a clean Draft/empty week, tries up to three
# more. Every candidate stays inside the fixture assignment window (FX_START_DATE,
# 07/01/2026) for as long as today is before late 2027 -- the spec checks rows render
# rather than assuming it.
#
# UNPROVEN UNTIL TT-779 IS DEPLOYED. Written 2026-10-05 against the model saved and
# built that day; it has never run. Against an environment that predates TT-779 it
# fails at assertion 1, with a message saying so.
#
# Env: TT_BASE_URL, TT_ROLE_PASS.
#
# tt-timeout: 8m

set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

CUSER="e2e_consultant2"
CNAME="E2E Consultant Two"
BACK="${TT_TT779_WEEKS_BACK:-8}"
TRIES=4
HOURS="3"
WED=".mx-name-galAssignmentRows .mx-name-txtDayWed input"
WEEKS=".mx-name-galAvailableWeeks"
PENDING=".mx-name-galPending"

# ------------------------------------------------- consultant: make a drafts-only week
tt_login "$CUSER" "My Timesheets"

# step_back <n> -- one eval for the whole walk (every playwright-cli call is a fresh
# node process), each click waiting for the caption to change before the next.
step_back() {
  playwright-cli eval "async () => {
    const cap = () => String((document.querySelector('.mx-name-txtWeekRange') || {}).innerText || '').trim();
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    for (let i = 0; i < $1; i++) {
      const before = cap();
      const b = document.querySelector('.mx-name-btnWeekPrev');
      if (!b) return 'NOPREV:' + i;
      b.click();
      let n = 0;
      while (cap() === before && n < 40) { await sleep(250); n++; }
      if (cap() === before) return 'STUCK:' + i + ':' + before;
    }
    await sleep(1500);
    return 'OK:' + cap();
  }" 2>/dev/null | _tt_eval_str
}

WEEK_KEY=""
STEP="$BACK"
for attempt in $(seq 1 "$TRIES"); do
  WALK="$(step_back "$STEP")"
  case "$WALK" in
    OK:*) ;;
    *) tt_fail "could not step back to the candidate week (attempt $attempt): $WALK" ;;
  esac
  KEY="$(tt_week_key "${WALK#OK:}")"
  [ -n "$KEY" ] || tt_fail "could not read a week range from the grid caption '${WALK#OK:}'"
  STATE="$(tt_week_status "$CUSER" "$KEY")"
  # Draft / empty ('?') / not yet created (UNKNOWN) are all a week nobody has
  # submitted or had rejected -- what this spec needs. Anything else belongs to
  # another spec; leave it alone and try the week before.
  case "$STATE" in
    Draft|'?'|UNKNOWN)
      if [ "$(tt_week_actionable)" = "true" ]; then WEEK_KEY="$KEY"; break; fi ;;
  esac
  echo "  week $KEY is not a clean draft week (data layer: $STATE) -- trying the week before"
  STEP=1
done
[ -n "$WEEK_KEY" ] || tt_fail "no clean Draft/empty week for $CUSER in $TRIES weeks from $BACK back -- other data is sitting there; was 00-setup skipped?"
echo "target week: $WEEK_KEY"

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

tt_fill ":nth-match($WED, $ORD)" "$HOURS"
playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1 \
  || tt_fail "could not press Save Draft on week $WEEK_KEY"
sleep 2
tt_clear_dialogs 4 || tt_fail "Save Draft on week $WEEK_KEY was stopped by a dialog: $TT_DIALOG_BLOCKED"

tt_refetch_week
GOT="$(playwright-cli eval "() => String((document.querySelectorAll('$WED')[$ORD - 1] || {}).value || '')" 2>/dev/null | _tt_eval_str)"
case "$GOT" in
  "$HOURS"|"$HOURS.0"|"$HOURS.00") echo "  saved: a Draft with $HOURS h on week $WEEK_KEY" ;;
  *) tt_fail "draft did not persist on week $WEEK_KEY (wrote $HOURS, re-fetched '$GOT') -- there is no draft for HR to close" ;;
esac

# ------------------------------------------------------------ HR: the Pending tab
tt_login "e2e_hr" "$TT_HR_READY"
tt_hr_click_tab "Pending"
tt_wait_for "$WEEKS" "the Pending tab's week list"
tt_gallery_load_all "$WEEKS" "Pending weeks" >/dev/null

# Pick our week by its caption, normalized through tt_week_key on both sides.
WEEK_JS="const key = s => { s = String(s || '').replace(/[–—]/g, '-'); const m = s.match(/([A-Z][a-z][a-z])\s+(\d\d?)\s*-\s*(?:([A-Z][a-z][a-z])\s+)?(\d\d?)(?!\d)/); if (!m) return ''; const p = n => String(+n).padStart(2, '0'); return m[1] + ' ' + p(m[2]) + ' - ' + (m[3] || m[1]) + ' ' + p(m[4]); };
  const items = () => [...document.querySelectorAll('$WEEKS .widget-gallery-item')];
  const mine = () => items().find(i => key((i.querySelector('.mx-name-txtAvailableWeekRange') || {}).innerText) === '$WEEK_KEY');"
PICK="$(playwright-cli eval "() => { $WEEK_JS const i = mine(); if (!i) return 'NF:' + items().map(x => key((x.querySelector('.mx-name-txtAvailableWeekRange') || {}).innerText)).join(','); i.click(); return 'CLICKED'; }" 2>/dev/null | _tt_eval_str)"
case "$PICK" in
  CLICKED) ;;
  NF:*) tt_fail "week $WEEK_KEY is not on HR's Pending week list (listed: ${PICK#NF:}). A drafts-only week is outstanding, so it should be -- unless HR's session resolves the week start differently from the consultant's (Main.SUB_Pending_GapsForWeek matches Timesheet.StartDate with '=')." ;;
  *) tt_fail "could not read HR's Pending week list (got '$PICK')" ;;
esac
sleep 4

# The week list marks its current week with an itemClass. If the class reaches the DOM,
# require it on OUR week; if it never does, say so rather than pretend it was checked.
SEL="$(playwright-cli eval "() => { $WEEK_JS const any = items().some(i => i.classList.contains('selected')); const i = mine(); return !any ? 'NOCLASS' : (i && i.classList.contains('selected') ? 'OURS' : 'OTHER'); }" 2>/dev/null | _tt_eval_str)"
case "$SEL" in
  OURS)    echo "  ok: week $WEEK_KEY is the selected Pending week" ;;
  NOCLASS) echo "  NOTE: the week list exposes no 'selected' class, so the selection is taken on trust from the click" ;;
  *)       tt_fail "clicked week $WEEK_KEY on the Pending tab, but another week is still marked selected ($SEL)" ;;
esac

tt_gallery_load_until_text "$PENDING" "$CNAME" "Pending rows for $WEEK_KEY"

# row_state -- facts about THIS consultant's row, scoped to its gallery item.
row_state() {
  playwright-cli eval "() => {
    const rows = [...document.querySelectorAll('$PENDING .widget-gallery-item')].filter(r => ((r.querySelector('.mx-name-txtPendingConsultant') || {}).innerText || '').trim() === '$CNAME');
    if (rows.length !== 1) return 'ROWS:' + rows.length;
    const r = rows[0];
    return ['btn=' + !!r.querySelector('.mx-name-btnSubmitZeroHours'), 'tip=' + !!r.querySelector('.mx-name-tipSubmitZeroBlocked'), 'count=' + ((r.querySelector('.mx-name-txtPendingAssignments') || {}).innerText || '').trim()].join('|');
  }" 2>/dev/null | _tt_eval_str
}

# ------------------------------------------------- 1. the live button, not the look-alike
ROW="$(row_state)"
echo "  row: $ROW"
case "$ROW" in
  ROWS:*) tt_fail "expected exactly one Pending row for '$CNAME' on week $WEEK_KEY, found ${ROW#ROWS:}" ;;
  "btn=true|tip=false|"*) echo "  ok: the drafts-only row offers the live Submit 0-hour entries button" ;;
  "btn=false|tip=true|"*) tt_fail "the drafts-only row shows the BLOCKED look-alike (tipSubmitZeroBlocked), not btnSubmitZeroHours. That is the pre-TT-779 behaviour (visibility on MissingEntryCount > 0 only) -- is TT-779 deployed to this environment?" ;;
  *) tt_fail "unexpected Pending row state for '$CNAME' on week $WEEK_KEY: $ROW (want btn=true|tip=false)" ;;
esac

# ------------------------------------------------- 2 & 3. the confirmation popup
CLICK="$(playwright-cli eval "() => { const r = [...document.querySelectorAll('$PENDING .widget-gallery-item')].find(x => ((x.querySelector('.mx-name-txtPendingConsultant') || {}).innerText || '').trim() === '$CNAME'); const b = r && r.querySelector('.mx-name-btnSubmitZeroHours'); if (!b) return 'NOBTN'; b.click(); return 'CLICKED'; }" 2>/dev/null | _tt_eval_str)"
[ "$CLICK" = "CLICKED" ] || tt_fail "could not press btnSubmitZeroHours on '$CNAME's row ($CLICK)"
tt_wait_for ".mx-name-txtConfirmZeroBody" "the Submit 0-hour confirmation (Main.HR_ConfirmZeroHours)"

POP="$(playwright-cli eval "() => { const t = s => { const e = document.querySelector(s); return e && e.offsetParent !== null ? (e.innerText || '').replace(/\s+/g, ' ').trim() : '<absent>'; }; return t('.mx-name-txtConfirmZeroDrafts') + '~~' + t('.mx-name-txtConfirmZeroMissing'); }" 2>/dev/null | _tt_eval_str)"
DRAFTS="${POP%%~~*}"
MISSING="${POP#*~~}"
echo "  drafts paragraph:  $DRAFTS"
echo "  missing paragraph: $MISSING"

if [ "$DRAFTS" = "<absent>" ]; then
  playwright-cli click ".mx-name-btnConfirmZeroCancel" >/dev/null 2>&1
  tt_fail "the confirmation shows no txtConfirmZeroDrafts paragraph for a week whose outstanding item is a Draft -- DraftProjectNames is empty on the row, or the widget is missing (pre-TT-779 model?)"
fi
case "$DRAFTS" in
  *"($HOURS h)"*) echo "  ok: the drafts paragraph names the draft and its $HOURS typed hours" ;;
  *) playwright-cli click ".mx-name-btnConfirmZeroCancel" >/dev/null 2>&1
     tt_fail "txtConfirmZeroDrafts is shown but does not name a draft with '($HOURS h)' -- the hours this spec typed and the close would replace with zero. Read: '$DRAFTS'" ;;
esac
if [ "$MISSING" != "<absent>" ]; then
  playwright-cli click ".mx-name-btnConfirmZeroCancel" >/dev/null 2>&1
  tt_fail "txtConfirmZeroMissing is shown ('$MISSING'), so week $WEEK_KEY also has a MISSING entry -- it is not the drafts-only case this spec exists for, and assertions 1-2 prove nothing about TT-779. Opening the week should have created an entry for every active assignment."
fi
echo "  ok: no missing-entries paragraph -- this really is a drafts-only week"

# ------------------------------------------------- 4. Cancel leaves everything as it was
playwright-cli click ".mx-name-btnConfirmZeroCancel" >/dev/null 2>&1 \
  || tt_fail "could not press btnConfirmZeroCancel"
GONE=""
for _ in 1 2 3 4 5 6; do
  sleep 2
  GONE="$(playwright-cli eval "() => String(!document.querySelector('.mx-name-txtConfirmZeroBody'))" 2>/dev/null | _tt_eval_str)"
  [ "$GONE" = "true" ] && break
done
[ "$GONE" = "true" ] || tt_fail "the Submit 0-hour confirmation is still open after Cancel"

ROW2="$(row_state)"
case "$ROW2" in
  "btn=true|tip=false|"*) echo "  ok: after Cancel the row is still pending with its live button ($ROW2)" ;;
  *) tt_fail "after Cancel, '$CNAME's Pending row for $WEEK_KEY changed: '$ROW2' (was '$ROW'). Cancel must not submit anything." ;;
esac

echo "PASS: verify-tt779-draft-only-week-closable - a drafts-only week on HR's Pending tab offers the live 0-hour close, and its confirmation lists the draft with its typed hours"
