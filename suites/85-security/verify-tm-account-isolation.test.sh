#!/usr/bin/env bash
# A Titan Manager cannot change, take over or delete anyone else's account: not the
# administrator's, not another Titan Manager's, not HR's - and, until a guarded
# path for it exists, not a project manager's either.
#
# tt-timeout: 12m
#
# WHY THIS EXISTS. The TitanManager user role was mapped to the Marketplace module
# role Administration.Administrator. That role's Administration.Account rule has no
# XPath, allows create and delete, and grants ReadWrite on Email (and on the
# inherited System.User members), and it may call Administration.ShowPasswordForm
# for ANY account. ManageableRoles = [ProjectManager] limits which roles a TM may
# GRANT, not which accounts a TM may EDIT. So a TM could put their own address on
# the administrator's account and use Forgot password to take it over - or skip the
# email and set the administrator's password outright. The fix (Gate 2, 2026-10-07)
# remaps TitanManager to Administration.User. Nothing in the suite has ever tried
# any of this: every other e2e_tm step uses the screens, and no screen offers it.
#
# NEVER A REAL ACCOUNT. Every probe acts on one of four disposable targets that hold
# no data:
#   e2e_target_admin (Administrator)    e2e_target_tm (TitanManager)
#   e2e_target_hr    (HR)               e2e_target_pm (ProjectManager only)
# PROVISIONED ONCE BY HAND, like e2e_pwreset: Admin Hub -> Accounts Overview -> New
# local user, that login, full name 'E2E Target Admin' / 'E2E Target TM' / ...,
# email <login with - for _>@example.invalid (so nothing is ever delivered), the one
# role named above, any employment status. The client cannot create them: an
# administrator's mx.data commit of a new Administration.Account is refused
# ("Internal server error", measured on dev 2026-10-07), while writes to an EXISTING
# account work - so setup only RESETS them: Email back to its canonical value, Active
# false, and for e2e_target_admin Active true with a password made up for this run
# (set through the Accounts Overview, lib/_accounts.sh), deactivated again on the way
# out (EXIT trap). A missing target is a setup failure naming this paragraph.
#
# DO NOT RUN THIS BEFORE THE FIX IS DEPLOYED. Before it, the TM's deletes SUCCEED, so
# one run deletes three of the hand-provisioned targets. Provision them after the
# deploy. This step NEVER calls Forgot password.
#
# WHAT IT ASSERTS (as e2e_tm, read back as the administrator)
#   A. the session holds the TitanManager role and not Administrator;
#   B. CONTROL: the administrator CAN change e2e_target_pm's Email through the same
#      client call (and puts it back) - so every refusal below is attributable to
#      access, not to the call; then the TM's own attempt on e2e_target_pm is
#      refused and the Email is unchanged. Josh skipped a TM account editor
#      (Step 2), so there is no sanctioned TM path to pin; if one is added, B's TM
#      half moves to it;
#   C/D. Email on e2e_target_admin: refused, and unchanged;
#   E/F. Email on e2e_target_tm and e2e_target_hr: refused, and unchanged;
#   G. Administration.ShowPasswordForm on e2e_target_admin: refused;
#   H. e2e_target_admin still signs in with the password this run gave it;
#   I/J. deleting e2e_target_admin and e2e_target_tm: refused, and both still exist;
#   K. deleting e2e_target_pm: refused, and it still exists (TM deactivates
#      instead of deleting - flip K if Josh ever wants TM to delete PM accounts).
# D, F, H and J are the ones that matter: a "refusal" that landed anyway is the
# shape this catches, so every write is read back by the administrator.
#
# RED UNTIL THE FIX IS DEPLOYED. On an environment where TitanManager still maps
# to Administration.Administrator, C-K all fail (A too, if the session lists the
# module role). That is the finding, not a defect of this step.
#
# Consumes: nothing a person uses. Leaves the four targets inactive (after the fix;
# before it, see DO NOT RUN THIS BEFORE THE FIX IS DEPLOYED). Clears cookies.
# Env: TT_BASE_URL, TT_ROLE_PASS, TT_ADMIN_USER, TT_ADMIN_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"
source "$TT_ROOT/lib/_testdata.sh"   # TT_ADMIN_U / TT_ADMIN_P
source "$TT_ROOT/lib/_accounts.sh"   # acct_set_password

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

TM_USER="${TT_TMISO_USER:-e2e_tm}"
# login|full name|user role
TARGETS="e2e_target_admin|E2E Target Admin|Administrator
e2e_target_tm|E2E Target TM|TitanManager
e2e_target_hr|E2E Target HR|HR
e2e_target_pm|E2E Target PM|ProjectManager"
email_of() { printf '%s@example.invalid' "$(printf '%s' "$1" | tr '_' '-')"; }
acc_xp()   { printf "//Administration.Account[Name = '%s']" "$1"; }
ADMIN_PW="Tmiso-$(date +%s)-Aa9!"

