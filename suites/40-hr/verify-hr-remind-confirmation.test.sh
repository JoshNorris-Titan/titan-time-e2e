#!/usr/bin/env bash
# tt-timeout: 15m
# verify-hr-remind-confirmation.test.sh
#
# TT-768: every Remind button on the HR dashboard tells HR the reminder went out,
# and to whom; after a customer reminder that card's Remind is unavailable and
# inert (TT-767).
#
# WHY THIS EXISTS. Remind used to finish silently, so HR could not tell a sent
# reminder from a click that did nothing, and pressed it again. Since model
# fa8f6d17 each of the three remind flows ends with a blocking Information message,
# "Reminder sent to {1} ({2}).", OK button:
#   Pending tab      btnRemind         Main.ACT_Email_RemindConsultant
#                                      {1} the consultant's name, {2} their email
#   Manager approval btnManagerRemind  Main.ACT_Email_Remind -> ACT_Email_RemindManager
#                                      {1} the project manager's name, {2} their email
#   Client approval  btnClientRemind   Main.ACT_Email_Remind -> ACT_Email_RemindCustomer
#                                      {1} the project's contact name, {2} contact email
# (ui/src/flows/overrides/Main.ReminderSent.ts records the model's text; the
# generator refuses all three flows on a Java action, so the mirror cannot print
# them.) The Pending tab's btnRemind had no test at all; the other two were pressed
# by helpers that never looked at what came back.
#
# WHAT IT ASSERTS
#   A. Pending: Remind on an E2E consultant's row shows "Reminder sent to <that
#      consultant> (<an email>)." - and the email is the account's own when HR can
#      read it.
#   B. Manager approval: Remind on E2E Consultant's card shows "Reminder sent to
#      E2E ProjectManger (<an email>)." - the fixture projects' manager.
#   C. Client approval: Remind on E2E Consultant / E2E Customer Approval shows
#      exactly "Reminder sent to Approver E2E (<FX_APPROVER_EMAIL>)." - the
#      project's contact from lib/_fixtures.sh;
#   D. after OK, that card shows btnClientRemindBlocked instead of btnClientRemind,
#      and clicking the look-alike opens nothing (TT-767).
#
# WHAT MAKES IT RED. Any of the three flows losing its message, or naming the wrong
# recipient (the acting HR user, the consultant on a customer reminder, ...); the
# customer card not gating after the send; the gated look-alike opening a page.
#
# ITS OWN DATA. The Client Approval cards are normally all gated by the time 40-hr
# runs - the 30-approval token specs remind the shared approver address, and the
# gate keys on it (lib/_login_core.sh). A timesheet submitted AFTER today's reminder
# re-enables the button, so when no E2E Customer Approval card can be reminded this
# submits one fresh week as e2e_consultant (tt_consultant_submit_project_row), and
# likewise one on E2E Manager Approval when the Manager approval tab is empty. Both
# leave a pending entry, as the 30-approval specs do.
#
# RUN ORDER. It gates E2E Customer Approval's newest card for the rest of the day,
# which suites/60-email/verify-hr-remind-daily-gate documents and accepts ("IF IT
# IS ALREADY GATED WHEN THIS STARTS that is not a failure").
#
# Consumes: three reminder emails (an e2e consultant, the fixture manager, the
# fixture approver), and at most two submitted weeks for e2e_consultant.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/lib/_authz.sh"

CONSULTANT="E2E Consultant"
CUSER="e2e_consultant"
MGR_PROJECT="E2E Manager Approval"
CUST_PROJECT="E2E Customer Approval"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

# remind_message — the confirmation text the LAST Remind raised. Reading and
# dismissing it is lib/_login_tokens.sh's job since #148: tt_hr_remind_confirm (and
# tt_hr_remind_e2e_entry, which calls it) waits for the blocking "Reminder sent to
# ..." message, clicks OK and leaves what it read in TT_REMIND_CONFIRM_TEXT. A second
# reader here would find the dialog already gone. Echoes NONE when nothing came up.
remind_message() {
  printf '%s' "${TT_REMIND_CONFIRM_TEXT:-NONE}"
}

# sent_to <message> — the "<name> (<email>)" part, or '' when the shape is wrong.
sent_to() {
  printf '%s' "$1" | grep -oE 'Reminder sent to [^()]+ \([^()@ ]+@[^()@ ]+\)\.' | head -1 \
    | sed -e 's/^Reminder sent to //' -e 's/\.$//'
}

# account_email <full name> — the account's Email as HR can read it, or ''.
account_email() {
  local v
  v="$(tt_authz_readback "//Administration.Account[FullName = '$1']" Email)"
  case "$v" in ERR:*) printf '' ;; *) printf '%s' "$v" ;; esac
}

