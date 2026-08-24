#!/usr/bin/env bash
# READ-ONLY preflight for the data seeders. Changes nothing; answers the questions that
# have historically killed a seeding run AFTER an hour of work had already been spent.
#
# NOT named *.test.sh: it reports rather than asserts, and must not be swept up by
# `mxcli playwright verify tests/`.
#
# Run this FIRST, every time, especially after a data wipe or an environment change:
#   TT_BASE_URL=https://... bash tests/seed-shakedown.sh
#
# It answers, in order of how cheaply they can kill the plan:
#   1. Is the app up, and is playwright-cli healthy?
#   2. How expensive is one browser round-trip? (budgets the whole run)
#   3. Do the admin and e2e logins actually work on THIS environment?
#   4. Do week navigation and click-registration behave?
#   5. WHICH WEEKS CAN HOLD DATA AT ALL — the "Projects: N" question. A week where no
#      assignment's date window applies renders zero rows and can never be seeded.
#   6. What does the HR dashboard currently hold?
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib/_login.sh
source tests/lib/_seed.sh

if [ -z "${TT_BASE_URL:-}" ]; then
  echo "FAIL: set TT_BASE_URL explicitly — a seeding preflight must not guess an environment." >&2
  exit 1
fi

CONSULTANTS="${SEED_CONSULTANTS:-e2e_consultant|e2e_consultant2|e2e_consultant3}"
PROBLEMS=0
note_problem() { PROBLEMS=$((PROBLEMS + 1)); echo "  ** $*"; }

echo "=============================================================="
echo " SEED SHAKEDOWN — $TT_BASE_URL"
echo "=============================================================="

# ---------------------------------------------------------------- 1. reachability
echo
echo "[1] app reachability"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 25 "$TT_BASE_URL/login.html" 2>/dev/null || echo 000)"
echo "  GET /login.html -> HTTP $CODE"
case "$CODE" in
  200|302) : ;;
  *) note_problem "app not reachable — everything below will fail"; echo; echo "RESULT: NO-GO"; exit 1 ;;
esac

if ! command -v playwright-cli >/dev/null 2>&1; then
  note_problem "playwright-cli is not on PATH"
  echo; echo "RESULT: NO-GO"; exit 1
fi

# ------------------------------------------------------------- 2. round-trip cost
#
# Everything about the seeder's runtime follows from this number. At ~4s/call a single
# consultant-week costs ~90 calls ≈ 6 minutes of pure process spawning, which is why the
# design returns compact JSON blobs instead of asking several small questions.
echo
echo "[2] browser round-trip cost"
playwright-cli close >/dev/null 2>&1; sleep 1
playwright-cli open "$TT_BASE/" >/dev/null 2>&1
sleep 6
T0=$(date +%s)
for _ in 1 2 3; do pw "() => 1" >/dev/null; done
T1=$(date +%s)
PERCALL=$(( (T1 - T0) / 3 ))
echo "  ~${PERCALL}s per eval  (3 calls in $((T1 - T0))s)"
[ "$PERCALL" -gt 8 ] && note_problem "round-trips are very slow; a full run will take hours"

# --------------------------------------------------------------------- 3. logins
echo
echo "[3] logins"
if seed_login_admin "Admin Hub"; then
  echo "  admin '$SEED_ADMIN_USER': OK  (session=$(seed_whoami))"
  ADMIN_OK=1
else
  note_problem "admin '$SEED_ADMIN_USER' could NOT sign in — admin overviews unavailable"
  ADMIN_OK=0
fi

OLD="$IFS"; IFS='|'
for U in $CONSULTANTS; do
  IFS="$OLD"
  [ -n "$U" ] || continue
  if seed_login_role "$U" "My Timesheets"; then
    echo "  consultant '$U': OK  (session=$(seed_whoami))"
  else
    note_problem "consultant '$U' could NOT sign in — it cannot be seeded"
  fi
  IFS='|'
done
IFS="$OLD"

if seed_login_role "e2e_hr" "WEEKLY TO PROCESS"; then
  echo "  hr 'e2e_hr': OK  (session=$(seed_whoami))"
  HR_OK=1
else
  note_problem "'e2e_hr' could NOT sign in — no approval/process/export stage is possible"
  HR_OK=0
fi

# ------------------------------------------------ 4/5. seedable weeks per consultant
#
# THE MOST IMPORTANT SECTION. "Projects: 0" means no active assignment spans that week,
# so it renders no rows and cannot hold seeded data no matter what the seeder does.
echo
echo "[4] seedable weeks per consultant  (label | projects | hours)"
OLD="$IFS"; IFS='|'
for U in $CONSULTANTS; do
  IFS="$OLD"
  [ -n "$U" ] || continue
  echo
  echo "  --- $U ---"
  if ! seed_login_role "$U" "My Timesheets"; then
    note_problem "$U: cannot sign in; skipping week probe"
    IFS='|'; continue
  fi
  sleep 2
  CAP="$(seed_week_caption)"
  ROWS="$(seed_open_rows)"
  echo "    current week: '$CAP'   rows: ${ROWS:-none}"
  [ -n "$ROWS" ] || note_problem "$U: current week renders NO assignment rows"

  LIST="$(seed_week_list)"
  if [ -z "$LIST" ]; then
    note_problem "$U: timesheet history gallery is empty — cannot resolve weeks"
  else
    SEEDABLE=$(printf '%s\n' "$LIST" | awk -F'|' '$2 != "0" && $2 != "?"' | wc -l | tr -d ' ')
    echo "    weeks offered: $(printf '%s\n' "$LIST" | wc -l | tr -d ' ')   with rows: $SEEDABLE"
    printf '%s\n' "$LIST" | head -10 | sed 's/^/      /'
    [ "$SEEDABLE" -lt 1 ] && note_problem "$U: NO week has rows — nothing can be seeded for this consultant"
  fi

  # click-registration probe: jump to the 2nd offered week and confirm the caption moved
  TARGET="$(printf '%s\n' "$LIST" | sed -n '2p' | cut -d'|' -f1)"
  if [ -n "$TARGET" ]; then
    if seed_goto_week "$TARGET"; then
      echo "    navigation probe: jumped to '$TARGET' OK"
    else
      note_problem "$U: could not navigate to '$TARGET' — clicks may not be registering"
    fi
  fi
  IFS='|'
done
IFS="$OLD"

# ------------------------------------------------------------------ 6. HR dashboard
echo
echo "[5] HR dashboard"
if [ "${HR_OK:-0}" = "1" ] && seed_login_role "e2e_hr" "WEEKLY TO PROCESS"; then
  sleep 2
  echo "  KPIs (pending manager client process invoice sent): $(seed_kpis)"
  for TAB in "MANAGER APPROVAL" "CLIENT APPROVAL" "WEEKLY TO PROCESS" "MONTHLY TO BE INVOICED" "SENT"; do
    if seed_click_tab "$TAB"; then
      W="$(seed_tab_weeks)"
      echo "    $TAB -> weeks: ${W:-none}"
    else
      note_problem "HR tab '$TAB' is not clickable"
    fi
  done
else
  echo "  skipped (no HR login)"
fi

playwright-cli close >/dev/null 2>&1

echo
echo "=============================================================="
if [ "$PROBLEMS" -eq 0 ]; then
  echo " RESULT: GO — environment looks seedable"
else
  echo " RESULT: $PROBLEMS problem(s) found above — resolve before seeding"
fi
echo "=============================================================="
exit 0
