#!/usr/bin/env bash
# Shared fixtures for the TT-692 / TT-693 timesheet change set (focus loss,
# line-item rollup, rejected-resubmit parity).
#
# Source AFTER lib/_login.sh:
#   source "$(dirname "$0")/lib/_login.sh"
#   source "$(dirname "$0")/lib/_tt692693.sh"
#
# Design notes for this change set:
#  * The Review & Edit popup (Main.AssignmentEntry_RejectionReview) uses GENERATED
#    widget names (textBox4..textBox10 = Sun..Sat, actionButton2 = "Resubmit
#    Timesheet", actionButton1 = "Cancel"). The TT-693 work adds a line-item editor
#    and editability gating, which will very likely RENUMBER those. So every helper
#    here targets the popup by CAPTION TEXT and by attribute semantics, never by
#    generated .mx-name-textBoxN. Do not "optimise" these into fixed names.
#  * The inline dashboard buttons btnReject/btnApprove/btnProcess are dead controls
#    (no server call). The working reject path is View -> popup -> Reject + comment.

# ---------------------------------------------------------------- popup helpers

# tt_popup — returns the popup root selector if a modal is open, else empty.
tt_popup_open() {
  playwright-cli eval "() => String(!!document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'))" 2>/dev/null | sed -n '2p' | tr -d '"'
}

# tt_popup_text — full text of the open popup (newlines flattened).
tt_popup_text() {
  playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); return d ? (d.innerText||'').replace(/\n+/g,' | ') : ''; }" 2>/dev/null | sed -n '2p'
}

# Button clicking by caption.
#
# NOTE: do NOT build a JS RegExp from a bash-interpolated string here. Inside a
# single-quoted JS string '\s' collapses to 's', so 'review\s*&\s*edit' silently
# becomes /reviews*&s*edit/ and never matches. Plain text comparison only.

# tt_click_button_exact <text> [scope: popup|page]  — trimmed, case-insensitive equality
tt_click_button_exact() {
  local txt="$1" scope="${2:-page}" root
  if [ "$scope" = "popup" ]; then
    root="document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window')"
  else
    root="document"
  fi
  playwright-cli eval "() => { const r=$root; if(!r) return 'noroot'; const want='$txt'.toLowerCase(); const b=[...r.querySelectorAll('button, a, .mx-link')].find(e=>e.offsetParent!==null && (e.innerText||'').trim().toLowerCase()===want); if(b){ b.click(); return 'clicked'; } return 'notfound'; }" 2>/dev/null | sed -n '2p' | grep -q "clicked"
}

# tt_click_button_contains <text> [scope: popup|page]  — case-insensitive substring
tt_click_button_contains() {
  local txt="$1" scope="${2:-page}" root
  if [ "$scope" = "popup" ]; then
    root="document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window')"
  else
    root="document"
  fi
  playwright-cli eval "() => { const r=$root; if(!r) return 'noroot'; const want='$txt'.toLowerCase(); const b=[...r.querySelectorAll('button, a, .mx-link')].find(e=>e.offsetParent!==null && (e.innerText||'').trim().toLowerCase().indexOf(want)>=0); if(b){ b.click(); return 'clicked'; } return 'notfound'; }" 2>/dev/null | sed -n '2p' | grep -q "clicked"
}

# tt_dismiss_dialogs — clears confirm/《OK》dialogs that block submit flows.
# Loops a bounded number of times so a stuck dialog can never hang a test.
tt_dismiss_dialogs() {
  # See tt_clear_dialogs in lib/_login.sh: Mendix keeps closed dialogs in the
  # DOM, so the previous document.querySelector approach clicked dead nodes.
  if ! tt_clear_dialogs 8; then
    echo "  (dialog blocks the action: $TT_DIALOG_BLOCKED)"
    return 1
  fi
  return 0
}

# ------------------------------------------------------------- week navigation

tt_week_label() {
  playwright-cli eval "() => String((document.querySelector('.mx-name-txtWeekRange')||{}).innerText||'')" 2>/dev/null | sed -n '2p' | tr -d '"'
}

tt_rows_text() {
  playwright-cli eval "() => String((document.querySelector('.mx-name-galAssignmentRows')||{}).innerText||'')" 2>/dev/null | sed -n '2p'
}

