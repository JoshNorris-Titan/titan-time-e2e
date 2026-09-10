# The Manual review environment

A second, human-owned copy of the E2E data set — same shape, `Manual ` prefix instead of
`E2E ` — provisioned on cloud dev for Rishika's dev review.

## Why it exists

The e2e suite's bookends **delete** the `E2E *` data at both ends of a run. A finished
nightly leaves dev with no E2E projects, assignments or timesheets at all, by design
(`suites/99-teardown`, `lib/_testdata.sh`). So the e2e data is never there when a person
opens the app to look at something — it exists only for the ~90 minutes a run is using it.

This directory builds a parallel set that nothing deletes on a timer. Two workflows drive
it: one creates everything, one removes everything **except the accounts**.

## What it creates

| | |
|---|---|
| Projects | `Manual Manager Approval`, `Manual Customer Approval`, `Manual Dual Approval`, `Manual Line Items`, `Manual Sandbox` |
| Assignments | Manual Consultant → the first four; Manual Consultant Two → Sandbox |
| Timesheets | one week per stage, per consultant: Exported, AwaitingExport, ToProcess, AwaitingCustomerApproval, AwaitingManagerApproval, Rejected, Draft, and one empty week |
| Customer | **shared** with the E2E set (Costco). Customers are never deleted by any clear |
| Accounts | **not created here.** See below |

Every approval shape the product supports is represented, and every HR dashboard tab has
something on it — that is the point of seeding the ladder rather than a pile of drafts.

The whole set is declared in one file: [`manual.env.sh`](manual.env.sh). Change the tables
there, not in the steps.

## The accounts — provisioned once

| Login | Full name | Role | Employment | Lands on |
|---|---|---|---|---|
| `manual_consultant`  | Manual Consultant         | Consultant     | FullTime | My Timesheets |
| `manual_consultant2` | Manual Consultant Two     | Consultant     | FullTime | My Timesheets |
| `manual_consultant3` | Manual Consultant Three   | Consultant     | FullTime | My Timesheets |
| `manual_pm`          | Manual ProjectManager     | ProjectManager | FullTime | Project Manager Dashboard |
| `manual_pm2`         | Manual ProjectManager Two | ProjectManager | FullTime | Project Manager Dashboard |
| `manual_hr`          | Manual HR                 | HR             | FullTime | WEEKLY TO PROCESS |
| `manual_tm`          | Manual TitanManager       | TitanManager   | FullTime | Add Customer |

One role each, mirroring the `e2e_*` accounts exactly — every one of those was verified to
be a single-role FullTime account. Each gets its own plus-address,
`jnorris+<username>@titanconsulting.net`, unlike the e2e set which shares one; that keeps
any mail the app sends a Manual user identifiable in the inbox.

**Employment status is not cosmetic.** Full-time consultants are warned when they log under
40 hours in a week and contract staff never are, so mirroring `FullTime` is what makes a
Manual week behave like an E2E one.

### Run the provisioner

```bash
TT_BASE_URL=https://titantime100-development.mendixcloud.com \
TT_ADMIN_USER=MxAdmin TT_ADMIN_PASS=... TT_ROLE_PASS=... \
  manual-env/provision-accounts.sh
```

Four phases, each separately runnable via `MANUAL_PHASES`, and all idempotent:

| Phase | As | What |
|---|---|---|
| `create` | administrator | creates any missing account on `Core.Account_New` |
| `stage`  | administrator | clears the Blocked flag if set, then sets a **staging** password |
| `reset`  | the account   | completes the forced reset from staging → `TT_ROLE_PASS` |
| `verify` | each account  | signs in normally and lands on its role's dashboard |

`MANUAL_ONLY=manual_hr` does one account; `MANUAL_DRY_RUN=1` drives the whole form and
cancels instead of saving.

### Why a staging password rather than the mailed one

The route a person follows is: `Account_New` asks for no password, autogenerates one, mails
it as *Welcome to the Titan Timesheet App*, and flags the account to reset on first login;
you read it from Admin Hub → **Emails Sent** (the Body column shows it) and complete the
reset by hand. The script deliberately does **not** do that. Three reasons, all measured
while building it:

