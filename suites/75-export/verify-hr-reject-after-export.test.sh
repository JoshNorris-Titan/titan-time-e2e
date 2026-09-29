#!/usr/bin/env bash
# verify-hr-reject-after-export.test.sh
#
# Rejecting an entry AFTER it has been exported (state transition T19,
# Exported -> Rejected) — and the hours arithmetic that goes with it.
#
# WHY THIS EXISTS. Once a week has been exported it has, in practice, been
# invoiced. ACT_RejectAfterExport is the only route back from there, and it was
# completely untested. Its own annotation states what it must do:
#
#   "Sets an assignment entry status to reject and subtracts the entry's total
#    hours worked from its assignment's total hours worked"
#
# The subtraction is the part worth guarding. If it silently stopped happening the
# entry would still visibly leave the Sent tab, every UI-level check would pass, and
# the assignment would quietly over-report hours worked for the rest of its life.
# So this asserts the exact arithmetic, not just the status change.
#
# WHY IT LIVES IN 75-export. It needs an entry in Exported state, and the only route
# there is Process -> Export All, which exports everything awaiting export across the
# environment. Rather than trigger that from an early folder, this runs AFTER
# suites/70-tickets/tt683/, reusing the entries those tests have already exported.
# The fallback below can still drive the chain itself, and says so loudly when it does.
#
# WHERE THE ASSIGNMENT TOTAL IS READ. Titan Manager has no assignment data grid — an
# earlier version of this test looked for one and could never have passed. The TM
# landing page is three cards (Customers / Projects / Consultants) over galleries, and
# an assignment's hours are shown in exactly one place: the Consultant Details popup,
# on the assignment card, as
#
#     WORKED/BUDGETED HOURS
#     200/400hrs
#
# That whole string is one text-template parameter fed by
# formatDecimal($IteratorAssignment/TotalHoursWorked,'#,###,###.##'), so it carries
# the two decimals the assertion needs — it is a rendering of the real attribute, not
# a rounded summary.
#
# THE REJECT IS NOW TWO STEPS. btnRejectAfterExport used to call
# Main.ACT_RejectAfterExport on the click, and the rejection landed there and then.
# It now opens Main.AssignmentEntry_RejectPage — the same 'Add Rejection Comments'
# popup the Weekly and Monthly tabs use — because the flow refuses to reject without
# a comment. So pressing the card's Reject is only half the action; see
# hre_confirm_reject_popup for the other half.
#
# That change also removed a canned comment. Main.ACT_RejectAfterExport used to set
# RejectionComment = 'Rejected by HR after export.' in the same change action as the
# status, overwriting anything present, and that string was what reached the
# ChangeLog and the consultant's email. It is gone; the comment typed below is what
# lands. The empty-comment refusal on this route is asserted by
# verify-hr-export-reject-guard, which runs before this step and consumes nothing.
#
# SELECTORS. btnRejectAfterExport, cardConsultants, galConsultants, cardConsultantRow,
# txtConsultantName, txtConsultantSearch and the popup's txtRejectionComment are all
# real names, and since the 2026-09-28 Sent rebuild so are the Sent row's cells
# (txtSentConsultant, txtSentProject, txtSentTotalHours). The one value still read
# out of an unnamed widget is anchored on LABEL TEXT instead: 'WORKED/BUDGETED
# HOURS' in the popup, whose value widget is the auto-named text18 inside a list view and could not be
# renamed anyway — it lives in a snippet, which the model tooling cannot reach. The
# popup's footer Reject is still the auto-named actionButton1, so it is pressed by
# caption.
#
# Consumes one exported entry.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt683.sh"
# For tt_click_button_exact / tt_dismiss_dialogs, which the comment popup needs.
source "$TT_ROOT/lib/_rejection.sh"

CONSULTANT_NAME="${TT_EXPORT_CONSULTANT:-E2E Consultant}"
REJECT_COMMENT="E2E automated post-export reject - hours returned to the assignment"

# ---------------------------------------------------------------------- helpers

