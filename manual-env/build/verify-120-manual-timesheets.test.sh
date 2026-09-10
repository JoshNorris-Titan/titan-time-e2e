#!/usr/bin/env bash
# Manual environment, step 3 of 3: seed timesheets across every reachable status.
#
# tt-timeout: 150m
#
# WHAT IT DOES
# ------------
# Drives seeders/seed-regression-ladder.sh — the existing ladder seeder — against the
# Manual accounts instead of the E2E ones. The ladder assigns a STAGE to each of the most
# recent seedable weeks and pushes it there, so the finished environment carries a spread
# rather than a pile of drafts:
#
#   export       -> Exported                     SENT tab
#   process      -> AwaitingExport               MONTHLY TO BE INVOICED
#   approve_all  -> ToProcess                    WEEKLY TO PROCESS
#   approve_mgr  -> AwaitingCustomerApproval     CLIENT APPROVAL
#   submit       -> AwaitingManagerApproval      MANAGER APPROVAL
#   reject       -> Rejected                     back with the consultant
#   draft        -> Draft                        PENDING
#   empty        -> nothing, week left at zero
#
# That is the whole reason a reviewer wants a seeded environment at all: every dashboard
# tab has something on it, and each approval shape (manager-only, customer-only, dual,
# line items) is represented because the projects behind those weeks differ.
#
# WHY THE SEEDER IS DRIVEN RATHER THAN COPIED
# -------------------------------------------
# Same argument as verify-110. The ladder encodes rules that were each paid for by a
# failure: hours must be multiples of 0.25 and a day's cross-project total must stay under
# 24; an over-40 week cannot be persisted at all (Consultant_OverWeeklyHours blocks SAVE,
# not just Submit) so it is not a seedable state; the empty week is transient because
# SCE_Timesheet_CleanupEmptyDrafts deletes zero-hour drafts with no age threshold; a
# submitted week's day boxes lock, so a re-run must skip it rather than report a failure.
# A Manual-only copy would lose all of that the first time one of them changed.
#
# It is parameterised entirely through SEED_* environment variables, so nothing about the
# E2E behaviour changes: every default in the seeder still names the e2e_* accounts.
#
# THE SEEDER ALWAYS EXITS 0 — SO THIS STEP ASSERTS AFTERWARDS
# -----------------------------------------------------------
# seed-regression-ladder.sh logs its problems and finishes with "done" whatever happened,
# by design: it is a data builder that would rather seed nine weeks and name the tenth
# than abort halfway. That makes its exit code useless as a verdict, so this step reads
# the result back through the data API and judges it.
#
# It judges the STATUS SPREAD, not the row count. A run that submitted every week and then
# failed to sign in as manual_hr produces plenty of rows, all in one status, and is exactly
# the outcome that must not report PASS — the HR half is where half the review value is.
# MANUAL_MIN_STATUSES is a FLOOR, not the ladder's full output: the seeder legitimately
# skips a stage when a week is not seedable, and demanding all seven would make this red
# for a reason nobody should have to chase. Four distinct statuses across the consultants
# cannot be reached by the consultant half alone, which is the property being bought here.
#
# BUDGET, MEASURED 2026-09-10 on cloud dev.
#
# The first attempt was killed by the machine part-way through the consultant phase, having
# seeded 40 entries for two of the three consultants. The RESUME then took 2137s (~36m) and
# finished everything: it skipped the already-submitted weeks, seeded the third consultant
# from scratch, and ran the whole HR phase. So a cold run is more than 2137s and less than
# the sum of the two, i.e. roughly 45-60 minutes.
#
# 150m therefore has real headroom rather than guessed headroom, and it is deliberately
# not trimmed to the measurement: the HR phase walks every seeded week across five stages,
# so its cost scales with how much the consultant phase produced, and a cold Mendix Cloud
# start adds minutes before anything is seeded at all.
#
# THE RESUME IS THE INTERESTING NUMBER. This step is re-runnable precisely because the
# seeder skips weeks that are already submitted (their day boxes lock once an entry leaves
# Draft), so a killed run is resumed rather than repeated. If this step ever fails for an
# environmental reason, run it again before investigating anything.
#
# RE-RUNNABLE. Weeks that are already submitted are skipped by the seeder rather than
# refilled, so kicking the build off again after a partial failure resumes rather than
# duplicating.
#
# Env:
#   TT_BASE_URL          REQUIRED
#   TT_MANUAL_PASS       manual_* password, defaults to TT_ROLE_PASS
#   MANUAL_MIN_STATUSES  distinct-status floor for the whole data set (default 4)
#   MANUAL_SKIP_SEED=1   skip the seeder and only assert what is already there
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test works
# at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/manual-env/manual.env.sh"

[ -n "${TT_BASE_URL:-}" ] \
  || tt_fail "TT_BASE_URL must be set explicitly — this submits, approves and exports real timesheets"

MIN_STATUSES="${MANUAL_MIN_STATUSES:-4}"