1. `Core.Force_PasswordReset` refuses *"Your new password must be different from your
   current password"* — so the mailed password can never be reset **to** `TT_ROLE_PASS`
   directly. Something has to sit in between either way.
2. A wrong guess at the mailed password costs a **failed login**, and Mendix blocks the
   account after a few. That is not theoretical: `manual_consultant` ended up
   `Blocked=true` during development, and a blocked account answers *"Invalid Credentials"*
   to every password — indistinguishable from a wrong one.
3. The welcome mail is sent once. Reading it later depends on the row still being in the
   grid, and re-issuing it means driving **Force Reset Password**.

The administrator's own **Change password** action on `Administration.Account_Edit` sets a
password with no old password and no mail. So the script stages a known value there and
lets the account complete its own reset. The staging password is *derived* from
`TT_ROLE_PASS`, so `reset` can be re-run without anything having been written down —
nothing is ever persisted to disk.

If an account does get blocked, re-run the `stage` phase: it clears the flag.

### Never touched by anything else

Neither workflow creates or deletes an account — both are built on the accounts outliving
them. `manual-env/build/verify-100-manual-accounts.test.sh` is the check: it signs in as
all seven and fails naming any that cannot, pointing at the provisioner. It is red until
provisioning has run — that is its job.

## Running it

**From GitHub** — Actions → *Manual env — build* → Run workflow. The teardown is
*Manual env — teardown*, and it requires you to type `DELETE` in the confirm box.

**Locally**, from `tests/`:

```bash
export TT_BASE_URL=https://titantime100-development.mendixcloud.com
export TT_ADMIN_USER=... TT_ADMIN_PASS=... TT_ROLE_PASS=...

manual-env/provision-accounts.sh             # ONCE — the seven manual_* logins
./run-tests.sh manual-env/build              # accounts -> structure -> timesheets
./run-tests.sh manual-env/teardown           # delete everything but the accounts

./run-tests.sh manual-env/build/verify-110-manual-structure.test.sh   # one step
```

The target is never implied — `run-tests.sh` exits 2 rather than guessing, because all of
this writes.

**These steps are invisible to the e2e suite.** `run-tests.sh` discovers only under
`suites/` when given no target, so the nightly never picks them up; naming them
`verify-*.test.sh` anyway is what lets them reuse the runner's shared browser session,
per-step timeouts and failure screenshots.

The build is **idempotent**: re-running it creates only what is missing, and the seeder
skips weeks that are already submitted. Kicking it off again after a partial failure
resumes rather than duplicating.

## The one rule that keeps the two data sets apart

> A Manual consultant must never be assigned to an E2E project, and an E2E consultant must
> never be assigned to a Manual project.

The clear is per consultant, and at `deep` it deletes that consultant's assignments **and
the projects those assignments were on**. Since a project is not owned by a consultant,
that is the only way either clear can reach past its own names — through a shared project.

Keep `MANUAL_ASSIGNMENTS` pointing only at `MANUAL_PROJECTS` and it holds. If it is ever
broken, the symptom is a Manual environment that quietly empties itself overnight when the
e2e nightly tears down, and nothing will report why.

The teardown verifies its own blast radius afterwards: zero entries and assignments for
each Manual consultant, no `Manual ` projects left, and all seven accounts still standing.

## What it reuses, and how

Nothing here re-implements the app's quirks — it points the existing machinery at
different names.

| Reused | Pointed at Manual by |
|---|---|
| `lib/_fixtures.sh` (projects, assignments, drift reconciliation) | `manual_apply_fixture_overrides` swaps the `FX_*` tables; `FX_TM_USER` selects `manual_tm` |
| `lib/_testdata.sh` (the deep clear) | `TT_E2E_CONSULTANTS` set to the Manual consultant names |
| `seeders/seed-regression-ladder.sh` (the timesheet ladder) | `SEED_CONSULTANTS`, `SEED_NAMES`, `SEED_HR_USER` |
| `lib/_login.sh`'s `_tt_login_form_variant` + `_tt_login_submit` | the provisioner's `login_probe`, which needs the *outcome* (including "a reset is demanded") where `tt_login` treats that as fatal |

