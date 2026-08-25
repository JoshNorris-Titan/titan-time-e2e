#!/usr/bin/env bash
# Consultant line-items ("tasks") UI on a NeedsLineItems project (E2E Line Items).
#
# Verifies the client-side line-item behaviour that IS reliable:
#   - expand the tasks section, Add Task adds a row
#   - filling a task's Mon-Fri recalculates that task's own total (txtLineTotal)
#   - editing a cell updates the line total
#   - a second Add Task adds independently
#   - Delete removes a task
#
# Asserts the per-task LINE total only. The assignment-ROW rollup is unreliable
# (TT-692: NOCH_AssignmentEntry_UpdateTotals intermittently 560s / stalls at 0.00),
# so it is deliberately NOT asserted, and a stray "An error occurred" dialog from
# that rollup is dismissed rather than treated as a failure.
#
# Client-side only (no Save Draft). Editing a cell commits the LineItem, so the
# test deletes the tasks it created to avoid accumulating data on the project.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

ROW=".mx-name-galAssignmentRows"

# Dismiss a stray dialog (TT-692 rollup error) so it doesn't block the next step.
dismiss_dialog() {
  playwright-cli eval "() => { const d=document.querySelector('[role=dialog],.modal-dialog'); if(!d) return 'none'; const b=[...d.querySelectorAll('button')].find(x=>/^(ok|close|×|got it|dismiss)$/i.test(x.innerText.trim())) || d.querySelector('button'); if(b){b.click(); return 'closed';} return 'open'; }" >/dev/null 2>&1
  sleep 1
}

task_count() {
  playwright-cli eval "() => String(document.querySelectorAll('$ROW .mx-name-txtLineItemName input').length)" 2>/dev/null | sed -n '2p' | tr -d '"'
}

# Read the line total of the task at 1-based ordinal $1.
line_total() {
  playwright-cli eval "() => String((document.querySelectorAll('$ROW .mx-name-txtLineTotal input')[$1 - 1]||{}).value || '')" 2>/dev/null | sed -n '2p' | tr -d '"'
}

tt_login "e2e_consultant" "My Timesheets"

# Find a week that has the E2E Line Items row.
found=""
for _ in $(seq 1 12); do
  if playwright-cli eval "() => String((((document.querySelector('$ROW')||{}).innerText)||'').indexOf('E2E Line Items') >= 0)" 2>/dev/null | grep -qiw true; then
    found=1; break
  fi
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
  sleep 2
done
[ -n "$found" ] || tt_fail "no week with an 'E2E Line Items' row found"
WEEK=$(playwright-cli eval "() => String((document.querySelector('.mx-name-txtWeekRange')||{}).innerText||'')" 2>/dev/null | sed -n '2p')
echo "week: $WEEK"

# Expand the tasks section — click whichever toggle is visible until Add Task shows.
for _ in 1 2 3; do
  playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnAddTask'); return String(!!b && b.offsetParent!==null); }" 2>/dev/null | grep -qiw true && break
  TGL=$(playwright-cli eval "() => { for (const s of ['btnLineItemsCollapse','btnLineItemsExpand']){ const t=document.querySelector('.mx-name-'+s); if (t && t.offsetParent!==null) return s; } return ''; }" 2>/dev/null | sed -n '2p' | tr -d '"')
  [ -n "$TGL" ] && playwright-cli click ".mx-name-$TGL" >/dev/null 2>&1
  sleep 2
done
tt_wait_for ".mx-name-btnAddTask" "Add Task button"

N0="$(task_count)"
echo "existing tasks: $N0"

# 1) Add a task.
playwright-cli click ".mx-name-btnAddTask" >/dev/null 2>&1
sleep 2; dismiss_dialog
[ "$(task_count)" = "$((N0 + 1))" ] || tt_fail "Add Task did not add a row (before=$N0, after=$(task_count))"
IDX=$((N0 + 1))

# 2) Fill name + Mon-Fri 6h -> this task's line total = 30.00.
playwright-cli fill ":nth-match($ROW .mx-name-txtLineItemName input, $IDX)" "E2E Task A" >/dev/null 2>&1
for d in Mon Tues Wed Thurs Fri; do
  playwright-cli fill ":nth-match($ROW .mx-name-txtLine${d} input, $IDX)" "6" >/dev/null 2>&1
done
playwright-cli click ":nth-match($ROW .mx-name-txtLineItemName input, $IDX)" >/dev/null 2>&1
sleep 2; dismiss_dialog
# The fill above is silenced, which hides a strict-mode violation refusing the
# write. Prove the name landed: an unnamed line item makes the whole week
# unsaveable for every project on it (see lib/_login.sh).
tt_assert_task_named "$ROW" "$IDX" "E2E Task A"
LT="$(line_total "$IDX")"
case "$LT" in *30*) echo "line total (6x5): $LT" ;; *) tt_fail "line total wrong after fill (expected 30, got '$LT')" ;; esac

# 3) Update Monday 6 -> 8, total 30 -> 32.
playwright-cli fill ":nth-match($ROW .mx-name-txtLineMon input, $IDX)" "8" >/dev/null 2>&1
playwright-cli click ":nth-match($ROW .mx-name-txtLineItemName input, $IDX)" >/dev/null 2>&1
sleep 2; dismiss_dialog
LT2="$(line_total "$IDX")"
case "$LT2" in *32*) echo "line total (updated): $LT2" ;; *) tt_fail "line total wrong after update (expected 32, got '$LT2')" ;; esac

# 4) Add a second task -> count N0+2.
playwright-cli click ".mx-name-btnAddTask" >/dev/null 2>&1
sleep 2; dismiss_dialog
[ "$(task_count)" = "$((N0 + 2))" ] || tt_fail "second Add Task did not add (got $(task_count))"

# This step only asserts the COUNT, so the second task used to be left unnamed.
# That is exactly the poison: if the delete in step 5 misses it (and step 5 openly
# expects to be flaky), an unnamed line item survives and every later submit on this
# week fails somewhere else entirely. Naming it costs nothing and defuses that.
IDX2=$((N0 + 2))
playwright-cli fill ":nth-match($ROW .mx-name-txtLineItemName input, $IDX2)" "E2E Task B" >/dev/null 2>&1
playwright-cli click ":nth-match($ROW .mx-name-txtLineItemName input, $IDX2)" >/dev/null 2>&1
sleep 2; dismiss_dialog
tt_assert_task_named "$ROW" "$IDX2" "E2E Task B"

# 5) Delete the tasks we added -> back to N0.
tries=0
while [ "$(task_count)" -gt "$N0" ] && [ "$tries" -lt 6 ]; do
  playwright-cli click ":nth-match($ROW .mx-name-btnLineItemDelete, $(task_count))" >/dev/null 2>&1
  sleep 2; dismiss_dialog
  tries=$((tries + 1))
done
FINAL="$(task_count)"
# This used to WARN and pass. Leftover tasks are not cosmetic: they accumulate
# hours on the project and skew later assertions, and this test runs EARLY
# (20-consultant), so whatever it leaves behind is inherited by every suite after
# it. A cleanup that did not clean up is a failure.
[ "$FINAL" = "$N0" ] || tt_fail "cleanup left $FINAL task(s) (started $N0) — likely TT-692 delete flakiness. Left in place these skew every later test on this week; clear the week before re-running."
tt_assert_no_unnamed_tasks "$ROW"

echo "PASS: line-items add / recalc / update / second-task / delete ($WEEK)"
