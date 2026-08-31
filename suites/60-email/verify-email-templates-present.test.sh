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
#   EXPECT THIS STEP TO GET LONGER, not shorter. The 474s run of 2026-08-28 was
#   fast only because every send was miscounted as a failure: that left nothing to
#   read back, and the poll loop exited on its first round. Counting the sends
#   properly means the loop actually runs, and the read-back is now the expensive
#   half. Against that, ~12s per type comes back from the wait this no longer does,
#   and ~1s per popup field is paid for the re-mark. 15m still covers it.
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
# recipient address distinct BY TYPE AND BY RUN, then asks the Emails Sent admin
# page's recipient filter whether a message exists for that address. A type whose
# template is missing produces no message at all, because
# Main.SUB_SendEmail_Template breaks out of its loop before creating one.
#
# It asks whether the message EXISTS, not whether it was delivered. A QUEUED row
# is a pass: the template behind it clearly existed. See tt_mail_find in
# lib/_login.sh for why reading page one of that grid could never answer this -
# the short version is that it sorts on SentDate, which is empty until a message
# has actually been sent, and is empty forever for one that fails.
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
# WHAT WAS WRONG ON 2026-08-28, AND HOW THE SEND IS JUDGED NOW
#
# The version before this one treated "the popup closed itself" as the signal
# that a send had gone through, and waited twelve seconds for it. That premise is
# false, and it failed all nine sendable types in a single run.
#
# Read from the live model on 2026-08-28: the Send button on every tester popup
# (Main.Remind_Consultant_Tester.actionButton1 and its eight siblings) is a
# MICROFLOW action calling Main.SUB_SendEmail_Template - synchronous, no progress
# bar, and NO close-page. Main.SUB_SendEmail_Template contains no close-page
# activity anywhere either, inside its send loop or outside it. The only widget on
# those popups that closes anything is Cancel. So a popup still standing after
# Send is the DESIGNED behaviour, not a microflow that never returned.
#
# The run said as much itself and nobody read it: it reported "the send could not
# be completed" for all nine types and, three lines earlier, "4 new rows visible
# on the Emails Sent page". Those rows are diffed against the baseline THIS test
# takes at its top, so four of the sends it had just called failures had in fact
# raised mail. The other five had not been through the two-minute queue yet.
#
# The reason text made it worse. With the popup still up, tt_clear_dialogs picked
# the last visible .modal-content - the tester popup itself - found no
# yes/ok/confirm button among its Send and Cancel, and reported it as a blocking
# dialog. Every "dialog:x Remind Consultant Email ..." in that output was the
# popup's own title being read back as if the app had complained.
#
# So the send is now judged on what the app actually offers:
#
#   * the Send button carries disabledDuringExecution, so it is DISABLED while the
#     microflow runs and enabled again when it returns. That, not the popup
#     closing, is the "it finished" signal - and waiting for it is also what stops
#     Cancel racing a send that is still in flight;
#   * a modal appearing ON TOP of the popup is the only UI evidence of a send that
#     actually failed, so the poll counts visible modals against the count taken
#     before the click and reports the extra one's text;
#   * the popup is then closed with Cancel, deliberately. Cancel rolls back the
#     client-side EmailHelper only; by the time it returns, SUB_SendEmail_Template
#     has already committed the template and queued the message server-side.
#
# Whether a template row exists is left where it always belonged: the Emails Sent
# readback in section 3.
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

# TT_RUN_ID - what makes this run's mail distinguishable from the last one's.
#
# The address used to be tmpl-<type>@e2e.local, IDENTICAL on every run, and the
# only thing separating this run's rows from older ones was the page-one baseline
# in tt_mail_prepare. That baseline can only exclude rows that were VISIBLE when
# it was taken, so an old row drifting onto page one later was counted as this
# run's - which is the most likely reason the accounted-for count wandered (4,
# then 5, then 1) across three runs instead of holding steady. With a per-run
# token in the address, a match can only be this run's, and the baseline stops
# mattering for this step.
# %Y%m%d as well as the time: nothing ever deletes tmpl-*@e2e.local rows, so a
# time-only token collides with any earlier day's run that happened to start at
# the same second, and that stale row would be reported as this run's message.
TT_RUN_ID="$(date -u +%Y%m%d%H%M%S)"

