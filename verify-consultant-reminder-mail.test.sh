#!/usr/bin/env bash
# Consultant submission-reminder email: trigger it, then READ the mail.
#
#   1. As admin, open Admin Hub -> Email Tester.
#   2. Address it to an inbox this suite controls, pick the
#      ToConsultant_SubmissionReminder type, and send.
#   3. Read the delivered message back and assert on its subject and body.
#
# Step 2 sends through Main.SUB_SendEmail_Template — the same sender the
# scheduled reminder (Main.SCE_ToConsultant_SubmissionReminder) and the HR
# dashboard both use — so this proves the whole pipeline: compose, send,
# deliver, read.
#
# Scope note: it deliberately does NOT drive the HR dashboard's own Remind
# button. The Email Tester is used because it lets the TEST choose the
# recipient address, without touching the app's data. The HR-dashboard trigger
# is covered for the customer flow by verify-customer-approval-flow.test.sh.
#
# Requires:
#   TT_ADMIN_USER / TT_ADMIN_PASS   an account holding Main.Administrator
#   TT_TESTMAIL_APIKEY / TT_TESTMAIL_NAMESPACE   see tests/lib/_login.sh

set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"

ADMIN_USER="${TT_ADMIN_USER:-}"
[ -n "$ADMIN_USER" ] || tt_fail "set TT_ADMIN_USER (an account with the Administrator role)"

# Fail fast on a misconfigured backend, before the login sequence.
tt_mail_prepare

TAG="consultant"
RECIP="$(tt_mail_address "$TAG")"
echo "reminder will be addressed to: $RECIP"

# 1) Admin -> Email Tester.
tt_login "$ADMIN_USER" "Admin Hub" "${TT_ADMIN_PASS:-}"
tt_click_text "Admin Hub" "admin hub nav item"
sleep 2
tt_click_text "Email Tester" "email tester card"
tt_wait_for ".mx-name-textBox2" "email tester form"

# 2) Address it, choose the reminder type, send.
TS=$(date +%s%3N)
tt_fill ".mx-name-textBox2 input" "$RECIP"
tt_combobox_select_text ".mx-name-comboBox1" "ToConsultant_SubmissionReminder" \
  || tt_fail "email tester: no 'ToConsultant_SubmissionReminder' option in the Email type dropdown"
playwright-cli click ".mx-name-actionButton3" >/dev/null 2>&1
sleep 3

# The reminder detail popup (Main.Remind_Consultant_Tester) collects the fields
# the template interpolates. Scope every selector to the popup: Mendix leaves
# CLOSED dialogs in the DOM, and .mx-name-textBox2 means "Email" on the page
# behind and "Days overdue" inside this popup — an unscoped selector would hit
# whichever the DOM happens to yield first.
if playwright-cli eval "() => String(!!document.querySelector('.modal-content .mx-name-textBox10'))" 2>/dev/null | sed -n '2p' | grep -qi true; then
  tt_fill ".modal-content .mx-name-textBox1 input" "E2E Consultant"
  tt_fill ".modal-content .mx-name-textBox10 input" "Mon 01 - Sun 07"
  tt_fill ".modal-content .mx-name-textBox2 input" "3"
  playwright-cli click ".modal-content .mx-name-actionButton1" >/dev/null 2>&1
  sleep 3
else
  echo "no reminder detail popup appeared — assuming the tester sent directly"
fi

# 3) Read the mail back and assert on it.
MSG=$(tt_mail_message "$TS" "$TAG") \
  || tt_fail "reminder email for '$RECIP' not received within timeout"

echo "--- received message ---"
printf '%s\n' "$MSG" | head -20
echo "------------------------"

printf '%s' "$MSG" | grep -qi "subject:" \
  || tt_fail "message came back without a subject line"

# The reminder must actually read like a timesheet reminder, not just be any
# mail that happened to land in the inbox.
printf '%s' "$MSG" | grep -qiE "timesheet|reminder|submit" \
  || tt_fail "message body does not look like a submission reminder: $(printf '%s' "$MSG" | head -3)"

echo "PASS: consultant submission-reminder email (trigger -> deliver -> read)"