# tt_goto_week_with_project <project-substring> [max-weeks]
# Steps FORWARD until the assignment grid contains the project. Prints the week.
tt_goto_week_with_project() {
  local proj="$1" max="${2:-14}" i
  for i in $(seq 1 "$max"); do
    case "$(tt_rows_text)" in *"$proj"*) tt_week_label; return 0 ;; esac
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  return 1
}

# tt_goto_fresh_week <project-substring> [max-weeks]
# A "fresh" week for A1/B1 = one where the project row exists, every day cell on
# that row reads as empty, AND the week is still actionable. Steps forward from
# the current week.
#
# WHY THE ACTIONABLE CHECK. "Reads as empty" cannot mean "never used". Main.SUB_
# Timesheet_Zero converts every empty day value to 0 whenever a week is saved or
# submitted, so ANY week that has been touched before reads 0.00 in all seven
# cells for good - identical, on screen, to a week nobody has opened. Treating
# '', '0' and '0.00' alike is still right for THIS job; what was missing is a
# second question the values cannot answer.
#
# tt_week_actionable asks the app instead: Clear, Save and Submit are all hidden
# once Main.Timesheet.Status leaves Draft/Rejected/(empty), and a hidden Mendix
# widget is absent from the DOM. A week that has moved on is therefore one no
# caller of this helper can do anything with - they all fill, save, submit or
# clear - so it is skipped here rather than handed over to fail obscurely later.
# verify-timesheet-clear took such a week and reported "Clear did not empty the
# week" about a Clear button that was not on the page.
tt_goto_fresh_week() {
  local proj="$1" max="${2:-16}" i
  for i in $(seq 1 "$max"); do
    local rows; rows="$(tt_rows_text)"
    case "$rows" in
      *"$proj"*)
        # all day inputs on the matching row blank?
        local blank
        blank=$(playwright-cli eval "() => { const rows=[...document.querySelectorAll('.mx-name-galAssignmentRows [class*=mx-name-txtDay]')]; if(!rows.length) return 'norows'; const vals=rows.map(i=>(i.querySelector('input')||i).value||''); return String(vals.every(v=>v===''||v==='0'||v==='0.00')); }" 2>/dev/null | sed -n '2p' | tr -d '"')
        # Blank-looking is necessary but not sufficient - see the note above.
        if [ "$blank" = "true" ] && [ "$(tt_week_actionable)" = "true" ]; then
          tt_week_label; return 0
        fi
        ;;
    esac
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  return 1
}

# ------------------------------------------------------- rejected-entry fixture

# tt_rejected_count — how many rows the consultant's Rejected Entries list shows.
# "No items found" => 0.
tt_rejected_count() {
  playwright-cli eval "() => { const b=document.body.innerText||''; const i=b.indexOf('Rejected Entries'); if(i<0) return '0'; const seg=b.slice(i, i+400); if(/No items found/i.test(seg)) return '0'; const m=seg.match(/Review & Edit/g); return String(m?m.length:0); }" 2>/dev/null | sed -n '2p' | tr -d '"'
}

# tt_hr_click_view_for <consultant-display-name>
# On the currently-selected week, click the View of the card whose FIRST LINE is
# exactly <consultant-display-name>. Exact first-line match matters: "E2E Consultant"
# is a prefix of "E2E Consultant Two"/"Three", so substring matching picks the wrong row.
tt_hr_click_view_for() {
  local who="$1"
  playwright-cli eval "() => { const vs=[...document.querySelectorAll('.mx-name-btnView, button')].filter(b=>/^view/i.test((b.innerText||'').trim())); for(const v of vs){ let el=v; for(let k=0;k<10;k++){ el=el.parentElement; if(!el) break; const t=(el.innerText||''); if(t.length>10 && t.length<400){ const first=t.split('\n')[0].trim(); if(first==='$who'){ v.click(); return 'clicked'; } } } } return 'notfound'; }" 2>/dev/null | sed -n '2p' | grep -q clicked
}

