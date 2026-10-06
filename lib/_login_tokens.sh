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

# tt_hr_remind_confirm — wait for, check and dismiss TT-768's Remind confirmation.
#
# Since TT-768 (model fa8f6d17, deployed) every HR Remind — Pending btnRemind
# (Main.ACT_Email_RemindConsultant), btnManagerRemind (…RemindManager) and
# btnClientRemind (…RemindCustomer) — ends in a BLOCKING Information message:
#
#     "Reminder sent to {name} ({email})."
#
# A blocking message puts a modal underlay over the page, so the NEXT real
# playwright-cli click in the same session (a tab, a card, a login link) times
# out against it. Every Remind therefore has to be followed by this.
#
# Polls up to ~30 s for the topmost visible dialog (the remind flow queues mail and,
# for a customer, mints a token before the message reaches the client). Then:
#   0  the dialog read "Reminder sent to <name> (<x@y>)." and its OK was clicked
#      and the dialog is gone;
#   2  no dialog came, or a dialog with OTHER text came (it is still dismissed with
#      OK/Close so the session is usable, and its text is printed). Distinct from 1,
#      which tt_hr_remind_e2e_entry keeps for "no card to remind", so a caller can
#      tell "the Remind was refused or silent" from "there was nothing to remind".
#
# The text read is printed to STDERR (STDOUT of tt_hr_remind_e2e_entry is its week
# label), and left in TT_REMIND_CONFIRM_TEXT for a caller that calls this directly.
TT_REMIND_CONFIRM_RE='Reminder sent to .+ \(.+@.+\)\.'
TT_REMIND_CONFIRM_TEXT=""
tt_hr_remind_confirm() {
  local d i t
  d="$(_tt_dialog_js)"
  TT_REMIND_CONFIRM_TEXT=""
  for i in $(seq 1 30); do
    t="$(playwright-cli eval "() => { const d=$d; if(!d) return ''; return (d.innerText||'').replace(/\\s+/g,' ').trim(); }" 2>/dev/null | _tt_eval_str)"
    [ -n "$t" ] && break
    sleep 1
  done
  TT_REMIND_CONFIRM_TEXT="$t"
  if [ -z "$t" ]; then
    echo "  [remind] TT-768: no confirmation dialog within 30 s of the Remind click - expected 'Reminder sent to {name} ({email}).'" >&2
    return 2
  fi
  # OK on a match; on anything else take the dialog's own way out (OK or Close)
  # so the session is not left behind a modal, and report what it said.
  playwright-cli eval "() => { const d=$d; if(!d) return 'none'; const b=[...d.querySelectorAll('button')].filter(x=>x.offsetParent!==null).find(x=>/^(ok|close)\$/i.test((x.innerText||'').trim())); if(b){ b.click(); return 'clicked'; } return 'nobutton'; }" >/dev/null 2>&1
  for i in $(seq 1 10); do
    [ "$(playwright-cli eval "() => String(!$d)" 2>/dev/null | _tt_eval_str)" = "true" ] && break
    sleep 1
  done
  if ! printf '%s' "$t" | grep -Eq "$TT_REMIND_CONFIRM_RE"; then
    echo "  [remind] TT-768: the Remind raised a dialog that is not the confirmation: '$t'" >&2
    return 2
  fi
  if [ "$(playwright-cli eval "() => String(!$d)" 2>/dev/null | _tt_eval_str)" != "true" ]; then
    echo "  [remind] TT-768: confirmation read '$t' but it was still up after OK" >&2
    return 2
  fi
  echo "  [remind] confirmed and dismissed: $t" >&2
  return 0
}

# _tt_hr_card_js <who> <proj> <sel> — JS prelude: HIT() is the button matching <sel>
# whose OWN card (the climb stops at an ancestor holding more than one such button)
# names <who> and <proj>, or null. Same one-card rule as tt_hr_remind_e2e_entry.
_tt_hr_card_js() {
  printf '%s' "const HIT=()=>{ const rs=[...document.querySelectorAll('$3')]; for(const r of rs){ let el=r; for(let i=0;i<9;i++){ el=el.parentElement; if(!el) break; if(el.querySelectorAll('$3').length!==1) break; const t=el.innerText||''; if(t.indexOf('$1')>=0 && ('$2'==='' || t.indexOf('$2')>=0)) return r; } } return null; };"
}

