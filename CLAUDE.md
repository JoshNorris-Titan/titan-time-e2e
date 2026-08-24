# Titan Time — E2E test suite

Playwright end-to-end tests for the Titan Time Mendix app. **This directory is its own Git
repository** (remote: `titan-time-e2e` on GitHub), nested inside the Mendix working copy at
`C:\Users\Josh\Mendix\Titan Time-main\tests`. The parent repo ignores it (`.gitignore:45`), so
Studio Pro and Team Server never see these files.

## Committing

Unlike the Mendix working copy, **you may commit and push here.** Always address it explicitly
so the parent repo's guard hook stays out of the way:

```bash
git -C tests add -A
git -C tests commit -m "..."
git -C tests push
```

`git -C <path>` is exempt from `guard-exec.sh`'s commit/push block. Never run a bare `git
commit` from the project root — that targets the Mendix model and is blocked for good reason.

## Running

```bash
./run-tests.sh                              # whole suite, localhost
./run-tests.sh verify-smoke-login.test.sh   # one script
./run-tests.sh --list
TT_BASE_URL=https://titantime100-development.mendixcloud.com ./run-tests.sh --skip-file ci-skip.txt
```

`run-tests.sh` replaced `mxcli playwright verify` (a Windows-only binary that could never run in
CI). It opens **one shared `playwright-cli` session** for the whole run and closes it at the end
— scripts call bare `playwright-cli` with no `-s=` flag and rely on login in one script
persisting into the next. Run order is load-bearing: `verify-000-testdata-clear-before` and
`verify-zzz-testdata-clear-after` bookend the suite, so discovery is always sorted.

**Preconditions:** the suite drives a *running* app. Locally that means Josh presses Ctrl+S then
F5 first — tests written against unsaved model changes test the previous build.

## Conventions

- **Naming:** `verify-<slug>.test.sh`; ticket work uses `verify-tt<ticket>-<case>.test.sh`.
- **Selectors:** `.mx-name-*` only. Mendix generates that class from a widget's *Name* property,
  so it is a contract you control from the model — not a styling class. Auto-generated names
  (`textBox1`, `dataView2`) renumber as pages are edited and must never be used; the fix is to
  name the widget in Studio Pro. Prefer scoping over structural chaining:
  `.mx-name-Grid` + `getByRole('row')` survives a redesign, `div > div:nth-child(3)` does not.
- **Login:** `source "$(dirname "$0")/lib/_login.sh"` then `tt_login "$USER" "<landing text>"`.
  It handles both the legacy `/login.html` form and the custom `Core.Login` page. Forms login is
  the app's only auth path, so the same test runs local / dev / acceptance.
- **Test data:** the bookend clear scripts reset only the consultants named in
  `TT_E2E_CONSULTANTS`. Never assert an unconstrained count — own the data you assert on.

## Environment

| Variable | Purpose |
|---|---|
| `TT_BASE_URL` | App origin, no trailing slash (default `http://localhost:8080`) |
| `TT_ADMIN_USER` / `TT_ADMIN_PASS` | Admin account |
| `TT_ROLE_PASS` | Password for the `e2e_*` role accounts |
| `TT_E2E_CONSULTANTS` | Which consultants the clear scripts reset |

In CI these come from GitHub Actions secrets. The defaults baked into `lib/_login.sh` are for
local convenience only and must never be relied on against a deployed environment.

## Two traps that have already bitten this suite

1. **The eval/grep false pass.** `playwright-cli eval "…return 'ok'" | grep -qiw ok` matches the
   *echoed source line*, not the result — so the assertion passes no matter what the page does.
   Decode with the `_tt_eval_str` helper in `lib/_login.sh` instead of grepping raw output.
2. **Assertions that cannot fail.** An audit found roughly 16 of them, and the suite has never
   had a recorded green run. Treat an unexpected PASS as suspicious until the assertion has been
   proven able to fail — break it deliberately and confirm the test goes red.
