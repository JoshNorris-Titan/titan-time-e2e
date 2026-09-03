#!/usr/bin/env bash
# Seed ~N AssignmentEntries into ToProcess so they appear on the HR dashboard's
# "WEEKLY TO PROCESS" tab.
#
# NOT named *.test.sh on purpose: this is a destructive data seeder, not a test,
# and must never be picked up by a `mxcli playwright verify tests/` sweep.
#
# Path per entry (the real one, not the zero-hour shortcut):
#   consultant fills a week's assignment row -> Save Draft -> Submit
#     -> Awaiting{Manager,Customer}Approval
#     -> HR approves on the MANAGER/CLIENT APPROVAL tab
#     -> ToProcess  ==> visible on WEEKLY TO PROCESS
#
# WHY NOT ZERO-HOUR ENTRIES. Main's status expression routes TotalHours = 0
# straight to ToProcess with no approval step, which would be far faster but
# every card would read "No approval required" and 0.00 hours. These are meant to
# look like real processed timesheets, so hours are always non-zero and the entry
# genuinely walks the approval chain.
#
# WEEKLY HOURS CAP. Main.Consultant_OverWeeklyHours is a BLOCKING dialog whose
# only button is Close -- clicking it CANCELS the submit (see tt_clear_dialogs in
# lib/_login.sh). The assignments are budgeted 40 weekly, and a submit covers
# EVERY row on the week at once, so per-row hours are scaled down by row count to
# keep the week total comfortably under 40. If a week is blocked anyway the week
# is retried once at 1h/day before being given up on.
#
# Env:
#   TT_BASE_URL     app origin  (default http://localhost:8080)
#   TT_ROLE_PASS    e2e account password (default E2ETest123!)
#   SEED_TARGET     how many entries to create (default 50)
#   SEED_START_WEEK week caption fragment to start submitting from (default "Sep 27")
#   SEED_MAX_WEEKS  safety cap on weeks walked per consultant (default 14)
#   SEED_SKIP_SUBMIT / SEED_SKIP_APPROVE   set to 1 to run only one half
set -uo pipefail
cd "$(dirname "$0")/../.."   # seeders/ -> tests/ -> project root
source tests/lib/_login.sh

TARGET="${SEED_TARGET:-50}"
START_WEEK="${SEED_START_WEEK:-Sep 27}"
MAX_WEEKS="${SEED_MAX_WEEKS:-14}"

# Densest consultant first so the target is reached in the fewest weeks, but each
# one is quota'd so entries stay spread across consultants AND weeks rather than
# piling 4-a-week onto one name.
# Which consultants SUBMIT this run (override to run one at a time in short
# chunks -- long unattended runs on this host die to Git-Bash fork exhaustion,
# since every UI interaction spawns a playwright-cli process).
CONSULTANTS="${SEED_CONSULTANTS:-e2e_consultant3|e2e_consultant2|e2e_consultant}"

# NAMES stays the FULL list regardless of who is submitting: the approve sweep
# and the ToProcess count must still recognise (and pick up stragglers from)
# every e2e consultant, while never matching anyone else's cards.
NAMES="E2E Consultant Three|E2E Consultant Two|E2E Consultant"

CREATED=0
declare -a SUBMITTED_WEEKS=()

# Progress goes to STDERR, always. hr_approve_round and count_toprocess return
# their result on stdout via $(...), so a log line on stdout would be captured as
# part of the number and every arithmetic test downstream would break.
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# pw <js> — the eval RESULT only.
#
# THE BUG THIS EXISTS TO KILL. playwright-cli echoes the JS SOURCE back on stdout
# under "### Ran Playwright code". The suite-wide idiom
#     playwright-cli eval "() => { ...; return 'ok'; }" | grep -qiw ok
# therefore matches the literal `return 'ok'` INSIDE THE SNIPPET and reports
# success no matter what the snippet actually returned. The first version of this
# seeder's approve loop ran its full 12-iteration guard on every week and logged
# "approved 12" while approving nothing. The result is always line 2 -- parse it.
pw() { playwright-cli eval "$1" 2>/dev/null | sed -n '2p' | sed -e 's/^"//' -e 's/"$//'; }

