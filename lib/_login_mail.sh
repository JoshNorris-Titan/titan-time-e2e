#!/usr/bin/env bash
# _login_mail.sh — part of the lib/_login.sh split (2026-09-17).
#
# Reading mail as administrator: finding a message, extracting a token, and the
# wait budgets, which are tuned against measured cloud-dev latency.
#
# DO NOT SOURCE THIS DIRECTLY. Source lib/_login.sh, which sources every part in
# order; the parts are positional slices of one file and several depend on names
# defined in an earlier one. Sourcing lib/_login.sh is exactly what it always was.
#
# This file is lines 1528-2069 of the pre-split lib/_login.sh, verbatim. Everything
# below the next line is unchanged, which is how the split was verified.
# --- begin verbatim slice of the original lib/_login.sh ---
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
# _tt_mail_new_rows - rows that have appeared since tt_mail_prepare.
#
# MULTISET difference, not a set difference. This used to be `grep -Fxv -f
# <seen>`, which drops EVERY row whose text appears in the high-water mark - so a
# second mail identical to one already there was invisible.
#
# Identical is not a corner case here. A row renders as
#
#   9/7/2026 ~ consultant@e2e.local ~ Please submit your overdue timesheet ~ Sent ~ ...
#
# leading with a DATE, not a timestamp. Two reminders to the same recipient with
# the same subject on the same day are therefore byte-identical, and the second
# one could never be seen.
#
# That is what failed verify-consultant-reminder-mail on CI run 34146189329. The
# diagnostic dump added for exactly this ambiguity printed the mail sitting on the
# page, Sent, correctly addressed, while the test reported it as never received:
#
#   [mail] no message for recipient 'consultant' after 278s and 8 poll(s)
#   [mail]   9/7/2026 ~ consultant@e2e.local ~ Please submit your overdue timesheet ~ Sent ~ ...
#   [mail] high-water mark held 20 row(s); anything above that was treated as already seen
#
# Counting copies fixes it: a row seen once before and present twice now yields
# one new row. Order is preserved, so the newest-first sort still holds.
_tt_mail_new_rows() {
  local cur
  cur="$(_tt_mail_rows)"
  if [ -s "${TT_MAIL_SEEN_FILE:-/dev/null}" ]; then
    printf '%s\n' "$cur" \
      | awk 'NR==FNR { seen[$0]++; next } { if (seen[$0] > 0) { seen[$0]--; next } print }' \
            "$TT_MAIL_SEEN_FILE" - 2>/dev/null || true
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
#
# THE BUDGET IS WALL CLOCK, AND USED NOT TO BE.
# ---------------------------------------------
# Both mail waiters used to count only their own `sleep 5`, while each iteration
# also ran _tt_mail_new_rows and _tt_mail_refresh - and _tt_mail_refresh does a
# full `playwright-cli reload` plus up to 15s of grid polling. So a nominal
# "120s" budget was really about 8 minutes of wall clock, which is the whole step
# budget these four mail specs declare.
#
# The damage was diagnostic, not just cosmetic. When mail did not arrive the
# helper never got to return 1, so the caller's own message - "token email not
# received within timeout" - was never printed. The step was killed from outside
# instead and reported as a bare TIMEOUT, which says nothing about mail at all.
# That is how CI runs 34018437556 and 34046052399 both burned 8 minutes and named
# no cause.
#
# WHY 240s, AND WHY IT IS AN UPPER BOUND RATHER THAN A PREFERENCE.
# Observed behaviour on cloud dev is bimodal: when mail works it lands in well
# under a minute (verify-customer-token-approve passes in 90s END TO END), and
# when it does not it never arrives at all. The longest legitimate wait is bounded
# by the 2-minute outbound queue event, so 240s is already double the real
# mechanism.
#
# The ceiling is what fixes the number, though. This budget has to expire while
# the step still has time to report, or the step is killed from outside and we are
# back to a bare TIMEOUT that names no cause - the exact failure this change
# exists to remove. The specs declare `tt-timeout: 8m` (480s), the expensive path
# through them (no pending entry, so create one as the consultant, then remind)
# costs roughly 3 minutes before mail is even asked for, and this loop overshoots
# its budget by up to one poll cycle (~20s at cloud-dev latency). 180 + 240 + 20
# leaves about a minute of margin inside 480s. A 300s budget did not.
#
# So if mail genuinely needs longer than 240s, raising THIS number alone will
# re-break the diagnostics: the step budget above it has to move first. Raising
# the step's tt-timeout on its own just buys more silence.
tt_mail_token() {
  local ts="$1" rx="${2:-customer-approval}" want="${3:-}" budget="${4:-240}"
  local tag rows link scoped started polls=0
  tag="$(_tt_mail_tag "$want")"
  started="$(date +%s)"
  while :; do
    rows="$(_tt_mail_new_rows)"
    scoped="$(printf '%s\n' "$rows" | grep -i -- "$tag" 2>/dev/null || true)"
    if [ -n "$scoped" ]; then
      rows="$scoped"
    elif [ -n "$want" ]; then
      rows=""     # an explicit recipient was demanded: do not settle for another
    fi
    link="$(printf '%s' "$rows" | grep -oE "https?://[^ \"'<>()~]+${rx}[^ \"'<>()~]*" | head -1)"
    if [ -n "$link" ]; then echo "$link"; return 0; fi
    polls=$((polls + 1))
    [ $(( $(date +%s) - started )) -ge "$budget" ] && break
    sleep 5
    _tt_mail_refresh >/dev/null 2>&1 || true
  done
  _tt_mail_dump "no link matching '$rx' for recipient '${want:-any}'" "$(( $(date +%s) - started ))" "$polls"
  return 1
}

# _tt_mail_dump <what> <seconds> <polls> - explain a mail timeout instead of just
# announcing one.
#
# WHY THIS EXISTS. verify-customer-token-reject fails intermittently in CI and has
# now survived two deliberate local reproductions: standalone after a fresh
# 00-setup, and again in its real sequence (customer-approval-flow ->
# customer-token-approve -> customer-token-reject, one shared browser session,
# forced down the create-your-own-entry branch). Both passed.
#
# A flake that will not reproduce cannot be diagnosed by staring at the helper, and
# the candidate causes need OPPOSITE fixes:
#
#   * no matching row at all      -> the app never queued the mail
#   * a row present but not Sent  -> queued, and the outbound event has not run
#   * a Sent row the regex missed -> the app is fine and the MATCHER is wrong
#
# Nothing printed so far could tell those apart, so every CI failure produced the
# same uninformative line. This dumps what the Emails Sent page actually held at
# the moment we gave up - unfiltered by the high-water mark, because "the row was
# there but we considered it already seen" is itself one of the answers.
#
# Deliberately capped and sent to stderr: it is diagnostic context for a failure,
# not test output, and an unbounded dump of a shared environment's mail would bury
# the failure it is meant to explain.
_tt_mail_dump() {
  local what="$1" secs="$2" polls="$3" all seen
  echo "  [mail] $what after ${secs}s and ${polls} poll(s) of the Emails Sent page" >&2
  all="$(_tt_mail_rows 2>/dev/null | head -12)"
  if [ -z "$all" ]; then
    echo "  [mail] the Emails Sent grid could not be read at all - the browser may not have been on that page" >&2
  else
    echo "  [mail] most recent rows actually on the page (recipient ~ status ~ subject ...):" >&2
    printf '%s\n' "$all" | sed 's/^/  [mail]   /' >&2
  fi
  seen="$(wc -l < "${TT_MAIL_SEEN_FILE:-/dev/null}" 2>/dev/null || echo 0)"
  echo "  [mail] high-water mark held $seen row(s); anything above that was treated as already seen" >&2
}

# tt_mail_message <ts-ms> [recipient] [timeout-seconds]
# Print the mail that just appeared as "Subject: <s>", a blank line, then the row
# as rendered (recipient, status and body included) - the primitive for a test
# that wants to LOOK at the mail rather than pull a link out of it.
#
# Budget is wall clock, for the reasons written above tt_mail_token.
tt_mail_message() {
  local ts="$1" want="${2:-}" budget="${3:-240}"
  local tag rows row subj started polls=0
  tag="$(_tt_mail_tag "$want")"
  started="$(date +%s)"
  while :; do
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
    polls=$((polls + 1))
    [ $(( $(date +%s) - started )) -ge "$budget" ] && break
    sleep 5
    _tt_mail_refresh >/dev/null 2>&1 || true
  done
  _tt_mail_dump "no message for recipient '${want:-any}'" "$(( $(date +%s) - started ))" "$polls"
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

# tt_week_row_of <project-substring> [editable] — 1-based position of the row for
# <project> in the consultant week grid (.mx-name-galAssignmentRows), or 0. With
# `editable`, only a row whose Mon cell holds a writable input counts.
#
# ONE ROW = ONE .mx-name-txtDayMon. The climb from each Mon cell stops the moment
# the ancestor holds more than one, so it can only ever match text inside its own
# row -- the same containment tt_consultant_submit_project_row below, lib/_seed.sh
# and lib/_tt654.sh already use.
#
# WHY THIS EXISTS (2026-09-12). Four 20-consultant specs each carried a private
# copy of this walk WITHOUT the containment test: climb ten parents, return the
# first whose text holds <project>. Measured on dev, a Mon cell is only four levels
# below the list holding EVERY row (txtDayMon > cntRowCells > cntAssignmentRow >
# .widget-gallery-item > .widget-gallery-items) since the 2026-09-09 CSS-grid
# refactor of the timesheetGrid region. So from row 1 the old climb reached the
# whole list by k=4, found <project> there whichever row it was on, and returned
# 1 -- every time. The four specs stayed correct only because e2e_consultant2 has
# exactly one assignment. verify-week-row-resolution holds this helper to the right
# answer on a grid with several rows.
tt_week_row_of() {
  local proj="$1" mode="${2:-any}"
  playwright-cli eval "() => { const rows=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')]; for(let n=0;n<rows.length;n++){ let el=rows[n]; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; if(el.querySelectorAll('.mx-name-txtDayMon').length!==1) break; if((el.innerText||'').indexOf('$proj')>=0){ if('$mode'!=='editable') return String(n+1); const inp=rows[n].querySelector('input'); if(inp && !inp.readOnly && !inp.disabled) return String(n+1); break; } } } return '0'; }" 2>/dev/null | _tt_eval_str
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

  # Record WHICH week is being submitted, as a canonical tt_week_key. Callers need
  # it to find the entry they just created rather than any card that happens to
  # mention the same project — see tt647_select_exact_week. The consultant caption
  # and the HR week picker word the same week differently ("This week · Oct 4 – 10"
  # against "Oct 04 - Oct 10, 2026"), so the key is what makes them comparable.
  TT_SUBMITTED_WEEK="$(tt_current_week)"
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
