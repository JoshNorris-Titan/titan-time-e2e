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
# HOW IT PROVES IT. Main.ENUM_EmailType has twelve values, and Main.EmailTester
# can send any one of them on demand. So the step sends all twelve, giving each a
# DISTINCT recipient address derived from the type name, and then reads the Emails
# Sent admin page once. A type whose template is missing produces no row, and the
# per-type address is what says which one.
#
# That indirection is deliberate. Counting twelve rows would prove only that
# twelve arrived; addressing each one by type is what turns "some emails are
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
# Sends twelve emails. They are queued rather than delivered, and the environment
# guard on the send event decides whether they ever leave.
# tt-timeout: 15m
#   Twelve sends, each with a combobox pick and a popup to dismiss, take ~230s on
#   their own; then the two-minute mail queue has to run before any of them can be
#   read back, and each poll round re-opens the Emails Sent page. Measured over 10m
#   at 20 rounds, so the loop is 8 and the budget has room around it.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

# The twelve values of Main.ENUM_EmailType, read from the model on 2026-08-26.
# If someone adds a thirteenth, this list is what makes the step notice.
#
# ForgotPassword was the twelfth, added 2026-08-26 with the self-service password
# reset. It is the type most likely to be missing on an environment restored from
# before that date, and the one whose absence is worst: ACT_Password_Forgot has
# already replaced the user's password by the time the send is skipped, so a
# missing row locks them out with no way back in.
#
# These are the enum value NAMES, which is what keys each type's recipient
# address. They are not necessarily what the dropdown displays - it displays
# captions, and ForgotPassword's caption is "Forgot Password". See et_pick_type.
TYPES="ToConsultant_SubmissionReminder ToConsultant_RejectionNotice \
ToManager_ApprovalRequest ToManager_ApprovalReminder ToManager_HoursNotice \
ToCustomer_ApprovalRequest ToCustomer_ApprovalReminder NewAccount \
ChangePassword ToConsultantApprovedRequest ToManager_ForApproval ForgotPassword"

# ---------------------------------------------------------------------- helpers

et_addr() {  # a recipient unique to one email type
  printf 'tmpl-%s@%s' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" "${TT_MAIL_DOMAIN:-e2e.local}"
}

# Selectors are decided once, from whichever naming the environment actually has.
SEL_EMAIL=""; SEL_TYPE=""; SEL_SEND=""
et_open_tester() {
  local v
  v="$(tt_open_email_tester)" || return 1
  case "$v" in
    new) SEL_EMAIL=".mx-name-txtTesterEmail"; SEL_TYPE=".mx-name-cbTesterEmailType"; SEL_SEND=".mx-name-btnTesterSend" ;;
    *)   SEL_EMAIL=".mx-name-textBox2";       SEL_TYPE=".mx-name-comboBox1";         SEL_SEND=".mx-name-actionButton3" ;;
  esac
  return 0
}

# et_pick_type — choose one value in the enum combobox.
#
# THE DROPDOWN SHOWS CAPTIONS, NOT NAMES. The tester's picker is the Mendix
# Combobox bound to Main.EmailHelper.EmailType, so each option renders the enum
# value's CAPTION. For eleven of the twelve values the caption happens to be
# identical to the name, which is why matching on the name worked for a year and
# looked like a rule. It is a coincidence. ForgotPassword, added 2026-08-26, is
# captioned "Forgot Password" - with a space - so an exact match on the name
# found nothing and the step reported the type as "not offered", i.e. as though
# the enum and the dropdown had diverged, when nothing had diverged at all.
#
# So: try the exact name first (unchanged for the eleven), then fall back to a
# comparison that ignores case and every non-alphanumeric character, which makes
# "Forgot Password", "forgot_password" and "ForgotPassword" the same string. The
# twelve names stay distinct under that flattening, so it cannot silently pick a
# neighbour - and if a future value ever does collide, the ambiguous case says so
# rather than guessing.
#
# The name is still what keys the recipient address; only the MATCHING is
# caption-aware. On a miss, return what the dropdown actually offered rather than
# a bare count, so the next divergence is read off the failure instead of hunted.
et_pick_type() {
  playwright-cli click "$SEL_TYPE" >/dev/null 2>&1
  sleep 1
  playwright-cli eval "() => { const os=[...document.querySelectorAll('[role=option]')]; const txt=e=>(e.innerText||'').trim(); const norm=s=>s.toLowerCase().replace(/[^a-z0-9]/g,''); const want='$1'; let o=os.find(e=>txt(e)===want); if(!o){ const m=os.filter(e=>norm(txt(e))===norm(want)); if(m.length===1){ o=m[0]; } else if(m.length>1){ return 'ambiguous:'+m.map(txt).join(', '); } } if(!o) return 'notoffered:'+os.map(txt).filter(Boolean).join(', '); o.click(); return 'picked'; }" 2>/dev/null | _tt_eval_str
}

# --------------------------------------------------------------- 1. mark the page
# Done first: everything sent after this point is what the step is allowed to see.
tt_mail_prepare

# ------------------------------------------------------------ 2. send all twelve
et_open_tester || tt_fail "could not open the Email Tester as ${TT_ADMIN_USER:-MxAdmin} (Admin Hub -> Email Tester)"