# tt_hr_find_remind_week <consultantName> <projectName> [open|gated]
#
# Walk the open picker tab's weeks and stop on the first whose card for
# <consultantName>/<projectName> offers Remind (open, the default) or shows the
# gated look-alike (gated). Echoes that week's label and LEAVES IT SELECTED, so a
# caller can count and act on that one week; returns 1 when no week has one. Clicks
# nothing on a card.
tt_hr_find_remind_week() {
  local who="${1//\'/\\\'}" proj="${2//\'/\\\'}" mode="${3:-open}" sel labels lbl i js
  sel="$TT_HR_BTN_REMIND"; [ "$mode" = "gated" ] && sel="$TT_HR_BTN_REMIND_BLOCKED"
  js="$(_tt_hr_card_js "$who" "$proj" "$sel")"
  for i in $(seq 1 20); do
    playwright-cli eval "() => String(!!document.querySelector('$TT_HR_GAL_WEEKS'))" 2>/dev/null | grep -qiw true && break
    sleep 1
  done
  labels="$(tt_hr_week_labels)"
  local IFS='|'
  for lbl in $labels; do
    [ -n "$lbl" ] || continue
    unset IFS
    if tt_hr_select_week "$lbl"; then
      for i in 1 2 3 4; do
        if [ "$(playwright-cli eval "() => { $js return String(!!HIT()); }" 2>/dev/null | _tt_eval_str)" = "true" ]; then
          echo "$lbl"; return 0
        fi
        sleep 1
      done
    fi
    IFS='|'
  done
  unset IFS
  return 1
}

# tt_hr_remind_here <consultantName> <projectName> — press Remind on that card in
# the week ALREADY selected (no walk), then read and dismiss TT-768's confirmation.
# 0 confirmed, 1 no such remindable card here, 2 reminded but no confirmation.
tt_hr_remind_here() {
  local who="${1//\'/\\\'}" proj="${2//\'/\\\'}" js
  js="$(_tt_hr_card_js "$who" "$proj" "$TT_HR_BTN_REMIND")"
  [ "$(playwright-cli eval "() => { $js const b=HIT(); if(!b) return 'false'; b.click(); return 'true'; }" 2>/dev/null | _tt_eval_str)" = "true" ] || return 1
  tt_hr_remind_confirm
}

# tt_hr_card_gated_here <consultantName> <projectName> — true | false: that card,
# in the week already selected, shows btnClientRemindBlocked.
tt_hr_card_gated_here() {
  local who="${1//\'/\\\'}" proj="${2//\'/\\\'}" js
  js="$(_tt_hr_card_js "$who" "$proj" "$TT_HR_BTN_REMIND_BLOCKED")"
  playwright-cli eval "() => { $js return String(!!HIT()); }" 2>/dev/null | _tt_eval_str
}

