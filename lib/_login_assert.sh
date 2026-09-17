#!/usr/bin/env bash
# _login_assert.sh — part of the lib/_login.sh split (2026-09-17).
#
# tt_assert_all. Small, and deliberately its own file rather than folded into a
# neighbour: the split is positional so the result can be proven identical to
# the original, and this is where it sits.
#
# DO NOT SOURCE THIS DIRECTLY. Source lib/_login.sh, which sources every part in
# order; the parts are positional slices of one file and several depend on names
# defined in an earlier one. Sourcing lib/_login.sh is exactly what it always was.
#
# This file is lines 937-945 of the pre-split lib/_login.sh, verbatim. Everything
# below the next line is unchanged, which is how the split was verified.
# --- begin verbatim slice of the original lib/_login.sh ---
tt_assert_all() {
  local label="$1"; shift
  local s
  for s in "$@"; do
    playwright-cli eval "() => String(document.body.innerText.indexOf('$s') >= 0)" 2>/dev/null | grep -qiw true \
      || tt_fail "$label: expected text not found: '$s'"
  done
}
