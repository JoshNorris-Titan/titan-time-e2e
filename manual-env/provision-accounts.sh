#!/usr/bin/env bash
# Provision the manual_* logins. RUN ONCE, BY HAND — not from either workflow.
#
# NOT NAMED *.test.sh, on purpose: it creates accounts and sets credentials, and must
# never be picked up by a runner sweep. Same reasoning as seeders/.
#
#   TT_BASE_URL=https://titantime100-development.mendixcloud.com \
#   TT_ADMIN_USER=MxAdmin TT_ADMIN_PASS=... TT_ROLE_PASS=... \
#     manual-env/provision-accounts.sh
#
# WHY THIS IS SEPARATE FROM THE BUILD WORKFLOW
# --------------------------------------------
# Creating a login is not a test side effect. It provisions a credential and — unlike a
# project or a timesheet — nothing here ever deletes it. The build and teardown workflows
# are both built on the accounts OUTLIVING them, so provisioning sits outside both and is
# invoked deliberately.
#
# THE FOUR PHASES
# ---------------
#   create   as the administrator, create each missing account on Core.Account_New
#   stage    as the administrator, unblock it if needed and set a STAGING password
#   reset    as the account itself, complete the forced reset to the real password
#   verify   as each account, sign in normally and land on its role's dashboard
#
# WHY A STAGING PASSWORD, AND NOT THE OBVIOUS ROUTE
# -------------------------------------------------
# The obvious route is the one a person follows: Account_New asks for no password, so it
# autogenerates one, mails it as "Welcome to the Titan Timesheet App", and flags the
# account to reset on first login; you read that password out of Admin Hub -> Emails Sent
# and complete the reset by hand. That works, and this script deliberately does NOT do it.
# Three measured reasons, all found while building this on 2026-09-09:
#
#  1. Core.Force_PasswordReset refuses "Your new password must be different from your
#     current password". So the mailed password can never be reset TO the target password
#     directly — something has to sit in between regardless.
#  2. A wrong guess at the mailed password costs a FAILED LOGIN, and Mendix blocks the
#     account after a few of those. That is not theoretical: manual_consultant ended up
#     Blocked=true during development, at which point every password returns "Invalid
#     Credentials" and the diagnosis looks exactly like a wrong password.
#  3. The welcome mail is sent once. Re-reading it later depends on the row still being
#     in the Emails Sent grid, and re-issuing it means driving Force Reset Password.
#
# The administrator's own "Change password" action on Administration.Account_Edit sets a
# password directly, with no old password and no mail. So: stage a known password, then
# let the account itself complete the reset from stage -> target. Deterministic, needs no
# mail, and costs exactly one login attempt per account.
#
# The staging password is DERIVED from the target rather than random, so `reset` can be
# re-run on its own without anything having been written down. Nothing is ever persisted
# to disk by this script.
#
# IDEMPOTENT AT EVERY PHASE. create skips an account whose Login row already exists;
# reset skips one that already accepts the target password. Re-running after a failure is
# safe and is the intended recovery.
#
# ONE CAVEAT: `stage` always sets the staging password, including on an account that was
# already finished, so it must always be followed by `reset`. The pair ends in the same
# place it started, but a `stage` that is interrupted before its `reset` leaves that
# account on the staging value — which is why they are adjacent in the default phase list
# and why MANUAL_ONLY accepts a LIST, so a re-run can name only the unfinished accounts.
#
# SELECTORS — VERIFIED LIVE ON DEV 2026-09-09, NOT READ FROM THE MODEL
# --------------------------------------------------------------------
# Admin Hub -> the "Accounts Overview" card is an AUTO-NAMED container (mx-name-container20
# today), so it is opened by its TEXT — the number renumbers as cards are added.
#
# Administration.Account_Overview:
#   "New local user" button              (and "New web service user" beside it — never it)
#   .mx-name-textFilter2 input           the Login column filter
#   a[aria-label="Edit Account"]         per row
#   a[aria-label="Force Reset Password"] per row  } NEVER CLICKED HERE. Both sit in the
#   a[aria-label="Delete Account"]       per row  } same row as the one action we want.
#
# Core.Account_New and Administration.Account_Edit both carry AUTO-NAMED fields, and they
# do not even agree with each other (Email is textBox1 on the new form and textBox10 on
# the edit form), so every field is resolved from its form-group LABEL at runtime. Only
# these names are used directly, because they are named in the model:
#   .mx-name-cbEmploymentStatus   employment status, both forms
#   .mx-name-microflowButton1     Save on Account_New / Change on the password dialog
#   .mx-name-cancelButton1        Cancel
#   .mx-name-saveButton1          Save on Account_Edit
#   .mx-name-microflowTrigger1    "Change password" on Account_Edit
#
# THE COMBOBOXES MUST BE OPENED ON .widget-combobox-input-container. Clicking the input
# leaves aria-expanded=false and renders zero options — measured, not guessed. And never
# press Escape to close one: Escape closes the whole popup, taking the half-filled form
# with it (the same trap lib/_fixtures.sh records for the date picker).
#
# Env:
#   TT_BASE_URL              REQUIRED. No default — this creates accounts.
#   TT_ADMIN_USER/PASS       administrator
#   TT_ROLE_PASS             the password the accounts end up with
#   TT_MANUAL_PASS           overrides TT_ROLE_PASS for the manual_* accounts
#   MANUAL_PHASES            space-separated subset of "create stage reset verify"
#   MANUAL_ONLY              one username, or several separated by spaces/commas/pipes
#   MANUAL_DRY_RUN=1         report what would be created, create nothing
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
cd "$TT_ROOT"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/manual-env/manual.env.sh"

[ -n "${TT_BASE_URL:-}" ] \
  || tt_fail "TT_BASE_URL must be set explicitly — this creates accounts and sets credentials, and must never fall back to a default environment"

ADMIN_U="${TT_ADMIN_USER:-MxAdmin}"
ADMIN_P="${TT_ADMIN_PASS:-}"
[ -n "$ADMIN_P" ] || tt_fail "TT_ADMIN_PASS is not set — Account_New is administrator-only"
TARGET_PASS="${TT_MANUAL_PASS:-${TT_ROLE_PASS:-$TT_PASS}}"
[ -n "$TARGET_PASS" ] || tt_fail "no target password — set TT_ROLE_PASS (or TT_MANUAL_PASS)"

# The staging password. Derived from the target so it satisfies whatever complexity rule
# the target satisfies, and so that `reset` can recompute it without anything having been
# stored. It exists on an account for seconds, between the stage and reset phases.
STAGE_PASS="${MANUAL_STAGE_PASS:-Sg7!$TARGET_PASS}"
[ "$STAGE_PASS" != "$TARGET_PASS" ] \
  || tt_fail "the staging password equals the target password — Core.Force_PasswordReset refuses a new password identical to the current one, so the reset could never complete"

PHASES="${MANUAL_PHASES:-create stage reset verify}"
ONLY="${MANUAL_ONLY:-}"
DRY="${MANUAL_DRY_RUN:-0}"