# tt_hr_reject_first <consultant-name> <tab-caption>
# As HR: open <tab>, then SCAN the week picker (the tab is filtered by week — the
# default week usually does NOT contain the entry you just submitted). For each
# available week, look for the consultant's card and click its View, then Reject in
# the "Review Timesheet Entry" popup with a comment.
# (The inline btnReject is a dead control — must go through View -> popup.)
tt_hr_reject_first() {
  local who="$1" tab="${2:-MANAGER APPROVAL}" comment="${3:-E2E automated reject for TT-693 testing}"
  tt_click_text "$tab"; sleep 3

  local opened="" labels lbl
  # try the currently-shown week first, then every week in the picker
  if tt_hr_click_view_for "$who"; then
    opened=1
  else
    labels=$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); if(!g) return ''; const s=[...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} \\d{2} - /.test(t)))]; return s.join('|'); }" 2>/dev/null | sed -n '2p')
    labels="${labels%\"}"; labels="${labels#\"}"
    local IFS='|'
    for lbl in $labels; do
      [ -n "$lbl" ] || continue
      playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$lbl')===0); if(el){el.click(); return 'ok';} return 'nf'; }" >/dev/null 2>&1
      sleep 3
      if tt_hr_click_view_for "$who"; then opened=1; echo "  (rejecting in week $lbl)"; break; fi
    done
    unset IFS
  fi
  [ -n "$opened" ] || { echo "  tt_hr_reject_first: no View card for '$who' on tab '$tab' in any week"; return 1; }
  sleep 4

  # In the popup: enter the required comment, then Reject.
  playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); if(!d) return 'nopopup'; const ta=d.querySelector('textarea') || [...d.querySelectorAll('input[type=text]')].pop(); if(ta){ const set=Object.getOwnPropertyDescriptor(ta.__proto__,'value').set; set.call(ta,'$comment'); ta.dispatchEvent(new Event('input',{bubbles:true})); ta.dispatchEvent(new Event('change',{bubbles:true})); return 'typed'; } return 'nofield'; }" >/dev/null 2>&1
  sleep 1
  tt_click_button_exact "reject" popup || { echo "  tt_hr_reject_first: no Reject button in popup"; return 1; }
  sleep 3
  tt_dismiss_dialogs
  return 0
}

# tt_make_rejected_entry <consultant-user> <consultant-display-name> <project>
# Full fixture: consultant submits a week for <project>, HR rejects it, and the
# entry lands back in the consultant's Rejected Entries list.
# Prints the week label used. Idempotent-ish: if the consultant ALREADY has a
# rejected entry it returns immediately (cheap), unless TT_FORCE_NEW_REJECT=1.
#
# EXPORTS TT_REJECTED_WEEK -- the week label this fixture submitted, or '' when it
# reused an entry it did not create and therefore cannot name the week. Callers that
# assert on the consultant's own history need it: the history list is every week the
# consultant has, newest first, so "read some text near the top of the page" reads a
# DIFFERENT week's status and cannot fail. verify-tt692693-c2-zero-hours checked its
# status that way and its slice stopped three rows above the row it had submitted.
tt_make_rejected_entry() {
  local cuser="$1" cname="$2" proj="$3" wk
  export TT_REJECTED_WEEK=""

  if [ "${TT_FORCE_NEW_REJECT:-0}" != "1" ]; then
    tt_login "$cuser" "My Timesheets" >/dev/null 2>&1
    if [ "$(tt_rejected_count)" != "0" ]; then
      echo "(reusing existing rejected entry for $cuser)"
      return 0
    fi
  fi

  # 1) consultant submits the project's row on an EDITABLE week. Project-agnostic:
  #    tt_consultant_submit_project_row only matches Manager/Customer-Approval rows,
  #    so we fill the matching row's day cells directly (5h/day keeps under caps).
  tt_login "$cuser" "My Timesheets" >/dev/null 2>&1
  local ord="" i d
  for i in $(seq 1 16); do
    ord=$(playwright-cli eval "() => { const rows=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')]; for(let n=0;n<rows.length;n++){ let el=rows[n]; for(let k=0;k<10;k++){el=el.parentElement; if(!el)break; if((el.innerText||'').indexOf('$proj')>=0){ const inp=rows[n].querySelector('input'); if(inp && !inp.readOnly && !inp.disabled) return String(n+1); }} } return '0'; }" 2>/dev/null | sed -n '2p' | tr -d '"')
    [ "$ord" != "0" ] && break
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1; sleep 2
  done
  [ "$ord" != "0" ] || { echo "  no editable '$proj' row for $cuser"; return 1; }
  wk="$(tt_week_label)"
  export TT_REJECTED_WEEK="$wk"
  for d in Mon Tues Wed Thurs Fri; do
    tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, ${ord})" "5"
  done
  tt_commit_focused
  sleep 1
  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
  sleep 2
  tt_dismiss_dialogs
  sleep 2
  echo "submitted $proj week $wk as $cuser"

  # 2) HR rejects it — retry with waits: the approval workflow routes the submitted
  #    entry into the manager queue ASYNCHRONOUSLY, so it may not appear immediately.
  #    Success signal = the consultant ends up with a rejected entry.
  local rej=""
  for i in 1 2 3 4 5 6; do
    tt_login "e2e_hr" "WEEKLY TO PROCESS" >/dev/null 2>&1
    tt_hr_reject_first "$cname" "MANAGER APPROVAL" >/dev/null 2>&1
    tt_login "$cuser" "My Timesheets" >/dev/null 2>&1
    [ "$(tt_rejected_count)" != "0" ] && { rej=1; break; }
    sleep 6
  done
  [ -n "$rej" ] || { echo "  HR could not find/reject the submitted '$proj' entry (async routing?)"; return 1; }

  # 3) confirm it came back as Rejected for the consultant
  tt_login "$cuser" "My Timesheets" >/dev/null 2>&1
  [ "$(tt_rejected_count)" != "0" ] || { echo "  entry did not return to Rejected Entries"; return 1; }
  echo "rejected entry ready for $cuser ($proj, $wk)"
  return 0
}

