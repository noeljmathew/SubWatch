// SubWatch — v2b checks (FR-29 to FR-33) on the three demo households.
//
//   node db/tests/v2b_check.js            rebuilds subwatch_test (regress.sh), then checks
//   node db/tests/v2b_check.js --no-rebuild
//
// For every household:
//   1. the optimizer is never worse than applying the non-conflicting v1
//      findings (hard types, highest saving first, skipping any that touch a
//      subscription already changed), measured inside a rolled-back transaction
//   2. after applying the run: no need is uncovered, no passive service is
//      lost, no service has more plans than before, and the cost is cost_after
//   3. the same data gives the same answer on repeat runs
//   4. a failure in the last step undoes every earlier step (atomicity)
// plus: the Sharma Netflix and YouTube Family plans are never split.
// The working "subwatch" database is never touched; server/.env is only read.
'use strict';

const path = require('path');
const { execFileSync } = require('child_process');
const assert = require('assert/strict');

const ROOT = path.resolve(__dirname, '../..');
const DB = process.env.V2B_DB || 'subwatch_test';
if (DB === 'subwatch') {
    console.error("refusing to run against the working database 'subwatch'");
    process.exit(2);
}
process.env.PGDATABASE = DB;                     // dotenv never overrides a set variable
require(require.resolve('dotenv', { paths: [path.join(ROOT, 'server')] }))
    .config({ path: path.join(ROOT, 'server/.env'), quiet: true });

if (!process.argv.includes('--no-rebuild')) {
    execFileSync(path.join(ROOT, 'db/tests/regress.sh'), [DB], { stdio: ['ignore', 'inherit', 'ignore'] });
}

const { pool } = require(path.join(ROOT, 'server/db'));
const { createRun, readRun } = require(path.join(ROOT, 'server/routes/optimizer'));

const HARD = ['hidden_duplicate', 'consolidation', 'spare_capacity', 'bundle', 'waste'];
let passed = 0;
function check(ok, label) {
    assert.ok(ok, 'FAIL: ' + label);
    passed++;
    console.log('PASS: ' + label);
}

// run fn inside a transaction that is always rolled back
async function rolledBack(fn) {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        return await fn(client);
    } finally {
        await client.query('ROLLBACK');
        client.release();
    }
}

const spendNow = async (c, hh) =>
    Number((await c.query('SELECT household_spend_at($1, CURRENT_DATE) AS s', [hh])).rows[0].s);

// v1, applied greedily without conflicts
async function v1Cost(hh) {
    return rolledBack(async (c) => {
        await c.query('SELECT lock_household($1)', [hh]);
        const { rows: alerts } = await c.query(
            `SELECT a.alert_id, array_agg(x.subscription_id) AS subjects
             FROM alerts a JOIN alert_subscriptions x ON x.alert_id = a.alert_id AND x.role = 'subject'
             WHERE a.household_id = $1 AND a.status = 'open' AND a.alert_type = ANY ($2)
             GROUP BY a.alert_id, a.potential_monthly_savings
             ORDER BY a.potential_monthly_savings DESC, a.alert_id`, [hh, HARD]);
        const touched = new Set();
        for (const a of alerts) {
            if (a.subjects.some((s) => touched.has(s))) continue;
            const open = await c.query(`SELECT 1 FROM alerts WHERE alert_id = $1 AND status = 'open'`, [a.alert_id]);
            if (!open.rows.length) continue;
            await c.query('SAVEPOINT fix');
            try {
                await c.query('SELECT apply_alert($1)', [a.alert_id]);
                a.subjects.forEach((s) => touched.add(s));
                await c.query('RELEASE SAVEPOINT fix');
            } catch (e) {
                await c.query('ROLLBACK TO SAVEPOINT fix');
            }
        }
        return spendNow(c, hh);
    });
}

async function householdState(c, hh) {
    const { rows } = await c.query(
        `SELECT s.subscription_id, s.status,
                (SELECT array_agg(sm.user_id ORDER BY sm.user_id) FROM subscription_members sm
                  WHERE sm.subscription_id = s.subscription_id) AS members
         FROM subscriptions s JOIN household_members hm ON hm.user_id = s.payer_id
         WHERE hm.household_id = $1 ORDER BY s.subscription_id`, [hh]);
    return JSON.stringify(rows);
}

