#!/usr/bin/env bash
# _hr_groups.sh — part of the lib/_login.sh set: the HR dashboard's GROUPED tabs.
#
# DO NOT SOURCE THIS DIRECTLY. Source lib/_login.sh, which sources every part in
# order; this one reads names defined in _login_core.sh and _login_waits.sh.
#
# WHAT CHANGED (model b2202878 + 771be886, 2026-09-28). Three of the HR dashboard's
# six stage tabs were rebuilt:
#
#   Weekly to process      week picker + card gallery  ->  week GROUPS
#   Sent                   week picker + card gallery  ->  week GROUPS, last 8 weeks,
#                                                          "Load more weeks"
#   Monthly to be invoiced month picker + card gallery ->  month GROUPS
#
# A group is a band (label, count, hours) over a hand-built table of rows. There is no
# picker any more and nothing is "selected": every group is listed at once, and a
# group's rows are rendered only while the group is EXPANDED. Only the newest group
# starts expanded. The widgets, per tab (<T> = Process | Sent | Invoice):
#
#   lst<T>Weeks / lstInvoiceMonths     the ListView of groups
#     cnt<T>GroupToggle                the band's clickable half (runs NACT_*Group_Toggle)
#       txt<T>GroupLabel               "Week of Sep 07 – Sep 13, 2026" / "Sep 2026"
#       txt<T>GroupCount / txt<T>GroupHours
#     btnSentPrintWeek                 Sent only: print THIS week
#     btnInvoiceExportMonth            Monthly only: export THIS month
#     cnt<T>GroupRows                  CONDITIONAL: present only while expanded
#       lst<T>Entries                  the rows' ListView
#         cnt<T>Row                    one row (txt<T>Consultant, txt<T>Project, ...)
#   btnSentLoadMore                    Sent only, while older weeks exist
#
# Removed with them: galProcessEntries, galSentEntries, galInvoiceEntries,
# galProcessAvailableWeeks, galSentAvailableWeeks, galAvailableMonths,
# containerProcessCard, containerSentCard, btnExportAll, btnSentPrint.
#
# The Manager approval and Client approval tabs were NOT rebuilt - they still have a
# week picker and a card gallery, and TT_HR_GAL_WEEKS / TT_HR_GAL_ENTRIES / TT_HR_CARD
# (lib/_login_core.sh) now name only those two.
#
# HOW THE OLD "SELECT A WEEK" MAPS ONTO GROUPS. Every caller in this suite was written
# against "pick a week, then read the entries gallery". tt_hr_select_week keeps that
# contract on both kinds of tab: on a picker tab it clicks the week; on a grouped tab
# it expands that ONE group and collapses every other, so the entries area of the
# page holds exactly that week's rows - which is what "the selected week" meant. The
# entries area of whichever tab is open is TT_HR_ENTRIES_ANY, and a single
# document.querySelector on it lands on the one expanded list.
#
# Collapsing the others is not tidiness. A querySelector over two expanded groups
# answers about the first one, silently, which is the same "read the first page"
# mistake the gallery paging notes in _login_gallery.sh describe at length.