Those 1,500-odd lines encode things that are true only of this app — the date picker that
ignores a DOM write, the customer-gates-project ordering on the assignment form, the
over-40 week that cannot be persisted at all, the popup that must be proven shut before
the next click lands. A Manual-only copy would start correct and drift the first time one
of them changed.

Three small changes were needed in the shared files to make that possible, all
default-preserving:

- `lib/_fixtures.sh` — `FX_TM_USER`, defaulting to `e2e_tm`.
- `seeders/seed-regression-ladder.sh` — `SEED_HR_USER`, defaulting to `e2e_hr`.
- `seeders/seed-regression-ladder.sh` — root resolution. It used `cd ../..` and
  `source tests/lib/_login.sh`, which assumed the suite was still nested inside the Mendix
  working copy; standalone (and in CI) that lands above the workspace and the seeder died
  on its first line. It now walks up to the directory holding `lib/`, like every test does.
  **`seed-shakedown.sh`, `seed-toprocess-entries.sh` and `verify-toprocess-count.sh` still
  have the old form and are still broken that way.**

## Env

| Variable | Purpose |
|---|---|
| `TT_BASE_URL` | Required. No default — everything here writes |
| `TT_ADMIN_USER` / `TT_ADMIN_PASS` | Admin, for the teardown's Test Data page |
| `TT_ROLE_PASS` | Password for the `manual_*` accounts, unless overridden |
| `TT_MANUAL_PASS` | Set only if the Manual accounts were given a *different* password |
| `MANUAL_PHASES` | Provisioner only: a subset of `create stage reset verify` |
| `MANUAL_ONLY` | Provisioner only: one username |
| `MANUAL_DRY_RUN=1` | Provisioner only: drive the form and cancel instead of saving |
| `MANUAL_ACCOUNT_EMAIL_TEMPLATE` | `printf` format for account addresses, `%s` = username |
| `MANUAL_CUSTOMER` | Owning customer for the Manual projects (default `Costco`) |
| `MANUAL_APPROVER_EMAIL` | Where customer-approval mail goes (default `jnorris+ttmanual@titanconsulting.net`) |
| `MANUAL_MIN_STATUSES` | Distinct-status floor the timesheet step asserts (default 4) |
| `MANUAL_SKIP_SEED=1` | Assert on existing timesheets without running the ladder |
| `TT_FIXTURES_READONLY=1` | Report missing structure, create nothing |

## Known rough edges

- **`Manual Consultant Three` has an assignment, where `E2E Consultant Three` has none.**
  The one deliberate divergence from the e2e tables. In the suite that consultant exists
  only so the clear has a row to name, and an unassigned consultant renders zero rows in
  every week — fine for a test, wrong for a review environment, where it would just look
  broken. It shares `Manual Manager Approval` with `Manual Consultant`.
- **The teardown has never been run.** It is written and its selectors are the same ones
  the e2e bookends use every night, but running it would delete the environment this was
  built for, so it is unverified. Test it deliberately, when the data is expendable.
- **First green build: 2026-09-10.** Accounts 72s, structure 1116s, timesheets 2137s on a
  resume (a cold ladder is roughly 45-60 min). The timesheet step is re-runnable — the
  seeder skips weeks that are already submitted — so a killed run resumes rather than
  repeats.
- **The echo-trap guard does not scan this directory.**
  `suites/80-platform/verify-no-echo-trap.test.sh` scans `lib/` and `suites/` only. The
  scripts here decode with `_tt_eval_str` throughout, but nothing enforces that.
- **Both account forms carry auto-named fields, and they disagree with each other** —
  Email is `textBox1` on `Account_New` and `textBox10` on `Account_Edit`. The provisioner
  resolves every field from its form-group **label** at runtime for that reason, so a page
  edit that renumbers the boxes costs nothing, but a *relabelled* field would need the
  regex updating.
- **Opening a popup form repeatedly leaves stale copies of it in the DOM** (two full sets
  of `Account_New` fields were observed, only the second live). The provisioner
  re-navigates to the page before each create and takes the *last visible* match of any
  field. A Mendix `reload` is not a substitute — it returns to the app's home page rather
  than the page that was open.
