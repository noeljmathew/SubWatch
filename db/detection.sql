-- ============================================================================
-- SubWatch — Optimizer: detection views, insights, and refresh_alerts()
-- ============================================================================
-- Detectors (each is a view):
--   v_hidden_duplicates   paying for a service you already get through another
--                         plan — recursive walk of the entitlement graph
--   v_consolidation       several people paying for individual plans of the
--                         same service where a shared plan is cheaper
--   v_spare_capacity      someone pays alone while a shared plan in the
--                         household has a free slot
--   v_bundle_opportunities a bundle (e.g. Apple One) replaces 2+ subs for less;
--                         relational division checks full coverage
--   v_churn_risk          usage trending toward zero — linear regression
--                         (regr_slope) over 30-day buckets
--   v_waste               not used in 30+ days
--   v_category_overlap    several services in one category; flags the least used
-- Insights:
--   v_fair_share / v_settle_up / v_member_costs   usage-weighted cost splitting
--   renewal_forecast(household, days)             upcoming charges
-- ============================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------------
-- small formatting helpers for alert messages
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inr(n NUMERIC) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT '₹' || to_char(ROUND(n), 'FM9,99,99,999')
$$;

-- {'A','B','C'} -> 'A, B and C'
CREATE OR REPLACE FUNCTION human_list(items TEXT[]) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN cardinality(items) IS NULL OR cardinality(items) = 0 THEN ''
        WHEN cardinality(items) = 1 THEN items[1]
        ELSE array_to_string(items[1:cardinality(items) - 1], ', ') || ' and ' || items[cardinality(items)]
    END
$$;

