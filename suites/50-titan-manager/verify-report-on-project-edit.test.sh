#!/usr/bin/env bash
# The On Project report edits assignments and projects IN PLACE, so it is held to
# the same standard as a form: Save persists, Cancel discards, the edit claim is
# released, and Archive takes the row off the Active roster.
#
# tt-timeout: 15m
#
# WHY THIS EXISTS. Reports -> On Project (Main.Report_OnProject) is the one report
# that WRITES. A row opens a side panel; Edit (Main.ACT_Report_Row_Edit) claims the
# assignment for the current user (Assignment_EditingBy) and swaps the panel for
# input fields - the assignment's weekly and budget hours and dates, plus the
# PROJECT's settings, which the page itself warns "reach every consultant working
# on it". Save (Main.ACT_Report_Row_Save) validates both, commits, and releases the
# claim; Cancel (Main.ACT_Report_Row_Cancel) rolls both back and releases it.
# Archive (Main.ACT_Assignment_Archive) sets Assignment.Archived. None of it had a
# test, and every one of those writes lands on data other people use.
#
# ITS OWN DATA, NOT THE FIXTURES'. Editing a fixture assignment's weekly hours or a
# fixture project's contact would change what later specs in the same run see, and
# archiving one would remove a consultant's row outright. So this builds a throwaway
# project and gives it to 'E2E Consultant Three' - a consultant in
# TT_E2E_CONSULTANTS that no spec drives (lib/_fixtures.sh) - so the deep clear in
# 99-teardown deletes the assignment AND the project with it. The project is also
# archived on exit, for a run that never reaches teardown.
#
# WHAT IT ASSERTS
#   A. the new assignment is on the Active roster with the project's approval pips
#      (manager required, client not required - the flags it was created with), and
#      TT-763's hover text on each: txtPipManagerRequired "Project manager approval
#      required", txtPipClientNotRequired "Client approval not required". The pips
#      are containers (pipManagerRequired / ...NotRequired, pipClient...), shown by
#      conditional visibility on the project's flags - not buttons;
#   B. the row's View button (btnOpenRow -> Main.ACT_Report_Row_Open; the row itself
#      has no click action on the deployed page) opens the panel on THAT assignment
#      (project, consultant, weekly hours 40);
#   C. Edit -> weekly hours 32 and client contact changed -> Save: the panel shows 32,
#      the assignment stores 32, the PROJECT stores the new contact, and the edit
#      claim (Assignment_EditingBy) is released;
#   D. Edit -> weekly hours 24 -> Cancel: the panel still reads 32 and the assignment
#      still stores 32 - the typed value was rolled back, not saved - and the claim
#      is released;
#   E. Archive: the row leaves the (default, Active) roster and the assignment
#      stores Archived = true.
#
# THE STATUS FILTER AND SORT HEADERS ARE NOT USED HERE. This spec works on the
# page's default Active view, which Save, Cancel and Archive refresh. The filter and
# sort (which did not reach the roster on 2026-09-29, and since TT-765 do) are
# verify-report-on-project-status-filter's job.
#
# Consumes: one project "E2E OnProject <epoch>" and one assignment of
# E2E Consultant Three to it. Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/lib/_authz.sh"

PROJ="E2E OnProject $(date +%s)"
CONS="E2E Consultant Three"
NEW_CONTACT="Contact OnProject"
ASG_XP="//Main.Assignment[ConsultantName = '$CONS'][Main.Assignment_Project/Main.Project/Name = '$PROJ']"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }
num()  { printf '%s' "$1" | tr -d ' ,' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1; }
eqn()  { awk -v a="$1" -v b="$2" 'BEGIN{ exit (a+0==b+0) ? 0 : 1 }'; }

cleanup() {
  # Never leave the row claimed: a stale Assignment_EditingBy blocks everyone else's
  # Edit on every assignment of that project.
  if [ "$(ev "() => String(!!document.querySelector('.mx-name-btnCancelRow'))")" = "true" ]; then
    playwright-cli click ".mx-name-btnCancelRow" >/dev/null 2>&1; sleep 2
  fi
  tt_authz_write "//Main.Project[Name = '$PROJ']" 'Archived' 'true' >/dev/null 2>&1 \
    && echo "  (archived $PROJ; the teardown clear deletes it and its assignment)" \
    || echo "  (could not archive '$PROJ' - the teardown clear of '$CONS' removes it)" >&2
}
trap cleanup EXIT

