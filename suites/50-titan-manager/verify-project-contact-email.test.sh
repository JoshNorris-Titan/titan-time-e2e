#!/usr/bin/env bash
# A project that needs customer approval cannot be saved without a contact email,
# and the address it is saved with is trimmed and lower-cased.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. Main.SUB_Project_ValidateForSave refuses the save when
# ApprovalFromCustomer is true and ContactEmail is empty or whitespace, with:
#
#   "A contact email is required when this project needs customer approval.
#    Without one, the customer never receives an approval request."
#
# and, when it does save, normalises the address with
# toLowerCase(trim(ContactEmail)).
#
# Both halves matter more than they look. The approval token is minted PER
# APPROVER EMAIL, so a stray leading space or a capital letter does not merely
# look untidy - it mints a second token against what is effectively a second
# approver, and the customer's existing link stops covering the new rows. The
# normalisation is the only thing preventing that, and nothing asserts it.
#
# The refusal half is the difference between a project that cannot be saved and a
# project whose entries route to AwaitingCustomerApproval and sit there forever,
# because the email that would have carried the request was never set.
#
# verify-project-dropdowns-sorted is the only other test that opens this form and
# it only reads dropdown order; the whole 50-titan-manager folder has no negative
# test at all.
#
# WHAT IT ASSERTS
#   A. with customer approval on and the email blank, the save is refused and the
#      message is the ContactEmail one - not merely "some validation appeared",
#      which a missing project name would also satisfy;
#   B. the project was not created;
#   C. with a MIXED-CASE, SPACE-PADDED address the save succeeds;
#   D. the stored ContactEmail is trimmed and lower-cased.
#
# Consumes: creates one project named "E2E ContactEmail <epoch>" in C, which it
# archives on exit. The epoch keeps a failed cleanup identifiable rather than
# colliding with the next run - the convention verify-tt729-new-customer-save uses.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/lib/_authz.sh"

PROJ="E2E ContactEmail $(date +%s)"
RAW_EMAIL="  E2E.Approver+TT@Titanconsulting.NET  "
WANT_EMAIL="e2e.approver+tt@titanconsulting.net"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

cleanup() {
  [ -n "${PROJ:-}" ] || return 0
  tt_authz_write "//Main.Project[Name = '$PROJ']" 'Archived' 'true' >/dev/null 2>&1 \
    && echo "  (archived $PROJ)" \
    || echo "  WARN: could not archive '$PROJ' - it may be left on the environment" >&2
}
trap cleanup EXIT

validations() {
  playwright-cli eval "() => [...document.querySelectorAll('.mx-validation-message')].filter(e=>e.offsetParent!==null).map(e=>(e.innerText||'').trim()).filter(Boolean).join(' ~ ')" 2>/dev/null | _tt_eval_str
}

open_form() {
  playwright-cli click ".mx-name-btnAddProject" >/dev/null 2>&1
  sleep 3
  tt_fill ".mx-name-txtProjectName input" "$PROJ"
  tt_combobox_select_text ".mx-name-cbCustomer" "$FX_CUSTOMER"        || bad "customer '$FX_CUSTOMER' not selectable on the project form"
  tt_combobox_select_text ".mx-name-cbProjectManager" "$FX_PROJECT_MANAGER" || bad "manager '$FX_PROJECT_MANAGER' not selectable"
  tt_fill ".mx-name-txtApproverName input" "$FX_APPROVER_NAME"
  fx_set_radio "rbApprovalManager"  "No"
  fx_set_radio "rbApprovalCustomer" "Yes"
  fx_set_radio "rbNeedsLineItems"   "No"
}

tt_login "e2e_tm" "Add Customer"

# ------------------------------------------------------- A/B. blank email is refused
open_form
tt_fill ".mx-name-txtApproverEmail input" ""
playwright-cli click ".mx-name-btnSave" >/dev/null 2>&1
sleep 3

MSG="$(validations)"
case "$MSG" in
  *"contact email is required"*) note "A ok: refused with: $MSG" ;;
  "")                            bad "A: a customer-approval project with no contact email saved with no complaint" ;;
  *)                             bad "A: something objected, but not about the contact email - that message would also appear for a missing name. Got: $MSG" ;;
esac

N="$(tt_authz_count "//Main.Project[Name = '$PROJ']")"
case "$N" in
  0)                 note "B ok: no project was created" ;;
  ERR:*|''|*[!0-9]*) bad "B: could not count projects named '$PROJ' (read: [$N])" ;;
  *)                 bad "B: $N project(s) named '$PROJ' exist although the save was refused" ;;
esac

# --------------------------------------------------- C/D. padded mixed case is normalised
tt_fill ".mx-name-txtApproverEmail input" "$RAW_EMAIL"
playwright-cli click ".mx-name-btnSave" >/dev/null 2>&1
sleep 4
fx_close_modals >/dev/null 2>&1 || note "note: the project form did not close cleanly"

N2="$(tt_authz_count "//Main.Project[Name = '$PROJ']")"
case "$N2" in
  1)                 note "C ok: the project saved once the address was supplied" ;;
  ERR:*|''|*[!0-9]*) bad "C: could not count projects named '$PROJ' (read: [$N2])" ;;
  0)                 bad "C: the project still did not save with a valid address" ;;
  *)                 bad "C: $N2 projects named '$PROJ' exist - the save ran more than once" ;;
esac

GOT="$(tt_authz_readback "//Main.Project[Name = '$PROJ']" 'ContactEmail')"
case "$GOT" in
  ERR:*)        bad "D: could not read ContactEmail back ($GOT)" ;;
  "$WANT_EMAIL") note "D ok: stored as '$GOT'" ;;
  *)            bad "D: stored ContactEmail is '$GOT', not '$WANT_EMAIL'. The token is minted per approver address, so an untrimmed or mixed-case value splits one approver into two." ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-project-contact-email — $fails problem(s) with the contact-email rule."
  exit 1
fi
echo "PASS: verify-project-contact-email — blank refused, and '$RAW_EMAIL' stored as '$GOT'."
