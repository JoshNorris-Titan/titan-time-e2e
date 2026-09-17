#!/usr/bin/env bash
# _login_core.sh — part of the lib/_login.sh split (2026-09-17).
#
# Environment, the HR dashboard tab selectors (TT-724 phase 4), field entry and
# commit, and week identity (tt_week_key, week status, actionability).
# Also tt_fail, which everything else depends on.
#
# DO NOT SOURCE THIS DIRECTLY. Source lib/_login.sh, which sources every part in
# order; the parts are positional slices of one file and several depend on names
# defined in an earlier one. Sourcing lib/_login.sh is exactly what it always was.
#
# This file is lines 1-496 of the pre-split lib/_login.sh, verbatim. Everything
# below the next line is unchanged, which is how the split was verified.
# --- begin verbatim slice of the original lib/_login.sh ---
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
#   TT_ROLE_PASS  password for the e2e_* role accounts. REQUIRED off localhost;
#                 the built-in default is a localhost-only convenience.

TT_BASE="${TT_BASE_URL:-http://localhost:8080}"
# The default below is a LOCALHOST convenience and _tt_require_explicit_pass()
# refuses it against any other target. See that function for why.
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
# Pending has galPending / galAvailableWeeks / cbWeekConsultant /
# btnSubmitZeroHours / btnRemind.
#
# THAT LAST ONE IS THE TRAP. `.mx-name-btnRemind` still exists — it is the
# Pending card's "remind this consultant to submit" button, which is a different
# button from the per-entry Remind that used to share its name. A helper left on
# the bare name does not error; it silently scans the wrong cards and reports
# "no pending entry". Use TT_HR_BTN_REMIND.
#
# btnSubmitZeroHours (added 2026-09-03) is the Pending card's second button: it
# closes a consultant's outstanding week at 0 hours. It does NOT act on click —
# it opens the popup page Main.HR_ConfirmZeroHours, so a spec has to press
# .mx-name-btnConfirmZeroSubmit (or .mx-name-btnConfirmZeroCancel) afterwards.
# That is a real page, not an inline confirm dialog, so tt_clear_dialogs will
# not dismiss it. A row closed this way then renders
# .mx-name-txtProcessZeroByHR on the To Process card, which is the cheapest
# thing to assert the close actually happened.
TT_HR_GAL_ENTRIES='.mx-name-galManagerEntries, .mx-name-galClientEntries, .mx-name-galProcessEntries, .mx-name-galSentEntries'
TT_HR_GAL_WEEKS='.mx-name-galManagerAvailableWeeks, .mx-name-galClientAvailableWeeks, .mx-name-galProcessAvailableWeeks, .mx-name-galSentAvailableWeeks'
TT_HR_CB_CONSULTANT='.mx-name-cbManagerConsultant, .mx-name-cbClientConsultant, .mx-name-cbProcessConsultant, .mx-name-cbSentConsultant'
TT_HR_CB_PROJECT='.mx-name-cbManagerProject, .mx-name-cbClientProject, .mx-name-cbProcessProject, .mx-name-cbSentProject'
TT_HR_BTN_APPROVE='.mx-name-btnManagerApprove, .mx-name-btnClientApprove'
TT_HR_BTN_REMIND='.mx-name-btnManagerRemind, .mx-name-btnClientRemind'
# THE CLIENT REMIND BUTTON IS NOW CONDITIONAL, AND THIS IS ITS OTHER HALF.
#
# The model gained a once-per-day gate on customer reminders (model commit
# fdd18a24). On the Client Approval card, .mx-name-btnClientRemind is rendered
# only while ApprovalHelper/CanRemindCustomer is true; when it is false the
# button is REPLACED by an inert look-alike, .mx-name-btnClientRemindBlocked,
# wrapped in a tooltip naming the time the reminder already went out. There is
# no disabled ActionButton in Mendix, so this is two mutually exclusive
# controls, not one control in two states.
#
# THE RULE THAT DECIDES WHICH ONE YOU GET:
#   blocked = a reminder was sent to this customer TODAY
#             AND this timesheet was already awaiting them when it went out
# So a timesheet submitted AFTER today's reminder still shows an enabled
# button, which is what the callers' fallback path relies on.
#
# WHY THIS BITES A WHOLE SUITE RUN, NOT ONE SPEC. Every project the fixtures
# create shares one approver address (FX_APPROVER_EMAIL), and the gate keys on
# that address. So the FIRST spec in a run to press Remind gates every
# already-pending client entry for the rest of the run, across all projects.
# The specs still pass -- their fallback submits a fresh entry, which re-enables
# the button -- but they take the slow path, and a helper that only looked for
# TT_HR_BTN_REMIND would report "no pending entry" for a card that is sitting
# right there. That misdiagnosis is the expensive failure mode in this suite;
# tt_hr_remind_e2e_entry names the gated state explicitly instead.
#
# NOTE the two class names are distinct tokens, so TT_HR_BTN_REMIND does NOT
# match the blocked look-alike. Do not "simplify" either selector into a prefix
# match, or every gated card will read as clickable.
TT_HR_BTN_REMIND_BLOCKED='.mx-name-btnClientRemindBlocked'
TT_HR_BTN_VIEW='.mx-name-btnManagerView, .mx-name-btnClientView'
TT_HR_BTN_PROCESS='.mx-name-btnProcessEntry'
TT_HR_BTN_REJECT='.mx-name-btnProcessReject'
TT_HR_TXT_APPROVER1='.mx-name-txtProcessManagerApprover'
TT_HR_TXT_APPROVER2='.mx-name-txtProcessClientApprover'
# The per-entry CARD inside the entries gallery. Was the snippet's generated
# container13, which is why a rename could never have been noticed by name alone.
TT_HR_CARD='.mx-name-containerManagerCard, .mx-name-containerClientCard, .mx-name-containerProcessCard, .mx-name-containerSentCard'