# ---------------------------------------------------------------- selectors
TT_HR_LST_WEEKS='.mx-name-lstProcessWeeks, .mx-name-lstSentWeeks'
TT_HR_LST_ENTRIES='.mx-name-lstProcessEntries, .mx-name-lstSentEntries'
TT_HR_ROW='.mx-name-cntProcessRow, .mx-name-cntSentRow'
TT_HR_LST_MONTHS='.mx-name-lstInvoiceMonths'
TT_HR_LST_INVOICE='.mx-name-lstInvoiceEntries'
TT_HR_INVOICE_ROW='.mx-name-cntInvoiceRow'
TT_HR_GROUP_TOGGLE='.mx-name-cntProcessGroupToggle, .mx-name-cntSentGroupToggle, .mx-name-cntInvoiceGroupToggle'
TT_HR_GROUP_LABEL='.mx-name-txtProcessGroupLabel, .mx-name-txtSentGroupLabel, .mx-name-txtInvoiceGroupLabel'
TT_HR_BTN_EXPORT_MONTH='.mx-name-btnInvoiceExportMonth'
TT_HR_BTN_PRINT_WEEK='.mx-name-btnSentPrintWeek'
TT_HR_BTN_SENT_LOADMORE='.mx-name-btnSentLoadMore'
TT_HR_BTN_SENT_VIEW='.mx-name-btnSentView'
TT_HR_BTN_REJECT_AFTER_EXPORT='.mx-name-btnRejectAfterExport'
TT_HR_TXT_SENT_WINDOW='.mx-name-txtSentWindow'
# The consultant cell of a card or row, on every tab that has one. The text widget,
# not the row's first line: a Process row can carry a "Closed at 0 hours by HR" note
# in the same cell, and a picker card's first line was only ever the consultant by
# layout accident.
TT_HR_TXT_CONSULTANT_ANY='.mx-name-txtManagerConsultant, .mx-name-txtClientConsultant, .mx-name-txtProcessConsultant, .mx-name-txtSentConsultant, .mx-name-txtInvoiceConsultant'
TT_HR_TXT_PROJECT_ANY='.mx-name-txtManagerProject, .mx-name-txtClientProject, .mx-name-txtProcessProject, .mx-name-txtSentProject, .mx-name-txtInvoiceProject'

# "Whichever tab is open" unions. At most one HR pane is in the DOM at a time
# (selecting a tab unrenders the previous one), so these match one tab's widgets.
TT_HR_WEEKS_ANY="$TT_HR_GAL_WEEKS, $TT_HR_LST_WEEKS"
TT_HR_ENTRIES_ANY="$TT_HR_GAL_ENTRIES, $TT_HR_LST_ENTRIES"
TT_HR_CARD_ANY="$TT_HR_CARD, $TT_HR_ROW"

# ------------------------------------------------------------ in-page model
#
# _tt_hr_grp_js — a JS statement block that defines, for whichever grouped pane is
# open:
#   HG.kind     'Process' | 'Sent' | 'Invoice', or null when no grouped pane is open
#   HG.groups() [{t: toggle, g: group root, label, key, open}] in page order
#   HG.find(w)  the group whose key or label matches w (a tt_week_key, a month label,
#               or any fragment of the label)
#   HG.rows(g)  the group's rows (only present while it is expanded)
#   HG.wk(s)    tt_week_key in JS: "Mmm DD - Mmm DD", or '' for a non-week label
#   HG.pageIn(root) click the ListView "Load more" inside root until it is gone
#
# A GROUP'S ROOT is found by climbing from its toggle while the parent still holds
# exactly one toggle - the highest such ancestor below the list is the list item
# that owns the band AND the rows. That survives whatever wrapper markup the
# ListView renders, which a fixed '.mx-listview-item' climb would not if the widget
# ever changes, and it cannot climb into a neighbouring group.
_tt_hr_grp_js() {
  cat <<'EOF' | tr '\n' ' '
const HG = (() => {
  const kinds = [['Process', 'lstProcessWeeks'], ['Sent', 'lstSentWeeks'], ['Invoice', 'lstInvoiceMonths']];
  let kind = null, list = null;
  for (const [k, l] of kinds) { const e = document.querySelector('.mx-name-' + l); if (e) { kind = k; list = e; break; } }
  const TOG = '.mx-name-cnt' + kind + 'GroupToggle', LBL = '.mx-name-txt' + kind + 'GroupLabel';
  const ROWS = '.mx-name-cnt' + kind + 'GroupRows', ROW = '.mx-name-cnt' + kind + 'Row';
  const wk = s => { s = String(s || '').replace(/[–—]/g, '-'); const m = s.match(/([A-Z][a-z]{2})\s+(\d{1,2})\s*-\s*(?:([A-Z][a-z]{2})\s+)?(\d{1,2})(?!\d)/); if (!m) return ''; const p = n => String(n).padStart(2, '0'); return m[1] + ' ' + p(m[2]) + ' - ' + (m[3] || m[1]) + ' ' + p(m[4]); };
  const groups = () => { if (!list) return []; return [...list.querySelectorAll(TOG)].map(t => { let g = t; while (g.parentElement && g.parentElement !== list && g.parentElement.querySelectorAll(TOG).length === 1) g = g.parentElement; const label = ((g.querySelector(LBL) || {}).innerText || '').replace(/\s+/g, ' ').trim(); return { t, g, label, key: kind === 'Invoice' ? label : wk(label), open: !!g.querySelector(ROWS) }; }); };
  const find = w => { const k = wk(w); return groups().find(x => (k && x.key === k) || x.label === w || x.key === w) || groups().find(x => w && x.label.indexOf(w) >= 0) || null; };
  const rows = g => [...g.querySelectorAll(ROW)];
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const pageIn = async root => { for (let i = 0; i < 30; i++) { const b = [...root.querySelectorAll('.mx-listview-loadMore, button.mx-listview-loadMore')].find(x => x.offsetParent !== null); if (!b) return; b.click(); await sleep(1200); } };
  return { kind, list, TOG, LBL, ROWS, ROW, wk, groups, find, rows, sleep, pageIn };
})();
EOF
}

