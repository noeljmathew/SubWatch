-- ============================================================================
-- SubWatch — v2a checks (FR-28, FR-37, FR-38)
-- ============================================================================
-- "Done when: coverage and reason path match v1 findings on all three demo
-- households." Run on a freshly built database, from the repo root (the
-- baseline CSVs are read with relative paths):
--
--   db/tests/regress.sh                                   # builds subwatch_test
--   psql -X -q -v ON_ERROR_STOP=1 -d subwatch_test -f db/tests/v2a_check.sql
--
-- Everything runs in one transaction that is rolled back at the end, and
-- every test that changes data sits inside a savepoint, so the database is
-- left exactly as it was. The first failed check stops the script.
-- ============================================================================

\set ON_ERROR_STOP 1
SET client_min_messages = notice;
-- results are the PASS notices (stderr); query output is noise
\o /dev/null

BEGIN;

CREATE FUNCTION pg_temp.check(p_ok BOOLEAN, p_label TEXT) RETURNS VOID
LANGUAGE plpgsql SET jit = off AS $$
BEGIN
    IF p_ok IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL: %', p_label;
    END IF;
    RAISE NOTICE 'PASS: %', p_label;
END;
$$;

-- run p_sql and require it to fail with SQLSTATE p_state
CREATE FUNCTION pg_temp.expect_error(p_sql TEXT, p_state TEXT, p_label TEXT) RETURNS VOID
LANGUAGE plpgsql SET jit = off AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = p_state THEN
            RAISE NOTICE 'PASS: % (rejected: %)', p_label, SQLERRM;
            RETURN;
        END IF;
        RAISE EXCEPTION 'FAIL: % (expected %, got %: %)', p_label, p_state, SQLSTATE, SQLERRM;
    END;
    RAISE EXCEPTION 'FAIL: % (was accepted)', p_label;
END;
$$;

CREATE FUNCTION pg_temp.uid(p_name TEXT) RETURNS INT
LANGUAGE sql SET jit = off AS $$ SELECT user_id FROM users WHERE full_name = p_name $$;
CREATE FUNCTION pg_temp.sid(p_name TEXT) RETURNS INT
LANGUAGE sql SET jit = off AS $$ SELECT service_id FROM services WHERE name = p_name $$;

-- v1 baseline
CREATE TEMP TABLE base_dups (household TEXT, subscription_id INT, payer_name TEXT, service_name TEXT,
    plan_name TEXT, via_subscription_id INT, via_payer TEXT, via_service TEXT, via_plan TEXT,
    depth INT, path_label TEXT);
\copy base_dups FROM 'db/tests/v1_baseline/hidden_duplicates.csv' CSV HEADER
CREATE TEMP TABLE base_panel (household TEXT, subscription_id INT, via_service TEXT, via_plan TEXT,
    payer_name TEXT, member_names TEXT, depth INT, path_label TEXT, unlocked_service TEXT,
    also_paid_separately BOOLEAN);
\copy base_panel FROM 'db/tests/v1_baseline/household_entitlements.csv' CSV HEADER
CREATE TEMP TABLE base_summary (household_id INT, household TEXT, active_subscriptions INT,
    monthly_spend NUMERIC, savings_found NUMERIC, worth_a_look NUMERIC);
\copy base_summary FROM 'db/tests/v1_baseline/summary.csv' CSV HEADER

-- ---------------------------------------------------------------------------
\echo '--- locks and settings'
-- (first, before anything else in this transaction locks household 2)
-- ---------------------------------------------------------------------------
SAVEPOINT t;
CALL refresh_member_needs(2);
SELECT pg_temp.check(EXISTS (SELECT 1 FROM pg_locks
                             WHERE locktype = 'advisory' AND classid = 7140 AND objid = 2
                               AND pid = pg_backend_pid() AND granted),
       'refresh_member_needs takes the household lock');
ROLLBACK TO SAVEPOINT t;

SELECT pg_temp.check(
    (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname IN ('monthly_equivalent','plans_at','entitlements_at','check_plan_price',
                          'household_spend_at','path_label','entitlement_closure_at',
                          'refresh_member_needs','set_member_need','renewal_forecast')
        AND 'jit=off' = ANY (p.proconfig)) = 10,
    'all 10 new or changed v2a functions/procedures run with jit = off');