CREATE OR REPLACE FUNCTION first_name(full_name TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT split_part(full_name, ' ', 1)
$$;

-- ---------------------------------------------------------------------------
-- v_subscription_detail — one row per subscription with everything the
-- detectors need: plan, service, category, household, members, usage stats
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_subscription_detail AS
WITH member_stats AS (
    SELECT sm.subscription_id,
           COUNT(*)::int AS member_count,
           STRING_AGG(u.full_name, ', ' ORDER BY u.full_name) AS member_names
    FROM subscription_members sm
    JOIN users u ON u.user_id = sm.user_id
    GROUP BY sm.subscription_id
),
usage_stats AS (
    SELECT subscription_id,
           COUNT(*)::int AS total_sessions,
           (COUNT(*) FILTER (WHERE used_at >= now() - interval '30 days'))::int AS sessions_30d,
           COALESCE(SUM(duration_minutes) FILTER (WHERE used_at >= now() - interval '30 days'), 0)::int AS minutes_30d,
           MAX(used_at) AS last_used_at
    FROM usage_logs
    GROUP BY subscription_id
)
SELECT
    s.subscription_id,
    hm.household_id,
    s.payer_id,
    pu.full_name                       AS payer_name,
    p.plan_id,
    p.name                             AS plan_name,
    p.tier,
    p.max_members,
    p.price,
    p.billing_cycle,
    p.monthly_price,
    sv.service_id,
    sv.name                            AS service_name,
    c.category_id,
    c.name                             AS category_name,
    c.is_passive,
    s.start_date,
    s.end_date,
    s.status,
    COALESCE(ms.member_count, 0)       AS member_count,
    ms.member_names,
    COALESCE(us.total_sessions, 0)     AS total_sessions,
    COALESCE(us.sessions_30d, 0)       AS sessions_30d,
    COALESCE(us.minutes_30d, 0)        AS minutes_30d,
    us.last_used_at,
    EXTRACT(DAY FROM now() - COALESCE(us.last_used_at, s.start_date::timestamptz))::int AS days_since_last_use
FROM subscriptions s
JOIN plans p              ON p.plan_id = s.plan_id
JOIN services sv          ON sv.service_id = p.service_id
JOIN categories c         ON c.category_id = sv.category_id
JOIN users pu             ON pu.user_id = s.payer_id
JOIN household_members hm ON hm.user_id = s.payer_id
LEFT JOIN member_stats ms ON ms.subscription_id = s.subscription_id
LEFT JOIN usage_stats us  ON us.subscription_id = s.subscription_id;

-- ---------------------------------------------------------------------------
-- path_label — a path of plan ids as text: the first plan with its plan
-- name, the rest by service: 'Airtel Postpaid (Family 1199) → Amazon Prime
-- → Prime Video'. Used for every reason path (FR-38).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION path_label(p_path INT[]) RETURNS TEXT
LANGUAGE sql STABLE
SET jit = off
AS $$
    SELECT STRING_AGG(CASE WHEN x.ord = 1 THEN xs.name || ' (' || xp.name || ')' ELSE xs.name END,
                      ' → ' ORDER BY x.ord)
    FROM UNNEST(p_path) WITH ORDINALITY AS x(plan_id, ord)
    JOIN plan_catalog xp ON xp.plan_id = x.plan_id
    JOIN services xs     ON xs.service_id = xp.service_id
$$;

-- ---------------------------------------------------------------------------
-- v_inclusion_closure — transitive closure of the entitlement graph over
-- time. Every (root plan, plan it ultimately unlocks) pair, with depth, the
-- path, and the dates the whole path is valid: the intersection (*) of every
-- edge's range along it. A path whose edges were never valid at the same time
-- is pruned (&&). The path array also prevents infinite loops on cycles.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_inclusion_closure AS
WITH RECURSIVE walk AS (
    SELECT h.parent_plan_id AS root_plan_id,
           h.included_plan_id,
           1 AS depth,
           ARRAY[h.parent_plan_id, h.included_plan_id] AS path,
           h.valid_during
    FROM plan_inclusion_history h
    UNION ALL
    SELECT w.root_plan_id,
           h.included_plan_id,
           w.depth + 1,
           w.path || h.included_plan_id,
           w.valid_during * h.valid_during
    FROM walk w
    JOIN plan_inclusion_history h ON h.parent_plan_id = w.included_plan_id
    WHERE h.included_plan_id <> ALL (w.path)
      AND h.valid_during && w.valid_during
)
SELECT w.root_plan_id, w.included_plan_id, ip.service_id AS included_service_id,
       w.depth, w.path, w.valid_during
FROM walk w
JOIN plan_catalog ip ON ip.plan_id = w.included_plan_id;

-- ---------------------------------------------------------------------------
-- v_entitlement_closure — the closure as it is today (what v1 walked), with a
-- readable path. entitlement_closure_at() is the same for any other date.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_entitlement_closure AS
SELECT root_plan_id, included_plan_id, included_service_id, depth, path,
       path_label(path) AS path_label
FROM v_inclusion_closure
WHERE valid_during @> CURRENT_DATE;

CREATE OR REPLACE FUNCTION entitlement_closure_at(p_date DATE)
RETURNS TABLE (root_plan_id INT, included_plan_id INT, included_service_id INT,
               depth INT, path INT[], path_label TEXT)
LANGUAGE sql STABLE
SET jit = off
AS $$
    SELECT root_plan_id, included_plan_id, included_service_id, depth, path, path_label(path)
    FROM v_inclusion_closure
    WHERE valid_during @> p_date
$$;

-- ---------------------------------------------------------------------------
-- v_plan_coverage — every service a purchasable plan gives access to today:
-- its own service (depth 0) plus everything it reaches through included
-- plans at any depth. The one traversal behind hidden duplicates, bundles,
-- member coverage and (v2b) the optimizer's candidate expansion.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_plan_coverage AS
SELECT p.plan_id, p.service_id, 0 AS depth, ARRAY[p.plan_id] AS path,
       path_label(ARRAY[p.plan_id]) AS path_label
FROM plan_catalog p
WHERE p.is_purchasable
UNION ALL
SELECT root_plan_id, included_service_id, depth, path, path_label
FROM v_entitlement_closure;

-- ---------------------------------------------------------------------------
-- v_member_coverage — who can use which service today, and through which
-- active subscription: one row per (member, subscription, service reached).
-- A member reaching a service through two subscriptions gets two rows.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_member_coverage AS
SELECT hm.household_id, sm.user_id, pc.service_id,
       s.subscription_id, s.plan_id, pc.depth, pc.path, pc.path_label
FROM subscriptions s
JOIN household_members hm    ON hm.user_id = s.payer_id
JOIN subscription_members sm ON sm.subscription_id = s.subscription_id
JOIN v_plan_coverage pc      ON pc.plan_id = s.plan_id
WHERE s.status = 'active';

-- ---------------------------------------------------------------------------
-- v_hidden_duplicates — an active subscription is redundant if another active
-- subscription in the household gives access to the same service AND every
-- member of the redundant one is a member of the one that covers it.
-- "Gives access" means either:
--   depth 0: it's the same service (you're already on someone's family plan)
--   depth 1+: it unlocks the service through the entitlement graph
-- For depth 0, the covering plan must be the "bigger" one (more members, then
-- higher price, then older) so two identical subs don't flag each other.
-- When several subscriptions explain it, the shortest path wins.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_hidden_duplicates AS
SELECT DISTINCT ON (dup.subscription_id)
    dup.household_id,
    dup.subscription_id,
    dup.service_name,
    dup.plan_name,
    dup.payer_name,
    dup.monthly_price,
    src.subscription_id AS via_subscription_id,
    src.service_name    AS via_service,
    src.plan_name       AS via_plan,
    src.payer_name      AS via_payer,
    cl.depth,
    cl.path_label,
    dup.payer_id,
    src.payer_id        AS via_payer_id,
    cl.path
FROM v_subscription_detail dup
JOIN v_subscription_detail src
    ON  src.household_id = dup.household_id
    AND src.subscription_id <> dup.subscription_id
    AND src.status = 'active'
JOIN v_plan_coverage cl
    ON  cl.plan_id = src.plan_id
    AND cl.service_id = dup.service_id
WHERE dup.status = 'active'
  AND (cl.depth > 0
       OR src.member_count > dup.member_count
       OR (src.member_count = dup.member_count
           AND (src.monthly_price > dup.monthly_price
                OR (src.monthly_price = dup.monthly_price AND src.subscription_id < dup.subscription_id))))
  AND NOT EXISTS (
        SELECT 1 FROM subscription_members dm
        WHERE dm.subscription_id = dup.subscription_id
          AND NOT EXISTS (SELECT 1 FROM subscription_members sm
                          WHERE sm.subscription_id = src.subscription_id
                            AND sm.user_id = dm.user_id))
ORDER BY dup.subscription_id, cl.depth, src.monthly_price DESC;

-- ---------------------------------------------------------------------------
-- v_consolidation — 2+ people in a household each on a single-person plan of
-- the same service. For every shared tier, cost = ceil(people / capacity) x
-- price; the cheapest option wins if it beats what they pay now.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_consolidation AS
WITH singles AS (
    SELECT d.household_id, d.service_id, d.service_name,
           COUNT(*)::int                                             AS people,
           SUM(d.monthly_price)                                      AS current_cost,
           ARRAY_AGG(first_name(d.payer_name) ORDER BY d.payer_name) AS names,
           ARRAY_AGG(d.subscription_id ORDER BY d.subscription_id)   AS subscription_ids
    FROM v_subscription_detail d
    WHERE d.status = 'active'
      AND d.tier IN ('individual', 'student')
      AND d.member_count = 1
      AND d.subscription_id NOT IN (SELECT subscription_id FROM v_hidden_duplicates)
    GROUP BY d.household_id, d.service_id, d.service_name
    HAVING COUNT(*) >= 2
),
options AS (
    SELECT s.*,
           p.plan_id, p.name AS plan_name, p.max_members,
           CEIL(s.people::numeric / p.max_members)::int                  AS plans_needed,
           CEIL(s.people::numeric / p.max_members) * p.monthly_price     AS new_cost,
           ROW_NUMBER() OVER (PARTITION BY s.household_id, s.service_id
                              ORDER BY CEIL(s.people::numeric / p.max_members) * p.monthly_price,
                                       p.max_members) AS rn
    FROM singles s
    JOIN plans p ON p.service_id = s.service_id
    WHERE p.is_purchasable AND p.max_members >= 2
)
SELECT household_id, service_id, service_name, people, names, subscription_ids, current_cost,
       plan_id AS recommended_plan_id, plan_name AS recommended_plan, max_members,
       plans_needed, new_cost, current_cost - new_cost AS savings
FROM options
WHERE rn = 1 AND new_cost < current_cost;

-- ---------------------------------------------------------------------------
-- v_spare_capacity — someone pays alone for a service while a shared plan of
-- that same service in their household still has a free slot
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_spare_capacity AS
SELECT DISTINCT ON (single.subscription_id)
    single.household_id,
    single.subscription_id,
    single.payer_name       AS person,
    single.service_name,
    single.plan_name        AS own_plan,
    single.monthly_price    AS own_cost,
    host.subscription_id    AS host_subscription_id,
    host.payer_name         AS host_payer,
    host.plan_name          AS host_plan,
    host.member_count,
    host.max_members
FROM v_subscription_detail single
JOIN v_subscription_detail host
    ON  host.household_id = single.household_id
    AND host.service_id = single.service_id
    AND host.subscription_id <> single.subscription_id
WHERE single.status = 'active' AND host.status = 'active'
  AND single.tier IN ('individual', 'student')
  AND single.member_count = 1
  AND host.max_members > 1
  AND host.member_count < host.max_members
  AND NOT EXISTS (SELECT 1 FROM subscription_members sm
                  WHERE sm.subscription_id = host.subscription_id AND sm.user_id = single.payer_id)
  AND single.subscription_id NOT IN (SELECT subscription_id FROM v_hidden_duplicates)
ORDER BY single.subscription_id, host.max_members - host.member_count DESC;

-- ---------------------------------------------------------------------------
-- v_bundle_opportunities — a purchasable plan whose entitlements cover 2+
-- services the household pays for separately, for less money. Telecom/cloud
-- (passive categories) aren't suggested as bundles. covers_everything is
-- relational division: "is there NO service in the bundle that the household
-- does NOT already pay for?"
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_bundle_opportunities AS
WITH bundle_services AS (
    SELECT DISTINCT p.plan_id, cl.service_id
    FROM plans p
    JOIN v_plan_coverage cl ON cl.plan_id = p.plan_id AND cl.depth > 0
    JOIN services s   ON s.service_id = p.service_id
    JOIN categories c ON c.category_id = s.category_id
    WHERE p.is_purchasable AND NOT c.is_passive
),
active AS (
    SELECT * FROM v_subscription_detail
    WHERE status = 'active'
      AND subscription_id NOT IN (SELECT subscription_id FROM v_hidden_duplicates)
),
candidates AS (
    SELECT a.household_id, bs.plan_id,
           COUNT(DISTINCT a.service_id)                         AS replaced_services,
           ARRAY_AGG(a.subscription_id ORDER BY a.subscription_id) AS replaced_ids,
           ARRAY_AGG(DISTINCT a.service_name)                   AS replaced_names,
           SUM(a.monthly_price)                                 AS current_cost
    FROM active a
    JOIN bundle_services bs ON bs.service_id = a.service_id
    GROUP BY a.household_id, bs.plan_id
    HAVING COUNT(DISTINCT a.service_id) >= 2
)
SELECT
    c.household_id,
    c.plan_id                       AS recommended_plan_id,
    s.name                          AS bundle_service,
    p.name                          AS bundle_plan,
    p.monthly_price                 AS bundle_cost,
    p.max_members,
    c.replaced_services,
    c.replaced_ids,
    c.replaced_names,
    c.current_cost,
    c.current_cost - p.monthly_price AS savings,
    NOT EXISTS (
        SELECT 1 FROM bundle_services bs
        WHERE bs.plan_id = c.plan_id
          AND NOT EXISTS (SELECT 1 FROM active a
                          WHERE a.household_id = c.household_id AND a.service_id = bs.service_id)
    ) AS covers_everything
FROM candidates c
JOIN plans p    ON p.plan_id = c.plan_id
JOIN services s ON s.service_id = p.service_id
WHERE c.current_cost > p.monthly_price
  AND NOT EXISTS (SELECT 1 FROM active a WHERE a.household_id = c.household_id AND a.service_id = p.service_id)
  AND (SELECT COUNT(DISTINCT sm.user_id) FROM subscription_members sm
        WHERE sm.subscription_id = ANY (c.replaced_ids)) <= p.max_members;

-- ---------------------------------------------------------------------------
-- v_usage_buckets — sessions per 30-day window for the last 180 days, with
-- empty windows filled in as 0 (generate_series + LEFT JOIN). x = 0 is the
-- oldest window, x = 5 the most recent one. Windows before the subscription
-- started are left out.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_usage_buckets AS
SELECT d.subscription_id,
       b.k,
       5 - b.k AS x,
       COUNT(ul.usage_log_id)::int AS sessions
FROM v_subscription_detail d
CROSS JOIN generate_series(0, 5) AS b(k)
LEFT JOIN usage_logs ul
    ON  ul.subscription_id = d.subscription_id
    AND ul.used_at <  now() - (b.k * 30)       * interval '1 day'
    AND ul.used_at >= now() - ((b.k + 1) * 30) * interval '1 day'
WHERE now() - (b.k * 30) * interval '1 day' > d.start_date
GROUP BY d.subscription_id, b.k;

-- ---------------------------------------------------------------------------
-- v_churn_risk — fit a line through the usage windows (least squares via
-- regr_slope / regr_intercept). Flag subscriptions that were used properly
-- (peak >= 4 sessions/window), are falling by at least 1 session per window,
-- and are projected to hit zero within 90 days — but are still in use (dead
-- ones are already "waste").
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_churn_risk AS
WITH fit AS (
    SELECT subscription_id,
           COUNT(*)                          AS windows,
           MAX(sessions)                     AS peak,
           REGR_SLOPE(sessions, x)           AS slope,
           REGR_INTERCEPT(sessions, x)       AS intercept,
           ARRAY_AGG(sessions ORDER BY x)    AS trend
    FROM v_usage_buckets
    GROUP BY subscription_id
)
SELECT d.household_id, d.subscription_id, d.service_name, d.plan_name, d.payer_name, d.monthly_price,
       f.trend,
       ROUND(f.slope::numeric, 2)                                            AS slope_per_window,
       ROUND(GREATEST(0, f.intercept + f.slope * 5)::numeric, 1)             AS projected_sessions_now,
       GREATEST(0, ROUND(((f.intercept + f.slope * 5) / -f.slope * 30)::numeric))::int AS days_until_unused
FROM fit f
JOIN v_subscription_detail d ON d.subscription_id = f.subscription_id
WHERE d.status = 'active'
  AND NOT d.is_passive
  AND f.windows >= 3
  AND f.peak >= 4
  AND f.slope <= -1
  AND (f.intercept + f.slope * 5) / -f.slope * 30 <= 90
  AND d.days_since_last_use < 30;

-- ---------------------------------------------------------------------------
-- v_waste — active, not passive, and nobody has used it in 30+ days
-- (subs already flagged as hidden duplicates are reported there instead)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_waste AS
SELECT d.household_id, d.subscription_id, d.service_name, d.plan_name, d.payer_name,
       d.monthly_price, d.total_sessions, d.days_since_last_use,
       CASE WHEN d.total_sessions = 0
            THEN 'has never been used since it started ' || d.days_since_last_use || ' days ago'
            ELSE 'hasn''t been used in ' || d.days_since_last_use || ' days'
       END AS reason
FROM v_subscription_detail d
WHERE d.status = 'active'
  AND NOT d.is_passive
  AND d.days_since_last_use >= 30
  AND d.subscription_id NOT IN (SELECT subscription_id FROM v_hidden_duplicates);

-- ---------------------------------------------------------------------------
-- v_category_overlap — a household paying for 2+ different services in the
-- same category; ranks them by recent usage and points at the least used one,
-- but only if it gets at most a quarter of the top service's usage
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_category_overlap AS
WITH per_service AS (
    SELECT d.household_id, d.category_id, d.category_name, d.service_id, d.service_name,
           SUM(d.sessions_30d)::int AS sessions_30d,
           SUM(d.monthly_price) AS monthly_cost,
           ARRAY_AGG(d.subscription_id ORDER BY d.subscription_id) AS subscription_ids
    FROM v_subscription_detail d
    WHERE d.status = 'active'
      AND NOT d.is_passive
      AND d.start_date <= CURRENT_DATE - 30          -- too new to judge usage yet
      AND d.subscription_id NOT IN (SELECT subscription_id FROM v_hidden_duplicates)
    GROUP BY d.household_id, d.category_id, d.category_name, d.service_id, d.service_name
),
ranked AS (
    SELECT ps.*,
           COUNT(*)          OVER w AS services_in_category,
           SUM(monthly_cost) OVER w AS category_cost,
           MAX(sessions_30d) OVER w AS top_sessions,
           ROW_NUMBER() OVER (PARTITION BY household_id, category_id
                              ORDER BY sessions_30d, monthly_cost DESC) AS usage_rank
    FROM per_service ps
    WINDOW w AS (PARTITION BY household_id, category_id)
),
names AS (
    SELECT household_id, category_id, ARRAY_AGG(service_name ORDER BY service_name) AS services
    FROM per_service
    GROUP BY household_id, category_id
)
SELECT r.household_id, r.category_id, r.category_name, r.services_in_category, r.category_cost,
       n.services,
       r.service_name            AS least_used_service,
       r.sessions_30d            AS least_used_sessions,
       r.subscription_ids        AS least_used_subscription_ids,
       r.monthly_cost            AS savings
FROM ranked r
JOIN names n ON n.household_id = r.household_id AND n.category_id = r.category_id
WHERE r.usage_rank = 1
  AND r.services_in_category >= 2
  AND r.sessions_30d <= 0.25 * r.top_sessions;   -- only when it's clearly the neglected one

-- ---------------------------------------------------------------------------
-- v_fair_share — how a shared subscription's cost should be split. Hybrid
-- rule: half split equally (everyone has access), half by minutes watched or
-- listened in the last 30 days. If nobody logged any usage, split equally.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_fair_share AS
WITH shared AS (
    SELECT * FROM v_subscription_detail
    WHERE status = 'active' AND member_count >= 2
),
member_use AS (
    SELECT sm.subscription_id, sm.user_id, u.full_name,
           COALESCE(SUM(ul.duration_minutes) FILTER (WHERE ul.used_at >= now() - interval '30 days'), 0)::int AS minutes_30d
    FROM shared s
    JOIN subscription_members sm ON sm.subscription_id = s.subscription_id
    JOIN users u                 ON u.user_id = sm.user_id
    LEFT JOIN usage_logs ul      ON ul.subscription_id = sm.subscription_id AND ul.user_id = sm.user_id
    GROUP BY sm.subscription_id, sm.user_id, u.full_name
)
SELECT s.household_id, s.subscription_id, s.service_name, s.plan_name,
       s.payer_id, s.payer_name, s.monthly_price, s.member_count,
       mu.user_id, mu.full_name, mu.minutes_30d,
       (SUM(mu.minutes_30d) OVER (PARTITION BY mu.subscription_id))::int AS total_minutes,
       ROUND(CASE
           WHEN SUM(mu.minutes_30d) OVER (PARTITION BY mu.subscription_id) = 0
               THEN s.monthly_price / s.member_count
           ELSE s.monthly_price * (0.5 / s.member_count
                + 0.5 * mu.minutes_30d / SUM(mu.minutes_30d) OVER (PARTITION BY mu.subscription_id))
       END, 2) AS fair_share
FROM shared s
JOIN member_use mu ON mu.subscription_id = s.subscription_id;

-- ---------------------------------------------------------------------------
-- v_settle_up — net "who pays whom" per month. Every member owes the payer
-- their fair share; opposite debts between the same two people cancel out.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_settle_up AS
WITH owes AS (
    SELECT household_id, user_id AS debtor_id, payer_id AS creditor_id, SUM(fair_share) AS amount
    FROM v_fair_share
    WHERE user_id <> payer_id
    GROUP BY household_id, user_id, payer_id
),
netted AS (
    SELECT household_id,
           LEAST(debtor_id, creditor_id)    AS u1,
           GREATEST(debtor_id, creditor_id) AS u2,
           SUM(CASE WHEN debtor_id < creditor_id THEN amount ELSE -amount END) AS net
    FROM owes
    GROUP BY household_id, LEAST(debtor_id, creditor_id), GREATEST(debtor_id, creditor_id)
)
SELECT n.household_id,
       CASE WHEN n.net > 0 THEN n.u1 ELSE n.u2 END AS from_user_id,
       CASE WHEN n.net > 0 THEN n.u2 ELSE n.u1 END AS to_user_id,
       fu.full_name AS from_name,
       tu.full_name AS to_name,
       ROUND(ABS(n.net), 2) AS amount
FROM netted n
JOIN users fu ON fu.user_id = CASE WHEN n.net > 0 THEN n.u1 ELSE n.u2 END
JOIN users tu ON tu.user_id = CASE WHEN n.net > 0 THEN n.u2 ELSE n.u1 END
WHERE ABS(n.net) >= 1;

-- ---------------------------------------------------------------------------
-- v_member_costs — per person: what they actually pay vs. their fair cost
-- (sole-member subs in full + their fair share of shared ones)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_member_costs AS
SELECT hm.household_id, u.user_id, u.full_name, hm.role,
       COALESCE((SELECT SUM(d.monthly_price) FROM v_subscription_detail d
                  WHERE d.payer_id = u.user_id AND d.status = 'active'), 0)                   AS pays,
       COALESCE((SELECT SUM(d.monthly_price) FROM v_subscription_detail d
                  WHERE d.payer_id = u.user_id AND d.status = 'active' AND d.member_count = 1), 0)
     + COALESCE((SELECT SUM(f.fair_share) FROM v_fair_share f WHERE f.user_id = u.user_id), 0) AS fair_cost
FROM household_members hm
JOIN users u ON u.user_id = hm.user_id;

-- ---------------------------------------------------------------------------
-- renewal_forecast — every charge coming up in the next p_days days. Each
-- renewal is computed from start_date + n * cycle (not by repeatedly adding a
-- month), so a plan that started on the 31st doesn't drift. Each charge is
-- priced at the plan's price on its renewal date (FR-37), so a price change
-- already on the books shows up from the first renewal after it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION renewal_forecast(p_household_id INT, p_days INT DEFAULT 30)
RETURNS TABLE (renewal_date DATE, subscription_id INT, service_name TEXT, plan_name TEXT,
               payer_name TEXT, billing_cycle TEXT, amount NUMERIC)
LANGUAGE sql STABLE
SET jit = off
AS $$
    SELECT r.renewal_date, d.subscription_id, d.service_name::text, d.plan_name::text,
           d.payer_name::text, d.billing_cycle::text, ph.price
    FROM v_subscription_detail d
    CROSS JOIN LATERAL (SELECT CASE d.billing_cycle
                                   WHEN 'weekly'    THEN interval '1 week'
                                   WHEN 'monthly'   THEN interval '1 month'
                                   WHEN 'quarterly' THEN interval '3 months'
                                   ELSE                  interval '1 year'
                               END AS step) c
    CROSS JOIN LATERAL generate_series(1, 600) AS g(n)
    CROSS JOIN LATERAL (SELECT (d.start_date + g.n * c.step)::date AS renewal_date) r
    LEFT JOIN plan_price_history ph ON ph.plan_id = d.plan_id AND ph.valid_during @> r.renewal_date
    WHERE d.household_id = p_household_id
      AND d.status = 'active'
      AND r.renewal_date BETWEEN CURRENT_DATE AND CURRENT_DATE + p_days
    ORDER BY r.renewal_date, ph.price DESC
$$;

-- ---------------------------------------------------------------------------
-- household_spend_at — what a household's subscriptions cost per month on
-- p_date, at the prices valid that day (FR-37). A subscription counts if it
-- had started and not yet ended then (cancelling sets end_date). Paused ones
-- don't count, as in v1.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION household_spend_at(p_household_id INT, p_date DATE)
RETURNS NUMERIC
LANGUAGE sql STABLE
SET jit = off
AS $$
    SELECT COALESCE(SUM(p.monthly_price), 0)
    FROM subscriptions s
    JOIN household_members hm ON hm.user_id = s.payer_id
    JOIN plans_at(p_date) p   ON p.plan_id = s.plan_id
    WHERE hm.household_id = p_household_id
      AND s.start_date <= p_date
      AND (s.end_date IS NULL OR s.end_date > p_date)
      AND s.status <> 'paused'
$$;

-- ---------------------------------------------------------------------------
-- v_findings — every detector's output in one shape, with a stable
-- fingerprint and a plain-English message. subject_paths is a JSON array
-- parallel to subject_ids: element i is the reason path (plan ids) for
-- subject i, or NULL for findings with no path (usage-based ones)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_findings AS
SELECT household_id, 'hidden_duplicate'::text AS alert_type,
       ARRAY[subscription_id] AS subject_ids, ARRAY[via_subscription_id] AS source_ids, NULL::int AS recommended_plan_id,
       'dup:' || subscription_id AS fingerprint,
       CASE WHEN depth = 0 AND payer_id = via_payer_id THEN
           format('%s pays for %s twice: %s (%s/mo) on top of the %s plan they already pay for.',
                  first_name(payer_name), service_name, plan_name, inr(monthly_price), via_plan)
       WHEN depth = 0 THEN
           format('%s pays %s/mo for their own %s (%s), but is already on %s''s %s %s plan.',
                  first_name(payer_name), inr(monthly_price), service_name, plan_name,
                  first_name(via_payer), via_service, via_plan)
       ELSE
           format('%s pays %s/mo for %s (%s), but already gets it through %s''s %s plan: %s.',
                  first_name(payer_name), inr(monthly_price), service_name, plan_name,
                  first_name(via_payer), via_service, path_label)
       END AS message,
       monthly_price AS savings,
       jsonb_build_array(to_jsonb(path)) AS subject_paths
FROM v_hidden_duplicates
UNION ALL
SELECT household_id, 'consolidation', subscription_ids, '{}'::int[], recommended_plan_id,
       'consolidate:' || service_id,
       format('%s each pay for %s separately (%s/mo). %s %s %s plan%s (up to %s people%s) would cover %s for %s/mo.',
              human_list(names), service_name, inr(current_cost),
              CASE plans_needed WHEN 1 THEN 'One' ELSE plans_needed::text END,
              service_name, recommended_plan, CASE WHEN plans_needed > 1 THEN 's' ELSE '' END,
              max_members, CASE WHEN plans_needed > 1 THEN ' each' ELSE '' END,
              CASE people WHEN 2 THEN 'both of them' ELSE 'all ' || people END,
              inr(new_cost)),
       savings,
       -- every subject is covered by the recommended shared plan (x.sid keeps
       -- the aggregate inside this subquery rather than the outer query)
       (SELECT jsonb_agg(CASE WHEN x.sid IS NOT NULL THEN to_jsonb(ARRAY[recommended_plan_id]) END ORDER BY x.ord)
          FROM UNNEST(subscription_ids) WITH ORDINALITY AS x(sid, ord))
FROM v_consolidation
UNION ALL
SELECT household_id, 'spare_capacity', ARRAY[subscription_id], ARRAY[host_subscription_id], NULL,
       'spare:' || subscription_id || ':' || host_subscription_id,
       format('%s''s %s %s has a free spot (%s of %s used). %s could join it and cancel their own %s plan (%s/mo).',
              first_name(host_payer), service_name, host_plan, member_count, max_members,
              first_name(person), own_plan, inr(own_cost)),
       own_cost,
       (SELECT jsonb_build_array(to_jsonb(ARRAY[s.plan_id])) FROM subscriptions s
         WHERE s.subscription_id = host_subscription_id)
FROM v_spare_capacity
UNION ALL
SELECT household_id, 'bundle', replaced_ids, '{}'::int[], recommended_plan_id,
       'bundle:' || recommended_plan_id,
       format('Your household pays separately for %s (%s/mo). %s %s includes %s for %s/mo.',
              human_list(replaced_names), inr(current_cost), bundle_service, bundle_plan,
              CASE WHEN covers_everything THEN 'all of them' ELSE 'these (and more)' END,
              inr(bundle_cost)),
       savings,
       -- per replaced subscription, the shortest path from the bundle to its service
       (SELECT jsonb_agg(to_jsonb((SELECT pc.path
                                     FROM v_plan_coverage pc
                                     JOIN subscriptions s ON s.subscription_id = x.sid
                                     JOIN plan_catalog p  ON p.plan_id = s.plan_id
                                    WHERE pc.plan_id = recommended_plan_id
                                      AND pc.service_id = p.service_id
                                      AND pc.depth > 0
                                    ORDER BY pc.depth, pc.path
                                    LIMIT 1)) ORDER BY x.ord)
          FROM UNNEST(replaced_ids) WITH ORDINALITY AS x(sid, ord))
FROM v_bundle_opportunities
UNION ALL
SELECT household_id, 'churn_risk', ARRAY[subscription_id], '{}'::int[], NULL,
       'churn:' || subscription_id,
       format('%s (%s) usage is falling: %s sessions per month over the last 6 months. At this rate nobody will be using it in about %s days.',
              service_name, plan_name, array_to_string(trend, ' → '), days_until_unused),
       monthly_price,
       NULL::jsonb
FROM v_churn_risk
UNION ALL
SELECT household_id, 'waste', ARRAY[subscription_id], '{}'::int[], NULL,
       'waste:' || subscription_id,
       format('%s (%s) %s. %s pays %s/mo for it.',
              service_name, plan_name, reason, first_name(payer_name), inr(monthly_price)),
       monthly_price,
       NULL::jsonb
FROM v_waste
UNION ALL
SELECT household_id, 'overlap', least_used_subscription_ids, '{}'::int[], NULL,
       'overlap:' || category_id,
       format('Your household pays for %s %s services (%s, %s/mo). %s is the least used, with %s session%s in the last 30 days.',
              services_in_category, category_name, human_list(services), inr(category_cost),
              least_used_service, least_used_sessions, CASE WHEN least_used_sessions = 1 THEN '' ELSE 's' END),
       savings,
       NULL::jsonb
FROM v_category_overlap;

-- ---------------------------------------------------------------------------
-- v_usage_data_quality — FR-40: how long each person has logged nothing at
-- all, across every subscription (since they joined, if never). 45 days or
-- more is flagged: their usage-based findings become Low.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_usage_data_quality AS
SELECT hm.household_id, hm.user_id, lu.last_logged_at,
       GREATEST(0, EXTRACT(DAY FROM now() - COALESCE(lu.last_logged_at, hm.joined_at::timestamptz)))::int AS days_silent,
       EXTRACT(DAY FROM now() - COALESCE(lu.last_logged_at, hm.joined_at::timestamptz)) >= 45 AS flagged
FROM household_members hm
LEFT JOIN LATERAL (SELECT MAX(ul.used_at) AS last_logged_at FROM usage_logs ul WHERE ul.user_id = hm.user_id) lu ON true;

-- ---------------------------------------------------------------------------
-- v_finding_evidence — FR-39: the facts behind every open finding, with
-- documented weights:
--   coverage  3  hidden duplicate: another plan already gives them the service
--             2  family plan / free spot / bundle: a plan covers them all
--   price     1  the catalog price behind the saving (every finding)
--   usage     2  waste: no use for 60+ days (or never, 60+ days in)
--             1  waste: no use for 30-59 days
--             1  usage falling: the trend is a projection
--             1  overlap: one service barely used next to the others
--   silence  -3  someone on it has logged nothing for 45+ days (FR-40);
--                only for the usage-based types (waste, churn_risk, overlap)
-- v_finding_confidence turns these into High / Medium / Low.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_finding_evidence AS
-- coverage: the stored reason path of each subject
SELECT a.alert_id, 'coverage'::varchar AS evidence_type,
       'path:' || array_to_string(x.reason_path, '>') AS source_ref,
       path_label(x.reason_path) || ' covers '
           || human_list((SELECT array_agg(first_name(u.full_name) ORDER BY u.full_name)
                            FROM subscription_members sm JOIN users u ON u.user_id = sm.user_id
                           WHERE sm.subscription_id = x.subscription_id)) AS value,
       CASE WHEN a.alert_type = 'hidden_duplicate' THEN 3 ELSE 2 END AS weight
FROM alerts a
JOIN alert_subscriptions x ON x.alert_id = a.alert_id AND x.role = 'subject' AND x.reason_path IS NOT NULL
WHERE a.status = 'open'
UNION ALL
-- price: each subject's plan, and the recommended plan, at today's catalog price
SELECT a.alert_id, 'price',
       'price:' || ph.plan_id || '@' || ph.valid_from,
       sv.name || ' ' || pc.name || ' costs ' || inr(monthly_equivalent(ph.price, pc.billing_cycle))
           || '/mo (catalog price since ' || ph.valid_from || ')',
       1
FROM alerts a
JOIN LATERAL (SELECT s.plan_id FROM alert_subscriptions x JOIN subscriptions s ON s.subscription_id = x.subscription_id
              WHERE x.alert_id = a.alert_id AND x.role = 'subject'
              UNION
              SELECT a.recommended_plan_id WHERE a.recommended_plan_id IS NOT NULL) pl ON true
JOIN plan_catalog pc        ON pc.plan_id = pl.plan_id
JOIN services sv            ON sv.service_id = pc.service_id
JOIN plan_price_history ph  ON ph.plan_id = pc.plan_id AND ph.valid_during @> CURRENT_DATE
WHERE a.status = 'open'
UNION ALL
-- usage: what the logs say about each subject, for the usage-based types
SELECT a.alert_id, 'usage',
       'subscription:' || d.subscription_id,
       CASE a.alert_type
           WHEN 'waste' THEN d.service_name || CASE WHEN d.total_sessions = 0
                                                    THEN ' never used in ' || d.days_since_last_use || ' days'
                                                    ELSE ' last used ' || d.days_since_last_use || ' days ago' END
           WHEN 'churn_risk' THEN d.service_name || ' sessions per month: '
                                  || array_to_string(cr.trend, ' → ') || ', heading to zero'
           ELSE d.service_name || ': ' || d.sessions_30d || ' session(s) in the last 30 days'
       END,
       CASE WHEN a.alert_type = 'waste' AND d.days_since_last_use >= 60 THEN 2 ELSE 1 END
FROM alerts a
JOIN alert_subscriptions x   ON x.alert_id = a.alert_id AND x.role = 'subject'
JOIN v_subscription_detail d ON d.subscription_id = x.subscription_id
LEFT JOIN v_churn_risk cr    ON cr.subscription_id = d.subscription_id
WHERE a.status = 'open' AND a.alert_type IN ('waste', 'churn_risk', 'overlap')
UNION ALL
-- silence: a member of a usage-based subject who has logged nothing for 45+ days
SELECT DISTINCT a.alert_id, 'silence',
       'user:' || q.user_id,
       u.full_name || ' has logged no usage at all for ' || q.days_silent || ' days',
       -3
FROM alerts a
JOIN alert_subscriptions x   ON x.alert_id = a.alert_id AND x.role = 'subject'
JOIN subscription_members sm ON sm.subscription_id = x.subscription_id
JOIN usage_data_quality q    ON q.user_id = sm.user_id AND q.flagged
JOIN users u                 ON u.user_id = q.user_id
WHERE a.status = 'open' AND a.alert_type IN ('waste', 'churn_risk', 'overlap');

-- ---------------------------------------------------------------------------
-- v_finding_confidence — evidence rows to High / Medium / Low. Each evidence
-- type counts once, at its strongest row (so three subject prices don't
-- triple-count); score = the sum. Any silence row makes it Low outright.
--   score >= 3 → High   score = 2 → Medium   otherwise → Low
-- With the weights above: duplicates 4, family plan / free spot / bundle 3,
-- long-unused waste 3, recent waste 2, falling usage 2, overlap 2.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_finding_confidence AS
WITH per_type AS (
    SELECT alert_id, evidence_type, MAX(weight) AS weight
    FROM finding_evidence
    GROUP BY alert_id, evidence_type
)
SELECT alert_id,
       COALESCE(SUM(weight) FILTER (WHERE evidence_type <> 'silence'), 0)::int AS score,
       bool_or(evidence_type = 'silence') AS silent,
       CASE WHEN bool_or(evidence_type = 'silence')                                   THEN 'Low'
            WHEN COALESCE(SUM(weight) FILTER (WHERE evidence_type <> 'silence'), 0) >= 3 THEN 'High'
            WHEN COALESCE(SUM(weight) FILTER (WHERE evidence_type <> 'silence'), 0) = 2  THEN 'Medium'
            ELSE 'Low'
       END::varchar AS confidence
FROM per_type
GROUP BY alert_id;

-- ---------------------------------------------------------------------------
-- v_household_savings — FR-41: the totals the summary shows. Concrete types
-- with High or Medium confidence are "savings found" (capped at spend, as in
-- v1); everything else, Low findings included, is "worth a look".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_household_savings AS
SELECT h.household_id,
       sp.spend AS monthly_spend,
       LEAST(COALESCE(SUM(a.potential_monthly_savings)
                      FILTER (WHERE a.counts_toward_savings
                                AND a.alert_type IN ('hidden_duplicate','consolidation','spare_capacity','bundle','waste')), 0),
             sp.spend) AS savings_found,
       COALESCE(SUM(a.potential_monthly_savings)
                FILTER (WHERE NOT a.counts_toward_savings
                           OR a.alert_type NOT IN ('hidden_duplicate','consolidation','spare_capacity','bundle','waste')), 0)
           AS worth_a_look,
       COUNT(a.alert_id) FILTER (WHERE NOT a.counts_toward_savings)::int AS low_confidence_findings
FROM households h
CROSS JOIN LATERAL (SELECT COALESCE(SUM(d.monthly_price), 0) AS spend FROM v_subscription_detail d
                    WHERE d.household_id = h.household_id AND d.status = 'active') sp
LEFT JOIN alerts a ON a.household_id = h.household_id AND a.status = 'open'
GROUP BY h.household_id, sp.spend;

-- ---------------------------------------------------------------------------
-- v_alert_reasons — the reason path behind each subscription in a finding,
-- as text, with the members it covers (FR-38): the members of the subject
-- subscription, who all keep the service through that path
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_alert_reasons AS
SELECT x.alert_id, a.household_id, a.alert_type, a.fingerprint, a.status,
       x.subscription_id, x.role, x.reason_path,
       path_label(x.reason_path) AS reason_label,
       (SELECT array_agg(sm.user_id ORDER BY sm.user_id)
          FROM subscription_members sm WHERE sm.subscription_id = x.subscription_id) AS member_ids,
       (SELECT array_agg(u.full_name ORDER BY u.full_name)
          FROM subscription_members sm JOIN users u ON u.user_id = sm.user_id
         WHERE sm.subscription_id = x.subscription_id) AS member_names
FROM alert_subscriptions x
JOIN alerts a ON a.alert_id = x.alert_id;

-- ---------------------------------------------------------------------------
-- lock_household — every transaction that changes a household's data takes
-- this lock FIRST (a transaction-level advisory lock, released at COMMIT /
-- ROLLBACK). Changes to the same household then run one after another instead
-- of each grabbing alert and subscription rows in a different order — which,
-- without this, can deadlock (found in testing: two fixes applied at once both
-- re-ran refresh_alerts and blocked each other). Different households still
-- run in parallel. Passing NULL locks every household, always in id order, so
-- lockers can never wait on each other in a circle.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lock_household(p_household_id INT) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    h INT;
BEGIN
    IF p_household_id IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(7140, p_household_id);
    ELSE
        FOR h IN SELECT household_id FROM households ORDER BY household_id LOOP
            PERFORM pg_advisory_xact_lock(7140, h);
        END LOOP;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- v_auto_needs — the needs the data implies (see member_needs in schema.sql).
-- A pair with both kinds of evidence is reported once, as usage.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_auto_needs AS
SELECT DISTINCT ON (user_id, service_id)
       household_id, user_id, service_id, source, last_evidence_at
FROM (
    SELECT hm.household_id, ul.user_id, p.service_id, 'usage'::varchar AS source,
           MAX(ul.used_at) AS last_evidence_at
    FROM usage_logs ul
    JOIN subscriptions s      ON s.subscription_id = ul.subscription_id
    JOIN plan_catalog p       ON p.plan_id = s.plan_id
    JOIN household_members hm ON hm.user_id = ul.user_id
    WHERE ul.used_at >= now() - interval '30 days'
    GROUP BY hm.household_id, ul.user_id, p.service_id
    UNION ALL
    SELECT DISTINCT mc.household_id, mc.user_id, mc.service_id, 'passive', NULL::timestamptz
    FROM v_member_coverage mc
    JOIN services sv   ON sv.service_id = mc.service_id
    JOIN categories c  ON c.category_id = sv.category_id
    WHERE c.is_passive
) evidence
ORDER BY user_id, service_id, source = 'usage' DESC;

-- ---------------------------------------------------------------------------
-- v_need_coverage — every need that is in force, whether anything covers it
-- today, and the shortest way it is covered (own plan first, then the fewest
-- hops through included plans).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_need_coverage AS
SELECT DISTINCT ON (n.user_id, n.service_id)
       hm.household_id, n.user_id, n.service_id, n.source, n.last_evidence_at,
       mc.subscription_id IS NOT NULL AS covered,
       mc.subscription_id             AS via_subscription_id,
       mc.depth, mc.path, mc.path_label
FROM member_needs n
JOIN household_members hm     ON hm.user_id = n.user_id
LEFT JOIN v_member_coverage mc ON mc.user_id = n.user_id AND mc.service_id = n.service_id
WHERE n.is_needed
ORDER BY n.user_id, n.service_id, mc.depth, mc.subscription_id;

-- ---------------------------------------------------------------------------
-- refresh_member_needs — sync the automatic rows of member_needs with
-- v_auto_needs for one household (or all). Manual rows are never touched:
-- a manual need stays, and a manual "not needed" keeps the automatic one out.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE refresh_member_needs(p_household_id INT DEFAULT NULL)
LANGUAGE plpgsql
SET jit = off
AS $$
BEGIN
    PERFORM lock_household(p_household_id);

    CREATE TEMP TABLE IF NOT EXISTS _auto_needs ON COMMIT DROP AS
        SELECT * FROM v_auto_needs WITH NO DATA;
    TRUNCATE _auto_needs;
    INSERT INTO _auto_needs
        SELECT * FROM v_auto_needs
        WHERE p_household_id IS NULL OR household_id = p_household_id;

    -- automatic needs the data no longer supports go away
    DELETE FROM member_needs n
    USING household_members hm
    WHERE hm.user_id = n.user_id
      AND (p_household_id IS NULL OR hm.household_id = p_household_id)
      AND n.source <> 'manual'
      AND NOT EXISTS (SELECT 1 FROM _auto_needs a
                      WHERE a.user_id = n.user_id AND a.service_id = n.service_id);

    -- new ones are added, existing automatic ones refreshed, manual ones kept
    INSERT INTO member_needs (user_id, service_id, source, last_evidence_at)
    SELECT user_id, service_id, source, last_evidence_at FROM _auto_needs
    ON CONFLICT (user_id, service_id) DO UPDATE
        SET source           = EXCLUDED.source,
            last_evidence_at = EXCLUDED.last_evidence_at,
            updated_at       = now()
        WHERE member_needs.source <> 'manual'
          AND (member_needs.source, member_needs.last_evidence_at)
              IS DISTINCT FROM (EXCLUDED.source, EXCLUDED.last_evidence_at);

    DROP TABLE _auto_needs;
END;
$$;

-- ---------------------------------------------------------------------------
-- refresh_usage_data_quality — sync usage_data_quality with
-- v_usage_data_quality for one household (or all)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE refresh_usage_data_quality(p_household_id INT DEFAULT NULL)
LANGUAGE plpgsql
SET jit = off
AS $$
BEGIN
    PERFORM lock_household(p_household_id);

    DELETE FROM usage_data_quality q
    USING household_members hm
    WHERE hm.user_id = q.user_id
      AND (p_household_id IS NULL OR hm.household_id = p_household_id);

    INSERT INTO usage_data_quality (user_id, last_logged_at, days_silent, flagged)
    SELECT user_id, last_logged_at, days_silent, flagged
    FROM v_usage_data_quality
    WHERE p_household_id IS NULL OR household_id = p_household_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- set_member_need — the owner's override for one (person, service):
--   true   they need it, whatever the data says
--   false  they don't, and the automatic need stays out
--   NULL   remove the override and go back to what the data says
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_member_need(p_user_id INT, p_service_id INT, p_is_needed BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
SET jit = off
AS $$
DECLARE
    v_hh INT;
BEGIN
    SELECT household_id INTO v_hh FROM household_members WHERE user_id = p_user_id;
    IF v_hh IS NULL THEN
        RAISE EXCEPTION 'User % is not part of any household', p_user_id USING ERRCODE = 'check_violation';
    END IF;
    PERFORM lock_household(v_hh);

    IF p_is_needed IS NULL THEN
        DELETE FROM member_needs
        WHERE user_id = p_user_id AND service_id = p_service_id AND source = 'manual';
    ELSE
        INSERT INTO member_needs (user_id, service_id, source, is_needed, last_evidence_at)
        VALUES (p_user_id, p_service_id, 'manual', p_is_needed, NULL)
        ON CONFLICT (user_id, service_id) DO UPDATE
            SET source = 'manual', is_needed = EXCLUDED.is_needed,
                last_evidence_at = NULL, updated_at = now();
    END IF;

    CALL refresh_member_needs(v_hh);
END;
$$;

-- ---------------------------------------------------------------------------
-- refresh_alerts — sync the alerts table with the current findings for one
-- household (or all). Idempotent:
--   * open alerts whose finding no longer exists are deleted
--   * new findings are inserted
--   * existing open alerts get their message/savings updated
--   * dismissed/resolved alerts are left alone, so they never come back
--   * alert_subscriptions is rebuilt for open alerts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE refresh_alerts(p_household_id INT DEFAULT NULL)
LANGUAGE plpgsql
SET jit = off
AS $$
BEGIN
    PERFORM lock_household(p_household_id);

    -- data quality and needs first: they follow the same data the findings do
    CALL refresh_usage_data_quality(p_household_id);
    CALL refresh_member_needs(p_household_id);

    -- snapshot the findings once so all statements below see the same thing
    CREATE TEMP TABLE IF NOT EXISTS _findings ON COMMIT DROP AS
        SELECT * FROM v_findings WITH NO DATA;
    TRUNCATE _findings;
    INSERT INTO _findings
        SELECT * FROM v_findings
        WHERE p_household_id IS NULL OR household_id = p_household_id;

    -- 1. open alerts that no longer apply go away
    DELETE FROM alerts a
    WHERE a.status = 'open'
      AND (p_household_id IS NULL OR a.household_id = p_household_id)
      AND NOT EXISTS (SELECT 1 FROM _findings f
                      WHERE f.household_id = a.household_id AND f.fingerprint = a.fingerprint);

    -- 2. new findings are added, existing open ones are refreshed,
    --    dismissed/resolved ones are left exactly as they are
    INSERT INTO alerts (household_id, alert_type, recommended_plan_id, fingerprint,
                        message, potential_monthly_savings)
    SELECT household_id, alert_type, recommended_plan_id, fingerprint, message, ROUND(savings, 2)
    FROM _findings
    ON CONFLICT (household_id, fingerprint) DO UPDATE
        SET message                   = EXCLUDED.message,
            potential_monthly_savings = EXCLUDED.potential_monthly_savings,
            recommended_plan_id       = EXCLUDED.recommended_plan_id
        WHERE alerts.status = 'open';

    -- 3. rebuild which subscriptions each open alert is about
    DELETE FROM alert_subscriptions x
    USING alerts a
    WHERE a.alert_id = x.alert_id
      AND a.status = 'open'
      AND (p_household_id IS NULL OR a.household_id = p_household_id);

    INSERT INTO alert_subscriptions (alert_id, subscription_id, role, reason_path)
    SELECT a.alert_id, x.sid, 'subject',
           CASE WHEN jsonb_typeof(f.subject_paths -> (x.ord::int - 1)) = 'array'
                THEN ARRAY(SELECT jsonb_array_elements_text(f.subject_paths -> (x.ord::int - 1))::int)
           END
    FROM _findings f
    JOIN alerts a ON a.household_id = f.household_id AND a.fingerprint = f.fingerprint AND a.status = 'open'
    CROSS JOIN LATERAL UNNEST(f.subject_ids) WITH ORDINALITY AS x(sid, ord)
    UNION
    SELECT a.alert_id, sid, 'source', NULL
    FROM _findings f
    JOIN alerts a ON a.household_id = f.household_id AND a.fingerprint = f.fingerprint AND a.status = 'open'
    CROSS JOIN LATERAL UNNEST(f.source_ids) AS sid
    ON CONFLICT DO NOTHING;

    -- 4. evidence and confidence for open alerts (FR-39 to FR-41)
    DELETE FROM finding_evidence e
    USING alerts a
    WHERE a.alert_id = e.alert_id
      AND a.status = 'open'
      AND (p_household_id IS NULL OR a.household_id = p_household_id);

    INSERT INTO finding_evidence (alert_id, evidence_type, source_ref, value, weight)
    SELECT v.alert_id, v.evidence_type, v.source_ref, v.value, v.weight
    FROM v_finding_evidence v
    JOIN alerts a ON a.alert_id = v.alert_id
    WHERE p_household_id IS NULL OR a.household_id = p_household_id
    ORDER BY v.alert_id, v.evidence_type, v.source_ref;

    UPDATE alerts a
       SET confidence = COALESCE(c.confidence, 'Low')
      FROM alerts a2
      LEFT JOIN v_finding_confidence c ON c.alert_id = a2.alert_id
     WHERE a.alert_id = a2.alert_id
       AND a.status = 'open'
       AND (p_household_id IS NULL OR a.household_id = p_household_id)
       AND a.confidence IS DISTINCT FROM COALESCE(c.confidence, 'Low');

    DROP TABLE _findings;
END;
$$;

-- ---------------------------------------------------------------------------
-- apply_alert — actually carry out a finding, and return a list of the steps
-- it took in plain English. Used two ways by the API:
--   preview: BEGIN; SELECT apply_alert(id); <read new totals>; ROLLBACK;
--   apply:   BEGIN; SELECT apply_alert(id); COMMIT;
-- so the user can see exactly what would change before anything is saved.
--
--   hidden_duplicate / waste / churn_risk / overlap → cancel the subject(s)
--   spare_capacity → join the shared plan, then cancel the own plan
--   consolidation  → start enough shared plans for everyone (heaviest user
--                    pays), move people onto them, cancel the individual plans
--   bundle         → start the bundle for the same people, cancel what it replaces
--
-- Locks: the household lock first (see lock_household), then the alert row
-- FOR UPDATE, so the same fix can't be applied twice by two clicks at once;
-- the second one waits, then sees it's resolved.
-- Every insert still goes through the normal triggers (capacity, household).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION apply_alert(p_alert_id INT) RETURNS TEXT[]
LANGUAGE plpgsql
SET jit = off
AS $$
DECLARE
    a          alerts%ROWTYPE;
    subj       INT[];
    src        INT[];
    steps      TEXT[] := '{}';
    r          RECORD;
    host       RECORD;
    v_plan     RECORD;
    v_people   INT[];
    v_names    TEXT[];
    v_payer    INT;
    v_new      INT;
    v_groups   INT;
    g          INT;
    i          INT;
    v_hh       INT;
BEGIN
    SELECT household_id INTO v_hh FROM alerts WHERE alert_id = p_alert_id;
    PERFORM lock_household(v_hh);                      -- household lock first, then the row
    SELECT * INTO a FROM alerts WHERE alert_id = p_alert_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Finding % does not exist', p_alert_id USING ERRCODE = 'check_violation';
    END IF;
    IF a.status <> 'open' THEN
        RAISE EXCEPTION 'This finding was already %', a.status USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(array_agg(subscription_id ORDER BY subscription_id) FILTER (WHERE role = 'subject'), '{}'),
           COALESCE(array_agg(subscription_id ORDER BY subscription_id) FILTER (WHERE role = 'source'),  '{}')
      INTO subj, src
      FROM alert_subscriptions WHERE alert_id = p_alert_id;

    IF a.alert_type = 'spare_capacity' THEN
        SELECT * INTO host FROM v_subscription_detail WHERE subscription_id = src[1];
        FOR r IN SELECT * FROM v_subscription_detail WHERE subscription_id = ANY (subj) LOOP
            INSERT INTO subscription_members (subscription_id, user_id) VALUES (host.subscription_id, r.payer_id);
            steps := steps || format('Add %s to %s''s %s %s',
                                     first_name(r.payer_name), first_name(host.payer_name),
                                     host.service_name, host.plan_name);
        END LOOP;

    ELSIF a.alert_type IN ('consolidation', 'bundle') THEN
        SELECT p.plan_id, p.name, p.max_members, p.monthly_price, s.name AS service_name
          INTO v_plan
          FROM plans p JOIN services s ON s.service_id = p.service_id
         WHERE p.plan_id = a.recommended_plan_id;

        IF a.alert_type = 'consolidation' THEN
            -- the people are the payers of the individual plans, heaviest user first
            SELECT array_agg(payer_id ORDER BY sessions_30d DESC, payer_id)
              INTO v_people
              FROM v_subscription_detail WHERE subscription_id = ANY (subj);
        ELSE
            -- everyone on any of the replaced plans; the payer of the priciest one pays
            SELECT array_agg(user_id ORDER BY is_payer DESC, user_id) INTO v_people
              FROM (SELECT sm.user_id,
                           bool_or(sm.user_id = d.payer_id
                                   AND d.monthly_price = (SELECT MAX(monthly_price) FROM v_subscription_detail
                                                          WHERE subscription_id = ANY (subj))) AS is_payer
                      FROM subscription_members sm
                      JOIN v_subscription_detail d ON d.subscription_id = sm.subscription_id
                     WHERE sm.subscription_id = ANY (subj)
                     GROUP BY sm.user_id) people;
        END IF;

        v_groups := CEIL(cardinality(v_people)::numeric / v_plan.max_members);
        FOR g IN 0 .. v_groups - 1 LOOP
            v_payer := v_people[g * v_plan.max_members + 1];
            INSERT INTO subscriptions (payer_id, plan_id, start_date)
            VALUES (v_payer, v_plan.plan_id, CURRENT_DATE)
            RETURNING subscription_id INTO v_new;

            v_names := '{}';
            FOR i IN g * v_plan.max_members + 2 .. LEAST((g + 1) * v_plan.max_members, cardinality(v_people)) LOOP
                INSERT INTO subscription_members (subscription_id, user_id) VALUES (v_new, v_people[i]);
                v_names := v_names || (SELECT first_name(full_name) FROM users WHERE user_id = v_people[i]);
            END LOOP;

            steps := steps || format('Start %s %s (%s/mo), paid by %s%s',
                                     v_plan.service_name, v_plan.name, inr(v_plan.monthly_price),
                                     (SELECT first_name(full_name) FROM users WHERE user_id = v_payer),
                                     CASE WHEN cardinality(v_names) > 0
                                          THEN ', shared with ' || human_list(v_names) ELSE '' END);
        END LOOP;
    END IF;

    -- every finding type ends by cancelling its subject subscriptions
    FOR r IN SELECT * FROM v_subscription_detail
              WHERE subscription_id = ANY (subj) AND status = 'active'
              ORDER BY monthly_price DESC, subscription_id LOOP
        UPDATE subscriptions
           SET status = 'cancelled', end_date = GREATEST(CURRENT_DATE, start_date)
         WHERE subscription_id = r.subscription_id;
        steps := steps || format('Cancel %s''s %s (%s), %s/mo',
                                 first_name(r.payer_name), r.service_name, r.plan_name, inr(r.monthly_price));
    END LOOP;

    UPDATE alerts SET status = 'resolved' WHERE alert_id = p_alert_id;
    CALL refresh_alerts(a.household_id);
    RETURN steps;
END;
$$;

-- ============================================================================
-- Household optimizer (FR-29 to FR-33): data in, steps out
-- ============================================================================

-- ---------------------------------------------------------------------------
-- optimizer_input — everything the optimizer (server/optimizer.js) needs for
-- one household, as one JSON document. Prices and inclusions are those valid
-- on p_date; needs, subscriptions and findings are as they are now.
--   users          the household's members
--   services       id, name, whether the category is passive
--   needs          every need in force, with covered_today (v_need_coverage)
--   subscriptions  active ones, with their members
--   plans          plans already held, plus every priced plan that reaches a
--                  needed service, each with the services it covers (shortest
--                  path to each, depth 0 = its own service)
--   alerts         open v1 findings, so the run can say which it adopts
--   inclusions     every entitlement edge valid on p_date, so a what-if can
--                  remove one and recompute coverage (server/whatif.js)
--   silent_user_ids  members flagged in usage_data_quality (FR-40), so steps
--                  that rest on missing usage can be marked Low
-- Every array is ordered, so the same data always gives the same document
-- (and the same optimizer_state_hash).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION optimizer_input(p_household_id INT, p_date DATE DEFAULT CURRENT_DATE)
RETURNS JSONB
LANGUAGE sql STABLE
SET jit = off
AS $$
    WITH members AS (
        SELECT hm.user_id, u.full_name
        FROM household_members hm JOIN users u ON u.user_id = hm.user_id
        WHERE hm.household_id = p_household_id
    ),
    subs AS (
        SELECT s.subscription_id, s.payer_id, s.plan_id,
               (SELECT array_agg(sm.user_id ORDER BY sm.user_id)
                  FROM subscription_members sm WHERE sm.subscription_id = s.subscription_id) AS member_ids,
               EXTRACT(DAY FROM now() - COALESCE((SELECT MAX(ul.used_at) FROM usage_logs ul
                                                   WHERE ul.subscription_id = s.subscription_id),
                                                  s.start_date::timestamptz))::int AS days_since_last_use
        FROM subscriptions s
        JOIN members m ON m.user_id = s.payer_id
        WHERE s.status = 'active'
    ),
    needs AS (
        SELECT n.user_id, n.service_id, n.source, COALESCE(nc.covered, false) AS covered_today
        FROM member_needs n
        JOIN members m ON m.user_id = n.user_id
        LEFT JOIN v_need_coverage nc ON nc.user_id = n.user_id AND nc.service_id = n.service_id
        WHERE n.is_needed
    ),
    coverage AS (
        SELECT DISTINCT ON (plan_id, service_id) plan_id, service_id, depth, path
        FROM (SELECT p.plan_id, p.service_id, 0 AS depth, ARRAY[p.plan_id] AS path
                FROM plan_catalog p WHERE p.is_purchasable
              UNION ALL
              SELECT root_plan_id, included_service_id, depth, path
                FROM entitlement_closure_at(p_date)) c
        ORDER BY plan_id, service_id, depth, path
    ),
    relevant_plans AS (
        SELECT plan_id FROM subs
        UNION
        SELECT c.plan_id
        FROM coverage c
        JOIN plans_at(p_date) p ON p.plan_id = c.plan_id
        WHERE p.price IS NOT NULL
          AND c.service_id IN (SELECT service_id FROM needs)
    )
    SELECT jsonb_build_object(
        'household_id', p_household_id,
        'evaluated_on', p_date,
        'users', (SELECT COALESCE(jsonb_agg(jsonb_build_object('user_id', user_id, 'name', full_name)
                                            ORDER BY user_id), '[]')
                    FROM members),
        'services', (SELECT jsonb_agg(jsonb_build_object('service_id', sv.service_id, 'name', sv.name,
                                                         'is_passive', c.is_passive)
                                      ORDER BY sv.service_id)
                       FROM services sv JOIN categories c ON c.category_id = sv.category_id),
        'needs', (SELECT COALESCE(jsonb_agg(jsonb_build_object('user_id', user_id, 'service_id', service_id,
                                                               'source', source, 'covered_today', covered_today)
                                            ORDER BY user_id, service_id), '[]')
                    FROM needs),
        'subscriptions', (SELECT COALESCE(jsonb_agg(jsonb_build_object('subscription_id', subscription_id,
                                                                       'payer_id', payer_id, 'plan_id', plan_id,
                                                                       'member_ids', member_ids,
                                                                       'days_since_last_use', days_since_last_use)
                                                    ORDER BY subscription_id), '[]')
                            FROM subs),
        'silent_user_ids', (SELECT COALESCE(jsonb_agg(q.user_id ORDER BY q.user_id), '[]')
                              FROM usage_data_quality q JOIN members m ON m.user_id = q.user_id
                             WHERE q.flagged),
        'plans', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                                     'plan_id', p.plan_id, 'service_id', p.service_id, 'name', p.name,
                                     'tier', p.tier, 'max_members', p.max_members,
                                     'is_purchasable', p.is_purchasable, 'monthly_price', p.monthly_price,
                                     'covers', (SELECT jsonb_agg(jsonb_build_object('service_id', c.service_id,
                                                                                    'depth', c.depth, 'path', c.path)
                                                                 ORDER BY c.service_id)
                                                  FROM coverage c WHERE c.plan_id = p.plan_id))
                                  ORDER BY p.plan_id), '[]')
                    FROM plans_at(p_date) p
                    WHERE p.plan_id IN (SELECT plan_id FROM relevant_plans)),
        'alerts', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                                      'alert_id', a.alert_id, 'alert_type', a.alert_type,
                                      'recommended_plan_id', a.recommended_plan_id,
                                      'savings', a.potential_monthly_savings,
                                      'subject_ids', COALESCE((SELECT array_agg(x.subscription_id ORDER BY x.subscription_id)
                                                                 FROM alert_subscriptions x
                                                                WHERE x.alert_id = a.alert_id AND x.role = 'subject'), '{}'),
                                      'source_ids', COALESCE((SELECT array_agg(x.subscription_id ORDER BY x.subscription_id)
                                                                FROM alert_subscriptions x
                                                               WHERE x.alert_id = a.alert_id AND x.role = 'source'), '{}'))
                                   ORDER BY a.alert_id), '[]')
                     FROM alerts a
                     WHERE a.household_id = p_household_id AND a.status = 'open'),
        'inclusions', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                                          'parent_plan_id', e.plan_id, 'included_plan_id', e.included_plan_id,
                                          'included_service_id', ip.service_id)
                                       ORDER BY e.plan_id, e.included_plan_id), '[]')
                         FROM entitlements_at(p_date) e
                         JOIN plan_catalog ip ON ip.plan_id = e.included_plan_id)
    )