# tt_hr_pane_kind — which kind of HR tab is open: Process | Sent | Invoice for a
# grouped tab, picker for Manager/Client, none when no stage pane has rendered.
#
# Waits up to ~10s for one to render, IN the page: a tab's week list comes from a
# data view's microflow and lands a beat after the pane itself, and an answer of
# 'none' read in that gap would send the caller down the wrong branch.
tt_hr_pane_kind() {
  playwright-cli eval "async () => { for (let i = 0; i < 20; i++) { $(_tt_hr_grp_js) if (HG.kind) return HG.kind; if (document.querySelector('$TT_HR_GAL_WEEKS')) return 'picker'; await new Promise(r => setTimeout(r, 500)); } return 'none'; }" 2>/dev/null | _tt_eval_str
}

# tt_hr_wait_pane [label] — wait (<=20s) for the open tab's week list, of either
# kind, to render. Fatal on a miss, like tt_wait_for. Replaces
# `tt_wait_for "$TT_HR_GAL_WEEKS"`, which can never succeed on a grouped tab.
tt_hr_wait_pane() {
  tt_wait_for "$TT_HR_WEEKS_ANY, $TT_HR_LST_MONTHS" "${1:-HR tab week list}"
}

# tt_hr_sent_load_all [max-rounds] — on the Sent tab, press "Load more weeks" until
# it is gone (every Sent week is listed) or max-rounds presses have been made.
# Echoes how many groups are listed afterwards. Harmless on any other tab.
#
# WHY. Sent shows only the last 8 weeks (txtSentWindow, "Showing the last 8 weeks").
# An entry exported from an older week is on the tab but NOT in the DOM until Load
# more is pressed, so any "is it on the Sent tab" answer that did not press it is
# about the window, not the tab.
tt_hr_sent_load_all() {
  local rounds="${1:-12}"
  playwright-cli eval "async () => { $(_tt_hr_grp_js) if (HG.kind !== 'Sent') return String(HG.groups().length); for (let r = 0; r < $rounds; r++) { const b = document.querySelector('$TT_HR_BTN_SENT_LOADMORE'); if (!b || b.offsetParent === null) break; const n = HG.groups().length; b.click(); for (let i = 0; i < 20 && HG.groups().length === n; i++) await HG.sleep(500); if (HG.groups().length === n) break; } return String(HG.groups().length); }" 2>/dev/null | _tt_eval_str
}

# tt_hr_groups — the open grouped tab's groups, one per line:
#   <key>|<label>|<open 1/0>|<rows rendered>
# <key> is the tt_week_key ("Sep 07 - Sep 13") on a week tab and the label itself
# ("Sep 2026") on the Monthly tab. Prints nothing on a picker tab.
tt_hr_groups() {
  playwright-cli eval "() => { $(_tt_hr_grp_js) return HG.groups().map(x => [x.key, x.label, x.open ? 1 : 0, HG.rows(x.g).length].join('|')).join('\n'); }" 2>/dev/null | _tt_eval_str | grep -v '^null$' | grep .
}

