#!/usr/bin/env bash
# verify-email-templates-present.test.sh
#
# tt-timeout: 15m
#   Twelve sends, each with a combobox pick and a popup to complete, take ~230s on
#   their own; then the two-minute mail queue has to run before any of them can be
#   read back, and each poll round re-reads the Emails Sent page. Measured over 10m
#   at 20 rounds, so the loop is 8 and the budget has room around it.
#
#   KEPT AT THE TOP DELIBERATELY. This line used to sit at the foot of the header,
#   and when the header below grew it landed on line 78 - past the first 40 lines,
#   which was all run-tests.sh read. The declaration was silently ignored, the 4m
#   default applied, and the step was killed six types into twelve and reported as
#   a plain TIMEOUT. The runner now reads the whole header, but a directive is
#   still easiest to trust where it cannot be pushed anywhere.
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
# HOW IT PROVES IT. Main.ENUM_EmailType has twelve values and Main.EmailTester can
# send some of them on demand. The step sends each one it can, giving each a
# DISTINCT recipient address derived from the type name, then reads the Emails
# Sent admin page. A type whose template is missing produces no row, and the
# per-type address is what says which one.
#
# WHAT CHANGED, AND WHY IT MATTERED
#
# The earlier version sent all twelve, then reported every type with no row as
# "no EmailTemplate row". That accusation is not supported by what it observed:
# no row also means "the send never happened", and there are several ways for
# that to be true. Two of them were live on this app:
#
#   1. THE TESTER CANNOT SEND THREE OF THE TWELVE. Main.ACT_SendTemplate1 splits
#      on $EmailHelper/EmailType and opens a per-type detail popup — but only for
#      nine values. Read from the live model on 2026-08-27, the cases
#          ToConsultantApprovedRequest, ToManager_ForApproval, ForgotPassword
#      (and the mandatory (empty) case) run straight into the merge and out of the
#      end event. No popup, no send, nothing to read back — whether or not their
#      template rows exist. The old test sent them, saw no row, and reported three
#      missing templates. That accusation could never have been anything else, and
#      it is also what the earlier "REAL FINDING — two email types have no template
#      row on dev" (commit e62b2a0, ToConsultantApprovedRequest and
#      ToManager_ForApproval) actually was.
#
#   2. THE DETAIL POPUP IS NOT ONE SHAPE. It was driven with the field names of
#      ONE popup (Main.Remind_Consultant_Tester: textBox1 / textBox10 / textBox2,
#      Send = actionButton1). The nine popups have different field sets —
#      Manager_Approval_Tester is textBox1 + textBox9, Manager_Remind_Tester is
#      textBox1..textBox4, OverHours_tester has seven — so on most of them those
#      fills hit nothing. Worse, every selector was scoped to `.modal-content`,
#      which matches CLOSED popups Mendix leaves in the DOM as well as the live
#      one: as soon as two match, Playwright refuses the action outright, and with
#      the output sent to /dev/null a SEND THAT NEVER HAPPENED looked exactly like
#      a missing template row.
#
# So this version separates the two questions it was conflating, and reports them
# separately:
#
#   * did the send happen at all?  — the popup is found, marked with a class of
#     this test's own so every later selector can only match the LIVE one, every
#     blank field in it is filled, and the Send button is located by its caption
#     rather than by an auto-generated widget name. Failures there are reported as
#     failures to send, naming the type and the reason.
#   * was a message raised for a send that did happen? — only that gets reported
#     as a template-row problem, and even then the message lists the other things
#     it could be, because this test cannot see the database.
#
# WHAT IT DOES NOT PROVE. That the wording is right, or that anything was
# delivered. Only that a template exists and a message was raised for every type
# the Email Tester can send. Delivery needs the send event, which runs on its own
# schedule. And it proves NOTHING about the three types the tester cannot send —
# including ForgotPassword, whose missing row is the worst of the twelve
# (Core.ACT_Password_Forgot has already replaced the password by the time the send
# is skipped). Covering those needs a branch for them in Main.ACT_SendTemplate1,
# or a different route to the template list; the step says so rather than
# pretending.
#
# ASSUMPTION, stated because it could not be checked without running: that
# Main.SUB_SendEmail_Template sends to the address in the tester's own email
# field. If it does not, every type will look missing at once — which is a
# distinctive enough failure to recognise, and the message below says so.
#
# Sends up to twelve emails. They are queued rather than delivered, and the
# environment guard on the send event decides whether they ever leave.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

# The twelve values of Main.ENUM_EmailType, read from the model on 2026-08-27.
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