ev() { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }
pv() { echo "[provision] $*"; }

# ---------------------------------------------------------------- one run at a time
#
# THIS LOCK IS NOT DEFENSIVE PROGRAMMING — IT IS A BUG FIX.
#
# There is ONE shared playwright-cli session per machine, and browser_reset below closes
# and reopens it. Two provisioner runs therefore do not merely interleave, they destroy
# each other's browser mid-action: every eval starts returning empty, and the script then
# reports "the reset form has no password box", "sign-in never settled (STUCK)", or "could
# not find the Accounts Overview card" — none of which has anything to do with the
# account being processed.
#
# That happened here: a six-account run was still going when a second run was started
# against the same session, and three separate "bugs" were investigated before the real
# cause was noticed. The repo's own rule is the same one — README: "One e2e run at a time,
# machine-wide" — it just had nothing enforcing it.
#
# mkdir is atomic on every filesystem this runs on, which is why it is the lock and not a
# file test. A stale lock names the PID that held it so it can be judged rather than
# blindly removed.
LOCK_DIR="${MANUAL_LOCK_DIR:-${TMPDIR:-/tmp}/tt-manual-provision.lock}"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo unknown)"
  tt_fail "another provisioning run holds $LOCK_DIR (pid $holder). Only one run may drive the shared playwright-cli session — wait for it, or remove that directory if the process is gone."
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
# Released on every exit path, including tt_fail and Ctrl-C.
trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

# browser_reset — a genuinely anonymous browser.
#
# Used wherever this script changes identity. cookie-clear does not drop the runtime's
# httpOnly session, mx.logout() does not reliably escape Core.Force_PasswordReset, and the
# root URL of a still-signed-in session renders the app rather than the login page. A new
# context has none of those problems because it has no session at all. Same conclusion
# lib/_seed.sh records for its own identity switches.
browser_reset() {
  local i
  playwright-cli close >/dev/null 2>&1 || true
  sleep 2
  playwright-cli open "$TT_BASE/" >/dev/null 2>&1 \
    || tt_fail "could not reopen a browser session"
  playwright-cli cookie-clear >/dev/null 2>&1 || true

  # WAIT FOR THE PAGE TO EXIST, do not assume it after a fixed sleep.
  #
  # A `sleep 3` here is a race, and it is the one that made manual_consultant look broken
  # for four runs. main calls browser_reset and then phase_reset's login_probe calls it
  # again moments later; on the second, colder open the app had not rendered within 3s,
  # so _tt_login_form_variant found no form, login_probe returned STUCK WITHOUT EVER
  # SUBMITTING, and the report read "sign-in never settled" for an account that signs in
  # perfectly. Nothing in the output distinguished that from a bad password.
  for i in $(seq 1 20); do
    [ -n "$(ev "() => document.title")" ] && { sleep 1; return 0; }
    sleep 2
  done
  pv "  note: the app did not render anything within 40s of opening the browser"
  return 0
}

CREATED=0; SKIPPED=0; STAGED=0; RESET=0; VERIFIED=0; FAILED=0
PROBLEMS=""
fail_soft() { PROBLEMS="$PROBLEMS\n    $*"; FAILED=$((FAILED + 1)); pv "FAIL  $*"; }

