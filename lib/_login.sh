#!/usr/bin/env bash
# Shared helpers for Titan Time E2E tests. Source it from a *.test.sh:
#   source "$(dirname "$0")/lib/_login.sh"
#
# Provides:
#   tt_login <username> <ready-text>   forms-login via /login.html, wait for <ready-text> on the dashboard
#   tt_assert_all <label> <text>...    fail unless ALL <text> substrings are present in document.body
#   tt_fail <msg>                      print FAIL and exit 1
#
# This file lives in tests/lib/ (not a *.test.sh) so the runner does not execute
# it as a test. Uses forms login (stable IDs) so it is portable across envs.
#
# Env:
#   TT_BASE_URL   app origin (no trailing slash; default http://localhost:8080)
#   TT_ROLE_PASS  password for the e2e_* role accounts (default E2ETest123!)

TT_BASE="${TT_BASE_URL:-http://localhost:8080}"
TT_PASS="${TT_ROLE_PASS:-E2ETest123!}"

# ---------------------------------------------------------------------------
# HR dashboard tab selectors — TT-724 phase 4 retired Main.SNIP_HRDashboardTab.
#
# WHAT CHANGED. Four of the HR dashboard's tabs (Manager Approval, Client
# Approval, To Process, Sent) used to render ONE shared snippet, so every widget
# in them carried one tab-agnostic name and a bare `.mx-name-galTabEntries`
# addressed whichever tab was open. The snippet was inlined into Main.HRDashboard
# on 2026-09-02 and the four copies were renamed apart, per tab:
#
#   galTabEntries        -> galManagerEntries / galClientEntries
#                           galProcessEntries / galSentEntries
#   galTabAvailableWeeks -> gal{Manager,Client,Process,Sent}AvailableWeeks
#   cbTabWeekConsultant  -> cb{Manager,Client,Process,Sent}Consultant
#   cbTabWeekProject     -> cb{Manager,Client,Process,Sent}Project
#   btnApprove           -> btnManagerApprove / btnClientApprove
#   btnRemind            -> btnManagerRemind  / btnClientRemind
#   btnView              -> btnManagerView    / btnClientView
#   btnProcess           -> btnProcessEntry
#   btnReject            -> btnProcessReject
#   textApprovedBy1/2    -> txtProcessManagerApprover / txtProcessClientApprover
#
# WHY A UNION AND NOT FOUR CODE PATHS. Selecting a tab flips
# HRDashboardHelper/DashboardSelected, which UNRENDERS the previous pane and
# builds the new one from scratch — so at most one of the four is in the DOM at
# any moment. A comma-joined selector therefore matches exactly what the single
# old name matched, and every helper below keeps working on "whatever tab is
# open" without being told which one that is. Naming the tabs explicitly in each
# helper would have been a much larger change for no extra assurance.
#
# THE INVOICE AND PENDING TABS ARE NOT IN THESE UNIONS, on purpose. Both were
# always page-level rather than snippet-level, so their names did not change and
# the old `galTabEntries` never matched them either: Invoice has galInvoiceEntries
# / galAvailableMonths / btnInvoiceView / btnInvoiceReject / btnExportAll, and
# Pending has galPending / galAvailableWeeks / cbWeekConsultant / btnRemind.
#
# THAT LAST ONE IS THE TRAP. `.mx-name-btnRemind` still exists — it is the
# Pending card's "remind this consultant to submit" button, which is a different
# button from the per-entry Remind that used to share its name. A helper left on
# the bare name does not error; it silently scans the wrong cards and reports
# "no pending entry". Use TT_HR_BTN_REMIND.
TT_HR_GAL_ENTRIES='.mx-name-galManagerEntries, .mx-name-galClientEntries, .mx-name-galProcessEntries, .mx-name-galSentEntries'
TT_HR_GAL_WEEKS='.mx-name-galManagerAvailableWeeks, .mx-name-galClientAvailableWeeks, .mx-name-galProcessAvailableWeeks, .mx-name-galSentAvailableWeeks'
TT_HR_CB_CONSULTANT='.mx-name-cbManagerConsultant, .mx-name-cbClientConsultant, .mx-name-cbProcessConsultant, .mx-name-cbSentConsultant'
TT_HR_CB_PROJECT='.mx-name-cbManagerProject, .mx-name-cbClientProject, .mx-name-cbProcessProject, .mx-name-cbSentProject'
TT_HR_BTN_APPROVE='.mx-name-btnManagerApprove, .mx-name-btnClientApprove'
TT_HR_BTN_REMIND='.mx-name-btnManagerRemind, .mx-name-btnClientRemind'
TT_HR_BTN_VIEW='.mx-name-btnManagerView, .mx-name-btnClientView'
TT_HR_BTN_PROCESS='.mx-name-btnProcessEntry'
TT_HR_BTN_REJECT='.mx-name-btnProcessReject'
TT_HR_TXT_APPROVER1='.mx-name-txtProcessManagerApprover'
TT_HR_TXT_APPROVER2='.mx-name-txtProcessClientApprover'
# The per-entry CARD inside the entries gallery. Was the snippet's generated
# container13, which is why a rename could never have been noticed by name alone.
TT_HR_CARD='.mx-name-containerManagerCard, .mx-name-containerClientCard, .mx-name-containerProcessCard, .mx-name-containerSentCard'

# tt_fail — report and stop. Writes to STDERR, deliberately.
#
# It used to write to stdout, which meant any helper that failed inside a command
# substitution had its diagnosis captured into the caller's variable instead of
# printed. verify-tt683-a1 does
#     TAB="$(tt683_open_export_tab)" || exit 1
# and tt683_open_export_tab ends in tt_fail; the whole "no HR dashboard tab
# exposes an Export All button" message went into $TAB and the test exited 1
# having printed NOTHING AT ALL. run-tests.sh merges stderr into the captured
# output, so stderr still shows up in the report and in the JUnit XML - it just
# also survives $( ).
tt_fail() { echo "FAIL: $*" >&2; exit 1; }

# TT_DIALOG_SEL — the dialog CONTAINER, established by inspecting the live DOM:
#
#   3 <div class="modal-content mx-window-content">  buttons=3
#   4   <div class="modal-header mx-window-header">  buttons=1   (the × )
#   4   <div class="modal-body mx-window-body">      buttons=2   (yes / No)
#
# Two things this suite had wrong. First, NO element with class mx-dialog or
# mx-window, and nothing with role=dialog, is present at all — so the original
# '.mx-dialog,.mx-window,[role=dialog]' matched nothing and only the loose
# '[class*=modal]' ever hit, which matches the header/body/footer CHILDREN too.
# Picking "the last match" therefore selected a modal-footer, whose innerText is
# just "OK" — that is why the terminal dialog looked like an empty OK box and
# why tt654_mint_token read no token.
#
# Message popups use mx-dialog-* rather than mx-window-*, so both are listed;
# .modal-content covers either, and [role=dialog] is kept as a forward-compatible
# fallback. Always select the OUTERMOST visible match (see _tt_dialog_js).
TT_DIALOG_SEL='.mx-window-content,.mx-dialog-content,.modal-content,[role=dialog]'
TT_DIALOG_BLOCKED=""

# _tt_dialog_js — JS snippet evaluating to the topmost visible dialog container,
# or null. Outermost-wins so a nested .modal-content can never shadow its parent.
_tt_dialog_js() {
  printf "%s" "(() => { const vis=[...document.querySelectorAll('$TT_DIALOG_SEL')].filter(d=>d.offsetParent!==null); const outer=vis.filter(d=>!vis.some(o=>o!==d && o.contains(d))); return outer[outer.length-1]||null; })()"
}

# tt_clear_dialogs [max] — walk the confirmation chain on the LIVE dialog.
#
# Mendix leaves CLOSED dialogs in the DOM. A probe during the submit chain found
# four dialog nodes, only three visible, with the stale one FIRST — so
# document.querySelector('.mx-dialog,…') handed back a dead dialog whose buttons
# do nothing. Every dismiss helper in this suite did exactly that, so
# "Submit Anyway" was clicked on a corpse while the live warning stayed up. The
# timesheet never submitted, the entry stayed Draft, and ~15 approval/reject
# tests failed with "entry did not reach the PM pending queue" — pointing at the
# workflow when nothing had ever been submitted. Always take the LAST VISIBLE one.
#
# Returns 0 when every dialog is cleared. Returns 1 when a dialog offers no way
# forward — e.g. Main.Consultant_OverWeeklyHours, whose ONLY button is Close, so
# it CANCELS the submit rather than confirming it. Its text is left in
# TT_DIALOG_BLOCKED so callers can fail with the real reason instead of
# clicking Close and reporting a mystery. (Note the old regexes included
# "close", which is precisely how that cancel went unnoticed.)
# Second argument: an EXTRA caption to accept as confirmation, for dialogs whose
# confirm button is labelled with the action itself ("Approve", "Reject"). It is
# opt-in per call rather than added to the shared list on purpose: this helper runs
# in almost every test, and a generic clearer that clicked anything called "Reject"
# would happily reject an entry a test was trying to approve. Same reasoning as the
# note above about "close".
tt_clear_dialogs() {
  local max="${1:-8}" extra="${2:-}" i r d alts
  d="$(_tt_dialog_js)"
  # 'submit' is listed as well as 'submit anyway'. Since the two submit popups
  # were merged, a week with nothing wrong opens the same confirm page reading
  # "Submit Timesheet?" with a plain Submit button (btnConfirmSubmit); only a
  # week that actually warned shows "Submit Anyway" (btnWarningSubmitAnyway).
  # Without the bare caption every clean submit parks on BLOCKED. The regex is
  # anchored with ^...$, so 'submit' does NOT swallow 'Submit Anyway'.
  alts='yes|submit|submit anyway|confirm|continue|proceed|ok'
  # Strip regex metacharacters — the caption is interpolated into a JS literal.
  [ -n "$extra" ] && alts="$alts|$(printf '%s' "$extra" | tr -d '\^$.[]|()?*+{}/')"
  TT_DIALOG_BLOCKED=""
  for i in $(seq 1 "$max"); do
    r=$(playwright-cli eval "() => { const d=$d; if(!d) return 'NONE'; const btns=[...d.querySelectorAll('button')].filter(b=>b.offsetParent!==null); const b=btns.find(x=>new RegExp('^(' + '$alts' + ')\$','i').test((x.innerText||'').trim())); if(b){ b.click(); return 'ADVANCED'; } return 'BLOCKED:'+(d.innerText||'').replace(/\\s+/g,' ').slice(0,140); }" 2>/dev/null | _tt_eval_str)
    case "$r" in
      NONE) return 0 ;;
      BLOCKED:*) TT_DIALOG_BLOCKED="${r#BLOCKED:}"; return 1 ;;
    esac
    sleep 2
  done
  return 0
}

