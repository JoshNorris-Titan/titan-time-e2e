# TT-654 — Manual test script (DEV)

Prompts to type into an LLM connected to Titan Time over MCP. Work top to bottom;
later sections depend on earlier ones.

**Environment**

- App: `https://titantime100-development.mendixcloud.com`
- Sign in as **`e2e_consultant`** / `E2ETest123!`
- MCP endpoint: `https://titantime100-development.mendixcloud.com/titan-time/mcp`

**Assignments on this account** (confirmed 2026-08-10 by browser probe)

| Project | Client | Notes |
|---|---|---|
| E2E Customer Approval | Costco | submitting sends a **real** email, caught by the mail catcher |
| E2E Manager Approval | Walmart | submitting routes to the PM queue — **safer for submit tests** |
| E2E Line Items | Yamaha | requires tasks (line items) |

Because there are **three** assignments, a newly created week has **three** entries
and `GetMyWeek` returns three projects.

**Dates.** Use a week that the existing E2E suite doesn't touch (it works on the
current/first-editable week). `2026-09-06` is a **Sunday**; `2026-09-09` is the
Wednesday of that week. If those fall outside an assignment's date range, move
closer to today and keep the Sunday/Wednesday pairing.

**Dev is shared.** Everything below writes real data. Part 7 cleans up.

---

## Part 0 — The Connect my LLM popup (UI, no assistant)

| # | Do this | Expect |
|---|---|---|
| 0.1 | Consultant dashboard → look at the button | Reads **Connect my LLM**, red-tinted with a small dot; hover fills solid red and lifts |
| 0.2 | Click it | Intro panel, "What your assistant can do", Step 1, Step 2 with **four** tabs (Claude Code, ChatGPT / Codex, Cursor, Other). **No Step 3** |
| 0.3 | Look at a command box before generating | Shows `CLICK-GENERATE-MY-TOKEN-FIRST` where the token goes |
| 0.4 | Click **Copy** on any tab | Button briefly reads **Copied** in green, then returns to "Copy". **No popup message** |
| 0.5 | Paste somewhere | You get the command, placeholder still in it, pointing at the dev host |
| 0.6 | Click **Generate my token** | Token box fills; every tab's command now contains the real token |
| 0.7 | Click **Copy**, then immediately click **Generate my token** while it still says "Copied" | Popup stays alive and usable. *(This is the React crash path that was fixed — a stuck button or a vanished popup is a failure.)* |
| 0.8 | Copy the Claude Code line and run it in a terminal | Client connects; `/mcp` lists **7** tools |

Keep the token — you need it for everything below.

---

## Part 1 — Reading

**1.1** — `What projects am I assigned to in Titan Time?`

> All three. **E2E Line Items** flagged as requiring line items / tasks.

**1.2** — `Show me my Titan Time timesheet for the week of 6 September 2026.`

> Either three entries, or a report that no timesheet exists for that week yet —
> both are fine at this point.

---

## Part 2 — Creating a week

**2.1** — `Create my Titan Time timesheet for the week of 9 September 2026.`

> Note **9 September is a Wednesday.** It should create the week **starting
> Sunday 6 September** and tell you the date was snapped. **Three** entries.

**2.2** — `Create it again for the same week.`

> Reports it already exists; nothing created.

---

## Part 3 — Logging hours

**3.1** — `Log 8 hours a day Monday to Friday on E2E Manager Approval for the week of 6 September 2026.`

> 40 hours recorded. Open that week in the app — the grid should match.

**3.2** — `Log 8 hours a day on Acme Consulting for the week of 6 September 2026.`

> Refused: no project of that name is assigned to you. **Then open that week in
> the app** — nothing changed, and no extra timesheet created.
> *(A phantom week here is the bug that was fixed.)*

**3.3** — `Log 4 hours a day Monday to Friday on E2E Line Items for the week of 6 September 2026.`

> Refused: that project records time as tasks. The entry must still show 0 hours.

**3.4** — `Log 6 hours on Tuesday only for E2E Manager Approval for the week of 9 September 2026.`

