#!/usr/bin/env bash
# TT-654 A4 — the MCP tools themselves, end to end.
#
# The actual feature. Everything else in the TT-654 suite covers supporting UI;
# this drives the four tools an MCP client would call. It runs them from the
# browser (same origin as the app) so the whole thing stays inside the normal
# Playwright harness instead of needing a separate curl rig.
#
# Asserts, in order:
#   1. a bogus token is rejected                (auth actually gates the tools)
#   2. a minted token lists all four tools      (server registered them)
#   3. ListMyAssignments returns real projects  (entity access + JSON shape)
#   4. GetMyWeek reports the seeded Draft week  (date parsing, week matching)
#   5. SetWeekHours writes and totals correctly (write path + recalc)
#   6. GetMyWeek reflects the write             (it really persisted)
#   7. SubmitWeek submits                       (shared submit flow)
#   8. SetWeekHours/SubmitWeek then refuse      (guards live in the shared sub,
#                                                so MCP cannot bypass them)
#
# Seeds its own Draft week and consumes it by submitting. Uses the CUSTOMER
# approval project, so the expected end status is AwaitingCustomerApproval.
#
# Requires the week caption to parse into yyyy-MM-dd. If it does not, the test
# says so rather than guessing a date and reporting a misleading pass.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt654.sh"

PROJ="$TT654_PROJECT_CUSTOMER"

tt_login "$TT654_CONSULTANT" "My Timesheets"

# --- seed a Draft week for this project -----------------------------------
tt654_find_editable_row "$PROJ"
WEEK="$TT654_WEEK"
WEEK_START="$TT654_WEEK_START"
tt654_fill_row "$TT654_ORD" "$TT654_HOURS"
tt654_save_draft
[ -n "$WEEK_START" ] || tt_fail "could not parse a yyyy-MM-dd week start from '$WEEK' — the MCP tools need one, so this test cannot assert against the seeded week"
echo "seeded '$PROJ' on $WEEK_START ($WEEK)"

# --- mint a token ----------------------------------------------------------
TOKEN="$(tt654_mint_token)"
[ -n "$TOKEN" ] || tt_fail "could not mint an MCP token from the dashboard"
echo "token: ${TOKEN:0:8}…"

# 1. auth is enforced
BAD="$(tt654_mcp_tools "not-a-real-token")"
case "$BAD" in
  *AUTHFAIL*) echo "1. bogus token rejected" ;;
  *NOSESSION*) tt_fail "MCP endpoint did not return a session — is TT654_MCP_PATH ('$TT654_MCP_PATH') right for this environment?" ;;
  *) tt_fail "bogus token was NOT rejected (got '$BAD') — the MCP tools are unauthenticated" ;;
esac

# 2. all four tools registered
TOOLS="$(tt654_mcp_tools "$TOKEN")"
for t in ListMyAssignments GetMyWeek SetWeekHours SubmitWeek; do
  case "$TOOLS" in *"$t"*) ;; *) tt_fail "tool '$t' missing from tools/list (got '$TOOLS')" ;; esac
done
echo "2. tools/list: $TOOLS"

# 3. ListMyAssignments sees the project
ASSIGN="$(tt654_mcp_call "$TOKEN" ListMyAssignments "{}")"
case "$ASSIGN" in
  *"$PROJ"*) echo "3. ListMyAssignments includes '$PROJ'" ;;
  *) tt_fail "ListMyAssignments did not include '$PROJ' (got: ${ASSIGN:0:300})" ;;
esac

# 4. GetMyWeek sees the seeded Draft entry
WK="$(tt654_mcp_call "$TOKEN" GetMyWeek "{WeekStartDate:'$WEEK_START'}")"
case "$WK" in
  *"$PROJ"*) ;;
  *) tt_fail "GetMyWeek($WEEK_START) did not include '$PROJ' (got: ${WK:0:300})" ;;
esac
case "$WK" in
  *'"editable":true'*) echo "4. GetMyWeek shows '$PROJ' editable" ;;
  *) tt_fail "GetMyWeek says '$PROJ' is not editable, so the seed did not leave it in Draft (got: ${WK:0:300})" ;;
esac

# 5. SetWeekHours writes 0/8/8/8/8/4/0 = 36
SET="$(tt654_mcp_call "$TOKEN" SetWeekHours "{ProjectName:'$PROJ',WeekStartDate:'$WEEK_START',Sunday:0,Monday:8,Tuesday:8,Wednesday:8,Thursday:8,Friday:4,Saturday:0}")"
case "$SET" in
  *'"totalHours":36'*) echo "5. SetWeekHours totalled 36" ;;
  *) tt_fail "SetWeekHours did not report 36 hours (got: ${SET:0:300})" ;;
esac

# 6. and it really persisted
WK2="$(tt654_mcp_call "$TOKEN" GetMyWeek "{WeekStartDate:'$WEEK_START'}")"
case "$WK2" in
  *'"friday":4'*) echo "6. GetMyWeek reflects the write" ;;
  *) tt_fail "GetMyWeek does not show the hours SetWeekHours wrote (got: ${WK2:0:300})" ;;
esac

# 7. SubmitWeek submits
SUB="$(tt654_mcp_call "$TOKEN" SubmitWeek "{ProjectName:'$PROJ',WeekStartDate:'$WEEK_START',ConfirmWarnings:true}")"
case "$SUB" in
  *'"result":"SUBMITTED"'*) echo "7. SubmitWeek: $SUB" ;;
  *) tt_fail "SubmitWeek did not submit (got: ${SUB:0:400})" ;;
esac

# 8. guards hold afterwards — these live inside Main.SUB_AssignmentEntry_Submit
#    and the resolution/editability checks in the tools, so MCP cannot bypass
#    what the page enforces.
AGAIN="$(tt654_mcp_call "$TOKEN" SubmitWeek "{ProjectName:'$PROJ',WeekStartDate:'$WEEK_START',ConfirmWarnings:true}")"
case "$AGAIN" in
  *'"error"'*) ;;
  *) tt_fail "re-submitting an already-submitted week was allowed (got: ${AGAIN:0:300})" ;;
esac
EDIT="$(tt654_mcp_call "$TOKEN" SetWeekHours "{ProjectName:'$PROJ',WeekStartDate:'$WEEK_START',Sunday:0,Monday:99,Tuesday:0,Wednesday:0,Thursday:0,Friday:0,Saturday:0}")"
case "$EDIT" in
  *'"error"'*) echo "8. re-submit and post-submit edit both refused" ;;
  *) tt_fail "editing an already-submitted week was allowed (got: ${EDIT:0:300})" ;;
esac

# and the refusal did not quietly write anyway
WK3="$(tt654_mcp_call "$TOKEN" GetMyWeek "{WeekStartDate:'$WEEK_START'}")"
case "$WK3" in
  *'"monday":99'*) tt_fail "the refused edit still wrote 99 hours — the guard reports but does not protect" ;;
  *) echo "   refused edit left the hours untouched" ;;
esac

echo "PASS: MCP tools end to end — auth, discovery, read, write, submit, guards ($WEEK_START)"
