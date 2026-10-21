#!/usr/bin/env bash
# tt-timeout: 10m
# verify-tt788-prompt-shown.test.sh
#
# TT-788 #1: on an editable week, a task-based project with no tasks shows the
# "Add your first task" prompt INSTEAD of its day totals.
#
# WHY THIS EXISTS. Before TT-788 such a row showed seven grey, read-only day cells
# and a 0.00 total, and the only way in was a small chevron that opened an empty
# panel with an Add Task link in it — consultants did not find it, and asked why
# they could not type hours on the project. TT-788 replaces the cells with one
# sentence and one button while there is nothing to total.
#
# HOW THE WEEK IS CHOSEN. From data the prompt does not control (lib/_tt788.sh):
# the week still has Save Draft, the row's btnAddTask is present (its rule is
# _IsEditable), and the row's own task list is empty. Only then is the prompt
# looked at, so "the prompt is showing" is an assertion and not the selector.
#
# WHAT IT ASSERTS, on that row
#   A. the prompt (cntFirstTaskPrompt) is visible, with txtFirstTaskPrompt reading
#      "Hours for this project are logged by task." and btnAddFirstTask visible,
#      its text "Add your first task" (textContent: narrow widths shorten the
#      caption with CSS, the text stays in the DOM);
#   B. the day totals are NOT shown — none of the seven day cells and not the row
#      total is visible;
#   C. the panel is shut — btnAddTask is not visible — and no show/hide chevron is
#      visible (there is nothing to show or hide yet).
#   control: another row on the same week shows its seven day cells, which proves
#      the visibility probe can say "visible" — without it B and C could not fail.
#
# WHAT MAKES IT RED. galFirstTask missing or not keyed on an empty task list; the
# CSS that takes the day cells out of the grid missing; the panel left open over
# the prompt.
#
# Read-only: changes nothing. Uses e2e_consultant / E2E Line Items.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt788.sh"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

tt_login "$TT788_CONSULTANT" "My Timesheets"

tt788_find_week empty-editable \
  || tt_fail "no editable week with a task-less '$TT788_PROJECT' row within $TT788_HORIZON weeks for $TT788_CONSULTANT
  $(tt788_census_help)"
note "week $TT788_WEEK: '$TT788_PROJECT' is editable and has no tasks"

P="$(tt788_probe)"
note "probe: $P"
g() { tt788_get "$P" "$1"; }

# control first: a B/C pass means nothing if the probe cannot see a visible cell.
case "$(g ctl_days)" in
  7) note "control ok: another row on the week shows 7 day cells" ;;
  -1) tt_fail "the week has no other row to use as a control, so B and C could not fail — check the fixtures (E2E Consultant has four assignments)" ;;
  *) tt_fail "control row shows $(g ctl_days) visible day cells, expected 7 — the visibility probe is wrong, so B and C below would prove nothing" ;;
esac

# A. the prompt
[ "$(g prompt)" = "1" ] \
  && note "A ok: the prompt is visible" \
  || bad "A the prompt (cntFirstTaskPrompt) is not visible on a task-less editable '$TT788_PROJECT' row (in DOM: $(g prompt_dom))"
[ "$(g ptext)" = "$TT788_PROMPT_TEXT" ] \
  && note "A ok: it reads \"$(g ptext)\"" \
  || bad "A txtFirstTaskPrompt reads \"$(g ptext)\", expected \"$TT788_PROMPT_TEXT\""
[ "$(g addfirst)" = "1" ] \
  && note "A ok: btnAddFirstTask is visible" \
  || bad "A btnAddFirstTask is not visible"
case "$(g addfirst_txt)" in
  *"$TT788_BUTTON_TEXT"*) note "A ok: the button says \"$(g addfirst_txt)\"" ;;
  *) bad "A btnAddFirstTask's text is \"$(g addfirst_txt)\", expected it to contain \"$TT788_BUTTON_TEXT\"" ;;
esac

# B. no day totals
[ "$(g days)" = "0" ] \
  && note "B ok: none of the day cells is visible" \
  || bad "B $(g days) of the row's day cells are visible while the prompt should replace them"
[ "$(g total)" = "0" ] \
  && note "B ok: the row total is not visible" \
  || bad "B the row total is visible while the prompt should replace it"

# C. panel shut, no chevron
[ "$(g addtask)" = "0" ] \
  && note "C ok: btnAddTask is not visible (panel state: $(g state))" \
  || bad "C btnAddTask is visible — the task panel is open over the prompt (state: $(g state))"
[ "$(g chevron)" = "0" ] \
  && note "C ok: no show/hide chevron is visible" \
  || bad "C a show/hide chevron is visible on a row with nothing to show"

if [ "$fails" -gt 0 ]; then
  echo "FAIL: verify-tt788-prompt-shown — $fails check(s) failed on week $TT788_WEEK"
  exit 1
fi
echo "PASS: verify-tt788-prompt-shown — a task-less task-based row shows the first-task prompt and no day totals ($TT788_WEEK)"
