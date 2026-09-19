# Titan Time — E2E test suite

Playwright end-to-end tests for the Titan Time Mendix app, and **the single source of truth for
this suite** — the model repo's manual no longer describes it.

**This is its own Git repository** (`JoshNorris-Titan/titan-time-e2e`), and since 2026-09-08 it sits
**outside** the Mendix working copy at `C:\Users\Josh\Mendix\Titan Time\tests` — beside `main\` and
`ui\`, not inside one, with its own branches, `main` and PRs. Nothing about the model repo's rules
carries into it. That repo still gitignores `/tests/`, which is now a no-op, and a relative
`tests/…` path from the model checkout resolves to nothing — use the absolute path.

## Committing

**You may commit, push and open PRs here** — the Team Server ban applies to the *model*, not to this
repo. Address it explicitly; a bare `git` from the workspace root is the model repo:

```bash
git -C "C:/Users/Josh/Mendix/Titan Time/tests" add <your files>
git -C "C:/Users/Josh/Mendix/Titan Time/tests" commit -m "..."
git -C "C:/Users/Josh/Mendix/Titan Time/tests" push -u origin <branch>
gh pr create --repo JoshNorris-Titan/titan-time-e2e
```

**What the guard hook enforces** (`guard-git.py`, which replaced a regex on 2026-09-08): it decides
from the **resolved target**, not the shape of the flags. A repo whose git root holds a `*.mpr` is a
**model repo** — read-only git only, on every branch. Every other repo, this one included, may commit
and push freely. **No** repo may run the work-destroying forms — `reset --hard`, `checkout -- .`,
`restore .`, `clean -fd`, `stash drop/clear` (the autofix ledger records `reset --hard origin/main`
destroying uncommitted work here; an unstaged change is in no object store, so nothing recovers it).
It fails **closed**: git it cannot parse, or git reached through `bash -c` / `xargs`, is refused.

`git -C <path>` is **not** an exemption and must never be treated as one. It used to be, and that was
a verified hole — one `-C` anywhere in the payload, including the free-text `description`, disabled
the block for the whole call. `-C` is now the normal way to name a repo, not a signal.

**Start from an up-to-date `main`, always.** `fetch origin`, then cut a small branch (`fix/…`,
`ci/…`, `docs/…`) from `origin/main` — never from whatever branch is checked out; rebase an existing
branch onto `origin/main` first. Several small PRs land here a day, so a stale tip means re-fixing
yesterday's work. The working tree also usually carries unrelated edits of Josh's: **stage only your
own files**, and leave a checkout-blocking file alone until you have checked whether `origin/main`
already has that exact content — often it does.

## Running

```bash
./run-tests.sh --base-url https://titantime100-development.mendixcloud.com   # whole suite
./run-tests.sh suites/10-smoke/verify-smoke-login.test.sh   # one script
./run-tests.sh suites/30-approval                        # one suite folder
./run-tests.sh --list                                    # no target needed
./run-tests.sh --no-fail-fast                            # don't stop at the first failure
TT_BASE_URL=https://titantime100-development.mendixcloud.com ./run-tests.sh --skip-file ci-skip.txt
```

**NEVER run this suite against Josh's local F5 app.** Its user accounts are completely different, so
a local run is not a weaker test but a *meaningless* one — and it still **writes**, deleting the e2e
consultants' timesheets, assignments and projects and provisioning them again, in a database these
tests were never written for. Since 2026-09-06 the bookend clear takes structure with it, so a
misdirected run destroys **projects**, not just timesheet rows. Always pass an explicit deployed
`--base-url` (cloud dev, `titantime100-development.mendixcloud.com`); the localhost defaults in
`run-tests.sh` and `lib/_login.sh` are wrong for this suite. **Nothing checks the target for you** —
the old wrapper `main\.claude\tools\e2e-local.sh` exits 3 unconditionally since the move (it
resolves the suite *and* the env file under `$ROOT/tests/`, and `TT_E2E_ROOT` overrides only the
suite path). Until an equivalent guard is committed *inside this repo*, that flag is the whole guard.

**The target is never implied.** With neither `TT_BASE_URL` nor `--base-url` the runner exits 2
rather than guessing — this suite writes data, and a wrong guess is indistinguishable from
environment drift in the output.

**Fail-fast is on by default.** The first `FAIL` stops the run; only `suites/99-teardown/` still
executes, so the environment is cleaned and the browser session closed. Remaining steps report
`NOTRUN` — a downstream step running against the state a failed step left behind produces noise that
reads like signal, and it keeps *writing*.

**`run-tests.sh` replaced `mxcli playwright verify`** (a Windows-only binary that could never run in
CI); the suite is driven by `playwright-cli` (npm `@playwright/cli`) on any platform, and spec and
seeder header comments still naming the old runner are stale prose, not live usage. It opens **one
shared `playwright-cli` session** for the whole run — scripts call bare `playwright-cli` with no
`-s=` flag and rely on login in one script persisting into the next. Always run **through the
runner**: a direct spec run skips `00-setup`'s data clear, and discovery is sorted because run order
is load-bearing.

**Preconditions:** the suite drives a *running deployed* app, so a model change says nothing here
until it is saved, committed **and deployed**. Ctrl+S and F5 build the local app you must not test.

## When a test fails

**Investigate first.** Read the spec, read the helper it calls, and **prove the cause against the
running app** rather than reasoning from the script. Most failures here have turned out to be test
defects wearing a product bug's clothes (a dead dialog node, a filter left set on a tab, a seed that
silently did nothing). "The app is broken" is a conclusion you earn with evidence. Then:

- **Fix entirely in this repo** — test, helper, fixture, selector, wait: fix it, verify against the
  running app, commit, push, open the PR. **No gates, no stopping to ask** — a standing opt-out from
  the six-gate workflow in `..\main\CLAUDE.md`. Report what you found and changed when done.
- **It points at the Mendix model** — the app really is wrong, or the fix belongs in the model:
  **stop and enter the gates at Gate 1.** The e2e changes that go with it are part of that change.
- **You cannot tell** which it is: that is a model-side answer. Gate 1.

## CI and the autofix loop

Workflow `e2e.yml` runs nightly at 02:00 CT (two cron entries plus a gate job, because GitHub cron is
UTC-only) and on demand, against cloud dev. **`/e2e-autofix` babysits it**, and under
`/loop /e2e-autofix` unattended: read the latest run, and if it is red for a **test-side** reason,
diagnose, reproduce locally against the same environment, fix, prove red-to-green, open the PR,
**merge it**, re-dispatch. Procedure: `..\main\.claude\skills\e2e-autofix\SKILL.md`.

- **It ends the loop and notifies Josh** instead of fixing whenever the failure points at the
  **model**, cannot be reproduced, would need a change to `.github/workflows/` or `run-tests.sh`, is
  the *same spec* it already fixed once this loop, or could only be made green by weakening the suite
  (deleting a test, adding to `ci-skip.txt`, loosening an assertion, `|| true`, a blind timeout bump).
- **Budget:** 12 autonomous merges per loop session, one dispatch per iteration; a green run is
  ~90 minutes against a 210-minute ceiling.

`main` here has **no branch protection**, so nothing downstream reviews those merges — the rails and
the PR body (run URL, quoted cause, local red-to-green evidence) are the whole audit trail. Loop
memory across a `/clear`: `C:\Users\Josh\titan-agentic-config\e2e-autofix\ledger.md`. Local repro
needs `.e2e-autofix.env` (gitignored, present here, same values as the Actions secrets) — but with
`e2e-local.sh` dead the loop must escalate rather than push a fix it never ran.

## Conventions

- **Layout:** `suites/<NN-area>/`, the numeric prefix being run order — `00-setup` → `10-smoke` →
  `20-consultant` → `30-approval` → `40-hr` → `50-titan-manager` → `60-email` →
  `70-tickets/<ticket>/` → `75-export` → `76-bulk` → `80-platform` → `85-security` → `99-teardown`.
  New tests go in the area they exercise, ticket regressions in `70-tickets/tt<ticket>/`. `lib/` holds
  shared helpers, `seeders/` the destructive data builders (the runner matches only
  `verify-*.test.sh`, so it never picks them up).
- **Inside `00-setup` the order is clear → build → seed**, numbered, not accidental:
  `verify-000-testdata-clear-before` deletes everything, `verify-001-fixtures` rebuilds projects and
  assignments from `FX_PROJECTS` / `FX_ASSIGNMENTS`, `verify-002-seed-isolation-control` seeds the
  isolation test's control rows. This inverted on 2026-09-06 when the clear stopped preserving
  structure — anything still claiming structure survives the clear is stale.
- **Paths:** a test resolves its root by walking up to the directory containing `lib/`:
  `TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"`
  then `source "$TT_ROOT/lib/_login.sh"`. Depth-independent, and keeps a test runnable without the
  runner. Copy that pattern into any new test.
