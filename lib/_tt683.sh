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

tt683_has_export_button() {
  playwright-cli eval "() => String([...document.querySelectorAll('button,a')].some(e=>/export\\s*all/i.test((e.innerText||'').trim())))" 2>/dev/null | grep -qiw true
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
  playwright-cli eval "() => { const b=[...document.querySelectorAll('button,a')].find(e=>/export\\s*all/i.test((e.innerText||'').trim())); if(b){b.click(); return 'ok';} return 'nf'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok \
    || tt_fail "could not click the 'Export All' button"
  local i
  for i in $(seq 1 30); do
    tt683_popup_open && return 0
    sleep 1
  done
  tt_fail "the 'Exporting Timesheets' popup (Main.ExportAll_Waiting) never appeared after Export All"
}

tt683_popup_open() {
  playwright-cli eval "() => String(/Exporting Timesheets/i.test(document.body.innerText||''))" 2>/dev/null | grep -qiw true
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

# ------------------------------------------------------- download inspection

# tt683_arm_download_capture — patch every route Mendix might use to hand the
# browser a file, before the download button is clicked. Mendix's Download File
# action has used window.open, a hidden anchor and a hidden iframe across
# versions, so all three are covered; the MutationObserver also catches an
# iframe whose src is assigned after insertion.
tt683_arm_download_capture() {
  playwright-cli eval "() => {
    window.__ttDlUrl = null; window.__ttZip = null; window.__ttZipErr = null;
    const rec = u => { try { if (u && /\\/file/.test(String(u))) window.__ttDlUrl = String(u); } catch(e){} return u; };
    if (!window.__ttPatched) {
      const _open = window.open;
      window.open = function(u){ rec(u); try { return _open.apply(window, arguments); } catch(e){ return null; } };
      document.addEventListener('click', e => { const a = e.target && e.target.closest && e.target.closest('a[href]'); if (a) rec(a.href); }, true);
      new MutationObserver(ms => { for (const m of ms) { for (const n of m.addedNodes||[]) { if (n && n.tagName === 'IFRAME') { rec(n.src); setTimeout(()=>rec(n.src), 300); } } } })
        .observe(document.documentElement, { subtree:true, childList:true });
      window.__ttPatched = true;
    }
    return 'armed';
  }" 2>/dev/null | grep -qiw armed || tt_fail "could not arm the download capture"
}

# tt683_fetch_zip_entries — fetch the captured URL and parse the ZIP central
# directory. Kicks the fetch off and stores the result on window, then polls;
# done this way so it does not depend on playwright-cli eval awaiting promises.
# Prints one entry name per line. Prints nothing and returns 1 on failure,
# leaving the reason in tt683_zip_error.
tt683_fetch_zip_entries() {
  local i url
  for i in $(seq 1 20); do
    url=$(playwright-cli eval "() => window.__ttDlUrl || ''" 2>/dev/null | sed -n '2p' | sed -e 's/^\"//' -e 's/\"$//')
    [ -n "$url" ] && break
    sleep 1
  done
  [ -n "$url" ] || { TT683_ZIP_ERR="no download URL was captured — the Download file action did not go through window.open, an anchor or an iframe"; return 1; }

  playwright-cli eval "() => {
    fetch(window.__ttDlUrl, { credentials: 'include' })
      .then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.arrayBuffer(); })
      .then(buf => {
        const b = new Uint8Array(buf);
        if (b.length < 4) throw new Error('empty response');
        if (!(b[0]===0x50 && b[1]===0x4b)) throw new Error('not a ZIP (magic ' + b[0] + ',' + b[1] + ')');
        // End of Central Directory: scan back for 0x06054b50.
        let eo = -1;
        for (let i = b.length - 22; i >= 0 && i > b.length - 66000; i--) {
          if (b[i]===0x50 && b[i+1]===0x4b && b[i+2]===0x05 && b[i+3]===0x06) { eo = i; break; }
        }
        if (eo < 0) throw new Error('no end-of-central-directory record');
        const dv = new DataView(buf);
        const total = dv.getUint16(eo + 10, true);
        let off = dv.getUint32(eo + 16, true);
        const names = [], recs = [];
        for (let n = 0; n < total; n++) {
          if (dv.getUint32(off, true) !== 0x02014b50) break;
          const crc      = dv.getUint32(off + 16, true);
          const rawSize  = dv.getUint32(off + 24, true);
          const nameLen  = dv.getUint16(off + 28, true);
          const extraLen = dv.getUint16(off + 30, true);
          const cmtLen   = dv.getUint16(off + 32, true);
          const nm = new TextDecoder().decode(b.subarray(off + 46, off + 46 + nameLen));
          names.push(nm);
          // CRC-32 and uncompressed size come straight out of the central
          // directory, so the CONTENT of each PDF is identifiable without
          // inflating anything. See tt683_zip_records for why that matters.
          // '~~' rather than a tab: these come back through JSON encoding, and
          // a real tab arrives as an escaped \t that the shell then has to
          // un-escape. Same reason lib/_tt647.sh joins its two lines with '~~'.
          recs.push(nm + '~~' + crc + '~~' + rawSize);
          off += 46 + nameLen + extraLen + cmtLen;
        }
        window.__ttZip = names;
        window.__ttZipRecs = recs;
      })
      .catch(e => { window.__ttZipErr = String(e && e.message || e); });
    return 'started';
  }" >/dev/null 2>&1

  for i in $(seq 1 30); do
    local err done_
    err=$(playwright-cli eval "() => window.__ttZipErr || ''" 2>/dev/null | sed -n '2p' | sed -e 's/^\"//' -e 's/\"$//')
    if [ -n "$err" ]; then TT683_ZIP_ERR="$err"; return 1; fi
    done_=$(playwright-cli eval "() => window.__ttZip ? String(window.__ttZip.length) : ''" 2>/dev/null | sed -n '2p' | sed -e 's/^\"//' -e 's/\"$//')
    if [ -n "$done_" ]; then
      playwright-cli eval "() => (window.__ttZip||[]).join('\\n')" 2>/dev/null | _tt_eval_str | grep .
      return 0
    fi
    sleep 1
  done
  TT683_ZIP_ERR="timed out fetching/parsing the archive"
  return 1
}

