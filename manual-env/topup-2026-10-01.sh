#!/usr/bin/env bash
# One-off top-up of the Manual data set on dev (2026-10-01), so the tickets finished since
# Sep 10 each have data to look at. Fills only the gaps the probe found; it does not
# clear anything. Usage: TT_BASE_URL=... TT_ROLE_PASS=... manual-env/topup-2026-10-01.sh [consultants|hr|all]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${TT_BASE_URL:?set TT_BASE_URL}"; : "${TT_ROLE_PASS:?set TT_ROLE_PASS}"
export SEED_PASS="$TT_ROLE_PASS"
export SEED_HR_USER=manual_hr
export SEED_NAMES="Manual Consultant|Manual Consultant Two|Manual Consultant Three"
export SEED_CONSULTANTS="manual_consultant|manual_consultant2|manual_consultant3"
export SEED_PLAN_FILE="${SEED_PLAN_FILE:-$HERE/.topup-plan.txt}"
export SEED_EXPORT_MONTHS="${SEED_EXPORT_MONTHS:-Jul|Aug}"
# user | week | stage | pattern. The four export rows are weeks that are already
# submitted: the consultant pass skips them and records them for the HR pass, which
# approves and processes what is left in them and exports July and August only.
export SEED_WEEK_PLAN="manual_consultant|Sep 13 - Sep 19|submit|lines
manual_consultant|Sep 20 - Sep 26|approve_mgr|weekend
manual_consultant|Sep 27 - Oct 03|draft|part
manual_consultant|Jul 19 - Jul 25|export|none
manual_consultant|Jul 26 - Aug 01|export|none
manual_consultant|Aug 02 - Aug 08|export|none
manual_consultant|Aug 09 - Aug 15|export|none
manual_consultant2|Sep 06 - Sep 12|approve_all|full40
manual_consultant2|Sep 20 - Sep 26|submit|uneven
manual_consultant2|Sep 27 - Oct 03|draft|part
manual_consultant3|Sep 06 - Sep 12|approve_all|full40"
case "${1:-all}" in
  consultants) SEED_SKIP_HR=1 bash "$HERE/../seeders/seed-regression-ladder.sh" ;;
  hr)          SEED_SKIP_SUBMIT=1 bash "$HERE/../seeders/seed-regression-ladder.sh" ;;
  all)         bash "$HERE/../seeders/seed-regression-ladder.sh" ;;
esac