# tt_click_card <text> [label] — click a dashboard card by its caption.
#
# tt_click_text is not enough for these. It matches the element whose OWN text is
# the caption and whose OWN cursor is a pointer, but an Admin Hub card puts its
# caption in a child text widget while the click handler and the pointer live on
# the container above it. So the caption element matches on text and fails on
# cursor, and nothing is clicked. This walks up from the caption to the first
# ancestor that actually looks clickable.
tt_click_card() {
  local txt="$1" label="${2:-$1}" r
  r=$(playwright-cli eval "() => { const all=[...document.querySelectorAll('*')].filter(e => e.childElementCount < 3 && (e.innerText||'').trim() === '$txt'); const el = all[all.length-1]; if (!el) return 'notext'; let p = el; for (let i = 0; i < 8 && p; i++) { const cs = getComputedStyle(p); if (cs.cursor === 'pointer' || p.onclick || p.getAttribute('role') === 'button') { p.click(); return 'ok'; } p = p.parentElement; } el.click(); return 'leaf'; }" 2>/dev/null | _tt_eval_str)
  case "$r" in
    ok|leaf) sleep 3; return 0 ;;
    *) tt_fail "no clickable card captioned '$txt' ($label)" ;;
  esac
}

# tt_open_email_tester — land on Main.EmailTester, whatever it is called today.
#
# The page's widgets were auto-named (textBox2 / comboBox1 / actionButton3) and
# have been renamed to txtTesterEmail / cbTesterEmailType / btnTesterSend. Both
# names are accepted here so the suite works either side of that reaching an
# environment, and says which one it found rather than leaving it a mystery.
# Prints "old" or "new" so a caller can pick its selectors.
#
# ALL THREE WIDGETS ARE REQUIRED BEFORE A NAMING IS DECLARED. This used to accept
# a naming on the strength of ONE widget, and it ran that check against whatever
# page happened to be showing BEFORE navigating anywhere. ".mx-name-textBox2" is a
# generic auto-generated name that exists on other pages, so the helper would
# report a naming for a page that is not the Email Tester at all, hand the caller
# selectors that match nothing, and tt_fill would then abort the whole script.
# Matching the full triple means the answer can only come from the tester itself.
tt_open_email_tester() {
  local i variant
  for i in $(seq 1 3); do
    variant="$(playwright-cli eval "() => { const has=s=>!!document.querySelector(s); if (has('.mx-name-btnTesterSend') && has('.mx-name-txtTesterEmail') && has('.mx-name-cbTesterEmailType')) return 'new'; if (has('.mx-name-actionButton3') && has('.mx-name-textBox2') && has('.mx-name-comboBox1')) return 'old'; return ''; }" 2>/dev/null | _tt_eval_str)"
    [ -n "$variant" ] && { echo "$variant"; return 0; }
    tt_login "${TT_ADMIN_USER:-MxAdmin}" "Admin Hub" "${TT_ADMIN_PASS:-${TT_PASS:-}}" >/dev/null 2>&1 || true
    tt_click_card "Email Tester" "email tester card" 2>/dev/null || true
    sleep 3
  done
  return 1
}

# tt_fill <selector> <value> — playwright-cli fill that CANNOT fail silently.
#
# Every fill in this suite was written as `playwright-cli fill ... 2>/dev/null`,
# which hides the one failure that matters: when a selector matches more than
# one element Playwright refuses the write outright —
#   strict mode violation: locator('.mx-name-txtDayWed input') resolved to 3 elements
# — and the test sails on to assert a value it never entered. That is exactly
# how verify-consultant-timesheet-crud came to report "draft did not persist
# (wrote 7, re-fetched '0.00')": nothing was ever typed, and the product was
# fine. It only bites when the consultant has several assignment rows, so it
# hid on a cluttered environment and appeared on a freshly cleared one.
#
# Use :nth-match(<selector>, <n>) whenever a selector can match several rows.
tt_fill() {
  local sel="$1" val="$2" out
  out=$(playwright-cli fill "$sel" "$val" 2>&1)
  case "$out" in
    *"strict mode violation"*)
      tt_fail "fill('$sel') matched MULTIPLE elements, so Playwright refused the write. Target one with :nth-match('$sel', <n>). Left unfixed this silently writes nothing and the assertion later reads a stale 0.00." ;;
    *"### Error"*)
      tt_fail "fill('$sel') failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" ;;
  esac
  tt_commit_focused
}

# ---------------------------------------------------------------------------
# Committing a filled field
#
# `playwright-cli fill` writes the DOM value directly. A Mendix text box only
# hands that value to the model when the field BLURS, so the LAST field of any
# fill sequence is never committed. Earlier fields look fine only because
# filling the next one blurred them.
#
# The symptom is a total short by exactly one cell. Measured against dev on
# 2026-08-26: filling Mon..Fri with 5 left Fri reading "5" while Mon..Thu read
# "5.00" - the reformat is the widget's commit signature - and the row total sat
# at 20.00. It was STILL 20.00 two seconds later, so this is not a debounce and
# no amount of sleeping fixes it. The instant the field blurred, Fri became
# "5.00" and the total became 25.00.
#
# That is what verify-hours-validation and verify-timesheet-clear were both
# failing on: one submitted 45 hours the app only ever saw as 40, so no over-40
# warning could fire; the other had its uncommitted Friday written back by the
# very click that was meant to clear the week.
#
# Blur is dispatched on the element itself rather than by clicking something
# else, so no row is selected and no button pressed as a side effect. It is
# synchronous - the value is committed by the time the next read runs - so this
# adds no sleeps.

# tt_commit_focused - make the focused input hand its value to Mendix.
tt_commit_focused() {
  playwright-cli eval "() => { const a=document.activeElement; if (a && a.blur) a.blur(); return 'ok'; }" >/dev/null 2>&1
}

# tt_fill_commit <selector> <value> - fill and commit, without tt_fill's fatal
# error checking. For a SINGLE cell, or the last of a short sequence.
tt_fill_commit() {
  playwright-cli fill "$1" "$2" >/dev/null 2>&1
  tt_commit_focused
}

# tt_fill_cell <selector> <value> - fill WITHOUT committing. For loops.
#
# WHY THIS EXISTS SEPARATELY. Every playwright-cli call is a fresh node process,
# so the cost of committing is process startup, not the blur. Inside a sequence
# the blur is also redundant: `fill` focuses its target, and focusing cell N+1
# blurs cell N, which is what commits it. Only the LAST cell is ever left
# uncommitted.
#
# Blurring per cell therefore paid ~1s of process startup five times per row to
# do once what the next fill does for free. Measured on 2026-08-26 it took the
# tt654 suite from 1000s/9-of-10 to 1652s/7-of-10, the three new failures all
# being TIMEOUTs rather than assertions - a test harness slow enough to fail
# tests that work.
#
# Loops use this and call tt_commit_focused ONCE afterwards. That single blur is
# still mandatory: it is the last cell that the old code lost, and a submit or
# clear click races it rather than committing it.
tt_fill_cell() {
  playwright-cli fill "$1" "$2" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Re-reading the week under test
#
# `playwright-cli reload` re-fetches, but the timesheet page OPENS ON TODAY'S
# WEEK. A test that reloads to prove something persisted therefore reads a
# different week than the one it wrote to, and reports whatever happens to be
# sitting in the current week as its own result.
#
# That is not hypothetical. verify-timesheet-clear reloaded to re-read an
# explicit 0 and got back 9.00 - the 9 hours verify-hours-validation had written
# minutes earlier into the week containing today's date. The number was stable
# across runs, which made it look like a product bug rather than a test reading
# the wrong row.
#
# Stepping one week back and forward re-runs the week's data source without
# leaving the week. tt654_refetch_week has done this since TT-654; it is here so
# every test can, and so the reason is written down once.

# tt_current_week — the week range the grid is showing right now, or ''.
tt_current_week() {
  playwright-cli eval "() => { const t=((document.querySelector('.mx-name-txtWeekRange')||{}).innerText||'').trim(); const m=t.match(/[A-Z][a-z]{2}\s+\d{1,2}\s*-\s*[A-Z][a-z]{2}\s+\d{1,2}/); return m ? m[0] : ''; }" 2>/dev/null | _tt_eval_str
}

# tt_refetch_week — re-query the week the grid is showing, staying on it.
tt_refetch_week() {
  playwright-cli click ".mx-name-btnWeekPrev" >/dev/null 2>&1
  sleep 2
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
  sleep 3
}

# ---------------------------------------------------------------------------
# Can this week still be acted on?
#
# btnClear, btnSaveDraft and btnSubmit share ONE conditional visibility rule, on
# Main.Timesheet.Status: shown for Draft, Rejected and (empty); HIDDEN for
# Awaiting_Approval, Approved and Awaiting_Export. A conditionally hidden Mendix
# widget is not in the DOM at all, so `playwright-cli click` on it FAILS - and a
# caller that discards the exit code cannot tell that from a successful press.
#
# That is how verify-timesheet-clear came to report "Clear did not empty the
# week" about a Clear button that was never on the page. The week it had been
# handed read 0.00 in every cell, which looked untouched, but its status had
# moved past Draft.
#
# Day-cell editability is a DIFFERENT rule - $currentObject/_IsEditable, held per
# ASSIGNMENT ENTRY - so a week can show editable day cells and no action buttons
# at the same time. Never infer one from the other.

# tt_week_actionable - 'true' when the week on screen still has its action buttons.
tt_week_actionable() {
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnClear'))" 2>/dev/null | _tt_eval_str
}

# tt_week_statuses <user> - that consultant's weeks as "<Mon> <D> <status>", one
# per line, read from the objects rather than the screen: the timesheet page
# never renders the week's OWN status anywhere.
#
# FAILURE MESSAGES ONLY. This is a data retrieve - far too slow for the
# week-hunting loop, which uses tt_week_actionable instead. Echoes ERR:<why> when
# it cannot read; a caller must not treat that as a status.
tt_week_statuses() {
  local xp="//Main.Timesheet[Main.Timesheet_Account/Administration.Account/Name = '$1']"
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"$xp\", filter:{amount:300}, callback: function(objs){ clearTimeout(t); try { var M=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec']; res((objs||[]).map(function(o){ var d=o.get('StartDate'); var s=o.get('Status'); if(!d) return '? ? '+(s||'?'); var dt=new Date(d); return M[dt.getMonth()]+' '+dt.getDate()+' '+(s||'?'); }).join('\n')); } catch(e){ res('ERR:read-'+e.message); } }, error: function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'retrieve-refused')); } }); } catch(e) { res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

# tt_week_status <user> <week-label> - the status of the single week whose start
# matches <week-label>. Both "E2E Sep 13 - Sep 19" and "Sep 13 - Sep 19" work.
# Echoes UNKNOWN rather than failing: this only ever decorates a message, and a
# diagnostic that can itself abort the test is worse than no diagnostic.
tt_week_status() {
  local user="$1" label="$2" start mon day all
  start="${label%% - *}"
  mon="$(printf '%s\n' "$start" | awk '{print $(NF-1)}')"
  day="$(printf '%s\n' "$start" | awk '{print $NF}')"
  case "$day" in ''|*[!0-9]*) echo "UNKNOWN"; return 0 ;; esac
  [ -n "$mon" ] || { echo "UNKNOWN"; return 0; }
  day="$((10#$day))"
  all="$(tt_week_statuses "$user")"
  case "$all" in ERR:*|'') echo "UNKNOWN"; return 0 ;; esac
  printf '%s\n' "$all" | awk -v m="$mon" -v d="$day" '$1==m && $2+0==d { print $3; f=1; exit } END { if(!f) print "UNKNOWN" }'
}

