#!/usr/bin/env bash
# tt-timeout: 15m
# verify-tt784-pending-filters.test.sh
#
# TT-784: the HR dashboard's Pending tab can be narrowed by Consultant and by
# Project, and the filters narrow BOTH lists on the tab - the consultants owing a
# week (galPending) and the weeks on offer (galAvailableWeeks) - without moving the
# Pending counter tile.
#
# WHY THIS EXISTS. Before TT-784 HR could only walk the Pending weeks one at a time
# looking for a person; the two comboboxes on the tab are new:
#   cbWeekConsultant  narrows galPending to that consultant, and the weeks to the
#                     weeks that consultant still owes;
#   cbWeekProject     narrows galPending to the consultants who owe that project,
#                     and the weeks to the weeks where someone owes it;
#   choosing a consultant who is not on the selected project empties cbWeekProject,
#   so the two can never combine into a filter that matches nobody.
# The Pending tile (cardKpiPending) is a dashboard-wide count and must not follow
# the filters - a counter that drops when HR filters reads as work disappearing.
#
# WHAT IT ASSERTS
#   A. Unfiltered: records the Pending tile's number, the offered weeks, and the
#      rows of one week that holds an E2E consultant (walks the first six weeks to
#      find one - the e2e consultants owe past weeks after 00-setup's clear).
#   B. Consultant filter, that E2E consultant: every galPending row names them; the
#      week list is non-empty and, for the first two weeks it offers, clicking the
#      week still shows that consultant and only them; the tile is unchanged.
#   C. Clearing the consultant: the week list is the unfiltered one again, and the
#      week recorded in A shows the same rows it showed in A; the tile is unchanged.
#   D. Project filter, E2E Customer Approval: for the first two weeks offered, the
#      week shows at least one row and every row is a consultant FX_ASSIGNMENTS
#      puts on that project (and never one it does not); the tile is unchanged.
#   E. With that project still selected, choosing a consultant FX_ASSIGNMENTS does
#      NOT put on it (E2E Consultant Two) empties cbWeekProject, and galPending
#      then shows only that consultant. Both filters are cleared afterwards.
#
# D and E are derived from lib/_fixtures.sh rather than hard-coded: the allowed
# consultants for the project and the "not on it" consultant are read from
# FX_ASSIGNMENTS, and if the fixtures stop supporting the case (no such project, or
# no fixture consultant off it) the step is SKIPPED with a note naming why, rather
# than asserting against data that is not there. The E2E projects hold only fixture
# consultants - 00-setup builds them from nothing - so "every row is a fixture
# consultant on the project" is exact, not a guess.
#
# HOW A COMBOBOX VALUE IS READ. The selection is picked with tt_combobox_select_text
# (lib/_login_gallery.sh) and read back as the combobox input's value, falling back
# to its rendered text; a pick is only trusted once the read-back equals the name
# asked for. tt_combobox_select_text matches on a PREFIX, and "E2E Consultant" is a
# prefix of "E2E Consultant Two" - the read-back is what catches a wrong pick.
# Clearing uses the widget's own clear button, as suites/40-hr/verify-hr-tab-filters
# does.
#
# WHAT MAKES IT RED. A filter that narrows only one of the two lists; a week offered
# under a consultant filter that shows nobody, or shows someone else; a project
# filter that lets in a consultant not on the project; a project selection that
# survives a switch to a consultant off that project; clearing that does not
# restore the unfiltered tab; the Pending tile changing with the filters.
#
# WRITTEN BUT UNPROVEN (2026-10-07): written before TT-784 was deployed to dev and
# never run. Break each assertion deliberately on its first real run.
#
# Consumes: nothing - read-only. It leaves both filters cleared.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"

CB_CONS=".mx-name-cbWeekConsultant"
CB_PROJ=".mx-name-cbWeekProject"
GAL=".mx-name-galPending"
D_PROJECT="E2E Customer Approval"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

# kpi_pending — the number on the Pending tile, or '?'.
kpi_pending() {
  ev "() => { const e=document.querySelector('.mx-name-cardKpiPending'); if(!e) return '?'; const m=(e.innerText||'').trim().match(/(\d+)\s*\$/); return m?m[1]:'?'; }"
}

