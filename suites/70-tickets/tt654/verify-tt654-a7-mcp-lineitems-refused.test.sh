#!/usr/bin/env bash
# TT-654 A7 — MCP SubmitWeek refuses a line-items project, and does not submit it.
#
# Main.ACT_MCP_SubmitWeek guards the branch it cannot serve:
#   if $Entry/NeedsLineItems then
#     return '{"error":"This project requires line items, which cannot be entered
#              over MCP yet. Please finish and submit this entry in the Titan Time app."}'
# Line items cannot be entered over MCP, so submitting such a week would send an
# entry for approval with no task breakdown — silently wrong rather than noisy.
#
# The refusal was implemented and then never asserted anywhere; verify-tt654-a4
# only exercises the customer-approval project. Without this test, deleting the
# guard breaks nothing that the suite would notice.
#
# Asserts:
#   1. SubmitWeek on the line-items project returns an error mentioning line items
#   2. the entry is STILL editable afterwards — i.e. the guard returned BEFORE
#      calling Main.SUB_AssignmentEntry_Submit, rather than reporting an error
#      after already submitting
#   3. the same week submits fine for a NON-line-items project, so (1) is the
#      guard firing and not SubmitWeek being broken for everything
#
# Consumes the week it seeds for the non-line-items project.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt654.sh"

LI_PROJ="$TT654_PROJECT_LINEITEMS"
OK_PROJ="$TT654_PROJECT_CUSTOMER"

tt_login "$TT654_CONSULTANT" "My Timesheets"

# --- seed a Draft week that carries BOTH projects -------------------------
# One weekly Save Draft covers every assignment row on that week, so the guard
# and the control case are compared on identical data.
tt654_find_editable_row "$LI_PROJ"
WEEK="$TT654_WEEK"
WEEK_START="$TT654_WEEK_START"
LI_ORD="$TT654_ORD"
tt654_fill_row "$LI_ORD" "$TT654_HOURS"
tt654_add_task "$LI_ORD" "TT654 A7 Task" "$TT654_HOURS" >/dev/null

OK_ORD="$(tt654_row_ordinal "$OK_PROJ")"
[ -n "$OK_ORD" ] && [ "$OK_ORD" != "0" ] \
  || tt_fail "'$OK_PROJ' has no editable row on the same week as '$LI_PROJ' — without a control case a refusal here cannot be distinguished from SubmitWeek simply not working"
tt654_fill_row "$OK_ORD" "$TT654_HOURS"

tt654_save_draft
[ -n "$WEEK_START" ] \
  || tt_fail "could not parse a yyyy-MM-dd week start from '$WEEK' — the MCP tools need one"
echo "seeded '$LI_PROJ' and '$OK_PROJ' on $WEEK_START ($WEEK)"

TOKEN="$(tt654_mint_token)"
[ -n "$TOKEN" ] || tt_fail "could not mint an MCP token"

# --- 1) the guard fires ----------------------------------------------------
OUT="$(tt654_mcp_call "$TOKEN" SubmitWeek "{ProjectName:'$LI_PROJ',WeekStartDate:'$WEEK_START',ConfirmWarnings:true}")"
echo "SubmitWeek('$LI_PROJ'): ${OUT:0:200}"

case "$OUT" in
  *'"result":"SUBMITTED"'*)
    tt_fail "MCP SUBMITTED a line-items week — Main.ACT_MCP_SubmitWeek's NeedsLineItems guard did not fire, so an entry went for approval with no task breakdown" ;;
  *'"error"'*) : ;;
  *) tt_fail "SubmitWeek on '$LI_PROJ' returned neither a result nor an error (got: ${OUT:0:300})" ;;
esac

# The wording matters: any error would satisfy the check above, including
# "expected exactly one assignment entry", which would mean the test never
# reached the guard at all.
case "$OUT" in
  *"line items"*|*"line item"*) echo "1. refused with the line-items message" ;;
  *) tt_fail "SubmitWeek refused '$LI_PROJ' but not because of line items (got: ${OUT:0:300}) — the guard under test was not the thing that fired" ;;
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

# --- 3) control: the same call works on a non-line-items project -----------
SUB="$(tt654_mcp_call "$TOKEN" SubmitWeek "{ProjectName:'$OK_PROJ',WeekStartDate:'$WEEK_START',ConfirmWarnings:true}")"
case "$SUB" in
  *'"result":"SUBMITTED"'*) echo "3. control: '$OK_PROJ' submitted normally on the same week" ;;
  *) tt_fail "the control project '$OK_PROJ' did not submit either (got: ${SUB:0:300}) — so step 1 does not prove the line-items guard, it may just be SubmitWeek failing" ;;
esac

echo "PASS: verify-tt654-a7-mcp-lineitems-refused — MCP refuses line-items weeks without submitting them ($WEEK_START)"
