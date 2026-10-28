# SubWatch — Viva Prep

Short answers to the questions a panel is most likely to ask, grouped by topic.
Each answer points at where the thing lives in the code so you can open it
if they ask "show me".

---

## 1. The idea

**Q: What does your project do, in one line?**
It tracks a household's subscriptions and uses SQL to find money being
wasted: paying twice for something, people on separate plans when a family
plan is cheaper, bundles that would be cheaper, and subscriptions nobody uses
anymore. v2 then works out the cheapest set of subscriptions that still gives
everyone what they use, lets you simulate a change before making it, and rates
how sure it is about each finding. It can apply the fix for you.

**Q: Apps like this already exist. What's new?**
Five things existing trackers don't do:
1. **Entitlement graph.** We model "plan X includes plan Y" (Airtel →
   Amazon Prime → Prime Video) and walk it with a recursive query. That catches
   duplicates that are invisible if you only compare service names.
2. **Household level.** Plans have member capacity and usage is logged per
   person, so the system can merge people onto shared plans, find free slots,
   and split a shared bill fairly by who actually uses it.
3. **Bank statement import.** Pure SQL finds recurring charges in a raw
   statement and checks them against what you track. That includes catching
   something you "cancelled" that is still being charged.
4. **One decision for the whole household.** Separate findings can contradict
   each other (a bundle and a cancel both claim the same saving). The optimizer
   picks one combination that keeps everyone's needs covered at the lowest cost.
5. **What-if and confidence.** You can ask "what if Priya moves out?" and see who
   loses what and the cheapest repair, without changing any data. Every
   finding also carries evidence and a High / Medium / Low confidence.

**Q: Why households and not individuals?**
Most waste comes from people *around* you: two flatmates each paying for
YouTube Premium, or your phone plan already including something your sibling
pays for. You can't see that one person at a time.

---

## 2. Schema and normalization