tt_login "e2e_hr" "$TT_HR_READY"

# =================================================================== A. Pending
tt_hr_click_tab "Pending"
sleep 3
# The tab opens on its newest week with a gap. Find an E2E consultant's row there
# or, failing that, in the next few weeks of the list.
PICK=""
for i in 0 1 2 3 4 5; do
  PICK="$(ev "() => { const rows=[...document.querySelectorAll('.mx-name-galPending .mx-name-cardPendingRow')]; const row=rows.find(c=>/^E2E Consultant/.test(((c.querySelector('.mx-name-txtPendingConsultant')||{}).innerText||'').trim()) && c.querySelector('.mx-name-btnRemind')); if(!row) return ''; const who=row.querySelector('.mx-name-txtPendingConsultant').innerText.trim(); row.querySelector('.mx-name-btnRemind').click(); return who; }")"
  # The Remind was clicked inside the eval above. Read and dismiss its confirmation
  # here, in this shell, so TT_REMIND_CONFIRM_TEXT survives for remind_message.
  if [ -n "$PICK" ]; then TT_REMIND_CONFIRM_TEXT=""; tt_hr_remind_confirm; break; fi
  ev "() => { const it=[...document.querySelectorAll('.mx-name-galAvailableWeeks .mx-name-txtAvailableWeekRange')][$i + 1]; if(!it) return 'END'; (it.closest('.widget-gallery-item')||it).click(); return 'OK'; }" >/dev/null
  sleep 3
done
if [ -z "$PICK" ]; then
  bad "A: no E2E consultant row with a Remind button in the first six Pending weeks - the e2e consultants should have gaps in past weeks after 00-setup's clear"
else
  MSG="$(remind_message)"
  TO="$(sent_to "$MSG")"
  case "$TO" in
    "$PICK ("*")")
      WANT="$(account_email "$PICK")"
      if [ -n "$WANT" ] && [ "$TO" != "$PICK ($WANT)" ]; then
        bad "A: Pending remind for '$PICK' says [$MSG]; the account's email is '$WANT'"
      else
        if [ -n "$WANT" ]; then note "A ok: [$MSG] - matches the email on the account"; else note "A ok: [$MSG]"; fi
      fi ;;
    *) bad "A: Pending remind for '$PICK' showed [$MSG]; expected 'Reminder sent to $PICK (<email>).'" ;;
  esac
fi

# remind_submitted <tab> <project> - Remind the card for the week JUST submitted
# (TT_SUBMITTED_WEEK), selected directly instead of walking every week of the tab:
# a walk over ~15 weeks at up to 8 s each is what ran this spec past its budget on
# 2026-10-06. Polls up to ~60 s, because a fresh submission reaches the queue
# asynchronously. Same 0/1/2 as tt_hr_remind_e2e_entry.
remind_submitted() {
  local i rc=1
  tt_login "e2e_hr" "$TT_HR_READY" >/dev/null 2>&1
  tt_hr_click_tab "$1"
  sleep 3
  for i in $(seq 1 6); do
    if tt_hr_select_week "${TT_SUBMITTED_WEEK:-}"; then
      tt_hr_remind_here "$CONSULTANT" "$2"; rc=$?
      [ "$rc" -ne 1 ] && return "$rc"
    fi
    sleep 7
    tt_hr_click_tab "$1"
    sleep 3
  done
  return 1
}

# =================================================================== B. Manager approval
# tt_hr_remind_e2e_entry returns 0 confirmed, 1 no remindable card, 2 reminded but
# the confirmation did not come or said something else. Only 1 is a reason to seed;
# 2 falls through to the message check below, which then names what it read.
mgr_remind() {
  tt_login "e2e_hr" "$TT_HR_READY" >/dev/null 2>&1
  tt_hr_click_tab "Manager approval"
  sleep 3
  tt_hr_remind_e2e_entry "$CONSULTANT" >/dev/null
}
TT_REMIND_CONFIRM_TEXT=""
mgr_remind; rc=$?
if [ "$rc" -eq 1 ]; then
  note "no $CONSULTANT card on Manager approval; submitting a fresh '$MGR_PROJECT' week to make one"
  tt_login "$CUSER" "My Timesheets"
  tt_consultant_submit_project_row "$MGR_PROJECT"
  remind_submitted "Manager approval" "$MGR_PROJECT"; rc=$?
  [ "$rc" -eq 1 ] && bad "B: still no remindable $CONSULTANT card on Manager approval after submitting week ${TT_SUBMITTED_WEEK:-?}"
