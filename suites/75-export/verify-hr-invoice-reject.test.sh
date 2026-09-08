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
# HRDashboardTab tabs. It is page-level, it has NO week picker, and its filter is
# galAvailableMonths - so tt_hr_count_cards_for and tt_hr_reject_card_for_project,
# which both iterate TT_HR_GAL_WEEKS, iterate an empty list here and report a
# clean "no card" against a tab full of cards. The month walk below is that
# difference, and it is the whole reason this is a separate file rather than a
# fourth argument to the shared helper.
#
# WHAT IT ASSERTS
#   A. An AwaitingExport card for the e2e consultant is on the tab.
#   B. Pressing its Reject and confirming with a comment removes it from the tab.
#   C. The entry arrives back in the consultant's Rejected Entries.
#
# It does NOT assert an empty-comment guard: the HR reject route runs
# Main.NACT_AssignmentEntry_PageReject -> Main.ACT_ApprovalHelper_Reject, which
# has no "Left Comments?" branch. The PM and client routes do. See
# verify-hr-process-reject for the same note.
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
source "$TT_ROOT/lib/_tt692693.sh"
source "$TT_ROOT/lib/_tt683.sh"

TAB="MONTHLY TO BE INVOICED"
CNAME="${TT_INVREJECT_NAME:-E2E Consultant}"
CUSER="${TT_INVREJECT_USER:-e2e_consultant}"
COMMENT="E2E automated invoice-stage reject - week pulled back before export"

hir_hr() { tt_login "e2e_hr" "WEEKLY TO PROCESS"; }

# hir_open_tab — select the invoice tab and wait for its own gallery.
#
# Waits on galInvoiceEntries rather than on a week list, because this tab has no
# week list. A wait on TT_HR_GAL_WEEKS here times out on a perfectly healthy tab.
hir_open_tab() {
  tt_try_click_text "$TAB" || return 1
  sleep 3
  local i
  for i in $(seq 1 20); do
    playwright-cli eval "() => String(!!document.querySelector('$TT_HR_GAL_INVOICE'))" 2>/dev/null | grep -qiw true && return 0
    sleep 1
  done
  return 1
}

# hir_months — the month labels in the filter, pipe joined. Empty when the tab
# shows everything at once (no month filter rendered), which is a legitimate
# state and is handled by the caller as "one pass over what is shown".
hir_months() {
  playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_MONTHS'); if(!g) return ''; const s=[...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>t.length>2 && t.length<40))]; return s.join('|'); }" 2>/dev/null | _tt_eval_str
}

hir_select_month() {
  playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_MONTHS'); if(!g) return 'nf'; const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim()==='$1'); if(el){ el.click(); return 'ok'; } return 'nf'; }" 2>/dev/null | _tt_eval_str
  sleep 3
}

# hir_count — cards on the CURRENTLY SELECTED month whose first line is $CNAME.
#
# Scoped from the row's own Reject button and capped at 500 characters, for the
# reason lib/_tt692693.sh documents at length: walk far enough up and the
# ancestor spans several cards, so a neighbouring row's text satisfies the match
# and the count is of the gallery rather than of the consultant.
hir_count() {
  playwright-cli eval "() => { const bs=[...document.querySelectorAll('$TT_HR_BTN_INVOICE_REJECT')].filter(b=>b.offsetParent!==null); let m=0; for(const b of bs){ let el=b; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; const t=(el.innerText||''); if(t.length>10 && t.length<500 && el.querySelectorAll('$TT_HR_BTN_INVOICE_REJECT').length===1){ if(t.split('\n')[0].trim()==='$CNAME') m++; break; } } } return String(m); }" 2>/dev/null | _tt_eval_str
}

# hir_total — walk every month and sum. Prints "<total>|<month with cards>".
hir_total() {
  local months m n total=0 hit=""
  months="$(hir_months)"
  if [ -z "$months" ] || [ "$months" = "null" ]; then
    n="$(hir_count)"; echo "${n:-0}|(no month filter)"; return 0
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
  playwright-cli eval "() => { const bs=[...document.querySelectorAll('$TT_HR_BTN_INVOICE_REJECT')].filter(b=>b.offsetParent!==null); for(const b of bs){ let el=b; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; const t=(el.innerText||''); if(t.length>10 && t.length<500 && el.querySelectorAll('$TT_HR_BTN_INVOICE_REJECT').length===1){ if(t.split('\n')[0].trim()==='$CNAME'){ b.click(); return 'ok'; } break; } } } return 'nf'; }" 2>/dev/null | _tt_eval_str | grep -qiw ok || return 1
  sleep 4
  # Main.AssignmentEntry_RejectPage: a textarea bound to RejectionComment and a
  # footer Reject. Both carry GENERATED widget names (textArea1 / actionButton1),
  # so they are matched structurally and by caption - the same approach
  # tt_hr_reject_card_for_project uses, and for the same reason.
  playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); if(!d) return 'nopopup'; const ta=d.querySelector('textarea') || [...d.querySelectorAll('input[type=text]')].pop(); if(!ta) return 'nofield'; const set=Object.getOwnPropertyDescriptor(ta.__proto__,'value').set; set.call(ta,'$COMMENT'); ta.dispatchEvent(new Event('input',{bubbles:true})); ta.dispatchEvent(new Event('change',{bubbles:true})); ta.blur(); return 'typed'; }" 2>/dev/null | _tt_eval_str | grep -qiw typed || return 2
  sleep 1
  tt_click_button_exact "reject" popup || return 3
  sleep 4
  tt_dismiss_dialogs
  return 0
}

# ------------------------------------------------- 1. find or make a card
hir_hr
hir_open_tab || tt_fail "the '$TAB' tab did not open, or it rendered no $TT_HR_GAL_INVOICE gallery. The tab strip is auto-named and matched on its caption, so a caption change breaks this first - check what the dashboard actually shows."

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
  "(no"*|"(none)") : ;;                       # nothing to select; the tab shows everything
  *) hir_select_month "$MONTH" >/dev/null 2>&1 ;;
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
