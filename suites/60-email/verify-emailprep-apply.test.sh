#!/usr/bin/env bash
# Redirect dev's outbound mail to one inbox by rewriting recipient DATA.
#
#   DRY RUN (default): opens every record, reports old -> new, saves NOTHING.
#   APPLY:             EMAILPREP_APPLY=1 — fills the field and clicks Save.
#
#   TT_BASE_URL=https://titantime100-development.mendixcloud.com \
#   TT_ADMIN_USER=MxAdmin TT_ADMIN_PASS=... EMAILPREP_TARGET=jnorris@titanconsulting.net \
#   mxcli playwright verify tests/verify-emailprep-apply.test.sh \
#     --base-url https://titantime100-development.mendixcloud.com -t 30m --verbose
#
# Two surfaces, both reached from the MxAdmin "Admin Hub":
#   Accounts Overview -> a[aria-label="Edit Account"] -> Email box -> Save
#   Project Overview  -> the PENCIL link -> "Client Approver Email" -> Save
#
# Customer.ContactEmail is deliberately NOT touched: Customer_NewEdit exposes
# only the Company field, so the attribute has no editor anywhere in the app,
# and no email microflow reads it (every send resolves its recipient from
# Account.Email or Project.ContactEmail).
#
# DESTRUCTIVE CONTROLS THAT LIVE NEXT TO THE ONES WE WANT — never selected here:
#   accounts: a[aria-label="Force Reset Password"], a[aria-label="Delete Account"]
#   projects: .mx-name-actionButton2 (mx-icon-trash-can)
# The edit affordances are icon-only <a role=button> links; the account one is
# identified by aria-label and the project one by its mx-icon-pencil child, and
# every click is guarded by that check rather than by position.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

ADMIN_U="${TT_ADMIN_USER:-MxAdmin}"
ADMIN_P="${TT_ADMIN_PASS:-}"
TARGET="${EMAILPREP_TARGET:-jnorris@titanconsulting.net}"
APPLY="${EMAILPREP_APPLY:-}"
[ -n "$ADMIN_P" ] || tt_fail "set TT_ADMIN_PASS"

if [ -n "$APPLY" ]; then echo "### MODE: APPLY — changes WILL be saved"; else echo "### MODE: DRY RUN — nothing will be saved"; fi
echo "### target address: $TARGET"

CHANGED=0; SKIPPED=0; FAILED=0

ev() { playwright-cli eval "$1" 2>/dev/null | sed -n '2p' | sed -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g'; }

# reach_login_form — get to a clean Sign In page. Returns 'ok' | 'no'.
#
# This is the flaky part of the whole script. cookie-clear does not drop the
# runtime's httpOnly session cookie, and an existing session gets restored on
# navigation — several runs silently ended up on an e2e_hr dashboard while
# believing they were MxAdmin. So: hit /logout, then require the words "Sign In"
# AND exactly one password box before typing anything.
reach_login_form() {
  local i
  for i in 1 2 3 4 5 6; do
    playwright-cli goto "$TT_BASE/logout" >/dev/null 2>&1
    sleep 5
    playwright-cli cookie-clear >/dev/null 2>&1
    playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
    sleep 6
    if [ "$(ev "() => String(/sign in/i.test(document.body.innerText) && document.querySelectorAll('input.form-control[type=password]').length === 1)")" = "true" ]; then
      echo "ok"; return 0
    fi
    playwright-cli eval "() => { if (window.mx && mx.logout) { mx.logout(); return 'out'; } return 'no-mx'; }" >/dev/null 2>&1
    sleep 7
  done
  echo "no"
}

admin_login() {
  local attempt i landed
  for attempt in 1 2 3; do
    [ "$(reach_login_form)" = "ok" ] || { echo "  (attempt $attempt: never got a clean Sign In form)"; continue; }
    playwright-cli fill "input.form-control[type=text]" "$ADMIN_U" >/dev/null 2>&1
    playwright-cli fill "input.form-control[type=password]" "$ADMIN_P" >/dev/null 2>&1
    playwright-cli click ".mx-name-actionButton1" >/dev/null 2>&1
    landed=""
    for i in $(seq 1 25); do
      if [ "$(ev "() => String(/Admin Hub/i.test(document.body.innerText))")" = "true" ]; then landed="admin"; break; fi
      if [ "$(ev "() => String(/invalid credentials|is incorrect/i.test(document.body.innerText))")" = "true" ]; then landed="rejected"; break; fi
      # any other dashboard means a stale session was restored, not our sign-in
      if [ "$(ev "() => String(/HR Dashboard|Titan Manager|My Timesheets|Project Manager Dashboard/i.test(document.body.innerText))")" = "true" ]; then landed="wrong-user"; break; fi
      sleep 2
    done
    case "$landed" in
      admin)      echo "### signed in as $ADMIN_U (Admin Hub)"; return 0 ;;
      rejected)   tt_fail "$ADMIN_U: credentials rejected on $TT_BASE" ;;
      wrong-user) echo "  (attempt $attempt: landed on someone else's dashboard — a stale session was restored; retrying)" ;;
      *)          echo "  (attempt $attempt: no dashboard within 50s; retrying)" ;;
    esac
  done
  tt_fail "$ADMIN_U: could not establish an admin session after 3 attempts"
}