**Q: Walk us through the ER diagram.**
(report.md §2.) The catalog is `CATEGORIES → SERVICES → PLAN_CATALOG`. Prices
live in `PLAN_PRICE_HISTORY`, one row per price per date range.
- `PLAN_INCLUSION_HISTORY` is a recursive many-to-many relationship on
  PLAN_CATALOG: plan includes plan, for a date range. (In v1 it was called
  ENTITLEMENTS, and a view with that name still shows today's rows.)
- People are `USERS`, grouped into `HOUSEHOLDS` through `HOUSEHOLD_MEMBERS`.
- A `SUBSCRIPTION` is one payer buying one plan; `SUBSCRIPTION_MEMBERS` says
  who shares it.
- `USAGE_LOGS` records who used what, and when.
- `ALERTS` + `ALERT_SUBSCRIPTIONS` store the findings, and `FINDING_EVIDENCE`
  stores the facts behind each one.
- `MEMBER_NEEDS` records what each person needs. `OPTIMIZATION_RUNS` and
  `OPTIMIZATION_STEPS` store what the optimizer and the what-if simulator
  produce, and `SCENARIOS` stores named what-ifs.
- The import side is `STATEMENT_IMPORTS → BANK_TRANSACTIONS`, plus
  `MERCHANT_ALIASES` for matching charges to services.

**Q: Why is ENTITLEMENTS a separate table and not a column on PLANS?**
One plan can include many plans (Apple One includes three), and one plan can
be included by many (Amazon Prime is included in several telecom plans). That
makes it M:N, so it needs a junction table. Both foreign keys point at the same
table, which is why it's called a recursive (unary) relationship. In v2 it also
carries `valid_from` and `valid_to`, so a plan can gain or lose an included
service over time.

**Q: Why is the price on the plan and not on SUBSCRIPTIONS?**
Price depends on the plan, not on the subscription. If it lived on
SUBSCRIPTIONS we'd have `subscription_id → plan_id → price`, a transitive
dependency, which breaks 3NF, and every Spotify Family row would repeat ₹179.
In v2 it sits in PLAN_PRICE_HISTORY so a price rise is a new row, not an
overwrite.
*Trade-off to admit if pushed:* real life has promo prices; supporting them
would need a nullable `price_override` on SUBSCRIPTIONS.

**Q: `monthly_price` can be calculated from price + billing_cycle. Isn't storing it redundant?**
It's a `GENERATED ALWAYS AS (...) STORED` column. The database computes it on
every write and nobody can set it by hand, so it can never be out of sync. We
keep it so every query can compare weekly, quarterly and yearly plans on one
basis without repeating the CASE expression everywhere.

**Q: Why is there no household_id on SUBSCRIPTIONS or STATEMENT_IMPORTS?**
It's derivable: subscription → payer → household. Storing it would be a
transitive dependency and could contradict the payer's actual household.

**Q: Why does USAGE_LOGS have a composite foreign key?**
`(subscription_id, user_id) REFERENCES subscription_members`. That makes it
impossible, at the schema level, to log usage for someone who isn't a member
of that subscription. No app code is needed for that rule.

**Q: Why ALERT_SUBSCRIPTIONS instead of `subscription_id` columns on ALERTS?**
One finding can involve any number of subscriptions; the Spotify family-plan
suggestion involves three. Fixed columns (`subscription_id`,
`related_subscription_id`) can't hold that without breaking 1NF. The `role`
column marks the *subject* (what to cancel or change) and the *source* (what
explains it, e.g. the telecom plan).

**Q: Isn't ALERTS denormalized? It's just the output of your views.**
Yes, on purpose. If alerts were only computed live, dismissing one would be
impossible, because it would come straight back. Each alert has a
`fingerprint` like `dup:5`; `refresh_alerts()` matches on it, inserts new
findings, updates open ones, deletes stale ones and never touches dismissed
ones.

**Q: Why surrogate keys everywhere instead of natural/composite keys?**
Shorter foreign keys and simpler joins. A natural key like (user, plan) would
also be *wrong* for SUBSCRIPTIONS: someone can cancel Netflix and resubscribe
later, which is two rows with the same user and plan.

---

## 3. Constraints and triggers

**Q: Which rules are CHECK constraints and which are triggers? Why the split?**
- **CHECK:** anything about a single row (`price >= 0`, valid status,
  `end_date >= start_date`, included plans must be free and not purchasable).
- **Triggers:** rules that need other rows or tables. A CHECK can't count rows
  or look up another table. The triggers are:
  - plan capacity
  - same-household sharing
  - no subscribing to an included-only plan
  - auto-adding the payer as a member
  - the payer can't be removed from their own subscription
  - (v2) an included-only plan must cost 0, and a run's steps must add up to
    its cost change, checked at COMMIT by a deferred trigger

**Q: Your capacity trigger does `SELECT ... FOR UPDATE`. Why?**
Without it, two people joining the last free slot at the same instant could
both count "1 of 2 used", both pass, and the plan ends up with 3 members.
Locking the parent subscription row makes the second insert wait until the
first commits; then it sees the plan is full.

**Q: What happens to members and usage when a subscription is deleted?**
`ON DELETE CASCADE` removes them. The "payer can't be removed" trigger allows
this because during a cascade the parent row is already gone, so the trigger's
check finds nothing to protect.

---

## 4. The queries

**Q: Explain the recursive CTE.** (`v_entitlement_closure`)
- The anchor part selects every direct edge (depth 1).
- The recursive part joins the result back to ENTITLEMENTS to go one level
  deeper.
- It stops when no new rows appear.
- The path is carried as an array; `WHERE next <> ALL(path)` stops infinite
  loops if the graph ever had a cycle.
- The result is the transitive closure: every plan you ultimately get access to.

**Q: How do you know *everyone* on the duplicate subscription is covered?**
A subset test written as a double negative: "there is NO member of A who is NOT
a member of B": `NOT EXISTS (... NOT EXISTS (...))`. SQL has no "for all", so
that's how you write one.

**Q: What is relational division and where do you use it?**
"Find X related to *all* Y." We use it for bundles: does the household already
pay for *every* service in Apple One? Written as "there is no service in the
bundle that the household does not pay for" (`v_bundle_opportunities`,
`covers_everything`).

