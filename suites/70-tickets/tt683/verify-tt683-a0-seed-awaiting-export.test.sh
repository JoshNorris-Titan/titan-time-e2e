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
# The seed rows: "<project>:<approval tab>[,<tab>]". Each project listed gets
# 40 hours on ONE week and one Submit, then is approved on the tab(s) named.
#
# HOURS ON EVERY LISTED ROW. One weekly Submit closes every assignment row on the
# week, but it used to fill hours on the FIRST project only. The rest went in at
# zero hours, and a zero-hour entry skips approval and goes straight to To
# Process (the status rule is "if TotalHours = 0 then ToProcess"). So the loop
# below sat polling approval tabs for cards that could never appear: on dev on
# 2026-10-26 the only approval it made was the first project's, and the step
# overran its 14 minutes. Read off dev afterwards: one 40h entry, three 0h.
#
# THE TAB IS NAMED, NOT SEARCHED. Trying both tabs for every project costs a
# failed wait per project. A dual-approval project (manager then client) can still
# be seeded as "E2E Dual Approval:manager,client".
SEED_ROWS="${TT683_SEED_ROWS:-E2E Customer Approval:client|E2E Manager Approval:manager}"

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
  SEED_PROJECTS=()
  OLDIFS="$IFS"; IFS='|'
  for ROW in $SEED_ROWS; do [ -n "$ROW" ] && SEED_PROJECTS+=("${ROW%%:*}"); done
  IFS="$OLDIFS"
  tt_consultant_submit_project_row "${SEED_PROJECTS[@]}"

  # Approve each seeded row on the tab(s) its spec names. HR can stand in on both
  # stages, which keeps this independent of the PM dashboard.
  #
  # THE SUBMITTED WEEK ONLY. This used to walk every week the tab offers until
  # one mentioned the project (tt647_select_week_with). On dev each tab offers
  # 17+ weeks, and each walked week is a select plus a full card load. The submit
  # recorded the week in TT_SUBMITTED_WEEK; pin it, and give the asynchronous
  # routing a few polls to land the card.
  IFS='|'
  for ROW in $SEED_ROWS; do
    IFS="$OLDIFS"
    [ -n "$ROW" ] || continue
    PROJ="${ROW%%:*}"; TABS="${ROW#*:}"
    IFS=','
    for T in $TABS; do
      IFS="$OLDIFS"
      case "$T" in
        manager) TAB="$TT647_TAB_MANAGER" ;;
        client)  TAB="$TT647_TAB_CLIENT" ;;
        *) tt_fail "TT683_SEED_ROWS: '$ROW' names tab '$T'; use manager and/or client" ;;
      esac
      tt647_hr_open_tab "$TAB"
      if tt647_wait_for_card "$TT_SUBMITTED_WEEK" "$PROJ" "" 5 && tt647_hr_approve_card "$PROJ"; then
        echo "  approved '$PROJ' on the $TAB tab"
      else
        echo "  could not approve '$PROJ' on the $TAB tab: ${TT647_WAIT_ERR:-${TT647_APPROVE_ERR:-unknown}}"
      fi
      IFS=','
    done
    IFS='|'
  done
  IFS="$OLDIFS"

  echo "processing the newly approved entries…"
  # Only the week just seeded: every other week was already walked in step 1.
  MORE="$(tt683_process_all_toprocess 12 week "$TT_SUBMITTED_WEEK")"
  PROCESSED="$(printf '%s\n%s\n' "${PROCESSED:-}" "${MORE:-}" | grep . || true)"
  BEST="$(best_week "${PROCESSED:-}")"; N="${BEST%%|*}"; WEEK="${BEST#*|}"
  echo "now $(printf '%s\n' "${PROCESSED:-}" | grep -c .) entr(y/ies) in AwaitingExport:"
  printf '%s\n' "${PROCESSED:-}" | grep . | sed 's/^/  /' || true
fi

# ------------------------------------------------------------------ 3) assert
[ "$N" -ge 1 ] \
  || tt_fail "nothing reached AwaitingExport — the export tests have no data to work on. Check that '$CONSULTANT' has assignments on the projects in TT683_SEED_ROWS (${SEED_ROWS}), that HR can approve them, and that the To Process cards expose a 'View & Process' button (Main.HRDashboard btnProcessEntry)."

[ "$N" -ge 2 ] \
  || tt_fail "no single week put 2 consultant/project pairings into AwaitingExport (best: $N, week '${WEEK:-none}'). Export All exports one month, so verify-tt683-a1 cannot prove the SPLIT with pairings spread over weeks - it would pass having only shown that an export produces a ZIP. Assign '$CONSULTANT' to at least two projects (an Assignment IS the consultant+project pairing), or set TT683_SEED_ROWS to two projects they are on; the week lines above say where each processed entry came from."

echo "PASS: verify-tt683-a0-seed-awaiting-export — $N consultant/project pairing(s) awaiting export from week '$WEEK'"
