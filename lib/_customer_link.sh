#!/usr/bin/env bash
# _customer_link.sh — shared steps for the customer-link security specs.
#
# Source AFTER lib/_login.sh, lib/_authz.sh and lib/_changelog.sh:
#
#   source "$TT_ROOT/lib/_login.sh"
#   source "$TT_ROOT/lib/_authz.sh"
#   source "$TT_ROOT/lib/_changelog.sh"
#   source "$TT_ROOT/lib/_customer_link.sh"
#
# WHAT CHANGED IN THE APP (the "customer-link security" model change, 2026-09-29).
# A customer approves from an emailed link without signing in. Opening the link now
# RECORDS A VISIT (Main.ApprovalVisit): the anonymous session's own user, the token,
# the approver's email and the projects the link covers. Every anonymous access rule
# on the business entities (AssignmentEntry, Timesheet, Assignment, Project, Customer,
# LineItem, AssignmentAttachment, AttachmentDocument, ExpenseReport,
# ExpenseReportDocuments) now admits only rows on a project covered by a live visit OF
# THE CURRENT SESSION, whose token is still Active and unexpired - and, for entries,
# only AwaitingCustomerApproval. Approve, Reject, View and the per-row Approve
# re-check that the link covers the entry (SUB_CustomerToken_CoversEntry).
#
# WHAT A REFUSAL LOOKS LIKE SINCE TT-778 (model 73b0683b, deployed 2026-10-05). On the
# "Link covers entry?" = false branch the action no longer shows the in-place
# message "This approval link is no longer valid. Please open the most recent
# approval email ..." (RETIRED). Instead Approve and Reject close the review popup,
# and all four then OPEN THE PAGE Main.Customer_LinkInvalid, whose heading is
# .mx-name-textLinkInvalidHeading = "This approval link is no longer valid" (read
# from the generated ACT_Customer_{ApprovePage,RejectPage,ShowPage,ApproveHelper} of
# the 10-05 build, and the page from disk). The retired dialog showing up instead is
# a TT-778 regression, and cl_await_refusal says so rather than accepting it.
#
# Either way the action ENDS NORMALLY. That matters to every spec below: a refusal
# is not an ERR on the wire, so it can only be proved by reading the entry back and
# finding it unmoved - never by the shape of the call's answer.
#
# Provides:
#   cl_remind_link <consultant> <project> <approver> [weekKey]
#                                                       a live approval link (from
#                                                       mail) listing that week. Sets
#                                                       CL_WEEK (a week key), CL_LINK,
#                                                       CL_WEEKFRAG.
#   cl_fresh_link  <consultant> <project> <approver>   the same for any pending week,
#                                                       creating one when there is none
#   cl_open_link_cold <link>                            new anonymous session, open it
#   cl_entry_guid <consultant> <project> <week-key>     HR: the pending entry's guid
#   cl_entry_status <guid> / cl_log_count <guid>        HR: readbacks for one entry
#   cl_dialog_text                                      the topmost visible dialog
#   cl_await_refusal <tries> [confirm caption]          wait for the refusal: the
#                                                       Customer_LinkInvalid page
#   cl_link_invalid_shown                               'true' when that page is up
#   cl_click_tab <tab widget name>                      open a tab page by its name
#   cl_staff_open / cl_staff <cmd…> / cl_staff_close    a SECOND browser for staff
#
# Env: none of its own beyond CL_STAFF_SESSION (default tt-staff).
# ---------------------------------------------------------------------------

# The refusal every link-covered action shows since TT-778: the Customer_LinkInvalid
# page, found by its heading's NAME (a contract) and checked against a fragment of
# its copy (so a reworded heading that still says the link is dead does not fail a
# spec, and a different page carrying the same widget name does).
CL_LINK_INVALID_SEL='.mx-name-textLinkInvalidHeading'
CL_REFUSAL_RE='no longer valid'
# The RETIRED in-place message's second sentence. Seeing it means TT-778 regressed.
CL_OLD_REFUSAL_RE='most recent approval email'

# The named playwright-cli session the staff half of a two-session spec runs in.
CL_STAFF_SESSION="${CL_STAFF_SESSION:-tt-staff}"

CL_WEEK=""
CL_LINK=""
CL_WEEKFRAG=""

