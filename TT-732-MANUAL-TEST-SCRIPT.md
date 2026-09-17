# TT-732 — Manual test plan (DEV)

**Bug:** editing any existing consultant assignment was blocked with *"Consultant is already assigned to this project."* The duplicate check matched the assignment against itself. **Fix:** the check now excludes the assignment being edited.

**App:** https://titantime100-development.mendixcloud.com
**Accounts:** `manual_tm` (Titan Manager), `manual_consultant2` (Consultant, Part 3 only), `MxAdmin` (Part 0 only). Manual accounts use the shared role password.
**Time:** ~10 min for Parts 0–2. Part 3 is optional.

## Data (prepared and verified on dev, 2026-09-10)

| Consultant | Project (all under Costco) | Dates | Used in |
|---|---|---|---|
| Manual Consultant Two | **Manual Sandbox** | 07/01/2026 – 12/31/2027, 40 h/wk | Part 1 (throwaway, safe to edit) |
| Manual Consultant | **Manual Manager Approval** | 07/01/2026 – 12/31/2027 | Part 2 (the duplicate target) |
| Manual Consultant Two | *(Draft week of 08/30/2026)* | — | Part 3 |

Please don't edit **Manual Consultant → Manual Customer Approval**. Its 01/01/2025 start date is deliberate, and ten 2025 weeks depend on it.

---

## Part 0 — Run the company backfill (MxAdmin, once)

The fix ships a one-off migration that has to be clicked per environment. It **has not been run on dev yet**: 85 assignments there have a project but no company, and those open read-only and fail with *"Company is required!"* The Manual assignments already have a company, so Parts 1–3 don't depend on this.

| # | Do this | Expect |
|---|---|---|
| 0.1 | Sign in as MxAdmin → Admin dashboard | **Backfill Assignment Company** card is present |
| 0.2 | Click it | Reports ~85 filled in |
| 0.3 | Click it again | Reports 0 filled in (idempotent) |

## Part 1 — The reported bug: an existing assignment can be edited

| # | Do this | Expect |
|---|---|---|
| 1.1 | Sign in as `manual_tm` → Consultants card → search **Manual Consultant Two** → click the card | Consultant Details: 1 assignment, Manual Sandbox |
| 1.2 | Click the **Manual Sandbox** row → **Edit** | Edit Assignment form, all fields enabled |
| 1.3 | Change Start date **07/01/2026 → 06/24/2026** → **Save** | ✅ Form closes. **No** "already assigned" message |
| 1.4 | Without refreshing, look at the assignment | Shows 06/24/2026 (saved, and the UI updated without F5) |
| 1.5 | Edit again, set Start date back to **07/01/2026**, Save | Saves cleanly. Data is restored |

**Fail:** "Consultant is already assigned to this project." on 1.3 means the original bug is back.

## Part 2 — A genuine duplicate is still blocked

The fix narrows the check. It must not have removed it, and the automated test doesn't cover this case.

| # | Do this | Expect |
|---|---|---|
| 2.1 | As `manual_tm`, Consultants card → **Add Assignment** | Empty assignment form |
| 2.2 | Company **Costco** → Project **Manual Manager Approval** → Consultant **Manual Consultant**, 40 h/wk, 400 budget, 07/01/2026 – 12/31/2027 | Form accepts it (pick company first, it gates the project list) |
| 2.3 | **Save** | ⛔ *"Consultant is already assigned to this project."*, not saved |
| 2.4 | **Cancel**. Reopen Manual Consultant | Still 4 assignments, no duplicate |

**Fail:** if 2.3 saves, the guard was deleted instead of fixed.

## Part 3 — *(Optional)* An assignment change reaches an existing timesheet week

| # | Do this | Expect |
|---|---|---|
| 3.1 | As `manual_consultant2`, open the week of **08/30/2026** (Draft) | One row: Manual Sandbox |
| 3.2 | As `manual_tm`, Add Assignment: Costco → **Manual Line Items** → Manual Consultant Two, 40 h/wk, 400 budget, 07/01/2026 – 12/31/2027 → Save | Saves (not a duplicate) |
| 3.3 | As `manual_consultant2`, reopen the 08/30/2026 week | **Manual Line Items row now appears** on a week that already existed |
| 3.4 | As `manual_tm`, open that new assignment → **Archive** | — |
| 3.5 | Reopen the 08/30/2026 week as `manual_consultant2` | Line Items row is gone. It was empty, so it was safe to remove. (Rows with logged hours are never removed, so don't type hours into it in 3.3) |
