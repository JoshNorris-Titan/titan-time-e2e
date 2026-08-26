#!/usr/bin/env bash
# Shared fixtures for TT-683 (group export -> one PDF per consultant/project,
# delivered as a ZIP) and TT-652 (the per-file naming standard).
#
# Source AFTER lib/_login.sh:
#   source "$(dirname "$0")/lib/_login.sh"
#   source "$(dirname "$0")/lib/_tt683.sh"
#
# What is under test:
#   Main.ACT_ExportAll_HRDash calls Main.SUB_BuildMonthHelpers, which buckets the
#   AwaitingExport entries by Main.AssignmentEntry_Assignment and creates ONE
#   Main.PDFMonthHelper per Assignment (an Assignment IS the consultant+project
#   pairing). Main.SUB_BuildTimesheetFileName names each helper
#   {yyyy}-{MMdd of month END}-{Last First}-{Project}.pdf. The green button on
#   Main.ExportAll_Waiting runs Main.ACT_PDF_ExportZip, which generates one PDF
#   per helper and hands back a single .zip via ZipHandling.ZipDocuments.
#
# HOW THESE TESTS VERIFY, AND WHY
#   Neither the helper rows nor the PDF filenames are rendered anywhere in the
#   UI, so a screen-only test would pass without proving either ticket. The
#   obvious alternative -- reading Main.PDFMonthHelper over `mxcli oql` -- only
#   works against a LOCAL F5 run: mxcli talks to the M2EE admin API, and Mendix
#   Cloud does not expose that port. These tests are meant to run on dev
#   alongside the rest of the suite, so they verify the ARTEFACT instead:
#
#     1. patch the browser's download paths to capture the file URL
#     2. click the download button
#     3. fetch() that URL from page JS -- same origin, same session cookie
#     4. assert the ZIP magic number and parse the central directory for the
#        entry names
#
#   That runs identically on localhost, dev and acceptance, and proves the real
#   promise (one correctly-named PDF per consultant/project inside one archive)
#   rather than the intermediate state it is built from.
#
#   ZipHandling.ZipDocuments takes each zip entry's name from the FileDocument's
#   Name attribute, which Main.SUB_PDFGenReturn sets from PDFMonthHelper/FileName
#   via JA_GenerateDocument -- so the entry names ARE the TT-652 filenames.
#
# Env: TT_BASE_URL, TT_ROLE_PASS (see lib/_login.sh). No admin port needed.

# ---------------------------------------------------------------- UI helpers

# tt683_tab_labels — the HR dashboard tab strip, discovered rather than
# hardcoded. The tab strip was not part of the widget-naming pass (see
# lib/_tt647.sh) and the awaiting-export tab's label lives in
# Main.HRDashboardTab/TabLabel as DATA, so it cannot be read out of the model.
tt683_tab_labels() {
  playwright-cli eval "() => { const s=new Set([...document.querySelectorAll('h4,h5,div,span,a,li')].filter(e=>e.childElementCount===0 && getComputedStyle(e).cursor==='pointer').map(e=>(e.innerText||'').trim()).filter(t=>t.length>2 && t.length<40 && t===t.toUpperCase())); return [...s].join('|'); }" 2>/dev/null | sed -n '2p' | sed -e 's/^\"//' -e 's/\"$//'
}

# MATCH THE WIDGET NAME, NOT THE CAPTION. The control on MONTHLY TO BE INVOICED
# is .mx-name-btnExportAll but it READS "Export" - so the old /export\s*all/i test
# against the button caption never matched, tt683_open_export_tab walked every tab
# and gave up, and a1/a2 reported "no HR dashboard tab exposes an 'Export All'
# button" against a dashboard that has one. Widget names are what this suite is
# supposed to select on precisely because captions drift; the caption match stays
# only as a loose fallback.
tt683_has_export_button() {
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnExportAll') || [...document.querySelectorAll('button,a')].some(e=>/^export/i.test((e.innerText||'').trim())))" 2>/dev/null | grep -qiw true
}

