const express = require('express');
const { pool } = require('../db');

const router = express.Router();

// how each service shows up on a bank statement (sample generator only)
const DESCRIPTORS = {
    'Netflix':          () => 'NETFLIX.COM MUMBAI IN',
    'JioHotstar':       () => 'JIOHOTSTAR MUMBAI',
    'Prime Video':      () => 'AMAZON PRIME VIDEO',
    'Amazon Prime':     () => 'AMAZON PRIME MEMBERSHIP',
    'YouTube Premium':  () => 'GOOGLE *YouTubePremium',
    'YouTube Music':    () => 'GOOGLE *YouTube Music',
    'Spotify':          (ref) => `SPOTIFY P${ref} STOCKHOLM`,
    'Apple Music':      () => 'APPLE.COM/BILL',
    'Apple TV+':        () => 'APPLE.COM/BILL',
    'iCloud+':          () => 'APPLE.COM/BILL',
    'Apple One':        () => 'APPLE.COM/BILL',
    'Audible':          () => 'AUDIBLE INDIA',
    'LinkedIn Premium': (ref) => `LINKEDIN PREMIUM ${ref}`,
    'Google One':       () => 'GOOGLE *Google One',
    'Airtel Postpaid':  (ref) => `AIRTEL POSTPAID BILL ${ref}`,
    'Jio Postpaid':     (ref) => `JIO POSTPAID BILL ${ref}`,
};

// small deterministic PRNG so the same person always gets the same sample
function rng(seed) {
    let a = seed >>> 0;
    return () => {
        a = (a + 0x6D2B79F5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

const iso = (d) => d.toISOString().slice(0, 10);
const addDays = (d, n) => { const x = new Date(d); x.setUTCDate(x.getUTCDate() + n); return x; };
const addMonths = (d, n) => {
    const x = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + n, 1));
    const last = new Date(Date.UTC(x.getUTCFullYear(), x.getUTCMonth() + 1, 0)).getUTCDate();
    x.setUTCDate(Math.min(d.getUTCDate(), last));
    return x;
};

// monthly charges on a fixed day, going back `months` months from `anchor`
function monthly(anchor, months, amount, description, from) {
    const out = [];
    for (let k = 0; k < months; k++) {
        const d = addMonths(anchor, -k);
        if (d >= from) out.push({ date: iso(d), description, amount });
    }
    return out;
}

// GET /api/households/:id/sample-statement?user_id=  — a realistic 6-month CSV
// built from that person's active subscriptions, plus a few charges SubWatch
// doesn't know about, plus everyday spending noise
router.get('/households/:id/sample-statement', async (req, res, next) => {
    const userId = Number(req.query.user_id);
    try {
        const u = await pool.query(
            `SELECT u.user_id, u.email, u.full_name, CURRENT_DATE::text AS today
             FROM users u JOIN household_members hm ON hm.user_id = u.user_id
             WHERE u.user_id = $1 AND hm.household_id = $2`,
            [userId, req.params.id]
        );
        if (!u.rows.length) return res.status(404).json({ error: 'That person is not in this household' });
        const { email, full_name, today: todayStr } = u.rows[0];
        const today = new Date(todayStr + 'T00:00:00Z');
        const from = addDays(today, -180);
        const rand = rng(userId * 7919);
        const ref = () => Math.floor(1000000 + rand() * 8999999).toString(16).toUpperCase();
        const rows = [];

        // 1. charges for everything they currently pay for (same dates the forecast uses)
        const charges = await pool.query(
            `SELECT d.service_name, d.price, r.dt::text AS dt
             FROM v_subscription_detail d
             CROSS JOIN LATERAL (SELECT CASE d.billing_cycle
                                          WHEN 'weekly' THEN interval '1 week' WHEN 'monthly' THEN interval '1 month'
                                          WHEN 'quarterly' THEN interval '3 months' ELSE interval '1 year' END AS step) c
             CROSS JOIN LATERAL generate_series(0, 600) AS g(n)
             CROSS JOIN LATERAL (SELECT (d.start_date + g.n * c.step)::date AS dt) r
             WHERE d.payer_id = $1 AND d.status = 'active'
               AND r.dt BETWEEN CURRENT_DATE - 180 AND CURRENT_DATE`,
            [userId]
        );
        for (const c of charges.rows) {
            const posted = addDays(new Date(c.dt + 'T00:00:00Z'), rand() < 0.3 ? 1 : 0); // bank posting delay
            if (posted > today) continue;
            const desc = (DESCRIPTORS[c.service_name] || (() => c.service_name.toUpperCase()))(ref());
            rows.push({ date: iso(posted), description: desc, amount: Number(c.price) });
        }

        // 2. things SubWatch doesn't know about yet (scripted for the demo people)
        if (email === 'priya.sharma@example.com') {
            rows.push(...monthly(addDays(today, -6), 6, 199, 'NETFLIX.COM MUMBAI IN', from));          // forgotten 2nd Netflix
            rows.push(...monthly(addDays(today, -15), 6, 1099, 'CULT.FIT BANGALORE', from));           // not in catalog
        } else if (email === 'vikram.iyer@example.com') {
            rows.push(...monthly(addDays(today, -9), 6, 149, 'GOOGLE *YouTubePremium', from));       // untracked
            rows.push(...monthly(addDays(today, -5), 6, 299, 'AMAZON PRIME MEMBERSHIP', from));      // "cancelled" but still billed
            rows.push(...monthly(addDays(today, -7), 6, 18000,
                `UPI/DR/${Math.floor(rand() * 1e9)}/LANDLORD RENT/HDFC/raj@okhdfc`, from));            // rent
        } else {
            rows.push(...monthly(addDays(today, -12), 6, 1500, "GOLD'S GYM KORAMANGALA", from));
        }

        // 3. everyday noise: varying amounts, irregular days
        const noise = [
            ['SWIGGY BANGALORE', 14, 120, 850], ['UBER INDIA', 10, 90, 600], ['ZEPTO MARKETPLACE', 8, 80, 1200],
            ['AMAZON PAY INDIA', 4, 300, 4500], ['MYNTRA DESIGNS', 2, 600, 3200],
        ];
        for (const [name, n, lo, hi] of noise) {
            for (let i = 0; i < n; i++) {
                rows.push({
                    date: iso(addDays(from, Math.floor(rand() * 180))),
                    description: `POS ${Math.floor(1000 + rand() * 8999)}XXXX ${name}`,
                    amount: Math.round(lo + rand() * (hi - lo)),
                });
            }
        }
        for (let k = 0; k < 6; k++) { // electricity: monthly, but the amount changes every time
            rows.push({ date: iso(addMonths(addDays(today, -20), -k)), description: 'BESCOM ELECTRICITY BILL',
                        amount: Math.round(900 + rand() * 1500) });
        }

        rows.sort((a, b) => a.date.localeCompare(b.date));
        const csv = ['date,description,amount',
                     ...rows.map(r => `${r.date},"${r.description.replace(/"/g, '""')}",${r.amount.toFixed(2)}`)].join('\n');
        res.type('text/csv')
           .set('Content-Disposition', `attachment; filename="${full_name.split(' ')[0].toLowerCase()}-statement.csv"`)
           .send(csv + '\n');
    } catch (err) { next(err); }
});

// POST /api/households/:id/imports — { user_id, file_name, rows: [{date, description, amount}] }
router.post('/households/:id/imports', async (req, res, next) => {
    const { user_id, file_name, rows } = req.body;
    if (!user_id || !Array.isArray(rows) || rows.length === 0) {
        return res.status(400).json({ error: 'user_id and a non-empty rows array are required' });
    }
    if (rows.length > 10000) return res.status(400).json({ error: 'Statement too large (max 10,000 rows)' });
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const member = await client.query(
            `SELECT 1 FROM household_members WHERE user_id = $1 AND household_id = $2`, [user_id, req.params.id]);
        if (!member.rows.length) {
            await client.query('ROLLBACK');
            return res.status(400).json({ error: 'That person is not in this household' });
        }
        const imp = await client.query(
            `INSERT INTO statement_imports (user_id, file_name) VALUES ($1, $2) RETURNING import_id`,
            [user_id, file_name || 'statement.csv']
        );
        const importId = imp.rows[0].import_id;
        // one INSERT with three parallel arrays instead of thousands of round trips
        await client.query(
            `INSERT INTO bank_transactions (import_id, txn_date, description, amount)
             SELECT $1, d, t, a FROM unnest($2::date[], $3::text[], $4::numeric[]) AS x(d, t, a)
             WHERE a <> 0`,
            [importId, rows.map(r => r.date), rows.map(r => String(r.description)), rows.map(r => Number(r.amount))]
        );
        await client.query('COMMIT');
        res.status(201).json({ import_id: importId, transactions: rows.length });
    } catch (err) {
        await client.query('ROLLBACK');
        next(err);
    } finally {
        client.release();
    }
});