fi
MSG="$(remind_message)"
TO="$(sent_to "$MSG")"
case "$TO" in
  "$FX_PROJECT_MANAGER ("*")")
    WANT="$(account_email "$FX_PROJECT_MANAGER")"
    if [ -n "$WANT" ] && [ "$TO" != "$FX_PROJECT_MANAGER ($WANT)" ]; then
      bad "B: manager remind says [$MSG]; the manager account's email is '$WANT'"
    else
      note "B ok: [$MSG]"
    fi ;;
  *) bad "B: manager remind showed [$MSG]; expected 'Reminder sent to $FX_PROJECT_MANAGER (<email>).'" ;;
esac

# =================================================================== C/D. Client approval
# Not CWEEK="$(...)": the helper must run in THIS shell, or the confirmation text it
# leaves in TT_REMIND_CONFIRM_TEXT dies with the subshell. The week label it prints
# goes through a file instead.
WKF="$(mktemp)"; trap 'rm -f "$WKF"' EXIT
cust_remind() {
  local rc
  tt_login "e2e_hr" "$TT_HR_READY" >/dev/null 2>&1
  tt_hr_click_tab "Client approval"
  sleep 3
  tt_hr_remind_e2e_entry "$CONSULTANT" "$CUST_PROJECT" > "$WKF"; rc=$?
  CWEEK="$(head -1 "$WKF")"
  return "$rc"
}
CWEEK=""
TT_REMIND_CONFIRM_TEXT=""
cust_remind; rc=$?
if [ "$rc" -eq 1 ]; then
  note "no remindable '$CUST_PROJECT' card (gated or absent); submitting a fresh week to re-enable Remind"
  tt_login "$CUSER" "My Timesheets"
  tt_consultant_submit_project_row "$CUST_PROJECT"
  remind_submitted "Client approval" "$CUST_PROJECT"; rc=$?
  CWEEK="${TT_SUBMITTED_WEEK:-}"
  [ "$rc" -eq 1 ] && tt_fail "C: still no remindable $CONSULTANT / '$CUST_PROJECT' card after submitting week ${TT_SUBMITTED_WEEK:-?}"
fi
MSG="$(remind_message)"
if [ "$MSG" = "Reminder sent to $FX_APPROVER_NAME ($FX_APPROVER_EMAIL). OK" ] || [ "$(sent_to "$MSG")" = "$FX_APPROVER_NAME ($FX_APPROVER_EMAIL)" ]; then
  note "C ok: [$MSG]"
else
  bad "C: customer remind showed [$MSG]; expected 'Reminder sent to $FX_APPROVER_NAME ($FX_APPROVER_EMAIL).'"
fi

# D. the same card, gated. The flow refreshes the tab, so re-pick the week first.
sleep 2
tt_hr_select_week "$CWEEK" >/dev/null 2>&1
CARD_JS="const cards=[...document.querySelectorAll('.mx-name-containerClientCard')]; const card=cards.find(c=>{ const t=c.innerText||''; return t.indexOf('$CONSULTANT')>=0 && t.indexOf('$CUST_PROJECT')>=0; });"
G=""
for i in $(seq 1 10); do
  G="$(ev "() => { $CARD_JS if(!card) return 'NOCARD'; return 'open='+(card.querySelector('.mx-name-btnClientRemind')?1:0)+' gated='+(card.querySelector('.mx-name-btnClientRemindBlocked')?1:0); }")"
  [ "$G" = "open=0 gated=1" ] && break
  sleep 1
done
if [ "$G" = "open=0 gated=1" ]; then
  note "D ok: the reminded card now shows the unavailable Remind"
  BEFORE="$(ev "() => { const d=$(_tt_dialog_js); return String(!!d) + '|' + location.pathname; }")"
  ev "() => { $CARD_JS const b=card && card.querySelector('.mx-name-btnClientRemindBlocked'); if(b){ b.click(); return 'clicked'; } return 'none'; }" >/dev/null
  sleep 3
  AFTER="$(ev "() => { const d=$(_tt_dialog_js); return String(!!d) + '|' + location.pathname; }")"
  if [ "$AFTER" = "$BEFORE" ]; then
    note "D ok: clicking the unavailable Remind opened nothing"
  else
    bad "D: clicking the unavailable Remind changed the screen ($BEFORE -> $AFTER) - TT-767 says it does nothing"
    tt_clear_dialogs 3 >/dev/null 2>&1
  fi
else
  bad "D: after the customer remind the $CONSULTANT / '$CUST_PROJECT' card in week '$CWEEK' reads [$G]; expected the gated look-alike only (open=0 gated=1)"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-hr-remind-confirmation - $fails problem(s) with the Remind confirmations (TT-768)."
  exit 1
fi
echo "PASS: verify-hr-remind-confirmation - all three Remind buttons confirm the send and name the right recipient, and the reminded customer card is gated and inert."
