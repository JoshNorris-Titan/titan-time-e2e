#!/usr/bin/env bash
# _login_tokens.sh — part of the lib/_login.sh split (2026-09-17).
#
# The customer-approval journey: flow helpers, the anonymous token page, the
# gated-state reporting for a missing Remind button (#83), and the review popup
# reached with View.
#
# DO NOT SOURCE THIS DIRECTLY. Source lib/_login.sh, which sources every part in
# order; the parts are positional slices of one file and several depend on names
# defined in an earlier one. Sourcing lib/_login.sh is exactly what it always was.
#
# This file is lines 1280-1527 of the pre-split lib/_login.sh, verbatim. Everything
# below the next line is unchanged, which is how the split was verified.
# --- begin verbatim slice of the original lib/_login.sh ---
# ---------------------------------------------------------------------------
# Customer-approval-flow helpers (see verify-customer-approval-flow.test.sh)
# ---------------------------------------------------------------------------

# tt_hr_remind_e2e_entry <consultant-name>
# On the HR "Client Approval" tab (must already be open): scans the available-
# weeks list; for each week it selects, it looks in the entries gallery for a
# pending card mentioning <consultant-name> and clicks that card's "Remind".
# Prints the matched week label and returns 0 on success; returns 1 if no
# matching entry is found in any listed week. (Reminding does NOT consume the
# entry, so the flow stays idempotent.)
# _tt_hr_tab_state <label> — print what the HR dashboard tab is ACTUALLY showing.
#
# Mirrors tt647_log_tab_state, but lives here: lib/_tt647.sh is sourced AFTER this
# file, so tt_hr_remind_e2e_entry below cannot call into it.
#
# Writes to STDERR on purpose. tt_hr_remind_e2e_entry's STDOUT is its return value
# — every caller does WEEK=$(tt_hr_remind_e2e_entry ...) — so a diagnostic printed
# to stdout would be captured as the week label and corrupt every assertion
# downstream of it. run-tests.sh captures both streams, so this still shows up in
# the run output.
#
# The distinction it exists to draw: "weekPicker=ABSENT" means the tab pane had not
# rendered and the queue was never actually inspected; "weekPicker=present" with
# weeks listed and no matching card means the entry genuinely is not in this queue.
# Those point at completely different causes and were indistinguishable before.
_tt_hr_tab_state() {
  local label="${1:-tab state}" s
  s="$(playwright-cli eval "() => { const val=sel=>{ const w=document.querySelector(sel); if(!w) return '(absent)'; const i=w.querySelector('input,select'); const v=(i&&i.value)||''; const txt=(w.innerText||'').replace(/\\s+/g,' ').trim(); return v || txt || '(empty)'; }; const wk=document.querySelector('$TT_HR_GAL_WEEKS'); const weeks=wk?[...new Set([...wk.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} /.test(t)))]:[]; const g=document.querySelector('$TT_HR_GAL_ENTRIES'); return 'weekPicker=' + (wk?'present':'ABSENT') + ' | entriesGallery=' + (g?'present':'ABSENT') + ' | consultantFilter=' + val('$TT_HR_CB_CONSULTANT') + ' | projectFilter=' + val('$TT_HR_CB_PROJECT') + ' | weeks(' + weeks.length + ')=' + (weeks.join(', ') || '(none)') + ' | remindCards=' + document.querySelectorAll('$TT_HR_BTN_REMIND').length + ' | remindGated=' + document.querySelectorAll('$TT_HR_BTN_REMIND_BLOCKED').length; }" 2>/dev/null | _tt_eval_str)"
  echo "  [hr-tab] $label: $s" >&2
}