**Q: How does the family-plan suggestion pick the plan?**
For each shared tier: `cost = ceil(people / max_members) × price`, and
`ROW_NUMBER()` picks the cheapest. For 2 people, Spotify Duo (₹149) beats
Family (₹179). For 3 people, Family (₹179) beats 2 × Duo (₹298). The Iyer and
Sharma households show both cases.

**Q: How do you predict usage is falling?**
- `v_usage_buckets` counts sessions in six 30-day windows, using
  `generate_series` + `LEFT JOIN` so empty windows show up as 0. If they were
  missing, the trend would look flat.
- `v_churn_risk` fits a line with `REGR_SLOPE` / `REGR_INTERCEPT` (least
  squares, built into Postgres).
- It flags a subscription if it was really used, is dropping by at least 1
  session per window, will hit zero within 90 days, and is still in use (dead
  ones are "unused" instead).

**Q: Where do you use window functions?**
- `ROW_NUMBER()` picks the cheapest family plan and the least-used service.
- `COUNT/SUM/MAX OVER` give category totals in the overlap check.
- `SUM OVER` gives each member's share of total minutes (fair share).
- `LAG()` gives the gaps between bank charges.
- A running `SUM OVER` numbers the islands in the statement import.

**Q: How is a shared bill split?**
`share = price × (0.5 / members + 0.5 × my_minutes / total_minutes)`. Half
is for having access, half is for what you actually use. With no usage logged
it falls back to an equal split. Settle-up then nets opposite debts: A owes B
₹400 and B owes A ₹96 becomes one transfer of ₹304.

---

## 5. Transactions and concurrency

**Q: How does "Preview fix" work without changing anything?**
The API opens a transaction, calls `apply_alert()` (which really cancels,
creates and moves subscriptions), reads the new totals, then `ROLLBACK`s.
Apply runs exactly the same code but ends with `COMMIT`. That's atomicity
from ACID, shown on screen.

**Q: What if applying a fix fails halfway?**
Everything rolls back. For example, if moving someone onto a family plan
breaks the capacity trigger, the new plan and any cancellations already made
in that transaction are undone too. You never end up half-applied.

**Q: Fun fact they might poke at:** after a preview, new subscription ids skip
numbers. Sequences (`SERIAL`) are deliberately *not* rolled back. It's a
performance choice in Postgres, so ids can have gaps.

**Q: What if two people click Apply on the same finding?**
`apply_alert()` locks the alert row `FOR UPDATE`. The second click waits for
the first to commit, then sees the status is already `resolved` and gets a 409.
We tested this with two concurrent sessions.

**Q: Did you hit any concurrency bugs?**
Yes, a real deadlock, found while testing.
- Two different fixes in the same household ran at once. Each transaction
  re-ran `refresh_alerts()` and tried to update the same alert rows, but in a
  different order.
- T1 waited for T2's row while T2 waited for T1's. Postgres detected the cycle
  in its wait-for graph and killed one transaction (error `40P01`).
- **Fix:** every transaction that changes a household first takes a
  per-household advisory lock (`lock_household()` → `pg_advisory_xact_lock`).
  Same-household changes now queue in one order and can't form a cycle.
  Different households still run in parallel.
- When locking all households, we always lock in id order. Consistent lock
  ordering is the textbook way to prevent deadlock.
- After the fix: 5 stress runs of 22 simultaneous requests each, zero
  deadlocks.

**Q: Which isolation level do you use?**
Postgres's default, READ COMMITTED. It's enough because the places where a
race matters (last slot on a plan, applying a fix, refreshing alerts) use
explicit locks: `FOR UPDATE` and the advisory lock.

---

## 6. Performance

**Q: Did you look at query performance?**
Yes, and found something surprising. Preview was taking 14 seconds.
`EXPLAIN ANALYZE` showed the query itself ran in about 40 ms, and 13.2 s went to
JIT compilation (LLVM compiling the query to machine code first).
- **Why:** the detector views are nested several levels deep. The planner
  multiplies its row estimates through each level, guessed a cost of 42
  million, and that crossed the JIT threshold.