go_home() { playwright-cli goto "$TT_BASE/" >/dev/null 2>&1; sleep 6; }

open_card() {
  local r
  r=$(ev "() => {
    const el = [...document.querySelectorAll('*')].find(e => e.offsetParent !== null &&
      e.childElementCount === 0 && (e.innerText||'').trim() === '$1');
    if (!el) return 'NOTFOUND';
    let t = el; for (let k=0;k<5&&t;k++){ if (getComputedStyle(t).cursor==='pointer') break; t=t.parentElement; }
    (t||el).click(); return 'ok';
  }")
  [ "$r" = "ok" ] || tt_fail "could not open the '$1' card on the Admin Hub"
  sleep 7
}

row_count() { ev "() => { const g=[...document.querySelectorAll('[role=grid],[role=treegrid]')].filter(e=>e.offsetParent!==null)[0]; return String(g ? [...g.querySelectorAll('[role=row]')].length - 1 : 0); }"; }

# pager_next — click the grid's next-page control. Returns 'ok' | 'end'.
pager_next() {
  ev "() => {
    const btns = [...document.querySelectorAll('button, a[role=button]')].filter(e => e.offsetParent !== null);
    const next = btns.find(e => /next/i.test((e.getAttribute('aria-label')||'') + ' ' + (e.getAttribute('title')||'')));
    if (!next) return 'end';
    if (next.disabled || next.getAttribute('aria-disabled') === 'true' || next.classList.contains('disabled')) return 'end';
    next.click(); return 'ok';
  }"
}

# email_selector — the .mx-name-* wrapper of the visible input whose form-group
# label matches <regex>, so fill() can target it. Auto-named widgets differ per
# form (textBox10 on the account editor, txtApproverEmail on the project one),
# so resolve it from the LABEL at runtime rather than hard-coding either.
email_selector() {
  ev "() => {
    const ins = [...document.querySelectorAll('input')].filter(i => i.offsetParent !== null);
    for (const i of ins) {
      const grp = i.closest('.form-group');
      const lbl = grp ? ((grp.querySelector('label')||{}).innerText||'').trim() : '';
      if (!/$1/i.test(lbl)) continue;
      let w = i;
      for (let k = 0; k < 6 && w; k++) {
        const m = (w.className||'').toString().match(/mx-name-[A-Za-z0-9_]+/);
        if (m) return m[0];
        w = w.parentElement;
      }
    }
    return 'NONE';
  }"
}

current_value() { ev "() => { const i=document.querySelector('.$1 input'); return i ? i.value : 'NOINPUT'; }"; }

click_by_text() {
  ev "() => {
    const b = [...document.querySelectorAll('button, a[role=button]')].filter(x => x.offsetParent !== null)
      .find(x => new RegExp('^$1\$','i').test((x.innerText||'').trim()));
    if (b) { b.click(); return 'ok'; }
    return 'none';
  }"
}

########################################################################
# PART A — accounts
########################################################################
process_accounts() {
  echo
  echo "########## ACCOUNTS ##########"
  local page=1 idx n name before sel r
  while : ; do
    n=$(row_count)
    echo "-- accounts page $page: $n rows --"
    [ "$n" -gt 0 ] 2>/dev/null || { echo "   (no rows)"; break; }
    for idx in $(seq 1 "$n"); do
      name=$(ev "() => {
        const g=[...document.querySelectorAll('[role=grid],[role=treegrid]')].filter(e=>e.offsetParent!==null)[0];
        const r=[...g.querySelectorAll('[role=row]')][$idx];
        return r ? (r.innerText||'').replace(/\n+/g,' | ').slice(0,60) : 'NOROW';
      }")
      [ "$name" = "NOROW" ] && continue
      r=$(ev "() => {
        const g=[...document.querySelectorAll('[role=grid],[role=treegrid]')].filter(e=>e.offsetParent!==null)[0];
        const row=[...g.querySelectorAll('[role=row]')][$idx];
        const edit=row ? row.querySelector('a[aria-label=\"Edit Account\"]') : null;
        if (!edit) return 'NOEDIT';
        edit.click(); return 'ok';
      }")
      if [ "$r" != "ok" ]; then echo "   SKIP  $name  (no Edit Account link)"; SKIPPED=$((SKIPPED+1)); continue; fi
      sleep 4
      sel=$(email_selector "^email\$")
      if [ "$sel" = "NONE" ]; then
        echo "   FAIL  $name  (editor has no Email field)"; FAILED=$((FAILED+1))
        click_by_text "cancel" >/dev/null; sleep 3; continue
      fi
      before=$(current_value "$sel")
      if [ "$before" = "$TARGET" ]; then
        echo "   ok    $name  already $TARGET"; SKIPPED=$((SKIPPED+1))
        click_by_text "cancel" >/dev/null; sleep 3; continue
      fi
      echo "   EDIT  $name"
      echo "         $before  ->  $TARGET"
      if [ -n "$APPLY" ]; then
        tt_fill ".$sel input" "$TARGET"
        sleep 1
        [ "$(click_by_text 'save')" = "ok" ] || { echo "         FAIL: no Save button"; FAILED=$((FAILED+1)); }
        sleep 4
        CHANGED=$((CHANGED+1))
      else
        click_by_text "cancel" >/dev/null; sleep 3
        CHANGED=$((CHANGED+1))
      fi
    done
    [ "$(pager_next)" = "ok" ] || break
    sleep 5; page=$((page+1))
    [ "$page" -gt 15 ] && { echo "   (stopping after 15 pages)"; break; }
  done
}