# tt683_open_export_tab — log in as HR and land on whichever tab owns the
# "Export All" button. Prints the tab label.
tt683_open_export_tab() {
  local lbl labels
  tt_login "e2e_hr" "WEEKLY TO PROCESS"
  if tt683_has_export_button; then echo "(landing tab)"; return 0; fi
  labels="$(tt683_tab_labels)"
  local IFS='|'
  for lbl in $labels; do
    [ -n "$lbl" ] || continue
    unset IFS
    tt_click_text "$lbl" "HR '$lbl' tab" 2>/dev/null || true
    sleep 2
    if tt683_has_export_button; then echo "$lbl"; return 0; fi
    IFS='|'
  done
  unset IFS
  tt_fail "no HR dashboard tab exposes an 'Export All' button (looked at: $labels)"
}

# tt683_click_export_all — click Export All, wait for Main.ExportAll_Waiting.
tt683_click_export_all() {
  playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnExportAll') || [...document.querySelectorAll('button,a')].find(e=>/^export/i.test((e.innerText||'').trim())); if(b){b.click(); return 'ok';} return 'nf'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok \
    || tt_fail "could not click the 'Export All' button"
  local i
  for i in $(seq 1 30); do
    tt683_popup_open && return 0
    sleep 1
  done
  tt_fail "the 'Exporting Timesheets' popup (Main.ExportAll_Waiting) never appeared after Export All"
}

# THE POPUP IS TITLED "Exporting PDF", NOT "Exporting Timesheets".
# This matched the literal string "Exporting Timesheets" anywhere in the body, so
# it never fired and a1/a2 failed with "the 'Exporting Timesheets' popup
# (Main.ExportAll_Waiting) never appeared" - against a popup that appears within
# three seconds and reads:
#     x  Exporting PDF   Your export is ready.   Download Timesheets (ZIP)
# Keyed on the dialog container plus the download button instead, so a further
# wording change cannot silently break it again.
tt683_popup_open() {
  playwright-cli eval "() => { const vis=[...document.querySelectorAll('$TT_DIALOG_SEL')].filter(d=>d.offsetParent!==null); const hasDlg=vis.some(d=>/exporting/i.test(d.innerText||'')); const hasZip=[...document.querySelectorAll('button')].some(e=>e.offsetParent!==null && /download.*zip|zip\)/i.test((e.innerText||'').trim())); return String(hasDlg || hasZip); }" 2>/dev/null | grep -qiw true
}

# tt683_zip_button_caption — caption of the visible download button in the popup.
# Main.ExportAll_Waiting holds two buttons: actionButton1 is the disabled
# placeholder shown while Date is the 1-1-1970 sentinel, actionButton2 is the
# real one. Only one shows at a time.
tt683_zip_button_caption() {
  local i out
  for i in $(seq 1 30); do
    out=$(playwright-cli eval "() => { const b=[...document.querySelectorAll('button')].filter(e=>e.offsetParent!==null).map(e=>(e.innerText||'').trim()).filter(t=>/zip|timesheet/i.test(t)); return b.join('~~'); }" 2>/dev/null | sed -n '2p' | sed -e 's/^\"//' -e 's/\"$//')
    [ -n "$out" ] && { echo "$out"; return 0; }
    sleep 1
  done
  echo ""
}

# ------------------------------------------------- AwaitingExport preconditions
#
# The export tests need entries in AwaitingExport, and NOTHING else in the suite
# puts them there: the TT-647 scenarios stop at ToProcess and the TT-654 ones
# stop at Awaiting*Approval. The ToProcess -> AwaitingExport hop is HR pressing
# "View & Process" on a To Process card and then "Process" on the page that
# opens (Main.SNIP_HRDashboardTab btnProcess -> Main.NACT_ProcessEntry ->
# Main.AssignmentEntry_Process -> Main.ACT_AssignmentEntry_Process).
#
# verify-tt683-a0 drives these. They are here rather than in the test so a1/a2
# can top up their own preconditions if they are ever run standalone.

TT683_TAB_TOPROCESS="WEEKLY TO PROCESS"