# tt_hr_remind_e2e_entry <consultantName> [projectName]
#
# Returns 0 (week label on STDOUT) once the Remind was clicked AND its TT-768
# confirmation was read and dismissed; 1 when no remindable card matched; 2 when
# the card was reminded but the confirmation did not come (see tt_hr_remind_confirm
# — the week label is still printed).
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
    # ONE CARD = ONE Remind button. The climb from each Remind stops the moment an
    # ancestor holds more than one, so it can only match text on its OWN card. It used
    # to climb nine parents unchecked, which from the FIRST card reaches the gallery
    # holding every card - so when another consultant's entry (dev's Manual Consultant
    # Three on Manual TT744, 2026-09-28) sat first in the week, this clicked THAT
    # card's Remind while reporting the E2E entry reminded, and the mail - and the
    # token link a caller then read - went to a different approver.
    # POLL, rather than looking once four seconds after the click. Selecting a week
    # reloads the entries gallery, and an entry submitted moments ago reaches the
    # queue ASYNCHRONOUSLY — tt647_wait_for_card polls up to 60s for that same
    # reason. Looking once is what made a slow reload read as an absent entry.
    for i in $(seq 1 8); do
      if playwright-cli eval "() => { const rs=[...document.querySelectorAll('$TT_HR_BTN_REMIND')]; const proj='$proj'; for(const r of rs){ let el=r; for(let i=0;i<9;i++){ el=el.parentElement; if(!el) break; if(el.querySelectorAll('$TT_HR_BTN_REMIND').length!==1) break; const t=el.innerText||''; if(t.indexOf('$who')>=0 && (proj==='' || t.indexOf(proj)>=0)){ r.click(); return 'true'; } } } return 'false'; }" 2>/dev/null | sed -n '2p' | grep -qiw true; then
        echo "$lbl"
        # TT-768: the Remind ends in a BLOCKING "Reminder sent to …" message. Clear
        # it here, so the caller's next click is not swallowed by the modal underlay.
        tt_hr_remind_confirm
        return $?
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
# tt_customer_link <consultantName> <projectName> <approverEmail> [weekKey]
#
# A LIVE customer-approval link whose page lists a pending <consultantName> entry on
# <projectName>, and that entry's week. Sets:
#
#   TT_CL_LINK      the /p/customer-approval/<token> URL, read from a real email
#   TT_CL_WEEK      the entry's week as a tt_week_key ("Sep 27 - Oct 03")
#   TT_CL_WEEKFRAG  its leading "Mon DD", which every rendering of that week contains
#   TT_CL_HOW       reused | created | reminded — which path produced them
#
# Pass [weekKey] when the caller has already made the entry it wants: only a row for
# that week then counts, and nothing is created. tt_fail's when no path yields a link.
#
# WHY THIS EXISTS. The customer specs used to get their link by pressing HR's Remind
# and reading the mail it sent. Remind is allowed once per entry per day (by design),
# so from the second spec of the day onward the button was gone (remindCards=0,
# remindGated=1), the walk reported "no pending entry" about an entry that was
# sitting in the queue, and each spec fell back to submitting a brand-new week as the
# consultant AND waiting on the outbound mail queue for a fresh message — 300-450 s
# of an 8 m budget, and the specs timed out.
#
# The link does not need to be fresh. Since per-email approval links (model,
# 2026-09-24) every approval email carries its own token, none is revoked by a later
# one, and each works until its own 7-day expiry; the page it opens lists everything
# that approver has waiting. So, in order:
#
#   1. REUSE: read the approval links already in Emails Sent for <approverEmail> and
#      open each cold until one lists our row. "Not revoked" is not the same as
#      "covers this entry" (a link from before this run's 00-setup rebuilt the
#      project may open and list nothing of ours), so a link is trusted only when its
#      own page shows the row.
#   2. CREATE: a live link that lists no row of ours means nothing is pending, so
#      submit one week as the consultant and look again through the same link.
#   3. REMIND: only when no link in the mailbox can be made to show the row — the
#      first customer spec of every run, since the bookend clears remove the E2E
#      approver's mail — press Remind (submitting a week first when there is nothing
#      to remind) and read the link of the mail it raises by searching for the
#      approver, which sees a QUEUED message the newest-first list does not.
#
# Every spec still opens the link itself afterwards and asserts the row, the popup's
# project and the week, so a wrong answer here fails the spec instead of passing it.
# ---------------------------------------------------------------------------

# _tt_cl_page <consultantName> <projectName> — what the token page in this browser
# shows, once it has painted. Echoes one line:
#   ROWS:<period>|<period>…  our pending rows, each its card's week (txtCustWeek)
#
# The week is read from the card's own WEEK field, .mx-name-txtCustWeek. Until
# TT-769 (deployed 2026-10-02) the row was one line ending "<n> hours <period>",
# and this took the text after "hours". TT-769 relaid the card as label/value
# facts PROJECT, WEEK, TOTAL "<n> hours" - hours LAST - so that slice returned ''
# for every row: links listing our week logged "ROWS:" / "ROWS:|", tt_week_key('')
# never matched, and all three customer specs timed out "no approval email ...
# within 240 s of the Remind" (run 37409110184) with the right mail in hand. A
# matching card without the field is reported, not read as an empty week.
#   LIVE                     an approval page with no row of ours
#   DEAD                     the link-invalid page, or nothing painted in ~25 s
_tt_cl_page() {
  local who="${1//\'/\\\'}" proj="${2//\'/\\\'}" i r seen=""
  for i in $(seq 1 25); do
    r="$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galPendingEntries'); const e=document.querySelector('.mx-name-containerNoPendingApprovals'); const bad=document.querySelector('.mx-name-textLinkInvalidHeading'); if(!g && !e) return bad ? 'DEAD' : 'WAIT'; if(!g) return 'LIVE'; const txt=r=>((r.innerText||'').replace(/\u00a0/g,' ').replace(/\s+/g,' ').trim()); const rows=[...g.querySelectorAll('.widget-gallery-item')].filter(it=>{ const t=txt(it); return t.indexOf('$who')>=0 && t.indexOf('$proj')>=0 && t.indexOf('hours')>=0; }).map(it=>{ const w=it.querySelector('.mx-name-txtCustWeek'); return w ? txt(w) : '(no txtCustWeek in: '+txt(it).slice(0,100)+')'; }); return rows.length ? 'ROWS:'+rows.join('|') : 'LIVE'; }" 2>/dev/null | _tt_eval_str)"
    case "$r" in
      DEAD|ROWS:*) echo "$r"; return 0 ;;
      LIVE)
        # The gallery can paint before its items arrive: an empty answer is only
        # believed once it has been seen twice, a second apart.
        [ -n "$seen" ] && { echo "LIVE"; return 0; }
        seen=1 ;;
    esac
    sleep 1
  done
  echo "DEAD"
}