# tt_open_review_edit — from the consultant dashboard, open the Review & Edit popup
# for the first rejected entry. Prefers the semantic widget class (stable), falls
# back to the caption.
tt_open_review_edit() {
  playwright-cli click ".mx-name-btnReviewRejected" >/dev/null 2>&1
  sleep 4
  if [ "$(tt_popup_open)" != "true" ]; then
    tt_click_button_contains "review" page || return 1
    sleep 4
  fi
  [ "$(tt_popup_open)" = "true" ] || return 1
  return 0
}

# tt_popup_day_inputs — JSON {count, values, readonly} for the popup's day boxes.
# Identified positionally: the numeric text inputs on the entry row, excluding the
# Name/Client text fields and the rejection-comment box.
tt_popup_day_inputs() {
  playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); if(!d) return '{}'; const ins=[...d.querySelectorAll('input')].filter(i=>i.type!=='checkbox' && i.offsetParent!==null); const num=ins.filter(i=>/^\s*-?[0-9]*\.?[0-9]*\s*$/.test(i.value||'')); return JSON.stringify({count:num.length, values:num.map(i=>i.value), readonly:num.map(i=>!!(i.readOnly||i.disabled))}); }" 2>/dev/null | sed -n '2p'
}

# ---------------------------------------------------- HR queue inspection (C1-C3)

# TT692693_GAL -- the HR tab's entries gallery. Named once because EVERY read of it
# must be preceded by tt_gallery_load_all; see below.
TT692693_GAL=".mx-name-galTabEntries"

# tt692693_hr_tab_state <label> -- print what the HR tab is actually showing.
#
# Main.DS_EntriesForTab filters the retrieved entries by the tab's OWN dropdowns
# (HRDashboardTab_Account / HRDashboardTab_Project), and Main.DS_WeeksForTab applies
# the same two to the WEEK LIST. So a cbTabWeekConsultant or cbTabWeekProject left
# set by an earlier test does not merely hide cards -- it can empty the week picker
# outright, at which point every "walk the weeks" helper here concludes the entry is
# in no queue at all. Cheap, and it runs on the happy path too: without it, "the
# entry never routed" and "a filter is hiding it" are indistinguishable in the log.
tt692693_hr_tab_state() {
  local label="${1:-tab state}" s
  s="$(playwright-cli eval "() => { const val=n=>{ const w=document.querySelector('.mx-name-'+n); if(!w) return '(absent)'; const i=w.querySelector('input,select'); const v=(i&&i.value)||''; const txt=(w.innerText||'').replace(/\s+/g,' ').trim(); return v || txt || '(empty)'; }; const wk=document.querySelector('.mx-name-galTabAvailableWeeks'); const weeks=wk?[...new Set([...wk.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} /.test(t)))]:[]; return 'consultantFilter=' + val('cbTabWeekConsultant') + ' | projectFilter=' + val('cbTabWeekProject') + ' | weeks(' + weeks.length + ')=' + (weeks.join(', ') || '(none)'); }" 2>/dev/null | sed -n '2p')"
  s="${s%\"}"; s="${s#\"}"
  echo "  [tab] $label: $s" >&2
}