# ---------------------------------------------------------------------------
# Reading the exported archive
#
# WHY THIS IS DONE THROUGH THE NETWORK LOG AND NOT THE DOM.
# Main.ACT_PDF_ExportZip ends in a Download file action with
# showFileInBrowser=false. Mendix 11.12.2 performs that by pointing a hidden
# iframe at /file?guid=..., and because the response is an attachment the browser
# turns the navigation into a DOWNLOAD: the iframe's location never changes, its
# src attribute is never set, and it is discarded immediately afterwards. An
# instrumented run proved it - every hook fired with an empty string:
#     rec() saw: {"patched":true,"hits":3,"last":["","",""]}
# One earlier run did capture the URL by reading contentWindow.location on a
# one-second poll, but that was winning a sub-second race, and refetching the URL
# afterwards returned HTTP 560 because the guid stops resolving once the flow
# closes the form.
#
# The browser makes the request regardless, so the bytes are taken from
# playwright's own network log and read off disk with tools/zipreport.py. No
# race, no second request, and no hand-rolled ZIP parsing in the page.
# ---------------------------------------------------------------------------

# Where the downloaded archive path is parked. Callers invoke these helpers in a
# command substitution, so a shell variable would not survive; a file does.
TT683_ZIP_STATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.tt683-zip.path"
TT683_ZIPREPORT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/zipreport.py"

# _tt683_zip_request_index — index of the /file request in the network log, or "".
_tt683_zip_request_index() {
  playwright-cli requests --static 2>/dev/null \
    | grep -oE '^[0-9]+\. \[[A-Z]+\] [^ ]*/file\?[^ ]*' \
    | tail -1 | cut -d. -f1
}

# tt683_download_zip_entries — click Download, capture the archive, print one
# entry name per line. Leaves the archive path in TT683_ZIP_STATE.
tt683_download_zip_entries() {
  local i idx out path
  rm -f "$TT683_ZIP_STATE"

  playwright-cli eval "() => { const b=[...document.querySelectorAll('button')].filter(e=>e.offsetParent!==null).find(e=>/zip/i.test(e.innerText||'')); if(b){b.click(); return 'ok';} return 'nf'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok \
    || tt_fail "could not click the ZIP download button"

  for i in $(seq 1 25); do
    idx="$(_tt683_zip_request_index)"
    [ -n "$idx" ] && break
    sleep 1
  done
  if [ -z "$idx" ]; then
    TT683_ZIP_ERR="the browser never requested /file? after the download was clicked"
    echo "  zip read failed: $TT683_ZIP_ERR" >&2
    echo "  network log tail: $(playwright-cli requests --static 2>/dev/null | tail -5 | tr '\n' ' ')" >&2
    return 1
  fi

  # A binary body is written to disk and the path printed; a textual one is
  # inlined, which for this request means an error page rather than an archive.
  out="$(playwright-cli response-body "$idx" 2>&1)"
  path="$(printf '%s\n' "$out" | grep -oE '[A-Za-z]:[\/][^ ]*|/[^ ]*\.(zip|bin|dat)' | tail -1)"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    TT683_ZIP_ERR="the /file response was not saved as a binary body (request #$idx)"
    echo "  zip read failed: $TT683_ZIP_ERR" >&2
    echo "  response-body said: $(printf '%s' "$out" | head -3 | tr '\n' ' ')" >&2
    return 1
  fi

  printf '%s\n' "$path" > "$TT683_ZIP_STATE"
  echo "  archive saved: $path ($(wc -c < "$path" | tr -d ' ') bytes)" >&2

  python "$TT683_ZIPREPORT" "$path" names 2>/tmp/ttzip.err || {
    TT683_ZIP_ERR="$(cat /tmp/ttzip.err 2>/dev/null | head -1)"
    echo "  zip read failed: $TT683_ZIP_ERR" >&2
    return 1
  }
}

# _tt683_zip_path — the archive captured by tt683_download_zip_entries.
_tt683_zip_path() {
  [ -f "$TT683_ZIP_STATE" ] || return 1
  local p; p="$(cat "$TT683_ZIP_STATE")"
  [ -n "$p" ] && [ -f "$p" ] || return 1
  printf '%s\n' "$p"
}

