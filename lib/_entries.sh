#!/usr/bin/env bash
# _entries.sh — read ONE week's timesheet and its assignment entries from the data
# layer, per project. Source AFTER lib/_login.sh.
#
# WHY THE DATA LAYER. The timesheet page never renders an entry's own status, and a
# row's editability lags a server change (see tt_draft_count in lib/_login_core.sh).
# The bug-reproduction specs that use this ask "what state is entry X in now?", which
# only the objects answer reliably. Same mx.data.get approach as tt_week_statuses and
# tt_draft_count, extended to follow entry -> assignment -> project / account.
#
# Runs as whoever is signed in, under that role's entity access: a consultant sees
# their own timesheets, HR sees everyone's.

# tt_week_entries <account> <week-label>
#
# <account> is a login Name ("e2e_consultant2") or, when it contains a space, a
# FullName ("E2E Consultant Two"). Pass the FullName when reading as HR or a Titan
# Manager: they cannot read the inherited System.User.Name, and Mendix then returns
# ZERO rows for an XPath on it, silently - even inside an `or` with a readable member
# (verified on dev 2026-09-28: as e2e_hr, [.../Account/FullName = 'E2E Consultant Two']
# finds 3 timesheets, [.../Account[Name = '...' or FullName = '...']] finds 0). Same
# trap TT-735 documents for [Active].
#
# Prints ONE line:  WEEK=<status>|<project>~<owner>=<status>|...
#   <week-label>  any shape tt_week_key accepts ("Sep 06 - Sep 12", the grid caption, ...)
#   <owner>       the FullName (Name when FullName is empty) of the account the entry's
#                 ASSIGNMENT belongs to,
#                 which is not necessarily the timesheet's owner - that difference is
#                 the whole of bug #8 (Clear adding the acting user's assignments).
# Echoes NOWEEK when the account has no timesheet starting on that date, and
# ERR:<why> when the read itself failed. A caller must treat neither as a status.
#
# The week is matched on the StartDate's month and day in the BROWSER's time zone,
# exactly as tt_week_statuses does, so the two can never disagree about which week
# is meant.
tt_week_entries() {
  local user="$1" key mon day js attr
  key="$(tt_week_key "$2")"
  [ -n "$key" ] || { echo "ERR:not-a-week-label:$2"; return 0; }
  mon="${key%% *}"
  day="${key#* }"; day="${day%% *}"; day="$((10#$day))"
  js="$(cat <<'EOF'
() => new Promise(res => {
  const guard = setTimeout(() => res('ERR:timeout'), 30000);
  const done = r => { clearTimeout(guard); res(r); };
  try {
    if (typeof mx === 'undefined' || !mx.data) return done('ERR:no-mx-client');
    const get = o => new Promise((ok, ko) => mx.data.get(Object.assign({ callback: ok, error: e => ko(e) }, o)));
    const M = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    (async () => {
      const ts = await get({ xpath: "//Main.Timesheet[Main.Timesheet_Account/Administration.Account/__ATTR__ = '__USER__']", filter: { amount: 400 } });
      const wk = (ts || []).find(o => { const d = o.get('StartDate'); if (!d) return false; const dt = new Date(d); return M[dt.getMonth()] === '__MON__' && dt.getDate() === __DAY__; });
      if (!wk) return 'NOWEEK';
      const es = await get({ xpath: "//Main.AssignmentEntry[Main.AssignmentEntry_Timesheet = '" + wk.getGuid() + "']", filter: { amount: 200 } });
      const ag = [...new Set((es || []).map(e => e.get('Main.AssignmentEntry_Assignment')).filter(Boolean))];
      const as = ag.length ? await get({ guids: ag }) : [];
      const pg = [...new Set(as.map(a => a.get('Main.Assignment_Project')).filter(Boolean))];
      const cg = [...new Set(as.map(a => a.get('Main.Assignment_Account')).filter(Boolean))];
      const ps = pg.length ? await get({ guids: pg }) : [];
      let cs = [];
      try { cs = cg.length ? await get({ guids: cg }) : []; } catch (e) { cs = []; }
      const pn = {}; ps.forEach(p => { pn[p.getGuid()] = p.get('Name'); });
      const cn = {}; cs.forEach(c => { cn[c.getGuid()] = c.get('FullName') || c.get('Name'); });
      const ai = {}; as.forEach(a => { ai[a.getGuid()] = (pn[a.get('Main.Assignment_Project')] || '?') + '~' + (cn[a.get('Main.Assignment_Account')] || '?'); });
      const rows = (es || []).map(e => (ai[e.get('Main.AssignmentEntry_Assignment')] || '?~?') + '=' + (e.get('Status') || '(empty)'));
      rows.sort();
      return ['WEEK=' + (wk.get('Status') || '(empty)')].concat(rows).join('|');
    })().then(done, e => done('ERR:' + ((e && e.message) || e)));
  } catch (e) { done('ERR:' + e.message); }
})
EOF
)"
  case "$user" in *" "*) attr=FullName ;; *) attr=Name ;; esac
  js="${js//__ATTR__/$attr}"
  js="${js//__USER__/$user}"
  js="${js//__MON__/$mon}"
  js="${js//__DAY__/$day}"
  playwright-cli eval "$js" 2>/dev/null | _tt_eval_str
}

# tt_entry_status_of <tt_week_entries-output> <project> [owner]
# The status of the entry on <project> (and, when given, whose assignment belongs to
# <owner>). Several matches print space-separated; none prints ''.
tt_entry_status_of() {
  local out="$1" proj="$2" owner="${3:-}" f res=""
  local IFS='|'
  for f in $out; do
    case "$f" in
      WEEK=*) continue ;;
    esac
    local lhs="${f%%=*}" st="${f#*=}"
    [ "${lhs%%~*}" = "$proj" ] || continue
    if [ -n "$owner" ] && [ "${lhs#*~}" != "$owner" ]; then continue; fi
    res="${res:+$res }$st"
  done
  printf '%s' "$res"
}

# tt_evidence <name> — screenshot the page to $TT_EVIDENCE_DIR/<name>.png when that
# variable is set; a no-op otherwise. Evidence, never an assertion: it cannot fail a
# step.
tt_evidence() {
  [ -n "${TT_EVIDENCE_DIR:-}" ] || return 0
  mkdir -p "$TT_EVIDENCE_DIR" 2>/dev/null || return 0
  playwright-cli screenshot --full-page --filename="$TT_EVIDENCE_DIR/$1.png" >/dev/null 2>&1 || true
}