$$;

-- fingerprint of the data a run was computed from (see optimization_runs)
CREATE OR REPLACE FUNCTION optimizer_state_hash(p_household_id INT, p_date DATE DEFAULT CURRENT_DATE)
RETURNS TEXT
LANGUAGE sql STABLE
SET jit = off
AS $$
    SELECT md5(optimizer_input(p_household_id, p_date)::text)
$$;

-- ---------------------------------------------------------------------------
-- apply_optimization — carry out an optimizer run's steps (FR-33), the same
-- way apply_alert carries out one finding. The API calls it two ways:
--   preview: BEGIN; SELECT apply_optimization(id); <read new totals>; ROLLBACK;
--   apply:   BEGIN; SELECT apply_optimization(id); COMMIT;
-- Locks: the household lock first (lock_household), then the run row FOR
-- UPDATE, so a run is applied at most once.
-- If the household changed since the run was computed (state_hash), nothing
-- is applied: the run is marked stale and NULL is returned.
-- Every insert goes through the normal triggers (capacity, household, payer).
-- After the steps it checks, and raises (rolling everything back) if not:
--   * every need that was covered before is still covered
--   * every member of a cancelled passive subscription still reaches it
--   * the household now costs exactly the run's cost_after
-- Returns the steps it took, in plain English.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION apply_optimization(p_run_id INT) RETURNS TEXT[]
LANGUAGE plpgsql
SET jit = off
AS $$
DECLARE
    r          optimization_runs%ROWTYPE;
    st         RECORD;
    v_hh       INT;
    v_new      INT;
    u          INT;
    v_cost     NUMERIC;
    v_open     TEXT[];
    v_lost     TEXT;
    steps      TEXT[] := '{}';
