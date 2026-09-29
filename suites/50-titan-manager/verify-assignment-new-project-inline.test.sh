#!/usr/bin/env bash
# Creating a project from inside the New Assignment popup: it inherits the
# assignment's customer, is held to the same save rules as the dashboard's form,
# commits, and lands selected on the assignment's Project picker.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. Main.Assignment_NewEdit gained an Add Project button
# (btnAddProject, visible only once a customer is picked) beside cbProject. It runs
# Main.ACT_Assignment_NewProject, which creates a Main.Project already pointed at
# the assignment's customer and opens Main.Assignment_NewProject over the popup.
# That form's Save (btnNewProjectSave) runs Main.ACT_Assignment_SaveNewProject:
# SUB_Project_ValidateForSave, then commit, point the in-edit Assignment at the new
# project, close. It is the TT-729 "New Customer" pattern one level down, and it
# had never been driven in a browser.
#
# WHAT IT ASSERTS
#   A. Add Project is not offered until a customer is picked (its visibility rule);
#   B. once it is, it opens the New Project form, and that form's Customer picker
#      already reads the assignment's customer (the Create's Project_Customer);
#   C. the form enforces SUB_Project_ValidateForSave: manager approval with no
#      project manager is refused, the form stays open, and nothing is committed -
#      the inline path is not a way round the dashboard's rules;
#   D. with a manager picked it saves, the form closes, and the assignment's
#      cbProject now reads the new project (the Change activity);
#   E. the project really was committed, under the assignment's customer, with the
#      manager and flags that were chosen - read from the data layer, not the form.
#
# The assignment itself is cancelled afterwards: this is about the project, and a
# half-built assignment would pollute the roster for later specs.
#
# Consumes: one project "E2E InlineProject <epoch>", archived on exit.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/lib/_authz.sh"

PROJ="E2E InlineProject $(date +%s)"
# The New Project form sits in a second popup over the assignment popup, and both
# carry a cbCustomer, so everything on it is scoped to the dialog that holds its Save.
NPF=".modal-content:has(.mx-name-btnNewProjectSave)"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

cleanup() {
  tt_authz_write "//Main.Project[Name = '$PROJ']" 'Archived' 'true' >/dev/null 2>&1 \
    && echo "  (archived $PROJ)" \
    || echo "  (nothing to archive for '$PROJ', or the archive was refused - check the Projects list if D passed)" >&2
}
trap cleanup EXIT

present() { ev "() => String(!!document.querySelector('$1'))"; }
count_proj() {
  local n; n="$(tt_authz_count "//Main.Project[Name = '$PROJ']")"
  case "$n" in ERR:*|''|*[!0-9]*) echo "ERR:$n" ;; *) echo "$n" ;; esac
}
# Radio on the New Project form, scoped to it - fx_set_radio is document-wide and the
# assignment popup has approval radios of its own once a project is picked.
npf_radio() {
  local r
  r="$(ev "() => { const g=document.querySelector('$NPF .mx-name-$1'); if(!g) return 'NOGROUP'; const l=[...g.querySelectorAll('label')].find(x=>(x.innerText||'').trim().toLowerCase()==='$(echo "$2" | tr '[:upper:]' '[:lower:]')'); if(!l) return 'NOOPT'; l.click(); return 'OK'; }")"
  [ "$r" = "OK" ] || tt_fail "New Project form: could not set $1 to $2 ($r)"
}

tt_login "e2e_tm" "Add Customer"

playwright-cli click ".mx-name-btnAddAssignment" >/dev/null 2>&1
sleep 3
tt_wait_for ".mx-name-cbProject" "the New Assignment popup"

# ------------------------------------------------------------------ A. gated on customer
# The dashboard has its own btnAddProject, so ask only inside the popup.
IN_POPUP=".modal-content .mx-name-btnAddProject"
if [ "$(present "$IN_POPUP")" = "false" ]; then
  note "A ok: no Add Project in the popup before a customer is picked"
else
  bad "A: Add Project is offered before any customer is chosen"
fi

tt_combobox_select_text ".modal-content .mx-name-cbCustomer" "$FX_CUSTOMER" || tt_fail "customer '$FX_CUSTOMER' not selectable on the assignment popup"
for _ in $(seq 1 10); do [ "$(present "$IN_POPUP")" = "true" ] && break; sleep 1; done
[ "$(present "$IN_POPUP")" = "true" ] || tt_fail "A: Add Project never appeared after picking customer '$FX_CUSTOMER'"
note "A ok: Add Project appeared once '$FX_CUSTOMER' was picked"