# tt_hr_week_labels [all] — the weeks (or months) the open tab offers, pipe joined,
# on EITHER kind of tab: the picker's labels on Manager/Client, the group keys on a
# grouped tab. Pass `all` to press Sent's Load more first. "" when there are none.
tt_hr_week_labels() {
  [ "${1:-}" = "all" ] && tt_hr_sent_load_all >/dev/null 2>&1
  playwright-cli eval "() => { $(_tt_hr_grp_js) if (HG.kind) return HG.groups().map(x => x.key || x.label).join('|'); const g=document.querySelector('$TT_HR_GAL_WEEKS'); if(!g) return ''; return [...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} \\d{2} - /.test(t)))].join('|'); }" 2>/dev/null | _tt_eval_str | grep -v '^null$'
}

# tt_hr_group_expand <week-key|month-label> [only]
#
# Expand the group matching the argument and wait for its rows to render, paging its
# row list in fully. With `only` (the default) every OTHER open group is collapsed
# first, so TT_HR_ENTRIES_ANY then addresses exactly this group. Prints
# OK:<rows> | NF (no such group) | STUCK:<why>.
#
# One toggle per round trip, re-reading the groups after each: a toggle runs a
# nanoflow that re-renders the list, so element references taken before a click are
# not trustworthy after it.
tt_hr_group_expand() {
  local want="$1" only="${2:-only}"
  playwright-cli eval "async () => { $(_tt_hr_grp_js) if (!HG.kind) return 'STUCK:no grouped tab is open'; const want='$want'; const only='$only'==='only'; const deadline=Date.now()+25000; while (Date.now() < deadline) { const target = HG.find(want); if (!target) return 'NF'; const extra = only ? HG.groups().filter(x => x.open && x.g !== target.g) : []; if (extra.length) { extra[0].t.click(); await HG.sleep(900); continue; } if (!target.open) { target.t.click(); await HG.sleep(900); continue; } await HG.pageIn(target.g); const again = HG.find(want); if (!again || !again.open) continue; return 'OK:' + HG.rows(again.g).length; } const t = HG.find(want); return 'STUCK:' + (t ? (t.open ? 'open' : 'still collapsed') : 'vanished') + ' after 25s; open groups=' + HG.groups().filter(x => x.open).map(x => x.label).join(' / '); }" 2>/dev/null | _tt_eval_str
}

# tt_hr_select_week <week-key|label> — "select" one week on the open tab, on either
# kind of tab. Picker tab: click it in the picker. Grouped tab: expand that group
# and collapse the rest. Returns 0 when selected, 1 when the tab does not offer it.
#
# Accepts every shape of week label this suite meets; tt_week_key normalizes it, so
# TT_SUBMITTED_WEEK ("Sep 07 - Sep 13"), a picker label and a group key all work.
tt_hr_select_week() {
  local w="$1" key r
  key="$(tt_week_key "$w")"; [ -n "$key" ] || key="$w"
  case "$(tt_hr_pane_kind)" in
    Process|Sent|Invoice)
      r="$(tt_hr_group_expand "$key")"
      case "$r" in OK:*) return 0 ;; esac
      [ "$r" = "NF" ] || echo "  (tt_hr_select_week '$key': $r)" >&2
      return 1
      ;;
  esac
  r="$(playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_WEEKS'); if(!g) return 'nopicker'; const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$key')===0); if(!el) return 'nf'; el.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)"
  [ "$r" = "ok" ] || return 1
  sleep 3
  return 0
}

# tt_hr_entries_load — page the selected week's entries in fully and echo how many
# cards/rows it holds. Picker tabs page the gallery (tt_gallery_load_all); grouped
# tabs page the expanded group's row list. Never fails; 0 when nothing is shown.
tt_hr_entries_load() {
  case "$(tt_hr_pane_kind)" in
    Process|Sent|Invoice)
      playwright-cli eval "async () => { $(_tt_hr_grp_js) const o = HG.groups().filter(x => x.open); let n = 0; for (const x of o) { await HG.pageIn(x.g); n += HG.rows(x.g).length; } return String(n); }" 2>/dev/null | _tt_eval_str
      ;;
    *) tt_gallery_load_all "$TT_HR_GAL_ENTRIES" "entries gallery" ;;
  esac
}