# pending_names — every galPending row's consultant, paged in fully, '|' joined.
pending_names() {
  tt_gallery_load_all "$GAL" "pending gallery" >/dev/null
  ev "() => [...document.querySelectorAll('$GAL .mx-name-cardPendingRow')].map(r=>((r.querySelector('.mx-name-txtPendingConsultant')||{}).innerText||'').trim()).join('|')"
}

# week_labels — the offered weeks, '|' joined, in list order.
week_labels() {
  ev "() => [...document.querySelectorAll('.mx-name-galAvailableWeeks .mx-name-txtAvailableWeekRange')].map(e=>(e.innerText||'').trim()).join('|')"
}

# click_week <label> — select the offered week whose text is exactly <label>.
click_week() {
  local r
  r="$(ev "() => { const it=[...document.querySelectorAll('.mx-name-galAvailableWeeks .mx-name-txtAvailableWeekRange')].find(e=>(e.innerText||'').trim()==='$1'); if(!it) return 'NF'; (it.closest('.widget-gallery-item')||it).click(); return 'OK'; }")"
  [ "$r" = "OK" ] || return 1
  sleep 3
  return 0
}

# cb_value <combobox-css> — what the combobox shows as selected ('' when empty).
cb_value() {
  ev "() => { const c=document.querySelector('$1'); if(!c) return 'NOCOMBO'; const i=c.querySelector('input'); const v=(i&&i.value||'').trim(); if(v) return v; const s=c.querySelector('.widget-combobox-selected-item'); return s?(s.innerText||'').trim():''; }"
}

# pick <combobox-css> <name> — select <name> and prove the combobox now shows it.
pick() {
  local v i
  tt_combobox_select_text "$1" "$2" || return 1
  for i in 1 2 3 4 5; do
    v="$(cb_value "$1")"
    [ "$v" = "$2" ] && return 0
    sleep 1
  done
  echo "  (pick: asked $1 for '$2', it shows '$v')" >&2
  return 1
}

# clear_cb <combobox-css> — empty the combobox through its own clear button.
clear_cb() {
  if [ "$(ev "() => { const b=document.querySelector('$1 .widget-combobox-clear-button'); if(!b) return 'none'; b.click(); return 'ok'; }")" != "ok" ]; then
    tt_combobox_select_text "$1" "" >/dev/null 2>&1 || playwright-cli press "Escape" >/dev/null 2>&1
  fi
  sleep 3
}

# only_names <names> <allowed...> — 0 when <names> is non-empty and every entry is
# one of <allowed>; otherwise prints the offenders (or EMPTY) and returns 1.
only_names() {
  local names="$1" n a ok off=""; shift
  [ -n "$names" ] || { printf 'EMPTY'; return 1; }
  local IFS='|'
  for n in $names; do
    ok=0
    for a in "$@"; do [ "$n" = "$a" ] && ok=1; done
    [ "$ok" -eq 1 ] || off="$off${off:+, }$n"
  done
  unset IFS
  [ -z "$off" ] && return 0
  printf '%s' "$off"; return 1
}

# wait_only <label> <allowed...> — poll galPending (~20 s) until only_names holds;
# leaves the last read in LAST_NAMES. A filter round-trips to the server.
LAST_NAMES=""
wait_only() {
  local i; shift
  for i in $(seq 1 10); do
    LAST_NAMES="$(pending_names)"
    only_names "$LAST_NAMES" "$@" >/dev/null && return 0
    sleep 2
  done
  return 1
}

# check_weeks <step> <allowed...> — for the first two offered weeks, click each and
# require at least one row, every row in <allowed>.
check_weeks() {
  local step="$1" labels w n=0 off; shift
  labels="$(week_labels)"
  if [ -z "$labels" ]; then bad "$step: the filtered tab offers no weeks at all"; return; fi
  local IFS='|'; set -f
  local arr=($labels)
  unset IFS; set +f
  for w in "${arr[@]:0:2}"; do
    n=$((n+1))
    if ! click_week "$w"; then bad "$step: offered week '$w' could not be clicked"; continue; fi
    if wait_only "$step week $w" "$@"; then
      note "$step ok: week '$w' shows only [${LAST_NAMES}]"
    else
      off="$(only_names "$LAST_NAMES" "$@")"
      bad "$step: offered week '$w' shows [${LAST_NAMES:-nobody}] - offending: $off; expected at least one row, all of: $*"
    fi
  done
}