# tt_hr_remind_e2e_entry <consultantName> [projectName]
#
# Clicks Remind on a pending card for <consultantName>, walking the week list until
# one matches. Pass <projectName> to require the card to be for that project too.
#
# WHY THE PROJECT ARGUMENT MATTERS. Matching on the consultant alone picks whatever
# pending entry comes first, and dev carries several client-approval projects for
# the same consultant on DIFFERENT customers (E2E ClientApproval B/C/D/E ->
# Walmart/Yamaha/Rapidappwerks/Thomas Inc., alongside E2E Customer Approval ->
# Costco), so reminding an unscoped entry acts on some other customer's queue and a
# caller asserting on a fixed project fails on data selection rather than on
# anything the product did.
#
# WHAT THE TOKEN IS SCOPED TO CHANGED (model commit 8ca78e2e, TT-741). It used to be
# one token per PROJECT; it is now one token per APPROVER EMAIL, and the landing page
# lists everything that approver has waiting across all of their projects. So the
# project argument no longer narrows what the token page shows — it only decides
# which pending entry gets reminded (and therefore which mail carries the link).
# A caller that needs to act on a specific project's entry must identify that entry
# on the page itself; see tt_token_popup_text below.
tt_hr_remind_e2e_entry() {
  local who="$1" proj="${2:-}" labels lbl i
  # WAIT FOR THE PANE, don't assume it is up. Selecting a tab flips
  # HRDashboardHelper/DashboardSelected, which UNRENDERS the previous pane and
  # builds this one from scratch — it must then run DS_TabForStatus, DS_WeeksForTab
  # and DS_EntriesForTab before the week picker exists. Callers allow about four
  # seconds (tt_click_text sleeps 2, then the test sleeps 2), which is not enough
  # against Mendix Cloud dev. When the picker is not in the DOM yet the label query
  # below returns nothing, the loop never executes, and this returns 1 — which is
  # indistinguishable from "no pending entry" and is why three tests reported a
  # missing entry that was sitting in the queue the whole time.
  #
  # Deliberately NOT tt_wait_for: that calls tt_fail, and an EMPTY Client Approval
  # queue is a legitimate outcome the caller handles by creating an entry. A hard
  # failure here would break the "is there a standing entry?" probe.
  for i in $(seq 1 20); do
    playwright-cli eval "() => String(!!document.querySelector('$TT_HR_GAL_WEEKS'))" 2>/dev/null | grep -qiw true && break
    sleep 1
  done

  # playwright-cli wraps eval results in a JSON string, so a returned array would
  # arrive double-encoded; return a pipe-joined line instead and split in bash.
  labels=$(playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_WEEKS'); if(!g) return ''; const set=[...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} \\d{2} - [A-Z][a-z]{2} \\d{2}/.test(t)))]; return set.join('|'); }" 2>/dev/null | sed -n '2p')
  labels="${labels%\"}"; labels="${labels#\"}"   # strip the wrapper quotes
  local IFS='|'
  for lbl in $labels; do
    [ -n "$lbl" ] || continue
    # $(seq ...) splits on IFS, and IFS is '|' here — without this the counter
    # below collapses into a single token and the poll runs exactly once.
    unset IFS
    playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_WEEKS'); const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$lbl')===0); if(el){el.click(); return 'ok';} return 'nf'; }" >/dev/null 2>&1
    # POLL, rather than looking once four seconds after the click. Selecting a week
    # reloads the entries gallery, and an entry submitted moments ago reaches the
    # queue ASYNCHRONOUSLY — tt647_wait_for_card polls up to 60s for that same
    # reason. Looking once is what made a slow reload read as an absent entry.
    for i in $(seq 1 8); do
      if playwright-cli eval "() => { const rs=[...document.querySelectorAll('$TT_HR_BTN_REMIND')]; const proj='$proj'; for(const r of rs){ let el=r; for(let i=0;i<9;i++){ el=el.parentElement; if(!el) break; const t=el.innerText||''; if(t.indexOf('$who')>=0 && (proj==='' || t.indexOf(proj)>=0)){ r.click(); return 'true'; } } } return 'false'; }" 2>/dev/null | sed -n '2p' | grep -qiw true; then
        echo "$lbl"
        return 0
      fi
      sleep 1
    done
    IFS='|'
  done
  unset IFS
  # DISTINGUISH "no such card" FROM "the card is there but Remind is gated today".
  # Since the once-per-day gate landed, an already-reminded client card renders
  # btnClientRemindBlocked INSTEAD of btnClientRemind, so the walk above finds
  # nothing and the old message asserted a cause this function never checked.
  # Same ancestor walk as the matcher, so the two cannot drift about what a row is.
  local gated
  gated=$(playwright-cli eval "() => { const rs=[...document.querySelectorAll('$TT_HR_BTN_REMIND_BLOCKED')]; const proj='$proj'; for(const r of rs){ let el=r; for(let i=0;i<9;i++){ el=el.parentElement; if(!el) break; const t=el.innerText||''; if(t.indexOf('$who')>=0 && (proj==='' || t.indexOf(proj)>=0)) return 'true'; } } return 'false'; }" 2>/dev/null | sed -n '2p')
  if echo "$gated" | grep -qiw true; then
    _tt_hr_tab_state "'$who'${proj:+ / '$proj'} card IS present but Remind is GATED (already reminded today); caller must create a fresh entry to re-enable it"
    return 1
  fi
  # Say what the tab was actually showing. Without this the caller can only report
  # "no pending entry", which asserts a cause this function never checked.
  _tt_hr_tab_state "no pending '$who'${proj:+ / '$proj'} card in any listed week"
  return 1
}