# row_js - JS expression for the roster row of our project, or null.
ROW_JS="[...document.querySelectorAll('.mx-name-lstRoster .mx-name-cntRosterRow')].find(r=>((r.querySelector('.mx-name-txtRowProject')||{}).innerText||'').trim()==='$PROJ')"
row_present() { ev "() => String(!!($ROW_JS))"; }
panel() { ev "() => { const e=document.querySelector('.mx-name-$1'); return e ? (e.innerText||'').replace(/\\s+/g,' ').trim() : '__MISSING__'; }"; }

# wait_row <present|absent>
wait_row() {
  local want="$1" got
  for _ in $(seq 1 12); do
    got="$(row_present)"
    { [ "$want" = present ] && [ "$got" = true ]; } && return 0
    { [ "$want" = absent ] && [ "$got" = false ]; } && return 0
    sleep 1
  done
  return 1
}

# ------------------------------------------------------------------ setup: own data
tt_login "e2e_tm" "Add Customer"
fx_view "cardProjects" "galProjects"
fx_create_project "$PROJ" "Yes" "No" "No"
fx_create_assignment "$CONS" "$PROJ" 40 "$FX_CUSTOMER"
N="$(tt_authz_count "$ASG_XP")"
[ "$N" = "1" ] || tt_fail "setup: expected one assignment of '$CONS' to '$PROJ', the data layer reports [$N]"

# ------------------------------------------------------------------ open the report
open_on_project() {
  local i
  for i in 1 2 3; do
    tt_try_click_text "Reports" || true
    sleep 2
    if [ "$(ev "() => String(!!document.querySelector('.mx-name-cardReportOnProject'))")" = "true" ]; then
      playwright-cli click ".mx-name-cardReportOnProject" >/dev/null 2>&1
      sleep 3
    fi
    [ "$(ev "() => String(!!document.querySelector('.mx-name-lstRoster'))")" = "true" ] && return 0
  done
  tt_fail "could not reach the On Project report (Reports menu -> cardReportOnProject -> lstRoster)"
}
open_on_project

# ------------------------------------------------------------------ A. on the roster, pips
if wait_row present; then
  PIPS="$(ev "() => { const r=$ROW_JS; const h=s=>String(!!r.querySelector('.mx-name-'+s)); return [h('pipManagerRequired'),h('pipManagerNotRequired'),h('pipClientRequired'),h('pipClientNotRequired'), ((r.querySelector('.mx-name-txtRowConsultant')||{}).innerText||'').trim()].join('|'); }")"
  if [ "$PIPS" = "true|false|false|true|$CONS" ]; then
    note "A ok: '$PROJ' is on the Active roster for $CONS, manager required, client not"
  else
    bad "A: row pips/consultant read [$PIPS], expected [true|false|false|true|$CONS] (manager-required, not client-required)"
  fi
  # TT-763: each pip carries its own hover text. textContent, not innerText: the tip
  # is hidden until hover, and innerText of a hidden element is empty.
  TIPS="$(ev "() => { const r=$ROW_JS; const t=s=>{ const e=r.querySelector('.mx-name-'+s); return e ? (e.textContent||'').replace(/\\s+/g,' ').trim() : '(absent)'; }; return t('txtPipManagerRequired')+'|'+t('txtPipClientNotRequired'); }")"
  if [ "$TIPS" = "Project manager approval required|Client approval not required" ]; then
    note "A ok: the pips' hover text reads '${TIPS%%|*}' and '${TIPS#*|}' (TT-763)"
  else
    bad "A: the pips' hover text reads [$TIPS], expected [Project manager approval required|Client approval not required] (TT-763)"
  fi
else
  tt_fail "A: '$PROJ' is not on the Active roster although its assignment exists (rows: $(ev "() => [...document.querySelectorAll('.mx-name-lstRoster .mx-name-txtRowProject')].map(e=>e.innerText.trim()).join(', ').slice(0,300)"))"
fi

# ------------------------------------------------------------------ B. panel
OPENED="$(ev "() => { const r=$ROW_JS; if(!r) return 'norow'; const b=[...r.querySelectorAll('.mx-name-btnOpenRow')].find(e=>e.offsetParent!==null) || r.querySelector('.mx-name-btnOpenRow'); if(!b) return 'nobutton'; b.click(); return 'ok'; }")"
[ "$OPENED" = "ok" ] || tt_fail "B: could not press the row's .mx-name-btnOpenRow ($OPENED)"
tt_wait_for ".mx-name-btnEditRow" "the On Project side panel (btnEditRow)"
P_PROJ="$(panel lblPanelProject)"; P_CONS="$(panel lblPanelConsultant)"; P_WEEK="$(panel lblPanelWeekly)"
if [ "$P_PROJ" = "$PROJ" ] && [ "$P_CONS" = "$CONS" ] && eqn "$(num "$P_WEEK")" 40; then
  note "B ok: the panel shows $P_PROJ / $P_CONS / $P_WEEK weekly hours"
