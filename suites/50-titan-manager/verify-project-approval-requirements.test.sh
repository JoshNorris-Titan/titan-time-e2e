#!/usr/bin/env bash
# A project cannot be saved asking for an approval nobody can give: manager
# approval needs a project manager, and customer approval needs a contact NAME as
# well as an email.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. Main.SUB_Project_ValidateForSave (run by Main.ACT_Project_Save on
# the TM dashboard's Add Project form, and by the inline New Project form in the
# assignment popup) gained two refusals beside the contact-email one that
# verify-project-contact-email already covers:
#
#   manager approval, no project manager (feedback on ApprovalFromManager):
#     "Enter a project manager before marking this project as manager approved.
#      Without one there is nobody the approval belongs to."
#   customer approval, no contact name (feedback on ContactName):
#     "A contact name is required when this project needs customer approval.
#      The approval request is addressed to that person."
#
# Either project, saved, is a trap for a consultant: entries route to
# AwaitingManagerApproval with nobody's queue to land in, or the customer's request
# goes out addressed to nobody. The fixtures always fill both fields, so no spec
# ever reaches either refusal.
#
# WHAT IT ASSERTS (one Add Project form, kept open across the refusals)
#   A. manager approval on, customer off, no project manager: Save is refused with
#      the project-manager message, shown ON the manager-approval field - not merely
#      "some validation appeared";
#   B. nothing was created;
#   C. customer approval on, email filled, contact name blank: refused with the
#      contact-name message on the contact-name field; still nothing created;
#   D. the same form with a project manager and a contact name saves exactly once;
#   E. what was stored is what was asked for: both approval flags true, the contact
#      name, and the project manager (the project's ManagerName).
#
# Consumes: creates one project "E2E ApprovalReq <epoch>" in D, archived on exit
# (the verify-project-contact-email convention). Nothing is assigned to it, so the
# bookend clear never sees it; the archive is its only cleanup.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/lib/_authz.sh"

PROJ="E2E ApprovalReq $(date +%s)"
CONTACT="Approver ApprovalReq"
MSG_PM="Enter a project manager"
MSG_NAME="contact name is required"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

cleanup() {
  tt_authz_write "//Main.Project[Name = '$PROJ']" 'Archived' 'true' >/dev/null 2>&1 \
    && echo "  (archived $PROJ)" \
    || echo "  (nothing to archive for '$PROJ', or the archive was refused - check the Projects list if D passed)" >&2
}
trap cleanup EXIT

# field_validation <widget> - the visible validation text inside that widget, or ''.
field_validation() {
  playwright-cli eval "() => { const w=document.querySelector('.mx-name-$1'); if(!w) return 'NOWIDGET'; return [...w.querySelectorAll('.mx-validation-message')].filter(e=>e.offsetParent!==null).map(e=>(e.innerText||'').trim()).join(' ~ '); }" 2>/dev/null | _tt_eval_str
}
all_validations() {
  playwright-cli eval "() => [...document.querySelectorAll('.mx-validation-message')].filter(e=>e.offsetParent!==null).map(e=>(e.innerText||'').trim()).filter(Boolean).join(' ~ ')" 2>/dev/null | _tt_eval_str
}
count_proj() {
  local n; n="$(tt_authz_count "//Main.Project[Name = '$PROJ']")"
  case "$n" in ERR:*|''|*[!0-9]*) echo "ERR:$n" ;; *) echo "$n" ;; esac
}
save() { playwright-cli click ".mx-name-btnSave" >/dev/null 2>&1; sleep 3; }

tt_login "e2e_tm" "Add Customer"
fx_view "cardProjects" "galProjects"

# Open the dashboard's form (Project_NewEdit), not the assignment popup's - the same
# guard fx_create_project uses now that btnAddProject exists on both.
playwright-cli click ".mx-name-btnAddProject" >/dev/null 2>&1
tt_wait_for ".mx-name-txtProjectName input" "the Add Project form (Project_NewEdit)"
[ "$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnNewProjectSave'))" 2>/dev/null | _tt_eval_str)" = "false" ] \
  || tt_fail "the assignment popup's New Project form opened instead of the dashboard's Add Project form"