# hre_open_reject_tab - open the Sent tab and expand the week holding an exported
# entry of our consultant's. Prints the tab label; returns 1 when no Sent week
# holds one.
#
# SENT IS WEEK GROUPS SINCE 2026-09-28 (model b2202878 / 771be886). The post-export
# Reject (.mx-name-btnRejectAfterExport) is on each Sent ROW, and a row exists only
# while its week's group is expanded - only the newest starts that way, and only the
# last 8 weeks are listed until "Load more weeks" is pressed. So "the tab that shows
# the button" is no longer a question a tab walk can answer: the button is on Sent,
# and whether it is in the DOM depends on which week is open. This used to walk
# every tab looking for a visible button; it now opens Sent by widget and searches
# its weeks, Load more included, for the consultant's row.
hre_open_reject_tab() {
  tt_login "e2e_hr" "$TT_HR_READY"
  tt_hr_try_click_tab "Sent" || return 1
  tt_hr_wait_pane "Sent week groups" >/dev/null
  tt_hr_find_group_for "$CONSULTANT_NAME" all >/dev/null || return 1
  echo "Sent"
}

hre_has_reject_button() {
  playwright-cli eval "() => String([...document.querySelectorAll('.mx-name-btnRejectAfterExport')].some(b => b.offsetParent !== null))" 2>/dev/null | _tt_eval_str
}

# hre_card_facts [project] - "<week>~~<consultant>~~<project>~~<hours>~~" for the
# first expanded Sent row whose consultant cell is exactly $CONSULTANT_NAME (and,
# given one, whose project matches), preferring a row with hours - rejecting a
# 0-hour entry would move nothing and make the hours assertion vacuous.
#
# Read from the row's named cells (txtSentConsultant / txtSentProject /
# txtSentTotalHours); the old card carried PROJECT / WEEK / TOTAL HOURS labels to
# anchor on, the table row carries values only. The week is the row's GROUP.
hre_card_facts() {
  playwright-cli eval "() => { $(_tt_hr_grp_js) if (HG.kind !== 'Sent') return ''; const c = (r, n) => ((r.querySelector('.mx-name-txtSent' + n) || {}).innerText || '').replace(/\s+/g, ' ').trim(); const num = s => parseFloat(String(s).replace(/[^0-9.-]/g, '')) || 0; const out = []; for (const x of HG.groups().filter(y => y.open)) for (const r of HG.rows(x.g)) { if (c(r, 'Consultant') !== '$CONSULTANT_NAME') continue; if (!r.querySelector('.mx-name-btnRejectAfterExport')) continue; out.push([x.key || x.label, c(r, 'Consultant'), c(r, 'Project'), c(r, 'TotalHours'), ''].join('~~')); } if (!out.length) return ''; return out.find(l => num(l.split('~~')[3]) > 0) || out[0]; }" 2>/dev/null | _tt_eval_str | grep -v '^null$'
}

# hre_card_present <project> - is our consultant's row for <project> still in the
# week it was found in? Re-expands that week first: rejecting refreshes the tab,
# which puts the groups back to "newest open", and ABSENCE is this file's pass
# condition - reading a collapsed group would call the row gone when it was only
# folded away. A week that no longer exists at all has no rows, so that is 'false'.
hre_card_present() {
  tt_hr_select_week "$WEEK" || { echo false; return 0; }
  if [ -n "$(tt_hr_row_facts "$CONSULTANT_NAME" "$1")" ]; then echo true; else echo false; fi
}

hre_click_reject() {
  case "$(tt_hr_row_click "$CONSULTANT_NAME" "$1" ".mx-name-btnRejectAfterExport")" in
    ok) echo clicked ;;
    *)  echo nf ;;
  esac
}

# hre_confirm_reject_popup <comment> — the second half of the reject: fill the
# 'Add Rejection Comments' popup and press its Reject.
#
# Return codes rather than a printed marker, because every one of these states is a
# different failure sentence and a command substitution would capture the helper's
# own diagnostics into the value as well:
#   1 no popup     — btnRejectAfterExport is not opening Main.AssignmentEntry_RejectPage
#   2 no field     — the popup opened without its comment box
#   3 no confirm   — the comment went in but the popup's Reject could not be pressed
#
# The comment box is matched by name first and structurally second: the popup is
# shared with the Weekly and Monthly routes, and this suite has been bitten before
# by widget renumbering in shared popups.
hre_confirm_reject_popup() {
  local r
  r="$(playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); if(!d) return 'nopopup'; const ta=d.querySelector('.mx-name-txtRejectionComment textarea') || d.querySelector('textarea') || [...d.querySelectorAll('input[type=text]')].pop(); if(!ta) return 'nofield'; const set=Object.getOwnPropertyDescriptor(ta.__proto__,'value').set; set.call(ta,'$1'); ta.dispatchEvent(new Event('input',{bubbles:true})); ta.dispatchEvent(new Event('change',{bubbles:true})); ta.blur(); return 'typed'; }" 2>/dev/null | _tt_eval_str)"
  case "$r" in
    typed)   : ;;
    nopopup) return 1 ;;
    *)       return 2 ;;
  esac
  sleep 1
  tt_click_button_exact "reject" popup || return 3
  sleep 4
  tt_dismiss_dialogs
  return 0
}