et_addr() {  # a recipient unique to one email type AND to this run
  printf 'tmpl-%s-%s@%s' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" "$TT_RUN_ID" "${TT_MAIL_DOMAIN:-e2e.local}"
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
# Each blank field is reported as  <widget name>:<occurrence>, e.g. textBox1:2.
#
# The name comes from walking up to eight parents for an mx-name-* class, so two
# inputs under ONE named container resolve to the same name - and a selector
# matching two inputs is refused by Playwright in strict mode, which
# tt_fill_commit swallows, leaving both fields blank with nothing said about it.
# De-duplicating the names (the previous attempt) does not help: it makes the LIST
# shorter but leaves the selector just as ambiguous. The occurrence index is what
# actually resolves it, via :nth-match - which is what tt_fill's own docstring
# recommends for exactly this. It is counted over every input under that name, not
# just the blank ones, because that is the set :nth-match will be matching against.
#
# Prints  none
#     or  popup|<title>|<blank field widget names, comma separated>|<send button widget name>
et_mark_popup() {
  playwright-cli eval "() => { const vis=[...document.querySelectorAll('.modal-content')].filter(d=>d.offsetParent!==null); document.querySelectorAll('.tt-live-popup').forEach(e=>e.classList.remove('tt-live-popup')); const d=vis[vis.length-1]; if(!d) return 'none'; d.classList.add('tt-live-popup'); const wname=el=>{ let p=el; for(let k=0;k<8&&p;k++){ const m=((p.className||'')+'').match(/mx-name-[A-Za-z0-9_]+/); if(m) return m[0]; p=p.parentElement; } return ''; }; const blanks=[...d.querySelectorAll('input')].filter(i=>i.offsetParent!==null && !i.disabled && !i.readOnly && !((i.value||'').trim())).map(i=>{ const n=wname(i); if(!n) return ''; const all=[...d.querySelectorAll('.'+n+' input')]; const k=all.indexOf(i); return k<0 ? '' : (n+':'+(k+1)); }).filter(Boolean); const btns=[...d.querySelectorAll('button')].filter(b=>b.offsetParent!==null); const send=btns.find(b=>/^send\$/i.test((b.innerText||'').trim())) || btns.find(b=>/btn-success/.test((b.className||'')+'')); const title=(((d.querySelector('.modal-header')||{}).innerText)||'').replace(/\s+/g,' ').trim(); return 'popup|'+title+'|'+blanks.join(',')+'|'+(send?wname(send):''); }" 2>/dev/null | _tt_eval_str
}

et_popup_open() {  # 'open' while a popup is on screen, 'gone' once it is not
  playwright-cli eval "() => { const vis=[...document.querySelectorAll('.modal-content')].filter(d=>d.offsetParent!==null); return vis.length ? 'open' : 'gone'; }" 2>/dev/null | _tt_eval_str
}

et_modal_count() {  # how many popups/dialogs are stacked on screen right now
  playwright-cli eval "() => String([...document.querySelectorAll('.modal-content')].filter(d=>d.offsetParent!==null).length)" 2>/dev/null | _tt_eval_str
}

# et_send_state <baseline-modal-count> — what the popup is doing after Send.
#
# This is the replacement for waiting on the popup to close, which it never does
# (see the 2026-08-28 note in the header). Prints:
#
#   busy           the Send button is disabled — the microflow is still running
#   idle           it is enabled again — the microflow returned
#   closed         no modal left at all; a future close-page would land here
#   nosend         no Send button visible this instant, e.g. mid re-render
#   dialog:<text>  a modal appeared ON TOP of the popup — the send complained
et_send_state() {
  playwright-cli eval "() => { const v=[...document.querySelectorAll('.modal-content')].filter(d=>d.offsetParent!==null); if(!v.length) return 'closed'; if(v.length > $1) return 'dialog:'+(((v[v.length-1].innerText)||'').replace(/\s+/g,' ').trim().slice(0,140)); const d=v[v.length-1]; const b=[...d.querySelectorAll('button')].filter(x=>x.offsetParent!==null).find(x=>/^send\$/i.test((x.innerText||'').trim())); if(!b) return 'nosend'; return b.disabled ? 'busy' : 'idle'; }" 2>/dev/null | _tt_eval_str
}

# et_close_popup — Cancel out of the tester popup and land back on the tester.
#
# Cancel is the ONLY way these popups close, so this is the normal path out of a
# type, not a recovery. It waits for the popup to actually go before re-opening
# the tester: re-reading the tester's own fields through a popup that is still up
# is how one odd type used to cascade into the next.
et_close_popup() {
  local _
  if [ "$(et_popup_open)" = "open" ]; then
    et_force_close >/dev/null 2>&1 || true
    for _ in $(seq 1 6); do
      sleep 1
      [ "$(et_popup_open)" = "gone" ] && break
    done
  fi
  et_open_tester >/dev/null 2>&1 || true
}

et_force_close() {  # last resort: Cancel out of whatever popup is still standing
  playwright-cli eval "() => { const m=[...document.querySelectorAll('.modal-content')].filter(d=>d.offsetParent!==null); const d=m[m.length-1]; if(!d) return 'none'; const b=[...d.querySelectorAll('button')].filter(x=>x.offsetParent!==null).find(x=>/^cancel\$/i.test((x.innerText||'').trim())) || [...d.querySelectorAll('.modal-header button, button.close')].filter(x=>x.offsetParent!==null)[0]; if(b){ b.click(); return 'closed'; } return 'nobutton'; }" 2>/dev/null | _tt_eval_str
}

# ------------------------------------------------------- 1. prove mail is readable
# Kept for the check it performs, not for the baseline it takes. tt_mail_prepare
# fails loudly here if the admin account cannot open the Emails Sent page at all,
# which is worth finding out BEFORE sending twelve emails at a page that cannot be
# read. Its page-one baseline is no longer what this step reads: every address now
# carries TT_RUN_ID, so a match can only be this run's, and section 3 asks the
# recipient filter directly instead of diffing a snapshot.
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
      # An empty or unrecognised result means the EVAL failed - a browser hiccup, a
      # dropdown not yet rendered - not that the dropdown lacks the value. Filing it
      # under $notoffered would claim "Main.ENUM_EmailType and the tester's dropdown
      # have diverged", which is an assertion about the MODEL, and would exit before
      # section 3 and discard every send this run has already made and queued.
      sendfail="$sendfail $t(type-pick:${r:-no-reply})"
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
  #
  # Re-mark before EACH fill, not once at the end. A committed field makes Mendix
  # re-render, a re-render can drop a class this test added, and tt_fill_commit
  # swallows its own errors by design - so a lost class turns every fill after the
  # first into a silent no-op that nothing reports.
  # et_mark_popup strips the class from everything BEFORE it looks for a popup to
  # re-tag, so if a re-render leaves the modal momentarily invisible it returns
  # 'none' and nothing carries the class. tt_fill_commit swallows its own errors by
  # design, so the fill would then match nothing and say nothing - and the type
  # would go on to be counted as sent and reported as a missing template row. Give
  # it a few tries, and if the popup still cannot be found, SAY so.
  unfilled=""
  for w in $blanks; do
    marked=""
    for _ in 1 2 3; do
      case "$(et_mark_popup)" in popup*) marked="yes"; break ;; esac
      sleep 1
    done
    if [ -z "$marked" ]; then
      unfilled="$unfilled $w"
      continue
    fi
    tt_fill_commit ":nth-match(.tt-live-popup .${w%%:*} input, ${w##*:})" "3"
  done
  [ -z "$unfilled" ] || echo "    (could not re-find the live popup, so these stayed blank:$unfilled)"

  if [ -z "$sendbtn" ]; then
    sendfail="$sendfail $t(no-send-button)"
    et_close_popup
    continue
  fi

  # Re-mark before the click: a fill commits, Mendix re-renders the popup, and a
  # re-render can drop a class this test added to it.
  et_mark_popup >/dev/null 2>&1 || true
  # How many modals are up BEFORE the click, so a dialog raised by the send is
  # recognised as an EXTRA one rather than mistaken for the popup itself. That
  # mistake is what produced the "dialog:x Remind Consultant Email ..." reasons.
  base="$(et_modal_count)"
  case "$base" in ''|*[!0-9]*) base=1 ;; esac
  clickout="$(playwright-cli click ".tt-live-popup .$sendbtn" 2>&1)"
  case "$clickout" in
    *"strict mode violation"*|*"### Error"*|*"Timeout"*)
      sendfail="$sendfail $t(send-click:$(printf '%s' "$clickout" | tr '\n' ' ' | cut -c1-80))"
      et_close_popup
      continue ;;
  esac

  # Wait for the MICROFLOW TO RETURN, not for the popup to close - it never does.
  # The Send button is disabledDuringExecution, so busy -> idle is the completion
  # signal, and waiting for it is also what stops the Cancel below racing a send
  # that is still in flight. 'closed' is accepted too, so that a close-page added
  # to SUB_SendEmail_Template later reads as success rather than as a new failure.
  state=""
  for _ in $(seq 1 15); do
    sleep 1
    state="$(et_send_state "$base")"
    case "$state" in idle|closed|dialog:*) break ;; esac
  done

  case "$state" in
    dialog:*)
      sendfail="$sendfail $t(dialog:$(printf '%s' "${state#dialog:}" | cut -c1-60))"
      tt_clear_dialogs 4 >/dev/null 2>&1 || true ;;
    idle|closed)
      sent="$sent $t" ;;
    *)
      # Fifteen seconds of 'busy', or a Send button that went missing and stayed
      # missing. This is the case the old popup-stayed-open reason was reaching
      # for, and now it only fires when that is what actually happened.
      sendfail="$sendfail $t(send-did-not-return:${state:-no-reply})" ;;
  esac

  et_close_popup
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

