#!/usr/bin/env bash
# TT-800: a project manager can open both reports, sees every project on them, can
# export, and cannot edit, save or archive an assignment from the report.
#
# tt-timeout: 6m
#
# THE CHANGE (TT-800). Main.Reports, Main.Report_OnProject and Main.Report_MonthlyHours
# allow Main.ProjectManager, as do the thirteen report flows behind their filters,
# sorts, row open/close and exports. ACT_Report_Row_Edit / _Save / _Cancel /
# _SaveDates and ACT_Assignment_Archive do NOT, so their buttons are not rendered for
# a PM. A new read-only, unconstrained ProjectManager rule on Main.Assignment lets the
# roster list assignments on projects the PM does not manage - before it, a PM could
# only read assignments on their own projects.
#
# WHAT IT ASSERTS (non-destructive, e2e_pm)
#   A. the session holds ProjectManager and none of HR / TitanManager / Administrator,
#      so a pass below is the PM grant and not an elevated role;
#   B. the top bar's Reports item opens the hub, and both cards are on it;
#   C. the On Project roster lists at least one row whose project e2e_pm does NOT
#      manage - the "see all projects" half of the ticket;
#   D. no Edit, Save, Cancel or Archive button is rendered on the roster, and the row
#      date pickers are not editable;
#   E. Export to Excel runs for a PM: the session's own ReportExport is replaced by a
#      new one (SUB_ReportExport_Download deletes the caller's old export and creates
#      a fresh one), and no error dialog comes up;
#   F. the Monthly Hours report opens (cbMonth and its row list render) with no error.
#
# Unproven until TT-800 is deployed to the target and this has run there.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"

PM="${TT_PM_A:-e2e_pm}"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }
dialog_text() { ev "() => { const d=$(_tt_dialog_js); return d ? (d.innerText||'').replace(/\\s+/g,' ').trim() : ''; }"; }
present() { ev "() => String(document.querySelectorAll('$1').length)"; }

tt_login "$PM" "Project Manager Dashboard"

# ------------------------------------------------------------------ A. the role
ROLES="$(tt_authz_roles)"
case "$ROLES" in *'"ProjectManager"'*) ;; *) tt_fail "A: '$PM' does not hold ProjectManager ($ROLES)" ;; esac
case "$ROLES" in
  *'"HR"'*|*'"TitanManager"'*|*'"Administrator"'*) tt_fail "A: '$PM' also holds an elevated role ($ROLES), so a pass would not prove the PM grant" ;;
esac
note "A ok: roles $ROLES"

# ------------------------------------------------------------------ B. the hub
for _ in 1 2 3; do
  tt_try_click_text "Reports"
  sleep 2
  [ "$(present '.mx-name-cardReportOnProject')" != "0" ] && break
done
[ "$(present '.mx-name-cardReportOnProject')" != "0" ] || tt_fail "B: the Reports item did not open the hub for '$PM' (no cardReportOnProject) - is TT-800 deployed?"
[ "$(present '.mx-name-cardReportMonthlyHours')" != "0" ] || bad "B: the hub has no cardReportMonthlyHours for '$PM'"
note "B ok: the Reports hub opens with both cards"

