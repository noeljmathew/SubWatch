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
-- v_entitlement_closure — transitive closure of the entitlement graph.
-- Every (root plan, plan it ultimately unlocks) pair, with depth and a
-- readable path. The path array also prevents infinite loops on cycles.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_entitlement_closure AS
WITH RECURSIVE walk AS (
    SELECT e.plan_id AS root_plan_id,
           e.included_plan_id,
           1 AS depth,
           ARRAY[e.plan_id, e.included_plan_id] AS path
    FROM entitlements e
    UNION ALL
    SELECT w.root_plan_id,
           e.included_plan_id,
           w.depth + 1,
           w.path || e.included_plan_id
    FROM walk w
    JOIN entitlements e ON e.plan_id = w.included_plan_id
    WHERE e.included_plan_id <> ALL (w.path)
)
SELECT
    w.root_plan_id,
    w.included_plan_id,
    ip.service_id AS included_service_id,
    w.depth,
    w.path,
    (SELECT STRING_AGG(CASE WHEN x.ord = 1 THEN xs.name || ' (' || xp.name || ')' ELSE xs.name END,
                       ' → ' ORDER BY x.ord)
       FROM UNNEST(w.path) WITH ORDINALITY AS x(plan_id, ord)
       JOIN plans xp    ON xp.plan_id = x.plan_id
       JOIN services xs ON xs.service_id = xp.service_id) AS path_label
FROM walk w
JOIN plans ip ON ip.plan_id = w.included_plan_id;

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
WITH coverage AS (
    SELECT root_plan_id AS plan_id, included_service_id AS service_id, depth, path_label
    FROM v_entitlement_closure
    UNION ALL
    SELECT p.plan_id, p.service_id, 0, s.name || ' (' || p.name || ')'
    FROM plans p JOIN services s ON s.service_id = p.service_id
    WHERE p.is_purchasable
)
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
    src.payer_id        AS via_payer_id
FROM v_subscription_detail dup
JOIN v_subscription_detail src
    ON  src.household_id = dup.household_id
    AND src.subscription_id <> dup.subscription_id
    AND src.status = 'active'
JOIN coverage cl
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
    SELECT DISTINCT p.plan_id, cl.included_service_id AS service_id
    FROM plans p
    JOIN v_entitlement_closure cl ON cl.root_plan_id = p.plan_id
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
-- month), so a plan that started on the 31st doesn't drift.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION renewal_forecast(p_household_id INT, p_days INT DEFAULT 30)
RETURNS TABLE (renewal_date DATE, subscription_id INT, service_name TEXT, plan_name TEXT,
               payer_name TEXT, billing_cycle TEXT, amount NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT r.renewal_date, d.subscription_id, d.service_name::text, d.plan_name::text,
           d.payer_name::text, d.billing_cycle::text, d.price
    FROM v_subscription_detail d
    CROSS JOIN LATERAL (SELECT CASE d.billing_cycle
                                   WHEN 'weekly'    THEN interval '1 week'
                                   WHEN 'monthly'   THEN interval '1 month'
                                   WHEN 'quarterly' THEN interval '3 months'
                                   ELSE                  interval '1 year'
                               END AS step) c
    CROSS JOIN LATERAL generate_series(1, 600) AS g(n)
    CROSS JOIN LATERAL (SELECT (d.start_date + g.n * c.step)::date AS renewal_date) r
    WHERE d.household_id = p_household_id
      AND d.status = 'active'
      AND r.renewal_date BETWEEN CURRENT_DATE AND CURRENT_DATE + p_days
    ORDER BY r.renewal_date, d.price DESC
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
-- fingerprint and a plain-English message
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
       monthly_price AS savings
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
       savings
FROM v_consolidation
UNION ALL
SELECT household_id, 'spare_capacity', ARRAY[subscription_id], ARRAY[host_subscription_id], NULL,
       'spare:' || subscription_id || ':' || host_subscription_id,
       format('%s''s %s %s has a free spot (%s of %s used). %s could join it and cancel their own %s plan (%s/mo).',
              first_name(host_payer), service_name, host_plan, member_count, max_members,
              first_name(person), own_plan, inr(own_cost)),
       own_cost
FROM v_spare_capacity
UNION ALL
SELECT household_id, 'bundle', replaced_ids, '{}'::int[], recommended_plan_id,
       'bundle:' || recommended_plan_id,
       format('Your household pays separately for %s (%s/mo). %s %s includes %s for %s/mo.',
              human_list(replaced_names), inr(current_cost), bundle_service, bundle_plan,
              CASE WHEN covers_everything THEN 'all of them' ELSE 'these (and more)' END,
              inr(bundle_cost)),
       savings
FROM v_bundle_opportunities
UNION ALL
SELECT household_id, 'churn_risk', ARRAY[subscription_id], '{}'::int[], NULL,
       'churn:' || subscription_id,
       format('%s (%s) usage is falling: %s sessions per month over the last 6 months. At this rate nobody will be using it in about %s days.',
              service_name, plan_name, array_to_string(trend, ' → '), days_until_unused),
       monthly_price
FROM v_churn_risk
UNION ALL
SELECT household_id, 'waste', ARRAY[subscription_id], '{}'::int[], NULL,
       'waste:' || subscription_id,
       format('%s (%s) %s. %s pays %s/mo for it.',
              service_name, plan_name, reason, first_name(payer_name), inr(monthly_price)),
       monthly_price
FROM v_waste
UNION ALL
SELECT household_id, 'overlap', least_used_subscription_ids, '{}'::int[], NULL,
       'overlap:' || category_id,
       format('Your household pays for %s %s services (%s, %s/mo). %s is the least used, with %s session%s in the last 30 days.',
              services_in_category, category_name, human_list(services), inr(category_cost),
              least_used_service, least_used_sessions, CASE WHEN least_used_sessions = 1 THEN '' ELSE 's' END),
       savings
FROM v_category_overlap;

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

    INSERT INTO alert_subscriptions (alert_id, subscription_id, role)
    SELECT a.alert_id, sid, 'subject'
    FROM _findings f
    JOIN alerts a ON a.household_id = f.household_id AND a.fingerprint = f.fingerprint AND a.status = 'open'
    CROSS JOIN LATERAL UNNEST(f.subject_ids) AS sid
    UNION
    SELECT a.alert_id, sid, 'source'
    FROM _findings f
    JOIN alerts a ON a.household_id = f.household_id AND a.fingerprint = f.fingerprint AND a.status = 'open'
    CROSS JOIN LATERAL UNNEST(f.source_ids) AS sid
    ON CONFLICT DO NOTHING;

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
