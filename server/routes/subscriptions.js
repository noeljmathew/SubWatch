const express = require('express');
const { pool, withHousehold, householdOfSubscription } = require('../db');

const router = express.Router();

class NotFound extends Error {}

// run a change to an existing subscription inside its household's transaction
async function onSubscription(subscriptionId, fn) {
    const hid = await householdOfSubscription(subscriptionId);
    if (!hid) throw new NotFound('Subscription not found');
    return withHousehold(hid, fn);
}

function handle(res, next, err) {
    if (err instanceof NotFound) return res.status(404).json({ error: err.message });
    next(err);
}

// GET /api/households/:id/subscriptions — with members and a 6-window usage trend
router.get('/households/:id/subscriptions', async (req, res, next) => {
    try {
        const { rows } = await pool.query(
            `SELECT d.*,
                    COALESCE((SELECT json_agg(json_build_object('user_id', u.user_id, 'full_name', u.full_name)
                                              ORDER BY (u.user_id = d.payer_id) DESC, u.full_name)
                              FROM subscription_members sm JOIN users u ON u.user_id = sm.user_id
                              WHERE sm.subscription_id = d.subscription_id), '[]') AS members,
                    COALESCE((SELECT array_agg(b.sessions ORDER BY b.x)
                              FROM v_usage_buckets b WHERE b.subscription_id = d.subscription_id), '{}') AS trend
             FROM v_subscription_detail d
             WHERE d.household_id = $1
             ORDER BY (d.status = 'active') DESC, d.monthly_price DESC`,
            [req.params.id]
        );
        res.json(rows);
    } catch (err) { next(err); }
});

// POST /api/households/:id/subscriptions — { payer_id, plan_id, start_date, member_ids[] }
// One transaction: if a trigger rejects any member (capacity, wrong household),
// the whole subscription is rolled back.
router.post('/households/:id/subscriptions', async (req, res, next) => {
    const { payer_id, plan_id, start_date, member_ids = [] } = req.body;
    if (!payer_id || !plan_id || !start_date) {
        return res.status(400).json({ error: 'payer_id, plan_id and start_date are required' });
    }
    try {
        const sub = await withHousehold(req.params.id, async (client) => {
            const { rows } = await client.query(
                `INSERT INTO subscriptions (payer_id, plan_id, start_date) VALUES ($1, $2, $3) RETURNING *`,
                [payer_id, plan_id, start_date]
            );
            for (const uid of member_ids) {
                if (Number(uid) === Number(payer_id)) continue;
                await client.query(
                    `INSERT INTO subscription_members (subscription_id, user_id) VALUES ($1, $2)`,
                    [rows[0].subscription_id, uid]
                );
            }
            return rows[0];
        });
        res.status(201).json(sub);
    } catch (err) { handle(res, next, err); }
});

// PATCH /api/subscriptions/:id — { status: 'active' | 'paused' | 'cancelled' }
router.patch('/subscriptions/:id', async (req, res, next) => {
    const { status } = req.body;
    if (!['active', 'paused', 'cancelled'].includes(status)) {
        return res.status(400).json({ error: "status must be 'active', 'paused' or 'cancelled'" });
    }
    try {
        const sub = await onSubscription(req.params.id, async (client) => {
            const { rows } = await client.query(
                `UPDATE subscriptions
                    SET status = $2,
                        end_date = CASE WHEN $3 THEN GREATEST(CURRENT_DATE, start_date) ELSE NULL END
                  WHERE subscription_id = $1
                  RETURNING *`,
                [req.params.id, status, status === 'cancelled']
            );
            return rows[0];
        });
        res.json(sub);
    } catch (err) { handle(res, next, err); }
});

// POST /api/subscriptions/:id/members — { user_id }
router.post('/subscriptions/:id/members', async (req, res, next) => {
    try {
        await onSubscription(req.params.id, (client) => client.query(
            `INSERT INTO subscription_members (subscription_id, user_id) VALUES ($1, $2)`,
            [req.params.id, req.body.user_id]
        ));
        res.status(201).json({ ok: true });
    } catch (err) { handle(res, next, err); }
});

// DELETE /api/subscriptions/:id/members/:userId
router.delete('/subscriptions/:id/members/:userId', async (req, res, next) => {
    try {
        await onSubscription(req.params.id, async (client) => {
            const { rowCount } = await client.query(
                `DELETE FROM subscription_members WHERE subscription_id = $1 AND user_id = $2`,
                [req.params.id, req.params.userId]
            );
            if (!rowCount) throw new NotFound('Not a member of this subscription');
        });
        res.status(204).end();
    } catch (err) { handle(res, next, err); }
});

// POST /api/subscriptions/:id/usage — { user_id, duration_minutes }
router.post('/subscriptions/:id/usage', async (req, res, next) => {
    const { user_id, duration_minutes } = req.body;
    try {
        const row = await onSubscription(req.params.id, async (client) => {
            const { rows } = await client.query(
                `INSERT INTO usage_logs (subscription_id, user_id, duration_minutes)
                 VALUES ($1, $2, $3) RETURNING *`,
                [req.params.id, user_id, duration_minutes || 30]
            );
            return rows[0];
        });
        res.status(201).json(row);
    } catch (err) { handle(res, next, err); }
});

module.exports = router;