# selected <username> — is this account in scope?
#
# MANUAL_ONLY takes one name or several, separated by spaces, commas or pipes, so a run
# can pick up exactly the accounts a previous run did not finish.
selected() {
  local n
  [ -n "$ONLY" ] || return 0
  for n in $(printf '%s' "$ONLY" | tr ',|' '  '); do
    [ "$n" = "$1" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------- admin navigation

admin_login() {
  # Anonymous browser first. A phase that follows `reset` starts with a CONSULTANT session
  # live, and escaping that is the flaky path — see browser_reset.
  browser_reset
  tt_login "$ADMIN_U" "Accounts Overview" "$ADMIN_P"
  local who
  who="$(ev "() => { try { return mx.session.userObject.jsonData.attributes.Name.value; } catch(e) { return ''; } }")"
  [ "$who" = "$ADMIN_U" ] \
    || tt_fail "expected to be signed in as '$ADMIN_U' but the session belongs to '${who:-unknown}' — refusing to touch accounts from someone else's session"
}

# admin_card <text> — go to the Admin Hub and open a card by its caption.
#
# POLLS for the card rather than sleeping a fixed amount and hoping. A fixed 4s was
# enough locally and not on Mendix Cloud, where it reported "could not find the
# 'Accounts Overview' card" for a hub that had simply not finished rendering.
# It DELEGATES THE CLICK TO tt_click_card in lib/_login.sh rather than hand-rolling the
# lookup, and that is not a style preference — it is the third fix to this one function.
# The hand-rolled version required the caption element to be a LEAF
# (childElementCount === 0) and took the FIRST match in the document; tt_click_card allows
# `childElementCount < 3` and takes the LAST match, and its own comment explains why:
#
#   "an Admin Hub card puts its caption in a child text widget while the click handler and
#    the pointer live on the container above it"
#
# The first-match rule is what made this fail intermittently — a hidden or leftover copy of
# the caption earlier in the document wins, and the real card is never clicked. Two runs
# died here with "could not find the 'Accounts Overview' card after 30s" on a hub that was
# healthy.
#
# Before each attempt the page is cleared (a restored popup or an OK-only error dialog sits
# OVER the hub and swallows the click) and the admin session is re-established if it is no
# longer on the hub at all — a lost session presents identically to a missing card.
admin_card() {
  local i
  for i in 1 2 3; do
    playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
    sleep 4

    close_open_forms || pv "  note: a popup would not close over the Admin Hub"
    # close_open_forms will not press OK, because pressing an affirmative button on a
    # popup it did not open could write data. tt_clear_dialogs is the instrument for an
    # OK-only informational dialog, and on the hub there is nothing it could confirm.
    tt_clear_dialogs 4 >/dev/null 2>&1 || true

    if [ "$(ev "() => String(/Welcome to your homepage|Accounts Overview/.test(document.body ? document.body.innerText : ''))")" != "true" ]; then
      pv "  (not on the Admin Hub — re-establishing the admin session)"
      browser_reset
      tt_login "$ADMIN_U" "Accounts Overview" "$ADMIN_P"
      sleep 2
    fi

    if ( tt_click_card "$1" ) >/dev/null 2>&1; then
      sleep 5
      return 0
    fi
    pv "  (attempt $i: the '$1' card did not take a click; retrying)"
  done
  tt_fail "could not open the '$1' card on the Admin Hub after 3 attempts — a dialog may be covering it, or the hub layout has changed"
}

# accounts_open — land on Account Overview with its grid rendered, from a FRESH page.
#
# It always re-navigates rather than short-circuiting when the filter happens to be on
# screen. That is what keeps the DOM free of stale copies of the popup forms: opening one
# repeatedly leaves earlier copies behind (two complete sets of Account_New fields were
# observed, ids …_pbs_38 and …_pbs_574, with only the second live), and a fill or a click
# that lands on a dead copy looks exactly like a form that has changed shape.
#
# A Mendix `reload` is NOT a substitute: reloading the client returns to the app's HOME
# page, not to the page that was open, so reload-then-check looks for the accounts filter
# on the Admin Hub and never finds it.
accounts_open() {
  local i j
  for i in 1 2 3; do
    admin_card "Accounts Overview"
    # The card raised a runtime error once, on a session that had gone anonymous under
    # us. Clearing the dialog and trying again fixed it, so that is what happens here
    # rather than reporting a missing page.
    tt_clear_dialogs 4 >/dev/null 2>&1 || true
    for j in $(seq 1 12); do
      [ "$(ev "() => String(!!document.querySelector('.mx-name-textFilter2'))")" = "true" ] && break
      sleep 2
    done
    if [ "$(ev "() => String(!!document.querySelector('.mx-name-textFilter2'))")" = "true" ]; then
      close_open_forms || pv "  note: a popup form is still open over Account Overview"
      return 0
    fi
    pv "  (attempt $i: Account Overview did not render its Login filter; retrying)"
  done
  tt_fail "Account Overview never rendered its Login filter after 3 attempts — the page may be erroring (look for 'An error occurred' on screen)"
}

# close_open_forms — dismiss any account popup left standing, and PROVE it is gone.
#
# WHY THIS IS NOT PARANOIA. Navigating to the app root does NOT guarantee a clean page:
# the Mendix client restores the popup that was open when it last unloaded. So a create
# that ended with its form still up comes back with that form restored, "New local user"
# then opens a SECOND copy, and from there everything downstream misfires in ways that
# read as unrelated bugs. On the first six-account run that produced exactly two:
#
#   manual_consultant3  "combobox .mx-name-cbEmploymentStatus would not open"
#   manual_pm           fill('.mx-name-textBox6 input') matched MULTIPLE elements
#
# ONLY DISMISS CONTROLS ARE PRESSED (cancel / close / ×), never an affirmative one. This
# runs before opening a form, not to advance a confirmation, and clicking Save or Change
# on a popup it did not open would write data. tt_clear_dialogs is the helper for
# advancing a chain and is deliberately not reused here — same reasoning as
# fx_close_modals in lib/_fixtures.sh.
#
# It delegates the "is a dialog open?" question to TT_DIALOG_SEL / _tt_dialog_js in
# lib/_login.sh rather than carrying its own selector list. That machinery was established
# by reading the live DOM and it matters: a loose modal match also hits the
# header/body/footer CHILDREN, so "the last match" can select a modal-footer whose only
# button is OK. This is the same shape as fx_close_modals in lib/_fixtures.sh, for the
# same reasons written up there.
#
# Returns 1 when a dialog offers no dismiss control at all, so the caller can say so
# instead of silently proceeding into a page that will swallow every click.
close_open_forms() {
  local i present d
  d="$(_tt_dialog_js)"
  for i in $(seq 1 12); do
    present="$(ev "() => String($d ? 1 : 0)")"
    case "$present" in
      0)           return 0 ;;
      ''|*[!0-9]*) return 0 ;;   # unreadable: let the caller report the real problem
    esac
    ev "() => { const d=$d; if(!d) return 'none'; const btns=[...d.querySelectorAll('button')].filter(b=>b.offsetParent!==null); const b=btns.find(x=>/^(cancel|close|dismiss|x|×)\$/i.test((x.innerText||'').trim())) || d.querySelector('.close, button.close, .mx-window-close, .mx-dialog-close, [aria-label=Close]'); if(b){ b.click(); return 'closed'; } return 'stuck'; }" >/dev/null
    # Escape closes a Mendix popup outright, which is exactly what is wanted HERE (unlike
    # inside a form being filled, where it would discard the work).
    [ $((i % 3)) -eq 0 ] && playwright-cli press "Escape" >/dev/null 2>&1
    sleep 1
  done
  return 1
}

# fill_field <wrapper-class> <value> — fill the LIVE copy of a form field.
#
# `playwright-cli fill` is strict: a selector matching several elements is refused
# outright, and tt_fail then aborts the whole run — which is how manual_pm died on the
# first six-account run, with "matched MULTIPLE elements". close_open_forms above should
# make duplicates impossible; this makes them harmless as well, by addressing the LAST
# match in DOM order, which is the most recently opened and therefore the live one.
# ev_num <js> — an eval whose answer must be a number, retried if it comes back blank.
#
# A blank answer is not an answer. `playwright-cli eval` occasionally returns nothing at
# all, and treating that as fatal is how attempt 4 of the six-account run aborted every
# remaining account over one hiccup: "could not count '.mx-name-textBox1 input' on the
# form (got [])". Retry the question before concluding anything from it.
ev_num() {
  local i r=""
  for i in 1 2 3 4; do
    r="$(ev "$1")"
    case "$r" in
      ''|*[!0-9]*) sleep 2 ;;
      *) printf '%s' "$r"; return 0 ;;
    esac
  done
  printf '%s' "$r"
  return 1
}

fill_field() {
  local wrap="$1" val="$2" n
  if ! n="$(ev_num "() => String(document.querySelectorAll('.$wrap input').length)")"; then
    pv "  could not count '.$wrap input' after 4 tries (got [$n]) — the browser stopped answering"
    return 1
  fi
  case "$n" in
    0) pv "  '.$wrap input' is not on the form at all"; return 1 ;;
    1) tt_fill ".$wrap input" "$val"; return 0 ;;
    *) pv "  note: $n copies of .$wrap on screen — filling the last"
       tt_fill ":nth-match(.$wrap input, $n)" "$val"; return 0 ;;
  esac
}

accounts_filter() {
  playwright-cli fill ".mx-name-textFilter2 input" "$1" >/dev/null 2>&1
  sleep 4
}

# account_login_row <username> — the grid row for that EXACT login, or ''.
#
# Exact equality on the Login cell, not a substring of the row: 'manual_consultant' is a
# prefix of 'manual_consultant2', so a contains-match would report the wrong account as
# already present and silently skip creating one.
account_login_row() {
  accounts_filter "$1"
  ev "() => { const g=[...document.querySelectorAll('[role=grid],[role=treegrid]')].filter(e=>e.offsetParent!==null)[0]; if(!g) return ''; for (const r of [...g.querySelectorAll('[role=row]')]) { const c=[...r.querySelectorAll('[role=gridcell],td')]; if (c.length<2) continue; if ((c[1].innerText||'').trim()==='$1') return c.map(function(x){ return (x.innerText||'').replace(/\\s+/g,' ').trim(); }).join(' | '); } return ''; }"
}