# click_text_soft — tt_click_text calls tt_fail, which EXITS. That is right for a
# test and wrong for a long seeder: one unclickable tab must not throw away an
# hour of submitted work. Returns 1 instead.
click_text_soft() {
  [ "$(pw "() => { const el=[...document.querySelectorAll('h4,h5,div,span,a,button,li')].find(e => (e.innerText||'').trim()==='$1' && getComputedStyle(e).cursor==='pointer'); if (el) { el.click(); return 'Y'; } return 'N'; }")" = "Y" ] || return 1
  sleep 2
}

# ---------------------------------------------------------------- consultant side

# week_caption — the current week caption, e.g. "E2E Sep 27 - Oct 03".
week_caption() {
  playwright-cli eval "() => String((document.querySelector('.mx-name-txtWeekRange')||{}).innerText||'').trim()" 2>/dev/null | sed -n '2p' | tr -d '"'
}

# open_row_ordinals — 1-based ordinals (into the full txtDayMon list) of rows that
# are editable on this week. Locked rows still render an input, so the ordinal has
# to count every row, not just the open ones -- that is what :nth-match indexes.
open_row_ordinals() {
  playwright-cli eval "() => { const m=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')]; const out=[]; for(let n=0;n<m.length;n++){ const i=m[n].querySelector('input'); if(i && !i.disabled && !i.readOnly) out.push(n+1); } return out.join(','); }" 2>/dev/null | sed -n '2p' | tr -d '"'
}

has_submit() {
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnSubmit'))" 2>/dev/null | grep -qiw true
}

# force_clear_dialogs — clear popups and SAY whether any remain.
#
# tt_clear_dialogs (lib/_login.sh) returns 0 both when everything is clear AND
# when it exhausts its loop with a dialog still up:
#     for i in $(seq 1 "$max"); do ... done
#     return 0          # <- dialog may still be open
# That false "all clear" is what stranded the 2-row weeks below.
force_clear_dialogs() {
  local i
  for i in 1 2 3; do
    tt_clear_dialogs 8 >/dev/null 2>&1 || true
    [ "$(pw "() => { const vis=[...document.querySelectorAll('.mx-window-content,.mx-dialog-content,.modal-content,[role=dialog]')].filter(d=>d.offsetParent!==null); return String(vis.length===0); }")" = "true" ] && return 0
    sleep 2
  done
  return 1
}

# advance_week — click "next week" and CONFIRM the caption actually changed.
#
# A blind `click btnWeekNext; sleep 2` silently does nothing when a leftover
# modal is swallowing clicks, and the caller then re-reads the same week forever.
# That burned ~16 no-op iterations per consultant on the 2-row weeks and cost
# this run roughly 25 entries. Clear first, click, verify, retry.
advance_week() {
  local before after i j
  before="$(week_caption)"
  for i in 1 2 3; do
    force_clear_dialogs || true
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    # POLL for the caption to change; do NOT click again just because the page is
    # slow. The first version re-clicked every 3s, so a lagging render advanced
    # TWO weeks per call -- it walked from Aug 2026 to Apr 2027 in 16 calls and
    # skipped every usable week on the way.
    for j in 1 2 3 4 5 6; do
      sleep 2
      after="$(week_caption)"
      [ -n "$after" ] && [ "$after" != "$before" ] && return 0
    done
  done
  return 1
}

# fill_rows <hours> <ord,ord,...> — Mon-Fri on each listed row.
# Mendix decimal inputs only commit on a real focus change, hence the two extra
# clicks inside the same row after filling it.
fill_rows() {
  local hrs="$1" ords="$2" ord d
  local OLD="$IFS"; IFS=','
  for ord in $ords; do
    IFS="$OLD"
    for d in Mon Tues Wed Thurs Fri; do
      tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, ${ord})" "$hrs"
    done
    tt_commit_focused
    IFS=','
  done
  IFS="$OLD"
  sleep 1
}