-- ---------------------------------------------------------------------------
\echo '--- FR-38: reason paths match v1'
-- ---------------------------------------------------------------------------
SELECT pg_temp.check(
    (SELECT COUNT(*) FROM base_dups) = 4
    AND NOT EXISTS (
        SELECT 1 FROM base_dups b
        WHERE NOT EXISTS (SELECT 1 FROM v_alert_reasons r
                          WHERE r.fingerprint = 'dup:' || b.subscription_id AND r.status = 'open'
                            AND r.role = 'subject' AND r.subscription_id = b.subscription_id
                            AND r.reason_label = b.path_label)),
    'every v1 hidden duplicate has the same path, as its stored reason path');

SELECT pg_temp.check(NOT EXISTS (
    SELECT 1 FROM v_alert_reasons r
    WHERE r.status = 'open' AND r.role = 'subject'
      AND (r.alert_type IN ('hidden_duplicate','consolidation','spare_capacity','bundle')) <> (r.reason_path IS NOT NULL)),
    'coverage-based findings have a reason path, usage-based ones do not');

SELECT pg_temp.check(NOT EXISTS (
    SELECT 1 FROM v_alert_reasons r WHERE r.role = 'source' AND r.reason_path IS NOT NULL),
    'source rows carry no reason path');

-- the path really explains the finding: it ends at the subject's service and
-- starts at the plan doing the covering
SELECT pg_temp.check(NOT EXISTS (
    SELECT 1
    FROM v_alert_reasons r
    JOIN alerts a          ON a.alert_id = r.alert_id
    JOIN subscriptions s   ON s.subscription_id = r.subscription_id
    JOIN plan_catalog sp   ON sp.plan_id = s.plan_id
    JOIN plan_catalog last ON last.plan_id = r.reason_path[cardinality(r.reason_path)]
    WHERE r.status = 'open' AND r.reason_path IS NOT NULL
      AND (last.service_id <> sp.service_id
           OR r.reason_path[1] <> CASE
                  WHEN r.alert_type IN ('consolidation','bundle') THEN a.recommended_plan_id
                  ELSE (SELECT hs.plan_id FROM alert_subscriptions x
                          JOIN subscriptions hs ON hs.subscription_id = x.subscription_id
                         WHERE x.alert_id = r.alert_id AND x.role = 'source')
              END)),
    'each reason path starts at the covering plan and ends at the subject''s service');

SELECT pg_temp.check(
    (SELECT array_agg(reason_label ORDER BY subscription_id) FROM v_alert_reasons
      WHERE fingerprint = 'bundle:30' AND role = 'subject')
    = ARRAY['Apple One (Individual) → Apple Music', 'Apple One (Individual) → iCloud+',
            'Apple One (Individual) → Apple TV+'],
    'Apple One bundle: one path per replaced subscription');

-- ---------------------------------------------------------------------------
\echo '--- coverage matches v1'
-- ---------------------------------------------------------------------------
SELECT pg_temp.check(
    NOT EXISTS (SELECT subscription_id, path_label FROM base_panel
                EXCEPT
                SELECT DISTINCT subscription_id, path_label FROM v_member_coverage WHERE depth > 0)
    AND NOT EXISTS (SELECT DISTINCT subscription_id, path_label FROM v_member_coverage WHERE depth > 0
                    EXCEPT
                    SELECT subscription_id, path_label FROM base_panel),
    'v_member_coverage reproduces the v1 Hidden entitlements panel exactly');

SELECT pg_temp.check(NOT EXISTS (
    SELECT 1 FROM v_hidden_duplicates hd
    JOIN subscription_members dm ON dm.subscription_id = hd.subscription_id
    WHERE NOT EXISTS (SELECT 1 FROM v_member_coverage mc
                      WHERE mc.user_id = dm.user_id
                        AND mc.service_id = (SELECT p.service_id FROM subscriptions s
                                               JOIN plan_catalog p ON p.plan_id = s.plan_id
                                              WHERE s.subscription_id = hd.subscription_id)
                        AND mc.subscription_id = hd.via_subscription_id
                        AND mc.path = hd.path)),
    'every member of every duplicate is covered through the via subscription, on the same path');

