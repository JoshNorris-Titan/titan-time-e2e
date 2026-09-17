# `password-refresh/` — keeping the test logins from ageing into a forced reset

Once a week, every `e2e_*` and `manual_*` account has its password **set away and set
back**. Nothing else. No product behaviour is tested here and no data is touched.

```bash
./run-tests.sh password-refresh --expect-count 2      # both steps
PR_ONLY=e2e_consultant3 ./run-tests.sh password-refresh --expect-count 2   # one account
```

`.github/workflows/password-refresh.yml` dispatches exactly that, on a Sunday
14:00 UTC cron and on demand.

## The password does not change

Each account ends the run on the value it started on. **No secret needs updating
afterwards** — not `TT_ROLE_PASS`, not `TT_MANUAL_PASS`, not the GitHub secrets, not
`.e2e-autofix.env`, not anyone's notes. It is a keep-alive, not a rotation. If it ever
starts behaving like a rotation, that is a bug in here.

## Why it exists

Left alone, these logins eventually start demanding a password reset. When that happens
the nightly does not fail with *"the password is wrong"* — it fails with whatever the
first step to hit a `Core.Force_PasswordReset` screen happened to be doing.
`lib/_login.sh` distinguishes those two states (its state 2 vs state 1) precisely because
the confusion cost real debugging time. This job stops the condition arising instead of
diagnosing it better.

## The two steps

| Step | What it does | Budget |
|---|---|---|
| `verify-200-password-refresh` | The churn: `original → temp1 → temp2 → original`, per account, as the administrator | 75m |
| `verify-zzz-password-verify` | Signs in as all fourteen with the original password and asserts each role's dashboard | 30m |

**The second step is the one that decides whether the run worked.** An administrator
setting someone else's password has no way to tell whether the account can use it, so the
churn step can only report that each submit was accepted. Everything this job promises is
asserted by the sign-in step.

It carries the `verify-zzz-` prefix so `run-tests.sh` treats it as teardown and runs it
**even after the churn step fails** (see `is_teardown` in `run-tests.sh`). That is
deliberate: the run where the churn failed is the run where *"which of the fourteen can
still log in?"* is the most valuable line in the log.

## Why the chain has two throwaway hops and not one

The obvious chain is `original → temp → original`, and it works only if the app's
no-reuse rule means *"the new password may not be the one you have right now"*. If it
means *"the new password may not be the one you had immediately before"* — a history of
one — the last hop is refused, because the password immediately before `temp` was the
original. Josh's read is the first one; the two are a word apart, and being wrong strands
every account on a throwaway value.

`original → temp1 → temp2 → original` survives both readings and stays true week after
week: at the final hop the current password is `temp2` and the previous one is `temp1`, so
the original collides with neither. The price is one extra form submit per account.

The throwaway values are **derived from the real password** (see `pr_temp` in
`refresh.env.sh`), never literals in this repo, and are **never printed** — a temp value
in a CI log would leak `TT_ROLE_PASS` in a form GitHub's masking will not catch.

## The roster is an allowlist

Dev carries far more accounts than these — real people (`mindy-hr`, `warren-tm`,
`rishika-consultant`, …), demo logins and one-off test users were all in the grid on
2026-09-09. **Nothing here ever reads the Accounts Overview grid for candidates.** It acts
on the names in `refresh.env.sh` and on nothing else. A step that swept the grid would
change a colleague's password.

Both halves are declared there, and **nothing is sourced from `manual-env/`**. That was the
first design and it was wrong twice over: `manual-env/` is a working directory that is not
committed, so `actions/checkout` would hand the runner a tree without it and the job would
die on the `source` line; and sourcing `manual.env.sh` overwrites `TT_ROLE_PASS` with
`TT_MANUAL_PASS`, which is right for a directory that only drives the Manual set and wrong
here, where both sets are in scope at once.

The drift protection that sourcing was really for is kept, without the coupling: when
`manual-env/` **is** present — a local checkout, never CI — `pr_check_manual_roster` reads
`MANUAL_ACCOUNTS` **in a subshell** and fails if the two lists disagree, naming the
accounts on each side. So an eighth manual account added for a reviewer stops a local run
with a message about it rather than being silently left to age into the very forced reset
this job exists to prevent. CI simply skips the comparison.

`MxAdmin` is deliberately absent. It is the credential the job authenticates *with*, so
churning it means changing the password out from under the session doing the changing —
and a failed restore would not break one test account, it would break `TT_ADMIN_PASS` and
lock every workflow out of the environment, this one included.

## Recovering a stranded account

The churn step reports `STRANDED` for any account it left on a throwaway password, and
that is the only outcome that leaves the environment worse than it found it.

**Re-run the workflow.** The administrator does not need to know an account's current
password to set a new one, so a second pass walks the chain again and lands on the
original. There is no state to reconcile and no recovery mode.

By hand, if you prefer: Admin Hub → Accounts Overview → filter the login → Edit Account →
Change password → type the `TT_ROLE_PASS` (or `TT_MANUAL_PASS`) value.

> [!WARNING]
> Do **not** use the row's *Force Reset Password* action to fix anything here. It arms the
> exact forced-reset state this job exists to prevent.

## One trap, already caught

`lib/_login.sh` sets `TT_PASS="${TT_ROLE_PASS:-E2ETest123!}"` at source time. So a
`${TT_ROLE_PASS:-$TT_PASS}` fallback in here can never be empty, and a run whose
`TT_ROLE_PASS` secret was missing or blank would have churned all fourteen deployed
accounts and **"restored" them to `E2ETest123!`** — changing the real password on a shared
environment and then reporting PASS, because the verification step would confirm the value
the churn step had just set.

`refresh.env.sh` therefore reads `TT_ROLE_PASS` **directly, with no fallback**, and refuses
to define a roster at all without it. That refusal lives in the shared file rather than in
the two steps, so neither step can be the one that forgets. This is the concrete version
of the warning in `README.md` §4: the lib defaults are a local convenience and must never
be relied on against a deployed environment.

## Knobs

| Variable | Effect |
|---|---|
| `PR_ONLY` | Churn/verify a single username instead of the whole roster |
| `PR_UNBLOCK` | `1` also clears the failed-login lockout when an account has one. Off by default — a lockout is a separate fault from an ageing password, and clearing one silently would hide it |
| `PR_TEMP_SALT` | Overrides the throwaway-password prefix |
| `TT_MANUAL_PASS` | The `manual_*` password, when it differs from `TT_ROLE_PASS` |

## Concurrency

The workflow shares `e2e.yml`'s concurrency group on purpose, so it and the nightly
**queue** rather than overlap: for about a minute per account this job holds a login on a
throwaway password, and a nightly signing in during that minute fails for a reason that
has nothing to do with the product.

The residual gap is `manual-env-build` / `-teardown`, which use their own group — a
workflow can only join one. That case needs a person to click at the wrong moment on a
Sunday morning and is recoverable, so it is accepted rather than designed around.

## Where the browser knowledge lives

`lib/_accounts.sh`. It holds the measured facts about
`Administration.Account_Overview` — the auto-named hub card, the `textFilter2` login
filter, the per-row `Edit Account` link, the `Change password` dialog and its two boxes
resolved **by label** because `textBox1` is the confirm box here and the *Username* box on
the form behind it.

`manual-env/provision-accounts.sh` still carries its own copies of those primitives. They
were being actively reworked on 2026-09-09 and were deliberately left alone so nothing
collided mid-flight; every function in `lib/_accounts.sh` is prefixed `acct_` so both can
be sourced into one shell. When that rework settles, point it at the library and delete
the copies.
