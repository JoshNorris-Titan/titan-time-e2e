#!/usr/bin/env bash
# Shared helpers for driving Administration.Account_Overview as an administrator:
# find an account, read its Blocked/Active state, and SET ITS PASSWORD without
# knowing the current one. Source it from a *.test.sh after lib/_login.sh:
#
#   source "$TT_ROOT/lib/_login.sh"
#   source "$TT_ROOT/lib/_accounts.sh"
#
# Provides:
#   acct_admin_login <user> <pass>          sign in and assert the session is really theirs
#   acct_overview_open                      land on Account Overview with its grid rendered
#   acct_row <login>                        the grid row for that EXACT login, or ''
#   acct_state <login>                      "Blocked=<b> Active=<a>" | ABSENT | ERR:<why>
#   acct_unblock <login>                    clear a failed-login lockout
#   acct_set_password <login> <newpass>     0 = set, 1 = mechanical failure, 2 = REFUSED
#   ACCT_LAST_ERROR                         why the last call returned non-zero
#
# WHY THIS IS A LIBRARY AND NOT PART OF A TEST
# --------------------------------------------
# Two callers need the same surface: manual-env/provision-accounts.sh (creating the
# manual_* logins) and password-refresh/ (keeping every test account's password from
# ageing into a forced reset). The surface is auto-named, stacks popups, and leaves stale
# copies of its forms in the DOM -- all three of which have already produced failures that
# looked like something else entirely. That knowledge belongs in one file.
#
# NOTE FOR WHOEVER FINISHES THE provision-accounts.sh REWORK: that script still carries
# its OWN copies of these primitives (accounts_open, form_field, fill_field, click_caption,
# validation_messages, account_state, open_edit_account, stage_account). They were being
# actively reworked on 2026-09-09 and were deliberately NOT touched here, so nothing
# collided mid-flight. Every function below is prefixed acct_ precisely so both can be
# sourced into one shell if that helps the convergence. When the rework settles, point
# provision-accounts.sh at these and delete its copies -- there should be one implementation.
#
# SELECTORS -- MEASURED LIVE ON DEV 2026-09-09, NOT READ FROM THE MODEL
# ---------------------------------------------------------------------
# Admin Hub -> the "Accounts Overview" card is an AUTO-NAMED container (mx-name-container20
# today), so it is opened by its TEXT. Account Overview then gives:
#
#   .mx-name-textFilter2 input            the Login column filter
#   a[aria-label="Edit Account"]          per row
#   a[aria-label="Force Reset Password"]  per row  } NEVER CLICKED HERE. Forcing a reset is
#   a[aria-label="Delete Account"]        per row  } the problem, not the remedy.
#
# On the Edit Account form: .mx-name-microflowTrigger1 is "Change password", and the
# dialog it opens has exactly two visible password boxes, labelled "New password" and
# "Confirm password". Their widget names are textBox3 and textBox1 today -- and
# textBox1 is ALSO the Username box on the Edit Account form behind it, which is why
# every field below is resolved by its form-group LABEL and never by name.
#
# THE ADMIN NEVER NEEDS THE CURRENT PASSWORD. The dialog asks for a new one and a
# confirmation, nothing else. That is what makes a password round-trip possible at all,
# and it means a run that dies half way can be recovered simply by running again.

# ACCT_LAST_ERROR -- set by every function that returns non-zero, so a caller can build
# one report instead of interleaving its own message with whatever printed below.
ACCT_LAST_ERROR=""

acct_log() { echo "  [accounts] $*"; }
acct_ev()  { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

# acct_ev_num <js> -- an eval whose answer must be a number, retried if it comes back blank.
#
# A blank answer is not an answer: playwright-cli eval occasionally returns nothing at
# all, and treating that as fatal is how one hiccup aborted every remaining account on a
# six-account provisioning run. Ask again before concluding anything.
acct_ev_num() {
  local i r=""
  for i in 1 2 3 4; do
    r="$(acct_ev "$1")"
    case "$r" in
      ''|*[!0-9]*) sleep 2 ;;
      *) printf '%s' "$r"; return 0 ;;
    esac
  done
  printf '%s' "$r"
  return 1
}

