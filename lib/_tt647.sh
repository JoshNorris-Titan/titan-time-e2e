#!/usr/bin/env bash
# Shared fixtures for TT-647 — approver name + approval date on the HR dashboard's
# "Weekly Timesheets to Process" tab.
#
# Source AFTER lib/_login.sh:
#   source "$(dirname "$0")/lib/_login.sh"
#   source "$(dirname "$0")/lib/_tt647.sh"
#
# What TT-647 renders, and where it comes from:
#   Main.DS_EntriesForTab calls Main.SUB_ApprovalHelper_SetApprovalLines for every
#   ToProcess row. That subflow reads the entry's Main.ChangeLog trail, keeps only
#   the current submission cycle (createdDate >= AssignmentEntry/SubmittedDT) and
#   only genuine approval steps, then writes:
#     ApprovalLine1 -> the manager-stage approval   -> .mx-name-textApprovedBy1
#     ApprovalLine2 -> the client-stage approval    -> .mx-name-textApprovedBy2
#   With no approval step at all, line 1 reads "No approval required".
#
# The role suffix is derived from ChangeLog.ChangeMethod plus FromStatus:
#   Manager                      -> "(Project Manager)"
#   Token  (emailed client link) -> "(Client)"
#   HR, from AwaitingManagerApproval -> "(HR/Titan Manager, on behalf of Project Manager)"
#   HR, from AwaitingCustomerApproval-> "(HR/Titan Manager, on behalf of Client)"
#
# Design notes:
#  * The HR dashboard renders only the ACTIVE tab, and the tab strip was not part
#    of the widget-naming pass — tabs are selected by text via tt_click_text.
#  * Main.DS_EntriesForTab returns an EMPTY list while HRDashboardTab/SelectedStart
#    is empty, so a week must always be selected before the entries gallery has
#    anything in it. tt647_select_week_with does that.
#  * Cards inside .mx-name-galTabEntries use the snippet's generated container name
#    (container13). That is exactly the brittleness CLAUDE.md warns about, so the
#    card lookup falls back to walking up from the named approver text widget.

TT647_TAB_TOPROCESS="WEEKLY TO PROCESS"
TT647_TAB_MANAGER="MANAGER APPROVAL"
TT647_TAB_CLIENT="CLIENT APPROVAL"

# tt647_hr_open_tab <TAB TEXT> — log in as HR and switch to the named tab.
tt647_hr_open_tab() {
  local tab="$1"
  tt_login "e2e_hr" "WEEKLY TO PROCESS"
  tt_click_text "$tab" "HR '$tab' tab"
  tt_wait_for ".mx-name-galTabAvailableWeeks" "'$tab' available-weeks list"
}

# tt647_select_week_with <needle> — walk the available-weeks list on the current
# tab, selecting each week until the entries gallery mentions <needle>.
# Prints the matched week label, returns 0. Returns 1 if no week matches.
tt647_select_week_with() {
  local needle="$1" labels lbl
  labels=$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); if(!g) return ''; const set=[...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} \\d{2} - [A-Z][a-z]{2} \\d{2}/.test(t)))]; return set.join('|'); }" 2>/dev/null | sed -n '2p')
  labels="${labels%\"}"; labels="${labels#\"}"
  local IFS='|'
  for lbl in $labels; do
    [ -n "$lbl" ] || continue
    unset IFS
    playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$lbl')===0); if(el){el.click(); return 'ok';} return 'nf'; }" >/dev/null 2>&1
    sleep 4
    if playwright-cli eval "() => String((((document.querySelector('.mx-name-galTabEntries')||{}).innerText)||'').indexOf('$needle') >= 0)" 2>/dev/null | grep -qiw true; then
      echo "$lbl"
      return 0
    fi
    IFS='|'
  done
  unset IFS
  return 1
}

# tt647_select_exact_week <week-fragment>
# Select the ONE week whose picker label starts with <week-fragment> (the
# "MMM DD - MMM DD" form recorded in TT_SUBMITTED_WEEK at submit time).
# Returns 1 if no such week is offered on this tab.
#
# WHY THIS EXISTS. tt647_select_week_with walks weeks until the gallery merely
# MENTIONS a needle, and tt647_card_lines then took the first card containing
# it. With one card per project that was fine; with several it is not.
# verify-tt647-a1 and -a6 use the SAME project AND the same consultant — only
# the week differs — so a6 was reading the PM-approved card a1 left behind and
# failing with "(Project Manager)" for an HR-performed approval. a2 failed the
# same way against an entry that had reached ToProcess with no approval at all
# ("No approval required"). Both looked like TT-647 defects and were not.
tt647_select_exact_week() {
  local frag="$1" r
  r=$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); if(!g) return 'nogallery'; const el=[...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).find(e=>(e.innerText||'').trim().indexOf('$frag')===0); if(!el) return 'nf'; el.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)
  case "$r" in ok) sleep 4; return 0 ;; esac
  return 1
}