tt_login "e2e_hr" "$TT_HR_READY"

# =================================================================== A. Unfiltered
tt_hr_click_tab "Pending"
sleep 3
clear_cb "$CB_CONS" >/dev/null 2>&1
clear_cb "$CB_PROJ" >/dev/null 2>&1
KPI0="$(kpi_pending)"
WEEKS0="$(week_labels)"
HDR0="$(ev "() => ((document.querySelector('.mx-name-txtPendingHeader')||{}).innerText||'').trim()")"
[ -n "$WEEKS0" ] || tt_fail "A: the unfiltered Pending tab offers no weeks - nothing to filter"
case "$KPI0" in ''|*[!0-9]*) tt_fail "A: could not read a number off the Pending tile (.mx-name-cardKpiPending): '$KPI0'" ;; esac

PICK=""; A_WEEK=""; NAMES0=""
IFS='|' read -r -a WARR <<< "$WEEKS0"
for w in "${WARR[@]:0:6}"; do
  click_week "$w" || continue
  NAMES0="$(pending_names)"
  PICK="$(printf '%s' "$NAMES0" | tr '|' '\n' | grep -E '^E2E Consultant' | head -1)"
  if [ -n "$PICK" ]; then A_WEEK="$w"; break; fi
done
[ -n "$PICK" ] || tt_fail "A: no E2E consultant in galPending in the first six Pending weeks - the e2e consultants should owe past weeks after 00-setup's clear"
N0="$(printf '%s' "$NAMES0" | tr '|' '\n' | grep -c .)"
note "A ok: tile=$KPI0, header [$HDR0], $(printf '%s' "$WEEKS0" | tr '|' '\n' | grep -c .) week(s); week '$A_WEEK' has $N0 row(s), using '$PICK'"

# =================================================================== B. Consultant filter
if ! pick "$CB_CONS" "$PICK"; then
  bad "B: '$PICK' could not be selected in the consultant filter ($CB_CONS)"
else
  if wait_only "B" "$PICK"; then
    note "B ok: galPending narrowed to [$LAST_NAMES]"
  else
    bad "B: with the consultant filter on '$PICK', galPending shows [${LAST_NAMES:-nobody}]"
  fi
  check_weeks "B" "$PICK"
  K="$(kpi_pending)"
  [ "$K" = "$KPI0" ] && note "B ok: Pending tile still $K" || bad "B: the Pending tile moved $KPI0 -> $K when the consultant filter was set - it must count the whole queue"
fi

# =================================================================== C. Clear it
clear_cb "$CB_CONS"
[ -z "$(cb_value "$CB_CONS")" ] || bad "C: the consultant filter still shows '$(cb_value "$CB_CONS")' after clearing"
WEEKS_C=""
for i in $(seq 1 10); do
  WEEKS_C="$(week_labels)"; [ "$WEEKS_C" = "$WEEKS0" ] && break; sleep 2
done
[ "$WEEKS_C" = "$WEEKS0" ] && note "C ok: the unfiltered week list is back" \
  || bad "C: after clearing, the weeks are [$WEEKS_C]; unfiltered they were [$WEEKS0]"
if click_week "$A_WEEK"; then
  NAMES_C=""
  for i in $(seq 1 10); do
    NAMES_C="$(pending_names)"
    [ "$(printf '%s' "$NAMES_C" | tr '|' '\n' | sort)" = "$(printf '%s' "$NAMES0" | tr '|' '\n' | sort)" ] && break
    sleep 2
  done
  if [ "$(printf '%s' "$NAMES_C" | tr '|' '\n' | sort)" = "$(printf '%s' "$NAMES0" | tr '|' '\n' | sort)" ]; then
    note "C ok: week '$A_WEEK' shows its $N0 unfiltered row(s) again"
  else
    bad "C: after clearing, week '$A_WEEK' shows [$NAMES_C]; unfiltered it showed [$NAMES0] - the filter is sticky"
  fi