# ------------------------------------------------------------------ C. all projects
MINE="$(ev "() => new Promise(res => { mx.data.get({ xpath: \"//Main.Project[Main.ProjectManager_Account = '[%CurrentUser%]']\", filter:{amount:500}, callback: ps => res(ps.map(p=>p.get('Name')).join('~')), error: e => res('ERR:'+((e&&e.message)||'refused')) }); })")"
case "$MINE" in ERR:*) tt_fail "C: could not read the projects '$PM' manages ($MINE)" ;; esac

playwright-cli click ".mx-name-cardReportOnProject" >/dev/null 2>&1
tt_wait_for ".mx-name-lstRoster" "the On Project roster"
sleep 3
ROSTER="$(ev "() => [...document.querySelectorAll('.mx-name-lstRoster .mx-name-txtRowProject')].map(e=>(e.innerText||'').trim()).join('~')")"
[ -n "$ROSTER" ] || tt_fail "C: the On Project roster is empty for '$PM'"
FOREIGN="$(printf '%s\n' "$ROSTER" | tr '~' '\n' | sort -u | grep -vxF -f <(printf '%s\n' "$MINE" | tr '~' '\n' | grep .) | head -3 | paste -sd, -)"
if [ -n "$FOREIGN" ]; then
  note "C ok: the roster lists projects '$PM' does not manage (e.g. $FOREIGN)"
else
  bad "C: every roster row is on a project '$PM' manages ($(printf '%s' "$ROSTER" | tr '~' '\n' | sort -u | paste -sd, -)) - the PM is still limited to their own projects"
fi

# ------------------------------------------------------------------ D. view only
for b in btnEditRow btnSaveRow btnCancelRow btnArchiveRow; do
  n="$(present ".mx-name-lstRoster .mx-name-$b")"
  [ "$n" = "0" ] || bad "D: $n '$b' button(s) rendered for '$PM' - editing from the report must stay with TM/HR/Admin"
done
EDITABLE="$(ev "() => String([...document.querySelectorAll('.mx-name-lstRoster .mx-name-dpRowStart input, .mx-name-lstRoster .mx-name-dpRowEnd input')].filter(i=>!i.disabled&&!i.readOnly).length)")"
[ "$EDITABLE" = "0" ] || bad "D: $EDITABLE row date picker(s) are editable for '$PM'"
[ "$fails" -eq 0 ] && note "D ok: no Edit/Save/Cancel/Archive button and no editable date picker"

# ------------------------------------------------------------------ E. export
EXPORT_GUID() { ev "() => new Promise(res => { mx.data.get({ xpath: \"//Main.ReportExport\", filter:{amount:5}, callback: o => res(o.map(x=>x.getGuid()).sort().join(',')), error: e => res('ERR:'+((e&&e.message)||'refused')) }); })"; }
BEFORE="$(EXPORT_GUID)"
case "$BEFORE" in ERR:*) bad "E: '$PM' cannot read its own exports ($BEFORE)" ;; esac
playwright-cli click ".mx-name-btnExportExcel" >/dev/null 2>&1
AFTER=""
for _ in $(seq 1 15); do
  sleep 1
  AFTER="$(EXPORT_GUID)"
  case "$AFTER" in ERR:*|'') continue ;; esac
  [ "$AFTER" != "$BEFORE" ] && break
done
DLG="$(dialog_text)"
case "$DLG" in *rror*|*"not allowed"*|*"no access"*) bad "E: the export raised a dialog for '$PM': $DLG" ;; esac
if [ -n "$AFTER" ] && [ "${AFTER#ERR:}" = "$AFTER" ] && [ "$AFTER" != "$BEFORE" ]; then
  note "E ok: the export created a new ReportExport for '$PM'"
else
  bad "E: no new export appeared for '$PM' within 15s (before [$BEFORE], after [$AFTER])"
fi

# ------------------------------------------------------------------ F. monthly hours
for _ in 1 2 3; do
  tt_try_click_text "Reports"
  sleep 2
  [ "$(present '.mx-name-cardReportMonthlyHours')" != "0" ] && break
done
playwright-cli click ".mx-name-cardReportMonthlyHours" >/dev/null 2>&1
tt_wait_for ".mx-name-cbMonth" "the Monthly Hours report (cbMonth)"
sleep 3
[ "$(present '.mx-name-lstReportRows')" != "0" ] || bad "F: the Monthly Hours row list did not render for '$PM'"
DLG="$(dialog_text)"
[ -z "$DLG" ] || bad "F: a dialog came up on the Monthly Hours report for '$PM': $DLG"
[ "$fails" -eq 0 ] && note "F ok: the Monthly Hours report opens"

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-tt800-pm-reports - $fails problem(s) with a project manager on the reports (TT-800)."
  exit 1
fi
echo "PASS: verify-tt800-pm-reports - '$PM' opens both reports, sees all projects, exports, and cannot edit or archive."
