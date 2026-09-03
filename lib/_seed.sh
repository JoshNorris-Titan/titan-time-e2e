#!/usr/bin/env bash
# Shared primitives for the data seeders. Source AFTER lib/_login.sh:
#   source "$(dirname "$0")/lib/_login.sh"
#   source "$(dirname "$0")/lib/_seed.sh"
#
# This file exists because the seeder and its shakedown must agree on HOW to talk to
# the app. Every rule below was paid for by a failure, so read the comment before
# "simplifying" any of it.
#
# Env:
#   TT_BASE_URL    app origin. REQUIRED by callers — seeding is destructive and must
#                  never fall back to a default environment.
#   TT_ROLE_PASS   password for the e2e_* accounts (default E2ETest123!)
#   TT_ADMIN_USER  admin login  (default MxAdmin)
#   TT_ADMIN_PASS  admin password

SEED_PASS="${TT_ROLE_PASS:-E2ETest123!}"
SEED_ADMIN_USER="${TT_ADMIN_USER:-MxAdmin}"
SEED_ADMIN_PASS="${TT_ADMIN_PASS:-TitanTime#2026}"

seed_log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# ---------------------------------------------------------------------------- pw
#
# pw <js> — the eval RESULT only.
#
# THE BUG THIS EXISTS TO KILL. playwright-cli echoes the JS SOURCE back on stdout
# under "### Ran Playwright code", so the tempting idiom
#     playwright-cli eval "() => { ...; return 'ok'; }" | grep -qiw ok
# matches the literal `return 'ok'` INSIDE THE SNIPPET and reports success no matter
# what the snippet actually returned. The result is always line 2 — parse it.
#
# COST. Each call spawns a process and takes roughly 3-5 SECONDS. That dominates
# everything: a week of seeding is ~90 calls. Never split one question into two calls,
# never poll something you could have returned in the same eval, and prefer returning a
# compact JSON blob over five separate probes.
pw() { playwright-cli eval "$1" 2>/dev/null | sed -n '2p' | sed -e 's/^"//' -e 's/"$//'; }

# pw_lines <js> — like pw, but for a result that CONTAINS NEWLINES.
#
# THE BUG THIS EXISTS TO KILL. playwright-cli JSON-encodes the result, so a multi-line
# string arrives with LITERAL backslash-n, not real newlines. Reading it with plain pw()
# therefore yields ONE line, and anything counting lines sees 1.
#
# That is not hypothetical: seed_week_list returns one row per week, and with pw() the
# whole gallery came back as a single line — so the ladder resolver concluded there was
# exactly ONE seedable week and dropped seven stages, immediately after the materialiser
# had correctly created all eight. Always use this for multi-line results.
pw_lines() {
  playwright-cli eval "$1" 2>/dev/null \
    | sed -n '2p' \
    | sed -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g' \
    | { IFS= read -r raw || true; printf '%b\n' "$raw"; }
}

# ------------------------------------------------------------------------- session
#
# seed_login <user> <pass> <ready-text>
#
# Closes and REOPENS the browser, then signs in on the app's own Core.Login page.
#
# WHY NOTHING CHEAPER WORKS. cookie-clear + mx.logout() does not reliably drop the
# session here: a consultant login was observed resolving to a stale MxAdmin session,
# and a consultant page silently turned into the HR dashboard mid-run. Worse,
# navigating to /logout CRASHES the browser process outright. A full close/open is the
# only switch that has proven reliable, so do not "optimise" it away.
#
# It asserts the SESSION IDENTITY, not just the landing text, because a stale session
# lands on a perfectly valid-looking dashboard belonging to somebody else — which is
# exactly how a whole run silently seeded as the wrong user.
seed_login() {
  local user="$1" pass="$2" ready="$3" i j r
  for i in 1 2 3; do
    playwright-cli close >/dev/null 2>&1
    sleep 2
    playwright-cli open "$TT_BASE/" >/dev/null 2>&1
    for j in $(seq 1 15); do
      [ "$(pw "() => String(!!document.querySelector('input.form-control[type=password]'))")" = "true" ] && break
      sleep 2
    done

    playwright-cli fill "input.form-control[type=text]" "$user" >/dev/null 2>&1
    sleep 1
    playwright-cli fill "input.form-control[type=password]" "$pass" >/dev/null 2>&1
    sleep 1
    # Confirm the field took before submitting. Mendix inputs commit on a real focus
    # change, and a fill that silently wrote nothing would submit empty credentials and
    # look identical to a wrong password.
    if [ "$(pw "() => { const t=document.querySelector('input.form-control[type=text]'); return String(!!t && t.value==='$user'); }")" != "true" ]; then
      seed_log "  login: username field did not take (attempt $i)"
      continue
    fi
    playwright-cli click ".mx-name-actionButton1" >/dev/null 2>&1

    # Identity + landing text in ONE eval — see the COST note on pw().
    for j in $(seq 1 12); do
      r="$(pw "() => { let n=''; try{ n=mx.session.userObject.jsonData.attributes.Name.value; }catch(e){} if(n==='$user' && document.body.innerText.indexOf('$ready')>=0) return 'READY'; if(/Invalid Credentials|is incorrect/i.test(document.body.innerText||'')) return 'BADCREDS'; return n||'-'; }")"
      case "$r" in
        READY)    return 0 ;;
        BADCREDS) seed_log "  login: '$user' rejected — wrong password for this environment"; return 1 ;;
      esac
      sleep 3
    done
    seed_log "  login attempt $i as '$user' never settled on '$ready' (last identity: ${r:-?})"
  done
  return 1
}

