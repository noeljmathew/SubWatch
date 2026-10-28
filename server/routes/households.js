const express = require('express');
const { pool } = require('../db');

const router = express.Router();

// GET /api/households
router.get('/', async (req, res, next) => {
    try {
        const { rows } = await pool.query(
            `SELECT h.household_id, h.name, h.monthly_budget, COUNT(hm.user_id)::int AS member_count
             FROM households h
             LEFT JOIN household_members hm ON hm.household_id = h.household_id
             GROUP BY h.household_id
             ORDER BY h.household_id`
        );
        res.json(rows);
    } catch (err) { next(err); }
});

// GET /api/households/:id/members
router.get('/:id/members', async (req, res, next) => {
    try {
        const { rows } = await pool.query(
            `SELECT user_id, full_name, role,
                    ROUND(pays, 2) AS pays, ROUND(fair_cost, 2) AS fair_cost,
                    ROUND(pays - fair_cost, 2) AS net
             FROM v_member_costs
             WHERE household_id = $1
             ORDER BY role DESC, full_name`,
            [req.params.id]
        );
        res.json(rows);
    } catch (err) { next(err); }
});

// GET /api/households/:id/summary
router.get('/:id/summary', async (req, res, next) => {
    const id = req.params.id;
    try {
        const hh = await pool.query(`SELECT household_id, name, monthly_budget FROM households WHERE household_id = $1`, [id]);
        if (!hh.rows.length) return res.status(404).json({ error: 'Household not found' });

        const spend = await pool.query(
            `SELECT COUNT(*)::int AS active_subscriptions,
                    COALESCE(SUM(monthly_price), 0) AS monthly_spend
             FROM v_subscription_detail
             WHERE household_id = $1 AND status = 'active'`,
            [id]
        );
        const byCategory = await pool.query(
            `SELECT category_name, SUM(monthly_price) AS spend
             FROM v_subscription_detail
             WHERE household_id = $1 AND status = 'active'
             GROUP BY category_name
             ORDER BY spend DESC`,
            [id]
        );
        const alerts = await pool.query(
            `SELECT alert_type, confidence, COUNT(*)::int AS count, COALESCE(SUM(potential_monthly_savings), 0) AS savings
             FROM alerts
             WHERE household_id = $1 AND status = 'open'
             GROUP BY alert_type, confidence`,
            [id]
        );
        // FR-41: only High and Medium concrete findings count; Low ones are
        // "worth a look" (v_household_savings holds the same rule in SQL)
        const totals = await pool.query(
            `SELECT savings_found, worth_a_look, low_confidence_findings FROM v_household_savings WHERE household_id = $1`,
            [id]
        );

        const monthlySpend = Number(spend.rows[0].monthly_spend);
        const savings = Number(totals.rows[0].savings_found);
        const efficiency = monthlySpend > 0 ? Math.round(100 * (1 - savings / monthlySpend)) : 100;

        res.json({
            household: hh.rows[0],
            active_subscriptions: spend.rows[0].active_subscriptions,
            monthly_spend: monthlySpend,
            savings_found: Math.round(savings * 100) / 100,
            worth_a_look: Math.round(Number(totals.rows[0].worth_a_look) * 100) / 100,
            low_confidence_findings: totals.rows[0].low_confidence_findings,
            efficiency_score: efficiency,
            spend_by_category: byCategory.rows,
            alert_counts: alerts.rows,
        });
    } catch (err) { next(err); }
});

module.exports = router;