# hre_tm_read <project> — the whole Titan Manager read in ONE eval: open the
# Consultants pane, open our consultant's details popup, and pull the worked hours off
# the assignment card for <project>. Folded into a single in-page async function on
# purpose — every playwright-cli call is a fresh node process, and the polling this
# needs would otherwise cost a dozen of them.
#
# Each rung reports its own miss ('NOPANE', 'NOLIST', ...) so a failure names the step
# that broke instead of just "hours not found".
hre_tm_read() {
  playwright-cli eval "async () => {
    const wait=(f,n)=>new Promise(async res=>{ for(let i=0;i<n;i++){ if(f()) return res(true); await new Promise(r=>setTimeout(r,500)); } res(false); });
    if(!document.querySelector('.mx-name-galConsultants')){
      const c=document.querySelector('.mx-name-cardConsultants');
      if(!c) return 'NOPANE';
      c.click();
    }
    if(!await wait(()=>document.querySelector('.mx-name-cardConsultantRow'),40)) return 'NOLIST';
    const row=[...document.querySelectorAll('.mx-name-cardConsultantRow')].find(r=>((r.querySelector('.mx-name-txtConsultantName')||{}).innerText||'').trim()==='$CONSULTANT_NAME');
    if(!row) return 'NOCONSULTANT';
    row.click();
    if(!await wait(()=>{ const m=document.querySelector('.modal-content,.mx-window'); return m && /Consultant Details/.test(m.innerText||''); },40)) return 'NOPOPUP';
    await new Promise(r=>setTimeout(r,1500));
    const m=document.querySelector('.modal-content,.mx-window');
    // Scope to the individual assignment card. A list view repeats every mx-name-*
    // per row, so an unscoped read would always answer for the first assignment.
    const items=[...m.querySelectorAll('.mx-name-listView1 li')];
    const first=(li)=>((li.innerText||'').split('\\n')[0]||'').trim();
    const hit=items.find(li=>first(li)==='$1');
    if(!hit) return 'NOASSIGNMENT:'+items.map(first).join(' / ');
    const mm=(hit.innerText||'').match(/WORKED\\/BUDGETED HOURS\\s*([0-9.,]+)\\s*\\//i);
    return mm ? 'HOURS:'+mm[1] : 'NOHOURS:'+(hit.innerText||'').replace(/\\n/g,' | ');
  }" 2>/dev/null | _tt_eval_str
}

# hre_assignment_hours <project> — as Titan Manager, the assignment's Total Hours
# Worked. Starts from a fresh landing page every time, so a popup left open by the
# previous read (or a pane left on Customers) cannot answer with a stale number.
hre_assignment_hours() {
  local r
  playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
  sleep 4
  r="$(hre_tm_read "$1")"
  # The gallery renders every consultant today, but it is a gallery and may page as
  # the environment grows — so a miss narrows it with the search box and asks again
  # before it is allowed to become a failure.
  if [ "$r" = "NOCONSULTANT" ]; then
    playwright-cli click ".mx-name-txtConsultantSearch input" >/dev/null 2>&1
    playwright-cli type "$CONSULTANT_NAME" >/dev/null 2>&1
    sleep 3
    r="$(hre_tm_read "$1")"
  fi
  printf '%s' "$r"
}