# account_state <username> — "Blocked=<b> Active=<a>" read through the data API, or ERR:.
#
# Worth its own round trip because a blocked account is INDISTINGUISHABLE from a wrong
# password at the login form, and that is the single most confusing failure this whole
# surface produces.
account_state() {
  ev "() => new Promise(function(res){ try { mx.data.get({ xpath: \"//Administration.Account[Name='$1']\", filter:{amount:1}, callback:function(o){ if(!o.length) return res('ABSENT'); res('Blocked='+o[0].get('Blocked')+' Active='+o[0].get('Active')); }, error:function(e){ res('ERR:'+((e&&e.message)||'retrieve-refused')); } }); } catch(e) { res('ERR:'+e.message); } })"
}

# ---------------------------------------------------------------- form primitives

# form_field <label-regex> — the .mx-name-* wrapper of the visible input whose form-group
# label matches. Resolved at runtime because both account forms carry auto-named boxes,
# and they do not agree with each other.
#
# Takes the LAST match, not the first, for the stale-copy reason given above accounts_open.
form_field() {
  ev "() => { const ins=[...document.querySelectorAll('input')].filter(i=>i.offsetParent!==null); let found=''; for (const i of ins) { const grp=i.closest('.form-group'); const lbl=grp?((grp.querySelector('label')||{}).innerText||'').trim():''; if(!/$1/i.test(lbl)) continue; let w=i; for(let k=0;k<6&&w;k++){ const m=(w.className||'').toString().match(/mx-name-[A-Za-z0-9_]+/); if(m){ found=m[0]; break; } w=w.parentElement; } } return found || 'NONE'; }"
}

# The Mendix combobox widget, driven through its OWN menu rather than the document.
#
# TWO THINGS MADE THE OBVIOUS VERSION WRONG, both measured on dev 2026-09-09.
#
# 1. It must be opened on .widget-combobox-input-container. Clicking the <input> itself
#    leaves aria-expanded="false" and renders zero options — so a helper that clicks the
#    input and then polls for [role=option] waits forever on a combobox nobody opened.
#
# 2. "User role(s)" is MULTI-SELECT, so picking an option leaves the menu OPEN for
#    another. A helper that treats "are any [role=option] on the page?" as "is my
#    combobox open?" therefore reads the PREVIOUS combobox's list: the first run of this
#    script picked the role, then went looking for 'FullTime' among
#    Administrator/Anonymous/Consultant/HR/ProjectManager/TitanManager and reported the
#    employment status as unselectable.
#
# So each combobox is addressed through the menu its own input names in aria-controls,
# and every pick is followed by an explicit close and a check that the caption changed.
_combo_js() {
  printf "%s" "[...document.querySelectorAll('.$1')].filter(e=>e.offsetParent!==null).pop()"
}

_combo_expanded() {
  ev "() => { const c=$(_combo_js "$1"); if(!c) return 'NONE'; const i=c.querySelector('input'); return i ? String(i.getAttribute('aria-expanded')==='true') : 'NONE'; }"
}

# _combo_set <wrapper-class> <true|false> — toggle until it agrees.
#
# The toggle is clicked in JS rather than through `playwright-cli click`, because a CSS
# selector cannot say "the visible one" and a stale copy would swallow every click.
_combo_set() {
  local wrap="$1" want="$2" i now
  for i in 1 2 3 4 5 6; do
    now="$(_combo_expanded "$wrap")"
    [ "$now" = "NONE" ] && return 1
    [ "$now" = "$want" ] && return 0
    ev "() => { const c=$(_combo_js "$wrap"); if(!c) return 'NONE'; const t=c.querySelector('.widget-combobox-input-container'); if(!t) return 'NOTOGGLE'; t.click(); return 'clicked'; }" >/dev/null
    sleep 1
  done
  [ "$(_combo_expanded "$wrap")" = "$want" ]
}

combo_value() {
  ev "() => { const c=$(_combo_js "$1"); if(!c) return 'NONE'; const cap=c.querySelector('.widget-combobox-caption-text, .widget-combobox-selected-items'); return cap ? (cap.innerText||'').replace(/\\s+/g,' ').trim() : ''; }"
}

combo_pick() {
  local wrap="$1" want="$2" i r shown
  for i in 1 2 3 4 5; do
    _combo_set "$wrap" true || { pv "  combobox .$wrap would not open"; return 1; }
    r="$(ev "() => { const c=$(_combo_js "$wrap"); if(!c) return 'NOWRAP'; const inp=c.querySelector('input'); const id=inp?inp.getAttribute('aria-controls'):''; const menu=id?document.getElementById(id):null; if(!menu) return 'NOMENU'; const opts=[...menu.querySelectorAll('[role=option]')]; const o=opts.find(e=>(e.innerText||'').trim()==='$want'); if(o){ o.click(); return 'PICKED'; } return 'NOMATCH:'+opts.map(function(e){ return (e.innerText||'').trim(); }).join(','); }")"
    case "$r" in PICKED) break ;; esac
    sleep 1
  done
  case "$r" in
    PICKED) : ;;
    *) pv "  combobox .$wrap has no option '$want' (last: $r)"; return 1 ;;
  esac

  sleep 1
  _combo_set "$wrap" false || pv "  note: combobox .$wrap did not close after picking '$want'"

  # Prove the selection took. A click that landed on a menu item the widget then ignored
  # is indistinguishable from success until the save fails validation.
  shown="$(combo_value "$wrap")"
  case "$shown" in
    *"$want"*) return 0 ;;
    *) pv "  combobox .$wrap shows '$shown' after picking '$want' — the selection did not take"; return 1 ;;
  esac
}

# validation_messages — whatever the widgets are currently complaining about.
validation_messages() {
  ev "() => [...document.querySelectorAll('.mx-validation-message')].filter(e=>e.offsetParent!==null).map(function(e){ return (e.innerText||'').trim(); }).filter(Boolean).join(' ~ ')"
}

# click_caption <regex> — click the LAST visible button whose text matches.
#
# Last, not first: these forms stack popups (the password dialog opens over the edit
# form), and both layers have a Cancel. The innermost is the one the user is looking at,
# and it is last in DOM order.
click_caption() {
  ev "() => { const bs=[...document.querySelectorAll('button, a[role=button]')].filter(e=>e.offsetParent!==null); const m=bs.filter(e=>new RegExp('^($1)\$','i').test((e.innerText||'').trim())); if(!m.length) return 'NOBUTTON:'+bs.map(function(e){ return (e.innerText||'').trim(); }).filter(Boolean).join(','); m[m.length-1].click(); return 'ok'; }"
}

# ---------------------------------------------------------------- create