# ----------------------------------------------- 3. ask the grid, per recipient
# WHY THIS IS A LOOKUP AND NOT A SCAN ANY MORE.
#
# Every previous version read page one of the Emails Sent grid and diffed it
# against a baseline. That could never work, and three runs failed three
# different ways before the reason turned up in the model:
#
#   * the grid pages at 20, sorted by SentDate DESCENDING;
#   * SentDate is stamped ONLY on successful delivery. Main.SUB_SendEmail_Template
#     commits each new message with QueuedForSending=true and Status=QUEUED and
#     nothing else; Email_Connector.SUB_SendQueuedEmail sets SentDate on its
#     success branch only, and the error and max-attempts branches never do.
#
# So a message that has been created but not yet delivered - which is every
# message the instant this step causes it, and permanently for any that fails to
# send - has an empty SentDate and sorts to the far end of the list. It never
# reaches page one. The step was measuring DELIVERY to tmpl-*@e2e.local and
# reporting the result as "no template row".
#
# Core.EmailsSent_Overview gained a recipient filter for this on 2026-08-28, so
# the question can now be asked directly, per address, via tt_mail_find. Sort
# order and page size stop mattering entirely.
#
# THE ROW EXISTS IMMEDIATELY. SUB_SendEmail_Template commits the message before
# it returns, so there is nothing to wait for the queue to do - which is why this
# is three quick rounds rather than the old eight-times-twenty-seconds. The retry
# is only there for a slow commit or a slow grid, not for delivery.
accounted=""     # types whose message was found, in any round
statuses=""      # "<type>=<status>" for each, so the report can say what it saw
unreadable=""    # types the grid could not be READ for - never a template verdict
pending="$sent"
nofilter=""
for round in 1 2 3; do
  [ -n "$pending" ] || break
  still=""
  for t in $pending; do
    r="$(tt_mail_find "$(et_addr "$t")")"
    case "$r" in
      FOUND*)
        accounted="$accounted $t"
        st="$(printf '%s' "$r" | cut -d'|' -f2)"
        er="$(printf '%s' "$r" | cut -d'|' -f3-)"
        statuses="$statuses $t=${st:-?}"
        [ -z "$er" ] || echo "  $t: $st - $er"
        ;;
      NOFILTER)
        nofilter="yes"
        still="$still $t"
        ;;
      NONE)
        still="$still $t"
        ;;
      *)
        # NOGRID, or nothing at all because tt_fail killed the $( ) subshell. The
        # page could not be read, so this says NOTHING about whether a message
        # exists - and it must not fall through to "no template row", which is the
        # one accusation this file exists to avoid making wrongly.
        case " $unreadable " in *" $t "*) ;; *) unreadable="$unreadable $t" ;; esac
        still="$still $t"
        ;;
    esac
  done
  pending="$still"
  [ -n "$nofilter" ] && break
  [ -n "$pending" ] || break
  [ "$round" -lt 3 ] && sleep 15
