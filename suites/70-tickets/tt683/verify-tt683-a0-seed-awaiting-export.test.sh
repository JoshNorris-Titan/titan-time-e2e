#!/usr/bin/env bash
# TT-683 A0 — put entries into AwaitingExport so a1/a2 have something to export.
#
# ── WHY THIS FILE EXISTS ────────────────────────────────────────────────────────
# verify-tt683-a1/a2 need AwaitingExport entries, and until this file was added
# NOTHING in the suite produced any. verify-000 clears both e2e consultants, the
# TT-647 scenarios stop at ToProcess, and the TT-654 ones stop at
# Awaiting*Approval. The ToProcess -> AwaitingExport hop only happens when HR
# presses "View & Process" on a To Process card and then "Process" on the page
# that opens, and no test did that.
#
# The practical effect was that on a clean run the export tests either failed at
# "no download button appeared" or silently exported whatever NON-e2e data
# happened to be sitting in a shared dev database — so their assertions were
# running against other people's fixtures, or not running at all.
# ────────────────────────────────────────────────────────────────────────────────
#
# What it does:
#   1. processes a week already sitting on the HR To Process tab, if one holds at
#      least 2 distinct owned consultant/project pairings
#   2. if none does, seeds one: the consultant submits a whole week (one weekly
#      Submit covers every project they are assigned to, on the SAME week, which
#      is what puts several pairings in one export month), HR approves them, and
#      it processes again
#   3. asserts at least 2 distinct pairings reached AwaitingExport FROM ONE WEEK -
#      one week means one export month, and Export All exports one month
#
# Two pairings is the bar, not one: with a single pairing the headline TT-683
# assertion — one PDF per consultant/project — cannot execute at all, and a1
# would report a pass having proven only that an export produces a ZIP. This
# FAILS rather than warns for the same reason verify-tt647-a5 fails on a missing
# fixture: a green run that proves nothing is worse than a red one.
#
# DESTRUCTIVE. Processing is one-way (ToProcess -> AwaitingExport) and a1 then
# flips those to Exported. Point the suite at an environment you can consume.
#
# Env: TT_BASE_URL, TT_ROLE_PASS
# tt-timeout: 14m
#   Two paths, and the slow one decides the budget. When To Process already holds
#   owned cards this drains them in ~1m. When it does not, it submits a fresh week
#   as the consultant, approves it on BOTH HR tabs for each of three projects
#   (dual approval needs two sign-offs) and processes again - five logins and six
#   tab walks. Measured at 400-570s on the fast path; the fallback needs more.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt647.sh"
source "$TT_ROOT/lib/_tt683.sh"

CONSULTANT="${TT683_CONSULTANT:-e2e_consultant}"
# One weekly Submit submits EVERY assignment row on the week, so E2E Dual Approval
# is submitted here whether or not it is listed. Listing it means it gets approved
# on both tabs and becomes a usable pairing, instead of arriving at To Process
# half-approved and being skipped as unprocessable.
SEED_PROJECTS="${TT683_SEED_PROJECTS:-E2E Customer Approval|E2E Manager Approval|E2E Dual Approval}"

# best_week <lines> — "<n>|<week>": the week holding the most distinct
# consultant/project pairings among the drain's "<consultant>|<project>|<week>"
# lines.
#
# PER WEEK, NOT OVERALL. This used to count distinct pairings across everything
# processed, and run 34899869829 passed here with one pairing from a December week
# and one from a November week - two months, one pairing each. Export All exports
# one month, so a1 exported December and failed "only one consultant/project
# pairing was in the archive". Two pairings from one week share a month by
# construction (see tt683_process_all_toprocess), so that is what is counted.
best_week() {
  printf '%s\n' "$1" | grep . | awk -F'|' '
    NF >= 3 && !seen[$3 SUBSEP $1 SUBSEP $2]++ { n[$3]++ }
    END { m = 0; b = ""; for (w in n) if (n[w] > m) { m = n[w]; b = w }; print m "|" b }'
}