# acct_admin_login <user> <pass> -- sign in as the administrator and land on the Admin Hub.
#
# Not a bare tt_login: it also PROVES the session belongs to that account. A cached
# session left behind by an earlier step authenticates instantly as somebody else, and
# every write below would then be attributed to them.
#
# TT_AUTH_CACHE=0 for the same reason the manual-env preflight refuses stored state:
# _tt_auth_try accepts a saved cookie on identity plus landing text WITHOUT
# re-authenticating, so a stale .auth/ entry would satisfy this whatever the password is.
acct_admin_login() {
  local user="$1" pass="$2" who
  TT_AUTH_CACHE=0 tt_login "$user" "Accounts Overview" "$pass"
  who="$(acct_ev "() => { try { return mx.session.userObject.jsonData.attributes.Name.value; } catch(e) { return ''; } }")"
  [ "$who" = "$user" ] \
    || tt_fail "expected to be signed in as '$user' but the session belongs to '${who:-unknown}' -- refusing to change passwords from someone else's session"
}

# acct_hub_card <text> -- go to the Admin Hub and open a card by its caption.
#
# By TEXT because the card containers are auto-named (container18, container20, ...) and
# renumber whenever a card is added. POLLS rather than sleeping a fixed amount: 4s was
# enough locally and not on Mendix Cloud, where it reported a missing card for a hub that
# had simply not finished rendering.
acct_hub_card() {
  local i r
  playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
  for i in $(seq 1 15); do
    sleep 2
    r="$(acct_ev "() => { const el=[...document.querySelectorAll('*')].find(e=>e.offsetParent!==null && e.childElementCount===0 && (e.innerText||'').trim()==='$1'); if(!el) return 'NOTFOUND'; let t=el; for(let k=0;k<5&&t;k++){ if(getComputedStyle(t).cursor==='pointer') break; t=t.parentElement; } (t||el).click(); return 'ok'; }")"
    [ "$r" = "ok" ] && { sleep 5; return 0; }
  done
  ACCT_LAST_ERROR="the '$1' card never appeared on the Admin Hub (30s)"
  return 1
}

# acct_overview_open -- land on Account Overview with its Login filter rendered, from a
# FRESH page.
#
# It always re-navigates rather than short-circuiting when the filter happens to be on
# screen, and that is the single most load-bearing line in this file. Opening these forms
# repeatedly leaves EARLIER COPIES in the DOM -- two complete sets of the account fields
# have been observed at once, with only the second live -- and a fill or a click that lands
# on a dead copy looks exactly like a form that has changed shape.
#
# A Mendix reload is NOT a substitute: reloading the client returns to the app's HOME
# page rather than the page that was open, so reload-then-check hunts for the accounts
# filter on the Admin Hub and never finds it.
acct_overview_open() {
  local i j
  for i in 1 2 3; do
    acct_hub_card "Accounts Overview" || continue
    # The card raised a runtime error once, on a session that had gone anonymous under
    # us. Clearing the dialog and trying again fixed it, so that is what happens here
    # rather than reporting a missing page.
    tt_clear_dialogs 4 >/dev/null 2>&1 || true
    for j in $(seq 1 12); do
      [ "$(acct_ev "() => String(!!document.querySelector('.mx-name-textFilter2'))")" = "true" ] && return 0
      sleep 2
    done
    acct_log "(attempt $i: Account Overview did not render its Login filter; retrying)"
  done
  ACCT_LAST_ERROR="Account Overview never rendered its Login filter after 3 attempts -- the page may be erroring (look for 'An error occurred' on screen)"
  return 1
}

acct_filter() {
  playwright-cli fill ".mx-name-textFilter2 input" "$1" >/dev/null 2>&1
  sleep 4
}