done

found=0
for t in $accounted; do found=$((found+1)); done

# A type that was never found splits two ways, and the difference matters more
# than anything else this step reports: $norow means the grid was READ and had no
# message, which is a real finding; $unreadable means the grid could not be read
# at all, which is a finding about the browser session and nothing else.
norow=""
for t in $sent; do
  case " $accounted " in *" $t "*) continue ;; esac
  case " $unreadable " in *" $t "*) continue ;; esac
  norow="$norow $t"
done

echo "  raised $found of $sent_count sent types${statuses:+ ($statuses )}"

fail=0

if [ -n "$nobranch" ]; then
  # REPORTED EVERY RUN, BUT NOT FATAL, and the choice is deliberate.
  #
  # This is a gap in the APP, not a defect in the step: those types have no branch
  # to send through, so this test can say nothing about them either way. Making it
  # exit 1 leaves a step that is red until somebody edits the model - and
  # run-tests.sh is fail-fast by default, so it would also take 70-tickets,
  # 75-export, 76-bulk and 80-platform down with it on every single run. A finding
  # that blocks four suites indefinitely stops being read. It belongs in a ticket.
  #
  # The step still fails for the things it CAN prove: a send that did not go
  # through, a sent type with no message behind it, and the case where nothing at
  # all could be sent.
  echo "GAP: verify-email-templates-present - the Email Tester cannot send:$nobranch"
  echo "      Picking the type and pressing Send Template opened no detail popup, which is"
  echo "      what Main.ACT_SendTemplate1 does when its split has no branch for the value:"
  echo "      the flow runs into the merge and ends without sending anything. Confirmed"
  echo "      against the live model on 2026-08-28 - the Which Type? split has nine"
  echo "      show-page branches and four case flows straight to the merge: (empty), plus"
  echo "      exactly these three."
  echo "      THIS IS NOT A MISSING TEMPLATE ROW, and it is not a defect in this step."
  echo "      Nothing was sent, so nothing can be concluded about whether the rows exist -"
  echo "      including ForgotPassword, whose absence would lock a user out after"
  echo "      Core.ACT_Password_Forgot has already replaced their password. Fix by adding a"
  echo "      branch and a tester popup per type in Main.ACT_SendTemplate1; until then"
  echo "      these types are untested here."
  # Compared as a sorted set: the accumulated list is in TYPES order, which only
  # happens to match KNOWN_NO_BRANCH today. Comparing the raw strings would report
  # "the split has changed" after a harmless reorder of TYPES.
  if [ "$(printf '%s\n' $nobranch | sort | tr '\n' ' ')" = "$(printf '%s\n' $KNOWN_NO_BRANCH | sort | tr '\n' ' ')" ]; then
    echo "      That is exactly the list this test was written against, so nothing has moved."
  else
    echo "      That DIFFERS from the list this test was written against, so the split has"
    echo "      changed since:$KNOWN_NO_BRANCH"
  fi
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

