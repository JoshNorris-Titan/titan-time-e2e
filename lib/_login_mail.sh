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
# and only rows the list renders are visible - hence the newest-first sort below,
# which keeps fresh mail on the first page.
#
# THE PAGE IS A HAND-BUILT LIST SINCE 2026-09-28 (model commit b2202878, the ST-17
# table rebuild), not a Data grid 2. What the readers below rely on, measured on
# cloud dev the same day:
#
#   .mx-name-lstEmailsSent            the list: 20 rows, then "Load more"; the data
#     .mx-name-cntEmailsSentRow       source returns at most the first 200 in order
#       txtRowSent txtRowTo txtRowSubject txtRowStatus txtRowError
#       txtRowPlainBody txtRowContent  one named text per column, in that order
#   .mx-name-fltSearch input          "Recipient or subject" - a CONTAINS match on To
#                                     OR Subject, so it narrows and never identifies
#   .mx-name-hdrSent                  the Sent header; tt-sort-desc/-asc is its state.
#                                     The page opens on Sent, descending
#
# THE SEARCH BOX DOES NOT REFRESH THE LIST BY ITSELF. Typing an address and tabbing
# away leaves the unfiltered rows on screen for as long as anyone waits (16s
# measured); the list's microflow source re-runs only when something refreshes the
# holder object, and clicking a sort header does. So _tt_mail_apply clicks the Sent
# header until it is back on descending - at least once, which is the refresh - and
# every filtered read then waits for rows that could only have come from that search.
# The same header click is how _tt_mail_refresh re-reads the list: a browser reload
# is useless here, because the page has no URL of its own and a reload lands on the
# home page.
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
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-lstEmailsSent'))" 2>/dev/null | _tt_eval_str
}

# _tt_mail_open - as the administrator, land on the Emails Sent list with no search
# in force.
_tt_mail_open() {
  local i
  if [ "$(_tt_mail_grid_up)" = "true" ]; then
    _tt_mail_unsearch
    return $?
  fi
  tt_login "${TT_ADMIN_USER:-MxAdmin}" "Welcome to your homepage" "${TT_ADMIN_PASS:-${TT_PASS:-}}" || return 1
  playwright-cli click ".mx-name-cardEmailsSent" >/dev/null 2>&1
  for i in $(seq 1 20); do
    [ "$(_tt_mail_grid_up)" = "true" ] && return 0
    sleep 1
  done
  return 1
}

# _tt_mail_sort_state - desc | asc | none (sorted on another column) | NOHDR.
_tt_mail_sort_state() {
  playwright-cli eval "() => { const h=document.querySelector('.mx-name-hdrSent'); if(!h) return 'NOHDR'; const c=h.className+''; return /tt-sort-desc/.test(c)?'desc':(/tt-sort-asc/.test(c)?'asc':'none'); }" 2>/dev/null | _tt_eval_str
}

# _tt_mail_apply - make the list re-run its data source, and leave it sorted on
# Sent, newest first.
#
# Clicks the Sent header until its state reads desc: once from asc, twice from desc
# or from any other column - so there is ALWAYS at least one click, and every click
# is a round trip that re-reads the rows from the database with whatever the search
# box holds. Each click is confirmed by the header's state changing, not by a sleep.
_tt_mail_apply() {
  local before after i n
  for n in 1 2 3; do
    before="$(_tt_mail_sort_state)"
    [ "$before" = "NOHDR" ] && return 1
    playwright-cli click ".mx-name-hdrSent" >/dev/null 2>&1
    after="$before"
    for i in $(seq 1 20); do
      after="$(_tt_mail_sort_state)"
      [ "$after" != "$before" ] && break
      sleep 0.5
    done
    [ "$after" = "$before" ] && return 1
    [ "$after" = "desc" ] && return 0
  done
  return 1
}

# _tt_mail_search <term> - put <term> in the search box and apply it.
_tt_mail_search() {
  playwright-cli fill ".mx-name-fltSearch input" "$1" >/dev/null 2>&1
  tt_commit_focused
  _tt_mail_apply
}

# _tt_mail_unsearch - clear a search a previous lookup left in force. The high-water
# mark and the link readers look at the UNFILTERED list, so a filter left over from
# tt_mail_find would silently narrow what they see.
_tt_mail_unsearch() {
  local v
  v="$(playwright-cli eval "() => { const i=document.querySelector('.mx-name-fltSearch input'); return i ? i.value : ''; }" 2>/dev/null | _tt_eval_str)"
  [ -z "$v" ] && return 0
  _tt_mail_search ""
}