seed_login_role()  { seed_login "$1" "$SEED_PASS" "$2"; }
seed_login_admin() { seed_login "$SEED_ADMIN_USER" "$SEED_ADMIN_PASS" "${1:-Admin Hub}"; }

seed_whoami() { pw "() => { let n=''; try{ n=mx.session.userObject.jsonData.attributes.Name.value; }catch(e){} return n||'(anonymous)'; }"; }

# ---------------------------------------------------------------- consultant page

seed_week_caption() { pw "() => String((document.querySelector('.mx-name-txtWeekRange')||{}).innerText||'').trim()"; }

# seed_week_list — one line per week the consultant's history gallery offers, as
# "<label>|<projects>|<hours>", newest first.
#
# This is the cheapest source of truth about WHICH WEEKS ARE SEEDABLE.
# Main.SUB_Assignment_FilterActive only creates entries for assignments whose date
# window spans the week, so a week outside every window renders ZERO rows and cannot be
# seeded at all — it shows "Projects: 0" here. Reading this first avoids designing a
# ladder on weeks that can never hold data (which is exactly how a January 2026 plan got
# built before anyone noticed every week before Jul 2026 was empty).
seed_week_list() {
  pw_lines "() => { const g=document.querySelector('.mx-name-galTimesheetHistory'); if(!g) return ''; return [...g.querySelectorAll('.widget-gallery-clickable')].map(e=>{ const t=(e.innerText||'').replace(/\s+/g,' ').trim(); const lbl=(t.match(/^([A-Z][a-z]{2} \d{2} - [A-Z][a-z]{2} \d{2})/)||[])[1]||''; const pr=(t.match(/Projects:\s*(\d+)/)||[])[1]||'?'; const hr=(t.match(/([\d.]+)\s*hrs/)||[])[1]||'?'; return lbl?(lbl+'|'+pr+'|'+hr):''; }).filter(Boolean).join('\n'); }"
}

# seed_materialise_weeks <n> — step BACK n weeks with the arrow, then return to where we
# started, so those weeks exist.
#
# WHY THIS IS NEEDED AT ALL. The timesheet history gallery only lists weeks that already
# have a Main.Timesheet row. On a freshly cleared database that is exactly ONE week — the
# current one, created by DS_Timesheet_Get when the page first renders. So a ladder that
# resolves its weeks from the gallery can only ever find one week and would silently seed
# a single week instead of eight.
#
# Visiting a week is what creates it: DS_Timesheet_Get retrieves the week's Timesheet and,
# finding none, calls SUB_Timesheet_Create, which also builds one AssignmentEntry per
# active assignment. So walking back materialises the weeks AND their rows.
#
# Each step is verified, because a click issued while the page is still rendering is
# silently swallowed — an unverified loop of 34 prev-clicks once advanced only 4 weeks.
seed_materialise_weeks() {
  local n="$1" made=0 i j before after
  for i in $(seq 1 "$n"); do
    before="$(seed_week_caption)"
    playwright-cli click ".mx-name-btnWeekPrev" >/dev/null 2>&1
    after="$before"
    for j in $(seq 1 8); do
      sleep 2
      after="$(seed_week_caption)"
      [ -n "$after" ] && [ "$after" != "$before" ] && break
    done
    if [ "$after" = "$before" ]; then
      seed_log "  materialise: stuck at '$before' after $made week(s)"
      break
    fi
    made=$((made + 1))
  done

  # RELOAD before the caller re-reads the gallery.
  #
  # The history gallery's data source is evaluated when the page renders and does NOT
  # pick up Timesheets created afterwards by walking the arrows. Without this reload the
  # caller materialises seven weeks, re-reads the gallery, still sees only the original
  # one, and silently seeds a single week — which is exactly what happened to
  # e2e_consultant2 and e2e_consultant3 while consultant 1 (whose weeks already existed
  # at page load) worked perfectly, making it look like a per-consultant problem.
  playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
  local k
  for k in $(seq 1 12); do
    sleep 2
    [ -n "$(seed_week_caption)" ] && break
  done

  echo "$made"
}