BEGIN
    SELECT household_id INTO v_hh FROM optimization_runs WHERE run_id = p_run_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Optimizer run % does not exist', p_run_id USING ERRCODE = 'check_violation';
    END IF;
    PERFORM lock_household(v_hh);                      -- household lock first, then the row
    SELECT * INTO r FROM optimization_runs WHERE run_id = p_run_id FOR UPDATE;
    IF r.kind <> 'optimize' THEN
        RAISE EXCEPTION 'Run % is a what-if simulation and cannot be applied', p_run_id USING ERRCODE = 'check_violation';
    END IF;
    IF r.status <> 'proposed' THEN
        RAISE EXCEPTION 'This optimizer run was already %', r.status USING ERRCODE = 'check_violation';
    END IF;
    IF optimizer_state_hash(v_hh, r.evaluated_on) <> r.state_hash THEN
        UPDATE optimization_runs SET status = 'stale' WHERE run_id = p_run_id;
        RETURN NULL;
    END IF;

    -- needs nothing covers even now: the run doesn't have to cover these
    SELECT COALESCE(array_agg(user_id || ':' || service_id), '{}') INTO v_open
      FROM v_need_coverage WHERE household_id = v_hh AND NOT covered;

    FOR st IN SELECT * FROM optimization_steps WHERE run_id = p_run_id ORDER BY step_no LOOP
        IF st.action IN ('start', 'switch') THEN
            INSERT INTO subscriptions (payer_id, plan_id, start_date)
            VALUES (st.payer_id, st.plan_id, CURRENT_DATE)
            RETURNING subscription_id INTO v_new;
            FOREACH u IN ARRAY st.user_ids LOOP
                IF u <> st.payer_id THEN
                    INSERT INTO subscription_members (subscription_id, user_id) VALUES (v_new, u);
                END IF;
            END LOOP;
        ELSIF st.action = 'add_member' THEN
            INSERT INTO subscription_members (subscription_id, user_id) VALUES (st.subscription_id, st.user_ids[1]);
        END IF;

        IF st.action IN ('switch', 'cancel') THEN
            UPDATE subscriptions
               SET status = 'cancelled', end_date = GREATEST(CURRENT_DATE, start_date)
             WHERE subscription_id = st.subscription_id AND status = 'active';
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Step %: subscription % is no longer active', st.step_no, st.subscription_id
                    USING ERRCODE = 'check_violation';
            END IF;
        END IF;
        steps := steps || st.description;
    END LOOP;

    -- checked against member_needs as it was before the change, so a passive
    -- need can't quietly disappear along with its subscription
    SELECT string_agg(u2.full_name || ' / ' || sv.name, ', ') INTO v_lost
      FROM v_need_coverage nc
      JOIN users u2    ON u2.user_id = nc.user_id
      JOIN services sv ON sv.service_id = nc.service_id
     WHERE nc.household_id = v_hh AND NOT nc.covered
       AND NOT (nc.user_id || ':' || nc.service_id) = ANY (v_open);
    IF v_lost IS NOT NULL THEN
        RAISE EXCEPTION 'Applying run % would leave needs uncovered: %', p_run_id, v_lost
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT string_agg(u2.full_name || ' / ' || sv.name, ', ') INTO v_lost
      FROM optimization_steps os
      JOIN subscriptions s         ON s.subscription_id = os.subscription_id
      JOIN plan_catalog p          ON p.plan_id = s.plan_id
      JOIN services sv             ON sv.service_id = p.service_id
      JOIN categories c            ON c.category_id = sv.category_id
      JOIN subscription_members sm ON sm.subscription_id = s.subscription_id
      JOIN users u2                ON u2.user_id = sm.user_id
     WHERE os.run_id = p_run_id AND os.action IN ('switch', 'cancel') AND c.is_passive
       AND NOT EXISTS (SELECT 1 FROM v_member_coverage mc
                       WHERE mc.user_id = sm.user_id AND mc.service_id = p.service_id);
    IF v_lost IS NOT NULL THEN
        RAISE EXCEPTION 'Applying run % would cancel a passive service outright: %', p_run_id, v_lost
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(SUM(p.monthly_price), 0) INTO v_cost
      FROM subscriptions s
      JOIN household_members hm           ON hm.user_id = s.payer_id
      JOIN plans_at(r.evaluated_on) p     ON p.plan_id = s.plan_id
     WHERE hm.household_id = v_hh AND s.status = 'active';
    IF v_cost <> r.cost_after THEN
        RAISE EXCEPTION 'Applying run % costs % a month, not the % it promised', p_run_id, v_cost, r.cost_after
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE optimization_runs SET status = 'applied', applied_at = now() WHERE run_id = p_run_id;
    CALL refresh_alerts(v_hh);
    RETURN steps;