# hre_check_read <raw> <project> — turn a hre_assignment_hours marker into a failure
# that names what was missing. Shared by the before and the after read.
hre_check_read() {
  case "$1" in
    HOURS:*)        return 0 ;;
    NOPANE)         tt_fail "the Titan Manager landing page has no Consultants card (.mx-name-cardConsultants) — the assignment hours cannot be reached" ;;
    NOLIST)         tt_fail "the Consultants pane never rendered a consultant row (.mx-name-cardConsultantRow)" ;;
    NOCONSULTANT)   tt_fail "no consultant card named '$CONSULTANT_NAME' in the Titan Manager consultants gallery, with or without the search filter" ;;
    NOPOPUP)        tt_fail "clicking '$CONSULTANT_NAME' did not open the Consultant Details popup" ;;
    NOASSIGNMENT:*) tt_fail "'$CONSULTANT_NAME' has no assignment for project '$2'; the popup lists: ${1#NOASSIGNMENT:}" ;;
    NOHOURS:*)      tt_fail "the assignment card for '$2' shows no WORKED/BUDGETED HOURS value: ${1#NOHOURS:}" ;;
    *)              tt_fail "unrecognised response reading the assignment hours for '$2': '$1'" ;;
  esac
}

hre_num() {  # strip anything that is not part of a decimal number
  printf '%s' "$1" | tr -d ' ,' | grep -oE '^-?[0-9]+(\.[0-9]+)?' || true
}

# --------------------------------------------------------- 1. find an exported entry

# hre_find_exported — set TAB and FACTS from whatever is on the HR dashboard now.
# Returns 1 when there is nothing of ours to reject, WITHOUT deciding why.
#
# The two ways to come up empty used to be handled a step apart, and only the
# second one reached the Process/Export fallback: an environment with no exported
# entries at all failed at "no HR dashboard tab exposes btnRejectAfterExport",
# which reads as "the feature is gone from the UI" when the truth was "the Sent
# tab is empty" — and the chain that would have filled it never ran.
hre_find_exported() {
  TAB="$(hre_open_reject_tab)" || return 1
  FACTS="$(hre_card_facts)"
  [ -n "$FACTS" ]
}

TAB=""
FACTS=""
if ! hre_find_exported; then
  echo "no exported entry for '$CONSULTANT_NAME' — driving Process + Export All to create one"
  echo "  NOTE: Export All exports EVERY entry awaiting export on this environment."
  # Each step runs in a SUBSHELL. These tt683 helpers end in tt_fail when the
  # dashboard has nothing for them — correct for the tt683 tests that own them, but
  # here they are a best-effort attempt to manufacture a fixture, and tt_fail's exit
  # would kill this script outright. With stderr redirected away it did exactly that
  # and printed nothing: an environment with an empty "Monthly To Be Invoiced" tab
  # ended the run at exit 1 with no message. ( ) keeps the exit inside the step; the
  # browser-side effects it did manage still stand.
  ( tt683_open_toprocess_tab )                            >/dev/null 2>&1 || true
  ( tt683_process_all_toprocess )                         >/dev/null 2>&1 || true
  ( tt683_open_export_tab && tt683_click_export_all )     >/dev/null 2>&1 || true
  sleep 5
  tt_clear_dialogs 8 >/dev/null 2>&1 || true
  hre_find_exported \
    || tt_fail "no exported entry for '$CONSULTANT_NAME' is reachable on any HR tab, and the Process/Export chain did not produce one — there is nothing awaiting export on this environment. Run suites/70-tickets/tt683/verify-tt683-a0-seed-awaiting-export.test.sh first. (If the Sent tab DOES show cards but none carries .mx-name-btnRejectAfterExport, post-export rejection has been removed from the UI and that is the real failure.)"
fi
echo "post-export reject lives on tab: $TAB"

WEEK="$(printf '%s' "$FACTS" | awk -F'~~' '{print $1}')"
PROJECT="$(printf '%s' "$FACTS" | awk -F'~~' '{print $3}')"
HOURS_RAW="$(printf '%s' "$FACTS" | awk -F'~~' '{print $4}')"
HOURS="$(hre_num "$HOURS_RAW")"

[ -n "$PROJECT" ] || tt_fail "could not read PROJECT off the exported card: $FACTS"
[ -n "$HOURS" ]   || tt_fail "could not read a numeric TOTAL HOURS off the exported card (got '$HOURS_RAW'): $FACTS"
echo "exported entry: project='$PROJECT' week='$WEEK' hours=$HOURS"

