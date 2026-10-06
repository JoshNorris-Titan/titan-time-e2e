#!/usr/bin/env bash
# tt-timeout: 12m
# verify-hr-export-writes-history.test.sh
#
# Every exported entry carries an "Exported" row in its change history.
# Bug-reproduction spec (bug #3): RED UNTIL THE MODEL FIX LANDS.
#
# THE BUG (scratchpad bug-verify.md #3 and gate1.md item 5, confirmed statically
# against the live model on 2026-09-28). A month's Export on HR's "Monthly to be
# invoiced" tab (btnInvoiceExportMonth -> Main.ACT_HRDashboard_ExportMonth ->
# Main.ACT_ExportAll_HRDash -> Main.SUB_ExportAll) flips each AwaitingExport entry
# to Exported. Inside the loop it creates a Main.ChangeLog
# {FromStatus=AwaitingExport, ToStatus=Exported, ChangeMethod=HR} with commit=No,
# and after the loop it commits ChangeLogList - but nothing ever ADDS the new row to
# that list, so an empty list is committed and every "Exported" history row is lost.
# Main.ChangeLog_AssignmentEntry is owned by the ChangeLog, so committing the
# entries cannot carry the log along. Its siblings commit theirs
# (ACT_ApprovalHelper_Reject, ACT_Page_Reject), so this is an omission.
#
# What a user sees: HR opens the history of an entry that was exported and the last
# row is the approval or processing step; nothing says it was exported, by whom or
# when.
#
# WHAT IT ASSERTS. Every entry of the suite's own consultants that is in status
# Exported has, in its change history, a row whose ToStatus is Exported. Nothing
# else can put an entry in Exported, and 00-setup deletes the suite's entries (and
# their history) at the start of every run, so every Exported entry this reads was
# exported by the app's Export during this run.
#
# To prove the read itself works, each failure prints the entry's whole trail: the
# earlier rows (Draft > ..., ToProcess > AwaitingExport, ...) are there and only the
# export's row is missing. A read that could not see history at all would show an
# empty trail and is reported as that, not as the bug.
#
# DATA. In a full run suites/70-tickets/tt683/a1 has already exported an all-e2e
# month by the time 75-export runs, so this only reads. Run on its own (after
# 00-setup) it produces an Exported entry itself - processes the suite's To Process
# entries and exports an all-e2e month through tt683_click_export_all, which refuses
# any month holding someone else's rows.
#
# Reads only in a full run. Standalone it CONSUMES the To Process / AwaitingExport
# entries it exports.
#
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt683.sh"
source "$TT_ROOT/lib/_changelog.sh"

fails=0
bad() { echo "  FAILED: $*"; fails=$((fails+1)); }

# heh_read — the suite's Exported entries with their history, as HR.
heh_read() {
  tt_login "e2e_hr" "$TT_HR_READY"
  tt_cl_entries "$(tt_cl_e2e_constraint Exported)"
}

ROWS="$(heh_read)"
case "$ROWS" in ERR:*) tt_fail "could not read the Exported entries and their history as HR ($ROWS)" ;; esac

if [ -z "$ROWS" ]; then
  echo "no Exported e2e entry yet - processing To Process and exporting an all-e2e month to make one"
  # Each step in a subshell: the tt683 helpers end in tt_fail when a tab has nothing
  # for them, and here that is an outcome to report below, not a reason to exit
  # before saying why.
  ( tt683_process_all_toprocess 6 ) >/dev/null
  if ( tt683_open_export_tab >/dev/null && tt683_click_export_all ); then
    sleep 5
    tt_clear_dialogs 8 >/dev/null
  else
    echo "  (the export step did not complete - see the read below)"
  fi
  ROWS="$(heh_read)"
  case "$ROWS" in ERR:*) tt_fail "could not read the Exported entries and their history as HR ($ROWS)" ;; esac
  [ -n "$ROWS" ] || tt_fail "no e2e entry is in status Exported, and processing + exporting an all-e2e month did not produce one, so this step has no verdict. suites/70-tickets/tt683/verify-tt683-a0 and -a1 are what put e2e entries there in a full run."
fi

checked=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  who="$(tt_cl_field "$line" 2)"; proj="$(tt_cl_field "$line" 3)"; wk="$(tt_cl_field "$line" 4)"
  trail="$(tt_cl_field "$line" 8)"
  checked=$((checked+1))
  if [ -z "$trail" ]; then
    bad "$who / $proj / week $wk: Exported, but NO history row at all was readable - not even its submit or approval rows. That is a read problem (entity access on Main.ChangeLog for HR?), not evidence for or against the export row."
  elif tt_cl_trail_has "$trail" "*" "Exported"; then
    echo "  ok   $who / $proj / week $wk: history ends ... ${trail##*;}"
  else
    bad "$who / $proj / week $wk is Exported but its history has no row into Exported (bug #3: Main.SUB_ExportAll never adds NewChangeLog to ChangeLogList, so the export's AwaitingExport > Exported row is never committed). Its history reads: $trail"
  fi
done <<< "$ROWS"

[ "$checked" -gt 0 ] || tt_fail "read $checked Exported entries - nothing was checked"

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-hr-export-writes-history - $fails of $checked exported entr(y/ies) carry no 'Exported' history row"
  exit 1
fi
echo "PASS: verify-hr-export-writes-history - all $checked exported e2e entr(y/ies) record the export in their history"