# acct_row <login> -- the grid row for that EXACT login, or ''.
#
# Exact equality on the Login cell, not a substring of the row: 'e2e_consultant' is a
# prefix of 'e2e_consultant2', and 'manual_consultant' of 'manual_consultant2', so a
# contains-match would happily act on the wrong account.
acct_row() {
  acct_filter "$1"
  acct_ev "() => { const g=[...document.querySelectorAll('[role=grid],[role=treegrid]')].filter(e=>e.offsetParent!==null)[0]; if(!g) return ''; for (const r of [...g.querySelectorAll('[role=row]')]) { const c=[...r.querySelectorAll('[role=gridcell],td')]; if (c.length<2) continue; if ((c[1].innerText||'').trim()==='$1') return c.map(function(x){ return (x.innerText||'').replace(/\\s+/g,' ').trim(); }).join(' | '); } return ''; }"
}

# acct_state <login> -- "Blocked=<b> Active=<a>" read through the data API.
#
# Worth its own round trip because a blocked account is INDISTINGUISHABLE from a wrong
# password at the login form, and that is the most confusing failure this whole surface
# produces: the verification step would report "the restored password does not work" for
# an account whose password is perfectly fine and which is simply locked out.
acct_state() {
  acct_ev "() => new Promise(function(res){ try { mx.data.get({ xpath: \"//Administration.Account[Name='$1']\", filter:{amount:1}, callback:function(o){ if(!o.length) return res('ABSENT'); res('Blocked='+o[0].get('Blocked')+' Active='+o[0].get('Active')); }, error:function(e){ res('ERR:'+((e&&e.message)||'retrieve-refused')); } }); } catch(e) { res('ERR:'+e.message); } })"
}

# acct_validation -- whatever the widgets are currently complaining about.
acct_validation() {
  acct_ev "() => [...document.querySelectorAll('.mx-validation-message')].filter(e=>e.offsetParent!==null).map(function(e){ return (e.innerText||'').trim(); }).filter(Boolean).join(' ~ ')"
}

# acct_click_caption <regex> -- click the LAST visible button whose text matches.
#
# Last, not first: these forms stack popups (the password dialog opens over the edit
# form) and both layers have a Cancel. The innermost is the one on screen, and it is last
# in DOM order.
acct_click_caption() {
  acct_ev "() => { const bs=[...document.querySelectorAll('button, a[role=button]')].filter(e=>e.offsetParent!==null); const m=bs.filter(e=>new RegExp('^($1)\$','i').test((e.innerText||'').trim())); if(!m.length) return 'NOBUTTON:'+bs.map(function(e){ return (e.innerText||'').trim(); }).filter(Boolean).join(','); m[m.length-1].click(); return 'ok'; }"
}

# acct_form_field <label-regex> -- the .mx-name-* wrapper of the visible input whose
# form-group label matches, or NONE.
#
# Resolved at runtime, by LABEL, because every box on both account forms is auto-named
# and the two forms do not agree with each other: textBox1 is the Username box on Edit
# Account and the "Confirm password" box in the dialog that opens over it. Takes the LAST
# match, for the stale-copy reason above acct_overview_open.
acct_form_field() {
  acct_ev "() => { const ins=[...document.querySelectorAll('input')].filter(i=>i.offsetParent!==null); let found=''; for (const i of ins) { const grp=i.closest('.form-group'); const lbl=grp?((grp.querySelector('label')||{}).innerText||'').trim():''; if(!/$1/i.test(lbl)) continue; let w=i; for(let k=0;k<6&&w;k++){ const m=(w.className||'').toString().match(/mx-name-[A-Za-z0-9_]+/); if(m){ found=m[0]; break; } w=w.parentElement; } } return found || 'NONE'; }"
}

