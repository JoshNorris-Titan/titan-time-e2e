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
# A "fresh" week for A1/B1 = one where the project row exists AND every day cell on
# that row is empty (never entered). Steps forward from the current week.
tt_goto_fresh_week() {
  local proj="$1" max="${2:-16}" i
  for i in $(seq 1 "$max"); do
    local rows; rows="$(tt_rows_text)"
    case "$rows" in
      *"$proj"*)
        # all day inputs on the matching row blank?
        local blank
        blank=$(playwright-cli eval "() => { const rows=[...document.querySelectorAll('.mx-name-galAssignmentRows [class*=mx-name-txtDay]')]; if(!rows.length) return 'norows'; const vals=rows.map(i=>(i.querySelector('input')||i).value||''); return String(vals.every(v=>v===''||v==='0'||v==='0.00')); }" 2>/dev/null | sed -n '2p' | tr -d '"')
        if [ "$blank" = "true" ]; then tt_week_label; return 0; fi
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
tt_make_rejected_entry() {
  local cuser="$1" cname="$2" proj="$3" wk

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
  for d in Mon Tues Wed Thurs Fri; do
    playwright-cli fill ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, ${ord})" "5" >/dev/null 2>&1
  done
  playwright-cli click ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDaySat input, ${ord})" >/dev/null 2>&1
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

# tt_hr_count_cards_for <consultant-display-name> [tab-caption]
# As HR (already logged in): opens <tab>, scans EVERY week in the picker, and counts
# cards whose FIRST LINE is exactly <consultant-display-name>. Prints the count.
# Used to assert an entry reached a queue (C1/C2) and that it appears ONCE (C3).
tt_hr_count_cards_for() {
  local who="$1" tab="${2:-MANAGER APPROVAL}" labels lbl total=0 n
  tt_click_text "$tab" >/dev/null 2>&1; sleep 3
  labels=$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); if(!g) return ''; const s=[...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} \d{2} - /.test(t)))]; return s.join('|'); }" 2>/dev/null | sed -n '2p')
  labels="${labels%\"}"; labels="${labels#\"}"
  if [ -z "$labels" ]; then
    playwright-cli eval "() => { const vs=[...document.querySelectorAll('.mx-name-btnView, button')].filter(b=>/^view/i.test((b.innerText||'').trim())); let m=0; for(const v of vs){ let el=v; for(let k=0;k<14;k++){ el=el.parentElement; if(!el) break; const t=(el.innerText||''); if(/TOTAL HOURS/i.test(t)){ if(t.split('\n')[0].trim()==='$who') m++; break; } } } return String(m); }" 2>/dev/null | sed -n '2p' | tr -d '"'
    return 0
  fi
  local IFS='|'
  for lbl in $labels; do
    [ -n "$lbl" ] || continue
    playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$lbl')===0); if(el){el.click(); return 'ok';} return 'nf'; }" >/dev/null 2>&1
    sleep 3
    n=$(playwright-cli eval "() => { const vs=[...document.querySelectorAll('.mx-name-btnView, button')].filter(b=>/^view/i.test((b.innerText||'').trim())); let m=0; for(const v of vs){ let el=v; for(let k=0;k<14;k++){ el=el.parentElement; if(!el) break; const t=(el.innerText||''); if(/TOTAL HOURS/i.test(t)){ if(t.split('\n')[0].trim()==='$who') m++; break; } } } return String(m); }" 2>/dev/null | sed -n '2p' | tr -d '"')
    total=$(( total + ${n:-0} ))
  done
  unset IFS
  echo "$total"
}

# tt_consultant_week_status <week-substring> — the consultant's own history row text
# for a week (status + hours), used to check totals/status shown to the consultant.
tt_consultant_week_status() {
  playwright-cli eval "() => { const b=document.body.innerText||''; const i=b.indexOf('$1'); return i<0?'':b.slice(i, i+120).replace(/\n+/g,' | '); }" 2>/dev/null | sed -n '2p'
}
