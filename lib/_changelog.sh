#!/usr/bin/env bash
# _changelog.sh — read assignment entries TOGETHER WITH their change history
# (Main.ChangeLog) and their week's status, from the data layer. Source AFTER
# lib/_login.sh.
#
# WHY THE DATA LAYER. An entry's history is shown only in a popup several clicks
# deep, on a list that (like every rebuilt list) does not refresh until a heading is
# clicked; and a week's status is a badge whose repaint lags the server. The specs
# that use this ask "was a history row saved?" and "what state is the week in?",
# which only the objects answer reliably. Same mx.data.get approach as
# tt_week_statuses (lib/_login_core.sh) and verify-export-hours-invariant.
#
# WHO MAY CALL IT. Main.ChangeLog is readable by HR and Titan Manager only
# (verify-changelog-role-denial), so sign in as e2e_hr first. The reads run under
# that role's entity access, exactly as the app's own pages do.
#
# HOW A ROW IS MATCHED TO ITS ENTRY. Main.ChangeLog_AssignmentEntry is owned by the
# ChangeLog, so each log row carries a reference to its entry and is asked for by
# that reference. A log row the app created but never committed does not exist in
# the database and is, correctly, not returned.

# tt_cl_entries <entry-xpath-constraint>
#
# Every Main.AssignmentEntry matching //Main.AssignmentEntry<constraint> (max 300),
# one line each:
#
#   <entry guid>~<consultant>~<project>~<week "Mon DD - Mon DD">~<entry status>~<timesheet guid>~<timesheet status>~<trail>
#
# <trail> is the entry's change history, oldest first, ';'-separated, each row
#   <From>><To>/<ChangeMethod>/<RejectionComments, trimmed to 60>
# with an empty From shown as '-'. An entry with no history has an empty trail.
# The week is formatted in the BROWSER's time zone, as the app shows it.
#
# Prints nothing for no match; ERR:<why> when a read failed. A caller must never
# read ERR as "no rows".
tt_cl_entries() {
  local c="$1" js
  js="$(cat <<'EOF'
() => new Promise(res => {
  const guard = setTimeout(() => res('ERR:timeout'), 45000);
  const done = r => { clearTimeout(guard); res(r); };
  try {
    if (typeof mx === 'undefined' || !mx.data) return done('ERR:no-mx-client');
    const get = o => new Promise((ok, ko) => mx.data.get(Object.assign({ callback: ok, error: e => ko(e) }, o)));
    const M = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const p2 = n => String(n).padStart(2, '0');
    const md = v => { if (!v) return '?'; const d = new Date(v); return M[d.getMonth()] + ' ' + p2(d.getDate()); };
    const uniq = a => [...new Set(a.filter(Boolean))];
    (async () => {
      const es = await get({ xpath: "//Main.AssignmentEntry__C__", filter: { amount: 300 } });
      if (!es || !es.length) return '';
      const ag = uniq(es.map(e => e.get('Main.AssignmentEntry_Assignment')));
      const tg = uniq(es.map(e => e.get('Main.AssignmentEntry_Timesheet')));
      const as = ag.length ? await get({ guids: ag }) : [];
      const ts = tg.length ? await get({ guids: tg }) : [];
      const pg = uniq(as.map(a => a.get('Main.Assignment_Project')));
      const ps = pg.length ? await get({ guids: pg }) : [];
      const pn = {}; ps.forEach(p => { pn[p.getGuid()] = p.get('Name'); });
      const ai = {}; as.forEach(a => { ai[a.getGuid()] = { who: a.get('ConsultantName') || '?', proj: pn[a.get('Main.Assignment_Project')] || '?' }; });
      const ti = {}; ts.forEach(t => { ti[t.getGuid()] = { wk: md(t.get('StartDate')) + ' - ' + md(t.get('EndDate')), st: t.get('Status') || '(empty)' }; });
      const logs = {};
      for (let i = 0; i < es.length; i += 40) {
        const chunk = es.slice(i, i + 40).map(e => "Main.ChangeLog_AssignmentEntry = '" + e.getGuid() + "'").join(' or ');
        const ls = await get({ xpath: '//Main.ChangeLog[' + chunk + ']', filter: { amount: 2000 } });
        (ls || []).forEach(l => { const k = l.get('Main.ChangeLog_AssignmentEntry'); (logs[k] = logs[k] || []).push(l); });
      }
      const clean = s => String(s || '').replace(/[~;|\n\r]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 60);
      return es.map(e => {
        const a = ai[e.get('Main.AssignmentEntry_Assignment')] || { who: '?', proj: '?' };
        const tgd = e.get('Main.AssignmentEntry_Timesheet');
        const t = ti[tgd] || { wk: '?', st: '?' };
        const trail = (logs[e.getGuid()] || [])
          .sort((x, y) => (Number(x.get('createdDate')) || 0) - (Number(y.get('createdDate')) || 0))
          .map(l => (l.get('FromStatus') || '-') + '>' + (l.get('ToStatus') || '-') + '/' + (l.get('ChangeMethod') || '-') + '/' + clean(l.get('RejectionComments')))
          .join(';');
        return [e.getGuid(), a.who, a.proj, t.wk, e.get('Status') || '(empty)', tgd || '?', t.st, trail].join('~');
      }).sort().join('\n');
    })().then(done, e => done('ERR:' + ((e && e.message) || e)));
  } catch (e) { done('ERR:' + e.message); }
})
EOF
)"
  js="${js//__C__/$c}"
  playwright-cli eval "$js" 2>/dev/null | _tt_eval_str | grep -v '^null$' | grep .
}

# tt_cl_e2e_constraint [status] — the XPath constraint for entries of the suite's
# own consultants (Assignment/ConsultantName starts with 'E2E '), optionally in one
# status. ConsultantName is the stored copy on the Assignment, which HR can read;
# the System.User.Name path cannot be read by HR and silently matches nothing
# (TT-735, lib/_entries.sh on the bug-repro branch).
tt_cl_e2e_constraint() {
  local c="[starts-with(Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName,'E2E ')]"
  [ -n "${1:-}" ] && c="$c[Status = '$1']"
  printf '%s' "$c"
}

# tt_cl_field <line> <n> — field n (1-based) of a tt_cl_entries line.
tt_cl_field() {
  printf '%s' "$1" | awk -F'~' -v n="$2" '{ print $n }'
}

# tt_cl_trail_has <trail> <from> <to> — 0 when the trail holds a <from> -> <to> row.
# Either side may be '*' for "any".
tt_cl_trail_has() {
  local trail="$1" from="$2" to="$3" row f t IFS=';'
  for row in $trail; do
    f="${row%%>*}"; t="${row#*>}"; t="${t%%/*}"
    { [ "$from" = "*" ] || [ "$f" = "$from" ]; } && { [ "$to" = "*" ] || [ "$t" = "$to" ]; } && return 0
  done
  return 1
}