async function main() {
    const { rows: households } = await pool.query('SELECT household_id, name FROM households ORDER BY household_id');
    const summary = [];

    for (const { household_id: hh, name } of households) {
        console.log(`\n--- ${name}`);
        const v1 = await v1Cost(hh);
        const runId = await createRun(hh);
        const run = await readRun(runId);
        const costBefore = Number(run.cost_before);
        const costAfter = Number(run.cost_after);

        // 1. never worse than v1
        check(costAfter <= v1 + 0.005,
              `${name}: optimizer ₹${costAfter} ≤ v1 findings applied ₹${v1} (from ₹${costBefore})`);
        check(run.is_optimal, `${name}: exact search finished within the time cap (${run.elapsed_ms} ms)`);

        // 2. apply it and look at the result
        await rolledBack(async (c) => {
            const passiveBefore = (await c.query(
                `SELECT sm.user_id, p.service_id
                 FROM subscriptions s
                 JOIN household_members hm    ON hm.user_id = s.payer_id
                 JOIN plan_catalog p          ON p.plan_id = s.plan_id
                 JOIN services sv             ON sv.service_id = p.service_id
                 JOIN categories cat          ON cat.category_id = sv.category_id
                 JOIN subscription_members sm ON sm.subscription_id = s.subscription_id
                 WHERE hm.household_id = $1 AND s.status = 'active' AND cat.is_passive`, [hh])).rows;
            const plansBefore = new Map((await c.query(
                `SELECT service_id, COUNT(*)::int AS n FROM v_subscription_detail
                 WHERE household_id = $1 AND status = 'active' GROUP BY service_id`, [hh])).rows
                .map((r) => [r.service_id, r.n]));
            const uncoveredBefore = Number((await c.query(
                `SELECT COUNT(*) AS n FROM v_need_coverage WHERE household_id = $1 AND NOT covered`, [hh])).rows[0].n);

            const { rows: [{ steps }] } = await c.query('SELECT apply_optimization($1) AS steps', [runId]);
            check(Array.isArray(steps) && steps.length === run.steps.length, `${name}: applied all ${run.steps.length} steps`);

            const uncovered = Number((await c.query(
                `SELECT COUNT(*) AS n FROM v_need_coverage WHERE household_id = $1 AND NOT covered`, [hh])).rows[0].n);
            check(uncovered === 0 && uncoveredBefore === 0, `${name}: no need left uncovered after applying`);

            let lost = 0;
            for (const p of passiveBefore) {
                const ok = await c.query(
                    'SELECT 1 FROM v_member_coverage WHERE user_id = $1 AND service_id = $2', [p.user_id, p.service_id]);
                if (!ok.rows.length) lost++;
            }
            check(lost === 0, `${name}: nothing passive lost (${passiveBefore.length} passive memberships still covered)`);

            const plansAfter = (await c.query(
                `SELECT service_id, COUNT(*)::int AS n FROM v_subscription_detail
                 WHERE household_id = $1 AND status = 'active' GROUP BY service_id`, [hh])).rows;
            check(plansAfter.every((r) => r.n <= Math.max(plansBefore.get(r.service_id) || 0, 1)),
                  `${name}: no service has more plans than before (no splitting)`);

            check(Math.abs((await spendNow(c, hh)) - costAfter) < 0.005, `${name}: household now costs ₹${costAfter}`);
        });

        // 3. same answer on repeat runs
        const again = await readRun(await createRun(hh));
        const shape = (r) => JSON.stringify({ steps: r.steps, outcomes: r.finding_outcomes, cost: r.cost_after });
        check(shape(again) === shape(run), `${name}: same steps and finding outcomes on a second run`);

        // 4. atomicity: a final step that must fail undoes everything before it
        const firstCancel = run.steps.find((s) => s.action === 'cancel' || s.action === 'switch');
        if (firstCancel) {
            await rolledBack(async (c) => {
                const before = await householdState(c, hh);
                await c.query(
                    `INSERT INTO optimization_steps (run_id, step_no, action, subscription_id, saving, description, reason)
                     VALUES ($1, $2, 'cancel', $3, 0, 'injected failure', 'test')`,
                    [again.run_id, again.steps.length + 1, firstCancel.subscription_id]);
                await c.query('SAVEPOINT apply');
                let failed = false;
                try {
                    await c.query('SELECT apply_optimization($1)', [again.run_id]);
                } catch (e) {
                    failed = /no longer active/.test(e.message);
                }
                await c.query('ROLLBACK TO SAVEPOINT apply');
                check(failed && (await householdState(c, hh)) === before,
                      `${name}: failing step ${again.steps.length + 1} of ${again.steps.length + 1} leaves nothing changed`);
            });
        }

        summary.push({ household: name, before: costBefore, v1, v2: costAfter,
                       v1_saving: Math.round((costBefore - v1) * 100) / 100,
                       v2_saving: Number(run.monthly_saving), ms: run.elapsed_ms });

        if (hh === 1) {
            const touched = new Set(run.steps.map((s) => s.subscription_id));
            const { rows: shared } = await pool.query(
                `SELECT subscription_id, service_name FROM v_subscription_detail
                 WHERE household_id = 1 AND service_name IN ('Netflix', 'YouTube Premium') AND member_count > 1`);
            check(shared.length === 2 && shared.every((s) => !touched.has(s.subscription_id))
                  && !run.steps.some((s) => s.action === 'start' && /Netflix|YouTube Premium/.test(s.description)),
                  'Sharma: shared Netflix Premium and YouTube Premium Family are not split into individual plans');
        }
    }

    console.log('');
    console.table(summary);
    console.log(`v2b checks: all ${passed} passed`);
}

main()
    .catch((err) => { console.error(err.message); process.exitCode = 1; })
    .finally(() => pool.end());
