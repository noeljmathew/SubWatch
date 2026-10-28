const express = require('express');
const { pool, withHousehold } = require('../db');

const router = express.Router();

// GET /api/households/:id/alerts?status=open
router.get('/households/:id/alerts', async (req, res, next) => {
    try {
        const { rows } = await pool.query(
            `SELECT a.*, sv.name AS recommended_service, p.name AS recommended_plan,
                    COALESCE((SELECT array_agg(x.subscription_id ORDER BY x.subscription_id)
                              FROM alert_subscriptions x
                              WHERE x.alert_id = a.alert_id AND x.role = 'subject'), '{}') AS subject_ids,
                    COALESCE((SELECT array_agg(x.subscription_id ORDER BY x.subscription_id)
                              FROM alert_subscriptions x
                              WHERE x.alert_id = a.alert_id AND x.role = 'source'), '{}') AS source_ids,
                    COALESCE((SELECT json_agg(json_build_object(
                                  'subscription_id', r.subscription_id, 'role', r.role,
                                  'reason_path', r.reason_path, 'reason_label', r.reason_label,
                                  'member_ids', r.member_ids, 'member_names', r.member_names)
                              ORDER BY r.role DESC, r.subscription_id)
                              FROM v_alert_reasons r WHERE r.alert_id = a.alert_id), '[]') AS reasons
             FROM alerts a
             LEFT JOIN plans p     ON p.plan_id = a.recommended_plan_id
             LEFT JOIN services sv ON sv.service_id = p.service_id
             WHERE a.household_id = $1 AND a.status = $2
             ORDER BY a.potential_monthly_savings DESC NULLS LAST, a.alert_id`,
            [req.params.id, req.query.status || 'open']
        );
        res.json(rows);
    } catch (err) { next(err); }
});

// POST /api/households/:id/alerts/refresh — re-run the optimizer
router.post('/households/:id/alerts/refresh', async (req, res, next) => {
    try {
        await withHousehold(req.params.id, async () => {});
        const { rows } = await pool.query(
            `SELECT COUNT(*)::int AS open FROM alerts WHERE household_id = $1 AND status = 'open'`,
            [req.params.id]
        );
        res.json(rows[0]);
    } catch (err) { next(err); }
});

// Preview and apply share the same code path. Both run apply_alert() inside a
// transaction and measure the household before and after; preview then rolls
// everything back, apply commits it.
async function runFix(alertId, commit) {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const a = await client.query(`SELECT household_id FROM alerts WHERE alert_id = $1`, [alertId]);
        if (!a.rows.length) {
            await client.query('ROLLBACK');
            return null;
        }
        const hid = a.rows[0].household_id;
        await client.query('SELECT lock_household($1)', [hid]);   // same lock order as every other change
        const snapshot = async () => {
            const spend = await client.query(
                `SELECT COALESCE(SUM(monthly_price), 0) AS spend FROM v_subscription_detail
                 WHERE household_id = $1 AND status = 'active'`, [hid]);
            const open = await client.query(
                `SELECT alert_id, alert_type, message FROM alerts WHERE household_id = $1 AND status = 'open'`, [hid]);
            return { spend: Number(spend.rows[0].spend), open: open.rows };
        };

        const before = await snapshot();
        const { rows } = await client.query(`SELECT apply_alert($1) AS steps`, [alertId]);
        const after = await snapshot();
        await client.query(commit ? 'COMMIT' : 'ROLLBACK');

        const beforeIds = new Set(before.open.map(x => x.alert_id));
        return {
            applied: commit,
            steps: rows[0].steps,
            spend_before: before.spend,
            spend_after: after.spend,
            monthly_saving: Math.round((before.spend - after.spend) * 100) / 100,
            open_before: before.open.length,
            open_after: after.open.length,
            new_findings: after.open.filter(x => !beforeIds.has(x.alert_id)),
        };
    } catch (err) {
        await client.query('ROLLBACK');
        throw err;
    } finally {
        client.release();
    }
}

// POST /api/alerts/:id/preview — what would change (nothing is saved)
router.post('/alerts/:id/preview', async (req, res, next) => {
    try {
        const result = await runFix(req.params.id, false);
        if (!result) return res.status(404).json({ error: 'Finding not found' });
        res.json(result);
    } catch (err) { next(err); }
});

// POST /api/alerts/:id/apply — do it for real
router.post('/alerts/:id/apply', async (req, res, next) => {
    try {
        const result = await runFix(req.params.id, true);
        if (!result) return res.status(404).json({ error: 'Finding not found' });
        res.json(result);
    } catch (err) { next(err); }
});

// PATCH /api/alerts/:id — { status: 'open' | 'dismissed' | 'resolved' }
router.patch('/alerts/:id', async (req, res, next) => {
    const { status } = req.body;
    if (!['open', 'dismissed', 'resolved'].includes(status)) {
        return res.status(400).json({ error: "status must be 'open', 'dismissed' or 'resolved'" });
    }
    try {
        const { rows } = await pool.query(
            `UPDATE alerts SET status = $2 WHERE alert_id = $1 RETURNING *`,
            [req.params.id, status]
        );
        if (!rows.length) return res.status(404).json({ error: 'Alert not found' });
        res.json(rows[0]);
    } catch (err) { next(err); }
});

module.exports = router;