else
  bad "C: week '$A_WEEK' is no longer offered after clearing the consultant filter"
fi
K="$(kpi_pending)"
[ "$K" = "$KPI0" ] || bad "C: the Pending tile moved $KPI0 -> $K after clearing the consultant filter"

# =================================================================== D/E. Project filter
# Consultants FX_ASSIGNMENTS puts on D_PROJECT, and the first fixture consultant
# with assignments who is NOT on it.
ON_PROJ=(); OFF_PROJ=""
for row in "${FX_ASSIGNMENTS[@]}"; do
  IFS='|' read -r c p _ <<< "$row"
  [ "$p" = "$D_PROJECT" ] && ON_PROJ+=("$c")
done
for row in "${FX_ASSIGNMENTS[@]}"; do
  IFS='|' read -r c _ _ <<< "$row"
  on=0; for a in "${ON_PROJ[@]}"; do [ "$a" = "$c" ] && on=1; done
  if [ "$on" -eq 0 ]; then OFF_PROJ="$c"; break; fi
done

if [ "${#ON_PROJ[@]}" -eq 0 ]; then
  note "D/E SKIPPED: FX_ASSIGNMENTS no longer puts anyone on '$D_PROJECT' - repoint D_PROJECT at a fixture project"
elif ! pick "$CB_PROJ" "$D_PROJECT"; then
  bad "D: '$D_PROJECT' could not be selected in the project filter ($CB_PROJ)"
else
  if wait_only "D" "${ON_PROJ[@]}"; then
    note "D ok: galPending narrowed to [$LAST_NAMES]"
  else
    bad "D: with the project filter on '$D_PROJECT', galPending shows [${LAST_NAMES:-nobody}]; only ${ON_PROJ[*]} are on it"
  fi
  check_weeks "D" "${ON_PROJ[@]}"
  K="$(kpi_pending)"
  [ "$K" = "$KPI0" ] && note "D ok: Pending tile still $K" || bad "D: the Pending tile moved $KPI0 -> $K when the project filter was set"

  # E. a consultant off the project clears the project.
  if [ -z "$OFF_PROJ" ]; then
    note "E SKIPPED: every fixture consultant is on '$D_PROJECT' - no one to switch to"
  elif ! pick "$CB_CONS" "$OFF_PROJ"; then
    bad "E: '$OFF_PROJ' could not be selected in the consultant filter - FX_ASSIGNMENTS gives them weeks to owe"
  else
    PV="$(cb_value "$CB_PROJ")"
    for i in $(seq 1 10); do
      [ -z "$PV" ] && break; sleep 1; PV="$(cb_value "$CB_PROJ")"
    done
    if [ -z "$PV" ]; then
      note "E ok: choosing '$OFF_PROJ' (not on '$D_PROJECT') emptied the project filter"
    else
      bad "E: after choosing '$OFF_PROJ', who is not on '$D_PROJECT', the project filter still shows '$PV'"
    fi
    if wait_only "E" "$OFF_PROJ"; then
      note "E ok: galPending shows only [$LAST_NAMES]"
    else
      bad "E: with the consultant filter on '$OFF_PROJ', galPending shows [${LAST_NAMES:-nobody}]"
    fi
    K="$(kpi_pending)"
    [ "$K" = "$KPI0" ] || bad "E: the Pending tile moved $KPI0 -> $K"
  fi
fi

# Leave the tab unfiltered for whatever runs next.
clear_cb "$CB_CONS" >/dev/null 2>&1
clear_cb "$CB_PROJ" >/dev/null 2>&1

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-tt784-pending-filters - $fails problem(s) with the Pending tab's consultant/project filters (TT-784)."
  exit 1
fi
echo "PASS: verify-tt784-pending-filters - the consultant and project filters narrow both Pending lists, a consultant off the project clears it, clearing restores the tab, and the Pending tile never moved ($KPI0)."