sent=""
notoffered=""
offered=""
for t in $TYPES; do
  addr="$(et_addr "$t")"
  # tt_fill is FATAL by design - a silent no-write is worse than a stop - so the
  # "|| continue" that used to be here was dead code, and redirecting its stderr
  # to /dev/null sent the explanation there too. That is how this test came to
  # exit 1 having printed NOTHING AT ALL: the first fill hit a selector matching
  # no elements, tt_fill called tt_fail, and the message went to /dev/null.
  # Check the field is present first, then fill and let a real failure speak.
  if ! playwright-cli eval "() => String(!!document.querySelector('$SEL_EMAIL input'))" 2>/dev/null | grep -qiw true; then
    notoffered="$notoffered $t(no-email-field)"
    continue
  fi
  tt_fill "$SEL_EMAIL input" "$addr" >/dev/null
  r="$(et_pick_type "$t")"
  case "$r" in
    picked) ;;
    notoffered:*)
      notoffered="$notoffered $t"
      [ -z "$offered" ] && offered="${r#notoffered:}"
      continue ;;
    ambiguous:*)
      notoffered="$notoffered $t(matched several options: ${r#ambiguous:})"
      continue ;;
    *)
      notoffered="$notoffered $t(combobox:$r)"
      continue ;;
  esac
  playwright-cli click "$SEL_SEND" >/dev/null 2>&1
  sleep 2
  tt_clear_dialogs 6 >/dev/null 2>&1 || true
  # COMPLETE THE DETAIL POPUP WITH ITS OWN CONTROLS.
  # Some types open a page popup for what the template interpolates. Probed live,
  # it is "Remind Consultant Email" with
  #     mx-name-textBox1 (recipient name) / textBox10 (week range) / textBox2 (days)
  #     mx-name-actionButton1 = Send, actionButton2 = Cancel
  # Two earlier attempts got this wrong in opposite directions: leaving the popup
  # open blocked the combobox for every LATER type (one sent, ten "not offered"),
  # and CLOSING it cancelled the send (zero of eleven raised, which read as eleven
  # missing template rows). verify-consultant-reminder-mail passes because it
  # fills these exact fields and presses Send, so do that.
  #
  # playwright-cli directly, not tt_fill: tt_fill is fatal by design and a popup
  # that does not happen to have these fields must not end the run.
  if playwright-cli eval "() => String(!!document.querySelector('.modal-content .mx-name-actionButton1'))" 2>/dev/null | sed -n '2p' | grep -qi true; then
    playwright-cli fill ".modal-content .mx-name-textBox1 input" "E2E Consultant" >/dev/null 2>&1 || true
    playwright-cli fill ".modal-content .mx-name-textBox10 input" "Mon 01 - Sun 07" >/dev/null 2>&1 || true
    playwright-cli fill ".modal-content .mx-name-textBox2 input" "3" >/dev/null 2>&1 || true
    playwright-cli click ".modal-content .mx-name-actionButton1" >/dev/null 2>&1
    sleep 3
    tt_clear_dialogs 6 >/dev/null 2>&1 || true
  fi
  # Whatever happened, do not carry a popup into the next type - that is what
  # produced the "not offered" cascade.
  playwright-cli eval "() => { const m=[...document.querySelectorAll('.modal-content')].filter(d=>d.offsetParent!==null); const d=m[m.length-1]; if(!d) return 'none'; const b=[...d.querySelectorAll('button')].filter(x=>x.offsetParent!==null).find(x=>/^cancel\$/i.test((x.innerText||'').trim())) || [...d.querySelectorAll('.modal-header button, button.close')].filter(x=>x.offsetParent!==null)[0]; if(b){ b.click(); return 'closed'; } return 'nobutton'; }" >/dev/null 2>&1
  sleep 2
  sent="$sent $t"
  et_open_tester >/dev/null 2>&1 || true
done

if [ -n "$notoffered" ]; then
  echo "FAIL: verify-email-templates-present - the tester did not offer these types:$notoffered"
  echo "      Main.ENUM_EmailType and the tester's dropdown have diverged, so those types"
  echo "      could not be exercised at all."
  if [ -n "$offered" ]; then
    echo "      The dropdown offered: $offered"
    echo "      Those are CAPTIONS. A value whose caption merely reads differently from its"
    echo "      name is matched anyway (case and punctuation are ignored), so a type listed"
    echo "      above is one the dropdown genuinely does not carry - a value added to the"
    echo "      enum since this list was written, or one the tester cannot select."
  fi
  exit 1
fi

# ------------------------------------------------- 3. read them back, patiently
# SENDING IS NOT DELIVERY. Nothing leaves until the queue scheduled event runs,
# which is every two minutes - verify-consultant-reminder-mail needs ~162s for a
# SINGLE message to appear. Reading the page once, immediately after sending
# eleven, reported "raised 0 of 11" and pointed at eleven missing templates when
# the only thing wrong was that none of them had been queued out yet.
#
# So poll until every type is accounted for, or the budget runs out, and only
# then decide. Re-opening the page each round is what re-queries it.
rows=""
found=0
for round in $(seq 1 8); do
  _tt_mail_open >/dev/null 2>&1 || true
  _tt_mail_sort_newest >/dev/null 2>&1 || true
  rows="$(_tt_mail_new_rows)"
  found=0
  for t in $TYPES; do
    printf '%s\n' "$rows" | grep -qi -- "$(et_addr "$t")" && found=$((found+1))
  done
  [ "$found" -ge 12 ] && break
  echo "  round $round: $found of 12 accounted for"
  [ "$round" -lt 8 ] && sleep 20
done

missing=""
for t in $TYPES; do
  if ! printf '%s\n' "$rows" | grep -qi -- "$(et_addr "$t")"; then
    missing="$missing $t"
  fi
done

echo "  raised $found of 12 email types"

if [ -n "$missing" ]; then
  echo "FAIL: verify-email-templates-present - no message was raised for:$missing"
  if [ "$found" -eq 0 ]; then
    echo "      NOTHING was raised for any type. Before hunting twelve missing templates,"
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

echo "PASS: verify-email-templates-present - all 12 ENUM_EmailType values raised a message, so each has a template row"
