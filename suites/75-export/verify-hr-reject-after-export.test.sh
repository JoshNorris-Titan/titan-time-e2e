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
# SELECTORS. btnRejectAfterExport, cardConsultants, galConsultants, cardConsultantRow,
# txtConsultantName and txtConsultantSearch are all real names. The two values read
# out of unnamed widgets are anchored on LABEL TEXT instead: 'TOTAL HOURS' on the HR
# card, and 'WORKED/BUDGETED HOURS' in the popup, whose value widget is the
# auto-named text18 inside a list view and could not be renamed anyway — it lives in
# a snippet, which the model tooling cannot reach.
#
# Consumes one exported entry.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt683.sh"

CONSULTANT_NAME="${TT_EXPORT_CONSULTANT:-E2E Consultant}"

# ---------------------------------------------------------------------- helpers

# hre_open_reject_tab — land on whichever HR tab exposes the post-export Reject.
# The tab-switch controls were never named, so tabs are selected by their caption;
# which tab carries this button is a model decision, so it is discovered, not assumed.
#
# tt_try_click_text, not tt_click_text: the fatal version EXITS THE WHOLE TEST when a
# caption is missing, which is exactly wrong in a loop over candidate targets — and
# this caller runs inside $( ), so its diagnosis would have been captured into $TAB
# and the run would have blamed "no tab exposes the button" instead of the caption.
hre_open_reject_tab() {
  local lbl labels
  tt_login "e2e_hr" "WEEKLY TO PROCESS"
  if [ "$(hre_has_reject_button)" = "true" ]; then echo "(landing tab)"; return 0; fi
  labels="$(tt683_tab_labels)"
  local IFS='|'
  for lbl in $labels; do
    [ -n "$lbl" ] || continue
    unset IFS
    tt_try_click_text "$lbl" || { IFS='|'; continue; }
    sleep 2
    if [ "$(hre_has_reject_button)" = "true" ]; then echo "$lbl"; return 0; fi
    IFS='|'
  done
  unset IFS
  return 1
}

hre_has_reject_button() {
  playwright-cli eval "() => String([...document.querySelectorAll('.mx-name-btnRejectAfterExport')].some(b => b.offsetParent !== null))" 2>/dev/null | _tt_eval_str
}

# hre_card_facts — pick an exported card for our consultant and read PROJECT, WEEK
# and TOTAL HOURS off it. Values are taken as "the line after the label", which is
# how the card stacks its label/value pairs; that survives the widget renumbering
# that auto-generated names do not.
#
# It picks a card with HOURS > 0 when there is one. Export All exports everything
# awaiting export, so the Sent tab routinely holds several of our cards and some of
# them are zero-hour weeks — and a zero-hour entry makes the whole point of this
# test vacuous: 0 subtracted from the assignment total is indistinguishable from the
# subtraction never happening.
hre_card_facts() {
  playwright-cli eval "() => { const btns=[...document.querySelectorAll('.mx-name-btnRejectAfterExport')].filter(b=>b.offsetParent!==null); const cards=[]; for(const b of btns){ let p=b; for(let k=0;k<12;k++){ if(!p.parentElement) break; p=p.parentElement; const t=(p.innerText||''); if(t.length<1500 && t.indexOf('$CONSULTANT_NAME')>=0 && t.toUpperCase().indexOf('TOTAL HOURS')>=0){ const lines=t.split('\\n').map(s=>s.trim()).filter(Boolean); const after=(lbl)=>{ const i=lines.findIndex(x=>x.toUpperCase()===lbl); return (i>=0 && i+1<lines.length) ? lines[i+1] : ''; }; cards.push({project:after('PROJECT'), week:after('WEEK'), hours:after('TOTAL HOURS')}); break; } } } if(!cards.length) return ''; const num=(s)=>parseFloat(String(s).replace(/[^0-9.-]/g,''))||0; return JSON.stringify(cards.find(c=>num(c.hours)>0) || cards[0]); }" 2>/dev/null | _tt_eval_str
}

# hre_card_present <project> — is an exported card for our consultant on THIS project
# still on the tab? Matched exactly the way hre_click_reject matches, so "the card I
# pressed Reject on" and "the card I am waiting to disappear" are the same notion.
#
# The disappearance check has to be project-scoped. It used to ask hre_card_facts,
# which answers about the FIRST card for the consultant — so with two of our cards on
# the Sent tab it kept answering "still there" about the sibling, and reported that
# ACT_RejectAfterExport had refused a rejection that had in fact already happened.
hre_card_present() {
  playwright-cli eval "() => { const btns=[...document.querySelectorAll('.mx-name-btnRejectAfterExport')].filter(b=>b.offsetParent!==null); for(const b of btns){ let p=b; for(let k=0;k<12;k++){ if(!p.parentElement) break; p=p.parentElement; const t=(p.innerText||''); if(t.length<1500 && t.indexOf('$CONSULTANT_NAME')>=0 && t.indexOf('$1')>=0) return 'true'; } } return 'false'; }" 2>/dev/null | _tt_eval_str
}

# hre_click_reject <project> — press Reject on the card for our consultant + project.
hre_click_reject() {
  playwright-cli eval "() => { const btns=[...document.querySelectorAll('.mx-name-btnRejectAfterExport')].filter(b=>b.offsetParent!==null); for(const b of btns){ let p=b; for(let k=0;k<12;k++){ if(!p.parentElement) break; p=p.parentElement; const t=(p.innerText||''); if(t.length<1500 && t.indexOf('$CONSULTANT_NAME')>=0 && t.indexOf('$1')>=0){ b.click(); return 'clicked'; } } } return 'nf'; }" 2>/dev/null | _tt_eval_str
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

PROJECT="$(printf '%s' "$FACTS" | sed -n 's/.*"project":"\([^"]*\)".*/\1/p')"
WEEK="$(printf '%s' "$FACTS"    | sed -n 's/.*"week":"\([^"]*\)".*/\1/p')"
HOURS_RAW="$(printf '%s' "$FACTS" | sed -n 's/.*"hours":"\([^"]*\)".*/\1/p')"
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
rc="$(hre_click_reject "$PROJECT")"
[ "$rc" = "clicked" ] \
  || tt_fail "could not press Reject on the exported card for '$PROJECT' (state: $rc)"
tt_clear_dialogs 8 "Reject" \
  || tt_fail "post-export rejection confirmation was not dismissed: ${TT_DIALOG_BLOCKED:-unknown dialog}"
sleep 4

# The card must leave the tab. Poll — the flow commits and refreshes every tab.
gone=""
for _ in $(seq 1 10); do
  [ "$(hre_card_present "$PROJECT")" = "false" ] && { gone=1; break; }
  sleep 3
done
[ -n "$gone" ] \
  || tt_fail "the exported entry for '$PROJECT' is still on tab '$TAB' after Reject — ACT_RejectAfterExport's 'Exported?' guard may have refused it"

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