# tt_draft_count <project> <consultant> - how many of <consultant>'s entries on
# <project> are still Draft, asked of the DATA LAYER rather than of the screen.
#
# WHY NOT READ THE ROW. The gallery does not reliably re-render a row as
# read-only the moment its entry is submitted: a probe watched one row for 30
# seconds after a submit that had already reached the server and the DOM never
# changed, while a second probe on the next week showed read-only within
# seconds. Submitting is a property of the ENTRY, not of how quickly a bound
# widget repaints.
#
# The asymmetry matters. "Still editable" is safe to read off the screen - a
# lagging DOM stays editable, which is what an unsubmitted week looks like
# anyway. "Became read-only" is NOT: a slow repaint is indistinguishable from a
# refused submit, and asserting it produces a confident, wrong failure. Prove
# the positive direction here.
#
# Echoes a count, or ERR:<why>. A caller that cannot get a number must not treat
# that as a pass.
tt_draft_count() {
  local xp="//Main.AssignmentEntry[Main.AssignmentEntry_Assignment/Main.Assignment/Main.Assignment_Project/Main.Project/Name = '$1'][Main.AssignmentEntry_Assignment/Main.Assignment/Main.Assignment_Account/Administration.Account/Name = '$2'][Status = 'Draft']"
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"$xp\", filter:{amount:500}, callback: function(objs){ clearTimeout(t); res(String((objs||[]).length)); }, error: function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e) { res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}


# ---------------------------------------------------------------------------
# Line-item name guards
#
# "Add Task" COMMITS a Main.LineItem immediately with an EMPTY Name, and the name
# is filled afterwards. Main.LineItem.Name is a REQUIRED validation and a timesheet
# week saves as ONE unit — so a single unnamed line item makes the entire week
# unsaveable, for every project on it, not just the one that owns the task.
#
# The consequences land nowhere near the cause. An interrupted TT-654 task-add left
# one unnamed row behind, after which verify-tt654-a2 and -a5 reported "row is still
# editable after Submit" and the MCP SubmitWeek returned "The timesheet could not be
# saved" — three tests, two independent submit paths, all reading like a product or
# MCP fault that did not exist.
#
# Use tt_assert_task_named right after naming a task, and tt_assert_no_unnamed_tasks
# before any submit.

# tt_assert_task_named <rows-selector> <idx> <expected-name>
# Read the name back. The fills that set it are usually silenced with 2>/dev/null,
# which hides the one error that matters (a strict-mode violation refuses the write
# outright), so a read-back is the only proof it landed.
tt_assert_task_named() {
  local rows="$1" idx="$2" want="$3" got
  got="$(playwright-cli eval "() => { const els=document.querySelectorAll('$rows .mx-name-txtLineItemName input'); const el=els[$idx-1]; return el ? (el.value||'') : '__MISSING__'; }" 2>/dev/null | _tt_eval_str)"
  [ "$got" = "$want" ] || tt_fail "task #$idx name did not stick (wanted '$want', got '$got'). An unnamed line item makes this ENTIRE week unsaveable for every project on it — clear the week before retrying."
}

# tt_assert_no_unnamed_tasks <rows-selector>
# Refuse to proceed while any line item on this week has an empty Name.
tt_assert_no_unnamed_tasks() {
  local rows="$1" bad
  bad="$(playwright-cli eval "() => { const els=[...document.querySelectorAll('$rows .mx-name-txtLineItemName input')]; return els.map((e,i)=>[i+1,(e.value||'').trim()]).filter(p=>!p[1]).map(p=>'#'+p[0]).join(','); }" 2>/dev/null | _tt_eval_str)"
  [ -z "$bad" ] || tt_fail "unnamed line item(s) $bad on this week — Main.LineItem.Name is required, so the week cannot be saved and EVERY project on it will fail to submit. Almost certainly debris from an interrupted run; clear the week and retry."
}

# _tt_eval_str — decode a `playwright-cli eval` result read from stdin.
#
# playwright-cli prints:
#     ### Result
#     "the JSON-encoded return value"
#     ### Ran Playwright code
#     ```js …```
#
# So the WHOLE result is on line 2, JSON-encoded — embedded newlines arrive as a
# literal \n, and quotes as \". Readers that used `sed -n '2,$p'` swallowed the
# "### Ran Playwright code" trailer as if it were data (verify-tt683-a2 failed
# with '### Ran Playwright code' as a PDF filename), and readers that never
# unescaped produced \"result\":\"SUBMITTED\", which no test's substring match
# could ever hit.
#
# Single-line callers can keep using `sed -n '2p' | tr -d '"'`; this is for
# results that are multi-line or contain quotes.
_tt_eval_str() {
  local raw
  raw="$(sed -n '2p' | sed -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g')"
  printf '%b\n' "$raw"
}

# tt_wait_for <css-selector> [label] — wait up to ~20s for the selector to appear.
tt_wait_for() {
  local sel="$1" label="${2:-$1}"
  local _
  for _ in $(seq 1 20); do
    if playwright-cli eval "() => String(!!document.querySelector('$sel'))" 2>/dev/null | grep -qiw true; then
      return 0
    fi
    sleep 1
  done
  tt_fail "timed out waiting for: $label"
}

# tt_click_text <exact-text> [label] — click the first clickable (cursor:pointer)
# element whose trimmed text equals <exact-text>. For auto-named controls (e.g. the
# HR/TM dashboard tab strips, which were not part of the widget-naming pass).
# <exact-text> must not contain a single quote.
tt_click_text() {
  local txt="$1" label="${2:-$1}"
  local r
  r=$(playwright-cli eval "() => { const el=[...document.querySelectorAll('h4,h5,div,span,a,button,li')].find(e => (e.innerText||'').trim()==='$txt' && getComputedStyle(e).cursor==='pointer'); if (el) { el.click(); return 'ok'; } return 'none'; }" 2>/dev/null | sed -n '2p' | grep -iw ok || true)
  [ -n "$r" ] || tt_fail "clickable element with text '$txt' not found ($label)"
  sleep 2
}

# tt_try_click_text <exact-text> — tt_click_text without the tt_fail: returns 1
# when nothing matches, so a caller that has somewhere else to look can move on.
#
# tt_click_text EXITS THE WHOLE TEST when it misses, which makes it the wrong
# tool for a loop over candidate targets. tt_hr_reject_project walks three HR
# tabs looking for a card, and with the fatal version a dashboard missing one of
# those captions killed the run instead of trying the next tab — and killed it
# silently, because the caller had redirected stderr away.
tt_try_click_text() {
  local txt="$1"
  playwright-cli eval "() => { const el=[...document.querySelectorAll('h4,h5,div,span,a,button,li')].find(e => (e.innerText||'').trim()==='$txt' && getComputedStyle(e).cursor==='pointer'); if (el) { el.click(); return 'ok'; } return 'none'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok || return 1
  sleep 2
  return 0
}

# _tt_login_form_variant — which sign-in form is on screen right now:
#   'old' = the stock Mendix /login.html form (#usernameInput)
#   'new' = the custom Core.Login page (mx widgets, input.form-control)
#   ''    = neither appeared
# Budget: each pass costs two evals, so 15 tries was roughly 15-20 seconds. That is
# plenty against a warm app and not nearly enough against a cold one. The very first
# login of a CI run lands on a Mendix Cloud environment that may not have served a
# request in days, and the suite's own ordering makes verify-00-fixtures that first
# caller -- "-" sorts before "0", so it precedes the clear step. It failed with
# "login form not found" while every later login in the same run succeeded, which is
# the signature of a cold start rather than a broken account.
#
# The runner's health check does not cover this: it curls the index and gets a 200
# back long before the client has booted far enough to render a login form.
#
# Raised to 60. It costs nothing on the happy path, because it returns the moment a
# form appears; it only spends the time when the alternative is failing the run.
#
# TRIES IS A PARAMETER because the caller probes TWO locations. Spending the full
# cold-start budget on /login.html before even looking at the app's own page is how
# verify-000-testdata-clear-before came to eat its whole 4m timeout: each pass costs
# two evals plus a sleep, so 60 tries is 2-3 minutes of waiting for a form that this
# environment does not serve there at all. Give the first probe a short budget and
# the second the long one -- a cold start is still covered, because the app has to
# boot before EITHER page renders a form.
_tt_login_form_variant() {
  local _ tries="${1:-60}"
  for _ in $(seq 1 "$tries"); do
    if playwright-cli eval "() => String(!!document.querySelector('#usernameInput'))" 2>/dev/null | grep -qiw true; then
      echo "old"; return 0
    fi
    if playwright-cli eval "() => String(!!document.querySelector('input.form-control[type=password]'))" 2>/dev/null | grep -qiw true; then
      echo "new"; return 0
    fi
    sleep 1
  done
  echo ""
}

# _tt_login_submit <variant> <user> <pass> <ready>
# Fill and submit the form on screen, then wait for the outcome. Exit codes:
#   0 signed in and the dashboard shows <ready>
#   1 credentials rejected ("… is incorrect")
#   2 authenticated but the app demands a password change (Core.Force_PasswordReset)
#   3 none of the above before the timeout
#
# 1 and 2 used to be one branch, reported as "incorrect password or forced
# reset". That conflation cost real debugging time: a VALID admin credential
# that the stock form refuses looks identical to a wrong one, so the obvious
# reading ("the password is wrong") is exactly the wrong conclusion. Keep them
# distinct.
_tt_login_submit() {
  local variant="$1" user="$2" pass="$3" ready="$4" _
  if [ "$variant" = "old" ]; then
    playwright-cli fill "#usernameInput" "$user" >/dev/null 2>&1
    playwright-cli fill "#passwordInput" "$pass" >/dev/null 2>&1
    playwright-cli click "#loginButton" >/dev/null 2>&1
  else
    playwright-cli fill "input.form-control[type=text]" "$user" >/dev/null 2>&1
    playwright-cli fill "input.form-control[type=password]" "$pass" >/dev/null 2>&1
    playwright-cli click ".mx-name-actionButton1" >/dev/null 2>&1
  fi

  for _ in $(seq 1 60); do
    if playwright-cli eval "() => String(location.pathname.indexOf('index.html') >= 0 && document.body.innerText.indexOf('$ready') >= 0)" 2>/dev/null | grep -qiw true; then
      return 0
    fi
    # Core.Force_PasswordReset: "In order to proceed with the Titan Timesheet
    # App, you must reset your password."
    if playwright-cli eval "() => String(/you must reset your password/i.test(document.body ? document.body.innerText : ''))" 2>/dev/null | grep -qiw true; then
      return 2
    fi
    # BOTH forms' rejection wordings. "is incorrect" is the stock /login.html
    # message; the custom Core.Login page raises an Information popup reading
    # "Invalid Credentials" instead, which this used to miss entirely -- so a
    # plainly rejected password fell through to the timeout below and was reported
    # as exit 3, "signed in via Core.Login but never reached a dashboard showing
    # '<ready>'". That sentence claims the sign-in worked and blames the ready text,
    # which is the opposite of what happened. It sent an investigation of
    # verify-000-testdata-clear-before at the landing-page wait in
    # tt_open_testdata_admin, when the account simply could not sign in (dev,
    # 2026-08-31: MxAdmin at the root URL, "Invalid Credentials").
    if playwright-cli eval "() => String(/is incorrect|invalid credentials/i.test(document.body ? document.body.innerText : ''))" 2>/dev/null | grep -qiw true; then
      return 1
    fi
    sleep 2
  done
  return 3
}

# tt_login <username> <ready-text> [password]
#
# Tries the stock /login.html form first, and FALLS BACK to the app's own
# Core.Login page at / if that form rejects the credentials.
#
# Why the fallback exists: on dev, MxAdmin authenticates fine against /xas/ but
# the stock /login.html form answers "The username or password you entered is
# incorrect" for the very same credentials, so every admin-dependent test was
# unrunnable there. The custom Core.Login page is the sign-in path the app
# actually ships (and the one a human uses), so when the legacy form refuses,
# the app's own page gets a turn before the test is allowed to fail.
#
# The fallback cannot mask a genuinely wrong password: it only runs after a
# rejection, and if the app's own page rejects too, the failure names both
# attempts.
# ---------------------------------------------------------------------------
# Authentication state cache
#
# Every one of the 50 scripts used to call tt_login, and tt_login always did a
# full logout + form sign-in. Against Mendix Cloud that is ~50 sequential
# round-trip logins and it dominated the run: the first CI run spent 40+ minutes
# and was still going. There are only about four distinct identities in the
# suite, so the other ~46 logins are pure overhead.
#
# tt_login now replays a saved storage state when one exists for that identity,
# and only falls back to the real form sign-in when there is no state or the
# state no longer works. Correctness rule: the fast path must PROVE it landed
# authenticated on the expected dashboard, and on any doubt it deletes the cache
# entry and lets the full sign-in run. A stale session must never look like a
# pass.
#
# Set TT_AUTH_CACHE=0 to force the full form login — verify-smoke-login does
# this, because testing the login flow is the whole point of that script.
TT_AUTH_DIR="${TT_AUTH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.auth}"

# Key on user AND base URL, so a cache written against localhost is never
# replayed against dev/acceptance.
_tt_auth_file() {
  local key
  key="$(printf '%s@%s' "$1" "$TT_BASE" | tr -c 'A-Za-z0-9._@-' '_')"
  printf '%s/%s.json\n' "$TT_AUTH_DIR" "$key"
}

_tt_auth_try() {
  local user="$1" ready="$2" f i
  [ "${TT_AUTH_CACHE:-1}" = "1" ] || return 1
  f="$(_tt_auth_file "$user")"
  [ -s "$f" ] || return 1

  playwright-cli state-load "$f" >/dev/null 2>&1 || return 1
  playwright-cli goto "$TT_BASE/" >/dev/null 2>&1 || return 1

  # Landing text alone is NOT enough. Two roles can share a landing string, and a
  # replayed cookie can belong to whoever was logged in when it was written - so a
  # cache hit could hand a test the wrong identity while looking perfectly healthy.
  # Every assertion downstream would then be describing the wrong user. Check WHO
  # the session actually belongs to as well, the same way lib/_seed.sh does.
  local r
  for i in $(seq 1 10); do
    r="$(playwright-cli eval "() => { let n=''; try { n = mx.session.userObject.jsonData.attributes.Name.value; } catch (e) {} const landed = document.body ? document.body.innerText.indexOf('$ready') >= 0 : false; if (n && n !== '$user') return 'WHO:' + n; return String(n === '$user' && landed); }" 2>/dev/null | _tt_eval_str)"
    case "$r" in
      true)   return 0 ;;
      WHO:*)  echo "  (cached session belonged to ${r#WHO:}, not $user - logging in properly)" >&2
              break ;;
    esac
    sleep 1
  done

  rm -f "$f"   # expired or wrong — drop it so we do not retry it all run
  return 1
}

