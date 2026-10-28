-- ============================================================================
-- SubWatch — snapshot of everything v1 computes, as CSV files
-- ============================================================================
-- Used to prove v2 changes nothing v1 already does. Run it against a fresh
-- database (schema.sql, seed.sql, detection.sql) and diff the output with
-- db/tests/v1_baseline/:
--
--   psql -X -q -v ON_ERROR_STOP=1 -d <db> -v outdir=<dir> -f db/tests/snapshot.sql
--
-- Only deterministic columns are written. Usage logs get random timestamps
-- inside their 30-day bucket, so anything quoting "days since last use" (the
-- waste message for a sub that was used once) can differ between seeds; those
-- messages go to alert_messages.csv, which is for reading, not diffing.
-- Everything is keyed by names as well as ids so a diff is readable.
-- ============================================================================

\pset format csv
\pset footer off

-- catalog: every plan with its (current) price
\set f :outdir '/catalog_plans.csv'
\o :f
SELECT p.plan_id, s.name AS service, p.name AS plan, p.tier, p.price, p.billing_cycle,
       p.max_members, p.is_purchasable, p.monthly_price
FROM plans p JOIN services s ON s.service_id = p.service_id
ORDER BY p.plan_id;

-- catalog: direct entitlement edges
\set f :outdir '/catalog_entitlements.csv'
\o :f
SELECT e.plan_id, e.included_plan_id
FROM entitlements e
ORDER BY e.plan_id, e.included_plan_id;

-- the transitive closure the detectors walk
\set f :outdir '/entitlement_closure.csv'
\o :f
SELECT root_plan_id, included_plan_id, included_service_id, depth, path, path_label
FROM v_entitlement_closure
ORDER BY root_plan_id, included_plan_id, path;

-- subscriptions, who shares them, what they cost per month
\set f :outdir '/subscriptions.csv'
\o :f
SELECT d.subscription_id, h.name AS household, d.payer_name, d.service_name, d.plan_name,
       d.status, d.monthly_price, d.member_count,
       (SELECT string_agg(u.full_name, '; ' ORDER BY u.full_name)
          FROM subscription_members sm JOIN users u ON u.user_id = sm.user_id
         WHERE sm.subscription_id = d.subscription_id) AS members
FROM v_subscription_detail d
JOIN households h ON h.household_id = d.household_id
ORDER BY d.subscription_id;

-- household totals, computed the way GET /api/households/:id/summary does
-- (hard types count toward "savings found", capped at spend)
\set f :outdir '/summary.csv'
\o :f
SELECT h.household_id, h.name AS household,
       (SELECT COUNT(*) FROM v_subscription_detail d
         WHERE d.household_id = h.household_id AND d.status = 'active')                  AS active_subscriptions,
       (SELECT COALESCE(SUM(monthly_price), 0) FROM v_subscription_detail d
         WHERE d.household_id = h.household_id AND d.status = 'active')                  AS monthly_spend,
       LEAST((SELECT COALESCE(SUM(potential_monthly_savings), 0) FROM alerts a
               WHERE a.household_id = h.household_id AND a.status = 'open'
                 AND a.alert_type IN ('hidden_duplicate','consolidation','spare_capacity','bundle','waste')),
             (SELECT COALESCE(SUM(monthly_price), 0) FROM v_subscription_detail d
               WHERE d.household_id = h.household_id AND d.status = 'active'))           AS savings_found,
       (SELECT COALESCE(SUM(potential_monthly_savings), 0) FROM alerts a
         WHERE a.household_id = h.household_id AND a.status = 'open'
           AND a.alert_type NOT IN ('hidden_duplicate','consolidation','spare_capacity','bundle','waste')) AS worth_a_look
FROM households h
ORDER BY h.household_id;

-- open findings: what, how much, about which subscriptions
\set f :outdir '/alerts.csv'
\o :f
SELECT h.name AS household, a.alert_type, a.fingerprint,
       s.name || ' ' || p.name AS recommended_plan,
       a.potential_monthly_savings,
       COALESCE((SELECT array_agg(x.subscription_id ORDER BY x.subscription_id)
                   FROM alert_subscriptions x WHERE x.alert_id = a.alert_id AND x.role = 'subject'), '{}') AS subject_ids,
       COALESCE((SELECT array_agg(x.subscription_id ORDER BY x.subscription_id)
                   FROM alert_subscriptions x WHERE x.alert_id = a.alert_id AND x.role = 'source'),  '{}') AS source_ids
FROM alerts a
JOIN households h     ON h.household_id = a.household_id
LEFT JOIN plans p     ON p.plan_id = a.recommended_plan_id
LEFT JOIN services s  ON s.service_id = p.service_id
WHERE a.status = 'open'
ORDER BY a.household_id, a.fingerprint;

-- the messages themselves (for reading; see the note at the top)
\set f :outdir '/alert_messages.csv'
\o :f
SELECT h.name AS household, a.fingerprint, a.message
FROM alerts a JOIN households h ON h.household_id = a.household_id
WHERE a.status = 'open'
ORDER BY a.household_id, a.fingerprint;

-- hidden duplicates with the path that explains each one (what FR-38's
-- reason paths must reproduce)
\set f :outdir '/hidden_duplicates.csv'
\o :f
SELECT h.name AS household, hd.subscription_id, hd.payer_name, hd.service_name, hd.plan_name,
       hd.via_subscription_id, hd.via_payer, hd.via_service, hd.via_plan, hd.depth, hd.path_label
FROM v_hidden_duplicates hd
JOIN households h ON h.household_id = hd.household_id
ORDER BY hd.household_id, hd.subscription_id;

-- the "Hidden entitlements" panel (GET /api/households/:id/entitlements)
\set f :outdir '/household_entitlements.csv'
\o :f
SELECT h.name AS household, d.subscription_id, d.service_name AS via_service, d.plan_name AS via_plan,
       d.payer_name, d.member_names, cl.depth, cl.path_label,
       s.name AS unlocked_service,
       EXISTS (SELECT 1 FROM v_hidden_duplicates hd
               WHERE hd.via_subscription_id = d.subscription_id
                 AND hd.service_name = s.name) AS also_paid_separately
FROM v_subscription_detail d
JOIN households h             ON h.household_id = d.household_id
JOIN v_entitlement_closure cl ON cl.root_plan_id = d.plan_id
JOIN services s               ON s.service_id = cl.included_service_id
WHERE d.status = 'active'
ORDER BY d.household_id, d.subscription_id, cl.depth, s.name;

\o