# ---------------------------------------------------------------------------
# Anonymous customer-approval (token) page helpers
#
# WHAT A ROW IS, AND WHAT IDENTIFIES IT. Main.Customer_Approval renders one
# gallery item per pending entry, and that item contains exactly three readable
# things: the consultant name, "<n> hours", and the period. Since model commit
# 8ca78e2e the row template is '{ConsultantName} - {ProjectName} ({Customer})',
# but Main.DS_ApprovalHelper_Customer never sets those two placeholders, so a row
# reads 'E2E Consultant - ()' and names no project at all.
#
# So a row is identified by CONSULTANT + WEEK, and nothing else is available on
# the landing page. The review popup is the one surface that names the project
# (see tt_token_popup_text below), and every caller that is about to do something
# irreversible must read it there first.
#
# THE PAGE IS SCOPED TO THE APPROVER, NOT TO A PROJECT, and it is not ours alone.
# Since 8ca78e2e the token resolves to an approver, and the gallery lists every
# entry awaiting that approver on ANY project. The Manual review environment
# (manual-env/) is on dev now, and its Manual Consultant entries appear on the
# same page as ours, AHEAD of them. Nothing here may assume a row it did not
# identify is E2E data.
#
# A ROW IS ITS GALLERY ITEM. rowOf() used to climb up to ten parents from the
# View button and return the first ancestor whose text held the consultant and
# "hours". It had no containment guard, and a Manual Consultant row never holds
# "E2E Consultant" -- so from a Manual row's View the climb ran straight past the
# row, reached the list holding EVERY row, matched there, and handed back the
# whole list. The first View on the page (a Manual row) then "matched" any week
# asked for. Run 34656051868 opened a Manual entry in three customer specs, which
# refused it on the popup's project, and approved one in verify-token-replay-
# refused, which did not look. Scoping to `.widget-gallery-item` -- what
# tt_token_rows_all_actionable and every other gallery spec in this suite already
# use -- makes a row exactly one entry, whatever else shares the page.
#
# Do NOT reintroduce a project-name match on the landing page: the row carries no
# project, so the predicate can never be true (it did this once, and made the
# row-open step fail every run while the did-it-leave poll passed instantly).
#
# The walk is defined ONCE, below, so the logger and the matchers cannot drift
# apart about which element the row is.
# ---------------------------------------------------------------------------

# _tt_token_row_js <consultantName> — emits the shared JS prelude.
#
#   itemOf(btnView)  the button's own gallery item: one entry, never more.
#   rowOf(btnView)   that item, but only when it is <consultantName>'s -- it
#                    must hold both the name and "hours" -- else null. Both
#                    lines of the row are inside the item, so the period is too.
#
# Emitted as ONE line on purpose. playwright-cli echoes the snippet source
# before its result and _tt_eval_str reads line 2, so a multi-line snippet would
# shift the result off the line every caller reads.
_tt_token_row_js() {
  printf '%s' "const who='$1';const txt=p=>((p&&p.innerText)||'').replace(/\u00a0/g,' ').replace(/\s+/g,' ').trim();const itemOf=v=>v.closest('.widget-gallery-item');const rowOf=v=>{const r=itemOf(v);if(!r)return null;const t=txt(r);return (t.indexOf(who)>=0&&t.indexOf('hours')>=0)?r:null;};const views=()=>[...document.querySelectorAll('.mx-name-galPendingEntries .mx-name-btnView')];"
}

# tt_token_log_rows <consultantName> — print every row the token page is
# offering, whole. When a match fails this is the evidence for why, so it must
# show the period; a partial row is what turned one bad predicate into days of
# looking for a product bug.
tt_token_log_rows() {
  local js; js="$(_tt_token_row_js "$1")"
  playwright-cli eval "() => { $js const g=document.querySelector('.mx-name-galPendingEntries'); if(!g) return '(no pending list)'; const rows=views().map(v=>{ const r=itemOf(v); return r ? txt(r).slice(0,160) : '(row text unavailable)'; }); return rows.length ? rows.join('  ||  ') : '(no rows)'; }" 2>/dev/null | _tt_eval_str | sed 's/^/  [token-page rows] /'
}