else
  bad "B: the panel shows project [$P_PROJ], consultant [$P_CONS], weekly [$P_WEEK]; expected $PROJ / $CONS / 40"
fi

claim() { tt_authz_count "$ASG_XP[Main.Assignment_EditingBy/Administration.Account/Name != '']"; }

# ------------------------------------------------------------------ C. edit + save
playwright-cli click ".mx-name-btnEditRow" >/dev/null 2>&1
tt_wait_for ".mx-name-btnSaveRow" "edit mode (btnSaveRow)"
C1="$(claim)"; [ "$C1" = "1" ] || bad "C: Edit did not claim the assignment (EditingBy set on [$C1] rows, expected 1)"
tt_fill ".mx-name-txtWeeklyHours input" "32"
tt_fill ".mx-name-txtContactName input" "$NEW_CONTACT"
playwright-cli click ".mx-name-btnSaveRow" >/dev/null 2>&1
for _ in $(seq 1 10); do [ "$(ev "() => String(!!document.querySelector('.mx-name-btnEditRow'))")" = "true" ] && break; sleep 1; done
P_WEEK="$(panel lblPanelWeekly)"
D_WEEK="$(tt_authz_readback "$ASG_XP" WeeklyHours)"
D_CONTACT="$(tt_authz_readback "//Main.Project[Name = '$PROJ']" ContactName)"
C2="$(claim)"
if eqn "$(num "$P_WEEK")" 32 && eqn "$(num "$D_WEEK")" 32 && [ "$D_CONTACT" = "$NEW_CONTACT" ] && [ "$C2" = "0" ]; then
  note "C ok: saved - panel $P_WEEK, stored WeeklyHours $D_WEEK, project contact '$D_CONTACT', claim released"
else
  bad "C: after Save the panel reads [$P_WEEK], stored WeeklyHours [$D_WEEK], project ContactName [$D_CONTACT], rows still claimed [$C2]; expected 32 / 32 / '$NEW_CONTACT' / 0. Validation: [$(ev "() => [...document.querySelectorAll('.mx-validation-message')].map(e=>e.innerText.trim()).join(' ~ ')")]"
fi

# ------------------------------------------------------------------ D. edit + cancel
playwright-cli click ".mx-name-btnEditRow" >/dev/null 2>&1
tt_wait_for ".mx-name-btnCancelRow" "edit mode (btnCancelRow)"
tt_fill ".mx-name-txtWeeklyHours input" "24"
playwright-cli click ".mx-name-btnCancelRow" >/dev/null 2>&1
for _ in $(seq 1 10); do [ "$(ev "() => String(!!document.querySelector('.mx-name-btnEditRow'))")" = "true" ] && break; sleep 1; done
P_WEEK="$(panel lblPanelWeekly)"
D_WEEK="$(tt_authz_readback "$ASG_XP" WeeklyHours)"
C3="$(claim)"
if eqn "$(num "$P_WEEK")" 32 && eqn "$(num "$D_WEEK")" 32 && [ "$C3" = "0" ]; then
  note "D ok: Cancel discarded 24 - panel $P_WEEK, stored $D_WEEK, claim released"
else
  bad "D: after Cancel the panel reads [$P_WEEK], stored WeeklyHours [$D_WEEK], rows still claimed [$C3]; expected 32 / 32 / 0"
fi

# ------------------------------------------------------------------ E. archive
playwright-cli click ".mx-name-btnArchiveRow" >/dev/null 2>&1
sleep 2
tt_clear_dialogs 3 >/dev/null 2>&1 || true
D_ARCH="$(tt_authz_readback "$ASG_XP" Archived)"
if wait_row absent && [ "$D_ARCH" = "true" ]; then
  note "E ok: archived - off the Active roster, Archived stored true"
else
  bad "E: after Archive the row is present=$(row_present) on the Active roster and Archived is stored [$D_ARCH]"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-report-on-project-edit - $fails problem(s) with the On Project report's in-place edits."
  exit 1
fi
echo "PASS: verify-report-on-project-edit - Save persists and releases, Cancel rolls back, Archive leaves the Active roster."