# The types Main.ACT_SendTemplate1 had no branch for when this was written. It is
# NOT used to skip them — the run still tries all twelve and decides from what the
# app actually does. It is here so the report can say "still true" or "this list is
# stale" instead of leaving the reader to guess.
KNOWN_NO_BRANCH="ToConsultantApprovedRequest ToManager_ForApproval ForgotPassword"

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

# et_mark_popup — find the LIVE detail popup and describe it.
#
# Mendix leaves closed popups in the DOM, so `.modal-content` on its own can match
# several nodes; Playwright then refuses every fill and click against it, silently
# when the output is discarded. This takes the last VISIBLE one, tags it with a
# class no Mendix widget uses, and every later selector is scoped to that tag — so
# an action can only ever reach the popup that is actually on screen.
#
# Prints  none
#     or  popup|<title>|<blank field widget names, comma separated>|<send button widget name>
et_mark_popup() {
  playwright-cli eval "() => { const vis=[...document.querySelectorAll('.modal-content')].filter(d=>d.offsetParent!==null); document.querySelectorAll('.tt-live-popup').forEach(e=>e.classList.remove('tt-live-popup')); const d=vis[vis.length-1]; if(!d) return 'none'; d.classList.add('tt-live-popup'); const wname=el=>{ let p=el; for(let k=0;k<8&&p;k++){ const m=((p.className||'')+'').match(/mx-name-[A-Za-z0-9_]+/); if(m) return m[0]; p=p.parentElement; } return ''; }; const blanks=[...d.querySelectorAll('input')].filter(i=>i.offsetParent!==null && !i.disabled && !i.readOnly && !((i.value||'').trim())).map(wname).filter(Boolean); const btns=[...d.querySelectorAll('button')].filter(b=>b.offsetParent!==null); const send=btns.find(b=>/^send\$/i.test((b.innerText||'').trim())) || btns.find(b=>/btn-success/.test((b.className||'')+'')); const title=(((d.querySelector('.modal-header')||{}).innerText)||'').replace(/\s+/g,' ').trim(); return 'popup|'+title+'|'+blanks.join(',')+'|'+(send?wname(send):''); }" 2>/dev/null | _tt_eval_str
}

et_popup_open() {  # 'open' while a popup is on screen, 'gone' once it is not
  playwright-cli eval "() => { const vis=[...document.querySelectorAll('.modal-content')].filter(d=>d.offsetParent!==null); return vis.length ? 'open' : 'gone'; }" 2>/dev/null | _tt_eval_str
}

et_force_close() {  # last resort: Cancel out of whatever popup is still standing
  playwright-cli eval "() => { const m=[...document.querySelectorAll('.modal-content')].filter(d=>d.offsetParent!==null); const d=m[m.length-1]; if(!d) return 'none'; const b=[...d.querySelectorAll('button')].filter(x=>x.offsetParent!==null).find(x=>/^cancel\$/i.test((x.innerText||'').trim())) || [...d.querySelectorAll('.modal-header button, button.close')].filter(x=>x.offsetParent!==null)[0]; if(b){ b.click(); return 'closed'; } return 'nobutton'; }" 2>/dev/null | _tt_eval_str
}

# --------------------------------------------------------------- 1. mark the page
# Done first: everything sent after this point is what the step is allowed to see.
tt_mail_prepare

# ------------------------------------------------------------ 2. send what we can
et_open_tester || tt_fail "could not open the Email Tester as ${TT_ADMIN_USER:-MxAdmin} (Admin Hub -> Email Tester)"