# tt_hr_find_group_with <needle> [needle2] [all]
#
# Walk the open grouped tab's groups, newest first, expanding each in turn, until one
# holds a row whose text contains <needle> (and <needle2>). Prints that group's key
# and leaves it the only one expanded. Returns 1 when no group holds one. Pass `all`
# to press Sent's Load more first, so weeks outside the 8-week window are searched.
tt_hr_find_group_with() {
  local needle="$1" needle2="${2:-}" all="${3:-}" labels lbl r
  labels="$(tt_hr_week_labels "$all")"
  local IFS='|'
  for lbl in $labels; do
    unset IFS
    [ -n "$lbl" ] || { IFS='|'; continue; }
    r="$(tt_hr_group_expand "$lbl")"
    case "$r" in
      OK:*)
        if [ "$(tt_hr_rows_match_count "$needle" "$needle2")" != "0" ]; then
          echo "$lbl"; return 0
        fi ;;
      *) echo "  (group '$lbl': $r)" >&2 ;;
    esac
    IFS='|'
  done
  unset IFS
  return 1
}

# tt_hr_find_group_for <consultant> [all] — tt_hr_find_group_with, but matched on
# the rows' consultant CELL exactly. Use this whenever the needle is a consultant:
# 'E2E Consultant' is a substring of 'E2E Consultant Two', so a text match stops on
# the wrong person's week.
tt_hr_find_group_for() {
  local who="$1" all="${2:-}" labels lbl r
  labels="$(tt_hr_week_labels "$all")"
  local IFS='|'
  for lbl in $labels; do
    unset IFS
    [ -n "$lbl" ] || { IFS='|'; continue; }
    r="$(tt_hr_group_expand "$lbl")"
    case "$r" in
      OK:*) [ "$(tt_hr_count_rows_for "$who")" != "0" ] && { echo "$lbl"; return 0; } ;;
      *)    echo "  (group '$lbl': $r)" >&2 ;;
    esac
    IFS='|'
  done
  unset IFS
  return 1
}

# tt_hr_rows_match_count <needle> [needle2] — how many rows in the EXPANDED groups
# contain <needle> (and <needle2>) in their text.
tt_hr_rows_match_count() {
  playwright-cli eval "() => { $(_tt_hr_grp_js) let n = 0; for (const x of HG.groups().filter(y => y.open)) for (const r of HG.rows(x.g)) { const t = r.innerText || ''; if (t.indexOf('$1') >= 0 && ('${2:-}' === '' || t.indexOf('${2:-}') >= 0)) n++; } return String(n); }" 2>/dev/null | _tt_eval_str
}

# tt_hr_expand_all — expand EVERY group on the open grouped tab and page each one's
# rows in, in one round trip. Echoes the number of rows rendered. For whole-tab
# counts; anything that reads "the selected week" wants tt_hr_select_week instead,
# which leaves exactly one group open.
tt_hr_expand_all() {
  playwright-cli eval "async () => { $(_tt_hr_grp_js) if (!HG.kind) return '0'; const deadline = Date.now() + 40000; while (Date.now() < deadline) { const c = HG.groups().find(x => !x.open); if (!c) break; c.t.click(); for (let i = 0; i < 20; i++) { await HG.sleep(300); const again = HG.groups().find(x => x.label === c.label); if (!again || again.open) break; } } let n = 0; for (const x of HG.groups()) { await HG.pageIn(x.g); n += HG.rows(x.g).length; } return String(n); }" 2>/dev/null | _tt_eval_str
}

# tt_hr_count_rows_for <consultant> — rows in the EXPANDED groups whose consultant
# cell reads exactly <consultant>. Exact, because 'E2E Consultant' is a prefix of
# 'E2E Consultant Two'.
tt_hr_count_rows_for() {
  playwright-cli eval "() => { $(_tt_hr_grp_js) let n = 0; for (const x of HG.groups().filter(y => y.open)) for (const r of HG.rows(x.g)) if (((r.querySelector('$TT_HR_TXT_CONSULTANT_ANY') || {}).innerText || '').trim() === '$1') n++; return String(n); }" 2>/dev/null | _tt_eval_str
}

