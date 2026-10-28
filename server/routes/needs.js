const express = require('express');
const { pool, withHousehold } = require('../db');

const router = express.Router();

class NotFound extends Error {}

function handle(res, next, err) {
    if (err instanceof NotFound) return res.status(404).json({ error: err.message });
    next(err);
}

// the person must belong to this household
async function checkMember(client, householdId, userId) {
    const { rows } = await client.query(
        `SELECT 1 FROM household_members WHERE household_id = $1 AND user_id = $2`,
        [householdId, userId]
    );
    if (!rows.length) throw new NotFound('That person is not in this household');
}

// GET /api/households/:id/needs — every need (and every "not needed"
// override) with whether it is covered today and the shortest path covering it
router.get('/households/:id/needs', async (req, res, next) => {
    try {
        const { rows } = await pool.query(
            `SELECT n.user_id, u.full_name, n.service_id, s.name AS service_name,
                    n.source, n.is_needed, n.last_evidence_at,
                    COALESCE(nc.covered, false) AS covered,
                    nc.via_subscription_id, nc.depth, nc.path, nc.path_label
             FROM member_needs n
             JOIN household_members hm   ON hm.user_id = n.user_id
             JOIN users u                ON u.user_id = n.user_id
             JOIN services s             ON s.service_id = n.service_id
             LEFT JOIN v_need_coverage nc ON nc.user_id = n.user_id AND nc.service_id = n.service_id
             WHERE hm.household_id = $1
             ORDER BY u.full_name, s.name`,
            [req.params.id]
        );
        res.json(rows);
    } catch (err) { next(err); }
});

// POST /api/households/:id/needs — { user_id, service_id }: they need it
router.post('/households/:id/needs', async (req, res, next) => {
    const { user_id, service_id } = req.body;
    if (!user_id || !service_id) {
        return res.status(400).json({ error: 'user_id and service_id are required' });
    }
    try {
        await withHousehold(req.params.id, async (client) => {
            await checkMember(client, req.params.id, user_id);
            await client.query('SELECT set_member_need($1, $2, true)', [user_id, service_id]);
        });
        res.status(201).json({ user_id, service_id, source: 'manual', is_needed: true });
    } catch (err) { handle(res, next, err); }
});

// DELETE /api/households/:id/needs/:userId/:serviceId — they don't need it
// (stays that way after refreshes). ?reset=1 removes the override instead and
// goes back to what the usage data says.
router.delete('/households/:id/needs/:userId/:serviceId', async (req, res, next) => {
    const { userId, serviceId } = req.params;
    const reset = req.query.reset === '1' || req.query.reset === 'true';
    try {
        await withHousehold(req.params.id, async (client) => {
            await checkMember(client, req.params.id, userId);
            await client.query('SELECT set_member_need($1, $2, $3)', [userId, serviceId, reset ? null : false]);
        });
        res.status(204).end();
    } catch (err) { handle(res, next, err); }
});

module.exports = router;
