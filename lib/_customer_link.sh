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
# only AwaitingCustomerApproval. Approve, Reject, View, the per-row Approve and the
# three downloads re-check that the link covers the entry and, when it does not, show
#
#   "This approval link is no longer valid. Please open the most recent approval
#    email from Titan Consulting and use the link in that message."
#
# and END NORMALLY. That last part matters to every spec below: a refusal is not an
# ERR on the wire, so it can only be proved by reading the entry back and finding it
# unmoved - never by the shape of the call's answer.
#
# Provides:
#   cl_remind_link <consultant> <project> <approver>   HR reminds a pending entry and
#                                                       the approval link is read from
#                                                       mail. Sets CL_WEEK, CL_LINK,
#                                                       CL_WEEKFRAG. 1 = nothing pending.
#   cl_fresh_link  <consultant> <project> <approver>   the same, creating the pending
#                                                       entry first when there is none
#   cl_open_link_cold <link>                            new anonymous session, open it
#   cl_entry_guid <consultant> <project> <week-key>     HR: the pending entry's guid
#   cl_entry_status <guid> / cl_log_count <guid>        HR: readbacks for one entry
#   cl_dialog_text                                      the topmost visible dialog
#   cl_await_refusal <tries> [confirm caption]          wait for the refusal message
#   cl_click_tab <tab widget name>                      open a tab page by its name
#   cl_staff_open / cl_staff <cmd…> / cl_staff_close    a SECOND browser for staff
#
# Env: none of its own beyond CL_STAFF_SESSION (default tt-staff).
# ---------------------------------------------------------------------------

# The refusal every link-covered action shows. A fragment, so rewording the second
# sentence does not fail a spec, and removing the refusal does.
CL_REFUSAL_RE='no longer valid'

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

# cl_remind_link <consultant> <project> <approver>
#
# Reset the mail high-water mark, press Remind on HR's Client approval tab for a
# pending <consultant> entry on <project>, and read the approval link addressed to
# <approver> out of the mail that produced. Returns 1 when HR has nothing pending for
# that pair (the caller decides whether to create one); tt_fail's on a mail failure.
#
# ORDER IS LOAD-BEARING: tt_mail_prepare signs in as the administrator, so it runs
# FIRST and the HR dashboard is opened LAST (verify-customer-token-approve has the
# long version of why).
cl_remind_link() {
  local who="$1" proj="$2" approver="$3" ts
  tt_mail_prepare
  ts=$(date +%s%3N)
  tt_login "e2e_hr" "$TT_HR_READY"
  tt_hr_click_tab "Client approval"
  sleep 2
  CL_WEEK="$(tt_hr_remind_e2e_entry "$who" "$proj")" || return 1
  [ -n "$CL_WEEK" ] || tt_fail "HR reminded an entry but the week under test could not be read"
  CL_LINK="$(tt_mail_token "$ts" customer-approval "$approver")" \
    || tt_fail "the approval email to '$approver' was not received within the timeout"
  case "$CL_LINK" in
    *"/p/customer-approval/"*) ;;
    *) tt_fail "the email link is not a customer-approval link: $CL_LINK" ;;
  esac
  CL_WEEKFRAG="$(_cl_weekfrag "$CL_WEEK")"
  echo "  reminded '$who' / '$proj' for week '$CL_WEEK'; link read from mail to $approver"
  return 0
}

# cl_fresh_link <consultant> <project> <approver> — cl_remind_link, creating the
# pending entry through the consultant first when HR has none to remind.
cl_fresh_link() {
  local who="$1" proj="$2" approver="$3"
  cl_remind_link "$who" "$proj" "$approver" && return 0
  echo "  no pending '$who' entry on '$proj' - creating one as the consultant"
  tt_login "e2e_consultant" "My Timesheets"
  tt_consultant_submit_project_row "$proj"
  cl_remind_link "$who" "$proj" "$approver" \
    || tt_fail "still no pending '$who' entry on '$proj' after submitting one"
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

# cl_await_refusal <tries> [confirm caption]
#
# Poll up to <tries> seconds for the "no longer valid" refusal. When a dialog is up
# that is NOT the refusal and offers a button captioned exactly [confirm caption]
# (the action's own confirmation), press it once and keep waiting. The review popup
# itself is never treated as that confirmation - its own Approve button carries the
# same caption, and pressing it again would be a second approval attempt. Echoes the
# refusal text and returns 0, or echoes the last dialog seen and returns 1.
#
# Deliberately does not use tt_clear_dialogs: that helper presses 'ok', and the
# refusal's only button IS ok - it would dismiss the evidence before it was read.
cl_await_refusal() {
  local tries="$1" confirm="${2:-}" i t="" pressed=""
  for i in $(seq 1 "$tries"); do
    t="$(cl_dialog_text)"
    if printf '%s' "$t" | grep -qi "$CL_REFUSAL_RE"; then
      printf '%s' "$t"
      return 0
    fi
    if [ -n "$t" ] && [ -n "$confirm" ] && [ -z "$pressed" ]; then
      if [ "$(playwright-cli eval "() => { const d=$(_tt_dialog_js); if(!d) return 'none'; if(d.querySelector('.mx-name-btnCustomerApprove,.mx-name-btnCustomerReject')) return 'none'; const b=[...d.querySelectorAll('button')].filter(x=>x.offsetParent!==null).find(x=>(x.innerText||'').trim().toLowerCase()==='$(printf '%s' "$confirm" | tr '[:upper:]' '[:lower:]')'); if(!b) return 'none'; b.click(); return 'pressed'; }" 2>/dev/null | _tt_eval_str)" = "pressed" ]; then
        pressed=1
      fi
    fi
    sleep 1
  done
  printf '%s' "${t:-(no dialog)}"
  return 1
}

# cl_dismiss_refusal — press OK on the refusal message, if it is up.
cl_dismiss_refusal() {
  playwright-cli eval "() => { const d=$(_tt_dialog_js); if(!d) return 'none'; if(!/$CL_REFUSAL_RE/i.test(d.innerText||'')) return 'other'; const b=[...d.querySelectorAll('button')].filter(x=>x.offsetParent!==null).find(x=>/^ok\$/i.test((x.innerText||'').trim())); if(!b) return 'nobutton'; b.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str
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