# tt683_zip_records — "<name>~~<crc32>~~<bytes>" per entry. Distinct names are not
# distinct documents; the CRC is what settles content identity.
tt683_zip_records() {
  local p; p="$(_tt683_zip_path)" || return 1
  python "$TT683_ZIPREPORT" "$p" records 2>/dev/null
}

# tt683_zip_pdf_report — "<name>~~OK <bytes>" or "<name>~~BAD <reason>", opening
# each entry. Correct names and distinct CRCs would still pass on an archive full
# of error pages, so this checks the bytes really are PDFs.
tt683_zip_pdf_report() {
  local p; p="$(_tt683_zip_path)" || { echo "ERR no archive was captured"; return 1; }
  python "$TT683_ZIPREPORT" "$p" pdf 2>/dev/null
}

# tt683_toprocess_weeks — the week labels offered on the currently-open tab.
tt683_toprocess_weeks() {
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); if(!g) return ''; const s=[...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} \\d{2} - /.test(t)))]; return s.join('|'); }" 2>/dev/null | sed -n '2p' | sed -e 's/^"//' -e 's/"$//'
}

# tt683_open_toprocess_tab — select the To Process tab WITHOUT dying if it is
# not clickable. tt_click_text calls tt_fail (which exits) when it finds nothing,
# so it cannot be used inside the processing loop: after Main.ACT_AssignmentEntry_Process
# closes its page the dashboard may already have that tab active, and an
# "already there" state must not abort the walk. Returns 1 instead.
tt683_open_toprocess_tab() {
  playwright-cli eval "() => { const el=[...document.querySelectorAll('h4,h5,div,span,a,button,li')].find(e => (e.innerText||'').trim()==='$TT683_TAB_TOPROCESS' && getComputedStyle(e).cursor==='pointer'); if(el){ el.click(); return 'ok'; } return 'none'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok || return 1
  sleep 2
}

# tt683_select_week <label> — click a week in the picker of the open tab.
tt683_select_week() {
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); if(!g) return 'nf'; const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$1')===0); if(el){el.click(); return 'ok';} return 'nf'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok
  sleep 4
}

# E2E-ONLY SCOPE. Processing is one-way and verify-tt683-a1 then flips whatever
# it exported to Exported, so this must never touch a consultant the suite does
# not own. Same reasoning as lib/_testdata.sh: on a shared dev environment,
# draining the whole To Process tab would consume other people's timesheets.
# Cards are matched on the consultant name being one of TT683_E2E_CONSULTANTS.
TT683_E2E_CONSULTANTS="${TT_E2E_CONSULTANTS:-E2E Consultant|E2E Consultant Two}"

# _tt683_owned_js — JS boolean expression testing whether card text `t` belongs
# to an e2e consultant. Built from TT683_E2E_CONSULTANTS so the list stays in
# one place.
_tt683_owned_js() {
  local n out="" IFS='|'
  for n in $TT683_E2E_CONSULTANTS; do
    [ -n "$n" ] || continue
    out="$out || t.split('\n')[0].trim()==='$n'"
  done
  unset IFS
  echo "(false${out})"
}