# _tt_mail_sort_newest - leave the list on Sent, newest first; prints the state.
#
# This used to be a deliberate no-op, because on the old Data grid 2 it looked for a
# header it could never find and a working version would have TOGGLED the sort away
# from the default. The list's header now says which way it is sorted, so this
# clicks only when the state is not already desc, and cannot toggle it away.
#
# It is still the wrong instrument for finding one specific message: SentDate is
# stamped only on successful DELIVERY (Email_Connector.SUB_SendQueuedEmail sets it on
# its success branch only), so a QUEUED or FAILED message has no SentDate and sorts
# to the far end. To find a specific message, search by recipient: see tt_mail_find.
_tt_mail_sort_newest() {
  local st
  st="$(_tt_mail_sort_state)"
  if [ "$st" != "desc" ] && [ "$st" != "NOHDR" ]; then
    _tt_mail_apply >/dev/null 2>&1
    st="$(_tt_mail_sort_state)"
  fi
  echo "$st"
}

# _tt_mail_rows - one line per rendered row, cells joined by " ~ ", in the column
# order the old grid had: Sent ~ To ~ Subject ~ Status ~ Error ~ Plain body ~ Content.
# Callers split on that order (field 2 is the recipient, field 3 the subject).
_tt_mail_rows() {
  playwright-cli eval "() => { const l=document.querySelector('.mx-name-lstEmailsSent'); if(!l) return ''; const cols=['txtRowSent','txtRowTo','txtRowSubject','txtRowStatus','txtRowError','txtRowPlainBody','txtRowContent']; return [...l.querySelectorAll('.mx-name-cntEmailsSentRow')].map(r=>cols.map(n=>(((r.querySelector('.mx-name-'+n)||{}).innerText)||'').replace(/\\s+/g,' ').trim()).join(' ~ ')).filter(s=>s.replace(/[ ~]/g,'').length>0).join('\\n'); }" 2>/dev/null | _tt_eval_str
}

# _tt_mail_refresh - re-read the list without paying for a fresh login.
_tt_mail_refresh() {
  if [ "$(_tt_mail_grid_up)" = "true" ]; then
    _tt_mail_unsearch >/dev/null 2>&1
    # _tt_mail_unsearch applied already when it had something to clear; when it did
    # not, this is the re-read.
    _tt_mail_apply && return 0
  fi
  _tt_mail_open
}

# _tt_mail_new_rows - rows that have appeared since tt_mail_prepare.
#
# MULTISET difference, not a set difference. This used to be `grep -Fxv -f
# <seen>`, which drops EVERY row whose text appears in the high-water mark - so a
# second mail identical to one already there was invisible.
#
# Identical was not a corner case on the old grid, whose Sent column showed a DATE
# and no time:
#
#   9/7/2026 ~ consultant@e2e.local ~ Please submit your overdue timesheet ~ Sent ~ ...
#
# Two reminders to the same recipient with the same subject on the same day were
# therefore byte-identical, and the second one could never be seen. That is what
# failed verify-consultant-reminder-mail on CI run 34146189329:
#
#   [mail] no message for recipient 'consultant' after 278s and 8 poll(s)
#   [mail]   9/7/2026 ~ consultant@e2e.local ~ Please submit your overdue timesheet ~ Sent ~ ...
#   [mail] high-water mark held 20 row(s); anything above that was treated as already seen
#
# The list shows date AND minute now ("9/25/2026, 9:02 AM"), which makes a collision
# rarer but not impossible, so the copies are still counted: a row seen once before
# and present twice yields one new row. Order is preserved, so the newest-first sort
# still holds.
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