# hours_persisted <ord,ord,...> — 0 only if EVERY listed row shows non-zero Monday
# hours after the draft save. A row that silently kept 0.00 would submit as a
# zero-hour entry, skip approval entirely and land on the tab reading
# "No approval required" -- exactly the junk this seeder is meant to avoid.
hours_persisted() {
  local ords="$1" ord v
  local OLD="$IFS"; IFS=','
  for ord in $ords; do
    IFS="$OLD"
    v=$(playwright-cli eval "() => String((document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon input')[$ord - 1]||{}).value||'')" 2>/dev/null | sed -n '2p' | tr -d '"')
    case "$v" in ""|0|0.0|0.00) return 1 ;; esac
    IFS=','
  done
  IFS="$OLD"
  return 0
}

# submit_week <hours> <ords> — draft, verify, submit, clear the confirm chain.
# Returns 0 on a committed submit, 1 if a dialog blocked it, 2 if hours vanished.
submit_week() {
  local hrs="$1" ords="$2"
  fill_rows "$hrs" "$ords"

  if playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnSaveDraft'))" 2>/dev/null | grep -qiw true; then
    playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
    sleep 3
    tt_clear_dialogs 4 >/dev/null 2>&1 || true
  fi
  hours_persisted "$ords" || return 2

  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
  sleep 2
  if ! tt_clear_dialogs 8; then
    log "    submit blocked: $TT_DIALOG_BLOCKED"
    return 1
  fi
  # tt_clear_dialogs can report success with a popup still up; make sure the page
  # is really interactive again before the caller tries to change week.
  force_clear_dialogs || log "    (a dialog is STILL open after submit)"
  sleep 2
  return 0
}

# seed_consultant <user> <quota> — walk forward to START_WEEK, then submit whole
# weeks until <quota> entries have been created or the weeks run out.
seed_consultant() {
  local user="$1" quota="$2" made=0 i wk ords n hrs rc

  log "  --- $user (quota $quota) ---"
  tt_login "$user" "My Timesheets"

  # advance to the common start week
  for i in $(seq 1 "$MAX_WEEKS"); do
    wk="$(week_caption)"
    case "$wk" in *"$START_WEEK"*) break ;; esac
    advance_week || break
  done
  case "$(week_caption)" in
    *"$START_WEEK"*) : ;;
    *) log "    !! never reached a week matching '$START_WEEK' (now: $(week_caption))" ;;
  esac

  for i in $(seq 1 "$MAX_WEEKS"); do
    [ "$made" -ge "$quota" ] && break
    [ "$CREATED" -ge "$TARGET" ] && break

    wk="$(week_caption)"
    ords="$(open_row_ordinals)"
    if [ -z "$ords" ] || ! has_submit; then
      log "    $wk: no open rows / no Submit - skipping"
      advance_week || { log "    !! cannot leave '$wk' - stopping this consultant"; break; }
      continue
    fi
    n=$(printf '%s' "$ords" | tr ',' '\n' | grep -c .)

    # Aim for EXACTLY 40h across the week wherever the row count divides into it.
    #
    # Not cosmetic. The assignments are budgeted 40 weekly, and a submit covers
    # every row at once, so the total must not exceed 40 (over-budget raises a
    # Close-only dialog that CANCELS the submit). But coming in UNDER 40 raises
    # the "fewer than 40 hours - Submit Anyway" warning, and that extra dialog is
    # what exhausted tt_clear_dialogs and stranded every 2-row week at 3h/day.
    # 4 rows x 2h x 5d = 40 submitted cleanly all run; match that exactly.
    if   [ "$n" -ge 4 ]; then hrs=2   # 40h
    elif [ "$n" -eq 3 ]; then hrs=2   # 30h - no integer hits 40; relies on force_clear_dialogs
    elif [ "$n" -eq 2 ]; then hrs=4   # 40h
    else                      hrs=8   # 40h
    fi

    submit_week "$hrs" "$ords"; rc=$?
    if [ "$rc" -eq 1 ]; then
      log "    $wk: retrying at 1h/day after a blocking dialog"
      submit_week 1 "$ords"; rc=$?
    fi

    case "$rc" in
      0)
        made=$((made + n)); CREATED=$((CREATED + n))
        SUBMITTED_WEEKS+=("$wk")
        log "    $wk: submitted $n row(s) @ ${hrs}h/day  [consultant $made/$quota, total $CREATED/$TARGET]"
        ;;
      2) log "    $wk: hours did not persist - skipped (would have been a zero-hour entry)" ;;
      *) log "    $wk: submit failed - skipped" ;;
    esac

    advance_week || { log "    !! cannot leave '$wk' after submit - stopping this consultant"; break; }
  done
  log "  --- $user done: $made entr(ies) ---"
}