# tt647_wait_for_card <week-fragment> <needle> [needle2] [tries]
# Re-pin <week-fragment> and poll until a card matching the needles appears.
# Returns 1 if it never does.
#
# The approval workflow routes a submitted entry into the queue ASYNCHRONOUSLY,
# so pinning the week straight after submit finds the week (the picker lists it
# regardless) but not yet the card. Without this wait the approve step reports
# "no Approve control" purely because it looked too early.
tt647_wait_for_card() {
  local frag="$1" needle="$2" needle2="${3:-}" tries="${4:-10}" i
  for i in $(seq 1 "$tries"); do
    if tt647_select_exact_week "$frag"; then
      if playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabEntries'); if(!g) return 'false'; const t=g.innerText||''; return String(t.indexOf('$needle')>=0 && ('$needle2'==='' || t.indexOf('$needle2')>=0)); }" 2>/dev/null | grep -qiw true; then
        return 0
      fi
    fi
    sleep 6
  done
  return 1
}

# tt647_card_lines <needle> [needle2]
# Prints the two approver lines of the entries-gallery card matching <needle>
# (and <needle2> when given), separated by "~~" (line1~~line2). Either side may
# be empty. Prints nothing if no card matches.
#
# Pass BOTH the consultant name and the project when a tab can hold several
# cards for the same project — with a week already pinned via
# tt647_select_exact_week, that identifies one entry.
tt647_card_lines() {
  local needle="$1" needle2="${2:-}" out
  out=$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabEntries'); if(!g) return ''; const hit=t=>t.indexOf('$needle')>=0 && ('$needle2'==='' || t.indexOf('$needle2')>=0); let cards=[...g.querySelectorAll('.mx-name-container13')]; if(!cards.length){ cards=[...g.querySelectorAll('.mx-name-textApprovedBy1')].map(e=>{let p=e; for(let i=0;i<9;i++){ if(!p.parentElement) break; p=p.parentElement; if(hit(p.innerText||'')) return p; } return null;}).filter(Boolean); } const c=cards.find(x=>hit(x.innerText||'')); if(!c) return ''; const a=c.querySelector('.mx-name-textApprovedBy1'); const b=c.querySelector('.mx-name-textApprovedBy2'); return (((a&&a.innerText)||'').trim())+'~~'+(((b&&b.innerText)||'').trim()); }" 2>/dev/null | sed -n '2p')
  out="${out%\"}"; out="${out#\"}"
  echo "$out"
}

# tt647_require_widgets — fail with a pointed message if the TT-647 dynamic texts
# are not on the page at all. Without this, an unwired snippet would surface as a
# vague "expected text not found" and read like a logic bug.
tt647_require_widgets() {
  local label="${1:-To Process tab}"
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-textApprovedBy1'))" 2>/dev/null | grep -qiw true \
    || tt_fail "$label: no .mx-name-textApprovedBy1 widget rendered — the TT-647 dynamic texts are missing from Main.SNIP_HRDashboardTab (or are not named textApprovedBy1/textApprovedBy2)"
}

# tt647_hr_approve_card <needle>
# On an Awaiting-* tab with a week already selected, clicks Approve on the card
# matching <needle> (HR approving in the PM's or the client's place), then waits
# for the card to leave the tab. Returns 1 if no matching card has an Approve.
# Returns 0 ONLY if the card actually left the tab. The old version ended with an
# unconditional `return 0` after its wait loop, so a click that never took effect
# was reported as a successful approval — verify-tt647-a2/a6 then asserted against
# an entry still sitting in the approval queue and failed with an empty approver
# line, pointing at TT-647 rather than at this helper. Clearing the confirmation
# dialog matters too: ACT_HRDashboard_ApproveOrReject can put one up, and until
# it is dismissed the approval does not commit.
tt647_hr_approve_card() {
  local needle="$1" i
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabEntries'); if(!g) return 'nf'; const bs=[...g.querySelectorAll('.mx-name-btnApprove')]; for(const b of bs){ let p=b; for(let i=0;i<9;i++){ if(!p.parentElement) break; p=p.parentElement; if((p.innerText||'').indexOf('$needle')>=0){ b.click(); return 'ok'; } } } return 'nf'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok || return 1
  sleep 3
  tt_clear_dialogs 6 >/dev/null 2>&1 || true
  # ACT_HRDashboard_ApproveOrReject refreshes every tab; the card should vanish.
  for i in $(seq 1 15); do
    if ! playwright-cli eval "() => String((((document.querySelector('.mx-name-galTabEntries')||{}).innerText)||'').indexOf('$needle') >= 0)" 2>/dev/null | grep -qiw true; then
      return 0
    fi
    tt_clear_dialogs 3 >/dev/null 2>&1 || true
    sleep 2
  done
  return 1
}
