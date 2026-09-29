#!/usr/bin/env bash
# tt-timeout: 12m
# verify-hr-invoice-reject.test.sh
#
# HR pulls a week back from MONTHLY TO BE INVOICED (state transition
# AwaitingExport -> Rejected) - the last hours-bearing state an entry can be
# rejected from before it is exported and, in practice, invoiced.
#
# WHY THIS EXISTS. This is the third of the three reject buttons TT-686 names -
# "Sent, weekly, and Monthly" - and the only one with no coverage:
#
#   Weekly  -> suites/40-hr/verify-hr-process-reject
#   Sent    -> suites/75-export/verify-hr-reject-after-export (Exported -> Rejected)
#   Monthly -> this step                                      (AwaitingExport -> Rejected)
#
# Monthly is the last exit before the money leaves. Once Main.ACT_ExportAll_HRDash
# has run, correcting the week means the after-export route and a re-issued
# invoice; while the entry is still merely AwaitingExport, rejecting it costs
# nothing but the consultant's time. If this button quietly stopped working,
# every correction would have to go the expensive way round and nothing would say
# why.
#
# WHY IT IS NOT A COPY OF THE WEEKLY ONE. The invoice tab is not one of the four
# HRDashboardTab tabs. It is page-level and its unit is a MONTH - since 2026-09-28 a
# list of month groups (lstInvoiceMonths), each expanded on its own, where it used to
# be a month picker (galAvailableMonths) - so the week helpers have nothing to walk
# here. The month walk below is that difference, and it is the whole reason this is
# a separate file rather than a fourth argument to the shared helper.
#
# WHAT IT ASSERTS
#   A. An AwaitingExport card for the e2e consultant is on the tab.
#   B. Pressing its Reject and confirming with a comment removes it from the tab.
#   C. The entry arrives back in the consultant's Rejected Entries.
#
# It does not assert the empty-comment guard, but that is now a division of
# labour rather than an absence. This paragraph used to read: the HR reject route
# runs Main.NACT_AssignmentEntry_PageReject -> Main.ACT_ApprovalHelper_Reject,
# which has no "Left Comments?" branch, while the PM and client routes do. The
# popup's Reject now calls Main.ACT_AssignmentEntry_PageReject, which refuses
# without a comment, and Main.ACT_ApprovalHelper_Reject carries the same guard
# server-side. The refusal is asserted once, on the Weekly tab, by
# verify-hr-process-reject-guard - the popup and the flow behind it are shared, so
# asserting it a third time here would only cost a fixture. What this step still
# owns is the Monthly tab reaching that popup at all, which is the hir_reject_one
# return code 2 below.
#
# WHY 75-export. It needs an entry in AwaitingExport, and the cheap supply of
# those is what suites/70-tickets/tt683/ has already processed by the time this
# folder runs. It takes ONE, leaving the rest for the export steps beside it. It
# can also drive the process chain itself when the tab is empty, and says loudly
# when it does.
#
# CONSUMES ONE AwaitingExport ENTRY.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_rejection.sh"
source "$TT_ROOT/lib/_tt683.sh"

TAB="Monthly to be invoiced"
CNAME="${TT_INVREJECT_NAME:-E2E Consultant}"
CUSER="${TT_INVREJECT_USER:-e2e_consultant}"
COMMENT="E2E automated invoice-stage reject - week pulled back before export"

hir_hr() { tt_login "e2e_hr" "$TT_HR_READY"; }

# hir_open_tab — select the invoice tab and wait for its own month list.
#
# Waits on lstInvoiceMonths rather than on a week list, because this tab has no
# week list. A wait on a week list here times out on a perfectly healthy tab.
hir_open_tab() {
  tt_hr_try_click_tab "$TAB" || return 1
  sleep 3
  local i
  for i in $(seq 1 20); do
    [ "$(playwright-cli eval "() => String(!!document.querySelector('$TT_HR_LST_MONTHS'))" 2>/dev/null | _tt_eval_str)" = "true" ] && return 0
    sleep 1
  done
  return 1
}

# hir_months — the month labels in the filter, pipe joined. Empty when the tab
# shows everything at once (no month filter rendered), which is a legitimate
# state and is handled by the caller as "one pass over what is shown".
hir_months() {
  tt_hr_week_labels
}

# hir_select_month <label> - expand that month and only it. The Monthly tab lists
# MONTH GROUPS since 2026-09-28 (model b2202878 / 771be886) and a month's rows exist
# only while it is expanded; only the newest starts that way.
hir_select_month() {
  case "$(tt_hr_group_expand "$1")" in OK:*) echo ok ;; *) echo nf ;; esac
}

# hir_count - rows for $CNAME in the expanded month, matched on the consultant
# CELL exactly ('E2E Consultant' is a prefix of 'E2E Consultant Two').
hir_count() {
  tt_hr_count_rows_for "$CNAME"
}

hir_total() {
  local months m n total=0 hit=""
  months="$(hir_months)"
  if [ -z "$months" ] || [ "$months" = "null" ]; then
    echo "0|(no months listed)"; return 0
  fi
  local IFS='|'
  for m in $months; do
    [ -n "$m" ] || continue
    unset IFS
    hir_select_month "$m" >/dev/null 2>&1
    n="$(hir_count)"; n="${n:-0}"
    [ "$n" -gt 0 ] && [ -z "$hit" ] && hit="$m"
    total=$(( total + n ))
    IFS='|'
  done
  unset IFS
  echo "$total|${hit:-(none)}"
}