# ---------------------------------------------------------------------- HR side

TABS="MANAGER APPROVAL|CLIENT APPROVAL"

# owned_js — JS boolean over card text `t`, true when the card's first line is one
# of our three consultants. Exact first-line equality, because "E2E Consultant" is
# a prefix of "E2E Consultant Two"/"Three".
#
# STRICTNESS IS NOT COSMETIC HERE. These approval tabs carry other people's live
# dev data (rishika / HelloTest / TT-697test were sitting on them during this
# work). Approving someone else's timesheet is not an undo-able mistake, so a
# card that cannot be positively attributed to an e2e consultant is skipped.
owned_js() {
  local n out="" OLD="$IFS"; IFS='|'
  for n in $NAMES; do
    [ -n "$n" ] || continue
    out="$out || f==='$n'"
  done
  IFS="$OLD"
  echo "(false${out})"
}

# _card_js — climb from a button to the CARD element.
#
# The first version stopped at "the first ancestor whose text is 10..400 chars",
# which is the button group ("View & Process / Reject"), not the card -- so the
# owned test ran against the wrong first line and matched nothing. Climb until a
# level's FIRST LINE is one of our consultants instead; that is unambiguous and
# is the same first-line rule lib/_tt692693.sh uses.
_card_js() {
  local owned; owned="$(owned_js)"
  printf "%s" "(b => { let p=b; for(let i=0;i<12;i++){ if(!p.parentElement) break; p=p.parentElement; const t=(p.innerText||'').trim(); if(!t) continue; const f=t.split('\n')[0].trim(); if($owned) return p; } return null; })"
}

# kpi <cardKpiXxx> — the count shown on a dashboard KPI card, e.g.
# kpi cardKpiProcess -> the WEEKLY TO PROCESS total. Cheap (no week walking) and
# it is the number a human reads off the dashboard, so it makes a good headline
# progress signal. Counts EVERY consultant, not just ours.
kpi() {
  local v
  v="$(pw "() => { const c=document.querySelector('.mx-name-$1'); if(!c) return 'NA'; const m=(c.innerText||'').trim().match(/(\d+)\s*$/); return m ? m[1] : 'NA'; }")"
  case "$v" in ''|*[!0-9]*) echo "?" ;; *) echo "$v" ;; esac
}

tab_weeks() {
  pw "() => { const g=document.querySelector('$TT_HR_GAL_WEEKS'); if(!g) return ''; const s=[...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} \\d{2} - /.test(t)))]; return s.join('|'); }"
}