# _tt_cl_try <consultantName> <projectName> <weekKey|''> <link>…
# Open each link cold; on the first whose page lists a matching row set TT_CL_LINK /
# TT_CL_WEEK and return 0. Links that opened a live page are left in _TT_CL_LIVE.
_tt_cl_try() {
  local who="$1" proj="$2" want="$3" link page p key tok IFS_SAVE
  shift 3
  _TT_CL_LIVE=""
  for link in "$@"; do
    [ -n "$link" ] || continue
    playwright-cli cookie-clear >/dev/null 2>&1
    playwright-cli goto "$link" >/dev/null 2>&1
    page="$(_tt_cl_page "$who" "$proj")"
    tok="${link##*/customer-approval/}"
    echo "  [customer-link] link ${tok:0:6}...: ${page:0:160}" >&2
    case "$page" in
      DEAD) continue ;;
    esac
    _TT_CL_LIVE="$_TT_CL_LIVE $link"
    case "$page" in
      ROWS:*)
        IFS_SAVE="$IFS"; IFS='|'
        for p in ${page#ROWS:}; do
          key="$(tt_week_key "$p")"
          [ -n "$key" ] || continue
          if [ -z "$want" ] || [ "$key" = "$want" ]; then
            IFS="$IFS_SAVE"
            TT_CL_LINK="$link"; TT_CL_WEEK="$key"
            return 0
          fi
        done
        IFS="$IFS_SAVE" ;;
    esac
  done
  return 1
}