# seed_goto_week <label> — land on a week and CONFIRM the caption says so.
#
# Fast path is the history gallery: one click, ~6s. The arrows cost ~20-25s per week
# because each step has to be verified — a loop of 34 prev-clicks with a 1s settle
# advanced the week only 4 times, the rest swallowed mid-render. The gallery lists only
# CURRENT and PAST weeks, so a future week needs the arrow fallback.
seed_goto_week() {
  local want="$1" i j before after
  case "$(seed_week_caption)" in *"$want"*) return 0 ;; esac

  for i in 1 2; do
    [ "$(pw "() => { const g=document.querySelector('.mx-name-galTimesheetHistory'); if(!g) return 'N'; const it=[...g.querySelectorAll('.widget-gallery-clickable')].find(e=>(e.innerText||'').trim().indexOf('$want')===0); if(it){ it.click(); return 'Y'; } return 'N'; }")" = "Y" ] || break
    for j in $(seq 1 8); do
      sleep 2
      case "$(seed_week_caption)" in *"$want"*) return 0 ;; esac
    done
  done

  for i in $(seq 1 "${SEED_MAX_FORWARD:-6}"); do
    before="$(seed_week_caption)"
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    after="$before"
    for j in $(seq 1 6); do
      sleep 2
      after="$(seed_week_caption)"
      [ -n "$after" ] && [ "$after" != "$before" ] && break
    done
    [ "$after" = "$before" ] && return 1
    case "$after" in *"$want"*) return 0 ;; esac
  done
  return 1
}

# seed_open_rows — "ordinal:kind" per assignment row (1-based), kind EDIT or LINE.
#
# STABILITY RETRY, not paranoia. Reading immediately after a week change can catch the
# gallery mid-render and report every row as locked — that happened on an arrow-navigated
# week and silently produced an EMPTY timesheet where an over-40 draft was intended,
# because the "all rows locked" reading made the fill loop skip every row. Require the
# same answer twice in a row before trusting it.
seed_open_rows() {
  local a b i
  a=""
  for i in $(seq 1 8); do
    b="$(pw "() => { const m=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')]; const out=[]; for(let n=0;n<m.length;n++){ const i=m[n].querySelector('input'); if(!i) continue; out.push((n+1)+':'+((!i.disabled && !i.readOnly)?'EDIT':'LINE')); } return out.join(','); }")"
    [ -n "$b" ] && [ "$b" = "$a" ] && { echo "$b"; return 0; }
    a="$b"
    sleep 2
  done
  echo "$a"
}

# seed_force_clear — clear popups and SAY whether any remain.
#
# tt_clear_dialogs returns 0 both when everything is clear AND when it exhausts its loop
# with a dialog still up. That false "all clear" strands the next action, because an open
# Mendix dialog swallows every subsequent click — which is how a blocked save silently
# took the FOLLOWING week down with it.
seed_force_clear() {
  local i
  for i in 1 2 3; do
    tt_clear_dialogs 8 >/dev/null 2>&1 || true
    [ "$(pw "() => { const vis=[...document.querySelectorAll('.mx-window-content,.mx-dialog-content,.modal-content,[role=dialog]')].filter(d=>d.offsetParent!==null); return String(vis.length===0); }")" = "true" ] && return 0
    sleep 2
  done
  return 1
}

# ------------------------------------------------------------------- HR dashboard

# seed_kpis — the six dashboard counters as "pending manager client process invoice sent".
# One eval, not six: see the COST note on pw().
seed_kpis() {
  pw "() => ['cardKpiPending','cardKpiManager','cardKpiCustomer','cardKpiProcess','cardKpiInvoice','cardKpiSent'].map(c=>{ const e=document.querySelector('.mx-name-'+c); if(!e) return '?'; const m=(e.innerText||'').trim().match(/(\d+)\s*\$/); return m?m[1]:'?'; }).join(' ')"
}

seed_click_tab() {
  local i
  for i in 1 2 3; do
    [ "$(pw "() => { const el=[...document.querySelectorAll('h4,h5,div,span,a,button,li')].find(e => (e.innerText||'').trim()==='$1' && getComputedStyle(e).cursor==='pointer'); if (el) { el.click(); return 'Y'; } return 'N'; }")" = "Y" ] && { sleep 4; return 0; }
    sleep 2
  done
  return 1
}

seed_tab_weeks() {
  pw "() => { const g=document.querySelector('$TT_HR_GAL_WEEKS'); if(!g) return ''; return [...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} \d{2} - /.test(t)))].join('|'); }"
}
