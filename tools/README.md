# Reading mail

The suite reads email from **the app's own admin page**, not from an external mail
catcher. `Core.EmailsSent_Overview` — "Emails Sent" on the administrator homepage —
lists every message the app has produced, with its recipient, subject, status, send
error and body.

There is nothing to install, run, expose or configure. An administrator login,
which every environment already has, is the whole requirement.

## Why it works this way

It used to be an external mail catcher: a fake SMTP server the app was pointed at,
which collected messages and served them over an HTTP API. That worked locally and never
worked anywhere else, because the *app* has to reach the catcher over SMTP. Against
a deployed environment that meant a publicly reachable host with an open SMTP port,
credentials for both listeners, and a secret in CI. It was the only reason CI needed
anything beyond the app itself, and it was never set up — so the email steps could
not pass in CI at all.

Reading the admin page removes all of that, and buys two things the catcher could
not give:

- **The recipient is a column, so a misdirected email is detectable.** The old
  reader fell back to "the newest message, whoever it was addressed to" whenever it
  could not match, which meant no test could ever catch mail going to the wrong
  address. `tt_mail_to` now answers that question directly.
- **Messages are visible while still queued.** Nothing actually sends until a
  scheduled event runs, roughly every two minutes. A row exists at `Queued` long
  before that, so a test can assert a mail was *raised* without waiting for delivery.

## The one mechanic that matters

Freshness is a **high-water mark**, not an emptied inbox.

`tt_mail_prepare` records the rows already on the page; every later read considers
only rows that were not there before. Call it **before** the action that triggers the
send. Nothing is deleted, so this is safe on a shared environment — unlike the old
catcher, which cleared the whole inbox on every prepare.

Two consequences, worth knowing rather than discovering:

- Two byte-for-byte identical mails collapse into one new row.
- Only rows the grid renders are visible. It pages at 20, so the helpers sort
  newest-first; if that sort ever fails they say so rather than quietly reading
  nothing.

## What it costs

The page is `Core.Administrator`-only, so reading mail means logging in as the
administrator and **losing whatever role session the test was using**. Read mail at
the end of a step, or log back in afterwards. That is the whole price.

## Day to day

```bash
tools/mail-selfcheck.sh     # can the suite read mail? run this before debugging one
```

It checks the *reader*, not the app's sending. If it passes and an email test still
fails, the app did not raise the message — which is a real finding, not a setup
problem.

## How the tests reach it

From `lib/_login.sh`:

| Helper | What it does |
|---|---|
| `tt_mail_prepare` | Opens the page as administrator and marks what is already there. Call before the trigger. |
| `tt_mail_token` | The first link matching a pattern (default: the customer-approval link) from mail that appeared since. |
| `tt_mail_message` | Subject and row for the mail that appeared, for a test that wants to look rather than extract. |
| `tt_mail_to` | The recipient of the new mail matching a substring — the "did it go to the right person" assertion. |
| `tt_mail_address` | A synthetic address, for the cases where a test chooses the recipient (the Email Tester). |

`tt_mail_reset` is kept as an alias of `tt_mail_prepare` so older call sites read
unchanged.