# tt692693_count_cards_here <consultant-display-name>
# Count the cards in the CURRENTLY selected week whose first line is exactly the
# consultant's name, paging the virtual-scrolling gallery in FIRST.
#
# THE SCROLL-AND-COUNT LOOP RUNS INSIDE ONE eval, DELIBERATELY. It used to be a bash
# loop around tt_gallery_load_all, and every iteration of that loop spends a fresh
# playwright-cli process -- ~2.6s of node startup, measured -- on each of its nine
# evals. One week's count therefore cost ~27s of which well under a second was the
# app. tt_hr_count_cards_for calls this once PER WEEK IN THE WEEK PICKER, and C2/C3
# call that twice over, so the paging that went in with efec776 multiplied out to
# ~10 minutes against a 4m default budget: verify-tt692693-c2-zero-hours was killed
# mid-sweep, having printed only the first tab's diagnostic. Identical DOM work, one
# process. Do not unroll this back into bash.
#
# The in-page loop is also MORE patient than the bash one it replaces: three barren
# rounds at 1s each before it calls the list finished, against the old two at 2s, so
# a slow page fetch on a cloud environment gets an extra chance rather than fewer.
tt692693_count_cards_here() {
  local who="$1"
  playwright-cli eval "async () => { const gal=document.querySelector('$TT692693_GAL'); const box=gal&&gal.querySelector('.widget-gallery-content'); const items=()=>gal?gal.querySelectorAll('.widget-gallery-item').length:0; if(box&&box.classList.contains('infinite-loading')){ let stuck=0; for(let r=0;r<40&&stuck<3;r++){ const before=items(); box.scrollTop=box.scrollHeight; box.dispatchEvent(new Event('scroll',{bubbles:true})); await new Promise(res=>setTimeout(res,1000)); stuck = items()===before ? stuck+1 : 0; } } const vs=[...document.querySelectorAll('.mx-name-btnView, button')].filter(b=>/^view/i.test((b.innerText||'').trim())); let m=0; for(const v of vs){ let el=v; for(let k=0;k<14;k++){ el=el.parentElement; if(!el) break; const t=(el.innerText||''); if(/TOTAL HOURS/i.test(t)){ if(t.split('\n')[0].trim()==='$who') m++; break; } } } return String(m); }" 2>/dev/null | sed -n '2p' | tr -d '"'
}