tt_fill ".mx-name-txtProjectName input" "$PROJ"
tt_combobox_select_text ".mx-name-cbCustomer" "$FX_CUSTOMER" || tt_fail "customer '$FX_CUSTOMER' not selectable on the project form"

# ------------------------------------------------------- A/B. manager approval, no manager
fx_set_radio "rbApprovalManager"  "Yes"
fx_set_radio "rbApprovalCustomer" "No"
fx_set_radio "rbNeedsLineItems"   "No"
PM_NOW="$(playwright-cli eval "() => ((document.querySelector('.mx-name-cbProjectManager')||{}).innerText||'').replace(/\\s+/g,' ').trim()" 2>/dev/null | _tt_eval_str)"
case "$PM_NOW" in *"$FX_PROJECT_MANAGER"*) tt_fail "a new project already has '$PM_NOW' as its manager, so the no-manager case cannot be set up" ;; esac
save

ON_FIELD="$(field_validation rbApprovalManager)"
case "$ON_FIELD" in
  *"$MSG_PM"*) note "A ok: refused on the manager-approval field: $ON_FIELD" ;;
  NOWIDGET)    bad "A: rbApprovalManager is not on the form" ;;
  *)           bad "A: manager approval with no project manager was not refused on that field. Field says [$ON_FIELD]; the form says [$(all_validations)]" ;;
esac
N="$(count_proj)"
[ "$N" = "0" ] && note "B ok: nothing was created" || bad "B: after the refusal, $N project(s) named '$PROJ' exist"

# ------------------------------------------------------- C. customer approval, no contact name
fx_set_radio "rbApprovalManager"  "No"
fx_set_radio "rbApprovalCustomer" "Yes"
tt_fill ".mx-name-txtApproverEmail input" "$FX_APPROVER_EMAIL"
tt_fill ".mx-name-txtApproverName input" ""
save

ON_FIELD="$(field_validation txtApproverName)"
case "$ON_FIELD" in
  *"$MSG_NAME"*) note "C ok: refused on the contact-name field: $ON_FIELD" ;;
  NOWIDGET)      bad "C: txtApproverName is not on the form" ;;
  *)             bad "C: customer approval with no contact name was not refused on that field. Field says [$ON_FIELD]; the form says [$(all_validations)]" ;;
esac
N="$(count_proj)"
[ "$N" = "0" ] && note "C ok: still nothing created" || bad "C: after the refusal, $N project(s) named '$PROJ' exist"

# ------------------------------------------------------- D/E. both supplied: saves
tt_fill ".mx-name-txtApproverName input" "$CONTACT"
tt_combobox_select_text ".mx-name-cbProjectManager" "$FX_PROJECT_MANAGER" || bad "D: manager '$FX_PROJECT_MANAGER' not selectable"
fx_set_radio "rbApprovalManager"  "Yes"
save
fx_close_modals >/dev/null 2>&1 || note "note: the project form did not close cleanly"

N="$(count_proj)"
case "$N" in
  1) note "D ok: saved once both a manager and a contact name were given" ;;
  0) bad "D: the project did not save with a manager and a contact name. Validation left: [$(all_validations)]" ;;
  *) bad "D: count of '$PROJ' reads [$N], expected 1" ;;
esac

if [ "$N" = "1" ]; then
  for pair in "ApprovalFromManager|true" "ApprovalFromCustomer|true" "ContactName|$CONTACT" "ManagerName|$FX_PROJECT_MANAGER"; do
    attr="${pair%%|*}"; want="${pair#*|}"
    got="$(tt_authz_readback "//Main.Project[Name = '$PROJ']" "$attr")"
    if [ "$got" = "$want" ]; then note "E ok: $attr = $got"; else bad "E: stored $attr is [$got], expected [$want]"; fi
  done
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-project-approval-requirements - $fails problem(s) with the project approval rules."
  exit 1
fi
echo "PASS: verify-project-approval-requirements - no-manager and no-contact-name projects are refused on the right field, and a complete one saves as asked."