create_account() {
  local user="$1" full="$2" role="$3" empl="$4" email="$5"
  local i ok="" f_full f_user f_email f_role flags bad row

  pv "creating $user  ($full, $role, $empl, $email)"

  # Fresh page first — see accounts_open on why stale form copies matter.
  accounts_open

  click_caption "new local user" >/dev/null

  for i in $(seq 1 10); do
    [ "$(ev "() => String(!!document.querySelector('.mx-name-cbEmploymentStatus'))")" = "true" ] && { ok=1; break; }
    sleep 1
  done
  [ -n "$ok" ] || { fail_soft "$user: the New Account popup never opened"; return 1; }

  f_full="$(form_field '^full name$')"
  f_user="$(form_field '^user ?name$')"
  f_email="$(form_field '^email$')"
  f_role="$(form_field 'user role')"
  case "$f_full$f_user$f_email$f_role" in
    *NONE*) fail_soft "$user: New Account is missing a field (full=$f_full user=$f_user email=$f_email role=$f_role) — the form has changed"
            click_caption "cancel" >/dev/null; sleep 2; return 1 ;;
  esac

  if ! { fill_field "$f_full" "$full" && fill_field "$f_user" "$user" && fill_field "$f_email" "$email"; }; then
    fail_soft "$user: could not fill the New Account form (reason above)"
    click_caption "cancel" >/dev/null; sleep 2; return 1
  fi

  combo_pick "$f_role" "$role" \
    || { fail_soft "$user: could not select role '$role'"; click_caption "cancel" >/dev/null; sleep 2; return 1; }
  combo_pick "mx-name-cbEmploymentStatus" "$empl" \
    || { fail_soft "$user: could not select employment status '$empl'"; click_caption "cancel" >/dev/null; sleep 2; return 1; }

  # Blocked must be off and Active on. Both are checkboxes with defaults, so this ASSERTS
  # rather than clicks: a form whose defaults have changed should say so, not be quietly
  # corrected into a state nobody declared.
  flags="$(ev "() => { const g=[...document.querySelectorAll('.form-group')].filter(e=>e.offsetParent!==null); let b='?',a='?'; for(const x of g){ const l=((x.querySelector('label')||{}).innerText||'').trim().toLowerCase(); const c=x.querySelector('input[type=checkbox]'); if(!c) continue; if(l==='blocked') b=String(c.checked); if(l==='active') a=String(c.checked); } return 'blocked='+b+' active='+a; }")"
  case "$flags" in
    "blocked=false active=true") : ;;
    *) fail_soft "$user: New Account defaults are not what this script expects ($flags; wanted blocked=false active=true) — check the form before creating accounts with it"
       click_caption "cancel" >/dev/null; sleep 2; return 1 ;;
  esac

  bad="$(validation_messages)"
  [ -z "$bad" ] || { fail_soft "$user: the form rejected the input before save: $bad"
                     click_caption "cancel" >/dev/null; sleep 2; return 1; }

  if [ "$DRY" = "1" ]; then
    pv "  DRY RUN — cancelling instead of saving"
    click_caption "cancel" >/dev/null
    sleep 2
    return 0
  fi

  click_caption "save" >/dev/null
  sleep 4
  tt_clear_dialogs 4 >/dev/null 2>&1 || true
  sleep 2

  row="$(account_login_row "$user")"
  if [ -z "$row" ]; then
    fail_soft "$user: saved, but no row with that Login is in the grid afterwards — the save was rejected"
    return 1
  fi
  pv "  created: $row"
  CREATED=$((CREATED + 1))
  return 0
}

phase_create() {
  pv "=== phase: create ==="
  admin_login

  local row user full role empl email have
  for row in "${MANUAL_ACCOUNTS[@]}"; do
    IFS='|' read -r user full role empl _ready <<< "$row"
    selected "$user" || continue
    email="$(manual_account_email "$user")"

    accounts_open
    have="$(account_login_row "$user")"
    if [ -n "$have" ]; then
      SKIPPED=$((SKIPPED + 1))
      pv "ok    $user already exists: $have"
      continue
    fi
    create_account "$user" "$full" "$role" "$empl" "$email"
  done
}

# ---------------------------------------------------------------- stage

# open_edit_account <username> — open Administration.Account_Edit for that row.
open_edit_account() {
  local user="$1" i r
  accounts_open
  accounts_filter "$user"
  r="$(ev "() => { const g=[...document.querySelectorAll('[role=grid],[role=treegrid]')].filter(e=>e.offsetParent!==null)[0]; if(!g) return 'NOGRID'; for (const r of [...g.querySelectorAll('[role=row]')]) { const c=[...r.querySelectorAll('[role=gridcell],td')]; if (c.length<2) continue; if ((c[1].innerText||'').trim()!=='$user') continue; const a=r.querySelector('a[aria-label=\"Edit Account\"]'); if(!a) return 'NOEDIT'; a.click(); return 'ok'; } return 'NOROW'; }")"
  [ "$r" = "ok" ] || { pv "  could not open Edit Account for '$user' ($r)"; return 1; }
  # 30s, not 10s. manual_tm's stage failed at 10s on a form that was merely slow — every
  # other wait in this script polls at 2s for 15 tries, and this one had no reason to be
  # the exception.
  for i in $(seq 1 15); do
    [ "$(ev "() => String(!!document.querySelector('.mx-name-saveButton1'))")" = "true" ] && return 0
    sleep 2
  done
  pv "  the Edit Account form for '$user' never rendered"
  return 1
}

# stage_account <username> — unblock if needed, then set the staging password.
#
# Unblocking is a SEPARATE save, deliberately. The password dialog's Change action closes
# both popups and commits, so a Blocked change made just before it appears to persist —
# but relying on one microflow to commit another form's edit is exactly the kind of
# coupling that breaks silently. Save the unblock, reopen, then change the password.
# stage_account <username> [password]
#
# The password defaults to the STAGING value. It is a parameter because an account whose
# force-reset flag is ALREADY cleared needs the target password set here directly — there
# is no reset left to carry it from staging to target. See the READY branch of phase_reset.
stage_account() {
  local user="$1" want="${2:-$STAGE_PASS}" state blocked f_new f_conf bad

  state="$(account_state "$user")"
  case "$state" in
    ABSENT) fail_soft "$user: no such account — run the create phase"; return 1 ;;
    ERR:*)  pv "  note: could not read $user's state ($state); continuing" ;;
  esac
  case "$state" in
    *"Blocked=true"*) blocked=1 ;;
    *)                blocked="" ;;
  esac

  if [ -n "$blocked" ]; then
    pv "  $user is BLOCKED (failed-login lockout) — clearing the flag first"
    open_edit_account "$user" || { fail_soft "$user: is blocked and the Edit Account form could not be opened to unblock it"; return 1; }
    ev "() => { const g=[...document.querySelectorAll('.form-group')].filter(e=>e.offsetParent!==null); for (const x of g) { const l=((x.querySelector('label')||{}).innerText||'').trim().toLowerCase(); const c=x.querySelector('input[type=checkbox]'); if (c && l==='blocked') { if (c.checked) c.click(); return String(c.checked); } } return 'NOBOX'; }" >/dev/null
    sleep 1
    click_caption "save" >/dev/null
    sleep 5
    tt_clear_dialogs 4 >/dev/null 2>&1 || true
    state="$(account_state "$user")"
    case "$state" in
      *"Blocked=true"*) fail_soft "$user: the Blocked flag is still set after saving the Edit Account form"; return 1 ;;
    esac
    pv "  unblocked ($state)"
  fi

  if [ "$DRY" = "1" ]; then
    pv "  DRY RUN — not setting a password for $user"
    return 0
  fi

  open_edit_account "$user" || { fail_soft "$user: could not open Edit Account to set a password"; return 1; }

  # "Change password" opens a nested dialog over the edit form: New password / Confirm
  # password / Change. It needs no old password, which is the whole reason this script
  # does not have to read the welcome mail.
  click_caption "change password" >/dev/null
  local i ok=""
  for i in $(seq 1 10); do
    [ "$(ev "() => String([...document.querySelectorAll('input[type=password]')].filter(e=>e.offsetParent!==null).length >= 2)")" = "true" ] && { ok=1; break; }
    sleep 1
  done
  [ -n "$ok" ] || { fail_soft "$user: the Change Password dialog never opened"; click_caption "cancel" >/dev/null; return 1; }

  f_new="$(form_field '^new password$')"
  f_conf="$(form_field 'confirm')"
  case "$f_new$f_conf" in
    *NONE*) fail_soft "$user: the Change Password dialog is missing a box (new=$f_new confirm=$f_conf)"
            click_caption "cancel" >/dev/null; return 1 ;;
  esac

  if ! { fill_field "$f_new" "$want" && fill_field "$f_conf" "$want"; }; then
    fail_soft "$user: could not fill the Change Password dialog (reason above)"
    click_caption "cancel" >/dev/null; return 1
  fi
  sleep 1

  bad="$(validation_messages)"
  [ -z "$bad" ] || { fail_soft "$user: the Change Password dialog rejected the password: $bad"
                     click_caption "cancel" >/dev/null; return 1; }

  click_caption "change" >/dev/null
  sleep 6
  tt_clear_dialogs 4 >/dev/null 2>&1 || true

  bad="$(validation_messages)"
  [ -z "$bad" ] || { fail_soft "$user: the password change was refused: $bad"; return 1; }

  STAGED=$((STAGED + 1))
  pv "ok    $user staged"
  return 0
}