- **Naming:** `verify-<slug>.test.sh`; ticket work `verify-tt<ticket>-<case>.test.sh`. `ci-skip.txt`
  keys on the **basename**, so re-filing a test elsewhere does not invalidate a skip entry.
- **Selectors:** `.mx-name-*` only — Mendix generates that class from a widget's *Name*, so it is a
  contract you control from the model, not a styling class. Auto-generated names (`textBox1`,
  `dataView2`) renumber as pages are edited and must never be used; name the widget in Studio Pro
  instead. Prefer scoping over structural chaining: `.mx-name-Grid` + `getByRole('row')` survives a
  redesign, `div > div:nth-child(3)` does not.
- **Login:** `source "$(dirname "$0")/lib/_login.sh"` then `tt_login "$USER" "<landing text>"`. It
  handles both the legacy `/login.html` form and the custom `Core.Login` page; forms login is the
  app's only auth path, so the same test runs local / dev / acceptance.
- **Test data:** the bookend clear scripts reset only the consultants in `TT_E2E_CONSULTANTS` — never
  assert an unconstrained count. They run the **deep** per-consultant control, which also deletes
  those consultants' assignments and the projects those were on, so a run starts from no structure
  and `verify-001-fixtures` builds what it needs. Two consequences: deleting a project cascades into
  *other* consultants' assignments on it (accepted — see `lib/_testdata.sh`), and a finished run
  leaves **no E2E projects at all**, so a single spec run after a completed suite finds nothing until
  `00-setup` runs again.