# Suppressed when the filter is missing: without it nothing could be looked up, so
# every type would land in $norow and be reported as a missing template row - the
# exact false accusation this file exists to avoid. The NOFILTER failure below
# says what actually happened.
if [ -n "$norow" ] && [ -z "$nofilter" ]; then
  fail=1
  echo "FAIL: verify-email-templates-present - sent, but no message exists for:$norow"
  echo "      The recipient filter on the Emails Sent page matched NOTHING for those"
  echo "      addresses, and the address carries this run's own token, so no older row"
  echo "      could have masked the answer either way. The message was never created."
  echo "      The most likely cause is that Email_Connector.EmailTemplate has no row for"
  echo "      that type, so Main.SUB_SendEmail_Template breaks out of its loop silently -"
  echo "      no error, no log line, no queued message. The wording lives in the database,"
  echo "      not the model, so it is fixed on the environment."
  echo "      BEFORE ADDING A ROW, CHECK THE ONE THAT MAY ALREADY BE THERE. The retrieve is"
  echo "      [TemplateName = \$TemplateName], where TemplateName is toString() of the enum"
  echo "      - the value's NAME, 'ToConsultant_SubmissionReminder', not its caption and not"
  echo "      a friendly title. A row that exists under any other spelling, or with stray"
  echo "      whitespace, is invisible to that retrieve and looks exactly like this."
  echo "      This no longer depends on the message having been DELIVERED. A message that"
  echo "      exists but has not left the queue shows up as QUEUED, and counts as a pass"
  echo "      for this step - the template behind it clearly existed."
  if [ "$found" -eq 0 ] && [ "$sent_count" -gt 0 ]; then
    echo "      NOTHING was found for any type that was sent. Before hunting missing"
    echo "      templates, check the assumption in this file's header: that the tester sends"
    echo "      to the address in its own email field. If it sends somewhere else, every"
    echo "      type looks missing even when all the templates are fine - and every address"
    echo "      this run searched for carried the token $TT_RUN_ID, so a tester that ignores"
    echo "      its email field would produce exactly this, nine times over."
  fi