-- ---------------------------------------------------------------------------
\echo '--- FR-37: temporal data'
-- ---------------------------------------------------------------------------
SELECT pg_temp.check(NOT EXISTS (
    SELECT 1 FROM base_summary b WHERE household_spend_at(b.household_id, CURRENT_DATE) <> b.monthly_spend),
    'household_spend_at(today) equals v1 monthly spend for all three households');

SELECT pg_temp.check(
    household_spend_at(1, CURRENT_DATE - 100) = household_spend_at(1, CURRENT_DATE) - 50,
    'Sharma 100 days ago costs ₹50 less (Netflix Premium was ₹599)');

SELECT pg_temp.check(
    NOT EXISTS (SELECT * FROM plans_at(CURRENT_DATE) EXCEPT SELECT * FROM plans)
    AND NOT EXISTS (SELECT * FROM plans EXCEPT SELECT * FROM plans_at(CURRENT_DATE)),
    'plans view = plans_at(today)');

SELECT pg_temp.check(
    NOT EXISTS (SELECT root_plan_id, included_plan_id, path FROM entitlement_closure_at(CURRENT_DATE)
                EXCEPT SELECT root_plan_id, included_plan_id, path FROM v_entitlement_closure)
    AND NOT EXISTS (SELECT root_plan_id, included_plan_id, path FROM v_entitlement_closure
                    EXCEPT SELECT root_plan_id, included_plan_id, path FROM entitlement_closure_at(CURRENT_DATE)),
    'v_entitlement_closure = entitlement_closure_at(today)');

SELECT pg_temp.check(
    EXISTS (SELECT 1 FROM entitlement_closure_at(CURRENT_DATE - 200)
            WHERE path_label = 'Airtel Postpaid (Family 1199) → Netflix')
    AND NOT EXISTS (SELECT 1 FROM v_entitlement_closure
                    WHERE path_label = 'Airtel Postpaid (Family 1199) → Netflix'),
    'ended inclusion: Airtel reached Netflix 200 days ago, not today');

SELECT pg_temp.expect_error(
    $$INSERT INTO plan_price_history (plan_id, price, valid_from)
      SELECT plan_id, 700, CURRENT_DATE - 10 FROM plan_catalog
       WHERE name = 'Premium' AND service_id = pg_temp.sid('Netflix')$$,
    '23P01', 'overlapping price range');

SELECT pg_temp.expect_error(
    $$INSERT INTO plan_inclusion_history (parent_plan_id, included_plan_id, valid_from)
      SELECT parent_plan_id, included_plan_id, CURRENT_DATE - 5 FROM plan_inclusion_history LIMIT 1$$,
    '23P01', 'overlapping inclusion range');

SELECT pg_temp.expect_error(
    $$INSERT INTO plan_price_history (plan_id, price, valid_from)
      SELECT plan_id, 10, CURRENT_DATE + 1000 FROM plan_catalog WHERE tier = 'included' LIMIT 1$$,
    '23514', 'included plan with a price');

SELECT pg_temp.expect_error(
    $$INSERT INTO plan_price_history (plan_id, price, valid_from, valid_to)
      SELECT plan_id, 10, CURRENT_DATE + 1000, CURRENT_DATE + 1000 FROM plan_catalog WHERE tier <> 'included' LIMIT 1$$,
    '23514', 'empty price range (valid_to = valid_from)');

-- the forecast prices each renewal at the price valid on that date
SAVEPOINT t;
UPDATE plan_price_history SET valid_to = CURRENT_DATE + 1
 WHERE valid_to IS NULL
   AND plan_id = (SELECT plan_id FROM plan_catalog WHERE name = 'Premium' AND service_id = pg_temp.sid('Netflix'));
INSERT INTO plan_price_history (plan_id, price, valid_from)
SELECT plan_id, 699, CURRENT_DATE + 1 FROM plan_catalog WHERE name = 'Premium' AND service_id = pg_temp.sid('Netflix');
SELECT pg_temp.check(
    EXISTS (SELECT 1 FROM renewal_forecast(1, 31) WHERE service_name = 'Netflix')
    AND NOT EXISTS (SELECT 1 FROM renewal_forecast(1, 31) WHERE service_name = 'Netflix'
                     AND amount <> CASE WHEN renewal_date >= CURRENT_DATE + 1 THEN 699 ELSE 649 END),
    'renewal_forecast uses the price valid on each renewal date');