# acct_fill_field <wrapper-class> <value> -- fill the LIVE copy of a form field.
#
# playwright-cli fill is strict: a selector matching several elements is refused
# outright and aborts the run. acct_overview_open should make duplicates impossible; this
# makes them harmless as well, by addressing the LAST match in DOM order, which is the
# most recently opened and therefore the live one.
acct_fill_field() {
  local wrap="$1" val="$2" n
  if ! n="$(acct_ev_num "() => String(document.querySelectorAll('.$wrap input').length)")"; then
    ACCT_LAST_ERROR="could not count '.$wrap input' after 4 tries (got [$n]) -- the browser stopped answering"
    return 1
  fi
  case "$n" in
    0) ACCT_LAST_ERROR="'.$wrap input' is not on the form at all"; return 1 ;;
    1) tt_fill ".$wrap input" "$val"; return 0 ;;
    *) acct_log "note: $n copies of .$wrap on screen -- filling the last"
       tt_fill ":nth-match(.$wrap input, $n)" "$val"; return 0 ;;
  esac
}

# acct_open_edit <login> -- open Administration.Account_Edit for that row, from a fresh page.
acct_open_edit() {
  local user="$1" i r
  acct_overview_open || return 1
  acct_filter "$user"
  r="$(acct_ev "() => { const g=[...document.querySelectorAll('[role=grid],[role=treegrid]')].filter(e=>e.offsetParent!==null)[0]; if(!g) return 'NOGRID'; for (const r of [...g.querySelectorAll('[role=row]')]) { const c=[...r.querySelectorAll('[role=gridcell],td')]; if (c.length<2) continue; if ((c[1].innerText||'').trim()!=='$user') continue; const a=r.querySelector('a[aria-label=\"Edit Account\"]'); if(!a) return 'NOEDIT'; a.click(); return 'ok'; } return 'NOROW'; }")"
  case "$r" in
    ok) : ;;
    NOROW)  ACCT_LAST_ERROR="no account with the login '$user' is in the grid"; return 1 ;;
    NOGRID) ACCT_LAST_ERROR="Account Overview rendered no grid at all"; return 1 ;;
    *)      ACCT_LAST_ERROR="could not open Edit Account for '$user' ($r)"; return 1 ;;
  esac
  for i in $(seq 1 12); do
    [ "$(acct_ev "() => String(!!document.querySelector('.mx-name-saveButton1'))")" = "true" ] && return 0
    sleep 1
  done
  ACCT_LAST_ERROR="the Edit Account form for '$user' never rendered"
  return 1
}

# acct_unblock <login> -- clear a failed-login lockout, if one is set.
#
# A SEPARATE save, deliberately. The password dialog's confirm action closes both layers
# and commits, so a Blocked change made just before it appears to persist -- but relying
# on one microflow to commit another form's edit is exactly the coupling that breaks
# silently later. Save the unblock, then reopen for the password.
acct_unblock() {
  local user="$1" state
  state="$(acct_state "$user")"
  case "$state" in
    ABSENT) ACCT_LAST_ERROR="$user: no such account"; return 1 ;;
    ERR:*)  acct_log "note: could not read $user's state ($state); continuing"; return 0 ;;
    *"Blocked=true"*) : ;;
    *) return 0 ;;
  esac

  acct_log "$user is BLOCKED (failed-login lockout) -- clearing the flag first"
  acct_open_edit "$user" || return 1
  acct_ev "() => { const g=[...document.querySelectorAll('.form-group')].filter(e=>e.offsetParent!==null); for (const x of g) { const l=((x.querySelector('label')||{}).innerText||'').trim().toLowerCase(); const c=x.querySelector('input[type=checkbox]'); if (c && l==='blocked') { if (c.checked) c.click(); return String(c.checked); } } return 'NOBOX'; }" >/dev/null
  sleep 1
  acct_click_caption "save" >/dev/null
  sleep 5
  tt_clear_dialogs 4 >/dev/null 2>&1 || true
  state="$(acct_state "$user")"
  case "$state" in
    *"Blocked=true"*) ACCT_LAST_ERROR="$user: the Blocked flag is still set after saving the Edit Account form"; return 1 ;;
  esac
  acct_log "$user unblocked ($state)"
  return 0
}