// GET /api/imports/:id/results
router.get('/imports/:id/results', async (req, res, next) => {
    try {
        const meta = await pool.query(
            `SELECT i.import_id, i.file_name, i.user_id, u.full_name,
                    (SELECT COUNT(*)::int FROM bank_transactions WHERE import_id = i.import_id) AS transactions,
                    (SELECT MIN(txn_date) FROM bank_transactions WHERE import_id = i.import_id) AS period_start,
                    (SELECT MAX(txn_date) FROM bank_transactions WHERE import_id = i.import_id) AS period_end
             FROM statement_imports i JOIN users u ON u.user_id = i.user_id
             WHERE i.import_id = $1`,
            [req.params.id]
        );
        if (!meta.rows.length) return res.status(404).json({ error: 'Import not found' });
        const { rows } = await pool.query(
            `SELECT r.*,
                    COALESCE((SELECT json_agg(json_build_object('plan_id', p.plan_id, 'service_name', s.name,
                                                                'plan_name', p.name, 'max_members', p.max_members)
                                              ORDER BY s.name, p.name)
                              FROM plans p JOIN services s ON s.service_id = p.service_id
                              WHERE p.plan_id = ANY (r.candidate_plan_ids)), '[]') AS candidates,
                    (SELECT string_agg(s.name, ' / ' ORDER BY s.name) FROM services s
                      WHERE s.service_id = ANY (r.service_ids)) AS service_names
             FROM v_import_results r
             WHERE r.import_id = $1
             ORDER BY CASE r.status WHEN 'still_charged' THEN 0 WHEN 'untracked' THEN 1 WHEN 'no_matching_plan' THEN 2
                                    WHEN 'not_in_catalog' THEN 3 WHEN 'cancelled' THEN 4 ELSE 5 END,
                      r.amount DESC`,
            [req.params.id]
        );
        res.json({ ...meta.rows[0], recurring: rows });
    } catch (err) { next(err); }
});

module.exports = router;