END;
$$;

-- ============================================================================
-- Bank statement import — find recurring charges in raw transactions
-- ============================================================================

-- 'UPI/DR/412345678/LANDLORD RENT/HDFC' -> 'UPI DR LANDLORD RENT HDFC'
-- upper-case, punctuation to spaces, and drop any token containing a digit
-- (reference numbers, card digits, order ids)
CREATE OR REPLACE FUNCTION normalize_merchant(t TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT btrim(regexp_replace(
               regexp_replace(
                   regexp_replace(upper(t), '[^A-Z0-9]+', ' ', 'g'),
                   '\m[A-Z]*[0-9][A-Z0-9]*\M', ' ', 'g'),
               '\s+', ' ', 'g'))
$$;

-- short label used to group charges: payment-rail prefixes removed, first two words
CREATE OR REPLACE FUNCTION merchant_key(norm TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT array_to_string(
        (string_to_array(regexp_replace(norm, '^(UPI (DR|CR)|POS|NEFT|IMPS|ACH D|ECS|BIL ONL) ', ''), ' '))[1:2], ' ')
$$;

-- ---------------------------------------------------------------------------
-- v_statement_series — groups debits into candidate series: same merchant,
-- same amount, and roughly the same day of the month. That last part is a
-- gaps-and-islands step: sort by day of month, start a new island whenever the
-- day jumps by more than 3. So two ₹99 Apple charges on the 5th and the 20th
-- become two series instead of one confusing "every 15 days" series.
-- Days are capped at 28 so a plan billed on the 31st (28th in Feb) stays together.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_statement_series AS
WITH t AS (
    SELECT bt.txn_id, bt.import_id, bt.txn_date, bt.description, bt.amount,
           normalize_merchant(bt.description)                 AS norm,
           LEAST(EXTRACT(DAY FROM bt.txn_date)::int, 28)       AS dom
    FROM bank_transactions bt
    WHERE bt.amount > 0
),
k AS (
    SELECT t.*, merchant_key(t.norm) AS mkey FROM t
),
step AS (
    SELECT k.*,
           CASE WHEN dom - LAG(dom) OVER (PARTITION BY import_id, mkey, amount ORDER BY dom, txn_date) > 3
                THEN 1 ELSE 0 END AS new_island
    FROM k
),
islands AS (
    SELECT step.*,
           SUM(new_island) OVER (PARTITION BY import_id, mkey, amount ORDER BY dom, txn_date
                                 ROWS UNBOUNDED PRECEDING) AS island
    FROM step
),
gaps AS (
    SELECT islands.*,
           txn_date - LAG(txn_date) OVER (PARTITION BY import_id, mkey, amount, island ORDER BY txn_date) AS gap
    FROM islands
)
SELECT import_id,
       mkey                                    AS merchant,
       amount,
       island,
       MIN(description)                        AS sample_description,
       MIN(norm)                               AS norm,
       MIN(dom)                                AS billing_day,
       COUNT(*)::int                           AS charges,
       MIN(txn_date)                           AS first_charge,
       MAX(txn_date)                           AS last_charge,
       ROUND(AVG(gap), 1)                      AS avg_gap_days,
       COALESCE(ROUND(STDDEV_SAMP(gap), 1), 0) AS gap_stddev
FROM gaps
GROUP BY import_id, mkey, amount, island;

-- ---------------------------------------------------------------------------
-- v_recurring_charges — series that repeat on a steady cycle. Monthly needs 3+
-- charges ~25–35 days apart (spread <= 3 days); quarterly / yearly need 2+.
-- Food orders, cabs and electricity bills fall out naturally: their amounts
-- change every time, so they never form a series.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_recurring_charges AS
SELECT s.*,
       CASE WHEN s.avg_gap_days BETWEEN 25 AND 35   THEN 'monthly'
            WHEN s.avg_gap_days BETWEEN 80 AND 100  THEN 'quarterly'
            ELSE 'yearly' END                                    AS cycle,
       s.last_charge + ROUND(s.avg_gap_days)::int                AS next_expected
FROM v_statement_series s
WHERE (s.charges >= 3 AND s.avg_gap_days BETWEEN 25 AND 35   AND s.gap_stddev <= 3)
   OR (s.charges >= 2 AND s.avg_gap_days BETWEEN 80 AND 100  AND s.gap_stddev <= 7)
   OR (s.charges >= 2 AND s.avg_gap_days BETWEEN 350 AND 380 AND s.gap_stddev <= 7);

-- ---------------------------------------------------------------------------
-- v_import_results — each recurring charge checked against the catalog and
-- against what the household already tracks:
--   tracked          matches an active subscription the statement owner pays for
--   still_charged    matches one marked cancelled, but the bank kept charging after
--   cancelled        matches a cancelled one and the charges did stop
--   untracked        a known service and plan that isn't in SubWatch yet
--   no_matching_plan looks like a known service, but no plan has that price/cycle
--   not_in_catalog   recurring, but not a service SubWatch knows (rent, gym...)
-- When several subscriptions could match, the one billed nearest the same day
-- of the month wins.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_import_results AS
WITH imp AS (
    SELECT i.import_id, i.user_id, hm.household_id,
           (SELECT MAX(txn_date) FROM bank_transactions bt WHERE bt.import_id = i.import_id) AS statement_end
    FROM statement_imports i
    JOIN household_members hm ON hm.user_id = i.user_id
),
matched AS (
    SELECT rc.*, imp.user_id, imp.household_id, imp.statement_end,
           (SELECT array_agg(DISTINCT ma.service_id) FROM merchant_aliases ma WHERE rc.norm ~ ma.pattern) AS service_ids
    FROM v_recurring_charges rc
    JOIN imp ON imp.import_id = rc.import_id
),
cand AS (
    SELECT m.*,
           (SELECT array_agg(p.plan_id ORDER BY p.plan_id)
              FROM plans p
             WHERE p.service_id = ANY (m.service_ids)
               AND p.is_purchasable
               AND ABS(p.price - m.amount) <= 1
               AND p.billing_cycle = m.cycle) AS candidate_plan_ids
    FROM matched m
)
SELECT c.import_id, c.user_id, c.household_id, c.merchant, c.sample_description, c.amount, c.cycle,
       c.charges, c.first_charge, c.last_charge, c.next_expected, c.billing_day,
       c.service_ids, c.candidate_plan_ids,
       tr.subscription_id  AS tracked_subscription_id,
       cx.subscription_id  AS cancelled_subscription_id,
       cx.end_date         AS cancelled_on,
       CASE WHEN c.service_ids IS NULL                         THEN 'not_in_catalog'
            WHEN tr.subscription_id IS NOT NULL                THEN 'tracked'
            WHEN cx.subscription_id IS NOT NULL
                 AND c.last_charge > cx.end_date               THEN 'still_charged'
            WHEN cx.subscription_id IS NOT NULL                THEN 'cancelled'
            WHEN c.candidate_plan_ids IS NULL                  THEN 'no_matching_plan'
            ELSE 'untracked'
       END AS status,
       c.last_charge >= c.statement_end - ROUND(c.avg_gap_days * 1.5)::int AS still_active
FROM cand c
LEFT JOIN LATERAL (
    SELECT s.subscription_id
    FROM subscriptions s
    WHERE s.payer_id = c.user_id AND s.status = 'active' AND s.plan_id = ANY (c.candidate_plan_ids)
    ORDER BY ABS(LEAST(EXTRACT(DAY FROM s.start_date)::int, 28) - c.billing_day), s.subscription_id
    LIMIT 1
) tr ON true
LEFT JOIN LATERAL (
    SELECT s.subscription_id, s.end_date
    FROM subscriptions s
    WHERE s.payer_id = c.user_id AND s.status = 'cancelled' AND s.plan_id = ANY (c.candidate_plan_ids)
    ORDER BY s.end_date DESC
    LIMIT 1
) cx ON true;

CALL refresh_alerts(NULL);
