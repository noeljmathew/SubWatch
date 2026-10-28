const express = require('express');
const { pool } = require('../db');
const { simulate, CHANGE_TYPES, BadChange } = require('../whatif');

const router = express.Router();

class NotFound extends Error {}

function handle(res, next, err) {
    if (err instanceof NotFound) return res.status(404).json({ error: err.message });
    if (err instanceof BadChange) return res.status(400).json({ error: err.message });
    next(err);
}

// { type, ...params } from a request body ({ change: {...} } or the change itself)
function changeFrom(body) {
    const c = body && (body.change || body);
    if (!c || typeof c !== 'object') throw new BadChange('A change is required');
    return c;
}

// Simulate one change for a household on the given client (inside the
// caller's transaction, under the household lock). Live tables are only read:
// the change is applied to a copy of optimizer_input() in Node. The result is
// stored as a what-if run (repair steps included) with the live state_hash.
async function evaluate(client, householdId, change, scenarioName = null) {
    const hh = await client.query('SELECT 1 FROM households WHERE household_id = $1', [householdId]);
    if (!hh.rows.length) throw new NotFound('Household not found');
    await client.query('SELECT lock_household($1)', [householdId]);
    const { rows: [{ input, hash }] } = await client.query(
        'SELECT optimizer_input($1) AS input, optimizer_state_hash($1) AS hash', [householdId]);

    const result = simulate(input, change);

    const { rows: [run] } = await client.query(
        `INSERT INTO optimization_runs (household_id, kind, scenario_name, evaluated_on, cost_before, cost_after,
                                        is_optimal, elapsed_ms, state_hash)
         VALUES ($1, 'what_if', $2, $3, $4, $5, $6, $7, $8)
         RETURNING run_id`,
        [householdId, scenarioName, input.evaluated_on, result.cost.after_change, result.repair.cost_after,
         result.repair.is_optimal, result.repair.elapsed_ms, hash]);
    for (const s of result.repair.steps) {
        await client.query(
            `INSERT INTO optimization_steps (run_id, step_no, action, subscription_id, plan_id, payer_id,
                                             user_ids, saving, description, reason, reason_path, confidence)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`,
            [run.run_id, s.step_no, s.action, s.subscription_id, s.plan_id, s.payer_id,
             s.user_ids, s.saving, s.description, s.reason, s.reason_path, s.confidence]);
    }

    const { _changed, _required, ...visible } = result;
    return { run_id: run.run_id, household_id: Number(householdId), ...visible };
}

// run fn(client) in one transaction
async function inTransaction(fn) {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const out = await fn(client);
        await client.query('COMMIT');
        return out;
    } catch (err) {
        await client.query('ROLLBACK');
        throw err;
    } finally {
        client.release();
    }
}

const scenarioChange = (s) => ({ type: s.change_type, ...s.change_params });

async function loadScenario(client, id) {
    const { rows } = await client.query('SELECT * FROM scenarios WHERE scenario_id = $1', [id]);
    if (!rows.length) throw new NotFound(`Scenario ${id} not found`);
    return rows[0];
}

// open a saved scenario: simulate it again on today's data, and say whether
// the last stored run of it was computed on data that has since changed
async function openScenario(client, id) {
    const s = await loadScenario(client, id);
    const { rows: prev } = await client.query(
        `SELECT run_id, state_hash, created_at FROM optimization_runs
         WHERE household_id = $1 AND kind = 'what_if' AND scenario_name = $2
         ORDER BY run_id DESC LIMIT 1`, [s.household_id, s.name]);
    const { rows: [{ hash }] } = await client.query('SELECT optimizer_state_hash($1) AS hash', [s.household_id]);
    const result = await evaluate(client, s.household_id, scenarioChange(s), s.name);
    return {
        scenario: s,
        previous_run: prev.length
            ? { run_id: prev[0].run_id, created_at: prev[0].created_at, stale: prev[0].state_hash !== hash }
            : null,
        result,
    };
}

const evaluateIn = (householdId, change, name) =>
    inTransaction((client) => evaluate(client, householdId, change, name));
