#!/usr/bin/env bash
# The week-status badge (txtWeekStatus) must agree with the week it describes.
#
# Why this test exists (2026-09-03): until now the consultant timesheet showed the
# week's status NOWHERE. A consultant inferred it from which buttons had vanished --
# Clear / Save / Submit are conditionally visible on Main.Timesheet.Status, so a
# submitted week rendered as a screen with no controls and no explanation.
#
# txtWeekStatus closes that gap. It is a DynamicText whose caption and whose
# dynamicClasses are two SEPARATE expressions over the same Status attribute:
#
#     Draft             -> "Draft"           / status-badge badge-draft
#     Awaiting_Approval -> "Submitted"       / status-badge badge-submitted
#     Approved          -> "Approved"        / status-badge badge-approved
#     Rejected          -> "Rejected"        / status-badge badge-rejected
#     Awaiting_Export   -> "Awaiting export" / status-badge badge-awaiting-export
#     (empty)           -> "Draft"           / status-badge badge-draft
#
# Two expressions over one attribute is the whole risk: edit one branch and forget
# the other and the badge reads "Approved" in rejected-red, which is worse than no
# badge at all. Assertion 2 is what catches that.
#
# Assertion 3 is the one that makes this test worth running. It cross-checks the NEW
# badge against an INDEPENDENT, pre-existing signal: btnSubmit's own conditional
# visibility, which the model drives from the same Status enum but through completely
# separate settings. Draft / Rejected / (empty) show the button; Awaiting_Approval /
# Approved / Awaiting_Export hide it. If the badge and the button ever disagree about
# what week this is, one of them is lying and the consultant is being misled either
# way. Nothing else in the suite can catch that -- no other test reads the badge, and
# the button visibility was previously unverified against anything.
#
# NON-DESTRUCTIVE and idempotent. It only pages between weeks and reads; it never
# types, saves or submits, so it does not consume a week from the fresh-week pool.
# That is deliberate -- verify-timesheet-locks-after-submit.test.sh already spends a
# week to prove the submit transition, and a second spender would starve whatever
# runs after it.
#
# NOTE: the same widget tree is mirrored onto Main.CreateTimesheet (HR's rewrite
# tool) -- see docs/reference/mirrored-regions.json, region "timesheetGrid". This
# spec covers the consultant copy only; the HR copy has thinner coverage by design.

set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

WEEKS_TO_SAMPLE=6

# Read the badge and the Submit button in ONE eval, so both describe the same week
# even if the page repaints between calls. Returns a pipe-delimited record:
#   <badge-present>|<text>|<classes>|<submit-present>
read_week() {
  playwright-cli eval "() => {
    const b = document.querySelector('.mx-name-txtWeekStatus');
    const submit = document.querySelector('.mx-name-btnSubmit');
    return [
      b ? 'yes' : 'no',
      b ? (b.innerText || '').trim() : '',
      b ? (b.className || '') : '',
      submit ? 'yes' : 'no'
    ].join('|');
  }" 2>/dev/null | _tt_eval_str
}

prev_week() { playwright-cli click ".mx-name-btnWeekPrev" >/dev/null 2>&1; sleep 2; }

tt_login "e2e_consultant" "My Timesheets"

# The badge lives beside txtWeekRange inside dvTimesheet. If the data view has not
# painted yet every assertion below reads an absent element and reports a confusing
# "badge missing", so settle first on a widget that is not part of this change.
for _ in $(seq 1 10); do
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-txtWeekRange'))" 2>/dev/null \
    | _tt_eval_str | grep -qiw true && break
  sleep 1
done

SAMPLED=0
SEEN_STATUSES=""