########################################################################
# PART B — projects
########################################################################
process_projects() {
  echo
  echo "########## PROJECTS ##########"
  local page=1 idx n name before sel r
  while : ; do
    n=$(row_count)
    echo "-- projects page $page: $n rows --"
    [ "$n" -gt 0 ] 2>/dev/null || { echo "   (no rows)"; break; }
    for idx in $(seq 1 "$n"); do
      name=$(ev "() => {
        const g=[...document.querySelectorAll('[role=grid],[role=treegrid]')].filter(e=>e.offsetParent!==null)[0];
        const r=[...g.querySelectorAll('[role=row]')][$idx];
        return r ? (r.innerText||'').replace(/\n+/g,' | ').slice(0,60) : 'NOROW';
      }")
      [ "$name" = "NOROW" ] && continue
      # the pencil, identified by its icon — NOT by position. The neighbouring
      # link is mx-icon-trash-can (Delete).
      r=$(ev "() => {
        const g=[...document.querySelectorAll('[role=grid],[role=treegrid]')].filter(e=>e.offsetParent!==null)[0];
        const row=[...g.querySelectorAll('[role=row]')][$idx];
        if (!row) return 'NOROW';
        const edit=[...row.querySelectorAll('a')].find(a => {
          const ic=a.querySelector('span[class*=mx-icon]');
          return ic && /mx-icon-pencil/.test(ic.getAttribute('class')||'');
        });
        if (!edit) return 'NOEDIT';
        edit.click(); return 'ok';
      }")
      if [ "$r" != "ok" ]; then echo "   SKIP  $name  (no pencil link)"; SKIPPED=$((SKIPPED+1)); continue; fi
      sleep 4
      sel=$(email_selector "approver email")
      if [ "$sel" = "NONE" ]; then
        echo "   FAIL  $name  (editor has no Client Approver Email field)"; FAILED=$((FAILED+1))
        click_by_text "cancel" >/dev/null; sleep 3; continue
      fi
      before=$(current_value "$sel")
      if [ "$before" = "$TARGET" ]; then
        echo "   ok    $name  already $TARGET"; SKIPPED=$((SKIPPED+1))
        click_by_text "cancel" >/dev/null; sleep 3; continue
      fi
      echo "   EDIT  $name"
      echo "         '$before'  ->  $TARGET"
      if [ -n "$APPLY" ]; then
        tt_fill ".$sel input" "$TARGET"
        sleep 1
        [ "$(click_by_text 'save')" = "ok" ] || { echo "         FAIL: no Save button"; FAILED=$((FAILED+1)); }
        sleep 4
        CHANGED=$((CHANGED+1))
      else
        click_by_text "cancel" >/dev/null; sleep 3
        CHANGED=$((CHANGED+1))
      fi
    done
    [ "$(pager_next)" = "ok" ] || break
    sleep 5; page=$((page+1))
    [ "$page" -gt 15 ] && { echo "   (stopping after 15 pages)"; break; }
  done
}

admin_login
open_card "Accounts Overview"; process_accounts
go_home
open_card "Project Overview";  process_projects

echo
echo "########## SUMMARY ##########"
if [ -n "$APPLY" ]; then echo "  changed: $CHANGED"; else echo "  would change: $CHANGED"; fi
echo "  skipped: $SKIPPED"
echo "  failed:  $FAILED"
[ "$FAILED" -eq 0 ] || tt_fail "$FAILED record(s) could not be processed"
echo "DONE"
