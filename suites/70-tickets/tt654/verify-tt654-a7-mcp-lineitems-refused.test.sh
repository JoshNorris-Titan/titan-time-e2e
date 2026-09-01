#!/usr/bin/env bash
# TT-654 A7 — MCP SubmitWeek refuses a line-items week that has NO tasks, and
# does not submit it; adding the task it asks for then lets the same call through.
#
# ── WHAT THIS TEST USED TO ASSERT, AND WHY IT CHANGED ───────────────────────────
# This test was written against a BLANKET refusal: Core.ACT_MCP_SubmitWeek was
# said to reject any NeedsLineItems project outright, with
#   {"error":"This project requires line items, which cannot be entered over MCP
#    yet. Please finish and submit this entry in the Titan Time app."}
# because line items could not be entered over MCP at all.
#
# They can now. Core.ACT_MCP_SetLineItem and Core.ACT_MCP_DeleteLineItem exist
# (with Core.ACT_MCP_CreateWeek), and the guard was narrowed to match. The split
# is captioned "Needs tasks but has none?" and its condition is
#   $Entry/NeedsLineItems and $LineItemCount = 0
# so what is refused is a line-items week with nothing on it, not the project.
# The error now names the remedy: "Add them with SetLineItem, then submit again."
#
# The old shape of this test seeded a task through the UI and THEN expected a
# refusal, so it failed the moment the narrowing landed: SubmitWeek correctly
# returned SUBMITTED and the assertion read that as the guard being gone. Two
# traced runs against cloud dev (2026-09-01) reproduced exactly that.
#
# Note the flow lives in Core, not Main — the old header called it
# Main.ACT_MCP_SubmitWeek throughout, which matches nothing in the model.
# ────────────────────────────────────────────────────────────────────────────────
#
# Asserts:
#   1. SubmitWeek on a line-items week with no tasks returns an error that names
#      tasks/line items — not merely "an error", which would also be satisfied by
#      "expected exactly one assignment entry", i.e. by never reaching the guard
#   2. the entry is STILL editable afterwards — the guard returned BEFORE calling
#      Main.SUB_AssignmentEntry_Submit, rather than reporting an error after
#      already submitting
#   3. SetLineItem adds the task the refusal asked for
#   4. the SAME SubmitWeek call then succeeds — so (1) is the guard firing and not
#      SubmitWeek being broken for this project. This replaces the old control
#      case, which needed a second project editable on the same week; same-project
#      before/after is a tighter control and one less precondition to satisfy.
#
# The guard is checked ahead of the warning branch, so ConfirmWarnings has no
# bearing on step 1. It is passed anyway, so step 4 does not stop at
# NOT_SUBMITTED on an in-progress week (see Core.ACT_MCP_SubmitWeek's notes on
# TT-710).
#
# Consumes the week it seeds.

# tt-timeout: 8m
#   Measured at 144s and 152s against Mendix Cloud dev on a week found with 0 and
#   1 steps of the hunt. tt654_find_editable_row will step up to 12 weeks looking
#   for an editable line-items row, at ~12s each, and on a full-suite run the near
#   weeks are already consumed by a0/a3. At the 4m default that overrun lands as a
#   bare TIMEOUT instead of the helper's own "no editable week ... found within 12
#   weeks", which is the one message that would explain it. Same reason a3 asks
#   for 8m.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt654.sh"

LI_PROJ="$TT654_PROJECT_LINEITEMS"

tt_login "$TT654_CONSULTANT" "My Timesheets"

# --- seed a Draft week on the line-items project, with NO tasks -------------
# Deliberately no hours and no Add Task: the aggregate day cells are read-only on
# a NeedsLineItems row (hours roll up from the tasks), and an empty task list is
# the precondition step 1 is about. Save Draft is still needed so the
# AssignmentEntry is committed and the MCP tools can find it.
tt654_find_editable_row "$LI_PROJ"
WEEK="$TT654_WEEK"
WEEK_START="$TT654_WEEK_START"

# An unnamed LineItem left behind by an earlier interrupted test blocks the save
# for the WHOLE week (Main.LineItem.Name is a required validation), which would
# surface here as a seeding failure rather than as the debris it is.
tt654_assert_no_unnamed_tasks
tt654_save_draft