sent=""        # the send went through: a message should follow
nobranch=""    # the tester has no branch for this type: nothing was ever sent
sendfail=""    # a popup appeared but the send could not be completed
notoffered=""  # the dropdown does not offer this type at all
offered=""     # what the dropdown listed, when a type was missing from it
for t in $TYPES; do
  addr="$(et_addr "$t")"
  # tt_fill is FATAL by design - a silent no-write is worse than a stop - so the
  # "|| continue" that used to be here was dead code, and redirecting its stderr
  # to /dev/null sent the explanation there too. That is how this test came to
  # exit 1 having printed NOTHING AT ALL: the first fill hit a selector matching
  # no elements, tt_fill called tt_fail, and the message went to /dev/null.
  # Check the field is present first, then fill and let a real failure speak.
  if ! playwright-cli eval "() => String(!!document.querySelector('$SEL_EMAIL input'))" 2>/dev/null | sed -n '2p' | grep -qiw true; then
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

  # Wait for the detail popup. Nine of the twelve types open one; the rest end the
  # microflow without sending anything, and no popup is exactly how that shows up
  # in the browser. Give it a fair wait before concluding that.
  popup=""
  for _ in $(seq 1 8); do
    sleep 1
    popup="$(et_mark_popup)"
    [ "${popup%%|*}" = "popup" ] && break
  done

  if [ "${popup%%|*}" != "popup" ]; then
    nobranch="$nobranch $t"
    echo "  $t: no detail popup - Main.ACT_SendTemplate1 has no send branch for this type"
    tt_clear_dialogs 4 >/dev/null 2>&1 || true
    et_open_tester >/dev/null 2>&1 || true
    continue
  fi

  title="$(printf '%s' "$popup" | cut -d'|' -f2)"
  blanks="$(printf '%s' "$popup" | cut -d'|' -f3 | tr ',' ' ')"
  sendbtn="$(printf '%s' "$popup" | cut -d'|' -f4)"
  echo "  $t: popup '$title'"

  # Fill every field the popup left blank. WHICH fields differ per type, so they
  # are discovered rather than hardcoded, and the value is one that is valid for
  # both a String and an Integer attribute (DaysOverdue and Count are Integer;
  # every other Main.EmailHelper attribute a tester popup shows is String). The
  # wording of these emails is not what this step asserts - only that a message
  # was raised at all.
  for w in $blanks; do
    tt_fill_commit ".tt-live-popup .$w input" "3"
  done

  if [ -z "$sendbtn" ]; then
    sendfail="$sendfail $t(no-send-button)"
    et_force_close >/dev/null 2>&1 || true
    sleep 2
    et_open_tester >/dev/null 2>&1 || true
    continue
  fi

  # Re-mark before the click: a fill commits, Mendix re-renders the popup, and a
  # re-render can drop a class this test added to it.
  et_mark_popup >/dev/null 2>&1 || true
  clickout="$(playwright-cli click ".tt-live-popup .$sendbtn" 2>&1)"
  case "$clickout" in
    *"strict mode violation"*|*"### Error"*|*"Timeout"*)
      sendfail="$sendfail $t(send-click:$(printf '%s' "$clickout" | tr '\n' ' ' | cut -c1-80))"
      et_force_close >/dev/null 2>&1 || true
      sleep 2
      et_open_tester >/dev/null 2>&1 || true
      continue ;;
  esac

  # The send is synchronous and the popup closes itself when it finishes. Wait for
  # that rather than for a fixed three seconds: closing it early is how an earlier
  # version cancelled every send and read the result as eleven missing templates.
  gone=""
  for _ in $(seq 1 12); do
    sleep 1
    [ "$(et_popup_open)" = "gone" ] && { gone="yes"; break; }
  done

  if [ -z "$gone" ]; then
    # Still up: either a dialog is in the way, or the send did not complete. Say
    # which, then clear it so one odd type cannot cascade into the next.
    tt_clear_dialogs 4 >/dev/null 2>&1 || true
    if [ -n "${TT_DIALOG_BLOCKED:-}" ]; then
      sendfail="$sendfail $t(dialog:$(printf '%s' "$TT_DIALOG_BLOCKED" | cut -c1-60))"
    else
      sendfail="$sendfail $t(popup-stayed-open)"
    fi
    et_force_close >/dev/null 2>&1 || true
    sleep 2
    et_open_tester >/dev/null 2>&1 || true
    continue
  fi

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

sent_count=0; for t in $sent; do sent_count=$((sent_count+1)); done
echo "  sent $sent_count of 12 types through the Email Tester"

