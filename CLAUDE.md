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
./run-tests.sh --base-url http://localhost:8080          # whole suite, local F5
./run-tests.sh suites/10-smoke/verify-smoke-login.test.sh   # one script
./run-tests.sh suites/30-approval                        # one suite folder
./run-tests.sh --list                                    # no target needed
./run-tests.sh --no-fail-fast                            # don't stop at the first failure
TT_BASE_URL=https://titantime100-development.mendixcloud.com ./run-tests.sh --skip-file ci-skip.txt
```

**The target is never implied.** With neither `TT_BASE_URL` nor `--base-url`, the runner exits 2
rather than guessing — this suite writes data, and a wrong guess is indistinguishable from
environment drift in the output.

**Fail-fast is on by default.** The first `FAIL` stops the run; only `suites/99-teardown/`
still executes, so the environment is cleaned and the browser session closed. Remaining steps
report as `NOTRUN` and the summary says what never ran — a downstream step running against the
state a failed step left behind produces noise that reads like signal, and it keeps *writing*.
Use `--no-fail-fast` when you deliberately want the full picture.

`run-tests.sh` replaced `mxcli playwright verify` (a Windows-only binary that could never run in
CI). It opens **one shared `playwright-cli` session** for the whole run and closes it at the end
— scripts call bare `playwright-cli` with no `-s=` flag and rely on login in one script
persisting into the next. Run order is load-bearing: `verify-000-testdata-clear-before` and
`verify-zzz-testdata-clear-after` bookend the suite, so discovery is always sorted.

**Preconditions:** the suite drives a *running* app. Locally that means Josh presses Ctrl+S then
F5 first — tests written against unsaved model changes test the previous build.

## The autofix loop

`.github/workflows/e2e.yml` runs this suite nightly at 02:00 CT against cloud dev. The model
repo's `/e2e-autofix` skill watches those runs and, under `/loop`, fixes test-side failures here
autonomously — branch, fix, prove locally, PR, squash-merge, re-dispatch — with no human gate.

Two things that constrains here:

- **Local reproduction is mandatory before any of its PRs.** It uses
  `../.claude/tools/e2e-local.sh --repro <spec>`, which sources `.e2e-autofix.env` (gitignored;
  copy `.e2e-autofix.env.example`) so the repro hits the same origin CI used, and always runs
  `suites/00-setup` first.
- **It may never turn a red test green by weakening it.** Deleting a test, an entry in
  `ci-skip.txt`, a loosened assertion, `|| true`, or a timeout bump with no evidence are all
  escalations to Josh, as is any change to `.github/workflows/` or `run-tests.sh`. The rails are
  in `.claude/skills/e2e-autofix/SKILL.md` in the model repo.

## `manual-env/` — the human review environment

`manual-env/` is **not part of the suite**. It provisions a parallel `Manual *` data set
(accounts, projects, assignments, timesheets in every status) for a person to review dev
against, because the e2e bookends delete the `E2E *` data at both ends of every run and so
it is never there when someone opens the app.

`run-tests.sh` discovers only under `suites/` when given no target, so nothing here is
ever picked up by the nightly. Its steps are still named `verify-*.test.sh` so they can
reuse the runner's shared session, per-step timeouts and failure screenshots:

```bash
manual-env/provision-accounts.sh      # ONCE: create the seven manual_* logins
./run-tests.sh manual-env/build       # accounts check -> structure -> timesheet ladder
./run-tests.sh manual-env/teardown    # delete everything but the accounts
```

Two GitHub workflows dispatch the two `run-tests.sh` commands (*Manual env — build* /
*— teardown*). The provisioner is deliberately not one of them: it creates credentials,
nothing ever deletes them, and both workflows assume the accounts outlive them.

**Never hunt for an account's password by trying logins.** Mendix blocks an account after
a few failed attempts, and a blocked account answers "Invalid Credentials" to everything —
indistinguishable from a wrong password. The provisioner sets a known password as the
administrator instead (Accounts Overview → Edit Account → Change password), and re-running
its `stage` phase is what clears the Blocked flag.

The one rule that keeps the two data sets from destroying each other: **a Manual
consultant must never be assigned to an E2E project, and vice versa** — the deep clear
follows a consultant's assignments into the projects behind them, which is the only way
either set can reach the other. See `manual-env/README.md`.

## `password-refresh/` — stopping the logins ageing into a forced reset

Also **not part of the suite**. Once a week it sets every `e2e_*` and `manual_*` account's
password away and straight back, as the administrator, through Accounts Overview → Edit
Account → Change password:

```bash
./run-tests.sh password-refresh --expect-count 2
```

**The password does not change** — each account ends on the value it started on, so no
secret needs updating afterwards. It is a keep-alive, not a rotation.

Two things worth knowing before touching it:

- **The roster is an allowlist, and that is the point.** Dev carries plenty of real
  people's logins alongside the test ones. Nothing here reads the grid for candidates; it
  acts on the names in `refresh.env.sh` and nothing else. `MxAdmin` is deliberately
  excluded — it is the credential the job authenticates *with*.
- **`verify-zzz-password-verify` is the step that proves anything.** An administrator
  setting someone else's password cannot tell whether the account can use it, so the churn
  step only reports that each submit was accepted. The sign-in step carries the
  `verify-zzz-` prefix so it runs even after the churn fails, which is the run where its
  answer matters most.

`lib/_accounts.sh` holds the measured facts about that admin surface.
`manual-env/provision-accounts.sh` still carries its own copies of the same primitives —
they were mid-rework when the library was extracted, so both exist on purpose and the
library's functions are all `acct_`-prefixed. Converge them when that rework settles.

Full detail, including how to recover an account left on a throwaway password:
`password-refresh/README.md`.

## Conventions

- **Layout:** tests live under `suites/<NN-area>/`. The numeric prefix is the run order —
  `00-setup` (clear, then build) → `10-smoke` → `20-consultant` → `30-approval` → `40-hr` →
  `50-titan-manager` → `60-email` → `70-tickets/<ticket>/` → `80-platform` → `99-teardown`.
  Put a new test in the area it exercises; ticket-specific regressions go in
  `70-tickets/tt<ticket>/`. `lib/` holds shared helpers, `seeders/` the destructive data
  builders (never picked up by the runner, which only matches `verify-*.test.sh`).
- **Inside `00-setup` the order is clear → build → seed**, and it is numbered, not accidental:
  `verify-000-testdata-clear-before` deletes everything, `verify-001-fixtures` rebuilds the
  projects and assignments from `FX_PROJECTS` / `FX_ASSIGNMENTS`, `verify-002-seed-isolation-control`
  seeds the entry rows the isolation test needs as its control. This inverted on 2026-09-06:
  the clear used to preserve structure, so the fixture step deliberately sorted *ahead* of it
  (exploiting `-` < `0` under `LC_ALL=C`, when it was named `verify-00-fixtures`). Anything
  that still claims structure survives the clear is stale.
- **Paths:** a test resolves its root by walking up to the directory containing `lib/`:
  `TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"`
  then `source "$TT_ROOT/lib/_login.sh"`. Depth-independent, and keeps a test directly runnable
  without the runner. Copy that pattern into any new test.
