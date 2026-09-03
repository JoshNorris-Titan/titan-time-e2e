#!/usr/bin/env bash
# Shared fixtures for TT-647 — approver name + approving role on the HR dashboard's
# "Weekly Timesheets to Process" tab.
#
# Source AFTER lib/_login.sh:
#   source "$(dirname "$0")/lib/_login.sh"
#   source "$(dirname "$0")/lib/_tt647.sh"
#
# What the approver lines render, and where they come from:
#   Main.DS_EntriesForTab calls Main.SUB_ApprovalHelper_SetApprovalLines for every
#   ToProcess row. That subflow reads the entry's Main.ChangeLog trail, keeps only
#   the current submission cycle (createdDate >= AssignmentEntry/SubmittedDT) and
#   only genuine approval steps, then writes:
#     ApprovalLine1 -> the manager-stage approval  -> .mx-name-txtProcessManagerApprover
#     ApprovalLine2 -> the client-stage approval   -> .mx-name-txtProcessClientApprover
#   (both were textApprovedBy1/2 until the TT-724 phase 4 snippet fold renamed them.)
#   Each line is a BARE NAME, and the literal 'N/A' when that stage has no
#   approval row in the cycle.
#
# The name is ChangeLog/ChangeBy, set by Main.ACT_ApprovalHelper_Approve from
# Core.SUB_Account_Name on the ACTING user's account -- FullName, falling back to
# Email. The one exception is ChangeMethod=Token (the emailed client link), which
# has no signed-in user and renders Project/ContactName instead.
#
# NOTE FOR ANYONE EXTENDING THESE TESTS. TT-647/648/649 describe a sentence form,
# "Approved by <name> (<role>) on <date>", with role suffixes distinguishing an HR
# stand-in from a real approver. That design was abandoned and the tickets were
# never updated -- do not reintroduce those assertions. The surviving guarantee
# these tests protect is narrower but real: the line names the person who ACTUALLY
# approved, so an HR stand-in shows the HR user, never the PM's or client's name.
#
# Design notes:
#  * The HR dashboard renders only the ACTIVE tab, and the tab strip was not part
#    of the widget-naming pass — tabs are selected by text via tt_click_text.
#  * Main.DS_EntriesForTab returns an EMPTY list while HRDashboardTab/SelectedStart
#    is empty, so a week must always be selected before the entries gallery has
#    anything in it. tt647_select_week_with does that.
#  * Cards inside the entries gallery are container<Tab>Card -- explicitly named
#    since the TT-724 phase 4 fold, but one name per tab where the retired snippet
#    had a single generated container13. The card lookup still falls back to
#    walking up from the named approver text widget if none of them matches.

# tt647_session_fullname -- the display name Core.SUB_Account_Name records in
# ChangeLog/ChangeBy for the currently signed-in user (FullName, falling back to
# Email). Read live from the session so no test hardcodes a fixture's full name,
# which is not recorded anywhere in this repo.
tt647_session_fullname() {
  playwright-cli eval "() => { try { const a = mx.session.userObject.jsonData.attributes; return (a.FullName && a.FullName.value) || (a.Email && a.Email.value) || ''; } catch (e) { return ''; } }" 2>/dev/null | _tt_eval_str
}

TT647_TAB_TOPROCESS="WEEKLY TO PROCESS"
TT647_TAB_MANAGER="MANAGER APPROVAL"
TT647_TAB_CLIENT="CLIENT APPROVAL"
TT647_TAB_SENT="SENT"

# TT647_GAL -- the entries gallery. Named once because EVERY read of it has to go
# through tt647_load_cards first; see below.
TT647_GAL="$TT_HR_GAL_ENTRIES"

# tt647_load_cards [label] -- page the entries gallery in fully, then echo how many
# cards it holds.
#
# MANDATORY BEFORE ANY READ OF TT647_GAL. galTabEntries is a virtual-scrolling
# gallery with pageSize 4: it renders four cards and fetches the rest only when its
# own .widget-gallery-content box is scrolled. Reading .innerText without scrolling
# therefore answers "is this row in the first four", not "is this row in this week",
# and the two are indistinguishable in the output.
#
# Measured on dev 2026-08-31: all five WEEKLY TO PROCESS weeks rendered 4 cards while
# their heading read "Weekly Timesheets to Process (5)", and one scroll took the
# count to 5. verify-tt647-a3 failed on exactly this -- its seeded zero-hour entries
# reached ToProcess (confirmed at the data layer) but sat past position 4, so the
# card wait timed out and tt647_locate_entry reported "(none of the three HR tabs)".
# Do not add a new read of this gallery without a tt647_load_cards in front of it.
tt647_load_cards() {
  tt_gallery_load_all "$TT647_GAL" "${1:-entries gallery}"
}