# _tt_mail_search_rows <term> <address> - the rows the search <term> produced whose
# recipient IS <address>, as  <to>|||<status>|||<error>|||<subject>, newest first.
#
# Prints  NOGRID    the list is not on screen - NOT the same as no rows
#         STALE     some row on screen could not have come from this search (its To
#                   and Subject both lack <term>): the list has not re-run yet
#         EMPTY     the list shows no rows at all
#         MATCHES:0 settled, but no row is addressed to <address> - only subject hits
#         MATCHES:<n> then n lines
#
# The recipient test is EQUALITY per address, not containment: the search is a
# contains-match on To OR Subject, so 'consultant@e2e.local' also finds
# 'e2e_consultant@e2e.local', and a subject line that quotes an address finds that
# row too. To is split on ';' and ',' first, so a message with several recipients
# still counts for each of them.
_tt_mail_search_rows() {
  local term="${1//\'/\\\'}" addr="${2//\'/\\\'}"
  playwright-cli eval "() => { const l=document.querySelector('.mx-name-lstEmailsSent'); if(!l) return 'NOGRID'; const t='$term'.toLowerCase(); const want='$addr'.trim().toLowerCase(); const rows=[...l.querySelectorAll('.mx-name-cntEmailsSentRow')]; if(!rows.length) return 'EMPTY'; const g=(r,n)=>(((r.querySelector('.mx-name-'+n)||{}).innerText)||'').replace(/\\s+/g,' ').trim(); if(!rows.every(r=>(g(r,'txtRowTo')+' '+g(r,'txtRowSubject')).toLowerCase().indexOf(t)>=0)) return 'STALE'; const hit=rows.filter(r=>g(r,'txtRowTo').split(/[;,]/).some(a=>a.trim().toLowerCase()===want)); return ['MATCHES:'+hit.length].concat(hit.map(r=>g(r,'txtRowTo')+'|||'+g(r,'txtRowStatus')+'|||'+g(r,'txtRowError')+'|||'+g(r,'txtRowSubject'))).join('\\n'); }" 2>/dev/null | _tt_eval_str
}

# _tt_mail_lookup <address> - search for <address> and wait for a settled answer.
# Prints what _tt_mail_search_rows printed last (MATCHES:<n> plus rows, or EMPTY),
# NOGRID / NOFILTER when the page cannot answer, or UNSETTLED if it never settled.
_tt_mail_lookup() {
  local addr="$1" i rows empties=0
  _tt_mail_open >/dev/null 2>&1 || { echo "NOGRID"; return 1; }
  if [ "$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-fltSearch input'))" 2>/dev/null | _tt_eval_str)" != "true" ]; then
    echo "NOFILTER"
    return 1
  fi
  _tt_mail_search "$addr" || { echo "NOGRID"; return 1; }
  for i in $(seq 1 12); do
    rows="$(_tt_mail_search_rows "$addr" "$addr")"
    case "$rows" in
      MATCHES:*) printf '%s\n' "$rows"; return 0 ;;
      EMPTY)
        # Empty is only trustworthy twice running - once could be a frame caught
        # mid-update, between the old rows going and the new ones arriving.
        empties=$((empties+1))
        [ "$empties" -ge 2 ] && { echo "EMPTY"; return 0; } ;;
      *) empties=0 ;;
    esac
    sleep 1
  done
  echo "UNSETTLED"
  return 1
}

# tt_mail_find <address> - is there a message for this recipient, and what is it?
#
# WHY THIS EXISTS. The old way of answering that was to read page one of the
# Emails Sent grid and diff it against a baseline. That cannot work: the page is
# sorted by SentDate DESCENDING, and SentDate is empty for exactly the messages a
# test has just caused - it is stamped only when the queue DELIVERS one. A queued
# message therefore sorts to the far end of the list and never reaches page one -
# and since 2026-09-28 the list stops at 200 rows, so it may not be on ANY page.
# Searching asks the question directly and does not care about sort order, page
# size, the cap, or whether anything has been delivered yet.
#
# Prints  NOGRID                  the Emails Sent page is not on screen
#         NOFILTER                the search box is not on the page - the model
#                                 change has not reached this environment yet
#         NONE                    no message is addressed to exactly <address>
#         FOUND|<status>|<error>  e.g. FOUND|QUEUED| or FOUND|ERROR|Unknown host,
#                                 for the newest message to <address>
#
# A QUEUED row is a real answer: the message exists, so the template behind it
# exists. Whether it was ever delivered is a separate question this does not ask.
tt_mail_find() {
  local addr="$1" out first
  out="$(_tt_mail_lookup "$addr")"
  case "$out" in
    NOGRID|NOFILTER) echo "$out"; return 1 ;;
    UNSETTLED)       echo "NOGRID"; return 1 ;;
    EMPTY|MATCHES:0) echo "NONE"; return 0 ;;
  esac
  # Fields are separated by three pipes, so cut -d'|' sees 1=to, 4=status,
  # 7=error, 10=subject, with empties between.
  first="$(printf '%s\n' "$out" | sed -n '2p')"
  printf 'FOUND|%s|%s\n' \
    "$(printf '%s' "$first" | cut -d'|' -f4)" \
    "$(printf '%s' "$first" | cut -d'|' -f7 | cut -c1-80)"
  return 0
}

