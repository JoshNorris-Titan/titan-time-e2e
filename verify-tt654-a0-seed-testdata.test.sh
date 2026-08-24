#!/usr/bin/env bash
# TT-654 A0 — seed DRAFT timesheet data for MCP testing.
#
# Not really an assertion test: this is the data setup the rest of TT-654 needs.
# It leaves editable Draft entries that can then be driven either through the
# timesheet page or through the MCP tools (GetMyWeek / SetWeekHours / SubmitWeek),
# and it prints the week start in yyyy-MM-dd — exactly the format those tools take.
#
# Seeds all three approval shapes on ONE week where possible, because the
# consultant timesheet shows one row per active assignment, so a single week
# covers every project the consultant is on:
#   - customer-approval project  -> exercises AwaitingCustomerApproval
#   - manager-approval project   -> exercises AwaitingManagerApproval
#   - line-items project         -> exercises the NeedsLineItems branch of
#                                   Main.SUB_AssignmentEntry_Submit, and the
#                                   MCP SubmitWeek refusal for such projects
#
# Everything is left in DRAFT (Save Draft, never Submit). Submitting consumes a
# week, so re-run this before any test or MCP pass that submits.
#
# Writes tests/.tt654-seed.env with the seeded week so later steps can source it.

set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"
source "$(dirname "$0")/lib/_tt654.sh"

OUT="$(dirname "$0")/.tt654-seed.env"

tt_login "$TT654_CONSULTANT" "My Timesheets"

# Anchor on the line-items project: it is the most constrained (the consultant
# must be assigned to a NeedsLineItems project) and it is the branch with no
# coverage today. The other two are seeded on the same week if they are editable
# there, which they normally are.
tt654_find_editable_row "$TT654_PROJECT_LINEITEMS"
WEEK="$TT654_WEEK"
WEEK_START="$TT654_WEEK_START"
LI_ORD="$TT654_ORD"
echo "seeding week: ${WEEK:-<unknown>}  (start ${WEEK_START:-<unparsed>})"

SEEDED=""
SKIPPED=""

# Line-items row: hours + one task.
tt654_fill_row "$LI_ORD" "$TT654_HOURS"
TASK_IDX="$(tt654_add_task "$LI_ORD" "TT654 Task" "$TT654_HOURS")"
echo "  seeded '$TT654_PROJECT_LINEITEMS' (row $LI_ORD, task #$TASK_IDX)"
SEEDED="$TT654_PROJECT_LINEITEMS"

# The other two projects on the same week, if they have an editable row here.
for PROJ in "$TT654_PROJECT_CUSTOMER" "$TT654_PROJECT_MANAGER"; do
  ORD="$(tt654_row_ordinal "$PROJ")"
  if [ -n "$ORD" ] && [ "$ORD" != "0" ]; then
    tt654_fill_row "$ORD" "$TT654_HOURS"
    echo "  seeded '$PROJ' (row $ORD)"
    SEEDED="$SEEDED|$PROJ"
  else
    echo "  SKIPPED '$PROJ' — no editable row on this week"
    SKIPPED="$SKIPPED|$PROJ"
  fi
done

tt654_save_draft

# Prove the draft actually persisted rather than just sitting in the inputs:
# step away and back, which re-queries the week from the server.
playwright-cli click ".mx-name-btnWeekPrev" >/dev/null 2>&1; sleep 2
playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1; sleep 3

RE_ORD="$(tt654_row_ordinal "$TT654_PROJECT_LINEITEMS")"
[ -n "$RE_ORD" ] && [ "$RE_ORD" != "0" ] \
  || tt_fail "after re-fetch the '$TT654_PROJECT_LINEITEMS' row is gone or not editable — the draft did not persist"

MON=$(playwright-cli eval "() => String((document.querySelectorAll('$TT654_ROWS .mx-name-txtDayMon input')[$RE_ORD - 1]||{}).value || '')" 2>/dev/null | sed -n '2p' | tr -d '"')
case "$MON" in
  *"$TT654_HOURS"*) echo "draft persisted across re-fetch (Mon=$MON)" ;;
  *) tt_fail "draft did not persist (wrote $TT654_HOURS, re-fetched '$MON')" ;;
esac

{
  echo "# written by verify-tt654-a0-seed-testdata.test.sh"
  echo "TT654_SEEDED_WEEK_START=\"$WEEK_START\""
  echo "TT654_SEEDED_WEEK=\"$WEEK\""
  echo "TT654_SEEDED_PROJECTS=\"${SEEDED#|}\""
  echo "TT654_SKIPPED_PROJECTS=\"${SKIPPED#|}\""
} > "$OUT"

echo ""
echo "wrote $OUT"
if [ -n "$WEEK_START" ]; then
  echo "MCP tools can target this week with WeekStartDate=\"$WEEK_START\""
else
  echo "NOTE: could not parse a yyyy-MM-dd week start from '$WEEK' —"
  echo "      pass the Sunday of that week to the MCP tools manually."
fi
echo "PASS: seeded DRAFT timesheet data (${SEEDED#|})"