# ---------------------------------------------------------------- 1) drain ToProcess
echo "processing any To Process week that already holds 2+ owned pairings…"
PROCESSED="$(tt683_process_all_toprocess 12 week)"
BEST="$(best_week "${PROCESSED:-}")"; N="${BEST%%|*}"; WEEK="${BEST#*|}"
echo "pushed $(printf '%s\n' "${PROCESSED:-}" | grep -c .) entr(y/ies) to AwaitingExport:"
printf '%s\n' "${PROCESSED:-}" | grep . | sed 's/^/  /' || true

# ------------------------------------------------------------------- 2) top up
if [ "$N" -lt 2 ]; then
  echo "no week gave 2 pairings — seeding a fresh week as '$CONSULTANT'"

  # One weekly Submit submits EVERY assignment row on that week, so a single
  # submit seeds several consultant/project pairings in the same month. That is
  # precisely the shape TT-683 splits on.
  tt_login "$CONSULTANT" "My Timesheets"
  FIRST="${SEED_PROJECTS%%|*}"
  tt_consultant_submit_project_row "$FIRST"

  # Approve everything that landed in an approval queue. HR can stand in on both
  # stages, which keeps this independent of the PM dashboard.
  OLDIFS="$IFS"; IFS='|'
  for PROJ in $SEED_PROJECTS; do
    IFS="$OLDIFS"
    [ -n "$PROJ" ] || continue
    # TRY BOTH TABS, DO NOT STOP AT THE FIRST. A dual-approval project needs a
    # manager AND a client sign-off; breaking after one leaves the entry half
    # approved, and it then turns up on To Process with no Process action on it.
    # That is what took the whole drain down before tt683_process_one learned to
    # skip such a card. For a single-approval project the second tab simply finds
    # nothing to approve, which costs one tab check.
    for TAB in "$TT647_TAB_MANAGER" "$TT647_TAB_CLIENT"; do
      tt647_hr_open_tab "$TAB"
      if tt647_select_week_with "$PROJ" >/dev/null 2>&1; then
        if tt647_hr_approve_card "$PROJ"; then
          echo "  approved '$PROJ' on the $TAB tab"
        fi
      fi
    done
    IFS='|'
  done
  IFS="$OLDIFS"

  echo "processing the newly approved entries…"
  MORE="$(tt683_process_all_toprocess 12 week)"
  PROCESSED="$(printf '%s\n%s\n' "${PROCESSED:-}" "${MORE:-}" | grep . || true)"
  BEST="$(best_week "${PROCESSED:-}")"; N="${BEST%%|*}"; WEEK="${BEST#*|}"
  echo "now $(printf '%s\n' "${PROCESSED:-}" | grep -c .) entr(y/ies) in AwaitingExport:"
  printf '%s\n' "${PROCESSED:-}" | grep . | sed 's/^/  /' || true
fi

# ------------------------------------------------------------------ 3) assert
[ "$N" -ge 1 ] \
  || tt_fail "nothing reached AwaitingExport — the export tests have no data to work on. Check that '$CONSULTANT' has assignments on ${SEED_PROJECTS}, that HR can approve them, and that the To Process cards expose a 'View & Process' button (Main.HRDashboard btnProcessEntry)."

[ "$N" -ge 2 ] \
  || tt_fail "no single week put 2 consultant/project pairings into AwaitingExport (best: $N, week '${WEEK:-none}'). Export All exports one month, so verify-tt683-a1 cannot prove the SPLIT with pairings spread over weeks - it would pass having only shown that an export produces a ZIP. Assign '$CONSULTANT' to at least two projects (an Assignment IS the consultant+project pairing), or set TT683_SEED_PROJECTS to two projects they are on; the week lines above say where each processed entry came from."

echo "PASS: verify-tt683-a0-seed-awaiting-export — $N consultant/project pairing(s) awaiting export from week '$WEEK'"