as_admin() { TT_AUTH_CACHE=0 tt_login "$TT_ADMIN_U" "Welcome to your homepage" "$TT_ADMIN_P"; }
as_tm()    { TT_AUTH_CACHE=0 tt_login "$TM_USER" "Add Customer"; }

# ensure_target <login> <active> - as the administrator: the target must exist; reset
# its Email to the canonical value and set Active. Echoes the guid, ABSENT, or ERR:<why>.
ensure_target() {
  ev "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),20000);
    mx.data.get({ xpath: \"$(acc_xp "$1")\", filter:{amount:1}, callback: o => {
      if (!o || !o.length) { clearTimeout(t); return res('ABSENT'); }
      const a=o[0]; a.set('Email', '$(email_of "$1")'); a.set('Active', $2);
      mx.data.commit({ mxobj: a, callback: () => { clearTimeout(t); res(a.getGuid()); }, error: e => { clearTimeout(t); res('ERR:commit-'+e.message); } });
    }, error: e => { clearTimeout(t); res('ERR:get-'+e.message); } }); } catch(e) { res('ERR:'+e.message); } })"
}

# guid_of <xpath> - the first match's guid as the CURRENT session sees it, or ERR:<why>.
guid_of() {
  ev "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"$1\", filter:{amount:1}, callback: o => { clearTimeout(t); res(o && o.length ? o[0].getGuid() : 'ERR:notfound'); }, error: e => { clearTimeout(t); res('ERR:'+e.message); } }); } catch(e) { res('ERR:'+e.message); } })"
}

# exists <login> - 'yes' / 'no' / ERR:<why>, read as the CURRENT session.
exists() {
  local n; n="$(tt_authz_count "$(acc_xp "$1")")"
  case "$n" in ERR:*) echo "$n" ;; 0) echo no ;; *) echo yes ;; esac
}

# sign_in <login> <password> - one attempt on Core.Login from a fresh session.
sign_in() {
  local v rc
  playwright-cli cookie-clear >/dev/null 2>&1
  playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
  v="$(_tt_login_form_variant 30)"
  [ "$v" = "new" ] || { echo "noform"; return 0; }
  _tt_login_submit new "$1" "$2" "Welcome to your homepage"; rc=$?
  case "$rc" in 0) echo in ;; 1) echo refused ;; 2) echo reset ;; *) echo stuck ;; esac
}

# Every target the TM managed to change is put back by the administrator, and the
# administrator target is always deactivated, however this step ends.
RESTORE=0
cleanup() {
  echo "  cleanup: the administrator resets the targets' email and deactivates them"
  as_admin >/dev/null 2>&1 || { echo "  WARNING: could not sign in as the administrator to deactivate e2e_target_admin - do it by hand (Accounts Overview)." >&2; return 0; }
  local line login full role g
  while IFS='|' read -r login full role; do
    [ "$(exists "$login")" = "yes" ] || continue
    g="$(ensure_target "$login" false)"
    case "$g" in ABSENT|ERR:*) echo "  WARNING: could not reset $login ($g) - deactivate it by hand." >&2 ;; esac
  done <<< "$TARGETS"
  return 0
}
trap cleanup EXIT

# ------------------------------------------------------------------ setup, as admin
as_admin
while IFS='|' read -r login full role; do
  g="$(ensure_target "$login" "$([ "$login" = e2e_target_admin ] && echo true || echo false)")"
  case "$g" in
    ABSENT) tt_fail "setup: there is no account '$login' on $TT_BASE. Provision the four targets once by hand, after the fix is deployed - see NEVER A REAL ACCOUNT in this file's header ('$full', role $role, email $(email_of "$login"))." ;;
    ERR:*)  tt_fail "setup: could not reset $login as the administrator ($g)" ;;
  esac
  note "target $login ($role) = $g"
done <<< "$TARGETS"
acct_set_password e2e_target_admin "$ADMIN_PW" || tt_fail "setup: could not set e2e_target_admin's password for this run ($ACCT_LAST_ERROR)"
as_admin

# B, control half: the administrator's own client write lands, and is put back.
PM_EMAIL="$(email_of e2e_target_pm)"
tt_authz_expect_ok "B-control" "$(tt_authz_write "$(acc_xp e2e_target_pm)" 'Email' 'b-control@example.invalid')" >/dev/null
[ "$(tt_authz_readback "$(acc_xp e2e_target_pm)" 'Email')" = "b-control@example.invalid" ] \
  || tt_fail "B-control: the administrator's write reported ok but did not read back - no refusal below could be attributed"
tt_authz_expect_ok "B-control-restore" "$(tt_authz_write "$(acc_xp e2e_target_pm)" 'Email' "$PM_EMAIL")" >/dev/null
note "B ok (control): the administrator changed and restored e2e_target_pm's Email through the same call"

