# SubWatch — Household Subscription Optimizer

A DBMS project: PostgreSQL + a Node/Express API + a plain HTML/JS dashboard.

v1 finds waste. v2 (this version) decides: it works out the cheapest set of
subscriptions that still covers what every person uses, lets you simulate a
change before making it, and rates how sure it is about each finding.

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

### New in v2

| Feature | What it does | Where |
|---|---|---|
| **Needs** | Records what each person actually uses. Usage in the last 30 days, passive services (phone plans, cloud storage) reached through any plan, or set by hand. | `member_needs`, Needs panel |
| **Price and inclusion history** | Prices and "plan X includes Y" are date ranges. Exclusion constraints refuse overlaps. Views `plans` and `entitlements` still show today, so v1 is unchanged. | `plan_price_history`, `plan_inclusion_history` |
| **Reason paths** | Each finding shows the chain behind it, e.g. Airtel → Amazon Prime → Prime Video, and who it covers. | `alert_subscriptions.reason_path` |
| **Household optimizer** | Branch and bound search for the cheapest plan set that keeps every need covered. Ordered steps, preview and apply, refuses a stale run. | `server/optimizer.js`, `apply_optimization()` |
| **What-if simulator** | Cancel, switch, remove a member, remove an inclusion or raise a price. Shows who is affected, what coverage is lost and the cheapest repair. Never changes data. Named scenarios can be compared. | `server/whatif.js`, `scenarios` |
| **Confidence** | Every finding has evidence and a High / Medium / Low rating. 45 days of silence makes usage findings Low, and Low ones don't count toward savings. | `finding_evidence` |
| **Benchmark** | Times v1 against the optimizer on generated households. | `db/tests/benchmark.js` |

On the demo data the optimizer saves ₹660.84 on Sharma (v1's findings alone:
₹610.84), ₹285 on the Hostel and ₹1,788 on Iyer.

Prices and "plan X includes Y" relationships in the seed data are illustrative
sample values in INR, not an official price list.

For the ER diagram, normalization notes and how each query works, see
**[report.md](report.md)**. For likely viva questions with short answers, see
**[VIVA.md](VIVA.md)**.

## Setup

Needs PostgreSQL 14+ (Postgres.app is fine) and Node.js 18+. `schema.sql`
creates the `btree_gist` extension, which ships with Postgres.

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

Tests (each rebuilds or uses a scratch database, never `subwatch`):

```bash
db/tests/regress.sh                    # v1 output unchanged (diff against v1_baseline/)
psql -d subwatch_test -f db/tests/v2a_check.sql
node db/tests/v2b_check.js             # optimizer
node db/tests/v2c_check.js             # what-if
node db/tests/v2d_check.js             # confidence and benchmark
node db/tests/benchmark.js             # v1 vs optimizer on generated households
cd server && npm test                  # unit tests
```

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
7. **Optimize my household** (Sharma): click Run. The steps and the new
   monthly spend (₹3,036.51 → ₹2,375.67) appear. Preview rolls back; Apply
   commits. If the household changes between Run and Apply, Apply is refused
   and the page asks you to run again.
8. **What-if** (Sharma): choose "remove a member", Priya. It shows who loses
   Netflix and YouTube Premium, and the cheapest repair. Save it, make a second
   scenario ("Airtel drops Amazon Prime") and compare the two.
9. **Needs:** Airtel and other passive services are marked as needed even
   though nobody logs usage on them. Remove one by hand and the optimizer will
   treat it as droppable; reset it to go back to automatic.
10. **Confidence:** every finding has a High / Medium / Low badge and an
    evidence list. Make a member silent for 45 days (delete their recent
    usage logs and refresh) and their usage findings turn Low and drop out of
    "savings found".

**Statement CSV format:** a header row with a date column (`YYYY-MM-DD` or
`DD/MM/YYYY`), a description/narration column, and an amount or debit
column. "download sample" next to the import button gives you an example.

## Project layout

```
db/
  schema.sql      tables, constraints, triggers (incl. history and exclusion
                  constraints)
  seed.sql        3 demo households, plans with price history, inclusions,
                  ~1,900 usage logs, merchant aliases for statement import
  detection.sql   detector views, coverage and needs views, confidence views,
                  fair-share/settle-up, forecast, refresh_alerts(),
                  apply_alert(), optimizer_input(), apply_optimization(),
                  statement import views
  tests/          regress.sh, v1_baseline/, snapshot.sql, v2a to v2d checks,
                  benchmark.js
server/
  index.js        Express app + DB-error → HTTP mapping
  db.js           connection pool, household transaction helper
  optimizer.js    branch and bound search (pure function, no database)
  whatif.js       what-if simulator (works on a copy of the optimizer input)
  routes/         households, subscriptions, alerts, insights, catalog,
                  imports, needs, optimizer, whatif
  *.test.js       unit tests (npm test)
public/
  index.html      dashboard (no build step)
docs/
  v2-summary.txt  every table, view, function, route and test added in v2
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
| GET | `/api/households/:id/alerts?status=open` | findings, with linked subscription ids, reason paths, evidence and confidence |
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
| GET | `/api/plans` | purchasable plans (with `service_id`) |
| GET | `/api/households/:id/needs` | each person's needs with source and coverage |
| POST | `/api/households/:id/needs` | `{user_id, service_id}` mark as needed |
| DELETE | `/api/households/:id/needs/:userId/:serviceId` | mark as not needed (`?reset=1` goes back to automatic) |
| GET | `/api/households/:id/spend?date=YYYY-MM-DD` | monthly spend on a date |
| POST | `/api/households/:id/optimize` | compute and store an optimizer run |
| GET | `/api/optimization-runs/:id` | the run, its steps, counted saving, finding outcomes |
| POST | `/api/optimization-runs/:id/preview` | run the steps, then roll back |
| POST | `/api/optimization-runs/:id/apply` | run the steps and commit (409 if stale) |
| POST | `/api/households/:id/what-if` | `{type, ...}` simulate one change |
| GET / POST | `/api/households/:id/scenarios` | saved scenarios / `{name, change}` save one |
| GET / DELETE | `/api/scenarios/:id` | re-simulate on today's data / delete |
| GET | `/api/scenarios/compare?a=&b=` | two scenarios side by side |

Every change made through the API runs as one transaction: lock the
household, make the change, re-run the optimizer, commit. If any step fails
(for example a trigger refuses it), the whole thing rolls back.

Limits: the exact search hits its 1.5 s cap from about 10 members and 20
subscriptions and then returns its best valid answer, flagged as not proven
cheapest. See report.md §16.