# wait_entries — block until the entries gallery has actually re-rendered.
#
# THE RACE THAT MADE A WHOLE SWEEP REPORT ZERO. The HR dashboard renders only the
# ACTIVE tab, so switching tab or week tears the gallery out of the DOM and
# rebuilds it. A fixed `sleep 3` sometimes read the gap: querySelector returned
# null, owned_approvable coerced that to 0, and the sweep concluded there was
# nothing to approve on a week that had four cards on it.
wait_entries() {
  local i
  for i in $(seq 1 15); do
    [ "$(pw "() => { const g=document.querySelector('$TT_HR_GAL_ENTRIES'); return String(!!g && (g.innerText||'').trim().length > 10); }")" = "true" ] && return 0
    sleep 2
  done
  return 1
}

# wait_sel <css> [tries] — NON-FATAL wait.
#
# tt_wait_for calls tt_fail, which exits. Inside a $(...) that only kills the
# subshell, so the caller silently captures the string "FAIL: timed out ..."
# and carries on using it as a number; in the main flow it would abort a
# 45-minute run over one slow render. Everything here polls instead.
wait_sel() {
  local sel="$1" tries="${2:-15}" i
  for i in $(seq 1 "$tries"); do
    [ "$(pw "() => String(!!document.querySelector('$sel'))")" = "true" ] && return 0
    sleep 2
  done
  return 1
}

select_week() {
  [ "$(pw "() => { const g=document.querySelector('$TT_HR_GAL_WEEKS'); if(!g) return 'N'; const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$1')===0); if(el){el.click(); return 'Y';} return 'N'; }")" = "Y" ] || return 1
  sleep 2
  wait_entries || true
}

# approve_owned_on_week — approve every owned card on the current view, ONE AT A
# TIME, confirming each one actually left before touching the next.
#
# The confirm-then-continue shape matters: the previous version fired clicks on a
# timer and counted them as approvals, so a click that did nothing was
# indistinguishable from a real approval. Here each card is identified by its
# project line, clicked, and then polled until that project no longer appears in
# the gallery. A card that will not leave is reported and skipped rather than
# clicked forever.
# owned_approvable — how many cards on this view are BOTH owned and still have an
# Approve control. This count, not any text match, is the progress signal.
# Distinguishes "gallery missing" from "gallery has no owned cards" and retries
# the former once. Collapsing the two is what let the mid-render gap masquerade
# as an empty week.
owned_approvable() {
  local c try
  for try in 1 2; do
    c="$(pw "() => { const card=$(_card_js); const g=document.querySelector('$TT_HR_GAL_ENTRIES'); if(!g) return 'NOGAL'; let n=0; for(const b of [...g.querySelectorAll('$TT_HR_BTN_APPROVE')]){ if(card(b)) n++; } return String(n); }")"
    case "$c" in
      NOGAL|'') wait_entries || true ;;
      *[!0-9]*) wait_entries || true ;;
      *) echo "$c"; return 0 ;;
    esac
  done
  echo 0
}

# confirm_approve — click "Approve" in the confirmation dialog that the inline
# Approve control raises.
#
# THE REASON NOTHING WAS EVER APPROVED. The inline btnApprove opens
#   "This will bypass the standard approval process, do you wish to approve
#    anyway?"   [ x | Approve | Cancel ]
# and tt_clear_dialogs (lib/_login.sh) only clicks
# yes|submit anyway|confirm|continue|proceed|ok -- "Approve" is not in that set.
# So the dialog stayed up, the approval never committed, AND the open dialog
# swallowed every later click, which is why a whole sweep could report progress
# and change nothing.
#
# Matches "Approve" EXACTLY: never the x and never Cancel, both of which abandon
# the approval (the same trap lib/_login.sh documents for the submit chain).
confirm_approve() {
  local i
  for i in 1 2 3 4 5 6; do
    case "$(pw "() => { const vis=[...document.querySelectorAll('.mx-window-content,.mx-dialog-content,.modal-content,[role=dialog]')].filter(d=>d.offsetParent!==null); if(!vis.length) return 'NONE'; const outer=vis.filter(d=>!vis.some(o=>o!==d && o.contains(d))); const d=outer[outer.length-1]; const b=[...d.querySelectorAll('button')].filter(x=>x.offsetParent!==null).find(x=>/^approve$/i.test((x.innerText||'').trim())); if(b){ b.click(); return 'OKD'; } return 'OTHER'; }")" in
      NONE)  return 0 ;;
      OKD)   sleep 2 ;;
      OTHER) tt_clear_dialogs 4 >/dev/null 2>&1 || true; return 0 ;;
    esac
  done
  return 0
}