# ------------------------------------------------------------------ B. opens, customer inherited
playwright-cli click "$IN_POPUP" >/dev/null 2>&1
tt_wait_for "$NPF .mx-name-txtProjectName input" "the New Project form (Assignment_NewProject)"
NP_CUST="$(ev "() => ((document.querySelector('$NPF .mx-name-cbCustomer')||{}).innerText||'').replace(/\\s+/g,' ').trim()")"
case "$NP_CUST" in
  *"$FX_CUSTOMER"*) note "B ok: the New Project form opened with customer '$FX_CUSTOMER' already set" ;;
  *)                bad "B: the New Project form's customer reads '$NP_CUST', expected the assignment's '$FX_CUSTOMER'" ;;
esac

tt_fill "$NPF .mx-name-txtProjectName input" "$PROJ"
tt_fill "$NPF .mx-name-txtApproverName input" "$FX_APPROVER_NAME"
tt_fill "$NPF .mx-name-txtApproverEmail input" "$FX_APPROVER_EMAIL"
npf_radio rbApprovalManager Yes
npf_radio rbApprovalCustomer No
npf_radio rbNeedsLineItems No

# ------------------------------------------------------------------ C. same rules as the dashboard
playwright-cli click "$NPF .mx-name-btnNewProjectSave" >/dev/null 2>&1
sleep 3
STILL="$(present "$NPF .mx-name-txtProjectName")"
MSG="$(ev "() => { const w=document.querySelector('$NPF .mx-name-rbApprovalManager'); return w ? [...w.querySelectorAll('.mx-validation-message')].filter(e=>e.offsetParent!==null).map(e=>(e.innerText||'').trim()).join(' ~ ') : 'NOWIDGET'; }")"
N="$(count_proj)"
if [ "$STILL" = "true" ] && [ "${MSG#*Enter a project manager}" != "$MSG" ] && [ "$N" = "0" ]; then
  note "C ok: no-manager save refused ('$MSG'), form still open, nothing committed"
else
  bad "C: manager approval with no manager - form open=$STILL, message on the field=[$MSG], projects named '$PROJ'=$N (expected true / the project-manager message / 0)"
fi

# ------------------------------------------------------------------ D. save lands on the assignment
tt_combobox_select_text "$NPF .mx-name-cbProjectManager" "$FX_PROJECT_MANAGER" || tt_fail "D: manager '$FX_PROJECT_MANAGER' not selectable on the New Project form"
playwright-cli click "$NPF .mx-name-btnNewProjectSave" >/dev/null 2>&1
gone=""
for _ in $(seq 1 10); do gone="$(present "$NPF")"; [ "$gone" = "false" ] && break; sleep 1; done
if [ "$gone" != "false" ]; then
  bad "D: the New Project form is still open after Save with a manager. Validation: [$(ev "() => [...document.querySelectorAll('$NPF .mx-validation-message')].map(e=>(e.innerText||'').trim()).join(' ~ ')")]"
else
  PICKED="$(ev "() => ((document.querySelector('.modal-content .mx-name-cbProject')||{}).innerText||'').replace(/\\s+/g,' ').trim()")"
  case "$PICKED" in
    *"$PROJ"*) note "D ok: the assignment's Project picker now reads '$PROJ'" ;;
    *)         bad "D: after Save the assignment's Project picker reads '$PICKED', expected '$PROJ'" ;;
  esac
fi

# Abandon the assignment.
playwright-cli click ".modal-content .mx-name-btnCancel" >/dev/null 2>&1
sleep 3
fx_close_modals >/dev/null 2>&1 || true

# ------------------------------------------------------------------ E. committed, as chosen
N="$(count_proj)"
if [ "$N" = "1" ]; then
  note "E ok: '$PROJ' is committed (once)"
  for pair in "CustomerName|$FX_CUSTOMER" "ManagerName|$FX_PROJECT_MANAGER" "ApprovalFromManager|true" "ApprovalFromCustomer|false" "Archived|false"; do
    attr="${pair%%|*}"; want="${pair#*|}"
    got="$(tt_authz_readback "//Main.Project[Name = '$PROJ']" "$attr")"
    if [ "$got" = "$want" ]; then note "E ok: $attr = $got"; else bad "E: stored $attr is [$got], expected [$want]"; fi
  done
else
  bad "E: $N project(s) named '$PROJ' after Save (expected 1) - the inline save did not commit"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-assignment-new-project-inline - $fails problem(s) creating a project from the assignment popup."
  exit 1
fi
echo "PASS: verify-assignment-new-project-inline - a project made from the assignment popup inherits its customer, obeys the save rules, commits and lands on the picker."