fi

if [ -n "$unreadable" ]; then
  fail=1
  echo "FAIL: verify-email-templates-present - the Emails Sent page could not be read for:$unreadable"
  echo "      tt_mail_find could not get the grid on screen - the admin session dropped, the"
  echo "      re-login did not take, or the page never rendered. THIS IS NOT A TEMPLATE"
  echo "      RESULT. Those types are excluded from the missing-message list above rather"
  echo "      than counted as missing, because nothing was ever looked at for them."
fi

if [ -n "$nofilter" ]; then
  fail=1
  echo "FAIL: verify-email-templates-present - the Emails Sent page has no recipient filter"
  echo "      (.mx-name-filterEmailsSentTo). This step needs it to ask whether a message"
  echo "      exists for a given address; without it the only alternative is reading page"
  echo "      one of a grid sorted by SentDate, which is empty for every message that has"
  echo "      not been DELIVERED - i.e. for exactly the ones this step creates."
  echo "      The filter was added to Core.EmailsSent_Overview on 2026-08-28, so this"
  echo "      environment is running a build from before that. Redeploy it and run again."
  echo "      NOTHING is being claimed about the template rows either way - the per-type"
  echo "      result is suppressed above precisely so this cannot be misread as twelve"
  echo "      missing templates."
fi

if [ "$sent_count" -eq 0 ]; then
  # Without this the step would report PASS having proven nothing at all, which is
  # the failure mode the whole file exists to avoid.
  fail=1
  echo "FAIL: verify-email-templates-present - not one type could be sent, so no template"
  echo "      row was proven to exist. Every type either has no branch in"
  echo "      Main.ACT_SendTemplate1 or failed to send; the lines above say which."
fi

[ "$fail" -eq 0 ] || exit 1

echo "PASS: verify-email-templates-present - all $sent_count types the Email Tester can send raised a message, so each has a template row"
[ -z "$nobranch" ] || echo "      Still unproven, for want of a branch in Main.ACT_SendTemplate1:$nobranch"