# ---------------------------------------------------------------- who gets seeded
#
# Derived from MANUAL_ASSIGNMENTS, not retyped. A consultant with no assignment renders no
# rows in any week, so seeding them is a no-op and asserting on them would fail for a
# reason that is a deliberate property of the table (see 'Manual Consultant Three' there).
# Reading the table means uncommenting that row is all it takes to include them.
SEED_NAME_LIST=""
for row in "${MANUAL_ASSIGNMENTS[@]}"; do
  who="$(printf '%s' "$row" | cut -d'|' -f1)"
  case "|$SEED_NAME_LIST|" in *"|$who|"*) continue ;; esac
  SEED_NAME_LIST="${SEED_NAME_LIST:+$SEED_NAME_LIST|}$who"
done
[ -n "$SEED_NAME_LIST" ] || tt_fail "MANUAL_ASSIGNMENTS is empty — there is no consultant with an assignment to seed"

# manual_user_for <full name> — the login that owns that consultant card.
manual_user_for() {
  local r
  for r in "${MANUAL_ACCOUNTS[@]}"; do
    case "$r" in *"|$1|"*) printf '%s' "${r%%|*}"; return 0 ;; esac
  done
  return 1
}

SEED_USER_LIST=""
OLD_IFS="$IFS"; IFS='|'
for n in $SEED_NAME_LIST; do
  IFS="$OLD_IFS"
  u="$(manual_user_for "$n")" \
    || tt_fail "MANUAL_ASSIGNMENTS names consultant '$n', but no row in MANUAL_ACCOUNTS has that full name — the two tables have drifted apart"
  SEED_USER_LIST="${SEED_USER_LIST:+$SEED_USER_LIST|}$u"
  IFS='|'
done
IFS="$OLD_IFS"

manual_log "seeding timesheets for: $SEED_NAME_LIST"

# ---------------------------------------------------------------- seed
if [ "${MANUAL_SKIP_SEED:-0}" = "1" ]; then
  manual_log "MANUAL_SKIP_SEED=1 — not running the ladder, asserting on existing data only"
else
  # SEED_NAMES is what the HR half uses to decide which CARDS on the shared dashboard
  # belong to us, and it must never widen: those tabs carry other people's live dev data,
  # and approving a stranger's timesheet is not recoverable from a test script. It is the
  # same list as the consultants being seeded, exact-matched by the seeder.
  #
  # SEED_PLAN_FILE is pointed away from the seeder's /tmp default on purpose: a leftover
  # E2E plan there would send the Manual HR pass at E2E weeks.
  SEED_CONSULTANTS="$SEED_USER_LIST" \
  SEED_NAMES="$SEED_NAME_LIST" \
  SEED_HR_USER="manual_hr" \
  SEED_PLAN_FILE="${TMPDIR:-/tmp}/tt-manual-seed-plan.txt" \
    bash "$TT_ROOT/seeders/seed-regression-ladder.sh" 2>&1 | sed 's/^/    /'
fi

# ---------------------------------------------------------------- assert
#
# Read as each consultant IN THEIR OWN SESSION. They can always retrieve their own rows,
# which keeps this free of any assumption about what another role is allowed to see —
# the same reasoning fx_entry_count records.
TOTAL_ROWS=0
ALL_STATUSES=""
REPORT=""

OLD_IFS="$IFS"; IFS='|'
for n in $SEED_NAME_LIST; do
  IFS="$OLD_IFS"
  u="$(manual_user_for "$n")"
  tt_login "$u" "My Timesheets"

  spread="$(manual_status_spread "$n")"
  case "$spread" in
    ERR:*) tt_fail "could not read '$n' entries back through the data API ($spread) — the seeding result is unverifiable, so this step cannot report PASS" ;;
    "")    tt_fail "'$n' has NO timesheet entries after seeding. Check the run log above: the likeliest causes are an assignment window that does not span the weeks the seeder walked, or a login that never reached 'My Timesheets'." ;;
  esac

  manual_log "$n: $spread"
  REPORT="$REPORT
    $n: $spread"

  for pair in $spread; do
    st="${pair%%:*}"; ct="${pair##*:}"
    TOTAL_ROWS=$((TOTAL_ROWS + ct))
    case " $ALL_STATUSES " in *" $st "*) : ;; *) ALL_STATUSES="${ALL_STATUSES:+$ALL_STATUSES }$st" ;; esac
  done
  IFS='|'
done
IFS="$OLD_IFS"

DISTINCT=0
for st in $ALL_STATUSES; do DISTINCT=$((DISTINCT + 1)); done

if [ "$DISTINCT" -lt "$MIN_STATUSES" ]; then
  tt_fail "the Manual data set landed in only $DISTINCT distinct status(es) ($ALL_STATUSES), below the floor of $MIN_STATUSES.$REPORT
      That normally means the HR half of the ladder never ran — check the log above for
      \"cannot sign in as manual_hr\" or \"no seeded plan\". Statuses beyond Draft and
      AwaitingManagerApproval are only reachable through it, and they are what puts
      something on the CLIENT APPROVAL, WEEKLY TO PROCESS, MONTHLY TO BE INVOICED and
      SENT tabs."
fi

echo "PASS: verify-120-manual-timesheets — $TOTAL_ROWS entries across $DISTINCT statuses ($ALL_STATUSES)$REPORT"