# hir_reject_one — on the CURRENTLY SELECTED month, reject the first $CNAME card.
hir_reject_one() {
  [ "$(tt_hr_row_click "$CNAME" "" "$TT_HR_BTN_INVOICE_REJECT")" = "ok" ] || return 1
  sleep 4
  # Main.AssignmentEntry_RejectPage: a textarea bound to RejectionComment and a
  # footer Reject. The textarea is now named - txtRejectionComment, matching the
  # PM and client reject pages - so it is tried by name first and structurally
  # second. The footer button is still the GENERATED actionButton1 and is pressed
  # by caption, the same approach tt_hr_reject_card_for_project uses.
  #
  # THE BLUR IS LOAD-BEARING NOW. A Mendix text area hands its value over on blur,
  # and the flow behind this button refuses to reject without a comment - so an
  # uncommitted comment no longer produces a rejection with an empty reason, it
  # produces no rejection at all and a message this helper would report as a
  # missing card.
  playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); if(!d) return 'nopopup'; const ta=d.querySelector('.mx-name-txtRejectionComment textarea') || d.querySelector('textarea') || [...d.querySelectorAll('input[type=text]')].pop(); if(!ta) return 'nofield'; const set=Object.getOwnPropertyDescriptor(ta.__proto__,'value').set; set.call(ta,'$COMMENT'); ta.dispatchEvent(new Event('input',{bubbles:true})); ta.dispatchEvent(new Event('change',{bubbles:true})); ta.blur(); return 'typed'; }" 2>/dev/null | _tt_eval_str | grep -qx typed || return 2
  sleep 1
  tt_click_button_exact "reject" popup || return 3
  sleep 4
  tt_dismiss_dialogs
  return 0
}

# ------------------------------------------------- 1. find or make a card
hir_hr
hir_open_tab || tt_fail "the '$TAB' tab did not open, or it rendered no month list ($TT_HR_LST_MONTHS). The tab is opened by its tile's widget name (cardKpiInvoice) and waits for its pane; check what the dashboard actually shows."

read -r TOTAL MONTH <<EOF
$(hir_total | tr '|' ' ')
EOF
TOTAL="${TOTAL:-0}"

if [ "$TOTAL" -eq 0 ]; then
  echo "  no '$CNAME' card awaiting export - driving the process chain to make one"
  tt683_process_all_toprocess 3 >/dev/null 2>&1 || true
  hir_hr
  hir_open_tab || tt_fail "the '$TAB' tab did not reopen after processing"
  read -r TOTAL MONTH <<EOF
$(hir_total | tr '|' ' ')
EOF
  TOTAL="${TOTAL:-0}"
fi

[ "$TOTAL" -gt 0 ] || tt_fail "no '$CNAME' card on '$TAB' even after processing To Process entries. An entry reaches this tab only in AwaitingExport, which is what Main.ACT_AssignmentEntry_Process sets - so either nothing was in To Process to process, or processing is failing. suites/70-tickets/tt683/ covers that chain directly and is the place to look."
echo "  '$TAB' holds $TOTAL '$CNAME' card(s), first found in month $MONTH"

# ------------------------------------------------------ 2. reject one card
case "$MONTH" in
  "(no"*|"(none)") : ;;
  *) [ "$(hir_select_month "$MONTH")" = "ok" ] || tt_fail "could not re-expand month '$MONTH', where the census found '$CNAME' a moment ago" ;;
esac

# Capture the return code on its own line. Folding it into a command
# substitution would compare against the function's OUTPUT as well as its code,
# and every one of these codes is a single digit that appears in ordinary output.
hir_reject_one
case "$?" in
  1) tt_fail "no '$CNAME' Reject button was clickable in month $MONTH, though the count above says there are $TOTAL. That is a paging or re-render difference between the count and the click, not a product fault." ;;
  2) tt_fail "the Reject button was pressed but no comment field appeared. Main.AssignmentEntry_RejectPage is what should open; if btnInvoiceReject no longer opens it, TT-686 has regressed on the Monthly tab." ;;
  3) tt_fail "the comment was typed but no Reject button in the popup could be pressed - the page opened and then would not confirm" ;;
esac
echo "  rejected one '$CNAME' card with a comment"

# --------------------------------------------------- 3. it left the tab
hir_hr
hir_open_tab || tt_fail "the '$TAB' tab did not reopen after the reject"
read -r AFTER _ <<EOF
$(hir_total | tr '|' ' ')
EOF
AFTER="${AFTER:-0}"
if [ "$AFTER" -ge "$TOTAL" ]; then
  echo "FAIL: the rejected card is still on '$TAB' (before=$TOTAL, after=$AFTER)."
  echo "      TT-686 covers this tab by name - 'Sent, weekly, and Monthly' - and its"
  echo "      complaint was exactly this: the timesheet stays on the screen after a"
  echo "      reject. The entry may be Rejected in the database with the tab merely"
  echo "      stale; either way the operator cannot tell what they have done."
  exit 1
fi
echo "  the card left '$TAB' (before=$TOTAL, after=$AFTER)"

# ------------------------------------- 4. the consultant can act on it again
tt_login "$CUSER" "My Timesheets"
tt_consultant_history_load >/dev/null 2>&1 || true
n="$(tt_rejected_count)"
case "$n" in
  ''|*[!0-9]*) tt_fail "could not read the consultant's Rejected Entries count: [$n]" ;;
  0) echo "FAIL: the card left '$TAB' but the consultant's Rejected Entries list is empty."
     echo "      An entry pulled back from the invoice stage that does not reach the"
     echo "      consultant is stranded: it is out of HR's queue and nobody is asked to"
     echo "      correct it."
     exit 1 ;;
esac

echo "PASS: verify-hr-invoice-reject - HR rejected a '$CNAME' card from '$TAB' (AwaitingExport -> Rejected), the card left the tab ($TOTAL -> $AFTER), and the consultant's Rejected Entries list holds $n row(s)"