_tt_auth_save() {
  local f
  [ "${TT_AUTH_CACHE:-1}" = "1" ] || return 0
  f="$(_tt_auth_file "$1")"
  mkdir -p "$TT_AUTH_DIR" 2>/dev/null || return 0
  playwright-cli state-save "$f" >/dev/null 2>&1 || true
}

# tt_login <username> <ready-text> [password]
# Replays a cached session when possible; otherwise signs in for real and caches
# the result. Same signature and same failure behaviour as before.
tt_login() {
  local user="$1" ready="$2" pass="${3:-$TT_PASS}"

  if _tt_auth_try "$user" "$ready"; then
    return 0
  fi

  _tt_login_interactive "$user" "$ready" "$pass"   # tt_fail's on failure
  _tt_auth_save "$user"
  return 0
}

# The original full sign-in: logout, find the form variant, submit, fall back to
# Core.Login. Unchanged apart from the name.
_tt_login_interactive() {
  local user="$1" ready="$2" pass="${3:-$TT_PASS}"
  local variant rc

  playwright-cli cookie-clear >/dev/null 2>&1
  playwright-cli goto "$TT_BASE/login.html" >/dev/null 2>&1
  sleep 1
  # If cookie-clear didn't drop the (httpOnly) session, we get bounced into the app.
  # Force a client-side logout, then return to the login page.
  if playwright-cli eval "() => String(!document.querySelector('#usernameInput') && !document.querySelector('input.form-control[type=password]'))" 2>/dev/null | grep -qiw true; then
    playwright-cli eval "() => { if (window.mx && mx.logout) mx.logout(); }" >/dev/null 2>&1
    sleep 3
    playwright-cli goto "$TT_BASE/login.html" >/dev/null 2>&1
  fi

  # /login.html first, on a SHORT budget, then the app's own page on the long one.
  #
  # WHY BOTH, IN THIS ORDER. Some accounts are not offered the stock form at all --
  # measured on dev 2026-08-31, MxAdmin's /login.html served no #usernameInput and no
  # password field for the full 60-try probe, while $TT_BASE/ rendered Core.Login
  # immediately. This used to tt_fail right here with "login form not found at
  # .../login.html", never trying the page that works, after burning ~2-3 minutes
  # doing it. Falling through costs nothing when /login.html does work: the probe
  # returns the moment a form appears.
  variant="$(_tt_login_form_variant 10)"
  if [ -z "$variant" ]; then
    echo "  ($user: no form at /login.html — going to the app's own sign-in page)"
    playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
    sleep 2
    variant="$(_tt_login_form_variant 10)"
    if [ -z "$variant" ]; then
      # Same trap the /login.html block above handles: cookie-clear does not always
      # drop the (httpOnly) session, and the ROOT url of a signed-in session renders
      # the app, not Core.Login. Without this the fallback reports "no sign-in page
      # at either location" purely because the previous test was still logged in.
      playwright-cli eval "() => { if (window.mx && mx.logout) mx.logout(); }" >/dev/null 2>&1
      sleep 3
      playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
      sleep 2
      variant="$(_tt_login_form_variant)"
    fi
    [ -n "$variant" ] || tt_fail "$user: no login form at $TT_BASE/login.html OR $TT_BASE/ — the app did not render a sign-in page at either location."
  fi

  _tt_login_submit "$variant" "$user" "$pass" "$ready"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    2) tt_fail "$user: the credentials were accepted but the app demands a password change (Core.Force_PasswordReset). Clear the reset flag on this account, or point TT_ADMIN_USER at an admin that does not have it — a test cannot complete the reset without changing the password out from under you." ;;
  esac

  # Fallback: the app's own sign-in page.
  if [ "$variant" = "old" ]; then
    echo "  ($user: /login.html refused — retrying on the app's own Core.Login page)"
    playwright-cli cookie-clear >/dev/null 2>&1
    playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
    sleep 2
    local variant2
    variant2="$(_tt_login_form_variant)"
    if [ "$variant2" = "new" ]; then
      _tt_login_submit "$variant2" "$user" "$pass" "$ready"
      rc=$?
      case "$rc" in
        0) return 0 ;;
        2) tt_fail "$user: the credentials were accepted but the app demands a password change (Core.Force_PasswordReset). Clear the reset flag on this account, or point TT_ADMIN_USER at an admin that does not have it." ;;
        1) tt_fail "$user: rejected by BOTH the stock /login.html form and the app's own Core.Login page — the password really is wrong for this account on $TT_BASE." ;;
        *) tt_fail "$user: signed in via Core.Login but never reached a dashboard showing '$ready'." ;;
      esac
    fi
    tt_fail "$user: /login.html rejected the credentials and no Core.Login form was found at $TT_BASE/ to retry against."
  fi

  case "$rc" in
    1) tt_fail "$user: credentials rejected by the Core.Login form on $TT_BASE." ;;
    *) tt_fail "$user: did not reach dashboard (expected text '$ready')" ;;
  esac
}

# tt_wait_text <text> [label] [tries]
#
# Poll until <text> appears anywhere in the page body. Use this INSTEAD of
# tt_assert_all for the first assertion that depends on an asynchronously loaded
# widget -- a gallery or list backed by a microflow data source.
#
# tt_assert_all is deliberately single-shot: one indexOf, no retry. That is right
# for content already on screen, and wrong for content still being fetched.
#
# Wait once for the slow thing, then assert the rest single-shot as before.
#
# WHAT THIS HELPER CANNOT DO. It only waits; it never makes the page load more. The
# note that used to sit here blamed verify-pm-dashboard-pending's managed-project
# failure on render timing and claimed the project was "one of only 10 that PM
# manages, well inside any page size". Both halves were wrong. That gallery pages at
# THREE with virtual scrolling, so 'E2E Customer Approval' was not in the DOM at all
# and no amount of waiting could ever find it. When the target lives in a gallery,
# reach for tt_gallery_load_until_text below instead -- a text wait against a paged
# list fails after the full timeout and reads exactly like slow data.
tt_wait_text() {
  local needle="$1" label="${2:-$1}" tries="${3:-20}" i
  for i in $(seq 1 "$tries"); do
    if playwright-cli eval "() => String(document.body.innerText.indexOf('$needle') >= 0)" 2>/dev/null | grep -qiw true; then
      return 0
    fi
    sleep 1
  done
  tt_fail "timed out waiting for text: $label"
}

