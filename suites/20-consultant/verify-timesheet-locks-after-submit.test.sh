#!/usr/bin/env bash
# Day-cell editability is driven by the STORED AssignmentEntry._IsEditable column.
#
# Why this test exists (2026-08-24): _IsEditable used to be a CALCULATED attribute,
# recomputed on every read, so it could never disagree with Status. It is now a
# STORED column, written only by the Before Commit handler
# Main.SUB_AssignmentEntry_SetIsEditable. Every timesheet surface reads that column,
# including SNIP_Timesheet, which binds day-cell editability to it.
#
# That swap created two new failure modes the UI can show and no other test catches:
#
#   1. FLAG NEVER WRITTEN — on an environment where the backfill has not run, every
#      pre-existing row reads false and NOTHING is editable, even Drafts. The
#      positive control below is what catches that.
#   2. FLAG GOES STALE — an entry is submitted but the column still says true, so the
#      consultant can keep typing into a timesheet that is already awaiting approval.
#      The post-submit assertion is what catches that.
#
# The re-fetch between submit and assert is load-bearing: it forces a server re-read,
# so a pass proves the DATABASE column changed, not just the client-side object.
#
# Mutating and not idempotent — it submits a week, consuming one editable week for
# whatever runs after it. The filename sorts LAST inside 20-consultant on purpose, so
# the draft-only CRUD test still gets an editable week to work with.

set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

DAYS="Mon Tues Wed Thurs Fri Sat Sun"

# How many of the seven day inputs in row 1 are locked (disabled or readOnly)?
locked_count() {
  local n=0 d v
  for d in $DAYS; do
    v=$(playwright-cli eval "() => { const i=document.querySelector('.mx-name-txtDay${d} input'); return String(i ? !!(i.disabled||i.readOnly) : 'absent'); }" 2>/dev/null | sed -n '2p')
    v="${v%\"}"; v="${v#\"}"
    [ "$v" = "true" ] && n=$((n+1))
  done
  echo "$n"
}

refetch_week() {
  playwright-cli click ".mx-name-btnWeekPrev" >/dev/null 2>&1; sleep 2
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1; sleep 3
}

tt_login "e2e_consultant" "My Timesheets"

# --- Positive control: a Draft week must be editable -------------------------
# If the backfill never ran on this environment, _IsEditable is false everywhere
# and this loop exhausts without finding an editable week.
found=""
for _ in $(seq 1 10); do
  if playwright-cli eval "() => { const i=document.querySelector('.mx-name-txtDayMon input'); const ed=i && !i.disabled && !i.readOnly; return String(!!ed && !!document.querySelector('.mx-name-btnSubmit')); }" 2>/dev/null | sed -n '2p' | grep -qiw true; then
    found=1; break
  fi
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
  sleep 2
done
[ -n "$found" ] || tt_fail "no editable week with a Submit button in the next 10 weeks. If EVERY week is locked, the stored AssignmentEntry._IsEditable column is false app-wide — the migration AssignmentEntry_IsEditable_Backfill has probably not run on this environment (it runs from Core.ASU_OnStartup on first boot)."

WEEK=$(playwright-cli eval "() => String((document.querySelector('.mx-name-txtWeekRange')||{}).innerText||'')" 2>/dev/null | sed -n '2p')
WEEK="${WEEK%\"}"; WEEK="${WEEK#\"}"

BEFORE="$(locked_count)"
[ "$BEFORE" = "0" ] || tt_fail "a Draft week ($WEEK) has $BEFORE of 7 day cells already locked before submit — the stored _IsEditable column disagrees with the entry's Draft status"
echo "before submit: 0 of 7 day cells locked ($WEEK)"

# --- Submit, then prove the flag refreshed in the DATABASE -------------------
tt_consultant_submit_entry || true
sleep 2
refetch_week

AFTER="$(locked_count)"
[ "$AFTER" = "7" ] || tt_fail "after submitting $WEEK and re-fetching, only $AFTER of 7 day cells are locked. The stored AssignmentEntry._IsEditable column did not refresh on commit, so a submitted entry is still editable — see Core.UT_SUB_SetIsEditable_RefreshesWhenStatusLeavesDraft for the model-layer version of this assertion."

echo "PASS: day cells editable while Draft and all 7 locked after submit, across a server re-fetch ($WEEK)"
