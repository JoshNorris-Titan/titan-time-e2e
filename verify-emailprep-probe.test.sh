#!/usr/bin/env bash
# READ-ONLY probe #14 — identify the two icon-only links on a Project Overview row.
#
# They are .mx-name-actionButton1 and .mx-name-actionButton2, both <a> with no
# aria-label and no text. One is almost certainly Edit and the other Delete, and
# on the Accounts grid the neighbouring control was a destructive Force Reset —
# so read the icon class instead of clicking to find out.

set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"

ADMIN_U="${TT_ADMIN_USER:-MxAdmin}"
ADMIN_P="${TT_ADMIN_PASS:-}"
[ -n "$ADMIN_P" ] || tt_fail "set TT_ADMIN_PASS"

admin_login() {
  local i seen="" ok=""
  for i in 1 2 3 4 5; do
    playwright-cli goto "$TT_BASE/logout" >/dev/null 2>&1
    sleep 4
    playwright-cli cookie-clear >/dev/null 2>&1
    playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
    sleep 5
    if playwright-cli eval "() => String(document.querySelectorAll('input.form-control[type=password]').length === 1)" 2>/dev/null \
         | sed -n '2p' | grep -qi true; then seen=1; break; fi
    playwright-cli eval "() => { if (window.mx && mx.logout) { mx.logout(); return 'out'; } return 'no-mx'; }" >/dev/null 2>&1
    sleep 6
  done
  [ -n "$seen" ] || tt_fail "no Sign In form after 5 logout attempts"
  playwright-cli fill "input.form-control[type=text]" "$ADMIN_U" >/dev/null 2>&1
  playwright-cli fill "input.form-control[type=password]" "$ADMIN_P" >/dev/null 2>&1
  playwright-cli click ".mx-name-actionButton1" >/dev/null 2>&1
  for i in $(seq 1 30); do
    if playwright-cli eval "() => String(/Admin Hub/i.test(document.body.innerText))" 2>/dev/null \
         | sed -n '2p' | grep -qi true; then ok=1; break; fi
    sleep 2
  done
  [ -n "$ok" ] || tt_fail "$ADMIN_U: did not reach the Admin Hub within 60s"
  echo "### signed in as $ADMIN_U"
}

admin_login
playwright-cli eval "() => {
  const el = [...document.querySelectorAll('*')].find(e => e.offsetParent !== null &&
    e.childElementCount === 0 && (e.innerText||'').trim() === 'Project Overview');
  let t = el; for (let k=0;k<5&&t;k++){ if (getComputedStyle(t).cursor==='pointer') break; t=t.parentElement; }
  (t||el).click(); return 'opened Project Overview';
}" 2>/dev/null | _tt_eval_str
sleep 7

echo
echo "=== project row 1: the two icon links, with their icon classes ==="
playwright-cli eval "() => {
  const g = [...document.querySelectorAll('[role=grid],[role=treegrid]')].filter(e => e.offsetParent !== null)[0];
  if (!g) return 'NO GRID';
  const row = [...g.querySelectorAll('[role=row]')][1];
  const links = [...row.querySelectorAll('a')];
  return links.map(a => {
    const icon = a.querySelector('span[class*=mx-icon], svg, i');
    return '  ' + ((a.className.match(/mx-name-[A-Za-z0-9_]+/)||['-'])[0]) +
      '  iconClass=\"' + (icon ? (icon.getAttribute('class')||'') : 'NO ICON') + '\"' +
      '  href=\"' + (a.getAttribute('href')||'') + '\"';
  }).join('\n') || 'NO LINKS';
}" 2>/dev/null | _tt_eval_str

echo
echo "=== all distinct icon classes in the project grid ==="
playwright-cli eval "() => {
  const g = [...document.querySelectorAll('[role=grid],[role=treegrid]')].filter(e => e.offsetParent !== null)[0];
  const icons = [...g.querySelectorAll('span[class*=mx-icon]')].map(e => e.getAttribute('class')||'');
  return '  ' + [...new Set(icons)].join('\n  ');
}" 2>/dev/null | _tt_eval_str

echo
echo "=== account form: confirm Save/Cancel widget names ==="
playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
sleep 6
playwright-cli eval "() => {
  const el = [...document.querySelectorAll('*')].find(e => e.offsetParent !== null &&
    e.childElementCount === 0 && (e.innerText||'').trim() === 'Accounts Overview');
  let t = el; for (let k=0;k<5&&t;k++){ if (getComputedStyle(t).cursor==='pointer') break; t=t.parentElement; }
  (t||el).click(); return 'opened Accounts Overview';
}" 2>/dev/null | _tt_eval_str
sleep 7
playwright-cli eval "() => {
  const g = [...document.querySelectorAll('[role=grid],[role=treegrid]')].filter(e => e.offsetParent !== null)[0];
  const row = [...g.querySelectorAll('[role=row]')][1];
  const edit = row.querySelector('a[aria-label=\"Edit Account\"]');
  if (!edit) return 'NO EDIT LINK';
  edit.click(); return 'opened editor for: ' + (row.innerText||'').replace(/\n+/g,' | ').slice(0,40);
}" 2>/dev/null | _tt_eval_str
sleep 6
playwright-cli eval "() => {
  const b = [...document.querySelectorAll('button, a[role=button]')].filter(x => x.offsetParent !== null)
    .filter(x => /^(save|cancel|save changes)\$/i.test((x.innerText||'').trim()))
    .map(x => '  ' + ((x.className.match(/mx-name-[A-Za-z0-9_]+/)||['(unnamed)'])[0]) + ' : \"' + (x.innerText||'').trim() + '\"');
  return b.join('\n') || '  NO SAVE/CANCEL FOUND';
}" 2>/dev/null | _tt_eval_str
playwright-cli eval "() => {
  const i = document.querySelector('.mx-name-textBox10 input');
  return '  textBox10 (Email) present=' + String(!!i) + ' value=\"' + (i ? i.value : '') + '\"';
}" 2>/dev/null | _tt_eval_str

echo
echo "PROBE COMPLETE"