# tt_hr_count_cards_for <consultant-display-name> [tab-caption]
# As HR (already logged in): opens <tab>, scans EVERY week in the picker, and counts
# cards whose FIRST LINE is exactly <consultant-display-name>. Prints the count.
# Used to assert an entry reached a queue (C1/C2) and that it appears ONCE (C3).
#
# EVERY READ OF THE GALLERY GOES THROUGH tt692693_count_cards_here, WHICH PAGES IT IN
# FIRST. Main.SNIP_HRDashboardTab's galTabEntries is virtual-scrolling with pageSize
# 4: it renders four cards and fetches the rest only when its own
# .widget-gallery-content box is scrolled. Reading the DOM without scrolling answers
# "is this consultant in the first four cards", not "is this consultant in this
# week" -- and the two are indistinguishable in the output.
#
# This function's whole job is to let a caller conclude an entry is NOT in a queue,
# which is exactly the conclusion an unpaged read cannot support. It is how
# verify-tt692693-c2-zero-hours reported "not-in-process-queue" against a routing
# chain that is provably correct in the model: Main.SUB_AssignmentEntry_Submit sets
# Status to ToProcess when TotalHours = 0, and Main.AssignmentEntry_Approval's first
# decision (TotalHours = 0) goes straight to the Process task. The tell in that log
# is MANAGER APPROVAL=4 -- exactly the page size. Commit 04e11d7 fixed the identical
# blindness in the tt647_* helpers and added tt_gallery_load_all for it; these
# helpers never adopted it. Do not add a new read of this gallery without it.
tt_hr_count_cards_for() {
  local who="$1" tab="${2:-MANAGER APPROVAL}" labels lbl total=0 n
  tt_click_text "$tab" >/dev/null 2>&1; sleep 3
  tt692693_hr_tab_state "counting '$who' on '$tab'"
  labels=$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); if(!g) return ''; const s=[...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} \d{2} - /.test(t)))]; return s.join('|'); }" 2>/dev/null | sed -n '2p')
  labels="${labels%\"}"; labels="${labels#\"}"
  if [ -z "$labels" ]; then
    # No week picker at all. Count whatever this tab is showing -- but say so, because
    # an empty picker is also what a stuck consultant/project filter looks like.
    echo "  (no week picker on '$tab' -- counting the cards currently shown)" >&2
    tt692693_count_cards_here "$who"
    return 0
  fi
  local IFS='|'
  for lbl in $labels; do
    [ -n "$lbl" ] || continue
    unset IFS
    playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$lbl')===0); if(el){el.click(); return 'ok';} return 'nf'; }" >/dev/null 2>&1
    sleep 3
    n="$(tt692693_count_cards_here "$who")"
    total=$(( total + ${n:-0} ))
    IFS='|'
  done
  unset IFS
  echo "$total"
}

# tt_hr_count_cards_for_week <consultant-display-name> <tab-caption> <week-label>
# As HR (already logged in): open <tab>, select THE ONE WEEK named, and count the
# cards there. Accepts either form of the week label; see tt_week_key.
#
# Prefer this over tt_hr_count_cards_for whenever the caller knows which week it is
# asking about, for two separate reasons.
#
# It is a SHARPER ASSERTION. tt_hr_count_cards_for sums the consultant's cards over
# every week in the picker, so "the entry reached the process queue" was satisfied by
# any card that consultant has in any week -- including the ones earlier tests left
# behind. C2 submits a specific week and asserts about that week's routing; summing
# the others in could only ever mask a failure.
#
# It is also ~9x cheaper, which is what killed C2: one week's paged count instead of
# one per week in the picker. See tt692693_count_cards_here.
#
# An empty count and a week that is not in the picker are DIFFERENT ANSWERS and both
# are reported: Main.DS_WeeksForTab builds the picker from the entries the tab holds,
# so a missing week means no entry of that status -- but it is also what a stuck
# consultant/project filter looks like, and tt692693_hr_tab_state has already printed
# which of the two it is.
tt_hr_count_cards_for_week() {
  local who="$1" tab="$2" week="$3" key sel
  key="$(tt_week_key "$week")"; [ -n "$key" ] || key="$week"
  tt_click_text "$tab" >/dev/null 2>&1; sleep 3
  tt692693_hr_tab_state "counting '$who' on '$tab' for week '$key'"
  sel="$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); if(!g) return 'nopicker'; const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$key')===0); if(!el) return 'absent'; el.click(); return 'ok'; }" 2>/dev/null | sed -n '2p' | tr -d '"')"
  case "$sel" in
    ok)
      sleep 3
      tt692693_count_cards_here "$who"
      ;;
    absent)
      echo "  (week '$key' is not in the '$tab' week picker at all, so no entry of that status exists for it)" >&2
      echo 0
      ;;
    *)
      echo "  (no week picker on '$tab' -- counting the cards currently shown)" >&2
      tt692693_count_cards_here "$who"
      ;;
  esac
}

# tt_week_key <week-label> -- the bare "Mmm DD - Mmm DD" part of a week label.
#
# The consultant grid's own .mx-name-txtWeekRange renders an environment prefix on
# this data set ("E2E Sep 06 - Sep 12"), while the timesheet-history rows and the HR
# week picker both render the range alone ("Sep 06 - Sep 12"). Matching one against
# the other verbatim therefore never hits. Normalise before comparing.
tt_week_key() {
  printf '%s' "$1" | sed -n 's/.*\([A-Z][a-z][a-z] [0-9][0-9] - [A-Z][a-z][a-z] [0-9][0-9]\).*/\1/p'
}

