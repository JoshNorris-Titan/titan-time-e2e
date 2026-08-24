#!/usr/bin/env bash
# Tier 0 smoke test — portable forms login.
#
# Logs in as the admin LOCAL account via the standard Mendix /login.html page and
# asserts landing on the Admin Hub homepage. This deliberately uses forms login
# (stable IDs #usernameInput / #passwordInput / #loginButton) rather than the
# local dev demo-user picker or cloud OIDC, so the SAME test runs against local,
# dev, and acceptance — only the env vars change.
#
# Environment (override per env; localhost defaults for a local Studio Pro run):
#   TT_BASE_URL    app origin (no trailing slash), e.g.
#                  https://titantime100-development.mendixcloud.com
#   TT_ADMIN_USER  admin username (default: MxAdmin)
#   TT_ADMIN_PASS  admin password
#
# The runner (`mxcli playwright verify`) already opened a shared browser session;
# this script drives it with plain playwright-cli commands and asserts via
# `eval` + `grep` so failures produce a non-zero exit the runner reports as FAIL.
set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"

USER="${TT_ADMIN_USER:-MxAdmin}"
PASS="${TT_ADMIN_PASS:-AdminPassword1!}"

# tt_login handles both the legacy /login.html form and the current custom
# Core.Login page, logs out any prior session, and asserts the landing text.
# (Third arg overrides the default e2e password with the admin password.)
tt_login "$USER" "Admin Hub" "$PASS"

echo "PASS: verify-smoke-login — logged in as $USER on $TT_BASE, landed on Admin Hub"