tt_assert_all() {
  local label="$1"; shift
  local s
  for s in "$@"; do
    playwright-cli eval "() => String(document.body.innerText.indexOf('$s') >= 0)" 2>/dev/null | grep -qiw true \
      || tt_fail "$label: expected text not found: '$s'"
  done
}

# ------------------------------------------------------------------ gallery paging
#
# WHY THIS EXISTS. A Mendix Gallery renders ONLY the page it has loaded, so a bare
# read of its innerText answers "is my row on the first page", not "is my row in
# this list". The two are indistinguishable in the output, and this suite has twice
# shipped a confident wrong diagnosis off the difference. Everything below exists so
# a caller can page a gallery IN before it reads it.
#
# THE APP USES TWO PAGINATION MODES, AND THEY PAGE DIFFERENTLY.
#
#   Pagination = "Virtual scrolling"  ->  .widget-gallery-content carries the extra
#     class `infinite-loading`, the widget listens for scroll on THAT box, and the
#     next page arrives only when it is scrolled:
#         scrollHeight - 30 - scrollTop <= clientHeight + 2   ->  setPage(p + 1)
#     Scrolling the window does nothing and there is no control to click.
#
#   Pagination = "Load more"          ->  no scroll handler and no `infinite-loading`
#     class at all. The widget renders <button class="widget-gallery-load-more-btn">
#     in its footer, and ONLY while more items exist -- when the button is gone, the
#     list is complete. Scrolling this one loads nothing, ever.
#
# Both are live in this app right now, so nothing here may assume either. Model
# commit b05c11d2 ("layout grid changes") moved the dashboards' content galleries to
# Load more with pageSize 25 -- Main.ProjectManagerDashboard's projects gallery1 and
# galPMPendingEntries, Main.HRDashboard's galPending / galManagerEntries /
# galClientEntries / galProcessEntries / galSentEntries / galInvoiceEntries, plus
# galProjects, galConsultants, galCustomers and galTimesheetHistory -- while the week
# and month pickers (galAvailableWeeks, galAvailableMonths), galAssignmentRows,
# galExpenseAttachments and galLineItems stayed on virtual scrolling.
#
# That flip is what broke verify-pm-dashboard-pending: the helper used to REQUIRE
# `.widget-gallery-content.infinite-loading` and tt_fail when it was missing, so the
# test died at the guard on a gallery that was, by then, already showing every card
# it had. _tt_gallery_page_in below asks what the gallery offers instead of assuming.
#
# HISTORY WORTH KEEPING. The projects gallery was virtual scrolling with pageSize 3
# and Main.DS_ProjectsManaged sorts createdDate DESCENDING, so once dev accumulated
# more E2E projects, 'E2E Customer Approval' left the DOM entirely and the test
# failed on a text wait that could never succeed -- read for days as a rendering
# delay. At pageSize 25 it is back on the first page, but the paging call stays: the
# page size is a model property and the next change to it is not this suite's to
# notice.

# _tt_gallery_page_in <gallery-css> <max-rounds> [stop-text]
#
# Page a gallery all the way in -- clicking Load more or scrolling the virtual box,
# whichever it has -- and echo `mode|count|found|titles`. Stops early when
# [stop-text] turns up inside the gallery. `mode` is what it used to page: loadMore,
# scroll, or single (nothing to page: one page is the whole list).
#
# ONE eval FOR THE WHOLE LOOP, DELIBERATELY. Each playwright-cli call is a fresh
# node process -- ~2.6s measured -- so a bash loop around a per-round eval spends its
# budget on process startup, which is what killed verify-tt692693-c2-zero-hours
# before efec776 folded that loop in-page. Do not unroll this back into bash.
_tt_gallery_page_in() {
  local gal="$1" rounds="${2:-12}" needle="${3:-}"
  playwright-cli eval "async () => {
    const gs = document.querySelectorAll('$gal');
    if (gs.length !== 1) return 'COUNT:' + gs.length;
    const g = gs[0];
    const needle = '$needle';
    const items = () => g.querySelectorAll('.widget-gallery-item').length;
    const has = () => needle !== '' && (g.innerText || '').indexOf(needle) >= 0;
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    // Advance one page by whichever mechanism this gallery actually has. The Load
    // more button is tried first because it is the positive signal: it exists only
    // while the widget still has items to fetch.
    const advance = () => {
      const b = g.querySelector('.widget-gallery-load-more-btn');
      if (b) { b.click(); return 'loadMore'; }
      const c = g.querySelector('.widget-gallery-content.infinite-loading');
      if (c) { c.scrollTop = c.scrollHeight; c.dispatchEvent(new Event('scroll', { bubbles: true })); return 'scroll'; }
      return 'single';
    };
    // A gallery mid-fetch has no cards AND no button, which is indistinguishable
    // from a finished empty one. Wait for the first page before concluding anything.
    for (let i = 0; i < 15 && items() === 0 && !g.querySelector('.widget-gallery-load-more-btn'); i++) await sleep(1000);
    let mode = 'single', stuck = 0;
    for (let r = 0; r < $rounds; r++) {
      if (has()) break;
      const before = items();
      mode = advance();
      if (mode === 'single') break;            // nothing left to page: list complete
      await sleep(2000);
      if (items() === before) { if (++stuck >= 2) break; } else stuck = 0;
    }
    const titles = [...g.querySelectorAll('.widget-gallery-item')].map(e => (((e.innerText || '').split('\n').find(s => s.trim())) || '(blank)').trim());
    return [mode, items(), String(has()), titles.join(', ') || '(no cards)'].join('|');
  }" 2>/dev/null | _tt_eval_str
}

# tt_gallery_load_until_text <gallery-css> <text> [label] [max-rounds]
#
# Page a gallery until <text> is inside it, or until the gallery runs out of pages.
# <gallery-css> must resolve to EXACTLY ONE element -- the helper refuses to guess
# which of several lists to page, because paging the wrong one looks identical to a
# missing row. <text> must not contain a single quote.
#
# Fails (via tt_fail) when the text never turns up, naming every card it did load.
tt_gallery_load_until_text() {
  local gal="$1" needle="$2" label="${3:-$2}" rounds="${4:-12}"
  local r mode count found titles

  r="$(_tt_gallery_page_in "$gal" "$rounds" "$needle")"
  case "$r" in
    COUNT:0)  tt_fail "$label: no gallery matches '$gal'" ;;
    COUNT:1)  tt_fail "$label: could not page '$gal' (the selector matched, then the read came back empty)" ;;
    COUNT:*)  tt_fail "$label: '$gal' matches ${r#COUNT:} elements -- scope it to one gallery; this helper will not guess which list to page" ;;
    *'|'*)    ;;
    *)        tt_fail "$label: could not read '$gal' (got [$r])" ;;
  esac

  mode="${r%%|*}";  r="${r#*|}"
  count="${r%%|*}"; r="${r#*|}"
  found="${r%%|*}"
  titles="${r#*|}"

  if [ "$found" = "true" ]; then
    echo "  [$label] '$needle' is loaded -- $count card(s), pagination: $mode"
    return 0
  fi

  echo "  [$label] cards loaded: $titles" >&2
  [ "$count" != "0" ] \
    || tt_fail "$label: '$gal' rendered no cards at all (pagination: $mode). The gallery is on the page but its data source returned nothing -- missing data or a filter, not a paging problem."
  tt_fail "$label: '$needle' is not in '$gal' after loading $count card(s) and running out of pages (pagination: $mode). The gallery paged to the end, so this is missing data or a wrong name -- not a paging problem."
}

# _tt_gallery_count <gallery-css> — how many cards are currently in the DOM.
_tt_gallery_count() {
  playwright-cli eval "() => String(document.querySelectorAll('$1 .widget-gallery-item').length)" 2>/dev/null | _tt_eval_str
}

# _tt_gallery_has_text <gallery-css> <text> — 'true' when the text is inside THIS
# gallery. Scoped deliberately: the page body carries other sections (the PM
# dashboard's Pending Approval list names projects too), so a body-wide check
# answers a different question than the one the caller is asking.
_tt_gallery_has_text() {
  playwright-cli eval "() => { const g = document.querySelector('$1'); return String(!!g && (g.innerText || '').indexOf('$2') >= 0); }" 2>/dev/null | _tt_eval_str
}

# tt_gallery_load_all <gallery-css> [label] [max-rounds]
# Page a gallery until it stops producing new cards, then echo the final card count.
# Never fails: a missing gallery echoes 0.
#
# THE ABSENCE-SAFE SIBLING of tt_gallery_load_until_text. That one stops as soon as
# it sees the text it wants and tt_fail's when it does not, which is right for "wait
# for my row" and wrong for every caller that must be able to conclude a row is NOT
# there -- walking weeks looking for a match, or asserting a tab renders none. Those
# callers need the whole list loaded and then a plain answer, so they get this.
#
# WHY THE TT-647 HELPERS NEEDED IT. Main.SNIP_HRDashboardTab's galTabEntries was
# virtual-scrolling with pageSize 4, and every tt647_* helper read
# .mx-name-galTabEntries (as it then was) innerText straight out of the DOM. Measured on dev
# 2026-08-31, every week on WEEKLY TO PROCESS rendered exactly 4 cards while its own
# heading said "Weekly Timesheets to Process (5)"; one scroll of the content box took
# the count 4 -> 5. So the FIFTH entry in any week was invisible to the suite.
#
# That is the whole of the verify-tt647-a3 failure. Its seed submitted a zero-hour
# week correctly -- the entries really did reach ToProcess, verified against dev at
# the data layer -- but they sorted past position 4 and never rendered, so
# tt647_wait_for_card polled the same first four cards for 60s and
# tt647_locate_entry then reported "(none of the three HR tabs)" using the same blind
# read. The log's tell is cardsInSelectedWeek=4 BEFORE the seed and still 4 after two
# more entries landed in that same week. It reads exactly like a routing defect in
# Main.ACT_Timesheet_Submit and is not.
#
# Those galleries are Load more with pageSize 25 today, so one page is usually the
# whole week. That is a data-volume accident, not a guarantee, and it is exactly the
# margin that vanished last time -- keep paging.
tt_gallery_load_all() {
  local gal="$1" label="${2:-$1}" rounds="${3:-12}" r

  r="$(_tt_gallery_page_in "$gal" "$rounds")"
  case "$r" in
    *'|'*) ;;
    *) echo 0; return 0 ;;      # deliberately silent and non-fatal: callers use
  esac                          # this defensively, before a read
  r="${r#*|}"
  echo "${r%%|*}"
}