# tt_token_open_row <consultantName> <weekFragment>
# Clicks View on the matching row. Echoes hit | nomatch | empty so the caller
# can tell "no rows at all" from "rows, but not ours" — different causes.
tt_token_open_row() {
  local js; js="$(_tt_token_row_js "$1")"
  playwright-cli eval "() => { $js const vs=views(); for(const v of vs){ const r=rowOf(v); if(r && txt(r).indexOf('$2')>=0){ v.click(); return 'hit'; } } return vs.length ? 'nomatch' : 'empty'; }" 2>/dev/null | _tt_eval_str
}

# tt_token_row_present <consultantName> <weekFragment> — true | false.
# Used on BOTH sides of the approve/reject click: asserted true before, polled
# to false after. A disappearance check that is never seen in its true state
# proves nothing.
tt_token_row_present() {
  local js; js="$(_tt_token_row_js "$1")"
  playwright-cli eval "() => { $js const g=document.querySelector('.mx-name-galPendingEntries'); if(!g) return 'false'; return String(views().some(v=>{ const r=rowOf(v); return !!r && txt(r).indexOf('$2')>=0; })); }" 2>/dev/null | _tt_eval_str
}

# tt_token_rows_all_actionable — 'true' when EVERY row on the token page offers an
# Approve button, i.e. every listed entry is actually awaiting this client's
# decision. btnApprove's conditional visibility on Customer_Approval is
# ApprovalHelper.AEStatus = AwaitingCustomerApproval, so a row without one is an
# entry in some other state that has leaked onto an anonymous page.
#
# Echoes 'true', 'false', or 'norows' — 'norows' is NOT true, so a caller cannot
# satisfy this by looking at an empty list.
tt_token_rows_all_actionable() {
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-galPendingEntries'); if(!g) return 'norows'; const rows=[...g.querySelectorAll('.widget-gallery-item')]; if(!rows.length) return 'norows'; return String(rows.every(r=>{ const b=r.querySelector('.mx-name-btnApprove'); return !!b && b.offsetParent!==null; })); }" 2>/dev/null | _tt_eval_str
}

# ---------------------------------------------------------------------------
# The review popup (Main.Customer_ReviewTimesheetEntry), reached with View.
#
# WHY THESE EXIST. Model commit 8ca78e2e rewrote Main.Customer_Approval: the
# Customer/Project header rows were replaced by one static heading, and the row
# template became '{ConsultantName} - {ProjectName} ({Customer})'. The landing page
# therefore no longer names the project or the customer anywhere in its own text —
# and, because Main.DS_ApprovalHelper_Customer never sets ApprovalHelper/ProjectName
# or ApprovalHelper/Customer, those two placeholders currently render EMPTY, so the
# row reads 'E2E Consultant - ()'. See the header of
# suites/30-approval/verify-customer-approval-flow.test.sh.
#
# The Entry Details panel inside the review popup DOES name the project (labelled
# 'Consultant', 'Project', 'Week Range', 'Submitted'), so that popup is the only
# surface on the anonymous journey where an entry's project can be asserted. Every
# test that needs to know WHICH entry it is looking at reads it from here.
# ---------------------------------------------------------------------------

# tt_token_popup_text — the whole review popup as one line, or '(no popup)'.
tt_token_popup_text() {
  playwright-cli eval "() => { const d=document.querySelector('.mx-window-active, .modal-dialog, [role=dialog]'); if(!d) return '(no popup)'; return (d.innerText||'').replace(/ /g,' ').replace(/\s+/g,' ').trim(); }" 2>/dev/null | _tt_eval_str
}

# tt_token_popup_close — dismiss the review popup with Cancel and WAIT for it to go.
# Echoes closed | open | missing, and returns non-zero unless it actually closed.
# Cancel is the only exit that leaves the entry pending, which is what
# verify-customer-approval-flow's repeatability depends on.
tt_token_popup_close() {
  local i state
  state="$(playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnCustomerCancel'); if(!b) return 'missing'; b.click(); return 'clicked'; }" 2>/dev/null | _tt_eval_str)"
  if [ "$state" != "clicked" ]; then echo "missing"; return 1; fi
  for i in $(seq 1 10); do
    if [ "$(playwright-cli eval "() => String(!document.querySelector('.mx-name-btnCustomerApprove'))" 2>/dev/null | _tt_eval_str)" = "true" ]; then
      echo "closed"; return 0
    fi
    sleep 1
  done
  echo "open"; return 1
}