phase_stage() {
  pv "=== phase: stage ==="
  admin_login
  local row user
  for row in "${MANUAL_ACCOUNTS[@]}"; do
    IFS='|' read -r user _full _role _empl _ready <<< "$row"
    selected "$user" || continue
    stage_account "$user"
  done
}

# ---------------------------------------------------------------- reset

# login_probe <user> <pass> <ready> — sign in and REPORT the outcome instead of failing.
#
# Echoes READY | RESET | BADCREDS | STUCK.
#
# WHY NOT tt_login. tt_login treats a forced reset as fatal — it cannot complete one
# without changing the password out from under its caller — and that is the state every
# freshly staged account is in. So this drives the same form and reads the outcome.
#
# IT REUSES _tt_login_form_variant AND _tt_login_submit FROM lib/_login.sh rather than
# re-implementing them. Those two already distinguish all four outcomes, know about both
# form variants (/login.html and the app's own Core.Login page), and know that the
# rejection wording differs between them ("is incorrect" vs an "Invalid Credentials"
# popup). Only the preamble — getting to a CLEAN form — is written out here.
#
# THE FIRST VERSION REPORTED A FALSE BADCREDS, and the mechanism is worth keeping written
# down. It did `playwright-cli close` then `open` (copying lib/_seed.sh) and then looked
# for rejection text in document.body. Inside a script that reopen does not reliably
# survive, so the browser stayed on the PREVIOUS attempt's page — which was showing
# "Invalid Credentials" from an earlier, expected failure. The probe read that stale popup
# and reported a password as rejected that had never been typed.
#
# EVERY CALL COSTS A FAILED-LOGIN ATTEMPT WHEN IT IS WRONG, and Mendix blocks an account
# after a few. So callers must not use this to hunt for a password: phase_reset tries the
# staging password (which it has just set) and at most one alternative.
login_probe() {
  local user="$1" pass="$2" ready="$3" variant rc i

  # A FULL BROWSER RESET, not cookie-clear plus mx.logout().
  #
  # An account left mid-reset is SIGNED IN and parked on Core.Force_PasswordReset, and
  # mx.logout() does not reliably get out of there — so the next account's sign-in found
  # no login form and reported STUCK after two minutes. That is what happened to
  # manual_consultant3 immediately after manual_consultant2's reset failed: nothing was
  # wrong with manual_consultant3 at all.
  #
  # lib/_seed.sh reached the same conclusion for switching identity mid-run: a full
  # close/open is the only switch that has proven reliable against this app. A fresh
  # context has no session to be stuck in.
  browser_reset

  # Require a form with NO leftover rejection text before typing. Without this the
  # outcome poll can match the previous attempt's message.
  for i in $(seq 1 12); do
    if [ "$(ev "() => { const t=document.body?document.body.innerText:''; const clean=!/is incorrect|invalid credentials|you must reset your password/i.test(t); const form=document.querySelectorAll('input.form-control[type=password]').length===1 || !!document.querySelector('#passwordInput'); return String(clean && form); }")" = "true" ]; then
      break
    fi
    playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
    sleep 3
  done

  variant="$(_tt_login_form_variant 10)"
  if [ -z "$variant" ]; then
    playwright-cli goto "$TT_BASE/login.html" >/dev/null 2>&1
    sleep 2
    variant="$(_tt_login_form_variant 10)"
  fi
  # An empty variant means NO SIGN-IN FORM WAS FOUND — nothing was ever submitted, so
  # this is not a statement about the password. Say so, because "STUCK" on its own reads
  # exactly like a credential problem and sent four runs chasing one.
  if [ -z "$variant" ]; then
    pv "  no sign-in form at $TT_BASE/ or /login.html — nothing was submitted for '$user'"
    pv "    page reads: $(ev "() => (document.body ? document.body.innerText : '(no body)').replace(/\\s+/g,' ').slice(0,140)")"
    echo "STUCK"
    return 0
  fi

  _tt_login_submit "$variant" "$user" "$pass" "$ready"
  rc=$?
  case "$rc" in
    0) echo "READY" ;;
    1) echo "BADCREDS" ;;
    2) echo "RESET" ;;
    *)
      # rc=3 IS NOT NECESSARILY A FAILURE — CHECK BEFORE BELIEVING IT.
      #
      # _tt_login_submit's success test is
      #     location.pathname.indexOf('index.html') >= 0 && body contains <ready>
      # and the pathname half is wrong for the app's OWN Core.Login page: signing in
      # there leaves the browser on "/", never "/index.html". So a perfectly good
      # sign-in reports rc=3 after burning the full 120s budget.
      #
      # That is not hypothetical. manual_consultant failed three runs with "sign-in with
      # the staging password never settled (STUCK)" while a frame-by-frame watch showed
      # it signed in at t+6s, identity confirmed, sitting on My Timesheets — at path "/".
      # The suite does not usually hit this because tt_login tries /login.html first,
      # which does redirect to /index.html; this script reaches Core.Login directly.
      #
      # So: ask the two questions that actually matter — who is signed in, and is the
      # landing text there — and ignore the URL entirely.
      if [ "$(ev "() => { let n=''; try { n=mx.session.userObject.jsonData.attributes.Name.value; } catch(e){} return String(n==='$user' && (document.body?document.body.innerText:'').indexOf('$ready')>=0); }")" = "true" ]; then
        echo "READY"
      else
        echo "STUCK"
      fi ;;
  esac
}