# ------------------------------------------------------------------ the probes, as TM
as_tm
ROLES="$(tt_authz_roles)"
note "session roles: $ROLES"
case "$ROLES" in
  *'"TitanManager"'*) case "$ROLES" in *'"Administrator"'*) bad "A: the TM session also holds Administrator ($ROLES)" ;; *) note "A ok: TitanManager, not Administrator" ;; esac ;;
  *) tt_fail "A: the session is not a TitanManager session ($ROLES) - nothing below would mean anything" ;;
esac

PROBE="tm-probe-$(date +%s)@example.invalid"
W_PM="$(tt_authz_write "$(acc_xp e2e_target_pm)"    'Email' "$PROBE")"
W_AD="$(tt_authz_write "$(acc_xp e2e_target_admin)" 'Email' "$PROBE")"
W_TM="$(tt_authz_write "$(acc_xp e2e_target_tm)"    'Email' "$PROBE")"
W_HR="$(tt_authz_write "$(acc_xp e2e_target_hr)"    'Email' "$PROBE")"
AD_G="$(guid_of "$(acc_xp e2e_target_admin)")"
case "$AD_G" in ERR:notfound) G_ANS="ERR:notfound" ;; ''|ERR:*) G_ANS="ERR:target-unreadable-by-tm($AD_G)" ;; *) G_ANS="$(tt_authz_action "Administration.ShowPasswordForm" "$AD_G")" ;; esac
D_AD="$(tt_authz_delete "$(acc_xp e2e_target_admin)")"
D_TM="$(tt_authz_delete "$(acc_xp e2e_target_tm)")"
D_PM="$(tt_authz_delete "$(acc_xp e2e_target_pm)")"
note "answers: B=$W_PM C=$W_AD E(tm)=$W_TM E(hr)=$W_HR G=$G_ANS I(admin)=$D_AD I(tm)=$D_TM K=$D_PM"

# said <label> <answer> <what> - the call's own answer. ERR:notfound means the TM
# cannot even read the target, which is a refusal of a stronger kind.
said() {
  case "$2" in
    ok|ok:*)          bad "$1: the call SUCCEEDED - $3" ;;
    ERR:notfound)     note "$1 ok: the Titan Manager cannot even read the target" ;;
    ERR:no-mx-client|ERR:timeout) bad "$1: the question was never answered ($2)" ;;
    ERR:*)            note "$1 ok: refused ($2)" ;;
  esac
}
said "B"     "$W_PM" "the Titan Manager changed e2e_target_pm's Email from the client (no guarded TM path exists)"
said "C"     "$W_AD" "the Titan Manager changed the ADMINISTRATOR target's Email - the takeover route"
said "E-tm"  "$W_TM" "the Titan Manager changed another Titan Manager's Email"
said "E-hr"  "$W_HR" "the Titan Manager changed HR's Email"
said "G"     "$G_ANS" "the Titan Manager opened the password form for the ADMINISTRATOR target"
said "I-adm" "$D_AD" "the Titan Manager DELETED the administrator target"
said "I-tm"  "$D_TM" "the Titan Manager DELETED another Titan Manager"
said "K"     "$D_PM" "the Titan Manager DELETED a project manager's account (TM deactivates, never deletes)"

# ------------------------------------------------------------------ read back, as admin
as_admin
for t in e2e_target_pm e2e_target_admin e2e_target_tm e2e_target_hr; do
  case "$t" in e2e_target_pm) L=B ;; e2e_target_admin) L=D ;; *) L=F ;; esac
  case "$(exists "$t")" in
    yes)
      E="$(tt_authz_readback "$(acc_xp "$t")" 'Email')"
      if [ "$E" = "$(email_of "$t")" ]; then note "$L ok: $t's Email is unchanged"
      else bad "$L: $t's Email is now [$E] - set by the Titan Manager"; fi ;;
    no)  note "$L: $t no longer exists, so its Email cannot be read (see J/K)" ;;
    *)   bad "$L: the administrator could not read $t" ;;
  esac
done
for t in e2e_target_admin e2e_target_tm e2e_target_pm; do
  case "$t" in e2e_target_pm) L=K ;; *) L=J ;; esac
  case "$(exists "$t")" in
    yes) note "$L ok: $t still exists" ;;
    no)  bad "$L: $t is GONE - the Titan Manager's delete landed (the next run recreates it)" ;;
    *)   bad "$L: the administrator could not tell whether $t exists" ;;
  esac
done

# H: the administrator target's password is still the one this run gave it.
if [ "$(exists e2e_target_admin)" = "yes" ]; then
  H="$(sign_in e2e_target_admin "$ADMIN_PW")"
  case "$H" in
    in) note "H ok: e2e_target_admin still signs in with this run's password" ;;
    *)  bad "H: e2e_target_admin no longer signs in with this run's password ($H)" ;;
  esac
else
  bad "H: e2e_target_admin was deleted, so its password could not be checked"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-tm-account-isolation - $fails problem(s). B's control proved the write path works, so these are findings about the Titan Manager's access, not about this script."
  exit 1
fi
echo "PASS: verify-tm-account-isolation - '$TM_USER' cannot change, take over or delete another account; every target reads back unchanged."
