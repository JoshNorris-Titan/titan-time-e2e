#!/usr/bin/env bash
# An administrator sees "Reports" in the top menu and can open both reports behind it.
#
# tt-timeout: 6m
#
# WHY THIS EXISTS. Reports belong to the Titan Manager, HR and the administrator.
# The 2026-10-02 "bugfixes" commit (TT-762) took Main.Administrator off the Reports
# hub (Main.Reports). Mendix shows a page menu item only to roles allowed to open the
# page, so the "Reports" item disappeared from the administrator's menu. Nothing
# noticed for two weeks: the three report specs in 50-titan-manager all sign in as
# e2e_tm, so they could not tell. The grant came back on 2026-10-15 after a user
# report. This spec makes losing it again a red run.
#
# THE ACCOUNT MUST BE ADMINISTRATOR-ONLY FOR THIS TO MEAN ANYTHING. An account that
# also holds HR or TitanManager reaches Reports through that role whatever the hub's
# grant says, so the spec reads the session's roles first and fails, rather than
# passing on a question it never asked, when either is present.
#
# WHAT IT ASSERTS
#   A. the administrator session holds neither HR nor TitanManager;
#   B. "Reports" is in the top menu and opens the hub (cardReportMonthlyHours and
#      cardReportOnProject both present);
#   C. the Monthly Hours card opens its report (cbMonth), and Back returns to the hub;
#   D. the Assignment Report card opens its roster (lstRoster).
#
# NON-DESTRUCTIVE: opening the two reports creates only their own selection/helper
# objects, which each report deletes and rebuilds on every open.
# Env: TT_BASE_URL, TT_ADMIN_USER, TT_ADMIN_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"

ADMIN="${TT_ADMIN_USER:-MxAdmin}"
ev()  { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }
has() { [ "$(ev "() => String(!!document.querySelector('$1'))")" = "true" ]; }

tt_login "$ADMIN" "Welcome to your homepage" "${TT_ADMIN_PASS:-${TT_PASS:-}}"

# ------------------------------------------------------------------ A. the session
ROLES="$(tt_authz_roles)"
echo "  $ADMIN session roles: ${ROLES:-none}"
[ -n "$ROLES" ] && [ "$ROLES" != "null" ] || tt_fail "A: could not read $ADMIN's session roles, so whether this measures the administrator grant is unknown"
case "$ROLES" in
  *'"HR"'*|*'"TitanManager"'*)
    tt_fail "A: $ADMIN also holds HR or TitanManager ($ROLES), so it reaches Reports through that role and this spec would prove nothing about the administrator. Point TT_ADMIN_USER at an administrator-only account." ;;
esac

# ------------------------------------------------------------------ B. menu and hub
for _ in 1 2 3; do
  tt_try_click_text "Reports"
  sleep 2
  has ".mx-name-cardReportMonthlyHours" && break
done
has ".mx-name-cardReportMonthlyHours" || tt_fail "B: $ADMIN cannot reach the Reports hub from the top menu. Check that Main.Reports still allows Main.Administrator: the menu item shows only to roles allowed to open the page"
has ".mx-name-cardReportOnProject"    || tt_fail "B: the Reports hub opened for $ADMIN but has no Assignment Report card (cardReportOnProject)"
echo "  B ok: Reports is in $ADMIN's menu and opens the hub"

# ------------------------------------------------------------------ C. Monthly Hours
playwright-cli click ".mx-name-cardReportMonthlyHours" >/dev/null 2>&1
tt_wait_for ".mx-name-cbMonth" "the Monthly Hours report (cbMonth) as $ADMIN"
playwright-cli click ".mx-name-btnBack" >/dev/null 2>&1
tt_wait_for ".mx-name-cardReportOnProject" "the Reports hub after Back from Monthly Hours"
echo "  C ok: Monthly Hours opens for $ADMIN, and Back returns to the hub"

# ------------------------------------------------------------------ D. Assignment Report
playwright-cli click ".mx-name-cardReportOnProject" >/dev/null 2>&1
tt_wait_for ".mx-name-lstRoster" "the Assignment Report roster (lstRoster) as $ADMIN"
echo "  D ok: the Assignment Report opens for $ADMIN"

echo "PASS: verify-admin-reaches-reports - an administrator-only session sees Reports in the menu and opens the hub, Monthly Hours and the Assignment Report"