ROLLBACK TO SAVEPOINT t;

SAVEPOINT t;
INSERT INTO plan_catalog (service_id, name, tier) VALUES (pg_temp.sid('Netflix'), 'Unpriced test plan', 'individual');
SELECT pg_temp.expect_error(
    $$INSERT INTO subscriptions (payer_id, plan_id, start_date)
      SELECT pg_temp.uid('Priya Sharma'), plan_id, CURRENT_DATE FROM plan_catalog WHERE name = 'Unpriced test plan'$$,
    '23514', 'subscribing to a plan with no current price');
ROLLBACK TO SAVEPOINT t;

-- ---------------------------------------------------------------------------
\echo '--- FR-28: member needs'
-- ---------------------------------------------------------------------------
SELECT pg_temp.check(NOT EXISTS (SELECT 1 FROM v_need_coverage WHERE NOT covered),
    'every need is covered today');

SELECT pg_temp.check(NOT EXISTS (
    SELECT 1
    FROM v_subscription_detail d
    JOIN subscription_members sm ON sm.subscription_id = d.subscription_id
    WHERE d.status = 'active' AND d.is_passive
      AND NOT EXISTS (SELECT 1 FROM member_needs n
                      WHERE n.user_id = sm.user_id AND n.service_id = d.service_id AND n.is_needed)),
    'every member of every passive subscription (phone plans, cloud storage) needs it');

SELECT pg_temp.check(
    (SELECT COUNT(*) FROM v_subscription_detail d
      WHERE d.status = 'active' AND d.is_passive AND d.total_sessions = 0) = 4,
    '...and those are the 4 passive subscriptions with no usage logs at all');

SELECT pg_temp.check(NOT EXISTS (
    SELECT 1 FROM member_needs n
    WHERE (n.user_id, n.service_id) IN ((pg_temp.uid('Arjun Sharma'), pg_temp.sid('Audible')),
                                        (pg_temp.uid('Vikram Iyer'),  pg_temp.sid('LinkedIn Premium')),
                                        (pg_temp.uid('Vikram Iyer'),  pg_temp.sid('Amazon Prime')))),
    'no need for v1''s unused subscriptions (Audible, LinkedIn) or the cancelled, unused Prime');

SELECT pg_temp.check(NOT EXISTS (
    SELECT 1 FROM alerts a JOIN alert_subscriptions x ON x.alert_id = a.alert_id
    JOIN subscriptions s   ON s.subscription_id = x.subscription_id
    JOIN plan_catalog p    ON p.plan_id = s.plan_id
    WHERE a.status = 'open' AND a.alert_type = 'waste' AND x.role = 'subject'
      AND EXISTS (SELECT 1 FROM member_needs n JOIN subscription_members sm ON sm.user_id = n.user_id
                  WHERE sm.subscription_id = s.subscription_id AND n.service_id = p.service_id AND n.is_needed)),
    'nobody on a v1 waste finding needs that service');

-- decision 3: usage on a cancelled subscription still counts
SAVEPOINT t;
INSERT INTO usage_logs (subscription_id, user_id, used_at, duration_minutes)
SELECT s.subscription_id, s.payer_id, now() - interval '2 days', 30
FROM subscriptions s WHERE s.payer_id = pg_temp.uid('Vikram Iyer') AND s.status = 'cancelled';
CALL refresh_alerts(3);
SELECT pg_temp.check(EXISTS (
    SELECT 1 FROM v_need_coverage
    WHERE user_id = pg_temp.uid('Vikram Iyer') AND service_id = pg_temp.sid('Amazon Prime')
      AND source = 'usage' AND covered AND depth = 1
      AND path_label = 'Jio Postpaid (Plus 699) → Amazon Prime'),
    'usage on the cancelled Prime creates a need, covered through Jio');
ROLLBACK TO SAVEPOINT t;

