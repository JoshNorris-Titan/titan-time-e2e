#!/usr/bin/env bash
# C4 — line-item entry: aggregate day boxes are LOCKED, line items are EDITABLE.
#
# Baseline captured pre-change on a non-line-item entry: day boxes readonly =
# [false x7, true] (only TotalHours locked) and NO line-item editor in the popup.
# After the change, for a NeedsLineItems entry the popup must instead show:
#   * aggregate day boxes read-only / not editable
#   * a line-item editor (view/add/edit/delete)
#
# Requires a REJECTED entry on a NeedsLineItems project (E2E Line Items).
#
# ── WHY THE FIXTURE IS NOT tt_make_rejected_entry ANY MORE ─────────────────────
# It cannot seed this project, and could not tell that it had not. Two reasons,
# both proved against dev:
#
#  1. E2E Line Items is declared No|No|Yes in lib/_fixtures.sh — needs line
#     items, needs NO approval. Main.SUB_AssignmentEntry_Submit therefore routes
#     a submitted entry STRAIGHT to ToProcess, so it never appears on MANAGER
#     APPROVAL, which is the only tab that fixture looked at.
#  2. On a NeedsLineItems row the aggregate day cells are read-only by design
#     (hours live on the task rows), so the fixture's fill-the-day-cells seed
#     cannot touch this project at all.
#
# What that produced was worse than a clean failure. The fixture rejected
# whatever OTHER card of this consultant's happened to be in the manager queue,
# accepted "the consultant now has some rejected entry" as success, printed
# "rejected entry ready for e2e_consultant (E2E Line Items, E2E Oct 25 - Oct
# 31)", and this test then opened a 'Walmart - E2E Manager Approval' entry for
# week Nov 01 - Nov 07 and asserted line-item behaviour against it. It failed
# on aggregate-day-boxes-still-editable and no-line-item-editor — both correct
# for the entry it was looking at, and nothing to do with the change under test.
#
# So: seed through the TT-654 line-item helpers, reject and reopen BY PROJECT,
# and make a project mismatch a hard failure instead of a warning that the run
# then ignores.
# ──────────────────────────────────────────────────────────────────────────────

# tt-timeout: 10m
#   Seeding a line-items week (find week, fill, add task, save, submit), a
#   reject hunt across the HR tabs and four logins. verify-tt654-a3 measures
#   277s for the same shape of fixture and declares 8m; this adds the popup
#   assertions on top.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt654.sh"
source "$TT_ROOT/lib/_tt692693.sh"

CUSER="${TT_C4_USER:-e2e_consultant}"
CNAME="${TT_C4_NAME:-E2E Consultant}"
PROJECT="${TT_C4_PROJECT:-E2E Line Items}"
# tt654_find_editable_row reports which consultant it looked at on failure.
TT654_CONSULTANT="$CUSER"

tt_make_rejected_lineitem_entry "$CUSER" "$CNAME" "$PROJECT" \
  || tt_fail "C4 setup: could not produce a rejected entry on '$PROJECT' (NeedsLineItems)"

tt_login "$CUSER" "My Timesheets"
[ "$(tt_rejected_count)" != "0" ] || tt_fail "C4: no rejected entry present"

# The rejected entry MUST be this project's — every assertion below is about
# NeedsLineItems behaviour and means nothing on any other entry. This used to be
# a warning, which is how the run above reported a failure it had manufactured.
tt_rejected_has_project "$PROJECT" \
  || tt_fail "C4: no rejected '$PROJECT' entry for $CUSER — the assertions below only apply to a NeedsLineItems entry.
  rejected list shows: $(tt_rejected_projects)"
echo "rejected rows: $(tt_rejected_projects)"

tt_open_review_for_project "$PROJECT" \
  || tt_fail "C4: could not open Review & Edit for the rejected '$PROJECT' entry"
POPUP="$(tt_popup_text)"
echo "popup: $POPUP"
case "$POPUP" in
  *"$PROJECT"*) : ;;
  *) tt_fail "C4: the Review & Edit popup is not showing the '$PROJECT' entry (got: ${POPUP:0:200})" ;;
esac

# Diagnostic only — and read it carefully. tt_popup_day_inputs counts every
# numeric input in the popup and does NOT exclude the line-item row, so on a
# passing run its 8 values are the TASK row (total 40.00 readonly, then Sun-Sat)
# and NOT the aggregate boxes. The aggregate boxes contribute nothing here at
# all: a Mendix text box whose conditional editability is false renders as static
# text with no <input>, which is why the assertion below counts 0 rather than
# seven readonly ones. The popup TEXT is where you can see the locked aggregates.
DAYS="$(tt_popup_day_inputs)"
echo "day inputs: $DAYS"

# 1) aggregate day boxes must be read-only.
EDITABLE=$(playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); const ins=[...d.querySelectorAll('input')].filter(i=>i.offsetParent!==null && /^\s*-?[0-9]*\.?[0-9]*\s*$/.test(i.value||'')); const lineish=(i)=>{ let p=i; for(let k=0;k<8;k++){ if(!p) break; const c=(p.className||'').toString(); if(/txtLine|LineItem/i.test(c)) return true; p=p.parentElement; } return false; }; const agg=ins.filter(i=>!lineish(i)); return String(agg.filter(i=>!i.readOnly && !i.disabled).length); }" 2>/dev/null | sed -n '2p' | tr -d '"')
echo "editable aggregate day boxes: $EDITABLE"

# 2) a line-item editor must be present.
#
# _tt_eval_str, not sed -n '2p'. playwright-cli prints the returned string as a
# JSON string literal, so the raw second line is "{\"lineWidgets\":true,...}"
# with the inner quotes escaped — and the case pattern below looks for
# '"lineWidgets":true', which never matches escaped output. That assertion could
# not pass, so this test reported no-line-item-editor on a popup that had already
# printed lineWidgets:true, addTaskBtn:true one line above. Same family as the
# `eval | grep -qiw ok` trap: the raw eval output is not the value.
LINEED=$(playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); if(!d) return '{}'; return JSON.stringify({ lineWidgets: !!d.querySelector('[class*=txtLine],[class*=LineItem],[class*=btnAddTask]'), addTaskBtn: !!d.querySelector('.mx-name-btnAddTask'), mentionsTask: /task|line item/i.test(d.innerText||'') }); }" 2>/dev/null | _tt_eval_str)
echo "line-item editor: $LINEED"

FAILS=""
[ "${EDITABLE:-99}" = "0" ] || FAILS="$FAILS aggregate-day-boxes-still-editable($EDITABLE)"
case "$LINEED" in *'"lineWidgets":true'*) ;; *) FAILS="$FAILS no-line-item-editor" ;; esac

tt_click_button_exact "cancel" popup >/dev/null 2>&1

[ -z "$FAILS" ] || tt_fail "C4 FAIL:$FAILS
  day inputs were: $DAYS
  (pre-change baseline for comparison: readonly=[false x7,true], no line-item editor)"

echo "PASS: C4 — aggregate day boxes locked and a line-item editor is present in the Review & Edit popup"