## Environment

| Variable | Purpose |
|---|---|
| `TT_BASE_URL` | App origin, no trailing slash. **Required — no default.** The runner used to fall back to `http://localhost:8080` and export it, which silently satisfied the explicit-target guard in `lib/_fixtures.sh` — a run meant for dev hit a local F5 app and read as dev drift. |
| `TT_ADMIN_USER` / `TT_ADMIN_PASS` | Admin account |
| `TT_ROLE_PASS` | Password for the `e2e_*` role accounts |
| `TT_E2E_CONSULTANTS` | Which consultants the clear scripts reset |
| `TT_E2E_CLEAR_DEPTH` | `deep` (default) also deletes their assignments and the projects those were on; `shallow` is the old transactional-only clear. No automatic fallback — against an environment predating the deep control the clear fails and names the reason, because a silent downgrade would leave structure in place and still report green |

In CI these come from GitHub Actions secrets; the defaults in `lib/_login.sh` are for local
convenience only. The `e2e_*` role account credentials are in the archived `FINDINGS.md` at
`C:\Users\Josh\titan-agentic-config\archive\plans-2026-07-30\`.

## Two traps that have already bitten this suite

1. **The eval/grep false pass.** `playwright-cli eval "…return 'ok'" | grep -qiw ok` matches the
   *echoed source line*, not the result — so the assertion passes no matter what the page does.
   Decode with the `_tt_eval_str` helper in `lib/_login.sh` instead of grepping raw output. Guarded
   by `suites/80-platform/verify-no-echo-trap.test.sh`, which fails the run on any new occurrence.
2. **Assertions that cannot fail.** The suite has never had a recorded green run. Treat an unexpected
   PASS as suspicious until the assertion has been proven able to fail — break it deliberately and
   confirm the test goes red. `suites/10-smoke/verify-helper-selftest.test.sh` asserts that property
   for the shared helpers on every run, and `run-tests.sh --expect-count N` keeps the *run itself*
   honest when tests vanish from discovery. Neither substitutes for breaking a new assertion on
   purpose.