# tt_mail_find_message <address> - the newest message addressed to exactly
# <address>, printed as "Subject: <s>", a blank line, the plain body, a blank line,
# then the HTML content as text. Prints nothing and returns 1 when there is none,
# or when the page could not answer (the reason goes to stderr).
#
# tt_mail_find says only THAT a message exists; this is for a test that has to read
# what it says.
tt_mail_find_message() {
  local addr="$1" out esc
  out="$(_tt_mail_lookup "$addr")"
  case "$out" in
    MATCHES:0|EMPTY) return 1 ;;
    MATCHES:*) ;;
    *) echo "  [mail] could not look up mail for '$addr': $out" >&2; return 1 ;;
  esac
  esc="${addr//\'/\\\'}"
  playwright-cli --raw eval "() => { const l=document.querySelector('.mx-name-lstEmailsSent'); if(!l) return ''; const want='$esc'.trim().toLowerCase(); const g=(r,n)=>(((r.querySelector('.mx-name-'+n)||{}).innerText)||'').trim(); const r=[...l.querySelectorAll('.mx-name-cntEmailsSentRow')].find(r=>g(r,'txtRowTo').split(/[;,]/).some(a=>a.trim().toLowerCase()===want)); if(!r) return ''; return 'Subject: '+g(r,'txtRowSubject')+'\\n\\n'+g(r,'txtRowPlainBody')+'\\n\\n'+g(r,'txtRowContent'); }" 2>/dev/null \
    | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{d=d.trim(); try{ d=JSON.parse(d); }catch(e){} if(!String(d).trim()) process.exit(1); process.stdout.write(d+"\n"); })'
}

# tt_mail_links_to <address> [link-regex] [max] - every DISTINCT link matching
# <link-regex> (default: customer-approval) in mail addressed to exactly <address>,
# one per line, in the list's order (Sent, newest first), at most [max] (default 4).
# Prints nothing when there is none. Prints NOGRID / NOFILTER and returns 1 when the
# Emails Sent page could not answer, so a caller can tell "no mail" from "no page".
#
# WHY THIS EXISTS. Since per-email approval links (model, 2026-09-24) every approval
# email carries its own token, and an earlier one is never revoked: it keeps working
# until its own ExpiresAt (CONST_ApprovalTokenLifetimeDays, 7). So a link already
# sitting in Emails Sent is as good as a freshly minted one, and reading it costs a
# search instead of a Remind (gated to one per entry per day) plus a wait on the
# outbound queue. tt_customer_link is the caller; it validates each link on the
# token page before trusting it, because "not revoked" is not "covers this entry".
tt_mail_links_to() {
  local addr="$1" rx="${2:-customer-approval}" max="${3:-4}" out esc
  out="$(_tt_mail_lookup "$addr")"
  case "$out" in
    NOGRID|NOFILTER) echo "$out"; return 1 ;;
    UNSETTLED)       echo "NOGRID"; return 1 ;;
    EMPTY|MATCHES:0) return 0 ;;
  esac
  esc="${addr//\'/\\\'}"
  playwright-cli eval "() => { const l=document.querySelector('.mx-name-lstEmailsSent'); if(!l) return ''; const want='$esc'.trim().toLowerCase(); const g=(r,n)=>(((r.querySelector('.mx-name-'+n)||{}).innerText)||'').replace(/\\s+/g,' ').trim(); return [...l.querySelectorAll('.mx-name-cntEmailsSentRow')].filter(r=>g(r,'txtRowTo').split(/[;,]/).some(a=>a.trim().toLowerCase()===want)).map(r=>g(r,'txtRowPlainBody')+' '+g(r,'txtRowContent')).join('\\n'); }" 2>/dev/null \
    | _tt_eval_str \
    | grep -oE "https?://[^ \"'<>()~]+${rx}[^ \"'<>()~]*" \
    | awk '!seen[$0]++' \
    | head -n "$max"
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
    scoped="$(_tt_mail_rows_to "$tag" <<<"$rows")"
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
  all="$(_tt_mail_rows 2>/dev/null | head -12 | cut -c1-220)"
  if [ -z "$all" ]; then
    echo "  [mail] the Emails Sent list could not be read at all - the browser may not have been on that page" >&2
  else
    echo "  [mail] most recent rows actually on the page (sent ~ recipient ~ subject ~ status ~ error ~ body ...):" >&2
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
    row="$(_tt_mail_rows_to "$tag" <<<"$rows" | head -1)"
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