# tt647_hr_open_tab <TAB TEXT> — log in as HR and switch to the named tab.
tt647_hr_open_tab() {
  local tab="$1"
  tt_login "e2e_hr" "WEEKLY TO PROCESS"
  tt_click_text "$tab" "HR '$tab' tab"
  tt_wait_for "$TT_HR_GAL_WEEKS" "'$tab' available-weeks list"
  tt647_log_tab_state "opened '$tab'"
}

# tt647_log_tab_state <label> -- print what the HR dashboard tab is actually
# showing. Cheap, and it runs on the happy path too: a CI run leaves nothing
# behind except its log, and the difference between "the entry never routed" and
# "a filter is hiding it" is invisible without this.
#
# cb<Tab>Consultant / cb<Tab>Project are the tab's own filter dropdowns, and
# Main.DS_WeeksForTab applies BOTH to the week list (HRDashboardTab_Account /
# HRDashboardTab_Project). One left set by an earlier test silently narrows every
# week and card the tab will show, which is the leading explanation for
# verify-tt647-a2 failing with a correctly-routed entry.
tt647_log_tab_state() {
  local label="${1:-tab state}" s
  # Page the gallery in first, or cardsInSelectedWeek reports the page size (4)
  # rather than the week -- which is precisely how a3's log showed 4 cards before
  # the seed and 4 after two more entries landed in that same week.
  tt647_load_cards >/dev/null 2>&1 || true
  s="$(playwright-cli eval "() => { const val=sel=>{ const w=document.querySelector(sel); if(!w) return '(absent)'; const i=w.querySelector('input,select'); const v=(i&&i.value)||''; const txt=(w.innerText||'').replace(/\\s+/g,' ').trim(); return v || txt || '(empty)'; }; const wk=document.querySelector('$TT_HR_GAL_WEEKS'); const weeks=wk?[...new Set([...wk.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} /.test(t)))]:[]; const g=document.querySelector('$TT_HR_GAL_ENTRIES'); const cards=g?g.querySelectorAll('$TT_HR_TXT_APPROVER1,$TT_HR_BTN_APPROVE').length:0; return 'consultantFilter=' + val('$TT_HR_CB_CONSULTANT') + ' | projectFilter=' + val('$TT_HR_CB_PROJECT') + ' | weeks(' + weeks.length + ')=' + (weeks.join(', ') || '(none)') + ' | cardsInSelectedWeek=' + cards; }" 2>/dev/null | _tt_eval_str)"
  echo "  [tab] $label: $s"
}

# tt647_select_week_with <needle> — walk the available-weeks list on the current
# tab, selecting each week until the entries gallery mentions <needle>.
# Prints the matched week label, returns 0. Returns 1 if no week matches.
tt647_select_week_with() {
  local needle="$1" labels lbl
  labels=$(playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_WEEKS'); if(!g) return ''; const set=[...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} \\d{2} - [A-Z][a-z]{2} \\d{2}/.test(t)))]; return set.join('|'); }" 2>/dev/null | sed -n '2p')
  labels="${labels%\"}"; labels="${labels#\"}"
  local IFS='|'
  for lbl in $labels; do
    [ -n "$lbl" ] || continue
    unset IFS
    playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_WEEKS'); const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$lbl')===0); if(el){el.click(); return 'ok';} return 'nf'; }" >/dev/null 2>&1
    sleep 4
    # Load the whole week before concluding it does not hold the needle -- this walk
    # decides "no entry anywhere", so a first-page-only read makes it lie.
    tt647_load_cards "week $lbl" >/dev/null 2>&1 || true
    if playwright-cli eval "() => String((((document.querySelector('$TT_HR_GAL_ENTRIES')||{}).innerText)||'').indexOf('$needle') >= 0)" 2>/dev/null | grep -qiw true; then
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
# seeing the PM's name for an HR-performed approval. a2 failed the same way
# against an entry that had reached ToProcess with no approval at all (both
# lines 'N/A'). Both looked like product defects and were not.
tt647_select_exact_week() {
  local frag="$1" r
  r=$(playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_WEEKS'); if(!g) return 'nogallery'; const el=[...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).find(e=>(e.innerText||'').trim().indexOf('$frag')===0); if(!el) return 'nf'; el.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)
  case "$r" in
    ok)
      sleep 4
      # Selecting a week re-runs Main.DS_EntriesForTab, so the gallery comes back at
      # page 1. Every caller reads it straight afterwards; page it in here so none of
      # them has to remember.
      tt647_load_cards "week $frag" >/dev/null 2>&1 || true
      return 0
      ;;
  esac
  return 1
}