# login_ok <user> <ready> — can this account sign in with the TARGET password?
#
# Uses tt_login (in a subshell, because it exits on failure) rather than login_probe: it
# retries and knows both form variants. Use it for "is this account usable", and
# login_probe only where the DISTINCTION between rejected and reset-demanded matters.
#
# TT_AUTH_CACHE=0 IS LOAD-BEARING. tt_login normally reuses a saved storage state, and
# _tt_auth_try accepts it on identity plus landing text WITHOUT re-authenticating — so a
# still-valid cookie from the provisioning run would satisfy this check no matter what the
# password is. That would make the one assertion this script rests on unable to fail.
# login_ok <user> <ready> — does this account sign in with the TARGET password?
#
# DELEGATES TO login_probe RATHER THAN tt_login, and that is the point: tt_login carries
# the same pathname assumption as _tt_login_submit, so it reports
#     "signed in via Core.Login but never reached a dashboard showing 'My Timesheets'"
# for a session that IS signed in and IS showing My Timesheets — just at "/" rather than
# "/index.html". That produced a red verify for manual_consultant one minute after the
# same helper had reported the very same account fine, because the two calls happened to
# take different form routes.
#
# login_probe judges on identity plus landing text and ignores the URL, so it gives the
# same answer every time. It also does its own browser_reset, which matters here: a reset
# leaves the account signed in, and this must test the PASSWORD, not that session.
login_ok() {
  [ "$(login_probe "$1" "$TARGET_PASS" "$2")" = "READY" ]
}

# reset_password <oldpass> <newpass> — complete the forced-reset form on screen.
#
# THE FORM HAS THREE BOXES, NOT TWO: Old password / New password / Confirm password, and
# a Submit that raises an "Are you sure?" confirmation. An earlier version filled every
# visible password input with the NEW password, which puts the new password in the Old
# box; the change is then refused, the account keeps the password it had, and the only
# symptom is that the new password does not sign in. Hence: every box is matched by its
# LABEL and nothing is filled positionally.
#
# Any box this does not recognise is a hard stop rather than a guess — filling an unknown
# password field with either credential is exactly how the above went unnoticed.
reset_password() {
  local old="$1" new="$2" boxes mapped wrap role val bad r i n

  # WAIT FOR THE BOXES TO EXIST BEFORE READING THEM.
  #
  # _tt_login_submit returns "a reset is demanded" the moment the sentence "you must reset
  # your password" appears in the body — which is BEFORE the form's inputs have rendered.
  # Reading immediately therefore sees nothing, and manual_consultant2's reset failed with
  # "the reset form has no visible password box at all" on a page that grew all three a
  # moment later.
  for i in $(seq 1 15); do
    n="$(ev "() => String([...document.querySelectorAll('input[type=password]')].filter(e=>e.offsetParent!==null).length)")"
    case "$n" in 2|3) break ;; esac
    sleep 2
  done

  boxes="$(ev "() => { const ps=[...document.querySelectorAll('input[type=password]')].filter(e=>e.offsetParent!==null); return ps.map(function(p){ const grp=p.closest('.form-group'); const lbl=grp?((grp.querySelector('label')||{}).innerText||'').trim():''; let w=p,n=''; for(let k=0;k<6&&w;k++){ const m=(w.className||'').toString().match(/mx-name-[A-Za-z0-9_]+/); if(m){n=m[0];break;} w=w.parentElement; } return n+'::'+lbl; }).join(' ~ '); }")"
  pv "  reset form: ${boxes:-(no password boxes)}"
  if [ -z "$boxes" ]; then
    # SAY WHAT WAS ACTUALLY ON SCREEN. "No password boxes" has three completely different
    # causes — a page that never rendered them, a page that is not the reset page at all,
    # and a browser that has stopped answering (every eval returns empty, which looks
    # identical to an empty page). Guessing between them cost several runs; these three
    # lines answer it in one.
    pv "  the reset form never rendered a password box (waited 30s). Diagnostics:"
    pv "    signed in as: $(ev "() => { try { return mx.session.userObject.jsonData.attributes.Name.value; } catch(e) { return '(anonymous)'; } }")"
    pv "    password inputs incl. hidden: $(ev "() => String(document.querySelectorAll('input[type=password]').length)")"
    pv "    page reads: $(ev "() => (document.body ? document.body.innerText : '(no body)').replace(/\\s+/g,' ').slice(0,200)")"
    pv "    (all three blank means the browser stopped answering — check nothing else is"
    pv "     driving the same playwright-cli session; only one run may use it at a time)"
    return 1
  fi

  mapped="$(ev "() => { const ps=[...document.querySelectorAll('input[type=password]')].filter(e=>e.offsetParent!==null); return ps.map(function(p){ const grp=p.closest('.form-group'); const lbl=(grp?((grp.querySelector('label')||{}).innerText||''):'').trim().toLowerCase(); let w=p,n=''; for(let k=0;k<6&&w;k++){ const m=(w.className||'').toString().match(/mx-name-[A-Za-z0-9_]+/); if(m){n=m[0];break;} w=w.parentElement; } let role='UNKNOWN'; if(/old|current|existing|temporary/.test(lbl)) role='old'; else if(/confirm|repeat|again|retype/.test(lbl)) role='confirm'; else if(/new/.test(lbl)) role='new'; return n+'|'+role; }).join('\\n'); }")"

  case "$mapped" in
    *UNKNOWN*) pv "  a password box on the reset form could not be identified from its label ($mapped) — refusing to guess which credential belongs in it"
               return 1 ;;
  esac
  case "$mapped" in
    *"|new"*) : ;;
    *) pv "  the reset form has no 'New password' box ($mapped)"; return 1 ;;
  esac

  local filled=1
  while IFS='|' read -r wrap role; do
    [ -n "$wrap" ] || continue
    case "$role" in
      old)     val="$old" ;;
      new|confirm) val="$new" ;;
      *)       continue ;;
    esac
    # tt_fill uses real keystrokes and verifies the value took: Mendix inputs commit on a
    # real focus change, and a DOM write can be accepted into .value and then ignored.
    fill_field "$wrap" "$val" || filled=""
    sleep 1
  done <<< "$mapped"
  # A partly filled reset form must never be submitted: an empty Old password box reads
  # as a wrong current password, which costs a failed-login attempt on an account that is
  # already one lockout away from being unusable.
  [ -n "$filled" ] || { pv "  a box on the reset form could not be filled — not submitting"; return 1; }

  # Do not submit a form the widget has already rejected. This is where "Your new
  # password must be different from your current password" shows up, which is the rule
  # the staging password exists to satisfy.
  bad="$(validation_messages)"
  [ -z "$bad" ] || { pv "  the reset form rejected the input before submit: $bad"; return 1; }

  r="$(click_caption "submit|save|change password|change|reset")"
  case "$r" in
    ok) : ;;
    *)  pv "  no submit button on the reset form ($r)"; return 1 ;;
  esac
  sleep 3

  # Submit raises "Are you sure? / Proceed". tt_clear_dialogs already accepts 'proceed'.
  tt_clear_dialogs 6 >/dev/null 2>&1 || pv "  note: a dialog after submit offered no way forward: ${TT_DIALOG_BLOCKED:-?}"
  sleep 5

  bad="$(validation_messages)"
  [ -z "$bad" ] || { pv "  the app refused the change: $bad"; return 1; }
  return 0
}

