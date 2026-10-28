# SubWatch — Household Subscription Optimizer

A DBMS project: PostgreSQL + a Node/Express API + a plain HTML/JS dashboard.

Most subscription trackers look at one person's list and say "you have two
streaming apps". SubWatch works at the level of a **household** (a family, a
hostel room, a couple) and lets the database work out things that are hard
to spot by hand:

| Finding | What it catches | Main SQL idea |
|---|---|---|
| **Hidden duplicate** | Paying for something you already get through another plan, even indirectly (Airtel plan → includes Amazon Prime → includes Prime Video, while someone also pays for Prime Video) | Recursive CTE over an entitlement graph |
| **Family plan** | 3 people each on individual Spotify when one Family plan is cheaper; picks the cheapest tier using `ceil(people / capacity) × price` | Aggregation + window function ranking |
| **Free spot** | Someone pays alone while a shared plan in the house has an empty slot | Self-join with capacity check |
| **Bundle** | A bundle (Apple One) replaces 2+ separate subscriptions for less | Relational division (double `NOT EXISTS`) |
| **Usage falling** | Usage trending toward zero *before* it's actually unused | Linear regression (`regr_slope`) over 30-day windows |
| **Unused** | Not opened in 30+ days | Aggregates + date math |
| **Overlap** | Several services in one category where one is clearly neglected | Window functions |

On top of that:

- **Who pays what:** shared plans are split half equally, half by minutes actually used.
- **Settle up:** works out who owes whom each month, with opposite debts netted out.
- **Next 30 days:** a forecast of upcoming renewals.
- **Preview & apply fixes:** every finding has a "Preview fix" button. It runs
  the change in a database transaction, shows exactly what would happen
  (steps, new monthly spend), then rolls back. "Apply" runs the same thing and
  commits.
- **Bank statement import:** upload a CSV and SQL finds the charges that repeat
  on a cycle. It tells you which ones aren't in SubWatch yet, which are
  already tracked, and which you marked as cancelled but are still being
  charged for.

Prices and "plan X includes Y" relationships in the seed data are illustrative
sample values in INR, not an official price list.

For the ER diagram, normalization notes and how each query works, see
**[report.md](report.md)**. For likely viva questions with short answers, see
**[VIVA.md](VIVA.md)**.

## Setup

Needs PostgreSQL 14+ (Postgres.app is fine) and Node.js 18+.

```bash
cd ~/subwatch
createdb subwatch            # skip if it already exists
psql -d subwatch -f db/schema.sql
psql -d subwatch -f db/seed.sql
psql -d subwatch -f db/detection.sql

cd server
npm install
cp .env.example .env         # first time only — then set PGUSER/PGPASSWORD for your machine
npm start
```

Open http://localhost:4000. `schema.sql` drops and recreates everything, so
re-running the three files gives you a fresh demo at any time.

## Demo walkthrough

1. **Sharma Household:** three hidden duplicates. One is two levels deep:
   Priya pays for Prime Video, but Arjun's Airtel family plan includes Amazon
   Prime, which includes Prime Video. See the *Hidden entitlements* panel for
   the full chain. Also: a Spotify family-plan saving, JioHotstar usage
   falling off, unused Audible, and an uneven Netflix split.
2. **Hostel Room A-412:** Aditya has a "free spot" alert. Open Karthik's
   Spotify Duo row, add Aditya, and the alert turns into "you're already on
   Karthik's Duo, cancel your own". Cancel his individual plan and it clears.
   There's also an Apple One bundle saving.
3. **Iyer Residence:** Ananya pays for Netflix even though Vikram's Jio
   plan includes it. Spotify Duo (not Family) is picked as the cheapest fix.
   The cancelled Amazon Prime correctly raises nothing.
4. Click **Preview fix** on the Spotify family-plan finding. You'll see the
   four steps and the new monthly spend, but nothing has changed yet. Click
   **Apply** to do it for real.
5. In *Import a bank statement*, pick Priya and click **Try a sample
   statement**. It finds a second Netflix she pays for that isn't tracked; add
   it and a "paying twice" finding appears. On the Iyer household, Vikram's
   sample shows an Amazon Prime marked cancelled that is still being charged.
6. Try breaking the rules: add a 3rd person to a 2-person plan, or log usage
   for someone who isn't a member. The database itself refuses (triggers +
   composite foreign key) and the UI shows its message.

**Statement CSV format:** a header row with a date column (`YYYY-MM-DD` or
`DD/MM/YYYY`), a description/narration column, and an amount or debit
column. "download sample" next to the import button gives you an example.

## Project layout

```
db/
  schema.sql      tables, constraints, triggers
  seed.sql        3 demo households, plans, entitlements, ~1,900 usage logs,
                  merchant aliases for statement import
  detection.sql   detector views, fair-share/settle-up views, forecast
                  function, refresh_alerts(), apply_alert(), statement
                  import views
server/
  index.js        Express app + DB-error → HTTP mapping
  db.js           connection pool, refresh helper
  routes/         households, subscriptions, alerts, insights, catalog, imports
public/
  index.html      dashboard (no build step)
```

## API

| Method | Path | |
|---|---|---|
| GET | `/api/households` | list households |
| GET | `/api/households/:id/summary` | spend, savings found, efficiency score, spend by category |
| GET | `/api/households/:id/members` | what each person pays vs. their fair cost |
| GET | `/api/households/:id/subscriptions` | subscriptions with members and 6-window usage trend |
| POST | `/api/households/:id/subscriptions` | `{payer_id, plan_id, start_date, member_ids[]}` (one transaction) |
| PATCH | `/api/subscriptions/:id` | `{status: active / paused / cancelled}` |
| POST / DELETE | `/api/subscriptions/:id/members[/:userId]` | add / remove a member |
| POST | `/api/subscriptions/:id/usage` | `{user_id, duration_minutes}` |
| GET | `/api/households/:id/alerts?status=open` | findings, with linked subscription ids |
| POST | `/api/households/:id/alerts/refresh` | re-run the optimizer |
| PATCH | `/api/alerts/:id` | `{status: dismissed / resolved}` |
| POST | `/api/alerts/:id/preview` | what the fix would change (rolled back) |
| POST | `/api/alerts/:id/apply` | carry out the fix (committed) |
| GET | `/api/households/:id/sample-statement?user_id=` | generated 6-month sample CSV |
| POST | `/api/households/:id/imports` | `{user_id, file_name, rows[]}` |
| GET | `/api/imports/:id/results` | recurring charges found and their status |
| GET | `/api/households/:id/fair-share` | per-member split of each shared plan |
| GET | `/api/households/:id/settle-up` | net monthly transfers |
| GET | `/api/households/:id/forecast?days=30` | upcoming renewals |
| GET | `/api/households/:id/entitlements` | everything unlocked through other plans |
| GET | `/api/plans` | purchasable plans |

Every change made through the API runs as one transaction: lock the
household, make the change, re-run the optimizer, commit. If any step fails
(for example a trigger refuses it), the whole thing rolls back.
