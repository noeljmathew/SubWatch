-- ============================================================================
-- SubWatch — Seed Data
-- ============================================================================
-- Prices are illustrative sample values in INR, loosely based on Indian
-- pricing — not an authoritative price list. Entitlements (e.g. "this telecom
-- plan includes Amazon Prime") are also sample data for the demo.
--
-- All dates are relative to now() so the demo keeps working whenever it runs.
-- Three households, each set up to trigger specific optimizer findings:
--   Sharma Household  — hidden duplicates (direct + 2-level transitive),
--                       family-plan consolidation, churn, waste, cost splitting
--   Hostel Room A-412 — consolidation, spare capacity on a Duo plan, an
--                       Apple One bundle opportunity, churn, overlap
--   Iyer Residence    — telecom-included Netflix, Duo consolidation, waste,
--                       and a cancelled sub that must NOT raise anything
-- ============================================================================

-- ---------------------------------------------------------------------------
-- catalog
-- ---------------------------------------------------------------------------
INSERT INTO categories (name, is_passive) VALUES
    ('Video Streaming',       false),
    ('Music Streaming',       false),
    ('Memberships & Bundles', false),
    ('Audiobooks',            false),
    ('Career',                false),
    ('Cloud Storage',         true),
    ('Telecom',               true);

INSERT INTO services (name, category_id, website)
SELECT v.name, c.category_id, v.website
FROM (VALUES
    ('Netflix',          'Video Streaming',       'https://netflix.com'),
    ('JioHotstar',       'Video Streaming',       'https://jiohotstar.com'),
    ('Prime Video',      'Video Streaming',       'https://primevideo.com'),
    ('YouTube Premium',  'Video Streaming',       'https://youtube.com/premium'),
    ('Apple TV+',        'Video Streaming',       'https://tv.apple.com'),
    ('Spotify',          'Music Streaming',       'https://spotify.com'),
    ('YouTube Music',    'Music Streaming',       'https://music.youtube.com'),
    ('Apple Music',      'Music Streaming',       'https://music.apple.com'),
    ('Amazon Music',     'Music Streaming',       'https://music.amazon.in'),
    ('Amazon Prime',     'Memberships & Bundles', 'https://amazon.in/prime'),
    ('Apple One',        'Memberships & Bundles', 'https://apple.com/apple-one'),
    ('Audible',          'Audiobooks',            'https://audible.in'),
    ('LinkedIn Premium', 'Career',                'https://linkedin.com/premium'),
    ('iCloud+',          'Cloud Storage',         'https://icloud.com'),
    ('Google One',       'Cloud Storage',         'https://one.google.com'),
    ('Airtel Postpaid',  'Telecom',               'https://airtel.in'),
    ('Jio Postpaid',     'Telecom',               'https://jio.com')
) AS v(name, category, website)
JOIN categories c ON c.name = v.category;

INSERT INTO plans (service_id, name, tier, price, billing_cycle, max_members, is_purchasable)
SELECT s.service_id, v.plan, v.tier, v.price, v.cycle, v.max_members, v.purchasable
FROM (VALUES
    ('Netflix',          'Mobile',                    'individual', 149,  'monthly',   1, true),
    ('Netflix',          'Basic',                     'individual', 199,  'monthly',   1, true),
    ('Netflix',          'Standard',                  'duo',        499,  'monthly',   2, true),
    ('Netflix',          'Premium',                   'family',     649,  'monthly',   4, true),
    ('Netflix',          'Basic (included)',          'included',   0,    'monthly',   1, false),
    ('JioHotstar',       'Mobile',                    'individual', 149,  'quarterly', 1, true),
    ('JioHotstar',       'Super',                     'duo',        299,  'quarterly', 2, true),
    ('JioHotstar',       'Premium',                   'family',     499,  'quarterly', 4, true),
    ('JioHotstar',       'Included',                  'included',   0,    'monthly',   1, false),
    ('Prime Video',      'Mobile Edition',            'individual', 599,  'yearly',    1, true),
    ('Prime Video',      'Included with Prime',       'included',   0,    'monthly',   1, false),
    ('YouTube Premium',  'Individual',                'individual', 149,  'monthly',   1, true),
    ('YouTube Premium',  'Student',                   'student',    89,   'monthly',   1, true),
    ('YouTube Premium',  'Family',                    'family',     299,  'monthly',   5, true),
    ('Apple TV+',        'Monthly',                   'individual', 99,   'monthly',   1, true),
    ('Apple TV+',        'Included with Apple One',   'included',   0,    'monthly',   1, false),
    ('Spotify',          'Individual',                'individual', 119,  'monthly',   1, true),
    ('Spotify',          'Student',                   'student',    59,   'monthly',   1, true),
    ('Spotify',          'Duo',                       'duo',        149,  'monthly',   2, true),
    ('Spotify',          'Family',                    'family',     179,  'monthly',   6, true),
    ('YouTube Music',    'Individual',                'individual', 119,  'monthly',   1, true),
    ('YouTube Music',    'Family',                    'family',     179,  'monthly',   5, true),
    ('YouTube Music',    'Included with YT Premium',  'included',   0,    'monthly',   1, false),
    ('Apple Music',      'Individual',                'individual', 99,   'monthly',   1, true),
    ('Apple Music',      'Student',                   'student',    59,   'monthly',   1, true),
    ('Apple Music',      'Family',                    'family',     149,  'monthly',   6, true),
    ('Apple Music',      'Included with Apple One',   'included',   0,    'monthly',   1, false),
    ('Amazon Music',     'Included with Prime',       'included',   0,    'monthly',   1, false),
    ('Amazon Prime',     'Annual',                    'duo',        1499, 'yearly',    2, true),
    ('Amazon Prime',     'Monthly',                   'duo',        299,  'monthly',   2, true),
    ('Amazon Prime',     'Included',                  'included',   0,    'monthly',   1, false),
    ('Apple One',        'Individual',                'individual', 195,  'monthly',   1, true),
    ('Apple One',        'Family',                    'family',     365,  'monthly',   6, true),
    ('Audible',          'Monthly',                   'individual', 199,  'monthly',   1, true),
    ('LinkedIn Premium', 'Career',                    'individual', 1500, 'monthly',   1, true),
    ('iCloud+',          '50 GB',                     'individual', 75,   'monthly',   1, true),
    ('iCloud+',          '200 GB',                    'family',     219,  'monthly',   6, true),
    ('iCloud+',          '50 GB (included)',          'included',   0,    'monthly',   1, false),
    ('Google One',       '100 GB',                    'family',     130,  'monthly',   5, true),
    ('Airtel Postpaid',  'Individual 449',            'individual', 449,  'monthly',   1, true),
    ('Airtel Postpaid',  'Family 1199',               'family',     1199, 'monthly',   4, true),
    ('Jio Postpaid',     'Plus 699',                  'family',     699,  'monthly',   4, true)
) AS v(service, plan, tier, price, cycle, max_members, purchasable)
JOIN services s ON s.name = v.service;

-- helper used only while seeding: look up a plan by service + plan name
CREATE FUNCTION pg_temp.plan_id(p_service TEXT, p_plan TEXT) RETURNS INT AS $$
    SELECT p.plan_id FROM plans p JOIN services s ON s.service_id = p.service_id
    WHERE s.name = p_service AND p.name = p_plan
$$ LANGUAGE sql;

-- entitlement graph (edges: plan -> included plan)
INSERT INTO entitlements (plan_id, included_plan_id) VALUES
    -- Amazon Prime includes Prime Video and Amazon Music
    (pg_temp.plan_id('Amazon Prime','Annual'),   pg_temp.plan_id('Prime Video','Included with Prime')),
    (pg_temp.plan_id('Amazon Prime','Annual'),   pg_temp.plan_id('Amazon Music','Included with Prime')),
    (pg_temp.plan_id('Amazon Prime','Monthly'),  pg_temp.plan_id('Prime Video','Included with Prime')),
    (pg_temp.plan_id('Amazon Prime','Monthly'),  pg_temp.plan_id('Amazon Music','Included with Prime')),
    (pg_temp.plan_id('Amazon Prime','Included'), pg_temp.plan_id('Prime Video','Included with Prime')),
    (pg_temp.plan_id('Amazon Prime','Included'), pg_temp.plan_id('Amazon Music','Included with Prime')),
    -- telecom plans that bundle OTT memberships (2nd level reaches Prime Video)
    (pg_temp.plan_id('Airtel Postpaid','Family 1199'), pg_temp.plan_id('Amazon Prime','Included')),
    (pg_temp.plan_id('Jio Postpaid','Plus 699'), pg_temp.plan_id('Netflix','Basic (included)')),
    (pg_temp.plan_id('Jio Postpaid','Plus 699'), pg_temp.plan_id('Amazon Prime','Included')),
    (pg_temp.plan_id('Jio Postpaid','Plus 699'), pg_temp.plan_id('JioHotstar','Included')),
    -- YouTube Premium includes YouTube Music
    (pg_temp.plan_id('YouTube Premium','Individual'), pg_temp.plan_id('YouTube Music','Included with YT Premium')),
    (pg_temp.plan_id('YouTube Premium','Student'),    pg_temp.plan_id('YouTube Music','Included with YT Premium')),
    (pg_temp.plan_id('YouTube Premium','Family'),     pg_temp.plan_id('YouTube Music','Included with YT Premium')),
    -- Apple One bundles Apple Music, iCloud+ and Apple TV+
    (pg_temp.plan_id('Apple One','Individual'), pg_temp.plan_id('Apple Music','Included with Apple One')),
    (pg_temp.plan_id('Apple One','Individual'), pg_temp.plan_id('iCloud+','50 GB (included)')),
    (pg_temp.plan_id('Apple One','Individual'), pg_temp.plan_id('Apple TV+','Included with Apple One')),
    (pg_temp.plan_id('Apple One','Family'),     pg_temp.plan_id('Apple Music','Included with Apple One')),
    (pg_temp.plan_id('Apple One','Family'),     pg_temp.plan_id('iCloud+','50 GB (included)')),
    (pg_temp.plan_id('Apple One','Family'),     pg_temp.plan_id('Apple TV+','Included with Apple One'));

-- ---------------------------------------------------------------------------
-- people
-- ---------------------------------------------------------------------------
INSERT INTO households (name, monthly_budget) VALUES
    ('Sharma Household',  4000),
    ('Hostel Room A-412', 1500),
    ('Iyer Residence',    2500);

INSERT INTO users (full_name, email, password_hash) VALUES
    ('Priya Sharma',  'priya.sharma@example.com',  'hash_placeholder'),
    ('Arjun Sharma',  'arjun.sharma@example.com',  'hash_placeholder'),
    ('Meera Sharma',  'meera.sharma@example.com',  'hash_placeholder'),
    ('Dev Sharma',    'dev.sharma@example.com',    'hash_placeholder'),
    ('Rahul Verma',   'rahul.verma@example.com',   'hash_placeholder'),
    ('Karthik Nair',  'karthik.nair@example.com',  'hash_placeholder'),
    ('Aditya Rao',    'aditya.rao@example.com',    'hash_placeholder'),
    ('Ananya Iyer',   'ananya.iyer@example.com',   'hash_placeholder'),
    ('Vikram Iyer',   'vikram.iyer@example.com',   'hash_placeholder');

INSERT INTO household_members (household_id, user_id, role)
SELECT h.household_id, u.user_id, v.role
FROM (VALUES
    ('Sharma Household',  'priya.sharma@example.com',  'owner'),
    ('Sharma Household',  'arjun.sharma@example.com',  'member'),
    ('Sharma Household',  'meera.sharma@example.com',  'member'),
    ('Sharma Household',  'dev.sharma@example.com',    'member'),
    ('Hostel Room A-412', 'rahul.verma@example.com',   'owner'),
    ('Hostel Room A-412', 'karthik.nair@example.com',  'member'),
    ('Hostel Room A-412', 'aditya.rao@example.com',    'member'),
    ('Iyer Residence',    'ananya.iyer@example.com',   'owner'),
    ('Iyer Residence',    'vikram.iyer@example.com',   'member')
) AS v(household, email, role)
JOIN households h ON h.name = v.household
JOIN users u ON u.email = v.email;

-- ---------------------------------------------------------------------------
-- seeding helpers
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.uid(p_email TEXT) RETURNS INT AS $$
    SELECT user_id FROM users WHERE email = p_email
$$ LANGUAGE sql;

-- new subscription; the payer is auto-added as a member by trg_enrol_payer
CREATE FUNCTION pg_temp.sub(p_payer TEXT, p_service TEXT, p_plan TEXT, p_days_ago INT) RETURNS INT AS $$
    INSERT INTO subscriptions (payer_id, plan_id, start_date)
    VALUES (pg_temp.uid(p_payer), pg_temp.plan_id(p_service, p_plan), CURRENT_DATE - p_days_ago)
    RETURNING subscription_id
$$ LANGUAGE sql;

CREATE FUNCTION pg_temp.share(p_sub INT, p_email TEXT) RETURNS VOID AS $$
    INSERT INTO subscription_members (subscription_id, user_id) VALUES (p_sub, pg_temp.uid(p_email))
$$ LANGUAGE sql;

-- usage: p_counts[1] = sessions in the last 30 days, p_counts[2] = 30-60 days
-- ago, ... up to 6 buckets (180 days)
CREATE FUNCTION pg_temp.usage(p_sub INT, p_email TEXT, p_counts INT[], p_minutes INT) RETURNS VOID AS $$
DECLARE
    k INT;
    i INT;
BEGIN
    FOR k IN 1 .. array_length(p_counts, 1) LOOP
        FOR i IN 1 .. p_counts[k] LOOP
            INSERT INTO usage_logs (subscription_id, user_id, used_at, duration_minutes)
            VALUES (p_sub, pg_temp.uid(p_email),
                    now() - ((k - 1) * 30 + 1 + random() * 28) * interval '1 day',
                    GREATEST(5, p_minutes + (random() * 20 - 10)::int));
        END LOOP;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- Sharma Household
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    airtel INT; primevideo INT; prime INT; ytp INT; ytm INT;
    sp_arjun INT; sp_meera INT; sp_dev INT; netflix INT; hotstar INT; audible INT;
BEGIN
    -- Airtel family postpaid (includes Amazon Prime -> Prime Video, Amazon Music)
    airtel := pg_temp.sub('arjun.sharma@example.com', 'Airtel Postpaid', 'Family 1199', 400);
    PERFORM pg_temp.share(airtel, 'priya.sharma@example.com');
    PERFORM pg_temp.share(airtel, 'meera.sharma@example.com');

    -- Priya pays for Prime Video separately -> hidden duplicate, 2 levels deep
    primevideo := pg_temp.sub('priya.sharma@example.com', 'Prime Video', 'Mobile Edition', 300);
    PERFORM pg_temp.usage(primevideo, 'priya.sharma@example.com', ARRAY[5,6,5,6,5,6], 60);

    -- Meera pays for Amazon Prime separately -> hidden duplicate, 1 level deep
    prime := pg_temp.sub('meera.sharma@example.com', 'Amazon Prime', 'Annual', 250);
    PERFORM pg_temp.usage(prime, 'meera.sharma@example.com', ARRAY[3,4,3,4,3,3], 20);

    -- YouTube Premium Family (Priya + Dev), but Dev also pays for YouTube Music
    ytp := pg_temp.sub('priya.sharma@example.com', 'YouTube Premium', 'Family', 500);
    PERFORM pg_temp.share(ytp, 'dev.sharma@example.com');
    PERFORM pg_temp.usage(ytp, 'priya.sharma@example.com', ARRAY[10,9,11,10,9,10], 40);
    PERFORM pg_temp.usage(ytp, 'dev.sharma@example.com',   ARRAY[20,22,19,21,20,22], 50);
    ytm := pg_temp.sub('dev.sharma@example.com', 'YouTube Music', 'Individual', 200);
    PERFORM pg_temp.usage(ytm, 'dev.sharma@example.com', ARRAY[15,14,16,15,14,15], 45);

    -- three separate Spotify plans -> one Family plan is cheaper
    sp_arjun := pg_temp.sub('arjun.sharma@example.com', 'Spotify', 'Individual', 600);
    sp_meera := pg_temp.sub('meera.sharma@example.com', 'Spotify', 'Individual', 450);
    sp_dev   := pg_temp.sub('dev.sharma@example.com',   'Spotify', 'Student',    350);
    PERFORM pg_temp.usage(sp_arjun, 'arjun.sharma@example.com', ARRAY[18,20,19,18,20,19], 45);
    PERFORM pg_temp.usage(sp_meera, 'meera.sharma@example.com', ARRAY[12,11,13,12,11,12], 30);
    PERFORM pg_temp.usage(sp_dev,   'dev.sharma@example.com',   ARRAY[25,24,26,25,24,26], 60);

    -- Netflix Premium shared by all four, used very unevenly -> fair-share split
    netflix := pg_temp.sub('priya.sharma@example.com', 'Netflix', 'Premium', 700);
    PERFORM pg_temp.share(netflix, 'arjun.sharma@example.com');
    PERFORM pg_temp.share(netflix, 'meera.sharma@example.com');
    PERFORM pg_temp.share(netflix, 'dev.sharma@example.com');
    PERFORM pg_temp.usage(netflix, 'priya.sharma@example.com', ARRAY[6,7,6,7,6,7], 90);
    PERFORM pg_temp.usage(netflix, 'arjun.sharma@example.com', ARRAY[2,2,3,2,2,3], 60);
    PERFORM pg_temp.usage(netflix, 'meera.sharma@example.com', ARRAY[14,15,13,14,15,14], 100);
    PERFORM pg_temp.usage(netflix, 'dev.sharma@example.com',   ARRAY[8,8,9,8,8,9], 80);

    -- JioHotstar shared by Dev + Arjun, usage falling off a cliff -> churn risk
    hotstar := pg_temp.sub('dev.sharma@example.com', 'JioHotstar', 'Super', 380);
    PERFORM pg_temp.share(hotstar, 'arjun.sharma@example.com');
    PERFORM pg_temp.usage(hotstar, 'dev.sharma@example.com',   ARRAY[1,2,4,6,8,10], 70);
    PERFORM pg_temp.usage(hotstar, 'arjun.sharma@example.com', ARRAY[0,1,1,2,2,3], 50);

    -- Audible: last opened ~2-3 months ago -> waste
    audible := pg_temp.sub('arjun.sharma@example.com', 'Audible', 'Monthly', 320);
    PERFORM pg_temp.usage(audible, 'arjun.sharma@example.com', ARRAY[0,0,1,2,3,3], 40);
END $$;

-- ---------------------------------------------------------------------------
-- Hostel Room A-412
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    yt_rahul INT; yt_karthik INT; yt_aditya INT; duo INT; sp_aditya INT;
    am INT; ic INT; tv INT; nf INT; hs INT;
BEGIN
    -- three YouTube Premium plans -> one Family plan
    yt_rahul   := pg_temp.sub('rahul.verma@example.com',  'YouTube Premium', 'Individual', 300);
    yt_karthik := pg_temp.sub('karthik.nair@example.com', 'YouTube Premium', 'Individual', 280);
    yt_aditya  := pg_temp.sub('aditya.rao@example.com',   'YouTube Premium', 'Student',    260);
    PERFORM pg_temp.usage(yt_rahul,   'rahul.verma@example.com',  ARRAY[20,21,19,20,21,20], 50);
    PERFORM pg_temp.usage(yt_karthik, 'karthik.nair@example.com', ARRAY[15,16,15,14,16,15], 40);
    PERFORM pg_temp.usage(yt_aditya,  'aditya.rao@example.com',   ARRAY[25,24,25,26,24,25], 60);

    -- Karthik's Spotify Duo has a free slot; Aditya pays for his own Spotify
    duo := pg_temp.sub('karthik.nair@example.com', 'Spotify', 'Duo', 240);
    PERFORM pg_temp.usage(duo, 'karthik.nair@example.com', ARRAY[18,17,18,19,17,18], 40);
    sp_aditya := pg_temp.sub('aditya.rao@example.com', 'Spotify', 'Individual', 200);
    PERFORM pg_temp.usage(sp_aditya, 'aditya.rao@example.com', ARRAY[22,21,23,22,21,22], 45);

    -- Rahul pays for Apple Music + iCloud+ + Apple TV+ separately -> Apple One
    am := pg_temp.sub('rahul.verma@example.com', 'Apple Music', 'Individual', 400);
    ic := pg_temp.sub('rahul.verma@example.com', 'iCloud+',     '50 GB',      500);
    tv := pg_temp.sub('rahul.verma@example.com', 'Apple TV+',   'Monthly',    200);
    PERFORM pg_temp.usage(am, 'rahul.verma@example.com', ARRAY[12,13,12,11,13,12], 35);
    PERFORM pg_temp.usage(tv, 'rahul.verma@example.com', ARRAY[4,5,4,5,4,5], 80);

    -- Netflix + JioHotstar on top of everything; Aditya's JioHotstar is dying off
    nf := pg_temp.sub('karthik.nair@example.com', 'Netflix', 'Mobile', 330);
    PERFORM pg_temp.usage(nf, 'karthik.nair@example.com', ARRAY[9,10,9,10,9,10], 70);
    hs := pg_temp.sub('aditya.rao@example.com', 'JioHotstar', 'Mobile', 260);
    PERFORM pg_temp.usage(hs, 'aditya.rao@example.com', ARRAY[1,2,3,5,7,9], 60);
END $$;

-- ---------------------------------------------------------------------------
-- Iyer Residence
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    jio INT; nf INT; sp_a INT; sp_v INT; li INT; go INT; au INT; pr INT;
BEGIN
    -- Jio postpaid for both (includes Netflix Basic, Amazon Prime, JioHotstar)
    jio := pg_temp.sub('vikram.iyer@example.com', 'Jio Postpaid', 'Plus 699', 500);
    PERFORM pg_temp.share(jio, 'ananya.iyer@example.com');

    -- Ananya pays for Netflix Basic on top of it -> hidden duplicate
    nf := pg_temp.sub('ananya.iyer@example.com', 'Netflix', 'Basic', 420);
    PERFORM pg_temp.usage(nf, 'ananya.iyer@example.com', ARRAY[10,11,10,9,11,10], 80);

    -- two individual Spotify plans -> Duo is the cheapest fix (not Family)
    sp_a := pg_temp.sub('ananya.iyer@example.com', 'Spotify', 'Individual', 380);
    sp_v := pg_temp.sub('vikram.iyer@example.com', 'Spotify', 'Individual', 360);
    PERFORM pg_temp.usage(sp_a, 'ananya.iyer@example.com', ARRAY[16,15,17,16,15,16], 40);
    PERFORM pg_temp.usage(sp_v, 'vikram.iyer@example.com', ARRAY[8,9,8,7,9,8], 30);

    -- LinkedIn Premium, never opened -> waste
    li := pg_temp.sub('vikram.iyer@example.com', 'LinkedIn Premium', 'Career', 120);

    -- shared Google One (passive category, so no waste flag) and a steady Audible
    go := pg_temp.sub('ananya.iyer@example.com', 'Google One', '100 GB', 600);
    PERFORM pg_temp.share(go, 'vikram.iyer@example.com');
    au := pg_temp.sub('ananya.iyer@example.com', 'Audible', 'Monthly', 300);
    PERFORM pg_temp.usage(au, 'ananya.iyer@example.com', ARRAY[6,5,6,7,5,6], 45);

    -- cancelled Amazon Prime: would be a hidden duplicate if active, so it must
    -- produce no alerts at all
    pr := pg_temp.sub('vikram.iyer@example.com', 'Amazon Prime', 'Monthly', 200);
    PERFORM pg_temp.usage(pr, 'vikram.iyer@example.com', ARRAY[0,1,3,4,4,5], 30);
    UPDATE subscriptions SET status = 'cancelled', end_date = CURRENT_DATE - 15 WHERE subscription_id = pr;
END $$;

-- ---------------------------------------------------------------------------
-- merchant aliases for bank statement import (regex on the cleaned-up,
-- upper-case description — see normalize_merchant() in detection.sql)
-- ---------------------------------------------------------------------------
INSERT INTO merchant_aliases (pattern, service_id)
SELECT v.pattern, s.service_id
FROM (VALUES
    ('NETFLIX',                     'Netflix'),
    ('HOTSTAR',                     'JioHotstar'),
    ('PRIME ?VIDEO',                'Prime Video'),
    ('AMAZON PRIME',                'Amazon Prime'),
    ('YOUTUBE ?PREMIUM',            'YouTube Premium'),
    ('YOUTUBE ?MUSIC',              'YouTube Music'),
    ('SPOTIFY',                     'Spotify'),
    ('APPLE COM BILL|ITUNES',       'Apple Music'),
    ('APPLE COM BILL|ITUNES',       'Apple TV+'),
    ('APPLE COM BILL|ITUNES',       'iCloud+'),
    ('APPLE COM BILL|ITUNES',       'Apple One'),
    ('AUDIBLE',                     'Audible'),
    ('LINKEDIN',                    'LinkedIn Premium'),
    ('GOOGLE ONE|GOOGLE STORAGE',   'Google One'),
    ('AIRTEL',                      'Airtel Postpaid'),
    ('JIO POSTPAID|RELIANCE JIO',   'Jio Postpaid')
) AS v(pattern, service)
JOIN services s ON s.name = v.service;