- **Fix:** `jit = off` for the database and the two heavy routines.
- **Result:** preview went from 14 s to about 0.06–0.15 s, roughly 100–200×
  faster.

**Q: Which indexes did you add and why?**
Foreign-key columns that get joined or filtered constantly: payer, plan,
member user, the included plan in ENTITLEMENTS, and `alerts(household_id,
status)`. Also `usage_logs(subscription_id, used_at)`, because every usage
query filters on one subscription and a time window. Postgres doesn't index
foreign keys automatically.

**Q: Why views and not materialized views?**
At this size the views run in milliseconds, and they're always up to date.
With many thousands of households we'd materialize the expensive ones and
refresh them on a schedule. `refresh_alerts()` already acts as a snapshot.

---

## 7. Bank statement import

**Q: How do you tell a subscription apart from food orders?**
Steps (all in `v_statement_series` and `v_recurring_charges`):
1. **Clean the description.** Upper-case it and drop any token containing
   digits (reference numbers, card numbers), so the same merchant always
   looks the same.
2. **Group the charges.** Same merchant, same amount, roughly the same day of
   the month.
3. **Check the gaps between charges** with `LAG()`. Monthly means 3+ charges
   about 25–35 days apart with a spread of 3 days or less. Quarterly and yearly
   need 2+.

Swiggy, Uber and electricity never qualify because the amount changes every
time, so they never form a series.

**Q: What's "gaps and islands"?**
A classic SQL pattern for splitting sorted rows into runs.
- **The problem:** Rahul pays Apple ₹99 twice a month, on the 3rd (Apple Music)
  and the 22nd (Apple TV+). Grouped only by merchant and amount, that looks
  like one charge every ~15 days, which matches no cycle.
- **The pattern:** sort the charges by day of month, mark a "new island"
  whenever the day jumps by more than 3, and number the islands with a running
  `SUM() OVER`.
- **Result:** two clean monthly series, each matched to the right subscription
  by billing day.

**Q: How is a charge matched to a plan?**
`MERCHANT_ALIASES` regex patterns map the description to a service (one
pattern can map to several, e.g. APPLE.COM/BILL). The amount and cycle then
pick the plan (₹199 monthly from NETFLIX = Netflix Basic). If several plans
fit, the user chooses.

**Q: What can't it detect?**
- Weekly charges (the day-of-month grouping splits them up).
- Yearly plans unless the statement covers 13+ months.
- A price change partway through, which splits the series in two.
- Two identical charges from the same merchant on the same day.

**Q: Isn't storing bank statements a privacy risk?**
In this prototype it's a local database. For real use: store only date,
description and amount (which is all we store); encrypt at rest; delete raw
transactions once the subscriptions are confirmed; and add row-level security
so nobody can read another household's data.

---

## 8. Limitations and future scope

**Q: Biggest weakness?**
No real authentication. The API trusts the ids in the URL. The fix we'd
build next is login plus Postgres **row-level security**, so the database
itself refuses to return another household's rows, even if the app has a bug.

**Q: What would you add next?**
- Row-level security and login.
- Price-hike alerts built on the price history we now store.
- A stronger search for big households (see section 9, scaling).
- A scheduled nightly refresh (e.g. `pg_cron`).
- Pulling usage automatically instead of logging it by hand.
- Supporting promo prices with a per-subscription price override.

---

## 9. v2: history, needs, optimizer, what-if, confidence

**Q: What is an exclusion constraint and why did you need one?**
Prices and inclusions are stored as date ranges. A normal UNIQUE can't stop two
ranges overlapping, because they can start on different dates and still
overlap. `EXCLUDE USING gist (plan_id WITH =, valid_during WITH &&)` says: no
two rows with the same plan and overlapping ranges. The database refuses the
insert, so "what was the price on this date" can never have two answers. It
needs the `btree_gist` extension so a plain integer and a range can share one
constraint. (`plan_price_history`, `plan_inclusion_history`)