# _tt_mail_rows_to <tag> - of the rows on stdin, those whose RECIPIENT (field 2)
# contains <tag>, case-insensitively.
#
# The recipient only. Matching the whole row, as this used to, let a tag hit the
# subject or the body: 'consultant' - the reminder spec's tag - appears in the body
# of nearly every mail this app sends ("E2E Consultant", "your consultant's
# timesheet"), so the reader could hand back any fresh mail as the reminder.
_tt_mail_rows_to() {
  awk -F' ~ ' -v t="$1" 'index(tolower($2), tolower(t)) > 0' 2>/dev/null || true
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
#
# HORIZON (2026-10-06). This walked 12 weeks forward from today, the same number
# lib/_tt654.sh found too small on 2026-09-1x: every weekly Submit closes that week
# for ALL of the consultant's projects, and every seeding helper walks forward from
# today, so the suite eats this pool in run order. In run 37409110184 (full,
# --no-fail-fast) verify-pm-approve-foreign-entry-refused - one of the last specs to
# seed an e2e_consultant week - failed "no editable week with a 'E2E Manager
# Approval' row found", while the same seeding passed in every spec before it. By
# then the run had already filled weeks out to Dec 06 - Dec 12 (75-export exported
# that week; HR's To Process tab listed Nov 29 - Dec 5 at tt647), i.e. 10 of the 12
# weeks ahead of Oct 4, before 76-bulk and 85-security seeded more. Same horizon as
# TT654_WEEK_HORIZON, same census on
# failure, so the next failure names its cause:
#   -  no editable '<proj>' row that week (not assigned, outside the window, or
#      the week is submitted and its rows locked)
#   S  the row is editable but the week offers no Submit
TT_SUBMIT_WEEK_HORIZON="${TT_SUBMIT_WEEK_HORIZON:-30}"
tt_consultant_submit_project_row() {
  local proj="$1" ord="" i d census="" from="" to=""
  from="$(playwright-cli eval "() => String((document.querySelector('.mx-name-txtWeekRange')||{}).innerText||'').trim()" 2>/dev/null | _tt_eval_str)"
  for i in $(seq 1 "$TT_SUBMIT_WEEK_HORIZON"); do
    ord=$(playwright-cli eval "() => { const mons=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')]; const isTarget=(mon)=>{let el=mon; for(let k=0;k<12;k++){el=el.parentElement; if(!el)break; const t=el.innerText||''; if(t.indexOf('$proj')>=0 && el.querySelectorAll('.mx-name-txtDayMon').length===1) return true;} return false;}; for(let n=0;n<mons.length;n++){ const inp=mons[n].querySelector('input'); if(isTarget(mons[n]) && inp && !inp.disabled && !inp.readOnly && document.querySelector('.mx-name-btnSubmit')) return String(n+1); } return '0'; }" 2>/dev/null | sed -n '2p')
    ord="${ord%\"}"; ord="${ord#\"}"
    [ -n "$ord" ] && [ "$ord" != "0" ] && break
    if [ "$(tt_week_row_of "$proj" editable)" = "0" ]; then census="${census}-"; else census="${census}S"; fi
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  if [ -z "$ord" ] || [ "$ord" = "0" ]; then
    to="$(playwright-cli eval "() => String((document.querySelector('.mx-name-txtWeekRange')||{}).innerText||'').trim()" 2>/dev/null | _tt_eval_str)"
    tt_fail "consultant: no editable week with a '$proj' row found within $TT_SUBMIT_WEEK_HORIZON weeks
  walked ${from:-<unknown>} -> ${to:-<unknown>}, one character per week: $census
  ('-' = no editable '$proj' row that week: not assigned, outside the window, or submitted and locked; 'S' = an editable row but no Submit button)"
  fi

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
