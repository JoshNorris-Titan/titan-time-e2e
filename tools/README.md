# The mail catcher

Several steps in the suite need to read an email the app just sent — a submission reminder, a
rejection notice, the customer's approval link. This directory holds the tooling for a **mail
catcher**: a server the app sends through, which keeps every message instead of delivering it.

---

## The one mechanic that matters

The catcher is a fake SMTP **server**, and the app is the client. That single fact is what makes
this approach work:

- It accepts **every recipient**, unconditionally. There is no mailbox, no domain, no MX record,
  no deliverability. Mail addressed to `sarah@a-real-client.com` is accepted and stored, exactly
  like mail to `anything@made-up.invalid`.
- Nothing is ever delivered onward. The catcher is a dead end by design.

So the app's data does **not** have to be doctored to point at test inboxes. Dev can keep its
real addresses, and a test can assert *"the reminder went to the consultant's actual address,
with these values in the body"* — a much stronger claim than *"something arrived in a shared
test inbox"*.

---

## What running it on a reachable host gives you

**1. Dev can never email a real person again.** This is the big one, and it is a safety control
rather than a testing convenience. Today, anything that triggers a reminder or an approval
request on dev sends real mail to whoever is in the data — including real client contacts. Point
dev at the catcher and that becomes structurally impossible.

**2. The email steps can run against dev.** Email subjects and bodies are per-environment
database rows, not model. Testing them anywhere other than dev proves the pipeline but not the
copy. This is the only way to assert what dev actually sends.

**3. No more rewriting recipient data.** `verify-emailprep-apply.test.sh` exists to redirect
every `Account.Email` and project approver address to one inbox. With a catch-all catcher that
becomes optional — worth keeping as a belt-and-braces measure, but no longer load-bearing.

**4. CI works.** A GitHub Actions runner can reach a public API. It could never reach a laptop,
so email coverage in the scheduled workflow only becomes possible once the catcher is hosted.

**5. A human-readable inbox for debugging.** The web UI shows exactly what dev sent, headers and
all — useful well beyond the test suite when a template renders wrongly.

---

## What it costs

**An SMTP port open to the internet is an abuse magnet.** An unauthenticated one will be found
and used as a spam relay within days. Both listeners must be protected:

- **SMTP** — `--smtp-auth-file` with a **bcrypt** hash. A plaintext password is rejected outright
  (`535 Authentication credentials invalid`); that mistake is what killed an earlier attempt at
  this. Better still, also restrict the source to Mendix Cloud's outbound addresses.
- **HTTP UI/API** — `--ui-auth-file`, same format. The suite passes `TT_MAILPIT_USER` /
  `TT_MAILPIT_PASS`.
- **TLS** on both, which needs a DNS name and a certificate.

**Port 25 is usually blocked outbound by cloud providers.** Run SMTP on a high port (2525 is
conventional) and set that port in the app's email configuration.

**Changing dev's mail settings affects everyone using dev.** It is a database row, so it is
reversible and cannot touch acceptance or production — but real dev mail stops arriving for
everybody, which is the intent and should still be announced.

---

## Standing one up

On the host:

```bash
TT_MAILPIT_BIND=0.0.0.0:8025 TT_MAILPIT_SMTP_BIND=0.0.0.0:2525 tools/mailpit.sh start
```

For anything internet-facing, run mailpit directly with auth and TLS rather than through that
script, which is deliberately minimal:

```bash
mailpit --listen 0.0.0.0:8025 --smtp 0.0.0.0:2525 \
        --smtp-auth-file /etc/mailpit/smtp.auth \
        --ui-auth-file   /etc/mailpit/ui.auth \
        --smtp-tls-cert  /etc/mailpit/cert.pem \
        --smtp-tls-key   /etc/mailpit/key.pem
```

Auth files are `username:bcrypt-hash`, one per line.

Then point the app at it. In the target environment, open the Email Connector's admin page
(`Email_Connector.Email_Connector_Overview`) and set the outgoing account to the catcher's host,
the SMTP port, TLS on, OAuth off, and the SMTP username/password from the auth file. These are
database rows — no Studio Pro save, and no effect on any other environment.

Finally, prove it before trusting it:

```bash
export TT_MAILPIT_URL=https://catcher.example.com
export TT_MAILPIT_SMTP=catcher.example.com:2525
tools/mail-selfcheck.sh
```

That sends a message to the catcher and reads it back, with no app involved. If it fails, nothing
else here will work. If it passes but an email step still fails, the fault is in the app or its
email configuration.

---

## Day to day

```bash
tools/mailpit.sh status     # is the configured catcher up
tools/mailpit.sh count      # how many messages it holds
tools/mailpit.sh clear      # empty it
```

`start` and `stop` act on a catcher running on the current machine; the rest act on whatever
`TT_MAILPIT_URL` points at.

---

## How the tests reach it

Tests never talk to the catcher directly. They use four helpers from `lib/_login.sh`:

| Helper | What it does |
|---|---|
| `tt_mail_prepare` | Check mail is readable, **and empty the inbox**. Call it *before* the action that sends. |
| `tt_mail_address <tag>` | A synthetic address, for the few tests that choose their own recipient |
| `tt_mail_message <ts> [who]` | The message — subject and body |
| `tt_mail_token <ts> [pattern] [who]` | A link pulled out of the message |

`[who]` filters by recipient and matches either a synthetic tag or a real address, so a test can
say "the mail addressed to `sarah@client.com`" directly.

With `TT_MAILPIT_URL` unset or unreachable, `tt_mail_prepare` **fails loudly**. Given this
suite's history of assertions that could not fail, that was deliberate: a missing mail backend
must never look like a pass.
