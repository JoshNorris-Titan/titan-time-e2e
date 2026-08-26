#!/usr/bin/env bash
# TT-652 angle 2 — every PDF in the archive is named to the agreed standard.
#
#   {yyyy}-{MMdd of month END}-{Last First}-{Project}.pdf
#   e.g. 2026-0630-Urech Thomas-Interstates Gizmo.pdf
#
# Four dash-separated groups; last and first joined by a space. Built by
# Main.SUB_BuildTimesheetFileName, which reuses Core.SUB_Account_Name's
# FullName -> Email -> role-name -> 'User' chain and then swaps to "Last First".
# ZipHandling.ZipDocuments takes each entry name from the FileDocument's Name,
# so the archive's entry names ARE these filenames.
#
# The highest-risk assertion is the DAY. Main.MonthlyHelper/MonthEnd is an
# UNLOCALIZED DateTime, so the filename must be built with formatDateTimeUTC.
# Plain formatDateTime renders in the session timezone and would turn a June
# month-end into 2026-0629 in America/Chicago. Step 4 catches exactly that.
#
# Reuses the archive verify-tt683-a1 already downloaded when it is still in the
# shared browser session (the runner keeps one session across scripts, and
# closing the popup is a client-side close, not a reload). Otherwise it drives a
# fresh export, which consumes another batch of AwaitingExport entries.
#
# Runs unchanged on localhost, dev and acceptance: no admin port, no OQL.
# DESTRUCTIVE only when it has to run its own export.
#
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt683.sh"

TT683_ZIP_ERR=""

# Prefer the archive a1 already parsed.
ENTRIES="$(playwright-cli eval "() => (window.__ttZip||[]).join('\\n')" 2>/dev/null | _tt_eval_str | grep . || true)"

if [ -n "$ENTRIES" ]; then
  echo "reusing the archive captured by verify-tt683-a1"
else
  echo "no archive in the session — driving a fresh export"
  TAB="$(tt683_open_export_tab)" || tt_fail "could not reach the HR tab that owns Export All (its own message is above)"
  echo "export lives on tab: $TAB"
  tt683_click_export_all
  CAPTION="$(tt683_zip_button_caption)"
  [ -n "$CAPTION" ] || tt_fail "no download button appeared in the popup within 30s"
  ENTRIES="$(tt683_download_zip_entries)" \
    || tt_fail "could not read the downloaded archive: ${TT683_ZIP_ERR:-unknown error}"
fi

[ -n "$ENTRIES" ] || tt_fail "no archive entries to check"

CHECKED=0
while IFS= read -r filename; do
  [ -n "$filename" ] || continue
  echo "checking: $filename"

  # 1) Overall shape.
  case "$filename" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]-*-*.pdf) : ;;
    *) tt_fail "'$filename' does not match {yyyy}-{MMdd}-{Last First}-{Project}.pdf. 'TEST.pdf' or 'Timesheet.pdf' here means SUB_PDFGenReturn fell back because PDFMonthHelper/FileName was empty." ;;
  esac

  YYYY="${filename%%-*}"
  REST="${filename#*-}"
  MMDD="${REST%%-*}"
  MM="${MMDD:0:2}"
  DD="${MMDD:2:2}"

  # 2) The name group must be "Last First" — a space, not a dash. A dash here
  #    means the group boundaries are wrong, not just the separator.
  NAMEPART="${filename#"$YYYY-$MMDD-"}"
  NAMEPART="${NAMEPART%.pdf}"
  NAMEPART="${NAMEPART%%-*}"
  [ -n "$NAMEPART" ] || tt_fail "'$filename' has an empty name group"
  case "$NAMEPART" in
    *\ *) : ;;
    *) echo "  NOTE: name group '$NAMEPART' has no space — expected for a single-word name or an email fallback from Core.SUB_Account_Name" ;;
  esac

  # 3) A project group must be present after the name.
  PROJECTPART="${filename#"$YYYY-$MMDD-$NAMEPART-"}"
  PROJECTPART="${PROJECTPART%.pdf}"
  [ -n "$PROJECTPART" ] \
    || tt_fail "'$filename' has no project group after the consultant name"

  # 4) The day must be the LAST day of the month — the formatDateTimeUTC check.
  tt683_is_month_end "$YYYY" "$MM" "$DD"
  case "$?" in
    0) : ;;
    2) tt_fail "could not evaluate month-end for $YYYY-$MM-$DD (GNU date required)" ;;
    *) tt_fail "'$filename' uses $YYYY-$MM-$DD, which is NOT the last day of $YYYY-$MM. This is the formatDateTime/formatDateTimeUTC timezone slip — Main.SUB_BuildTimesheetFileName must use formatDateTimeUTC because MonthlyHelper/MonthEnd is unlocalized." ;;
  esac

  CHECKED=$((CHECKED + 1))
done <<EOF
$ENTRIES
EOF

[ "$CHECKED" -ge 1 ] || tt_fail "no filenames were checked"

echo "PASS: verify-tt683-a2-filename-standard — $CHECKED filename(s) match {yyyy}-{MMdd month-end}-{Last First}-{Project}.pdf"
