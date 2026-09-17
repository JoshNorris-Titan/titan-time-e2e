#!/usr/bin/env bash
# _login_gallery.sh — part of the lib/_login.sh split (2026-09-17).
#
# Gallery paging and reading: loading every page of a gallery, pulling titles,
# and the combobox helpers.
#
# DO NOT SOURCE THIS DIRECTLY. Source lib/_login.sh, which sources every part in
# order; the parts are positional slices of one file and several depend on names
# defined in an earlier one. Sourcing lib/_login.sh is exactly what it always was.
#
# This file is lines 946-1279 of the pre-split lib/_login.sh, verbatim. Everything
# below the next line is unchanged, which is how the split was verified.
# --- begin verbatim slice of the original lib/_login.sh ---
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

# tt_pm_pending_rows [settle-seconds] — how many approvable rows the CURRENT
# session has in the PM pending-approval queue. Echoes a count, or ERR:<why>.
#
# WHY THIS IS NOT `tt_wait_for .mx-name-galPMPendingEntries` FOLLOWED BY A COUNT,
# which is what all three callers used to do. As of 2026-09-03 (model commit
# c5b00326, "Hiding awating approval component for pm's when there isn't any")
# the PM dashboard HIDES the whole awaiting-approval component when the manager
# has nothing pending. An absent gallery is now the app working correctly: it
# means ZERO. The old shape turned that into two different false failures --
# a tt_wait_for timeout, and a raw NOGALLERY hitting a numeric-parse guard --
# and both are in this suite's history, one of them aborting a whole CI run with
# 49 steps left unrun.
#
# The distinction that still has to hold is EMPTY vs NOT LOADED YET. A missing
# gallery means zero only once the dashboard itself is on screen; read too early
# it means nothing at all, and reporting 0 for a manager with a full queue is the
# silent-pass failure this suite exists to avoid. So this anchors on the page
# heading, which renders either way and sits outside the hidden component, and
# calls a missing gallery zero only after the settle window elapsed with the
# heading present.
#
# Note the asymmetry, which is deliberate: a gallery that IS there answers
# immediately, so the common non-empty path costs one round trip. Only the zero
# case pays the full settle. The poll runs IN THE PAGE rather than as a bash
# loop -- each playwright-cli call is ~2.6s of node startup against cloud dev,
# so a bash poll would cost more than the thing it is waiting for.
TT_PM_DASH_ANCHOR="${TT_PM_DASH_ANCHOR:-Project Manager Dashboard}"

tt_pm_pending_rows() {
  local secs="${1:-12}"
  playwright-cli eval "() => new Promise(res => {
    const deadline = Date.now() + $secs * 1000;
    const tick = () => {
      const g = document.querySelector('.mx-name-galPMPendingEntries');
      if (g) return res(String(g.querySelectorAll('.mx-name-btnPMApprove').length));
      const up = (document.body.innerText || '').indexOf('$TT_PM_DASH_ANCHOR') >= 0;
      if (Date.now() >= deadline) return res(up ? '0' : 'ERR:dashboard-never-rendered');
      setTimeout(tick, 500);
    };
    tick();
  })" 2>/dev/null | _tt_eval_str
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
# tt_combobox_select_text <combobox-selector> <option-text-prefix>
#
# RETRIES, because a Mendix combobox does not populate synchronously. This used
# to click once, sleep exactly 1s, look for [role=option] a single time, and give
# up - so it failed whenever the option list had not rendered yet, and the caller
# reported the value as "not selectable" when it was merely not ready.
#
# That surfaced as "fixtures: customer 'Costco' not selectable on the assignment
# form" while creating the THIRD assignment in a row, on an environment where
# Costco plainly exists. Same failure family as fx_view in lib/_fixtures.sh: one
# attempt, a fixed sleep, and no way to recover a click that never landed.
#
# It only re-clicks when NO options are showing. Clicking an already-open combobox
# toggles it shut, so an unconditional re-click would oscillate open/closed and
# could starve the very poll that was about to succeed.
#
# A genuine "this value is not in the list" now costs ~20s instead of ~3s before
# it reports. That is deliberate and safe here: all seven call sites treat a
# failure as fatal and none probes for an expected absence.
tt_combobox_select_text() {
  local cb="$1" want="$2" i r
  for i in $(seq 1 6); do
    if [ "$(playwright-cli eval "() => String(document.querySelectorAll('[role=option]').length)" 2>/dev/null | _tt_eval_str)" = "0" ]; then
      playwright-cli click "$cb" >/dev/null 2>&1
      sleep 1
    fi
    r="$(playwright-cli eval "() => { const o=[...document.querySelectorAll('[role=option]')].find(e=>(e.innerText||'').trim().indexOf('$want')===0); if(o){o.click(); return 'PICKED';} return 'NOMATCH:'+document.querySelectorAll('[role=option]').length; }" 2>/dev/null | _tt_eval_str)"
    case "$r" in
      PICKED) sleep 2; return 0 ;;
    esac
    sleep 1
  done
  echo "  [combobox] '$want' not selectable in $cb after $i attempts (last: $r)" >&2
  return 1
}
