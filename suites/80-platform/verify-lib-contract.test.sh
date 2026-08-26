#!/usr/bin/env bash
# verify-lib-contract.test.sh
#
# Every helper library must source cleanly under `set -u`, and the variables the
# helpers rely on must actually exist after sourcing.
#
# WHY THIS EXISTS. Editing lib/_tt683.sh to replace two functions silently took
# TT683_PROCESS_TARGET with them - it sat between the functions being replaced.
# Nothing noticed until a cloud run failed ten minutes in with
#     lib/_tt683.sh: line 364: TT683_PROCESS_TARGET: unbound variable
# and because `set -u` aborts the subshell, the drain died, the seeder fell to its
# slow path, and the whole step timed out. The real defect was one missing line,
# and it cost a ten-minute run plus the two dependent tests to find.
#
# This runs in about a second, needs no app, and fails on exactly that class of
# mistake: a library that will not source, or one that sources but has lost a
# definition its own functions read.
#
# Nothing here drives a browser. It is a static contract check.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"

fails=0
bad() { echo "  FAILED: $*"; fails=$((fails+1)); }

# ---------------------------------------------------------------- 1. parse
for f in "$TT_ROOT"/lib/*.sh; do
  bash -n "$f" 2>/dev/null || bad "$(basename "$f") does not parse"
done
echo "  $(ls "$TT_ROOT"/lib/*.sh | wc -l | tr -d ' ') librar(y/ies) parse"

# ------------------------------------------------- 2. source cleanly under set -u
# Sourced in a subshell so a failure here cannot take this script with it.
for f in "$TT_ROOT"/lib/*.sh; do
  b="$(basename "$f")"
  [ "$b" = "_login.sh" ] && continue          # the base every other lib needs
  out="$(bash -c "set -u; source '$TT_ROOT/lib/_login.sh' >/dev/null 2>&1; source '$f'" 2>&1)"
  if [ -n "$out" ]; then
    bad "$b produced output or errors when sourced: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
  fi
done

# ------------------------------------- 3. the definitions the helpers depend on
# One line per "library : variable it reads". Add to this when a helper starts
# depending on a new module-level definition.
CONTRACT="
_tt683.sh:TT683_PROCESS_TARGET
_tt683.sh:TT683_E2E_CONSULTANTS
_tt683.sh:TT683_TAB_TOPROCESS
_tt683.sh:TT683_ZIP_STATE
_tt683.sh:TT683_ZIPREPORT
_tt654.sh:TT654_PROJECT_CUSTOMER
_tt654.sh:TT654_PROJECT_MANAGER
_tt654.sh:TT654_PROJECT_LINEITEMS
_tt654.sh:TT654_CONSULTANT
_tt654.sh:TT654_ROWS
_tt647.sh:TT647_TAB_TOPROCESS
_tt647.sh:TT647_TAB_MANAGER
_tt647.sh:TT647_TAB_CLIENT
_login.sh:TT_BASE
_login.sh:TT_DIALOG_SEL
"
checked=0
while IFS=: read -r lib var; do
  [ -n "$lib" ] || continue
  [ -f "$TT_ROOT/lib/$lib" ] || { bad "contract names $lib, which does not exist"; continue; }
  if ! bash -c "set -u; source '$TT_ROOT/lib/_login.sh' >/dev/null 2>&1; source '$TT_ROOT/lib/$lib' >/dev/null 2>&1; printf '%s' \"\${$var}\"" >/dev/null 2>&1; then
    bad "$lib does not define $var (a helper in it reads that variable)"
  else
    checked=$((checked+1))
  fi
done <<EOF
$CONTRACT
EOF
echo "  $checked declared variable(s) present"

# ------------------------------------------------ 4. the reporter is executable
[ -f "$TT_ROOT/tools/zipreport.py" ] \
  || bad "tools/zipreport.py is missing — lib/_tt683.sh calls it to read the export archive"

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-lib-contract — $fails library contract violation(s)."
  exit 1
fi

echo "PASS: verify-lib-contract — every library parses, sources cleanly under set -u, and defines what its helpers read"