-- decisions 3 and 4 together: after Rahul moves to Apple One, his usage needs
-- (logged on the now-cancelled plans) stay, and iCloud+ stays needed as a
-- passive service reached through the bundle
SAVEPOINT t;
SELECT apply_alert(alert_id) FROM alerts WHERE household_id = 2 AND fingerprint = 'bundle:30';
SELECT pg_temp.check(
    (SELECT array_agg(s.name || ':' || nc.source || ':' || nc.covered || ':' || nc.path_label ORDER BY s.name)
       FROM v_need_coverage nc JOIN services s USING (service_id)
      WHERE nc.user_id = pg_temp.uid('Rahul Verma') AND s.name IN ('Apple Music','Apple TV+','iCloud+'))
    = ARRAY['Apple Music:usage:true:Apple One (Individual) → Apple Music',
            'Apple TV+:usage:true:Apple One (Individual) → Apple TV+',
            'iCloud+:passive:true:Apple One (Individual) → iCloud+'],
    'after applying the Apple One bundle, Rahul''s needs stay and are covered by the bundle');
ROLLBACK TO SAVEPOINT t;

-- manual overrides
SAVEPOINT t;
SELECT set_member_need(pg_temp.uid('Vikram Iyer'), pg_temp.sid('Google One'), false);
CALL refresh_alerts(3);
SELECT pg_temp.check(
    (SELECT source || '/' || is_needed FROM member_needs
      WHERE user_id = pg_temp.uid('Vikram Iyer') AND service_id = pg_temp.sid('Google One')) = 'manual/false'
    AND NOT EXISTS (SELECT 1 FROM v_need_coverage
                    WHERE user_id = pg_temp.uid('Vikram Iyer') AND service_id = pg_temp.sid('Google One')),
    'a manual "not needed" survives a refresh and hides the need');
SELECT set_member_need(pg_temp.uid('Vikram Iyer'), pg_temp.sid('Google One'), NULL);
SELECT pg_temp.check(
    (SELECT source || '/' || is_needed FROM member_needs
      WHERE user_id = pg_temp.uid('Vikram Iyer') AND service_id = pg_temp.sid('Google One')) = 'passive/true',
    'clearing the override brings the automatic need back');
SELECT set_member_need(pg_temp.uid('Vikram Iyer'), pg_temp.sid('Audible'), true);
CALL refresh_alerts(3);
SELECT pg_temp.check(EXISTS (
    SELECT 1 FROM v_need_coverage
    WHERE user_id = pg_temp.uid('Vikram Iyer') AND service_id = pg_temp.sid('Audible')
      AND source = 'manual' AND NOT covered),
    'a manual need nobody covers shows as uncovered');
ROLLBACK TO SAVEPOINT t;

SELECT pg_temp.expect_error(
    $$INSERT INTO member_needs (user_id, service_id, source, is_needed)
      VALUES (pg_temp.uid('Vikram Iyer'), pg_temp.sid('Audible'), 'usage', false)$$,
    '23514', 'an automatic need marked not needed');

SELECT pg_temp.expect_error(
    $$INSERT INTO member_needs (user_id, service_id, source)
      SELECT u.user_id, pg_temp.sid('Audible'), 'manual' FROM users u
       WHERE NOT EXISTS (SELECT 1 FROM household_members hm WHERE hm.user_id = u.user_id)
      UNION ALL SELECT 999999, pg_temp.sid('Audible'), 'manual'$$,
    '23503', 'a need for someone outside any household');

-- ---------------------------------------------------------------------------
\echo '--- v1 behaviour on the new schema'
-- ---------------------------------------------------------------------------
SAVEPOINT t;
SELECT pg_temp.check(
    (SELECT apply_alert(alert_id) FROM alerts WHERE household_id = 1 AND fingerprint = 'consolidate:9')
    = ARRAY['Start Spotify Family (₹179/mo), paid by Dev, shared with Arjun and Meera',
            'Cancel Arjun''s Spotify (Individual), ₹119/mo',
            'Cancel Meera''s Spotify (Individual), ₹119/mo',
            'Cancel Dev''s Spotify (Student), ₹59/mo'],
    'apply_alert still runs the v1 Spotify Family fix step by step');
SELECT pg_temp.check(household_spend_at(1, CURRENT_DATE) = 3036.51 - 118,
    '...and Sharma spend drops by the ₹118 the finding promised');
ROLLBACK TO SAVEPOINT t;

ROLLBACK;
\o
\echo 'v2a checks: all passed'