**Q: You changed the main tables. Didn't that break everything?**
No. `plans` and `entitlements` are now views over the history tables that show
the rows valid today, so every v1 query, trigger and route runs unchanged. To
prove it, `db/tests/snapshot.sql` writes everything v1 computes to CSV, and
`regress.sh` diffs a fresh database against the v1 copy after every change.
It stayed identical through every step.

**Q: How do you ask "what did this plan include last year"?**
`entitlement_closure_at(date)`. It is the same recursive walk, but each step
keeps the intersection of the date ranges so far, so a path only counts while
every edge on it is valid. `household_spend_at(household, date)` does the same
for prices. The dashboard's "spend on date" box uses it.

**Q: What is a "need" and why does it belong to a person?**
It's a fact that a person uses a service. It sits on the household member, not
on a subscription, because the optimizer's job is to move people between
subscriptions. A need has to stay put while that happens. It comes from usage
in the last 30 days, from passive services reached through any plan, or from
the owner by hand. (`member_needs`, report.md §11)

**Q: Why are phone plans and cloud storage always "needed"?**
They have no usage logs, so by usage alone they look dead and the optimizer
would cancel them. Anyone who can reach a passive-category service through an
active plan, at any depth, needs it. At any depth because Apple One covers
iCloud+: once Rahul moves to it, his iCloud+ need must still count as covered.

**Q: What is the optimizer solving, and how?**
Choose which plans the household holds and who is on each, so every need stays
covered, no plan goes over capacity and the cost is as low as possible. That is
weighted set cover with capacity limits. We use branch and bound in Node: branch
on the uncovered need with the fewest options, start from today's setup as the
first upper bound, tighten it with a greedy pass, and cut any branch that can't
beat the best answer. The database loads the input and checks the result.
(`server/optimizer.js`, report.md §12)

**Q: Why is the search in Node and not in SQL?**
Search with pruning and backtracking is awkward in SQL and fast in a normal
language. SQL does what it's good at: `optimizer_input()` builds one JSON
document, and `apply_optimization()` applies the answer through the normal
triggers and re-checks it. The search can't corrupt data, because anything it
suggests still has to pass the database's own rules.

**Q: Is the answer really the cheapest?**
Yes on our households: all three are solved exactly in under 60 ms, and a unit
test compares it with an exhaustive search on 40 random households. On big
households the search stops at 1.5 s and returns the best valid answer with
`is_optimal = false`.

**Q: What are the rules it follows?**
- Every need that is covered today stays covered.
- A passive subscription is only replaced by a plan covering the same service
  for the same people, never just cancelled.
- No student plans (no eligibility data) and no service nobody uses today.
- No splitting: a service never ends up with more plans than it has now.
- A change must save at least ₹10 a month.

**Q: Why the "no splitting" rule?**
Without it the search replaces one shared Netflix Premium (₹649, four people)
with four Netflix Mobile plans (₹596). That is cheaper on paper but a worse
product, and the optimizer can't see quality. The rule makes the result easy to
defend.

**Q: Why the ₹10 minimum?**
Sharma's YouTube Premium Family costs ₹299 and two Individual plans cost ₹298.
The search would make three changes to save ₹1. `MIN_SAVING` skips changes that
small. It is measured per dropped subscription by searching again with it kept.

**Q: What does the optimizer find that v1 didn't?**
For Sharma it saves ₹660.84 against v1's ₹610.84. The extra ₹50 is Dev's
JioHotstar Super going to Mobile, because nobody else on it used it in 30 days.
Hostel (₹285) and Iyer (₹1,788) match v1 exactly. It also decides conflicts:
each v1 finding is labelled adopted, superseded or rejected.

**Q: What if the household changes between "Run" and "Apply"?**
Each run stores a `state_hash`, an md5 of the optimizer input. Apply takes the
household lock and compares it. If it differs, the run is marked stale and
refused (HTTP 409), and the page offers Run again. This is optimistic
concurrency: nobody holds a lock while thinking, but a stale answer can never
be applied.

**Q: What stops a bad run from being applied?**
`apply_optimization()` runs the steps through the normal triggers, then checks
that every need that was covered still is, that no passive service was
cancelled, and that the cost equals the promised `cost_after`. If any check
fails it raises, and the whole transaction rolls back. A test injects a failure
in the last step and confirms nothing changed.

