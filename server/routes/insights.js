const express = require('express');
const { pool } = require('../db');

const router = express.Router();

// GET /api/households/:id/fair-share — usage-weighted split of each shared plan
router.get('/households/:id/fair-share', async (req, res, next) => {
    try {
        const { rows } = await pool.query(
            `SELECT subscription_id, service_name, plan_name, payer_id, payer_name, monthly_price,
                    json_agg(json_build_object('user_id', user_id, 'full_name', full_name,
                                               'minutes_30d', minutes_30d, 'fair_share', fair_share)
                             ORDER BY fair_share DESC) AS shares
             FROM v_fair_share
             WHERE household_id = $1
             GROUP BY subscription_id, service_name, plan_name, payer_id, payer_name, monthly_price
             ORDER BY monthly_price DESC`,
            [req.params.id]
        );
        res.json(rows);
    } catch (err) { next(err); }
});

// GET /api/households/:id/settle-up — net monthly transfers between members
router.get('/households/:id/settle-up', async (req, res, next) => {
    try {
        const { rows } = await pool.query(
            `SELECT from_user_id, from_name, to_user_id, to_name, amount
             FROM v_settle_up WHERE household_id = $1 ORDER BY amount DESC`,
            [req.params.id]
        );
        res.json(rows);
    } catch (err) { next(err); }
});

// GET /api/households/:id/forecast?days=30 — upcoming charges
router.get('/households/:id/forecast', async (req, res, next) => {
    const days = Math.min(Math.max(parseInt(req.query.days, 10) || 30, 1), 365);
    try {
        const { rows } = await pool.query(`SELECT * FROM renewal_forecast($1, $2)`, [req.params.id, days]);
        res.json(rows);
    } catch (err) { next(err); }
});

// GET /api/households/:id/spend?date=YYYY-MM-DD — monthly spend on that date,
// at the prices valid then (default: today)
router.get('/households/:id/spend', async (req, res, next) => {
    const date = req.query.date || null;
    if (date && !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
        return res.status(400).json({ error: 'date must be YYYY-MM-DD' });
    }
    try {
        const { rows } = await pool.query(
            `SELECT COALESCE($2::date, CURRENT_DATE)::text AS date,   -- text: no timezone shift in JSON
                    household_spend_at($1, COALESCE($2::date, CURRENT_DATE)) AS monthly_spend`,
            [req.params.id, date]
        );
        res.json(rows[0]);
    } catch (err) { next(err); }
});

// GET /api/households/:id/entitlements — everything the household unlocks
// indirectly, with the path through the entitlement graph
router.get('/households/:id/entitlements', async (req, res, next) => {
    try {
        const { rows } = await pool.query(
            `SELECT d.subscription_id, d.service_name AS via_service, d.plan_name AS via_plan,
                    d.payer_name, d.member_names, cl.depth, cl.path_label,
                    s.name AS unlocked_service,
                    EXISTS (SELECT 1 FROM v_hidden_duplicates hd
                            WHERE hd.via_subscription_id = d.subscription_id
                              AND hd.service_name = s.name) AS also_paid_separately
             FROM v_subscription_detail d
             JOIN v_entitlement_closure cl ON cl.root_plan_id = d.plan_id
             JOIN services s ON s.service_id = cl.included_service_id
             WHERE d.household_id = $1 AND d.status = 'active'
             ORDER BY d.subscription_id, cl.depth, s.name`,
            [req.params.id]
        );
        res.json(rows);
    } catch (err) { next(err); }
});

module.exports = router;