approve_owned_on_week() {
  local n=0 before after i
  while [ "$n" -lt 25 ]; do
    before="$(owned_approvable)"
    [ "$before" = "0" ] && break

    if [ "$(pw "() => { const card=$(_card_js); const g=document.querySelector('$TT_HR_GAL_ENTRIES'); if(!g) return 'N'; for(const b of [...g.querySelectorAll('$TT_HR_BTN_APPROVE')]){ const c=card(b); if(c){ b.click(); return 'Y'; } } return 'N'; }")" != "Y" ]; then
      break
    fi
    sleep 2
    confirm_approve
    sleep 2
    tt_clear_dialogs 6 >/dev/null 2>&1 || true

    # Require the owned-approvable COUNT to drop.
    #
    # The previous version identified the card by its project line and waited for
    # that text to vanish -- but when the line could not be parsed it fell back to
    # the literal 'CARD', and "is 'CARD' still in the gallery?" is false
    # immediately, so a click that did nothing was logged as an approval. A
    # decreasing count cannot be faked that way and needs no text parsing at all.
    after="$before"
    for i in $(seq 1 10); do
      after="$(owned_approvable)"
      [ "$after" -lt "$before" ] && break
      tt_clear_dialogs 3 >/dev/null 2>&1 || true
      sleep 2
    done

    if [ "$after" -lt "$before" ]; then
      n=$((n + 1))
      log "        approved ($before -> $after remaining)"
    else
      log "        !! a card did not leave the tab after Approve ($before still owned+approvable) - moving on"
      break
    fi
  done
  echo "$n"
}

# hr_approve_round — one sweep of both approval tabs across every offered week.
# Prints the number approved. Dual-stage projects need a SECOND round: a
# manager-stage approval moves the entry to the client tab, which this sweep may
# already have walked past.
hr_approve_round() {
  local total=0 tab weeks w got OLD
  tt_login "e2e_hr" "WEEKLY TO PROCESS" >&2

  OLD="$IFS"; IFS='|'
  for tab in $TABS; do
    IFS="$OLD"
    click_text_soft "$tab" || { log "    $tab: tab not clickable - skipped"; IFS='|'; continue; }
    sleep 2
    wait_sel "$TT_HR_GAL_WEEKS" 12 || { log "    $tab: no weeks list rendered - skipped"; IFS='|'; continue; }
    weeks="$(tab_weeks)"
    log "    $tab: weeks [$weeks]"
    local IFS2='|'
    local OLD2="$IFS"; IFS='|'
    for w in $weeks; do
      IFS="$OLD2"
      [ -n "$w" ] || continue
      select_week "$w" || { IFS='|'; continue; }
      got="$(approve_owned_on_week)"
      [ "$got" != "0" ] && log "      $w -> approved $got"
      total=$((total + got))
      IFS='|'
    done
    IFS="$OLD2"
    IFS='|'
  done
  IFS="$OLD"
  echo "$total"
}