# tt647_wait_for_card <week-fragment> <needle> [needle2] [tries]
# Re-pin <week-fragment> and poll until a card matching the needles appears.
# Returns 1 if it never does, with TT647_WAIT_ERR distinguishing the two very
# different reasons: the week was never offered by the picker, or the week was
# offered but held no matching card. Callers should include TT647_WAIT_ERR.
#
# The approval workflow routes a submitted entry into the queue ASYNCHRONOUSLY,
# so pinning the week straight after submit finds the week (the picker lists it
# regardless) but not yet the card. Without this wait the approve step reports
# "no Approve control" purely because it looked too early.
tt647_wait_for_card() {
  local frag="$1" needle="$2" needle2="${3:-}" tries="${4:-10}" i
  local week_seen="" weeks=""
  TT647_WAIT_ERR=""

  for i in $(seq 1 "$tries"); do
    if tt647_select_exact_week "$frag"; then
      week_seen=1
      if playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_ENTRIES'); if(!g) return 'false'; const t=g.innerText||''; return String(t.indexOf('$needle')>=0 && ('$needle2'==='' || t.indexOf('$needle2')>=0)); }" 2>/dev/null | grep -qiw true; then
        return 0
      fi
    fi
    sleep 6
  done

  # Say WHICH half failed. These point at completely different causes, and
  # collapsing them into one message is what made verify-tt647-a2 read as "the
  # workflow never routed the entry" when the week may simply never have been
  # offered. Main.DS_WeeksForTab retrieves [Status = tab status] and then filters
  # by the tab's OWN consultant/project dropdowns
  # (HRDashboardTab_Account / HRDashboardTab_Project) -- so a filter left set by an
  # earlier test narrows the picker and hides the week, with the entry sitting
  # correctly in the queue the whole time.
  tt647_log_tab_state "card wait gave up on week '$frag'"
  weeks="$(playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_WEEKS'); if(!g) return '(no week picker)'; const s=[...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(Boolean))]; return s.length ? s.join(' / ') : '(picker is empty)'; }" 2>/dev/null | _tt_eval_str)"

  if [ -z "$week_seen" ]; then
    TT647_WAIT_ERR="week '$frag' was never offered by this tab's week picker. Weeks on offer: $weeks. The entry may be in the queue but hidden by a consultant/project filter left set on this tab, or it may not have reached this status at all."
  else
    TT647_WAIT_ERR="week '$frag' WAS selectable, but no card in it matches '$needle'${needle2:+ + '$needle2'} after ~$((tries * 6))s, with $(tt647_load_cards) card(s) fully paged in. The week is in this queue, so routing worked; the specific entry is what is missing."
  fi
  return 1
}

