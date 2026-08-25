#!/usr/bin/env bash
# verify-email-templates-present.test.sh
#
# Every email type the app can send must have a template row behind it.
#
# WHY THIS EXISTS. The subject and body of each email are not in the model — they
# are rows in the database, configured per environment. When the row for a given
# type is missing, the send loop simply breaks: no error, no warning in the log,
# no message queued. The email just never happens. That is the single most likely
# way email silently stops working on a fresh or restored environment, and nothing
# tested it.
#
# HOW IT PROVES IT. Main.ENUM_EmailType has eleven values, and Main.EmailTester
# can send any one of them on demand. So the step sends all eleven, giving each a
# DISTINCT recipient address derived from the type name, and then reads the Emails
# Sent admin page once. A type whose template is missing produces no row, and the
# per-type address is what says which one.
#
# That indirection is deliberate. Counting eleven rows would prove only that
# eleven arrived; addressing each one by type is what turns "some emails are
# broken" into "ToManager_HoursNotice has no template".
#
# WHAT IT DOES NOT PROVE. That the wording is right, or that anything was
# delivered. Only that a template exists and a message was raised for every type.
# Delivery needs the send event, which runs on its own schedule.
#
# ASSUMPTION, stated because it could not be checked without running: that
# Main.ACT_SendTemplate1 sends to the address in the tester's own email field. If
# it does not, every type will look missing at once — which is a distinctive
# enough failure to recognise, and the message below says so.
#
# Sends eleven emails. They are queued rather than delivered, and the environment
# guard on the send event decides whether they ever leave.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

# The eleven values of Main.ENUM_EmailType, read from the model on 2026-08-25.
# If someone adds a twelfth, this list is what makes the step notice.
TYPES="ToConsultant_SubmissionReminder ToConsultant_RejectionNotice \
ToManager_ApprovalRequest ToManager_ApprovalReminder ToManager_HoursNotice \
ToCustomer_ApprovalRequest ToCustomer_ApprovalReminder NewAccount \
ChangePassword ToConsultantApprovedRequest ToManager_ForApproval"

# ---------------------------------------------------------------------- helpers

et_addr() {  # a recipient unique to one email type
  printf 'tmpl-%s@%s' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" "${TT_MAIL_DOMAIN:-e2e.local}"
}

et_open_tester() {
  local i
  [ "$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnTesterSend'))" 2>/dev/null | _tt_eval_str)" = "true" ] && return 0
  tt_login "${TT_ADMIN_USER:-MxAdmin}" "Welcome to your homepage" "${TT_ADMIN_PASS:-${TT_PASS:-}}" || return 1
  playwright-cli click ".mx-name-cardEmailTester" >/dev/null 2>&1
  for i in $(seq 1 20); do
    [ "$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnTesterSend'))" 2>/dev/null | _tt_eval_str)" = "true" ] && return 0
    sleep 1
  done
  return 1
}

# et_pick_type — choose one value in the enum combobox. Mendix's combobox renders
# its options as role=option nodes once opened, so the value is matched on its own
# text rather than on a generated widget id.
et_pick_type() {
  playwright-cli click ".mx-name-cbTesterEmailType" >/dev/null 2>&1
  sleep 1
  playwright-cli eval "() => { const os=[...document.querySelectorAll('[role=option]')]; const o=os.find(e=>(e.innerText||'').trim()==='$1'); if(!o) return 'notoffered:'+os.length; o.click(); return 'picked'; }" 2>/dev/null | _tt_eval_str
}

# --------------------------------------------------------------- 1. mark the page
# Done first: everything sent after this point is what the step is allowed to see.
tt_mail_prepare

# ------------------------------------------------------------ 2. send all eleven
et_open_tester || tt_fail "could not open the Email Tester as ${TT_ADMIN_USER:-MxAdmin} (Core.AdministratorDashboard -> cardEmailTester)"

sent=""
notoffered=""
for t in $TYPES; do
  addr="$(et_addr "$t")"
  tt_fill ".mx-name-txtTesterEmail input, .mx-name-txtTesterEmail" "$addr" >/dev/null 2>&1 \
    || { notoffered="$notoffered $t(no-email-field)"; continue; }
  r="$(et_pick_type "$t")"
  case "$r" in
    picked) ;;
    notoffered:*)
      notoffered="$notoffered $t"
      continue ;;
    *)
      notoffered="$notoffered $t(combobox:$r)"
      continue ;;
  esac
  playwright-cli click ".mx-name-btnTesterSend" >/dev/null 2>&1
  sleep 2
  tt_clear_dialogs 6 >/dev/null 2>&1 || true
  sent="$sent $t"
  et_open_tester >/dev/null 2>&1 || true
done

if [ -n "$notoffered" ]; then
  echo "FAIL: verify-email-templates-present - the tester did not offer these types:$notoffered"
  echo "      Main.ENUM_EmailType and the tester's dropdown have diverged, so those types"
  echo "      could not be exercised at all."
  exit 1
fi

# ------------------------------------------------------- 3. one read, eleven answers
rows="$(_tt_mail_new_rows)"
missing=""
found=0
for t in $TYPES; do
  if printf '%s\n' "$rows" | grep -qi -- "$(et_addr "$t")"; then
    found=$((found+1))
  else
    missing="$missing $t"
  fi
done

echo "  raised $found of 11 email types"

if [ -n "$missing" ]; then
  echo "FAIL: verify-email-templates-present - no message was raised for:$missing"
  if [ "$found" -eq 0 ]; then
    echo "      NOTHING was raised for any type. Before hunting eleven missing templates,"
    echo "      check the assumption in this file's header: that ACT_SendTemplate1 sends to"
    echo "      the tester's own email field. If it sends somewhere else, every type looks"
    echo "      missing even when all the templates are fine."
  else
    echo "      Each of those types has no EmailTemplate row, so its send loop breaks"
    echo "      silently - no error, no log line, no queued message. Add the row on this"
    echo "      environment; the wording lives in the database, not the model."
  fi
  exit 1
fi

echo "PASS: verify-email-templates-present - all 11 ENUM_EmailType values raised a message, so each has a template row"