# acct_set_password <login> <newpass> -- set that account's password as the administrator.
#
# Exit codes are three-way ON PURPOSE, because the two failure kinds want opposite
# handling from a caller walking a chain of passwords:
#
#   0  the change was accepted
#   1  MECHANICAL failure -- the form did not open, a box was missing, the browser stopped
#      answering. Nothing is known about the account's password; say so and stop.
#   2  REFUSED -- the form rendered, took the value, and the app rejected it (too short,
#      too weak, or the same as the one it already has). The account's password is
#      UNCHANGED and still whatever it was, which is a safe state to continue from.
#
# Collapsing those two into "failed" is what would make this dangerous: a caller cannot
# tell whether it may keep going, and the honest answer differs.
#
# It does NOT verify the password works. It cannot -- only the account itself can prove
# that, by signing in. That is a separate step, and it is the one that actually matters.
acct_set_password() {
  local user="$1" new="$2" i ok="" f_new f_conf bad r
  ACCT_LAST_ERROR=""

  acct_open_edit "$user" || return 1

  r="$(acct_click_caption "change password")"
  case "$r" in
    ok) : ;;
    *)  ACCT_LAST_ERROR="$user: no 'Change password' button on the Edit Account form ($r)"
        acct_click_caption "cancel" >/dev/null; return 1 ;;
  esac

  for i in $(seq 1 12); do
    [ "$(acct_ev "() => String([...document.querySelectorAll('input[type=password]')].filter(e=>e.offsetParent!==null).length >= 2)")" = "true" ] && { ok=1; break; }
    sleep 1
  done
  [ -n "$ok" ] || { ACCT_LAST_ERROR="$user: the Change password dialog never opened"
                    acct_click_caption "cancel" >/dev/null; return 1; }

  f_new="$(acct_form_field '^new password$')"
  f_conf="$(acct_form_field 'confirm')"
  case "$f_new$f_conf" in
    *NONE*) ACCT_LAST_ERROR="$user: the Change password dialog is missing a box (new=$f_new confirm=$f_conf) -- the form has changed shape"
            acct_click_caption "cancel" >/dev/null; return 1 ;;
  esac

  if ! { acct_fill_field "$f_new" "$new" && acct_fill_field "$f_conf" "$new"; }; then
    ACCT_LAST_ERROR="$user: could not fill the Change password dialog -- $ACCT_LAST_ERROR"
    acct_click_caption "cancel" >/dev/null; return 1
  fi
  sleep 1

  # Complained about before the confirm is even pressed: too short, not confirmed. The
  # account is untouched, so this is a refusal, not a mechanical failure.
  bad="$(acct_validation)"
  if [ -n "$bad" ]; then
    ACCT_LAST_ERROR="$user: the dialog rejected the new password before saving: $bad"
    acct_click_caption "cancel" >/dev/null
    return 2
  fi

  # The confirm button's caption has been seen as both "Change" and "Save" on this
  # dialog, so both are accepted -- and in that order, so the more specific one wins when
  # the Edit Account form's own Save is also on screen behind it.
  r="$(acct_click_caption "change")"
  case "$r" in
    ok) : ;;
    *)  r="$(acct_click_caption "save")" ;;
  esac
  case "$r" in
    ok) : ;;
    *)  ACCT_LAST_ERROR="$user: the Change password dialog has neither a 'Change' nor a 'Save' button ($r)"
        acct_click_caption "cancel" >/dev/null; return 1 ;;
  esac

  sleep 6
  tt_clear_dialogs 4 >/dev/null 2>&1 || true

  bad="$(acct_validation)"
  if [ -n "$bad" ]; then
    ACCT_LAST_ERROR="$user: the password change was refused: $bad"
    return 2
  fi
  return 0
}