# tt_gallery_titles <gallery-css> — the first line of each loaded card, comma
# separated. For diagnostics: "what did the gallery actually show me".
tt_gallery_titles() {
  playwright-cli eval "() => [...document.querySelectorAll('$1 .widget-gallery-item')].map(e => (((e.innerText || '').split('\n').find(s => s.trim())) || '(blank)').trim()).join(', ') || '(no cards)'" 2>/dev/null | _tt_eval_str
}

# tt_combobox_sorted <combobox-css> <dismiss-css> <label>
# Opens the (Mendix pluggable) combobox, asserts its rendered option list has >=2
# items in ascending (case-insensitive) order, then clicks <dismiss-css> — a neutral
# field on the same form — to close the dropdown WITHOUT closing the popup.
# (Escape closes the whole popup, so we never use it.)
#
# THE TWO FAILURE MODES ARE REPORTED SEPARATELY, deliberately. This used to emit one
# message for both -- "not sorted ascending (or fewer than 2 options)" -- and on
# 2026-09-03 a completely EMPTY picker was reported as a sorting regression: the
# Create Timesheet consultant picker (cbCreateForAccount) had an [Active] XPath
# constraint that returned zero rows for the HR role, because Active is an inherited
# System.User member HR cannot read and Mendix silently returns nothing for a
# constraint on an unreadable member. Fifteen seconds of triage went to the sort.
# The two causes have nothing in common: an empty list is a data-source, XPath or
# entity-access problem, and a full list in the wrong order is a sort-key problem.
# Say which one it is.
#
# The eval result is read from line 2 via _tt_eval_str, never grepped out of the whole
# output: playwright-cli echoes the SOURCE it ran, so a grep for a literal appearing in
# the snippet matches that echo rather than the return value, and passes no matter what
# actually happened.
tt_combobox_sorted() {
  local cb="$1" dismiss="$2" label="$3" r n ordered rendered
  playwright-cli click "$cb" >/dev/null 2>&1
  sleep 1
  # "<count>|<true|false>|<the options, comma separated>"
  r="$(playwright-cli eval "() => { const o=[...document.querySelectorAll('[role=option]')].map(e=>e.innerText.trim()).filter(Boolean); const s=o.every((n,i)=>i===0||o[i-1].toLowerCase().localeCompare(n.toLowerCase())<=0); return o.length + '|' + s + '|' + o.join(', '); }" 2>/dev/null | _tt_eval_str)"
  playwright-cli click "$dismiss" >/dev/null 2>&1

  n="${r%%|*}"
  ordered="${r#*|}"; ordered="${ordered%%|*}"
  rendered="${r#*|*|}"

  case "$n" in
    ''|*[!0-9]*)
      tt_fail "$label: could not read the dropdown's options at all -- the eval returned '$r'. The combobox probably never opened." ;;
  esac

  if [ "$n" -lt 2 ]; then
    tt_fail "$label: the dropdown rendered $n option(s), expected at least 2 -- it came back empty or near-empty. This is NOT an ordering problem. Check the data source's XPath constraint, and whether the role this test logs in as can READ every attribute that constraint names: a constraint on an unreadable member returns zero rows with no error. Rendered: ${rendered:-(nothing)}"
  fi

  if [ "$ordered" != "true" ]; then
    tt_fail "$label: dropdown options are not in ascending order. Rendered: $rendered"
  fi
  sleep 1
}

# tt_combobox_select_first <combobox-css>
# Opens the combobox and clicks its first option (used to drive cascading forms
# where dependent dropdowns only populate after a selection). Selecting an option
# closes the dropdown, so no dismiss is needed.
tt_combobox_select_first() {
  local cb="$1"
  playwright-cli click "$cb" >/dev/null 2>&1
  sleep 1
  playwright-cli eval "() => { const o = document.querySelector('[role=option]'); if (o) { o.click(); return 'ok'; } return 'none'; }" >/dev/null 2>&1
  sleep 2
}

# tt_combobox_select_text <combobox-css> <option-text>
# Opens the combobox and clicks the option whose text starts with <option-text>.
# Returns 1 if no such option rendered.
#
# The result is read from line 2, never grepped from the whole output: the
# echoed SOURCE contains the literal 'true', so a plain grep would match the
# snippet rather than its return value and pass no matter what happened.
tt_combobox_select_text() {
  local cb="$1" want="$2"
  playwright-cli click "$cb" >/dev/null 2>&1
  sleep 1
  if playwright-cli eval "() => { const o=[...document.querySelectorAll('[role=option]')].find(e=>(e.innerText||'').trim().indexOf('$want')===0); if(o){o.click(); return 'true';} return 'false'; }" 2>/dev/null \
       | sed -n '2p' | grep -qi true; then
    sleep 2; return 0
  fi
  return 1
}

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
  s="$(playwright-cli eval "() => { const val=sel=>{ const w=document.querySelector(sel); if(!w) return '(absent)'; const i=w.querySelector('input,select'); const v=(i&&i.value)||''; const txt=(w.innerText||'').replace(/\\s+/g,' ').trim(); return v || txt || '(empty)'; }; const wk=document.querySelector('$TT_HR_GAL_WEEKS'); const weeks=wk?[...new Set([...wk.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} /.test(t)))]:[]; const g=document.querySelector('$TT_HR_GAL_ENTRIES'); return 'weekPicker=' + (wk?'present':'ABSENT') + ' | entriesGallery=' + (g?'present':'ABSENT') + ' | consultantFilter=' + val('$TT_HR_CB_CONSULTANT') + ' | projectFilter=' + val('$TT_HR_CB_PROJECT') + ' | weeks(' + weeks.length + ')=' + (weeks.join(', ') || '(none)') + ' | remindCards=' + document.querySelectorAll('$TT_HR_BTN_REMIND').length; }" 2>/dev/null | _tt_eval_str)"
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
# Costco). The approval token is per PROJECT, so reminding an unscoped entry emails
# a token for some other customer, and a caller asserting a fixed customer name on
# the token page fails on data selection rather than on anything the product did.
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
  # Say what the tab was actually showing. Without this the caller can only report
  # "no pending entry", which asserts a cause this function never checked.
  _tt_hr_tab_state "no pending '$who'${proj:+ / '$proj'} card in any listed week"
  return 1
}

# ---------------------------------------------------------------------------
# Anonymous customer-approval (token) page helpers
#
# WHAT A ROW IS, AND WHAT IDENTIFIES IT. Main.Customer_Approval renders one
# gallery row per pending entry, and that row contains exactly three readable
# things: the consultant name, "<n> hours", and the period. It does NOT contain
# the project name — that is a single heading above the gallery, in the page's
# project data view, far more than ten DOM levels away from the row's buttons.
#
# So a row is identified by CONSULTANT + WEEK, and nothing else is available.
# That is sufficient, because the token page is scoped to ONE PROJECT already:
# Main.DS_Project_ByToken turns the token into a single Project, and the
# gallery's Main.DS_ApprovalHelper_Customer retrieves
#   [...Main.Assignment_Project = $Project][Status = 'AwaitingCustomerApproval']
# There is nothing on the page belonging to another project to disambiguate.
#
# Do NOT reintroduce a project-name match here. A predicate requiring the
# project inside a row can never be true, and when one was added it made the
# row-open step fail every run ("the token page lists entries but none for week
# X") while simultaneously making the did-it-leave-the-queue poll pass instantly
# without ever observing the entry present. Both failure modes are silent.
#
# The walk is defined ONCE, below, so the logger and the matchers cannot drift
# apart about which ancestor the row is.
# ---------------------------------------------------------------------------

# _tt_token_row_js <consultantName> — emits the shared JS prelude.
#
# rowOf(btnView) walks up at most ten parents and returns the first ancestor
# whose text holds both the consultant and "hours" — i.e. the ancestor spanning
# BOTH lines of the row, which is the one carrying the period. (Deliberately not
# a text-length heuristic: the first line alone, "E2E Consultant ViewApprove",
# is 26 characters, so a >25 rule stops one level short and hides the week.)
#
# Emitted as ONE line on purpose. playwright-cli echoes the snippet source
# before its result and _tt_eval_str reads line 2, so a multi-line snippet would
# shift the result off the line every caller reads.
_tt_token_row_js() {
  printf '%s' "const who='$1';const rowOf=v=>{let p=v;for(let k=0;k<10;k++){if(!p.parentElement)break;p=p.parentElement;const t=p.innerText||'';if(t.indexOf(who)>=0&&t.indexOf('hours')>=0)return p;}return null;};const views=()=>[...document.querySelectorAll('.mx-name-btnView')];const txt=p=>((p&&p.innerText)||'').replace(/\u00a0/g,' ').replace(/\s+/g,' ').trim();"
}