**Q: How does what-if avoid changing data?**
It never touches the tables. `server/whatif.js` applies the change to an
in-memory copy of `optimizer_input()` and re-runs the optimizer on that copy to
find the cheapest repair. A test runs 123 scenarios and compares row counts and
hashes of all 18 live tables before and after: nothing changes. What-if runs are
stored with `kind = 'what_if'`, and `apply_optimization()` refuses them.

**Q: Example of a what-if?**
Priya moves out of the Sharma household. Cost drops from ₹3,036.51 to
₹2,038.59, but Arjun, Meera and Dev lose Netflix and Dev loses YouTube Premium.
The repair gives all four back for a new cost of ₹2,225.67.

**Q: How is confidence decided?**
Every finding stores evidence rows with weights: coverage 3 for a duplicate
(2 for a shared plan or bundle), price 1, usage 1 or 2, silence -3. Each type
counts once at its strongest row. Three or more is High, two is Medium, less is
Low. (`finding_evidence`, `v_finding_confidence`)

**Q: Why does 45 days of silence make a finding Low?**
"Unused for 60 days" means nothing if the person never logs anything. If a
member has logged no usage at all for 45 days, usage-based findings about them
are rated Low, kept out of "savings found" and shown muted under "worth a
look". Coverage findings stay High, because a duplicate is true whether or not
someone logs usage.

**Q: Where does the system fall short?** (say this before they ask)
- **Scaling.** From about 10 members and 20 subscriptions the exact search hits
  its 1.5 s cap. It then returns the best valid answer, flagged as not proven
  cheapest. The PRD's goal of exact answers for 15 members and 30 plans isn't
  met. The problem is NP-hard in general. Next steps: a stronger lower bound,
  splitting by service where plans don't overlap, and caching sub-problems.
- It can't see plan quality (Mobile vs Premium), so downgrades are labelled and
  never rated above Medium.
- Needs come from the last 30 days of usage, so seasonal use can be missed. The
  owner can add a need by hand.
- The confidence weights are our own judgement, not calibrated on real data.

**Q: What did the benchmark show?**
`node db/tests/benchmark.js` builds synthetic households of a chosen size inside
a rolled-back transaction and times v1 against the optimizer. v2 saved at least
as much as v1 every time. Households with 5 members are solved exactly in well
under 2 s.

**Q: How did you test it?**
Six layers, all on scratch databases:
1. A diff of v1's output against a saved baseline, after every change.
2. SQL checks for history, coverage, needs and reason paths (34).
3. Optimizer checks per household (28): never worse than v1, no need lost,
   nothing passive lost, no splitting, repeatable, a failure leaves nothing
   changed.
4. What-if checks (22): 123 scenarios, live tables unchanged, every repair
   re-covers every need.
5. Confidence checks (26).
6. 20 unit tests, including a comparison with an exhaustive search.

---

## 10. Three-minute demo order

Re-run the three SQL files first so the demo database is fresh.

1. **Sharma Household → Hidden entitlements panel.** Show the 2-level chain:
   Airtel → Amazon Prime → Prime Video, which Priya also pays for.
2. **Spotify family-plan finding → Preview fix.** Read the steps and the
   ₹3,037 → ₹2,919 drop, then point out the database didn't change. Don't
   apply.
3. **What-if.** Choose "remove a member", Priya. Show who loses what and the
   repair (₹2,038.59 before the repair, ₹2,225.67 after). Save it as a named
   scenario.
4. **Optimize my household → Run.** Read the first few steps and the total:
   ₹3,036.51 → ₹2,375.67, ₹50 more than v1's findings alone. Click **Preview**
   (nothing changes), then **Apply**.
5. **Needs panel.** Point at a passive need (the Airtel plan) and say why it
   can't be cancelled.
6. **Import Priya's sample statement.** It finds a forgotten second Netflix.
7. **Try to break it.** Add a third person to a 2-person plan; the database's
   own error appears in the UI.
8. *(Terminal, if asked about scaling)* `node db/tests/benchmark.js`.
