const express = require('express');
const { pool } = require('../db');
const { optimize } = require('../optimizer');

const router = express.Router();

// Compute and store an optimizer run for one household, in one transaction:
//   BEGIN → household lock → refresh needs and findings → load input → search
//   → store run, steps and finding outcomes → COMMIT
// Refreshing first means the run's state_hash matches the household as it is,
// so the run can be applied straight away.
async function createRun(householdId) {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const hh = await client.query('SELECT 1 FROM households WHERE household_id = $1', [householdId]);
        if (!hh.rows.length) {
            await client.query('ROLLBACK');
            return null;
        }
        await client.query('SELECT lock_household($1)', [householdId]);
        await client.query('CALL refresh_alerts($1)', [householdId]);
        const { rows: [{ input, hash }] } = await client.query(
            'SELECT optimizer_input($1) AS input, optimizer_state_hash($1) AS hash', [householdId]);

        const result = optimize(input);

        const { rows: [run] } = await client.query(
            `INSERT INTO optimization_runs (household_id, kind, evaluated_on, cost_before, cost_after,
                                            is_optimal, elapsed_ms, state_hash)
             VALUES ($1, 'optimize', $2, $3, $4, $5, $6, $7)
             RETURNING run_id, status, created_at`,
            [householdId, input.evaluated_on, result.cost_before, result.cost_after,
             result.is_optimal, result.elapsed_ms, hash]);
        for (const s of result.steps) {
            await client.query(
                `INSERT INTO optimization_steps (run_id, step_no, action, subscription_id, plan_id, payer_id,
                                                 user_ids, saving, description, reason, reason_path)
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
                [run.run_id, s.step_no, s.action, s.subscription_id, s.plan_id, s.payer_id,
                 s.user_ids, s.saving, s.description, s.reason, s.reason_path]);
        }
        for (const o of result.outcomes) {
            await client.query(
                `INSERT INTO optimization_alert_outcomes (run_id, alert_id, outcome, alert_saving, note)
                 VALUES ($1, $2, $3, $4, $5)`,
                [run.run_id, o.alert_id, o.outcome, o.alert_saving, o.note]);
        }
        await client.query('COMMIT');      // the deferred trigger checks the steps add up here
        return run.run_id;
    } catch (err) {
        await client.query('ROLLBACK');
        throw err;
    } finally {
        client.release();
    }
}

// a stored run with its steps (reason paths as text) and finding outcomes
async function readRun(runId) {
    const run = await pool.query(`SELECT * FROM optimization_runs WHERE run_id = $1`, [runId]);
    if (!run.rows.length) return null;
    const steps = await pool.query(
        `SELECT step_no, action, subscription_id, plan_id, payer_id, user_ids, saving,
                description, reason, reason_path, path_label(reason_path) AS reason_label
         FROM optimization_steps WHERE run_id = $1 ORDER BY step_no`, [runId]);
    const outcomes = await pool.query(
        `SELECT o.alert_id, a.alert_type, a.fingerprint, o.outcome, o.alert_saving, o.note, a.message
         FROM optimization_alert_outcomes o JOIN alerts a ON a.alert_id = o.alert_id
         WHERE o.run_id = $1 ORDER BY o.outcome, o.alert_id`, [runId]);
    const r = run.rows[0];
    return {
        ...r,
        monthly_saving: Math.round((Number(r.cost_before) - Number(r.cost_after)) * 100) / 100,
        steps: steps.rows,
        finding_outcomes: outcomes.rows,
    };
}

// Preview and apply share one code path, like fixes do (alerts.js runFix):
// BEGIN → household lock → apply_optimization() → read totals → ROLLBACK or COMMIT.
// A stale run (the household changed since it was computed) is marked stale
// and committed even on preview, since nothing else was changed.
async function runOptimization(runId, commit) {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const r = await client.query(`SELECT household_id FROM optimization_runs WHERE run_id = $1`, [runId]);
        if (!r.rows.length) {
            await client.query('ROLLBACK');
            return null;
        }
        const hid = r.rows[0].household_id;
        await client.query('SELECT lock_household($1)', [hid]);
        const spend = async () => Number((await client.query(
            `SELECT COALESCE(SUM(monthly_price), 0) AS spend FROM v_subscription_detail
             WHERE household_id = $1 AND status = 'active'`, [hid])).rows[0].spend);

        const before = await spend();
        const { rows: [{ steps }] } = await client.query(`SELECT apply_optimization($1) AS steps`, [runId]);
        if (steps === null) {
            await client.query('COMMIT');
            return { stale: true };
        }
        const after = await spend();
        await client.query(commit ? 'COMMIT' : 'ROLLBACK');
        return {
            applied: commit,
            steps,
            spend_before: before,
            spend_after: after,
            monthly_saving: Math.round((before - after) * 100) / 100,
        };
    } catch (err) {
        await client.query('ROLLBACK');
        throw err;
    } finally {
        client.release();
    }
}

const STALE = { error: 'The household has changed since this run was computed. Run the optimizer again.' };

// POST /api/households/:id/optimize — compute the cheapest configuration
router.post('/households/:id/optimize', async (req, res, next) => {
    try {
        const runId = await createRun(req.params.id);
        if (!runId) return res.status(404).json({ error: 'Household not found' });
        res.status(201).json(await readRun(runId));
    } catch (err) { next(err); }
});

// GET /api/optimization-runs/:id
router.get('/optimization-runs/:id', async (req, res, next) => {
    try {
        const run = await readRun(req.params.id);
        if (!run) return res.status(404).json({ error: 'Optimizer run not found' });
        res.json(run);
    } catch (err) { next(err); }
});

// POST /api/optimization-runs/:id/preview — what would change (nothing is saved)
// POST /api/optimization-runs/:id/apply   — do it, all steps or none
for (const [action, commit] of [['preview', false], ['apply', true]]) {
    router.post(`/optimization-runs/:id/${action}`, async (req, res, next) => {
        try {
            const result = await runOptimization(req.params.id, commit);
            if (!result) return res.status(404).json({ error: 'Optimizer run not found' });
            if (result.stale) return res.status(409).json(STALE);
            res.json(result);
        } catch (err) { next(err); }
    });
}

module.exports = router;