tt_customer_link() {
  local who="$1" proj="$2" approver="$3" want="${4:-}" links started i
  TT_CL_LINK=""; TT_CL_WEEK=""; TT_CL_WEEKFRAG=""; TT_CL_HOW=""
  if [ -n "$want" ]; then want="$(tt_week_key "$want")"; fi

  # ---- 1. reuse a link already in the mailbox
  links="$(tt_mail_links_to "$approver" customer-approval)"
  case "$links" in
    NOGRID|NOFILTER) tt_mail_prepare; links="" ;;   # tt_fail's with the real reason if mail is unreadable
  esac
  # shellcheck disable=SC2086 # one link per word, by construction
  if _tt_cl_try "$who" "$proj" "$want" $links; then
    TT_CL_HOW="reused"
  elif [ -n "$_TT_CL_LIVE" ] && [ -z "$want" ]; then
    # ---- 2. a live link that lists nothing of ours: nothing is pending, so make one
    echo "  [customer-link] a live link lists no pending '$who' / '$proj' row - submitting one as the consultant" >&2
    tt_login "e2e_consultant" "My Timesheets"
    tt_consultant_submit_project_row "$proj"
    # The entry reaches AwaitingCustomerApproval asynchronously; give it a few looks.
    # Without the submitted week there is nothing to look for, and step 3 finds the
    # new card on HR's tab instead.
    if [ -n "${TT_SUBMITTED_WEEK:-}" ]; then
      for i in 1 2 3; do
        # shellcheck disable=SC2086
        if _tt_cl_try "$who" "$proj" "$TT_SUBMITTED_WEEK" $_TT_CL_LIVE; then TT_CL_HOW="created"; break; fi
        sleep 5
      done
    fi
  fi

  # ---- 3. remind, and read the link out of the mail it raises
  # The only path when the mailbox holds no usable link - which is EVERY run's first
  # customer spec, because the bookend clears take the E2E approver's mail with them
  # (measured 2026-09-30: after a run, Emails Sent holds nothing to that address).
  if [ -z "$TT_CL_HOW" ]; then
    # Nothing in the mailbox for this approver at all means the clear ran and nothing
    # has been submitted since, so HR's queue is empty too: submit first, rather than
    # paying for a walk of every listed week to learn that. A caller that named its
    # week made its own entry already.
    if [ -z "$want" ] && [ -z "$links" ]; then
      echo "  [customer-link] no approval mail to '$approver' yet - submitting a '$proj' week as the consultant" >&2
      tt_login "e2e_consultant" "My Timesheets"
      tt_consultant_submit_project_row "$proj"
    fi
    echo "  [customer-link] no link in the mailbox shows a pending '$who' / '$proj' row - reminding" >&2
    tt_login "e2e_hr" "$TT_HR_READY"
    tt_hr_click_tab "Client approval"
    sleep 2
    local _rc=0
    TT_CL_WEEK="$(tt_hr_remind_e2e_entry "$who" "$proj")" || _rc=$?
    # 2 = reminded, but no TT-768 confirmation: the mail may not have gone, so do
    # not go and submit another week on top of it - say what happened.
    [ "$_rc" -eq 2 ] && tt_fail "Remind on '$who' / '$proj' (week '$TT_CL_WEEK') did not end in TT-768's 'Reminder sent to {name} ({email}).' message - see the [remind] line above"
    if [ "$_rc" -ne 0 ]; then
      [ -z "$want" ] || tt_fail "no live link lists week '$want' for '$who' / '$proj', and HR has nothing to remind for it"
      echo "  [customer-link] HR has nothing to remind - submitting one as the consultant" >&2
      tt_login "e2e_consultant" "My Timesheets"
      tt_consultant_submit_project_row "$proj"
      tt_login "e2e_hr" "$TT_HR_READY"
      tt_hr_click_tab "Client approval"
      sleep 2
      _rc=0
      TT_CL_WEEK="$(tt_hr_remind_e2e_entry "$who" "$proj")" || _rc=$?
      [ "$_rc" -eq 2 ] && tt_fail "Remind on '$who' / '$proj' (week '$TT_CL_WEEK') did not end in TT-768's 'Reminder sent to {name} ({email}).' message - see the [remind] line above"
      [ "$_rc" -eq 0 ] || tt_fail "still no pending '$who' entry on '$proj' after creating one"
    fi
    TT_CL_WEEK="$(tt_week_key "$TT_CL_WEEK")"
    # A caller that named its week gets that week: the link lists everything the
    # approver has waiting, whichever card the Remind happened to land on.
    [ -z "$want" ] || TT_CL_WEEK="$want"
    # Read the new link by SEARCHING for the approver, not by waiting for it to
    # surface in the unfiltered list: a message is listed from QUEUED, but it has no
    # SentDate until the ~2-minute send event delivers it, so it sorts to the far end
    # of the newest-first list, and tt_mail_token only saw it after delivery. A search
    # finds it at once. Freshness is proven the same way as a reused link - the page
    # it opens has to list the reminded week.
    started="$(date +%s)"
    while [ -z "$TT_CL_HOW" ]; do
      links="$(tt_mail_links_to "$approver" customer-approval)"
      case "$links" in NOGRID|NOFILTER) links="" ;; esac
      # shellcheck disable=SC2086
      if [ -n "$links" ] && _tt_cl_try "$who" "$proj" "$TT_CL_WEEK" $links; then
        TT_CL_HOW="reminded"; break
      fi
      [ $(( $(date +%s) - started )) -ge 240 ]         && tt_fail "no approval email to '$approver' whose link lists week '$TT_CL_WEEK' within 240 s of the Remind"
      sleep 10
    done
  fi

  case "$TT_CL_LINK" in
    *"/p/customer-approval/"*) ;;
    *) tt_fail "the approval link is not a customer-approval link: $TT_CL_LINK" ;;
  esac
  [ -n "$TT_CL_WEEK" ] || tt_fail "could not determine the week under test"
  TT_CL_WEEKFRAG="${TT_CL_WEEK%% - *}"
  echo "  customer link for '$who' / '$proj' week '$TT_CL_WEEK' ($TT_CL_HOW)"
  return 0
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