# count_toprocess — owned cards sitting on WEEKLY TO PROCESS, across all weeks.
# This is the acceptance measure, so it counts CARDS on the tab rather than
# trusting the submit/approve tallies.
count_toprocess() {
  local weeks w total=0 n OLD
  tt_login "e2e_hr" "WEEKLY TO PROCESS" >&2
  wait_sel ".mx-name-cardKpiProcess" 10 || true
  log "    KPIs: pending=$(kpi cardKpiPending) manager=$(kpi cardKpiManager) client=$(kpi cardKpiCustomer) toprocess=$(kpi cardKpiProcess) invoice=$(kpi cardKpiInvoice) sent=$(kpi cardKpiSent)"
  click_text_soft "WEEKLY TO PROCESS" || true
  sleep 2
  wait_sel "$TT_HR_GAL_WEEKS" 12 || { log "    (no To Process weeks list rendered)"; echo 0; return 0; }
  weeks="$(tab_weeks)"
  OLD="$IFS"; IFS='|'
  for w in $weeks; do
    IFS="$OLD"
    [ -n "$w" ] || continue
    select_week "$w" || { IFS='|'; continue; }
    n="$(pw "() => { const card=$(_card_js); const g=document.querySelector('$TT_HR_GAL_ENTRIES'); if(!g) return '0'; let c=0; for(const b of [...g.querySelectorAll('$TT_HR_BTN_PROCESS')]){ if(card(b)) c++; } return String(c); }")"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" != "0" ] && log "    $w -> $n"
    total=$((total + n))
    IFS='|'
  done
  IFS="$OLD"
  echo "$total"
}

# ------------------------------------------------------------------------ main

log "target: $TARGET entries into ToProcess on $TT_BASE (start week '$START_WEEK')"

# Walking every week to count owned cards costs ~2 minutes once the tab is full.
# Skip it on submit-only chunks, where the number is not needed.
if [ "${SEED_SKIP_COUNT:-0}" = "1" ]; then
  BEFORE_TP="(not counted)"
else
  BEFORE_TP="$(count_toprocess)"
fi
log "ToProcess already holding: ${BEFORE_TP:-0} owned card(s)"

# Submit and approve are INTERLEAVED per consultant, not run as two big phases.
# A client-approval entry does not sit on the CLIENT APPROVAL tab indefinitely --
# during the first run of this seeder three entries left that tab within ~10
# minutes of being submitted and turned up on SENT, where the only controls are
# View and Reject and HR can no longer approve them at all. Approving each
# consultant's batch straight after it is submitted keeps that window small.
if [ "${SEED_SKIP_SUBMIT:-0}" != "1" ]; then
  IDX=0
  NCONS=$(printf '%s' "$CONSULTANTS" | tr '|' '\n' | grep -c .)
  OLD="$IFS"; IFS='|'
  for U in $CONSULTANTS; do
    IFS="$OLD"
    [ "$CREATED" -ge "$TARGET" ] && break
    REMAIN=$((TARGET - CREATED))
    LEFT=$((NCONS - IDX))
    QUOTA=$(( (REMAIN + LEFT - 1) / LEFT ))

    log "SUBMIT $U"
    seed_consultant "$U" "$QUOTA"

    if [ "${SEED_SKIP_APPROVE:-0}" != "1" ]; then
      log "APPROVE after $U"
      for ROUND in 1 2; do
        GOT="$(hr_approve_round)"
        log "  round $ROUND approved $GOT"
        [ "$GOT" = "0" ] && break
      done
    fi

    IDX=$((IDX + 1))
    IFS='|'
  done
  IFS="$OLD"
  log "submitted $CREATED entr(ies) in total"
fi

# Final sweep: dual-stage entries move manager -> client between rounds, and a
# sweep may have walked past the client tab before they landed on it.
if [ "${SEED_SKIP_APPROVE:-0}" != "1" ]; then
  log "final approve sweep"
  for ROUND in 1 2 3; do
    GOT="$(hr_approve_round)"
    log "  round $ROUND approved $GOT"
    [ "$GOT" = "0" ] && break
  done
fi

if [ "${SEED_SKIP_COUNT:-0}" = "1" ]; then
  log "skipping final count (SEED_SKIP_COUNT=1)"
  exit 0
fi

log "verify"
FINAL="$(count_toprocess)"
log "WEEKLY TO PROCESS now holds $FINAL owned card(s) (was ${BEFORE_TP:-0}, submitted $CREATED)"