# tt_hr_row_facts <consultant> [project-fragment] — the first row in the EXPANDED
# groups whose consultant cell is exactly <consultant> (and whose project cell
# contains <project-fragment>), as one line:
#   <group key>~~<consultant>~~<project>~~<total hours>~~<week cell (Monthly only)>
# Nothing when no row matches. Read from the row's named cells, so no label text is
# needed - the table's column headings live in a separate header row.
tt_hr_row_facts() {
  playwright-cli eval "() => { $(_tt_hr_grp_js) const K = HG.kind; if (!K) return ''; const c = (r, n) => ((r.querySelector('.mx-name-txt' + K + n) || {}).innerText || '').replace(/\s+/g, ' ').trim(); for (const x of HG.groups().filter(y => y.open)) for (const r of HG.rows(x.g)) { if (c(r, 'Consultant') !== '$1') continue; if ('${2:-}' !== '' && c(r, 'Project').indexOf('${2:-}') < 0) continue; return [x.key || x.label, c(r, 'Consultant'), c(r, 'Project'), c(r, 'TotalHours'), c(r, 'Week')].join('~~'); } return ''; }" 2>/dev/null | _tt_eval_str | grep -v '^null$'
}

# tt_hr_row_click <consultant> <project-fragment> <button-css> — press <button-css>
# on the first matching row (as tt_hr_row_facts matches it). Prints ok | NF |
# NOBUTTON. Scoped to the row, so a neighbouring row's button can never be pressed.
tt_hr_row_click() {
  playwright-cli eval "() => { $(_tt_hr_grp_js) const K = HG.kind; if (!K) return 'NF'; const c = (r, n) => ((r.querySelector('.mx-name-txt' + K + n) || {}).innerText || '').replace(/\s+/g, ' ').trim(); for (const x of HG.groups().filter(y => y.open)) for (const r of HG.rows(x.g)) { if (c(r, 'Consultant') !== '$1') continue; if ('$2' !== '' && c(r, 'Project').indexOf('$2') < 0) continue; const b = r.querySelector('$3'); if (!b) return 'NOBUTTON'; b.click(); return 'ok'; } return 'NF'; }" 2>/dev/null | _tt_eval_str
}

# tt_hr_group_click <week-key|month-label> <button-css> — press a control that sits
# on a group's BAND (btnInvoiceExportMonth, btnSentPrintWeek), scoped to that one
# group. Prints ok | NF (no such group) | NOBUTTON.
#
# WHY SCOPED. Every group has its own Export / Print, all with the same widget name,
# so document.querySelector('.mx-name-btnInvoiceExportMonth') is "the first month on
# screen" - which is how the old Export All fallback (/^export/i on any button) would
# have exported whichever month sorted first, not the month the test prepared.
tt_hr_group_click() {
  playwright-cli eval "() => { $(_tt_hr_grp_js) const x = HG.find('$1'); if (!x) return 'NF'; const bs = [...x.g.querySelectorAll('$2')].filter(b => b.offsetParent !== null); if (bs.length !== 1) return 'NOBUTTON:' + bs.length; bs[0].click(); return 'ok'; }" 2>/dev/null | _tt_eval_str
}

# tt_hr_export_month <month-label> — press THAT month's Export (Monthly tab).
tt_hr_export_month() { tt_hr_group_click "$1" "$TT_HR_BTN_EXPORT_MONTH"; }

# tt_hr_print_week <week-key> — press THAT week's Print (Sent tab).
tt_hr_print_week() {
  local key; key="$(tt_week_key "$1")"; [ -n "$key" ] || key="$1"
  tt_hr_group_click "$key" "$TT_HR_BTN_PRINT_WEEK"
}

# tt_hr_group_census <owned-js> — for the EXPANDED groups: "<rows>|<owned rows>",
# where <owned-js> is a JS boolean over `t`, the row's consultant text (see
# _tt683_owned_js). Used before a destructive per-group action to prove the group
# holds only rows the suite owns.
tt_hr_group_census() {
  playwright-cli eval "() => { $(_tt_hr_grp_js) let a = 0, o = 0; for (const x of HG.groups().filter(y => y.open)) for (const r of HG.rows(x.g)) { a++; const t = ((r.querySelector('$TT_HR_TXT_CONSULTANT_ANY') || {}).innerText || '').trim(); if ($1) o++; } return a + '|' + o; }" 2>/dev/null | _tt_eval_str
}