# tt_consultant_history_load -- page the consultant's timesheet-history gallery in
# fully and echo its text (newlines flattened).
#
# galTimesheetHistory is virtual-scrolling like the HR tabs, and it holds EVERY week
# the consultant has, newest first. A week from a few rows down is simply not in the
# DOM until it is scrolled to, so an unpaged read silently answers about whichever
# weeks happen to be on top.
tt_consultant_history_load() {
  tt_gallery_load_all ".mx-name-galTimesheetHistory" "timesheet history" >/dev/null 2>&1 || true
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTimesheetHistory'); return g ? (g.innerText||'').replace(/\n+/g,' | ') : ''; }" 2>/dev/null | sed -n '2p'
}

# tt_consultant_week_status <week-label> -- the consultant's own history row for ONE
# week (status + hours). Accepts either form of the label; see tt_week_key.
# Echoes '' when that week is not in the history at all, which is a distinct answer
# from "it is there with the wrong status" and must be reported as such.
#
# Falls back to the old body-wide slice when the needle is not in the history gallery
# at all, because verify-customer-token-reject passes 'Rejected Entries' -- a heading
# that lives outside it -- and still wants the text that follows.
tt_consultant_week_status() {
  local key; key="$(tt_week_key "$1")"
  [ -n "$key" ] || key="$1"
  tt_gallery_load_all ".mx-name-galTimesheetHistory" "timesheet history" >/dev/null 2>&1 || true
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTimesheetHistory'); if(g){ const hit=[...g.querySelectorAll('.widget-gallery-item')].find(c=>(c.innerText||'').indexOf('$key')>=0); if(hit) return (hit.innerText||'').replace(/\n+/g,' | '); const t=(g.innerText||''); const i=t.indexOf('$key'); if(i>=0) return t.slice(i, i+120).replace(/\n+/g,' | '); } const b=document.body.innerText||''; const j=b.indexOf('$key'); return j<0 ? '' : b.slice(j, j+120).replace(/\n+/g,' | '); }" 2>/dev/null | sed -n '2p'
}

# ------------------------------------------------------- Review & Edit popup edits

# tt_popup_zero_days -- set every editable day box in the Review & Edit popup to 0
# and COMMIT the last one. Echoes how many boxes it touched.
#
# WHY THE EXPLICIT BLUR. A Mendix numeric input commits on blur, not on the input or
# change event, so setting the boxes in a loop commits box N only when box N+1 takes
# focus -- and the LAST box is left holding an uncommitted value. The tell in the C2
# log was the day-input dump reading ["0.00","0.00","0.00","0.00","0.00","0.00","0"]:
# six committed zeroes and one raw one. It did not change that run's outcome (that
# box was already 0.00), but it means the test was not actually proving the week had
# been zeroed, which is the entire premise of the assertion that follows.
tt_popup_zero_days() {
  playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); if(!d) return '0'; const ins=[...d.querySelectorAll('input')].filter(i=>i.offsetParent!==null && !i.readOnly && !i.disabled && /^\s*-?[0-9]*\.?[0-9]*\s*$/.test(i.value||'')); const set=(t,v)=>{ t.focus(); Object.getOwnPropertyDescriptor(t.__proto__,'value').set.call(t,v); t.dispatchEvent(new Event('input',{bubbles:true})); t.dispatchEvent(new Event('change',{bubbles:true})); }; ins.forEach(i=>set(i,'0')); if(ins.length){ ins[ins.length-1].blur(); } return String(ins.length); }" 2>/dev/null | sed -n '2p' | tr -d '"'
}

# tt_popup_days_all_zero -- 'true' when EVERY editable day box in the popup reads as
# a committed zero. A committed Mendix decimal renders '0.00'; a value that was set
# but never blurred is still the raw '0', so requiring the decimal form IS the test.
tt_popup_days_all_zero() {
  playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); if(!d) return 'false'; const ins=[...d.querySelectorAll('input')].filter(i=>i.offsetParent!==null && !i.readOnly && !i.disabled && /^\s*-?[0-9]*\.?[0-9]*\s*$/.test(i.value||'')); if(!ins.length) return 'false'; return String(ins.every(i=>/^0\.0+$/.test((i.value||'').trim()))); }" 2>/dev/null | sed -n '2p' | tr -d '"'
}
