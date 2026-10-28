const express = require('express');
const { pool } = require('../db');

const router = express.Router();

// GET /api/plans — purchasable plans for the "add subscription" form
router.get('/plans', async (req, res, next) => {
    try {
        const { rows } = await pool.query(
            `SELECT p.plan_id, p.service_id, p.name AS plan_name, p.tier, p.price, p.billing_cycle,
                    p.monthly_price, p.max_members, s.name AS service_name, c.name AS category_name
             FROM plans p
             JOIN services s   ON s.service_id = p.service_id
             JOIN categories c ON c.category_id = s.category_id
             WHERE p.is_purchasable
             ORDER BY c.name, s.name, p.monthly_price`
        );
        res.json(rows);
    } catch (err) { next(err); }
});

module.exports = router;