> Works despite the mid-week date — lands on the 6 September week and replaces
> Tuesday's hours.

---

## Part 4 — Tasks (line items)

**4.1** — `On E2E Line Items for the week of 6 September 2026, add a task called "Sprint planning" with 2 hours on Monday and 3 hours on Tuesday.`

> Task created, entry total 5. Open the week in the app, expand the tasks panel
> on the Yamaha row — the task should be there with those hours, and the entry's
> Mon/Tue columns should read 2 and 3.

**4.2** — `Change Sprint planning to 4 hours on Monday and nothing on Tuesday.`

> **Updated, not duplicated.** Entry total 4. Confirm in the app there is still
> only one task with that name.

**4.3** — `Add a task called Bug fix: "login" screen with 1 hour on Wednesday.`

> Note the quote marks. Should succeed, and the assistant should read the name
> back intact. *(JSON-escaping fix — a parse error or mangled name is a failure.)*

**4.4** — `What tasks do I have on E2E Line Items that week?`

> Both tasks, names exactly as entered.

**4.5** — `Delete the Bug fix: "login" screen task.`

> Deleted; entry total drops by 1. Ask again — should report it doesn't exist.

---

## Part 5 — Submitting

> ⚠️ **Use E2E Manager Approval, not E2E Customer Approval.** The customer one
> sends a real email, caught by the mail catcher. The manager one routes to the PM queue.
> E2E Line Items' approval route is unconfirmed — check before submitting it.

**5.1** — `Submit my E2E Manager Approval timesheet for the week of 6 September 2026.`

> If the week is under the expected hours it should **refuse** and report the
> warning rather than submitting silently. If hours are exactly right it submits
> straight away — also correct.

**5.2** — `Yes, submit it anyway.`

> Submits. Status becomes awaiting approval; the app should agree.

**5.3** — `Change the hours on E2E Manager Approval for that week to 8 a day.`

> Refused — no longer editable once submitted.

**5.4** — `Submit E2E Line Items for the week of 6 September 2026.`

> With tasks entered (from Part 4) it should submit or warn. To see the
> no-tasks refusal, create a **fresh** week first and submit it before adding
> any tasks: *"This project requires tasks…"*.

---

## Part 6 — Things that should fail gracefully

**6.1** — `Show me my timesheet for the week of 32 August 2026.`

> **Known limitation:** an invalid-but-date-like value may resolve to a different
> week rather than erroring. Note what actually happens.

**6.2** — `Show me my timesheet for last Tuesday.`

> The assistant resolves the date itself and uses that week's Sunday.

**6.3** — `Delete the task called Nothing At All from E2E Line Items for the week of 6 September 2026.`

> Reports no such task; nothing changes.

---

## Part 7 — Cleanup (dev is shared)

**7.1** — `Delete all the tasks I added to E2E Line Items for the week of 6 September 2026.`

**7.2** — `Set my hours to zero on E2E Manager Approval for the week of 6 September 2026.`

> Only works if the entry wasn't submitted in Part 5. If it was, leave it — a
> submitted E2E entry is normal for this environment.

The 6 September timesheet itself stays. Empty drafts are swept by
`Core.SCE_Timesheet_CleanupEmptyDrafts`.

---

## Known limitations (don't report these as new bugs)

- **Malformed dates** aren't validated — a bad string can throw a raw runtime
  error, and a date-like invalid one can resolve to another week.
- **Whitespace-only task names** are accepted; the response reports
  `allTasksNamed: false` but the task is still created.
- **Adding a task via MCP and via the app take different routes.** The app's Add
  Task button creates an empty task and recalculates later; the tool creates a
  complete task and recalculates immediately. Totals end up the same.
- **`GetMyWeek` and `ListMyAssignments` return bare arrays**, with no error
  envelope, unlike the write tools.
- **No tool submits a whole week at once** — one project at a time.
- Attachments, expenses, clearing a week and listing past weeks are **not
  exposed over MCP**.
