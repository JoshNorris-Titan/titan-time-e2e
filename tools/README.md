# The mail catcher

Some steps in the suite need to read an email the app just sent — a submission reminder, a
rejection notice, the customer's approval link. This directory holds a **fake mail server** that
makes that possible without sending real mail anywhere.

The app is pointed at it as if it were a normal mail server. It accepts every message, delivers
none of them, and keeps them where the tests (and you) can read them back.

---

## Why not just use a real inbox

The suite used to read from a hosted inbox at testmail.app. That still works and is still
supported — but it needs an account and an API key, mail leaves the network, and its inbox
**cannot be emptied**, so a test has to guess whether the message it found is the one it just
triggered or one from an earlier run.

The local catcher has none of those problems. Its one limitation is reach:

> [!IMPORTANT]
> It only works when the app runs **on this machine**. A Mendix Cloud environment cannot open a
> connection back to a laptop. Against cloud, the suite falls back to the hosted inbox.

An earlier attempt to bridge that gap with an ngrok tunnel was abandoned: ngrok requires a card
on file before it will open the kind of port this needs, and doing so would expose an
unauthenticated mailbox to the internet. Not worth it.

---

## One-time setup

**1. Start the catcher.**

```bash
tools/mailpit.sh start
```

**2. Prove it works, before involving the app.**

```bash
tools/mail-selfcheck.sh
```

This posts a message to the catcher and reads it back. If it fails, nothing else here will work.
If it passes but an email step still fails, the fault is in the app or its settings — not here.

**3. Point the app's email settings at it.** In the *running local app*, open the Email
Connector's own admin page (`Email_Connector.Email_Connector_Overview`) and set the outgoing
account to:

| Field | Value |
|---|---|
| Server host | `127.0.0.1` |
| Server port | `1025` |
| SSL | off |
| TLS | off |
| OAuth | off (use username/password; any value is accepted, including blank) |

> [!NOTE]
> These are **database rows, not model settings** — they live in the local database only. Changing
> them cannot affect dev, acceptance, or production, and does not need a Studio Pro save.

That is all. From then on, `tools/mailpit.sh start` before a run is the only step.

---

## Day to day

```bash
tools/mailpit.sh start      # idempotent — safe to run when it's already up
tools/mailpit.sh status     # is it up, and which version
tools/mailpit.sh count      # how many messages are held
tools/mailpit.sh clear      # empty the inbox
tools/mailpit.sh stop       # shut down (also a full reset — storage is in memory)
```

**Read the mail yourself** at <http://127.0.0.1:8025>. It is a normal webmail-style interface —
useful when a template renders wrongly and you want to see what actually went out.

---

## How the tests reach it

Tests never talk to either backend directly. They call the same four helpers in
`lib/_login.sh` regardless of which is in use:

| Helper | What it does |
|---|---|
| `tt_mail_prepare` | Check mail is readable, **and empty the inbox**. Call it *before* the action that sends. |
| `tt_mail_address <tag>` | An address to send to that this suite can read back |
| `tt_mail_message <ts> [tag]` | The message itself — subject and body |
| `tt_mail_token <ts> [pattern] [tag]` | A link pulled out of the message |

Which backend answers is decided by `TT_MAIL_BACKEND`:

- `auto` (default) — the local catcher if it is running, otherwise the hosted inbox
- `mailpit` — force local; fails if it isn't running
- `testmail` — force hosted; needs `TT_TESTMAIL_APIKEY` and `TT_TESTMAIL_NAMESPACE`

With neither available, `tt_mail_prepare` **fails loudly**. Given this suite's history of
assertions that could not fail, that was deliberate: a missing mail backend must never look like
a pass.

---

## No passwords here

The catcher runs with `--smtp-auth-accept-any` and has no credentials at all. An earlier attempt
stored an SMTP username and password in `.mailpit/`, which mailpit then rejected anyway — it
wants a bcrypt hash, not a plaintext password. Those files are gone. `.mailpit/` now holds only a
pid and a log, and stays out of Git.