- **Naming:** `verify-<slug>.test.sh`; ticket work uses `verify-tt<ticket>-<case>.test.sh`.
  `ci-skip.txt` keys on the **basename**, so re-filing a test into another folder does not
  invalidate a skip entry.
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
  They now run the **deep** per-consultant control, which also deletes those consultants'
  assignments and the projects those assignments were on, so a run starts from no structure and
  `verify-001-fixtures` builds what it needs. Two consequences worth holding on to: deleting a
  project cascades into *other* consultants' assignments on it (accepted — see
  `lib/_testdata.sh`), and a finished run leaves the environment with **no E2E projects at all**,
  so a single spec run after a completed suite finds nothing until `00-setup` runs again.

## Environment

| Variable | Purpose |
|---|---|
| `TT_BASE_URL` | App origin, no trailing slash. **Required — no default.** `run-tests.sh` used to fall back to `http://localhost:8080` and export it, which silently satisfied the explicit-target guard in `lib/_fixtures.sh`; a run meant for dev went to a local F5 app and its fixture report was read as dev drift. Pass `--base-url` or set this. |
| `TT_ADMIN_USER` / `TT_ADMIN_PASS` | Admin account |
| `TT_ROLE_PASS` | Password for the `e2e_*` role accounts |
| `TT_E2E_CONSULTANTS` | Which consultants the clear scripts reset |
| `TT_E2E_CLEAR_DEPTH` | `deep` (default) also deletes their assignments and the projects those were on; `shallow` is the old transactional-only clear. No automatic fallback — against an environment that predates the deep control the clear fails and names the reason, because a silent downgrade would leave structure in place and still report green |

In CI these come from GitHub Actions secrets. The defaults baked into `lib/_login.sh` are for
local convenience only and must never be relied on against a deployed environment.

## Two traps that have already bitten this suite

1. **The eval/grep false pass.** `playwright-cli eval "…return 'ok'" | grep -qiw ok` matches the
   *echoed source line*, not the result — so the assertion passes no matter what the page does.
   Decode with the `_tt_eval_str` helper in `lib/_login.sh` instead of grepping raw output.
   Guarded by `suites/80-platform/verify-no-echo-trap.test.sh`, which fails the run on any new
   occurrence and needs no browser.
2. **Assertions that cannot fail.** The suite has never had a recorded green run. Treat an
   unexpected PASS as suspicious until the assertion has been proven able to fail — break it
   deliberately and confirm the test goes red.
   `suites/10-smoke/verify-helper-selftest.test.sh` asserts that property for the shared helpers
   on every run, and `run-tests.sh --expect-count N` keeps the *run itself* honest when tests
   vanish from discovery. Neither substitutes for breaking a new assertion on purpose.