# MONTHLY TO BE INVOICED, named separately for the reason given above: it is a
# page-level tab, not one of the four HRDashboardTab snippet tabs, so it is
# deliberately NOT in the unions and a helper written against them cannot see it.
#
# ITS PICKER IS MONTHS, NOT WEEKS. There is no galInvoiceAvailableWeeks and no
# HRDashboardTab row behind it — the filter is galAvailableMonths, which is why
# tt_hr_count_cards_for and tt_hr_reject_card_for_project (both of which iterate
# TT_HR_GAL_WEEKS) find nothing here however long they are left to run. A caller
# on this tab has to walk the months itself; see
# suites/75-export/verify-hr-invoice-reject.test.sh for the shape of that walk.
TT_HR_GAL_MONTHS='.mx-name-galAvailableMonths'
TT_HR_GAL_INVOICE='.mx-name-galInvoiceEntries'
TT_HR_BTN_INVOICE_VIEW='.mx-name-btnInvoiceView'
TT_HR_BTN_INVOICE_REJECT='.mx-name-btnInvoiceReject'

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
  # 'submit' is listed as well as 'submit anyway'. The two submit popups were
  # merged into one page, and the 2026-09-04 consultant rework then merged that
  # page's two states as well: warned or clean, the dialog now reads "Submit
  # timesheet?" and its only confirm is a plain Submit (btnConfirmSubmit).
  # Without the bare caption every submit would park on BLOCKED. 'submit anyway'
  # is kept for the other popups that still use that wording, and the regex is
  # anchored with ^...$, so 'submit' does NOT swallow it.
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

# ---------------------------------------------------------------------------
# tt_week_key <text> — the canonical "Mmm DD - Mmm DD" key for a week, or ''.
#
# THE PROBLEM THIS SOLVES. Four surfaces name the same week four different ways,
# and half this suite identifies a week by matching one against another:
#
#   .mx-name-txtWeekRange   "This week · Sep 7 – 13"   (TT-745; en dash, no
#                                                       trailing month, no zero pad)
#   .mx-name-txtWeekRange   "E2E Sep 06 - Sep 12"      (the pre-TT-745 caption,
#                                                       prefixed with the account's
#                                                       first name)
#   galTimesheetHistory row "Sep 06 - Sep 12"
#   HR week picker          "Oct 04 - Oct 10, 2026"
#
# Matching any of those against another verbatim never hits, so every comparison
# goes through this function first. It accepts ALL FOUR shapes deliberately: the
# model half of TT-745 ships separately from this suite, so between the PR landing
# and the deploy reaching cloud dev the consultant grid still renders the old
# caption. A key-based comparison is green on both sides of that deploy; a regex
# tuned to one caption is red on the other.
#
# Rules: any prefix is discarded, en/em dashes count as the separator, a missing
# trailing month is inherited from the start of the range, days are zero-padded,
# and a trailing ", 2026" is dropped.
#
# Prints NOTHING and still returns 0 when the text holds no week range at all —
# one caller runs under `set -e`, and the established contract is that callers
# test for an empty result (`[ -n "$key" ] || key="$week"`). A partial range is
# not a week: "Sep 7" alone yields '' rather than a guess.
#
# suites/80-platform/verify-week-key-contract.test.sh pins every row above.
tt_week_key() {
  local s="$1"
  s="${s//$'\xe2\x80\x93'/-}"        # en dash
  s="${s//$'\xe2\x80\x94'/-}"        # em dash
  local re='([A-Z][a-z][a-z])[[:space:]]+([0-9][0-9]?)[[:space:]]*-[[:space:]]*(([A-Z][a-z][a-z])[[:space:]]+)?([0-9][0-9]?)([^0-9]|$)'
  [[ $s =~ $re ]] || return 0
  local m1="${BASH_REMATCH[1]}" d1="${BASH_REMATCH[2]}"
  local m2="${BASH_REMATCH[4]}" d2="${BASH_REMATCH[5]}"
  [ -n "$m2" ] || m2="$m1"
  printf '%s %02d - %s %02d\n' "$m1" "$((10#$d1))" "$m2" "$((10#$d2))"
}

# tt_current_week — the week the grid is showing right now, as a tt_week_key, or ''.
tt_current_week() {
  tt_week_key "$(playwright-cli eval "() => String((document.querySelector('.mx-name-txtWeekRange')||{}).innerText||'').trim()" 2>/dev/null | _tt_eval_str)"
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