[ -n "$WEEK_START" ] \
  || tt_fail "could not parse a yyyy-MM-dd week start from '$WEEK' — the MCP tools need one"
echo "seeded '$LI_PROJ' with no tasks on $WEEK_START ($WEEK)"

TOKEN="$(tt654_mint_token)"
[ -n "$TOKEN" ] || tt_fail "could not mint an MCP token"

# --- 1) the guard fires on a week with no tasks ----------------------------
OUT="$(tt654_mcp_call "$TOKEN" SubmitWeek "{ProjectName:'$LI_PROJ',WeekStartDate:'$WEEK_START',ConfirmWarnings:true}")"
echo "SubmitWeek('$LI_PROJ', no tasks): ${OUT:0:200}"

case "$OUT" in
  *'"result":"SUBMITTED"'*)
    tt_fail "MCP SUBMITTED a line-items week with no tasks — Core.ACT_MCP_SubmitWeek's 'Needs tasks but has none?' guard did not fire, so an entry went for approval with no task breakdown" ;;
  *'"error"'*) : ;;
  *) tt_fail "SubmitWeek on '$LI_PROJ' returned neither a result nor an error (got: ${OUT:0:300})" ;;
esac

# The wording matters: any error would satisfy the check above, including
# "expected exactly one assignment entry", which would mean the test never
# reached the guard at all.
case "$OUT" in
  *"line item"*|*"tasks"*) echo "1. refused, naming tasks/line items" ;;
  *) tt_fail "SubmitWeek refused '$LI_PROJ' but not because of missing tasks (got: ${OUT:0:300}) — the guard under test was not the thing that fired" ;;
esac

# --- 2) refusing must not have submitted anyway ----------------------------
WK="$(tt654_mcp_call "$TOKEN" GetMyWeek "{WeekStartDate:'$WEEK_START'}")"
case "$WK" in
  *"$LI_PROJ"*) : ;;
  *) tt_fail "GetMyWeek($WEEK_START) no longer lists '$LI_PROJ' (got: ${WK:0:300})" ;;
esac
# The entry must still be editable — Draft/Rejected. If the guard ran after the
# submit rather than before it, this flips to false.
case "$WK" in
  *'"editable":true'*) echo "2. the line-items entry is still editable — the guard returned before submitting" ;;
  *) tt_fail "'$LI_PROJ' is no longer editable after a REFUSED SubmitWeek — the entry was submitted and then reported as an error (got: ${WK:0:300})" ;;
esac

# --- 3) do what the refusal asked for --------------------------------------
SET="$(tt654_mcp_call "$TOKEN" SetLineItem "{ProjectName:'$LI_PROJ',WeekStartDate:'$WEEK_START',TaskName:'TT654 A7 Task',Sunday:0,Monday:8,Tuesday:8,Wednesday:8,Thursday:8,Friday:8,Saturday:0}")"
case "$SET" in
  *'"result":"OK"'*) echo "3. SetLineItem added the task: ${SET:0:160}" ;;
  *) tt_fail "SetLineItem did not add a task to '$LI_PROJ' on $WEEK_START (got: ${SET:0:300}) — step 4 cannot distinguish the guard from a broken SubmitWeek without it" ;;
esac

# --- 4) the same call now goes through -------------------------------------
SUB="$(tt654_mcp_call "$TOKEN" SubmitWeek "{ProjectName:'$LI_PROJ',WeekStartDate:'$WEEK_START',ConfirmWarnings:true}")"
case "$SUB" in
  *'"result":"SUBMITTED"'*) echo "4. with a task present, the same SubmitWeek submitted: ${SUB:0:160}" ;;
  *) tt_fail "'$LI_PROJ' still did not submit after SetLineItem added a task (got: ${SUB:0:300}) — so step 1 does not prove the missing-tasks guard, SubmitWeek may be refusing this project for another reason" ;;
esac

echo "PASS: verify-tt654-a7-mcp-lineitems-refused — MCP refuses a task-less line-items week without submitting it, and accepts it once SetLineItem fills one in ($WEEK_START)"