# ------------------------------------------------- 3. read them back, patiently
# SENDING IS NOT DELIVERY. Nothing leaves until the queue scheduled event runs,
# which is every two minutes - verify-consultant-reminder-mail needs ~162s for a
# SINGLE message to appear. Reading the page once, immediately after sending,
# reported "raised 0 of 11" and pointed at eleven missing templates when the only
# thing wrong was that none of them had been queued out yet.
#
# So poll until every type that was actually SENT is accounted for, or the budget
# runs out, and only then decide.
#
# _tt_mail_refresh, NOT _tt_mail_open. The rows this waits for are written by the
# queue's scheduled event, on the server, with nothing to tell this browser session
# about them - so the grid only shows them after a real re-query. _tt_mail_open
# returns immediately once `.mx-name-gridEmailsSent` is on screen, which after
# round 1 it always is, so rounds 2-8 re-read the SAME rendered rows they read the
# first time. The loop looked patient and was not: it could only ever report what
# had already arrived by the time the last send finished, seconds earlier, and
# every later arrival came back as "sent, but no message was raised" - the exact
# missing-template accusation this file was rewritten to stop making.
# _tt_mail_refresh reloads the page and re-sorts, which is what the other mail
# helpers (tt_mail_message, tt_mail_token) poll with.
rows=""
found=0
for round in $(seq 1 8); do
  if [ "$round" -eq 1 ]; then
    _tt_mail_open >/dev/null 2>&1 || true
    _tt_mail_sort_newest >/dev/null 2>&1 || true
  else
    _tt_mail_refresh >/dev/null 2>&1 || true
  fi
  rows="$(_tt_mail_new_rows)"
  found=0
  for t in $sent; do
    printf '%s\n' "$rows" | grep -qi -- "$(et_addr "$t")" && found=$((found+1))
  done
  [ "$found" -ge "$sent_count" ] && break
  echo "  round $round: $found of $sent_count sent types accounted for"
  [ "$round" -lt 8 ] && sleep 20
done

norow=""
for t in $sent; do
  if ! printf '%s\n' "$rows" | grep -qi -- "$(et_addr "$t")"; then
    norow="$norow $t"
  fi
done

newrows="$(printf '%s\n' "$rows" | grep -c . || true)"
echo "  raised $found of $sent_count sent types ($newrows new rows visible on the Emails Sent page)"

fail=0

if [ -n "$nobranch" ]; then
  fail=1
  echo "FAIL: verify-email-templates-present - the Email Tester cannot send:$nobranch"
  echo "      Picking the type and pressing Send Template opened no detail popup, which is"
  echo "      what Main.ACT_SendTemplate1 does when its split has no branch for the value:"
  echo "      the flow runs into the merge and ends without sending anything."
  echo "      THIS IS NOT A MISSING TEMPLATE ROW. Nothing was sent, so nothing can be"
  echo "      concluded about whether the rows exist - including ForgotPassword, whose"
  echo "      absence would lock a user out after Core.ACT_Password_Forgot has already"
  echo "      replaced their password. Fix by adding a branch and a tester popup per type"
  echo "      in Main.ACT_SendTemplate1; until then these types are untested here."
  echo "      Known to be branchless when this test was written:$KNOWN_NO_BRANCH"
fi

if [ -n "$sendfail" ]; then
  fail=1
  echo "FAIL: verify-email-templates-present - the send could not be completed for:$sendfail"
  echo "      The detail popup appeared, so the type IS wired, but pressing Send did not go"
  echo "      through. Read the reason in brackets: a blocked dialog is the app saying"
  echo "      something, a strict mode violation is a selector matching a closed popup as"
  echo "      well as the live one, and popup-stayed-open means the microflow never"
  echo "      returned. None of these say anything about the template rows."
fi

if [ -n "$norow" ]; then
  fail=1
  echo "FAIL: verify-email-templates-present - sent, but no message was raised for:$norow"
  echo "      The most likely cause is that Email_Connector.EmailTemplate has no row for"
  echo "      that type, so Main.SUB_SendEmail_Template breaks out of its loop silently -"
  echo "      no error, no log line, no queued message. The wording lives in the database,"
  echo "      not the model, so it is fixed on the environment."
  echo "      BEFORE ADDING A ROW, CHECK THE ONE THAT MAY ALREADY BE THERE. The retrieve is"
  echo "      [TemplateName = \$TemplateName], where TemplateName is toString() of the enum"
  echo "      - the value's NAME, 'ToConsultant_SubmissionReminder', not its caption and not"
  echo "      a friendly title. A row that exists under any other spelling, or with stray"
  echo "      whitespace, is invisible to that retrieve and looks exactly like this."
  echo "      Two other readings this step cannot rule out: the message was raised but is"
  echo "      not on the first page of the Emails Sent grid (it shows 20 rows; $newrows new"
  echo "      ones were visible), or the send failed inside the queue for that type."
  if [ "$found" -eq 0 ] && [ "$sent_count" -gt 0 ]; then
    echo "      NOTHING was raised for any type that was sent. Before hunting missing"
    echo "      templates, check the assumption in this file's header: that the tester sends"
    echo "      to the address in its own email field. If it sends somewhere else, every"
    echo "      type looks missing even when all the templates are fine."
  fi
fi

[ "$fail" -eq 0 ] || exit 1

echo "PASS: verify-email-templates-present - all $sent_count types the Email Tester can send raised a message, so each has a template row"