# tt683_download_zip_entries — arm, click the ZIP button, return entry names.
tt683_download_zip_entries() {
  tt683_arm_download_capture
  playwright-cli eval "() => { const b=[...document.querySelectorAll('button')].filter(e=>e.offsetParent!==null).find(e=>/zip/i.test(e.innerText||'')); if(b){b.click(); return 'ok';} return 'nf'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok \
    || tt_fail "could not click the ZIP download button"
  tt683_fetch_zip_entries
}

# tt683_zip_records — one "<name>~~<crc32>~~<uncompressed-size>" line per archive
# entry, from the archive most recently parsed into the page by
# tt683_fetch_zip_entries. Prints nothing if no archive is in the session.
#
# WHY THIS EXISTS. Filenames alone cannot prove TT-683. Main.SUB_BuildMonthHelpers
# sets PDFMonthHelper/FileName per helper, so the names come out right even if
# every PDF holds the SAME data — which is exactly the pre-TT-683 defect:
# Main.ACT_PDF_GoTo used to ignore its context object and retrieve the newest
# PDFMonthHelper, so N generations rendered one consultant N times. Identical
# renders produce identical bytes, hence an identical CRC-32. Comparing CRCs
# catches that regression without inflating or parsing the PDFs.
tt683_zip_records() {
  playwright-cli eval "() => (window.__ttZipRecs||[]).join('\\n')" 2>/dev/null \
    | _tt_eval_str | grep . || true
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
  label=$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabEntries'); if(!g) return ''; const bs=[...g.querySelectorAll('.mx-name-btnProcess')]; for(const b of bs){ let p=b; for(let k=0;k<10;k++){ if(!p.parentElement) break; p=p.parentElement; const t=(p.innerText||''); if(t.length>10 && t.length<400){ if($owned) return t.split('\n').map(s=>s.trim()).filter(Boolean).slice(0,2).join('|'); break; } } } return ''; }" 2>/dev/null | sed -n '2p' | sed -e 's/^"//' -e 's/"$//')
  [ -n "$label" ] || return 1

  playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabEntries'); if(!g) return 'nf'; const bs=[...g.querySelectorAll('.mx-name-btnProcess')]; for(const b of bs){ let p=b; for(let k=0;k<10;k++){ if(!p.parentElement) break; p=p.parentElement; const t=(p.innerText||''); if(t.length>10 && t.length<400){ if($owned){ b.click(); return 'ok'; } break; } } } return 'nf'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok || return 1
  sleep 4

  # Main.AssignmentEntry_Process opens with a footer 'Process' button. Its widget
  # name is generated (actionButton3), so match the caption instead.
  local clicked=""
  for i in 1 2 3 4 5 6 7 8; do
    if playwright-cli eval "() => { const b=[...document.querySelectorAll('button')].filter(e=>e.offsetParent!==null).find(e=>(e.innerText||'').trim().toLowerCase()==='process'); if(b){b.click(); return 'ok';} return 'nf'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok; then
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
