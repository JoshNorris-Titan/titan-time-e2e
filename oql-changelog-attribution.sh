#!/usr/bin/env bash
# ChangeLog attribution check — LOCAL F5 ONLY, not part of the Playwright suite.
#
# ── WHY THIS IS NOT A verify-*.test.sh ──────────────────────────────────────────
# The suite runner picks up verify-*.test.sh. This file is deliberately named
# outside that pattern because it CANNOT run where the suite runs: it needs the
# M2EE admin port, which a local F5 exposes and Mendix Cloud does not.
#
# Writing it as a suite test would mean either failing every dev/acceptance run,
# or skipping silently — and a silent skip reads as "covered" when nothing was
# checked. So it is an explicit, manual local check instead. Run it after an F5
# when you have touched any flow that writes Main.ChangeLog.
# ────────────────────────────────────────────────────────────────────────────────
#
# What it checks, and why it matters:
#
# Commit 4701e3f0 hardened Main.ChangeLog attribution in three flows —
#   Main.ACT_Timesheet_Draft      (Save)             now sets ChangeBy + FromStatus
#   Main.ACT_Timesheet_Submit     (weekly Submit)    creates the row BEFORE the
#                                                    status change and patches
#                                                    ToStatus after, so FromStatus
#                                                    is the real prior status
#   Main.SUB_Timesheet_BlankForHR (HR blanks a week) now sets ChangeBy
#
# None of that is visible in the UI, so no Playwright test can assert it. It is
# not cosmetic: Main.SUB_ApprovalHelper_SetApprovalLines (TT-647) reads ChangeBy
# and FromStatus off these rows to build the "Approved by … on …" sentences, and
# a blank ChangeBy renders an approval line with a missing name.
#
# Usage:
#   TT_ADMIN_PORT=8090 TT_ADMIN_TOKEN='<admin password>' ./oql-changelog-attribution.sh
#
# Admin port and password come from Studio Pro:
#   App Settings -> Configurations -> Server.

set -uo pipefail

MPR="${TT_MPR:-Titan Timee.mpr}"
HOST="${TT_ADMIN_HOST:-localhost}"
PORT="${TT_ADMIN_PORT:-}"
TOKEN="${TT_ADMIN_TOKEN:-}"

fail() { echo "FAIL: $*"; exit 1; }

[ -n "$PORT" ] && [ -n "$TOKEN" ] \
  || fail "TT_ADMIN_PORT and TT_ADMIN_TOKEN must be set. This check only works against a local F5 run (App Settings -> Configurations -> Server for the admin port and password); there is no cloud equivalent."

oql() {
  mxcli oql --direct --host "$HOST" --port "$PORT" --token "$TOKEN" --json "$1" 2>&1
}

echo "== querying Main.ChangeLog on $HOST:$PORT =="

# 1) Nothing recent should be missing its author. ChangeBy is a plain string, so
#    an unattributed row is either empty or absent rather than an error.
BLANK="$(oql "SELECT COUNT(*) AS n FROM Main.ChangeLog WHERE ChangeBy = '' OR ChangeBy = NULL")"
echo "rows with no ChangeBy: $BLANK"
case "$BLANK" in
  *'"n":0'*|*'"n": 0'*) echo "  OK — every ChangeLog row is attributed" ;;
  *Error*|*error*)      fail "OQL query failed: $BLANK" ;;
  *) echo "  WARN — some rows have no ChangeBy. Pre-fix rows are expected to; check whether any were written AFTER this build:"
     oql "SELECT createdDate, ChangeMethod, FromStatus, ToStatus FROM Main.ChangeLog WHERE ChangeBy = '' OR ChangeBy = NULL ORDER BY createdDate DESC LIMIT 10" ;;
esac

# 2) The GAP-1 fix: a submit row must not record its own destination as its
#    origin. FromStatus = ToStatus is the signature of a row written before the
#    status change without the later patch (or of the old ACT_AssignmentEntryChangeStatus
#    no-op).
SAME="$(oql "SELECT COUNT(*) AS n FROM Main.ChangeLog WHERE FromStatus = ToStatus")"
echo "rows where FromStatus = ToStatus: $SAME"
case "$SAME" in
  *'"n":0'*|*'"n": 0'*) echo "  OK — no self-transitions logged" ;;
  *) echo "  WARN — self-transitions present (legacy rows may predate the fix):"
     oql "SELECT createdDate, ChangeBy, ChangeMethod, FromStatus, ToStatus FROM Main.ChangeLog WHERE FromStatus = ToStatus ORDER BY createdDate DESC LIMIT 10" ;;
esac

# 3) The line-items branch of Main.SUB_AssignmentEntry_Submit writes
#    ChangeLog.LineItems. verify-tt654-a3 drives that branch through the UI but
#    cannot see the field, so this is where it gets confirmed.
echo "== most recent line-item change logs =="
oql "SELECT createdDate, ChangeBy, ChangeMethod, FromStatus, ToStatus, LineItems FROM Main.ChangeLog WHERE LineItems <> '' ORDER BY createdDate DESC LIMIT 5"
echo "  (expect a non-empty LineItems string on the entry verify-tt654-a3 resubmitted)"

echo "== recent rows, newest first =="
oql "SELECT createdDate, ChangeBy, ChangeMethod, FromStatus, ToStatus FROM Main.ChangeLog ORDER BY createdDate DESC LIMIT 15"

echo
echo "Read the output above — this script reports, it does not gate. The two"
echo "counts are the assertions; the listings are there to tell a legacy row"
echo "from one this build just wrote."