phase_reset() {
  pv "=== phase: reset ==="
  local row user full ready state

  for row in "${MANUAL_ACCOUNTS[@]}"; do
    IFS='|' read -r user full _role _empl ready <<< "$row"
    selected "$user" || continue

    # The staging password is what phase_stage has just set, so it is tried FIRST. Trying
    # the target first would spend a failed-login attempt on every fresh account, and a
    # few of those get the account blocked.
    state="$(login_probe "$user" "$STAGE_PASS" "$ready")"

    case "$state" in
      RESET)
        if reset_password "$STAGE_PASS" "$TARGET_PASS"; then
          # CONFIRMED WITH tt_login, NOT login_probe. Completing the reset leaves the
          # account SIGNED IN, so an immediate probe is racing the app's own post-reset
          # navigation: on the first real run that probe returned STUCK while tt_login,
          # moments later in the verify phase, signed in perfectly. tt_login retries,
          # knows both form variants and understands the cached-session case, so it is
          # the right instrument for "is this account usable now?".
          # TWO ATTEMPTS, because the first one races the app's own post-reset navigation.
          # manual_tm was reported as "the target password does not sign in (STUCK)" and
          # then signed in perfectly in the verify phase a minute later — the reset had
          # worked and only the check was early. A false failure here is worse than a slow
          # one: it sends someone to re-provision an account that is already correct.
          if login_ok "$user" "$ready" || { sleep 10; login_ok "$user" "$ready"; }; then
            RESET=$((RESET + 1)); pv "ok    $user — password set and the reset flag is cleared"
          else
            state="$(login_probe "$user" "$TARGET_PASS" "$ready")"
            case "$state" in
              RESET) fail_soft "$user: the reset was accepted but the app still demands one — the new password may not have been committed" ;;
              *)     fail_soft "$user: the reset form was submitted but the target password does not sign in ($state)" ;;
            esac
          fi
        else
          fail_soft "$user: could not complete the forced-reset form (reason above)"
        fi ;;
      READY)
        # Signed in on the staging password, and NO reset was demanded — this account has
        # been through a forced reset before, so its flag is already cleared and nothing
        # will ever carry it from staging to target. Staging was simply the wrong step for
        # it; set the target password directly, as the administrator, and move on.
        #
        # Leaving it staged is not an option: the run would end with a working account on
        # a throwaway password that only this script knows how to derive.
        pv "  $user was not asked to reset (its flag is already cleared) — setting the target password directly"
        admin_login
        if stage_account "$user" "$TARGET_PASS"; then
          if login_ok "$user" "$ready" || { sleep 10; login_ok "$user" "$ready"; }; then
            RESET=$((RESET + 1)); pv "ok    $user — target password set directly"
          else
            fail_soft "$user: the target password was set directly but does not sign in"
          fi
        else
          fail_soft "$user: could not set the target password directly (reason above)"
        fi ;;
      BADCREDS)
        # Perhaps already fully provisioned. ONE alternative attempt, then stop.
        state="$(login_probe "$user" "$TARGET_PASS" "$ready")"
        case "$state" in
          READY) SKIPPED=$((SKIPPED + 1)); pv "ok    $user already accepts the target password" ;;
          *)     fail_soft "$user: neither the staging nor the target password is accepted ($state). Account state: $(account_state "$user" 2>/dev/null || echo unknown). If it reads Blocked=true, the failed-login lockout has tripped — re-run the stage phase, which clears it." ;;
        esac ;;
      *)
        fail_soft "$user: sign-in with the staging password never settled ($state)" ;;
    esac
  done
}

phase_verify() {
  pv "=== phase: verify ==="
  local row user full ready state
  for row in "${MANUAL_ACCOUNTS[@]}"; do
    IFS='|' read -r user full _role _empl ready <<< "$row"
    selected "$user" || continue

    # login_probe, not tt_login — see login_ok for why the latter cannot be trusted to
    # answer this question consistently. It starts from an anonymous browser and uses no
    # cached storage state, so a PASS here means the password works, not that a cookie
    # from provisioning is still warm.
    state="$(login_probe "$user" "$TARGET_PASS" "$ready")"
    case "$state" in
      READY)    VERIFIED=$((VERIFIED + 1)); pv "ok    $user -> '$ready'" ;;
      RESET)    fail_soft "$user: signs in with the target password but the app still demands a password reset — the reset flag was never cleared" ;;
      BADCREDS) fail_soft "$user: the target password is rejected. Account state: $(account_state "$user" 2>/dev/null || echo unknown) — Blocked=true means the failed-login lockout tripped, and the stage phase clears it." ;;
      *)        fail_soft "$user: could not establish whether it signs in ($state) — see the diagnostics above; nothing may have been submitted at all" ;;
    esac
  done
}

# ---------------------------------------------------------------- main

pv "target: $TT_BASE"
pv "phases: $PHASES${ONLY:+   (only: $ONLY)}"
[ "$DRY" = "1" ] && pv "DRY RUN — nothing will be saved"

# START FROM A GENUINELY EMPTY BROWSER.
#
# The third six-account run died inside tt_login with "no login form at /login.html OR /
# — the app did not render a sign-in page at either location", which is the flakiness
# lib/_login.sh documents: cookie-clear does not reliably drop the runtime's httpOnly
# session, and the ROOT url of a still-signed-in session renders the app rather than
# Core.Login. The session it was carrying belonged to the previous run.
#
# A fresh browser context has no cookies at all, so that whole class of failure cannot
# happen at startup. lib/_seed.sh reached the same conclusion for switching identity
# mid-run: a full close/open is the only switch that has proven reliable here.
browser_reset

for p in $PHASES; do
  case "$p" in
    create) phase_create ;;
    stage)  phase_stage ;;
    reset)  phase_reset ;;
    verify) phase_verify ;;
    *)      tt_fail "unknown phase '$p' (expected any of: create stage reset verify)" ;;
  esac
done

echo "----------------------------------------------------------------"
pv "created: $CREATED   already present: $SKIPPED   staged: $STAGED   passwords set: $RESET   verified: $VERIFIED   problems: $FAILED"
if [ -n "$PROBLEMS" ]; then
  printf '[provision] PROBLEMS:%b\n' "$PROBLEMS" >&2
  exit 1
fi
pv "done."