const openScenarioIn = (id) => inTransaction((client) => openScenario(client, id));

// POST /api/households/:id/what-if — { type, ...params } or { change: {...} }
router.post('/households/:id/what-if', async (req, res, next) => {
    try {
        res.json(await evaluateIn(req.params.id, changeFrom(req.body)));
    } catch (err) { handle(res, next, err); }
});

// GET /api/households/:id/scenarios
router.get('/households/:id/scenarios', async (req, res, next) => {
    try {
        const { rows } = await pool.query(
            `SELECT scenario_id, household_id, name, change_type, change_params, created_at
             FROM scenarios WHERE household_id = $1 ORDER BY name`, [req.params.id]);
        res.json(rows);
    } catch (err) { next(err); }
});

// POST /api/households/:id/scenarios — { name, change: { type, ...params } }
// The change is simulated before it is saved, so a scenario that can't be
// simulated is never stored.
router.post('/households/:id/scenarios', async (req, res, next) => {
    const name = req.body && typeof req.body.name === 'string' ? req.body.name.trim() : '';
    if (!name) return res.status(400).json({ error: 'name is required' });
    try {
        const change = changeFrom(req.body.change ? { change: req.body.change } : null);
        const { type, ...params } = change;
        if (!CHANGE_TYPES.includes(type)) throw new BadChange(`change.type must be one of ${CHANGE_TYPES.join(', ')}`);
        const out = await inTransaction(async (client) => {
            const result = await evaluate(client, req.params.id, change, name);
            const { rows: [scenario] } = await client.query(
                `INSERT INTO scenarios (household_id, name, change_type, change_params)
                 VALUES ($1, $2, $3, $4) RETURNING *`, [req.params.id, name, type, params]);
            return { scenario, result };
        });
        res.status(201).json(out);
    } catch (err) { handle(res, next, err); }
});

// GET /api/scenarios/compare?a=1&b=2 — two scenarios of one household, side by side
router.get('/scenarios/compare', async (req, res, next) => {
    try {
        const out = await inTransaction(async (client) => {
            const sa = await loadScenario(client, req.query.a);
            const sb = await loadScenario(client, req.query.b);
            if (sa.household_id !== sb.household_id) throw new BadChange('Both scenarios must belong to the same household');
            const a = await openScenario(client, sa.scenario_id);
            const b = await openScenario(client, sb.scenario_id);
            const row = (x) => ({
                name: x.scenario.name,
                description: x.result.description,
                members_affected: x.result.affected_members.length,
                needed_coverage_lost: x.result.coverage_lost.filter((l) => l.needed).length,
                cost_after_change: x.result.cost.after_change,
                cost_change: x.result.cost.change,
                repaired_cost: x.result.repair.cost_after,
                repaired_vs_today: x.result.repair.change_vs_today,
                repair_steps: x.result.repair.steps.length,
            });
            const ra = row(a);
            const rb = row(b);
            return {
                a, b,
                comparison: {
                    a: ra, b: rb,
                    cheaper_after_repair: ra.repaired_cost < rb.repaired_cost ? 'a'
                        : rb.repaired_cost < ra.repaired_cost ? 'b' : 'same',
                    difference: Math.round((ra.repaired_cost - rb.repaired_cost) * 100) / 100,
                },
            };
        });
        res.json(out);
    } catch (err) { handle(res, next, err); }
});

// GET /api/scenarios/:id — re-open a saved scenario
router.get('/scenarios/:id', async (req, res, next) => {
    try {
        res.json(await openScenarioIn(req.params.id));
    } catch (err) { handle(res, next, err); }
});

// DELETE /api/scenarios/:id (its past runs stay as history)
router.delete('/scenarios/:id', async (req, res, next) => {
    try {
        const { rowCount } = await pool.query('DELETE FROM scenarios WHERE scenario_id = $1', [req.params.id]);
        if (!rowCount) return res.status(404).json({ error: `Scenario ${req.params.id} not found` });
        res.status(204).end();
    } catch (err) { next(err); }
});

// the helpers are exported too, for db/tests/v2c_check.js
module.exports = Object.assign(router, { evaluateIn, openScenarioIn });