# ------------------------------------------- 2. the assignment total, before
tt_login "e2e_tm" "Add Customer"
BEFORE_RAW="$(hre_assignment_hours "$PROJECT")"
hre_check_read "$BEFORE_RAW" "$PROJECT"
BEFORE="$(hre_num "${BEFORE_RAW#HOURS:}")"
[ -n "$BEFORE" ] || tt_fail "assignment Total Hours Worked is not numeric before the reject (got '$BEFORE_RAW')"
echo "assignment total hours worked, before: $BEFORE"

# -------------------------------------------------------- 3. reject after export
TAB="$(hre_open_reject_tab)" || tt_fail "could not return to the post-export reject tab"
tt_hr_select_week "$WEEK" \
  || tt_fail "could not re-open Sent week '$WEEK', where the exported '$PROJECT' entry was found a moment ago"
rc="$(hre_click_reject "$PROJECT")"
[ "$rc" = "clicked" ] \
  || tt_fail "could not press Reject on the exported card for '$PROJECT' (state: $rc)"
sleep 4

# The card's Reject opens the comment popup; the rejection happens when the popup's
# own Reject is pressed with a comment in the box.
hre_confirm_reject_popup "$REJECT_COMMENT"
case "$?" in
  1) tt_fail "pressing Reject on the exported card opened no comment popup. btnRejectAfterExport is meant to open Main.AssignmentEntry_RejectPage; if it is calling Main.ACT_RejectAfterExport directly again then the post-export route captures no comment at all, and this test's own comment would be replaced by whatever the flow writes. verify-hr-export-reject-guard asserts the same thing from the other side." ;;
  2) tt_fail "the comment popup opened but exposed no comment field (.mx-name-txtRejectionComment, or any textarea) - there is nowhere to type the reason the flow now insists on, so no rejection from this tab can succeed" ;;
  3) tt_fail "the comment was typed but no Reject button in the popup could be pressed - the popup opened and then would not confirm" ;;
esac
sleep 4

# The card must leave the tab. Poll — the flow commits and refreshes every tab.
gone=""
for _ in $(seq 1 10); do
  [ "$(hre_card_present "$PROJECT")" = "false" ] && { gone=1; break; }
  sleep 3
done
[ -n "$gone" ] \
  || tt_fail "the exported entry for '$PROJECT' is still on tab '$TAB' after Reject — one of the two guards in front of the rejection refused it. 'Exported?' in Main.ACT_RejectAfterExport is the old suspect; the newer one is 'Left Comments?', which refuses when the comment did not reach the server, and a Mendix text area hands its value over on BLUR. hre_confirm_reject_popup blurs the box for exactly that reason, so a refusal here means the blur is not committing rather than that the comment was never typed."

# ---------------------------------------- 4. the arithmetic, which is the point
tt_login "e2e_tm" "Add Customer"

EXPECTED="$(awk -v b="$BEFORE" -v h="$HOURS" 'BEGIN{printf "%.2f", b-h}')"
AFTER_RAW=""
AFTER=""
for _ in $(seq 1 6); do
  AFTER_RAW="$(hre_assignment_hours "$PROJECT")"
  AFTER="$(hre_num "${AFTER_RAW#HOURS:}")"
  [ -n "$AFTER" ] && [ "$(awk -v a="$AFTER" -v e="$EXPECTED" 'BEGIN{print (a-e<0.005 && e-a<0.005) ? "y" : "n"}')" = "y" ] && break
  sleep 4
done
hre_check_read "$AFTER_RAW" "$PROJECT"
[ -n "$AFTER" ] || tt_fail "could not read the assignment total after the reject (got '$AFTER_RAW')"

same="$(awk -v a="$AFTER" -v e="$EXPECTED" 'BEGIN{print (a-e<0.005 && e-a<0.005) ? "y" : "n"}')"
if [ "$same" != "y" ]; then
  unchanged="$(awk -v a="$AFTER" -v b="$BEFORE" 'BEGIN{print (a-b<0.005 && b-a<0.005) ? "y" : "n"}')"
  if [ "$unchanged" = "y" ]; then
    tt_fail "the entry was rejected but the assignment total stayed at $BEFORE — the hours subtraction in ACT_RejectAfterExport did not happen, so '$PROJECT' now over-reports $HOURS hours"
  fi
  tt_fail "assignment total went $BEFORE -> $AFTER after rejecting a $HOURS-hour entry; expected $EXPECTED"
fi

echo "PASS: verify-hr-reject-after-export — exported entry for '$PROJECT' ($WEEK, ${HOURS}h) rejected; assignment total $BEFORE -> $AFTER as expected"