# tt_token_log_rows <consultantName> — print every row the token page is
# offering, whole. When a match fails this is the evidence for why, so it must
# show the period; a partial row is what turned one bad predicate into days of
# looking for a product bug.
tt_token_log_rows() {
  local js; js="$(_tt_token_row_js "$1")"
  playwright-cli eval "() => { $js const g=document.querySelector('.mx-name-galPendingEntries'); if(!g) return '(no pending list)'; const rows=views().map(v=>{ const r=rowOf(v); return r ? txt(r).slice(0,160) : '(row text unavailable)'; }); return rows.length ? rows.join('  ||  ') : '(no rows)'; }" 2>/dev/null | _tt_eval_str | sed 's/^/  [token-page rows] /'
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

# ---------------------------------------------------------------------------
# Mail access
#
# The suite reads mail from the app's OWN ADMIN PAGE, not from an external mail
# catcher. Core.EmailsSent_Overview lists every Email_Connector.EmailMessage the
# app has produced, with its recipient, subject, status, error and body.
#
# Why this rather than a catcher:
#
#   * No infrastructure. Nothing to run, no host to expose, no secret to
#     configure, so the same test works unchanged on a laptop and against a
#     deployed environment. The mail tests were the only reason CI needed
#     anything beyond the app itself.
#   * The recipient is a column, so "sent to the wrong address" is DETECTABLE.
#     The catcher-based reader fell back to "the newest message, whoever it was
#     addressed to", which meant no test could ever catch a misdirected mail.
#   * Rows exist at QUEUED, before the ~2-minute send event runs, so a test can
#     assert that a mail was RAISED without waiting for it to be delivered.
#
# What it costs: the page is Core.Administrator-only, so reading mail means
# logging in as the administrator and losing whatever role session the test was
# using. Read mail at the END of a step, or log back in afterwards.
#
# Freshness is a HIGH-WATER MARK, not an emptied inbox. tt_mail_prepare records
# the rows that already exist; later reads consider only rows that were not there
# before. Nothing is deleted, so this is safe on a shared environment. Two limits
# follow, stated rather than hidden: two byte-identical mails collapse into one,
# and only rows the grid renders are visible - hence the newest-first sort below,
# which keeps fresh mail on the first page.
#
# Env:
#   TT_ADMIN_USER / TT_ADMIN_PASS  administrator account (already required)
#   TT_MAIL_DOMAIN                 domain for tt_mail_address (default e2e.local)
#   TT_MAIL_CUSTAPPROVAL_TAG       default recipient filter (default custapproval)
# ---------------------------------------------------------------------------

TT_MAIL_SEEN_FILE=""

_tt_mail_tag() {
  echo "${1:-${TT_MAIL_CUSTAPPROVAL_TAG:-custapproval}}"
}

_tt_mail_grid_up() {
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-gridEmailsSent'))" 2>/dev/null | _tt_eval_str
}

# _tt_mail_open - as the administrator, land on the Emails Sent grid.
_tt_mail_open() {
  local i
  [ "$(_tt_mail_grid_up)" = "true" ] && return 0
  tt_login "${TT_ADMIN_USER:-MxAdmin}" "Welcome to your homepage" "${TT_ADMIN_PASS:-${TT_PASS:-}}" || return 1
  playwright-cli click ".mx-name-cardEmailsSent" >/dev/null 2>&1
  for i in $(seq 1 20); do
    [ "$(_tt_mail_grid_up)" = "true" ] && return 0
    sleep 1
  done
  return 1
}

# _tt_mail_sort_newest - A DELIBERATE NO-OP. Do not "fix" it.
#
# It was written to sort by Sent Date descending so new mail lands on page one.
# It has never done that: it looks for a column header matching /sent\s*date/i,
# but the caption on Core.EmailsSent_Overview is the single word `Sent`, so it
# returns 'nocol' and clicks nothing - and every caller discards the result to
# /dev/null, so nobody noticed.
#
# MAKING IT WORK WOULD BREAK THE CALLERS. The grid's data source already sorts by
# SentDate DESCENDING by default, which is exactly what this was reaching for, so
# the no-op is accidentally correct. A working version would click the `Sent`
# header and TOGGLE that sort away from the default, on every call, inside
# _tt_mail_refresh and tt_mail_prepare - which tt_mail_token and tt_mail_message
# depend on. Left as-is on purpose. (Data Grid 2 also does not reliably emit
# aria-sort, so its success test is unsound even on its own terms.)
#
# It is also the wrong instrument. SentDate is stamped only on successful
# DELIVERY - Email_Connector.SUB_SendQueuedEmail sets it on its success branch
# only, and neither the error nor the max-attempts branch ever does - so a QUEUED
# or FAILED message has no SentDate at all, and no amount of sorting brings it to
# page one. To find a specific message, filter by recipient: see tt_mail_find.
_tt_mail_sort_newest() {
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-gridEmailsSent'); if(!g) return 'nogrid'; const hs=[...g.querySelectorAll('[role=columnheader], th')]; const h=hs.find(e=>/sent\\s*date/i.test((e.innerText||'').trim())); if(!h) return 'nocol'; for(let i=0;i<3;i++){ const s=(h.getAttribute('aria-sort')||'').toLowerCase(); if(s.indexOf('desc')===0) return 'desc'; (h.querySelector('[role=button],button')||h).click(); } return (h.getAttribute('aria-sort')||'unsorted'); }" 2>/dev/null | _tt_eval_str
}

# _tt_mail_rows - one line per rendered row, cells joined by " ~ ".
_tt_mail_rows() {
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-gridEmailsSent'); if(!g) return ''; return [...g.querySelectorAll('[role=row], tr')].map(r=>[...r.querySelectorAll('[role=gridcell], td')].map(c=>(c.innerText||'').replace(/\\s+/g,' ').trim()).join(' ~ ')).filter(s=>s.replace(/[ ~]/g,'').length>0).join('\\n'); }" 2>/dev/null | _tt_eval_str
}

# _tt_mail_refresh - re-read the grid without paying for a fresh login.
_tt_mail_refresh() {
  local i
  playwright-cli reload >/dev/null 2>&1
  for i in $(seq 1 15); do
    if [ "$(_tt_mail_grid_up)" = "true" ]; then
      _tt_mail_sort_newest >/dev/null 2>&1 || true
      return 0
    fi
    sleep 1
  done
  _tt_mail_open
}

# _tt_mail_new_rows - rows that were not present at tt_mail_prepare time.
_tt_mail_new_rows() {
  local cur
  cur="$(_tt_mail_rows)"
  if [ -s "${TT_MAIL_SEEN_FILE:-/dev/null}" ]; then
    printf '%s\n' "$cur" | grep -Fxv -f "$TT_MAIL_SEEN_FILE" 2>/dev/null || true
  else
    printf '%s\n' "$cur"
  fi
}

# _tt_mail_filter_rows - the rendered rows, as  <to>|||<status>|||<error>.
#
# Only the three cells a caller needs, so a body cell containing the separator
# cannot corrupt the split. Column order on the grid is Sent, To, Subject, Status,
# Error, Body (text), Body (HTML) - hence cells 1, 3 and 4.
# Prints NOGRID when the grid is not on screen, which is NOT the same as no rows.
_tt_mail_filter_rows() {
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-gridEmailsSent'); if(!g) return 'NOGRID'; const rows=[...g.querySelectorAll('[role=row], tr')].filter(r=>r.querySelector('[role=gridcell], td')); return rows.map(r=>{ const c=[...r.querySelectorAll('[role=gridcell], td')].map(x=>(x.innerText||'').replace(/\s+/g,' ').trim()); return (c[1]||'')+'|||'+(c[3]||'')+'|||'+(c[4]||''); }).join('\n'); }" 2>/dev/null | _tt_eval_str
}

# tt_mail_find <address> - is there a message for this recipient, and what is it?
#
# WHY THIS EXISTS. The old way of answering that was to read page one of the
# Emails Sent grid and diff it against a baseline. That cannot work. The grid
# pages at 20 sorted by SentDate DESCENDING, and SentDate is empty for exactly the
# messages a test has just caused - it is stamped only when the queue DELIVERS
# one. A queued message therefore sorts to the far end of the list and never
# reaches page one, so the old read was measuring delivery, not existence, and
# reported perfectly good templates as missing.
#
# Core.EmailsSent_Overview gained a recipient filter (filterEmailsSentTo) for this
# on 2026-08-28. Filtering asks the question directly and does not care about sort
# order, page size, or whether anything has been delivered yet.
#
# Prints  NOGRID                  the Emails Sent page is not on screen
#         NOFILTER                the filter widget is not on the page - the model
#                                 change has not reached this environment yet
#         NONE                    the filter matched nothing
#         FOUND|<status>|<error>  e.g. FOUND|QUEUED| or FOUND|ERROR|Unknown host
#
# A QUEUED row is a real answer: the message exists, so the template behind it
# exists. Whether it was ever delivered is a separate question this does not ask.
tt_mail_find() {
  local addr="$1" i rows total match
  _tt_mail_open >/dev/null 2>&1 || { echo "NOGRID"; return 1; }
  if ! playwright-cli eval "() => String(!!document.querySelector('.mx-name-filterEmailsSentTo input'))" 2>/dev/null | sed -n '2p' | grep -qiw true; then
    echo "NOFILTER"
    return 1
  fi

  # Clear first, and wait for the unfiltered grid to come back. Without this, a
  # previous lookup that matched nothing leaves an EMPTY grid on screen, and the
  # next address reads that emptiness as its own answer before its filter has even
  # been applied - a false "no message" for a message that is really there.
  tt_fill_commit ".mx-name-filterEmailsSentTo input" ""
  for i in $(seq 1 8); do
    sleep 1
    rows="$(_tt_mail_filter_rows)"
    [ "$rows" = "NOGRID" ] && continue
    [ -n "$rows" ] && break
  done

  tt_fill_commit ".mx-name-filterEmailsSentTo input" "$addr"
  # The filter debounces by delay:500 in the model and then round-trips to the
  # server, so nothing is settled for at least a second.
  for i in $(seq 1 10); do
    sleep 1
    rows="$(_tt_mail_filter_rows)"
    [ "$rows" = "NOGRID" ] && continue
    if [ -z "$rows" ]; then
      # Empty is only trustworthy twice running - once could be a frame caught
      # mid-update, between the old rows going and the new ones arriving.
      sleep 1
      [ -z "$(_tt_mail_filter_rows)" ] && { echo "NONE"; return 0; }
      continue
    fi
    # Settled means every visible row belongs to THIS address. While the previous
    # lookup's rows are still on screen they do not, which is the signal to keep
    # waiting - no fixed sleep can tell those two states apart.
    total="$(printf '%s\n' "$rows" | grep -c . || true)"
    match="$(printf '%s\n' "$rows" | cut -d'|' -f1 | grep -cFi -- "$addr" || true)"
    if [ "${total:-0}" -gt 0 ] && [ "${total:-0}" -eq "${match:-0}" ]; then
      # Fields are separated by three pipes, so cut -d'|' sees 1=to, 4=status,
      # 7=error, with empties between.
      printf 'FOUND|%s|%s\n' \
        "$(printf '%s' "$rows" | head -1 | cut -d'|' -f4)" \
        "$(printf '%s' "$rows" | head -1 | cut -d'|' -f7- | cut -c1-80)"
      return 0
    fi
  done
  echo "NONE"
  return 0
}

# --- the API the tests use -------------------------------------------------

# tt_mail_prepare - make sure mail is readable, and mark what is already there.
# Call it BEFORE the action that triggers the send.
tt_mail_prepare() {
  _tt_mail_open \
    || tt_fail "could not open the Emails Sent page as ${TT_ADMIN_USER:-MxAdmin} - the suite has nowhere to read mail from (is that account an Administrator?)"
  _tt_mail_sort_newest >/dev/null 2>&1 || true
  [ -n "$TT_MAIL_SEEN_FILE" ] || TT_MAIL_SEEN_FILE="$(mktemp)"
  _tt_mail_rows > "$TT_MAIL_SEEN_FILE"
}

# tt_mail_reset - kept so existing call sites read unchanged; re-marks the page.
tt_mail_reset() { tt_mail_prepare; }

# tt_mail_address <tag> - a synthetic address for the cases where a test CHOOSES
# the recipient (the Email Tester). Mail to the app's real addresses is listed
# too, and is filtered by passing that address as the tag.
tt_mail_address() {
  local tag="${1:-e2e}"
  echo "${tag}@${TT_MAIL_DOMAIN:-e2e.local}"
}

# tt_mail_token <ts-ms> [link-regex] [recipient] [timeout-seconds]
# Print the first link matching <link-regex> (default: customer-approval) from
# mail that appeared since tt_mail_prepare.
#
# <ts-ms> is accepted and ignored: freshness comes from the high-water mark,
# which is stronger than a timestamp fence. The argument is kept so existing
# call sites read unchanged.
tt_mail_token() {
  local ts="$1" rx="${2:-customer-approval}" want="${3:-}" budget="${4:-120}"
  local tag waited=0 rows link scoped
  tag="$(_tt_mail_tag "$want")"
  while [ "$waited" -lt "$budget" ]; do
    rows="$(_tt_mail_new_rows)"
    scoped="$(printf '%s\n' "$rows" | grep -i -- "$tag" 2>/dev/null || true)"
    if [ -n "$scoped" ]; then
      rows="$scoped"
    elif [ -n "$want" ]; then
      rows=""     # an explicit recipient was demanded: do not settle for another
    fi
    link="$(printf '%s' "$rows" | grep -oE "https?://[^ \"'<>()~]+${rx}[^ \"'<>()~]*" | head -1)"
    if [ -n "$link" ]; then echo "$link"; return 0; fi
    sleep 5; waited=$((waited + 5))
    _tt_mail_refresh >/dev/null 2>&1 || true
  done
  return 1
}

# tt_mail_message <ts-ms> [recipient] [timeout-seconds]
# Print the mail that just appeared as "Subject: <s>", a blank line, then the row
# as rendered (recipient, status and body included) - the primitive for a test
# that wants to LOOK at the mail rather than pull a link out of it.
tt_mail_message() {
  local ts="$1" want="${2:-}" budget="${3:-120}"
  local tag waited=0 rows row subj
  tag="$(_tt_mail_tag "$want")"
  while [ "$waited" -lt "$budget" ]; do
    rows="$(_tt_mail_new_rows)"
    row="$(printf '%s\n' "$rows" | grep -i -- "$tag" 2>/dev/null | head -1 || true)"
    if [ -z "$row" ] && [ -z "$want" ]; then
      row="$(printf '%s\n' "$rows" | head -1)"
    fi
    if [ -n "$row" ]; then
      subj="$(printf '%s' "$row" | awk -F' ~ ' '{print $3}')"
      printf 'Subject: %s\n\n%s\n' "$subj" "$row"
      return 0
    fi
    sleep 5; waited=$((waited + 5))
    _tt_mail_refresh >/dev/null 2>&1 || true
  done
  return 1
}

# tt_mail_to <substring> - the recipient of the new mail matching <substring>.
# This is what the catcher could never answer: it exists so a test can assert
# that mail went to the RIGHT address.
tt_mail_to() {
  _tt_mail_new_rows | grep -i -- "$1" | head -1 | awk -F' ~ ' '{print $2}'
}


# tt_consultant_submit_entry
# Fallback data-setup (only used when no pending entry exists): as the currently
# logged-in consultant, steps forward to the first editable week, fills Mon-Fri,
# and submits — clicking through whatever confirm dialogs appear (future-week
# "Submit Anyway", under-40 warning, "Are you sure? yes"). Returns 0 if the row
# became non-editable (submitted), 1 otherwise. Exact hours may vary (Mendix
# decimal inputs commit unreliably under automation) but any submitted entry
# reaches AwaitingCustomerApproval, which is all this flow needs.
tt_consultant_submit_entry() {
  local i d
  for i in $(seq 1 10); do
    if playwright-cli eval "() => { const dm=document.querySelector('.mx-name-txtDayMon input'); const ed=dm && !dm.disabled && !dm.readOnly; const hasSubmit=!!document.querySelector('.mx-name-btnSubmit'); return String(!!ed && hasSubmit); }" 2>/dev/null | grep -qiw true; then
      break
    fi
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnSubmit'))" 2>/dev/null | grep -qiw true \
    || tt_fail "consultant: no editable week with a Submit button found"
  # :nth-match is required, not cosmetic: a consultant on several projects has
  # one row per assignment, so a bare .mx-name-txtDayX selector matches them all
  # and Playwright refuses the fill. See tt_fill.
  for d in Mon Tues Wed Thurs Fri; do
    tt_fill ":nth-match(.mx-name-txtDay${d} input, 1)" "8"
  done
  # force the last cell to commit via real focus changes
  playwright-cli click ":nth-match(.mx-name-txtDaySat input, 1)" >/dev/null 2>&1
  playwright-cli click ":nth-match(.mx-name-txtDayMon input, 1)" >/dev/null 2>&1
  sleep 1
  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
  sleep 2
  # click through the confirm dialog until none remain.
  # ONE popup now, not two: btnSubmit calls Main.ACT_Timesheet_Submit_Start, which
  # evaluates the warnings and then opens Main.Consultant_OverFortyHours once —
  # "Submit Anyway" when something warned, plain "Submit" when nothing did. The old
  # "Are you Sure?" page (Main.Confirmation_timesheet) is no longer reachable.
  # Click the affirmative only — NEVER the close 'x' (it cancels submit).
  # Mendix popups are .mx-window/.mx-dialog, not [role=dialog]/.modal-dialog.
  # tt_clear_dialogs targets the LAST VISIBLE dialog. The loop that used to
  # live here called document.querySelector, which can return a stale hidden
  # dialog left behind by Mendix — clicking its buttons does nothing, so the
  # confirm chain stalled and the timesheet was never submitted.
  if ! tt_clear_dialogs 8; then
    tt_fail "submit blocked by a dialog with no way forward: $TT_DIALOG_BLOCKED"
  fi
  sleep 2
  playwright-cli eval "() => { const i=document.querySelector('.mx-name-txtDayMon input'); return String(i ? (i.disabled||i.readOnly) : false); }" 2>/dev/null | grep -qiw true
}

# tt_consultant_submit_project_row <project-substring>
# Multi-assignment variant of tt_consultant_submit_entry: on the consultant
# timesheet (which shows one row per active assignment), steps forward to the
# first week where the row for <project-substring> is editable, fills THAT row's
# Mon-Fri, and submits — clicking through any confirm dialog. Targets the correct
# row by computing its ordinal at runtime (row order is not assumed) and using
# Playwright's :nth-match. Best-effort (exact hours may vary); returns 0.
# Row identification: walk UP from a day input until we reach the container that
# both mentions <proj> and holds exactly ONE day-row (one .mx-name-txtDayMon). The
# single-row test is what stops us ascending into a wrapper that spans several
# assignments and then submitting the wrong one.
#
# It replaced a guard that required exactly one match of
# /E2E (Customer|Manager) Approval/ in the row text. That hardcoded two project
# names, so "E2E Dual Approval" matched ZERO times, the condition was never true,
# and verify-tt647-a5 failed every run with "no editable week with a
# 'E2E Dual Approval' row found" - which read like a missing fixture and was not
# (the assignment exists on dev, 2026-07-01..2027-12-31).
tt_consultant_submit_project_row() {
  local proj="$1" ord="" i d
  for i in $(seq 1 12); do
    ord=$(playwright-cli eval "() => { const mons=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')]; const isTarget=(mon)=>{let el=mon; for(let k=0;k<12;k++){el=el.parentElement; if(!el)break; const t=el.innerText||''; if(t.indexOf('$proj')>=0 && el.querySelectorAll('.mx-name-txtDayMon').length===1) return true;} return false;}; for(let n=0;n<mons.length;n++){ const inp=mons[n].querySelector('input'); if(isTarget(mons[n]) && inp && !inp.disabled && !inp.readOnly && document.querySelector('.mx-name-btnSubmit')) return String(n+1); } return '0'; }" 2>/dev/null | sed -n '2p')
    ord="${ord%\"}"; ord="${ord#\"}"
    [ -n "$ord" ] && [ "$ord" != "0" ] && break
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  { [ -n "$ord" ] && [ "$ord" != "0" ]; } || tt_fail "consultant: no editable week with a '$proj' row found"

  # Record WHICH week is being submitted, in the "MMM DD - MMM DD" form the HR
  # dashboard uses. Callers need it to find the entry they just created rather
  # than any card that happens to mention the same project — see
  # tt647_select_exact_week. The consultant caption is "E2E Oct 04 - Oct 10";
  # the HR week picker renders "Oct 04 - Oct 10, 2026". Stripping the prefix
  # and keeping the day range makes them comparable.
  TT_SUBMITTED_WEEK=$(playwright-cli eval "() => { const t=((document.querySelector('.mx-name-txtWeekRange')||{}).innerText||'').trim(); const m=t.match(/[A-Z][a-z]{2}\\s+\\d{1,2}\\s*-\\s*[A-Z][a-z]{2}\\s+\\d{1,2}/); return m ? m[0] : ''; }" 2>/dev/null | sed -n '2p' | tr -d '"')
  export TT_SUBMITTED_WEEK

  for d in Mon Tues Wed Thurs Fri; do
    tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, ${ord})" "8"
  done
  # commit the last cell - the four before it were committed by the next fill
  tt_commit_focused
  sleep 1

  # Save Draft BEFORE submitting, then confirm the hours actually persisted.
  # Without this the typed values often never reach the server: the entry
  # submits with TotalHours = 0, which the status expression routes STRAIGHT to
  # ToProcess ("if TotalHours = 0 then ToProcess") with no approval step. The
  # card then legitimately reads "No approval required" — which is what made
  # verify-tt647-a2/a6 look like TT-647 defects when the seed was at fault.
  if playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnSaveDraft'))" 2>/dev/null | grep -qiw true; then
    playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
    sleep 3
    tt_clear_dialogs 4 >/dev/null 2>&1 || true
  fi
  local mon
  mon=$(playwright-cli eval "() => String((document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon input')[$ord - 1]||{}).value||'')" 2>/dev/null | sed -n '2p' | tr -d '"')
  case "$mon" in
    ""|0|0.00|0.0)
      tt_fail "consultant: hours did not persist on the '$proj' row (Monday reads '$mon'). Submitting now would create a ZERO-hour entry, which skips approval entirely and renders 'No approval required' — any approval assertion downstream would be meaningless." ;;
  esac

  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
  sleep 2
  # ONE confirm popup now, not two — see tt_consultant_submit_entry. "Submit Anyway"
  # when the week warned, plain "Submit" when it did not.
  # Click the affirmative only — NEVER the close 'x' (it cancels submit).
  # Mendix popups are .mx-window/.mx-dialog, not [role=dialog]/.modal-dialog.
  # tt_clear_dialogs targets the LAST VISIBLE dialog. The loop that used to
  # live here called document.querySelector, which can return a stale hidden
  # dialog left behind by Mendix — clicking its buttons does nothing, so the
  # confirm chain stalled and the timesheet was never submitted.
  if ! tt_clear_dialogs 8; then
    tt_fail "submit blocked by a dialog with no way forward: $TT_DIALOG_BLOCKED"
  fi
  sleep 2
  return 0
}