# tt683_process_one — process the first card on the currently-selected week that
# belongs to an e2e consultant. Prints "<consultant>|<project>" for the card it
# processed; returns 1 when the week has no owned, processable card left.
#
# The card's consultant/project text is read BEFORE clicking, because the page
# navigates away and the gallery is re-queried afterwards.
tt683_process_one() {
  local label i owned
  owned="$(_tt683_owned_js)"
  # KEEP WALKING UP. These used to stop at the first ancestor sized 10-400 chars,
  # which on a To Process card is the BUTTON GROUP ("View & Process" / "Reject",
  # ~21 chars) whose first line is a button caption, never a consultant name. So
  # every owned card failed the ownership test and was skipped, and
  # tt683_process_all_toprocess reported "pushed 0 entr(y/ies)" against a tab
  # holding four processable cards - which then sent verify-tt683-a0 down its slow
  # seeding path until it hit the timeout. The equivalent walk in verify-tt654-a3
  # does not break early, which is why that one finds its cards.
  # BOUND THE WALK TO ONE CARD. Requiring the ancestor to carry the PROJECT
  # section makes the walk climb higher than the card header - and nothing stopped
  # it climbing past the card entirely into a container holding SEVERAL cards,
  # whose first line is still an owned consultant. The label was then read from one
  # card while the click landed on another card's button, and the Process page that
  # opened belonged to an entry the seeder was not tracking. An ancestor that holds
  # exactly one Process button is exactly one card. Same guard tt654_row_ordinal
  # uses to stop a row match leaking into its siblings.
  # THE PAIRING IS consultant|project, AND THE PROJECT IS NOT LINE 2.
  # A To Process card reads:
  #     E2E Consultant / Submitted Aug 26 / View & Process / Reject /
  #     PROJECT / E2E Manager Approval / WEEK / ... / TOTAL HOURS / ...
  # so taking the first two lines yielded "E2E Consultant|Submitted Aug 26" for
  # EVERY card. All entries then looked like the same pairing, the distinct-pairing
  # counter never reached TT683_PROCESS_TARGET, and the seeder ground through
  # entries before falling into its slow path and timing out. The project is the
  # line after the PROJECT label.
  #
  # The walk must also keep climbing PAST the first owned ancestor: the card's
  # header block ("E2E Consultant / Submitted ... / View & Process / Reject")
  # already satisfies the name test but stops short of the project, which yielded
  # "E2E Consultant|?" for every card - the same collapse by another route. So the
  # ancestor has to carry the PROJECT section too before it counts as the card.
  label=$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabEntries'); if(!g) return ''; const bs=[...g.querySelectorAll('.mx-name-btnProcess')]; for(const b of bs){ let p=b; for(let k=0;k<10;k++){ if(!p.parentElement) break; p=p.parentElement; const t=(p.innerText||''); if(t.length>10 && t.length<400 && p.querySelectorAll('.mx-name-btnProcess').length === 1 && $owned && t.indexOf('PROJECT')>=0) { const ls=t.split('\n').map(s=>s.trim()).filter(Boolean); const pi=ls.findIndex(x=>x.toUpperCase()==='PROJECT'); return ls[0]+'|'+((pi>=0 && ls[pi+1]) ? ls[pi+1] : '?'); } } } return ''; }" 2>/dev/null | sed -n '2p' | sed -e 's/^"//' -e 's/"$//')
  [ -n "$label" ] || return 1

  playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabEntries'); if(!g) return 'nf'; const bs=[...g.querySelectorAll('.mx-name-btnProcess')]; for(const b of bs){ let p=b; for(let k=0;k<10;k++){ if(!p.parentElement) break; p=p.parentElement; const t=(p.innerText||''); if(t.length>10 && t.length<400 && p.querySelectorAll('.mx-name-btnProcess').length === 1 && $owned && t.indexOf('PROJECT')>=0){ b.click(); return 'ok'; } } } return 'nf'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok || return 1
  sleep 4

  # Main.AssignmentEntry_Process opens with a footer 'Process' button. Its widget
  # name is generated (actionButton3), so match the caption instead.
  local clicked=""
  # The Process page can take a while to render on cloud dev; 8 x 2s was not
  # always enough and the seeder then reported "no Process button" on a page that
  # simply had not painted yet. Also accept a caption that merely STARTS with
  # "Process" rather than equalling it exactly.
  for i in $(seq 1 20); do
    if playwright-cli eval "() => { const b=[...document.querySelectorAll('button')].filter(e=>e.offsetParent!==null).find(e=>/^process/i.test((e.innerText||'').trim())); if(b){b.click(); return 'ok';} return 'nf'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok; then
      clicked=1; break
    fi
    sleep 2
  done
  [ -n "$clicked" ] || { echo "  (no 'Process' button on the Process Consultant Timesheet page for $label)" >&2; return 1; }
  sleep 4

  # ACT_AssignmentEntry_Process ends by completing the workflow task; clear any
  # confirmation it leaves behind so the next card is reachable.
  playwright-cli eval "() => { const d=document.querySelector('.mx-dialog,.mx-window,[role=dialog],[class*=modal]'); if(!d) return 'none'; const b=[...d.querySelectorAll('button')].find(x=>/^(ok|close|yes|confirm)$/i.test((x.innerText||'').trim())); if(b){b.click(); return 'clicked';} return 'stuck'; }" >/dev/null 2>&1
  sleep 2
  echo "$label"
  return 0
}