# _cl_weekfrag <week label> — the leading "Mon D(D)" of a week label, which every
# rendering of that week contains (the HR tab and the token page word it differently;
# see verify-customer-token-approve). Falls back to the whole label.
_cl_weekfrag() {
  local re='^([A-Za-z]{3} [0-9]{1,2})'
  if [[ $1 =~ $re ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$1"
  fi
}

# cl_remind_link <consultant> <project> <approver> [weekKey]
# cl_fresh_link  <consultant> <project> <approver>
#
# Both are thin wrappers around tt_customer_link (lib/_login_tokens.sh, #146), which
# reuses a live approval link already in Emails Sent when its page lists our row,
# submits a week as the consultant when nothing is pending, and presses HR's Remind
# only when no email in the mailbox can serve. They used to press Remind every time;
# Remind is allowed once per entry per day, so from the day's second spec onward the
# button was gone and each spec fell back to a fresh submit plus a wait on the mail
# queue - 300-450 s, and the specs timed out.
#
# They map TT_CL_LINK / TT_CL_WEEK / TT_CL_WEEKFRAG onto CL_LINK / CL_WEEK /
# CL_WEEKFRAG. CL_WEEK is now a tt_week_key ("Sep 27 - Oct 03"), not HR's label;
# tt_week_key of a key is the key, so callers that normalise it still work.
#
# cl_remind_link takes the week the caller already created and accepts only a link
# whose page lists THAT week; nothing is submitted for it. tt_customer_link tt_fail's
# when no path yields a link, so a return here is always 0.
_cl_from_tt() {
  CL_LINK="$TT_CL_LINK"
  CL_WEEK="$TT_CL_WEEK"
  CL_WEEKFRAG="$TT_CL_WEEKFRAG"
  [ -n "$CL_WEEKFRAG" ] || CL_WEEKFRAG="$(_cl_weekfrag "$CL_WEEK")"
  echo "  link for '$1' / '$2' week '$CL_WEEK' ($TT_CL_HOW); read from mail to $3"
}

cl_remind_link() {
  local who="$1" proj="$2" approver="$3" wk="${4:-}"
  tt_customer_link "$who" "$proj" "$approver" "$wk" || return 1
  _cl_from_tt "$who" "$proj" "$approver"
}

cl_fresh_link() {
  local who="$1" proj="$2" approver="$3"
  tt_customer_link "$who" "$proj" "$approver"     || tt_fail "no pending '$who' entry on '$proj' with a live approval link, even after submitting one"
  _cl_from_tt "$who" "$proj" "$approver"
}

# cl_open_link_cold <link> — throw the session away and open <link> as a first-time
# visitor. Opening it is what RECORDS THE VISIT, so everything a spec then asks in the
# same browser session is asked by a session that has one. 0 when the approval page
# (list or empty state) painted, 1 otherwise.
cl_open_link_cold() {
  local i
  playwright-cli cookie-clear >/dev/null 2>&1
  playwright-cli goto "$1" >/dev/null 2>&1
  for i in $(seq 1 25); do
    [ "$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-galPendingEntries') || !!document.querySelector('.mx-name-containerNoPendingApprovals'))" 2>/dev/null | _tt_eval_str)" = "true" ] && { sleep 1; return 0; }
    sleep 1
  done
  return 1
}

# cl_entry_guid <consultant> <project> <week-key>
#
# As the CURRENT session (sign in as e2e_hr first - tt_cl_entries needs HR's read on
# the change log): the guid of the AwaitingCustomerApproval entry for that consultant,
# project and week. <week-key> is a tt_week_key ("Sep 27 - Oct 03"), which is exactly
# the form tt_cl_entries prints. Echoes '' when there is none, ERR:<why> on a failed
# read.
cl_entry_guid() {
  local who="$1" proj="$2" wk="$3" c out line
  c="[Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName = '$who'][Main.AssignmentEntry_Assignment/Main.Assignment/Main.Assignment_Project/Main.Project/Name = '$proj'][Status = 'AwaitingCustomerApproval']"
  out="$(tt_cl_entries "$c")"
  case "$out" in ERR:*) printf '%s' "$out"; return 0 ;; esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$(tt_cl_field "$line" 4)" = "$wk" ]; then
      tt_cl_field "$line" 1
      return 0
    fi
  done <<< "$out"
  printf ''
}

# cl_entry_status <guid> — the entry's Status as the current session reads it.
cl_entry_status() {
  tt_authz_readback "//Main.AssignmentEntry[id = '$1']" 'Status'
}

# cl_log_count <guid> — how many Main.ChangeLog rows the entry has. HR / TM only.
cl_log_count() {
  tt_authz_count "//Main.ChangeLog[Main.ChangeLog_AssignmentEntry = '$1']"
}

# cl_dialog_text — the topmost visible dialog's text on one line, or ''.
cl_dialog_text() {
  playwright-cli eval "() => { const d=$(_tt_dialog_js); return d ? (d.innerText||'').replace(/\\s+/g,' ').trim().slice(0,300) : ''; }" 2>/dev/null | _tt_eval_str
}

# cl_link_invalid_text — the Customer_LinkInvalid heading's text when that page is
# on screen (heading visible), else ''.
cl_link_invalid_text() {
  playwright-cli eval "() => { const h=[...document.querySelectorAll('$CL_LINK_INVALID_SEL')].find(e=>e.offsetParent!==null); return h ? (h.innerText||'').replace(/\\s+/g,' ').trim() : ''; }" 2>/dev/null | _tt_eval_str
}

# cl_link_invalid_shown — 'true' when Main.Customer_LinkInvalid is on screen: its
# heading is visible AND reads "no longer valid".
cl_link_invalid_shown() {
  if printf '%s' "$(cl_link_invalid_text)" | grep -qi "$CL_REFUSAL_RE"; then echo true; else echo false; fi
}

# cl_await_refusal <tries> [confirm caption]
#
# Poll up to <tries> seconds for the TT-778 refusal: the Customer_LinkInvalid page
# (cl_link_invalid_shown). When a dialog is up that is NOT the refusal and offers a
# button captioned exactly [confirm caption] (the action's own confirmation), press
# it once and keep waiting. The review popup itself is never treated as that
# confirmation - its own Approve button carries the same caption, and pressing it
# again would be a second approval attempt.
#
# Echoes "Customer_LinkInvalid: <heading>" and returns 0. Returns 1, echoing why,
# when the RETIRED in-place message appears instead (a TT-778 regression - not a
# pass, even though it is also a refusal) or nothing came within <tries> seconds.
cl_await_refusal() {
  local tries="$1" confirm="${2:-}" i t="" h pressed=""
  for i in $(seq 1 "$tries"); do
    h="$(cl_link_invalid_text)"
    if printf '%s' "$h" | grep -qi "$CL_REFUSAL_RE"; then
      printf 'Customer_LinkInvalid: %s' "$h"
      return 0
    fi
    t="$(cl_dialog_text)"
    if printf '%s' "$t" | grep -qi "$CL_OLD_REFUSAL_RE"; then
      printf 'the RETIRED in-place refusal (since TT-778 the action opens Customer_LinkInvalid instead): %s' "$t"
      return 1
    fi
    if [ -n "$t" ] && [ -n "$confirm" ] && [ -z "$pressed" ]; then
      if [ "$(playwright-cli eval "() => { const d=$(_tt_dialog_js); if(!d) return 'none'; if(d.querySelector('.mx-name-btnCustomerApprove,.mx-name-btnCustomerReject')) return 'none'; const b=[...d.querySelectorAll('button')].filter(x=>x.offsetParent!==null).find(x=>(x.innerText||'').trim().toLowerCase()==='$(printf '%s' "$confirm" | tr '[:upper:]' '[:lower:]')'); if(!b) return 'none'; b.click(); return 'pressed'; }" 2>/dev/null | _tt_eval_str)" = "pressed" ]; then
        pressed=1
      fi
    fi
    sleep 1
  done
  printf 'no Customer_LinkInvalid page within %ss; last dialog: %s' "$tries" "${t:-(none)}"
  return 1
}

# cl_dismiss_refusal — press OK on the RETIRED refusal message, if it is up, so a
# spec that has already failed on it can still go on to read the entry back. The
# TT-778 refusal is a page, not a dialog, and has nothing to dismiss.
cl_dismiss_refusal() {
  playwright-cli eval "() => { const d=$(_tt_dialog_js); if(!d) return 'none'; if(!/$CL_OLD_REFUSAL_RE/i.test(d.innerText||'')) return 'other'; const b=[...d.querySelectorAll('button')].filter(x=>x.offsetParent!==null).find(x=>/^ok\$/i.test((x.innerText||'').trim())); if(!b) return 'nobutton'; b.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str
}

# cl_click_tab <tab page widget name> — select a tab page by its Name.
#
# Mendix puts the tab page's mx-name class on its header item; the clickable part is
# the anchor inside it when there is one. Echoes ok | missing. The CALLER proves the
# tab really opened by waiting for a widget that lives on it - a click that landed on
# the wrong element would otherwise read as an empty tab.
cl_click_tab() {
  playwright-cli eval "() => { const t=[...document.querySelectorAll('.mx-name-$1')].find(e=>e.offsetParent!==null) || document.querySelector('.mx-name-$1'); if(!t) return 'missing'; const a=t.matches('a,[role=tab]') ? t : (t.querySelector('a,[role=tab]') || t); a.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str
}

# cl_visible <selector> — 'true' when an element matching <selector> is on screen.
cl_visible() {
  playwright-cli eval "() => String([...document.querySelectorAll('$1')].some(e=>e.offsetParent!==null))" 2>/dev/null | _tt_eval_str
}

# ---------------------------------------------------------------------------
# A SECOND BROWSER, for the specs that need a staff user to act while an anonymous
# visitor's page stays open. The suite otherwise runs in ONE shared playwright-cli
# session (run-tests.sh), and signing in there would replace the visitor's cookies -
# the very session whose visit is under test. A named session is a separate browser
# context with its own cookies, so both can be live at once.
#
#   cl_staff_open                       launch it (once)
#   cl_staff tt_login e2e_hr "$TT_HR_READY"
#   cl_staff tt_authz_write …           any helper, run against the staff browser
#   cl_staff_close                      always, from an EXIT trap
#
# cl_staff works by exporting PLAYWRIGHT_CLI_SESSION for the duration of one command,
# which every bare `playwright-cli` call inside it inherits.
# ---------------------------------------------------------------------------
cl_staff_open() {
  playwright-cli -s="$CL_STAFF_SESSION" open "$TT_BASE/" >/dev/null 2>&1 \
    || tt_fail "could not open a second browser session ($CL_STAFF_SESSION) for the staff half of this step"
}

cl_staff() {
  PLAYWRIGHT_CLI_SESSION="$CL_STAFF_SESSION" "$@"
}

cl_staff_close() {
  playwright-cli -s="$CL_STAFF_SESSION" close >/dev/null 2>&1
  return 0
}
