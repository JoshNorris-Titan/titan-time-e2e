#!/usr/bin/env bash
# Shared helpers for Titan Time E2E tests. Source it from a *.test.sh:
#   source "$(dirname "$0")/lib/_login.sh"
#
# Provides:
#   tt_login <username> <ready-text>   forms-login via /login.html, wait for <ready-text> on the dashboard
#   tt_assert_all <label> <text>...    fail unless ALL <text> substrings are present in document.body
#   tt_fail <msg>                      print FAIL and exit 1
#   ...and the gallery, combobox, week, approval-token and mail surfaces - see the parts below.
#
# This file lives in tests/lib/ (not a *.test.sh) so the runner does not execute
# it as a test. Uses forms login (stable IDs) so it is portable across envs.
#
# Env:
#   TT_BASE_URL   app origin (no trailing slash; default http://localhost:8080)
#   TT_ROLE_PASS  password for the e2e_* role accounts. REQUIRED off localhost;
#                 the built-in default is a localhost-only convenience.
#
# ---------------------------------------------------------------------------
# THIS FILE IS NOW AN AGGREGATOR (2026-09-17).
#
# It was 2,068 lines and 70 functions under a name that promised login. What was
# actually in here: dialog handling, week identity, gallery paging, combobox
# helpers, HR tab state, the whole approval-token surface and the whole mail-reading
# surface. It is the most-sourced file in the suite - 88 of 99 tests begin by
# sourcing it - so its shape is the first thing anyone extending the suite has to
# understand, and understanding it meant reading two thousand lines under a
# misleading title.
#
# NOTHING MOVED RELATIVE TO ANYTHING ELSE. The parts are contiguous positional
# slices of the original file, sourced below in their original order, so the
# resulting definitions are identical to what a single file produced. That is not a
# claim, it is how the split was made and checked: concatenating the parts (each
# minus its own header) reproduces the pre-split file byte for byte.
#
# CALL SITES DID NOT CHANGE. `source .../lib/_login.sh` still does exactly what it
# did. Do not source a part directly - several depend on names an earlier part
# defines, and the parts are slices, not modules.
#
# Boundaries follow the file's own `# ---` banners, so no function is cut in half.
# _login_assert.sh is nine lines; it is its own file because the split is positional
# and that is where tt_assert_all sits. Resist tidying that by moving code between
# parts - the byte-for-byte property is the only reason this refactor is safe to
# take without a full suite run, and it dies the moment anything is reordered.
# ---------------------------------------------------------------------------

# Resolve this file's own directory rather than trusting the caller's $PWD or a
# relative path: tests source this from any nesting depth under suites/, and the
# runner also runs single specs from the repo root.
_TT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Order is load-bearing. These are slices of one file, not independent modules.
# shellcheck source=/dev/null
source "$_TT_LIB_DIR/_login_core.sh"
# shellcheck source=/dev/null
source "$_TT_LIB_DIR/_login_waits.sh"
# shellcheck source=/dev/null
source "$_TT_LIB_DIR/_login_auth.sh"
# shellcheck source=/dev/null
source "$_TT_LIB_DIR/_login_assert.sh"
# shellcheck source=/dev/null
source "$_TT_LIB_DIR/_login_gallery.sh"
# shellcheck source=/dev/null
source "$_TT_LIB_DIR/_login_tokens.sh"
# shellcheck source=/dev/null
source "$_TT_LIB_DIR/_login_mail.sh"