# tt683_process_all_toprocess [max]
# As HR: walk the To Process tab and process owned cards, stopping as soon as
# TT683_PROCESS_TARGET distinct consultant/project pairings have been pushed to
# AwaitingExport (or <max> entries have been processed). Prints one
# "<consultant>|<project>" line per entry actually processed.
#
# The stop condition is DISTINCT PAIRINGS, not a raw count, because that is what
# the export tests actually need: two pairings prove the split, and a third is
# margin. The first version drained up to 12 entries at roughly 20-25s each and
# blew verify-tt683-a0's 8-minute cap without ever reaching its assertions —
# processing more than the tests need is pure wall-clock.
# 2, not 3: two distinct pairings is exactly what verify-tt683-a1 needs to prove
# the split, and each processed entry costs ~20-25s (open tab, pick week, open
# the Process page, submit, return). At 3 the seeder overran the per-script
# timeout and a1/a2 were left with no AwaitingExport data at all — so TT-683
# went unverified. Raise this only if a1 starts reporting a single pairing.
TT683_PROCESS_TARGET="${TT683_PROCESS_TARGET:-2}"

tt683_process_all_toprocess() {
  local max="${1:-6}" done_=0 lbl labels one seen="" uniq=0
  tt_login "e2e_hr" "$TT683_TAB_TOPROCESS"
  tt_click_text "$TT683_TAB_TOPROCESS" "HR To Process tab"
  tt_wait_for ".mx-name-galTabAvailableWeeks" "To Process available-weeks list"

  labels="$(tt683_toprocess_weeks)"
  [ -n "$labels" ] || return 0

  local IFS='|'
  for lbl in $labels; do
    [ -n "$lbl" ] || continue
    unset IFS
    tt683_select_week "$lbl" || { IFS='|'; continue; }
    # Each processed card leaves the tab, so re-read the first card each time
    # rather than indexing — the gallery re-renders under us.
    while [ "$done_" -lt "$max" ] && [ "$uniq" -lt "$TT683_PROCESS_TARGET" ]; do
      one="$(tt683_process_one)" || break
      done_=$((done_ + 1))
      echo "$one"
      case "$seen" in
        *"[$one]"*) : ;;
        *) seen="$seen[$one]"; uniq=$((uniq + 1)) ;;
      esac
      # Processing navigates away and drops the week selection, so re-open the
      # tab and re-pick the week before looking for the next card.
      tt683_open_toprocess_tab >/dev/null 2>&1 || true
      tt683_select_week "$lbl" || break
    done
    { [ "$done_" -ge "$max" ] || [ "$uniq" -ge "$TT683_PROCESS_TARGET" ]; } && break
    IFS='|'
  done
  unset IFS
  return 0
}

# ------------------------------------------------------------------ asserts

# tt683_is_month_end <yyyy> <mm> <dd> — 0 when the date is the last day of its
# month. TT-652's highest-risk detail: Main.MonthlyHelper/MonthEnd is an
# UNLOCALIZED DateTime, so SUB_BuildTimesheetFileName must format it with
# formatDateTimeUTC. Plain formatDateTime renders in the session timezone and
# drags a June month-end back to 0629 in America/Chicago.
tt683_is_month_end() {
  local y="$1" m="$2" d="$3" nextmonth
  nextmonth=$(date -d "${y}-${m}-${d} +1 day" +%m 2>/dev/null) || return 2
  [ "$nextmonth" != "$m" ]
}