# tt647_locate_entry <week-fragment> <needle>
# Say WHICH HR queue actually holds <needle>'s card for <week-fragment>, by walking
# every week-picker tab. Prints e.g. "MANAGER APPROVAL, CLIENT APPROVAL", or
# "(no week-picker tab; the entry is Draft, Rejected or AwaitingExport)".
#
# THE TAB LIST IS FOUR, NOT THREE. Main.SUB_HRDashboard_CreateTabs creates exactly
# four HRDashboardTab rows -- Manager, Customer, Process, Sent -- and this walked
# only the first three, so an Exported entry came back as "nowhere". PENDING and
# MONTHLY TO BE INVOICED are not HRDashboardTab tabs at all (the monthly one has no
# week gallery), so Draft, Rejected and AwaitingExport are genuinely unreachable from
# here; say that rather than implying the entry does not exist.
#
# FOR FAILURE PATHS ONLY -- it changes the selected tab and week, so call it when
# the test is about to fail anyway.
#
# WHY. "the entry did not reach the To Process tab" has two completely different
# causes and the message cannot tell them apart: the entry was never submitted, or
# it was submitted and ROUTED SOMEWHERE ELSE. Main.SUB_AssignmentEntry_Submit picks
# the queue from the hours it re-reads server-side -- 0 goes to ToProcess, anything
# else follows the project's approval flags -- so a seed whose hours had not yet
# committed lands its entries in the approval queues and leaves To Process empty.
# That is a seed defect that reads exactly like a product routing defect. Naming the
# queue turns a day of model-diving into one line of output.
tt647_locate_entry() {
  local frag="$1" needle="$2" tab found=""
  for tab in "$TT647_TAB_TOPROCESS" "$TT647_TAB_MANAGER" "$TT647_TAB_CLIENT" "$TT647_TAB_SENT"; do
    tt647_hr_open_tab "$tab" >/dev/null 2>&1
    # tt647_select_exact_week pages the gallery in, so this read sees every card in
    # the week rather than the first four.
    tt647_select_exact_week "$frag" || continue
    if playwright-cli eval "() => String((((document.querySelector('$TT_HR_GAL_ENTRIES')||{}).innerText)||'').indexOf('$needle') >= 0)" 2>/dev/null | grep -qiw true; then
      found="${found:+$found, }$tab"
    fi
  done
  echo "${found:-(no week-picker tab holds it, so it is Draft, Rejected or AwaitingExport)}"
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
  # The card may be past the gallery's first page of four.
  tt647_load_cards >/dev/null 2>&1 || true
  out=$(playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_ENTRIES'); if(!g) return ''; const hit=t=>t.indexOf('$needle')>=0 && ('$needle2'==='' || t.indexOf('$needle2')>=0); let cards=[...g.querySelectorAll('$TT_HR_CARD')]; if(!cards.length){ cards=[...g.querySelectorAll('$TT_HR_TXT_APPROVER1')].map(e=>{let p=e; for(let i=0;i<9;i++){ if(!p.parentElement) break; p=p.parentElement; if(hit(p.innerText||'')) return p; } return null;}).filter(Boolean); } const c=cards.find(x=>hit(x.innerText||'')); if(!c) return ''; const a=c.querySelector('$TT_HR_TXT_APPROVER1'); const b=c.querySelector('$TT_HR_TXT_APPROVER2'); return (((a&&a.innerText)||'').trim())+'~~'+(((b&&b.innerText)||'').trim()); }" 2>/dev/null | sed -n '2p')
  out="${out%\"}"; out="${out#\"}"
  echo "$out"
}

# tt647_require_widgets — fail with a pointed message if the TT-647 dynamic texts
# are not on the page at all. Without this, an unwired snippet would surface as a
# vague "expected text not found" and read like a logic bug.
tt647_require_widgets() {
  local label="${1:-To Process tab}"
  playwright-cli eval "() => String(!!document.querySelector('$TT_HR_TXT_APPROVER1'))" 2>/dev/null | grep -qiw true \
    || tt_fail "$label: no .mx-name-txtProcessManagerApprover widget rendered — the TT-647 dynamic texts are missing from the To Process tab on Main.HRDashboard (or are not named txtProcessManagerApprover/txtProcessClientApprover)"
}

# tt647_hr_approve_card <needle> [needle2]
# On an Awaiting-* tab with a week already selected, clicks Approve on the card
# matching <needle> (and <needle2> when given -- pass the consultant name so the
# right card is chosen when a tab holds several for one project), then waits for
# THAT card to leave the tab. Returns 0 only if it actually left.
#
# On failure, TT647_APPROVE_ERR says WHICH of the four things went wrong: no
# gallery, no matching card, the confirmation was not dismissed, or the card
# never left. Callers should include it -- reporting every failure as "no Approve
# control" is what sent verify-tt647-a6 to the wrong root cause for days. The old version ended with an
# unconditional `return 0` after its wait loop, so a click that never took effect
# was reported as a successful approval — verify-tt647-a2/a6 then asserted against
# an entry still sitting in the approval queue and failed with an empty approver
# line, pointing at TT-647 rather than at this helper. Clearing the confirmation
# dialog matters too: ACT_HRDashboard_ApproveOrReject can put one up, and until
# it is dismissed the approval does not commit.
tt647_hr_approve_card() {
  local needle="$1" needle2="${2:-}" i r
  TT647_APPROVE_ERR=""

  # 1) Click Approve on the card matching the needles. Page the gallery in first:
  #    with pageSize 4, "cards are present but none matches" was reachable purely by
  #    the card sitting on page 2.
  tt647_load_cards >/dev/null 2>&1 || true
  r="$(playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_ENTRIES'); if(!g) return 'nogallery'; const bs=[...g.querySelectorAll('$TT_HR_BTN_APPROVE')]; for(const b of bs){ let p=b; for(let i=0;i<9;i++){ if(!p.parentElement) break; p=p.parentElement; const t=p.innerText||''; if(t.indexOf('$needle')>=0 && ('$needle2'==='' || t.indexOf('$needle2')>=0)){ b.click(); return 'ok'; } } } return bs.length ? 'nomatch' : 'nobuttons'; }" 2>/dev/null | _tt_eval_str)"
  case "$r" in
    ok) : ;;
    nogallery) TT647_APPROVE_ERR="the entries gallery is not rendered at all"; return 1 ;;
    nomatch)   TT647_APPROVE_ERR="cards are present with Approve buttons, but none matches '$needle'${needle2:+ + '$needle2'}"; return 1 ;;
    *)         TT647_APPROVE_ERR="no Approve button anywhere in the entries gallery"; return 1 ;;
  esac
  sleep 3

  # 2) Clear the confirmation. ITS BUTTON IS CAPTIONED "Approve", which
  #    tt_clear_dialogs does NOT accept by default -- its built-in list is
  #    yes|submit anyway|confirm|continue|proceed|ok. Passing the caption is
  #    mandatory, and the result must NOT be swallowed: this used to be
  #    `tt_clear_dialogs 6 >/dev/null 2>&1 || true`, so the dialog stayed open,
  #    the approval never committed, the card never left, and the function
  #    returned 1 -- which verify-tt647-a6 reported as "no Approve control on the
  #    Manager Approval card". The button was always there; the confirmation was
  #    never dismissed. (Main.HRDashboard renders the tab's Approve button with no
  #    visibility condition, so "no Approve control" could never be literally true.)
  if ! tt_clear_dialogs 8 "Approve"; then
    TT647_APPROVE_ERR="the Approve confirmation was not dismissed: ${TT_DIALOG_BLOCKED:-unknown dialog}"
    return 1
  fi

  # 3) ACT_HRDashboard_ApproveOrReject refreshes every tab; OUR card should vanish.
  #    Match per-card on both needles rather than substring-matching the whole
  #    gallery: several cards can share a project name, so a gallery-wide check
  #    reports "still there" because of somebody else's row.
  for i in $(seq 1 15); do
    # ACT_HRDashboard_ApproveOrReject refreshes the tab, which puts the gallery back
    # on page 1. Absence is the PASS condition here, so an unpaged read would call a
    # card "gone" when it had only scrolled out of the first four.
    tt647_load_cards >/dev/null 2>&1 || true
    r="$(playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_ENTRIES'); if(!g) return 'false'; const rows=[...g.querySelectorAll('$TT_HR_BTN_APPROVE')].map(b=>{ let p=b; for(let k=0;k<9;k++){ if(!p.parentElement) break; p=p.parentElement; const t=p.innerText||''; if(t.indexOf('$needle')>=0) return t; } return ''; }); return String(rows.some(t => t.indexOf('$needle')>=0 && ('$needle2'==='' || t.indexOf('$needle2')>=0))); }" 2>/dev/null | _tt_eval_str)"
    [ "$r" = "false" ] && return 0
    tt_clear_dialogs 3 "Approve" >/dev/null 2>&1 || true
    sleep 2
  done
  TT647_APPROVE_ERR="Approve was clicked and confirmed, but the card is still on the tab after ~30s"
  return 1
}