for _ in $(seq 1 "$WEEKS_TO_SAMPLE"); do
  REC="$(read_week)"
  PRESENT="${REC%%|*}"; REST="${REC#*|}"
  TEXT="${REST%%|*}";   REST="${REST#*|}"
  CLASSES="${REST%%|*}"
  SUBMIT="${REST##*|}"

  # --- Assertion 1: the badge renders at all ---------------------------------
  # Guards the plain "nobody wired it up" regression, and the subtler one where a
  # future edit drops the widget while leaving the CSS behind.
  if [ "$PRESENT" != "yes" ]; then
    tt_fail "week-status badge missing: no .mx-name-txtWeekStatus on the consultant timesheet (sampled week $((SAMPLED+1)))"
  fi

  if [ -z "$TEXT" ]; then
    tt_fail "week-status badge rendered empty: caption expression produced no text (classes='$CLASSES')"
  fi

  # It must actually be wearing the shared pill, not just be a bare span. This is
  # what proves the page adopted the theme's status vocabulary rather than
  # inventing a one-off.
  case "$CLASSES" in
    *status-badge*) : ;;
    *) tt_fail "week-status badge is not using the shared pill: expected 'status-badge' in class list, got '$CLASSES'" ;;
  esac

  # --- Assertion 2: caption and colour agree ---------------------------------
  # The two expressions are independent; this is the only thing that couples them.
  case "$TEXT" in
    "Draft")           WANT="badge-draft" ;;
    "Submitted")       WANT="badge-submitted" ;;
    "Approved")        WANT="badge-approved" ;;
    "Rejected")        WANT="badge-rejected" ;;
    "Awaiting export") WANT="badge-awaiting-export" ;;
    *) tt_fail "week-status badge shows an unmapped caption '$TEXT' — the caption expression has a branch the badge vocabulary does not (classes='$CLASSES')" ;;
  esac

  case "$CLASSES" in
    *"$WANT"*) : ;;
    *) tt_fail "week-status badge disagrees with itself: caption '$TEXT' should carry '$WANT' but classes are '$CLASSES'" ;;
  esac

  # --- Assertion 3: the badge agrees with the Submit button ------------------
  # Independent signal, same underlying enum. Editable ⟺ Draft or Rejected.
  case "$TEXT" in
    "Draft"|"Rejected") EXPECT_SUBMIT="yes" ;;
    *)                  EXPECT_SUBMIT="no" ;;
  esac

  if [ "$SUBMIT" != "$EXPECT_SUBMIT" ]; then
    if [ "$EXPECT_SUBMIT" = "yes" ]; then
      tt_fail "badge says '$TEXT' (an editable week) but btnSubmit is absent — the badge and the button disagree about this week's status"
    else
      tt_fail "badge says '$TEXT' (a locked week) but btnSubmit is present — a consultant can resubmit a week the badge calls finished"
    fi
  fi

  case "$SEEN_STATUSES" in
    *"[$TEXT]"*) : ;;
    *) SEEN_STATUSES="$SEEN_STATUSES[$TEXT]" ;;
  esac

  SAMPLED=$((SAMPLED+1))
  prev_week
done

# --- Assertion 4: the empty state is not stuck on --------------------------
# galAssignmentRows went from showEmptyPlaceholder "none" to "custom". A
# misconfigured placeholder renders permanently, underneath real rows. Only assert
# when rows are actually present, so this stays honest on a genuinely empty week.
ROWS_AND_EMPTY="$(playwright-cli eval "() => {
  const rows  = document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDaySun').length;
  const empty = document.querySelectorAll('.mx-name-containerNoAssignments').length;
  return rows + '|' + empty;
}" 2>/dev/null | _tt_eval_str)"

ROWS="${ROWS_AND_EMPTY%%|*}"
EMPTY="${ROWS_AND_EMPTY##*|}"

if [ "${ROWS:-0}" -gt 0 ] && [ "${EMPTY:-0}" -gt 0 ]; then
  tt_fail "assignment rows ($ROWS) and the empty-state placeholder are showing at the same time — galAssignmentRows' custom placeholder is rendering unconditionally"
fi

echo "PASS: week-status badge agrees with its caption, its colour and btnSubmit across $SAMPLED week(s); statuses seen: ${SEEN_STATUSES:-none}; rows=$ROWS empty-state=$EMPTY"
