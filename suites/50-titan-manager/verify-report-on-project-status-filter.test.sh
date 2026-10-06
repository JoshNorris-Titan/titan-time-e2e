#!/usr/bin/env bash
# The On Project report's (now captioned "Assignment Report", TT-765) Status filter
# and sort headers must change the roster they sit above.
#
# tt-timeout: 6m
#
# FIXED IN THE MODEL, DEPLOYED (TT-765, fa8f6d17). On the deployed
# Main.Report_OnProject (read from disk) cbStatusFilter, and the new column filters
# cbFltProject / cbFltCustomer / cbFltConsultant, have on-change
# Main.ACT_Report_FiltersChanged, which changes the ReportSelection and so re-runs
# lstRoster's data source; hdrProject (and hdrCustomer / hdrConsultant / hdrEnds) call
# Main.ACT_Report_SortBy. This spec is expected green; it stays as the regression
# guard for the bug below, and is unproven until a dev run shows it.
#
# THE BUG AS IT WAS (seen on cloud dev, 2026-09-29, model HEAD 7500058f). On
# Main.Report_OnProject, picking "Archived" in cbStatusFilter changes the picker's
# text and nothing else: the roster (lstRoster, data source
# Main.DS_Report_OnProject, which DOES filter on ReportSelection/StatusFilter) keeps
# listing the same active rows, E2E fixture assignments included. Clicking a sort
# header (hdrProject -> Main.NACT_Report_SortBy) flips the header's tt-sort-asc /
# tt-sort-desc class but the rows stay in the same order. cbStatusFilter has no
# on-change action in the model, and nothing re-runs the list view's microflow data
# source when the selection object changes. Probe output (probe4, same session):
#   initial:            Active   | tt-sort-asc  | 25 rows, E2E Customer Approval ... E2E Sandbox
#   archived, no click: Archived | tt-sort-asc  | 25 rows, the same six active E2E rows
#   after hdr click:    Archived | tt-sort-desc | 25 rows, the same rows, same order
# while the data layer holds 31 archived assignments. Save, Cancel and Archive on a
# row DO refresh the list (they commit with refresh), which is why
# verify-report-on-project-edit is written against the default Active view.
#
# WHAT IT ASSERTS (non-destructive, TM)
#   A. with Status = Archived, no row for an assignment the data says is active
#      (E2E Consultant on E2E Manager Approval) remains, and at least one row shows;
#   B. clicking the Project header until it sorts descending puts the rows in
#      descending project order - compared on the database collation's first-level
#      key (letters and digits, lowercased), as lib/_login_gallery.sh's
#      tt_combobox_sorted does: dev's Postgres ignores case, spaces and punctuation,
#      so a punctuation-significant localeCompare disagrees with a correct sort.
# It leaves the filter on Active.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"

ACTIVE_PROJ="E2E Manager Approval"
ACTIVE_CONS="E2E Consultant"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }
rows() { ev "() => [...document.querySelectorAll('.mx-name-lstRoster .mx-name-cntRosterRow')].map(r=>((r.querySelector('.mx-name-txtRowProject')||{}).innerText||'').trim()+'|'+((r.querySelector('.mx-name-txtRowConsultant')||{}).innerText||'').trim()).join('~')"; }

tt_login "e2e_tm" "Add Customer"
ARCH="$(tt_authz_readback "//Main.Assignment[ConsultantName = '$ACTIVE_CONS'][Main.Assignment_Project/Main.Project/Name = '$ACTIVE_PROJ']" Archived)"
[ "$ARCH" = "false" ] || tt_fail "precondition: the fixture assignment $ACTIVE_CONS -> $ACTIVE_PROJ should be active, the data says Archived=[$ARCH] (run 00-setup)"
N_ARCH="$(tt_authz_expect_count "archived assignments" "//Main.Assignment[Archived = true()]")"
[ "$N_ARCH" -gt 0 ] || tt_fail "precondition: no archived assignment exists on this environment, so the Archived view has nothing to show"

for _ in 1 2 3; do
  tt_try_click_text "Reports"
  sleep 2
  [ "$(ev "() => String(!!document.querySelector('.mx-name-cardReportOnProject'))")" = "true" ] && break
done
playwright-cli click ".mx-name-cardReportOnProject" >/dev/null 2>&1
tt_wait_for ".mx-name-lstRoster" "the On Project roster"
sleep 2
case "~$(rows)~" in *"~$ACTIVE_PROJ|$ACTIVE_CONS~"*) ;; *) tt_fail "precondition: the Active roster does not list $ACTIVE_CONS on $ACTIVE_PROJ" ;; esac

# ------------------------------------------------------------------ A. Archived
tt_combobox_select_text ".mx-name-cbStatusFilter" "Archived" || tt_fail "the status filter offers no 'Archived'"
R=""
for _ in $(seq 1 10); do
  R="$(rows)"
  case "~$R~" in *"~$ACTIVE_PROJ|$ACTIVE_CONS~"*) sleep 1 ;; *) break ;; esac
done
case "~$R~" in
  *"~$ACTIVE_PROJ|$ACTIVE_CONS~"*) bad "A: Status = Archived still lists the ACTIVE assignment $ACTIVE_CONS on $ACTIVE_PROJ after 10s - the filter did not re-run the roster (rows: ${R:0:300})" ;;
  "~~")                            bad "A: Status = Archived shows no rows, though the data holds $N_ARCH archived assignments" ;;
  *)                               note "A ok: the Archived view dropped the active rows ($(printf '%s' "$R" | tr '~' '\n' | grep -c .) rows)" ;;
esac
tt_combobox_select_text ".mx-name-cbStatusFilter" "Active" >/dev/null 2>&1
sleep 2

# ------------------------------------------------------------------ B. sort
for _ in 1 2 3; do
  st="$(ev "() => (document.querySelector('.mx-name-hdrProject')||{}).className||''")"
  case "$st" in *tt-sort-desc*) break ;; esac
  playwright-cli click ".mx-name-hdrProject" >/dev/null 2>&1
  sleep 3
done
ORDER="$(ev "() => { const n=[...document.querySelectorAll('.mx-name-lstRoster .mx-name-txtRowProject')].map(e=>(e.innerText||'').trim()); const k=t=>t.toLowerCase().replace(/[^\p{L}\p{N}]+/gu,''); const bad=n.findIndex((x,i)=>i>0&&k(n[i-1]).localeCompare(k(x))<0); const ok=n.length>1 && bad<0; return (ok?'DESC':'NOTDESC')+'|'+(bad>0?'first break at #'+bad+': '+n[bad-1]+' > '+n[bad]+' | ':'')+n.slice(0,8).join(', '); }")"
case "$ORDER" in
  DESC*) note "B ok: descending by project (${ORDER#DESC|})" ;;
  *)     bad "B: the Project header reads [$st] but the rows are not in descending project order: ${ORDER#NOTDESC|}" ;;
esac
# Put the header back to ascending for whoever opens this next.
for _ in 1 2; do
  case "$(ev "() => (document.querySelector('.mx-name-hdrProject')||{}).className||''")" in *tt-sort-asc*) break ;; esac
  playwright-cli click ".mx-name-hdrProject" >/dev/null 2>&1; sleep 2
done

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-report-on-project-status-filter - $fails problem(s): the On Project filter/sort do not reach the roster (fixed by TT-765 - a regression if this is red)."
  exit 1
fi
echo "PASS: verify-report-on-project-status-filter - the Archived filter and the Project sort both re-run the roster."
