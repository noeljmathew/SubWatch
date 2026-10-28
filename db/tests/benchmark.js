// SubWatch — benchmark mode (FR-42).
//
//   node db/tests/benchmark.js [--sizes 5x10,10x20,15x30,20x40] [--households 3] [--seed 42] [--grid]
//
// For each size "<members>x<subscriptions>" it generates --households
// synthetic households in the scratch database (default subwatch_test) and,
// for each one, measures:
//   v1  refresh_alerts() (the rule-based detectors), then applying its
//       non-conflicting concrete findings, highest saving first
//   v2  optimizer_input() + optimize(), with MIN_SAVING and without it
// Everything happens inside one transaction that is rolled back, so the
// database is left as it was. --grid runs the PRD's full 4 x 4 grid
// (5/10/15/20 members x 10/20/30/40 subscriptions).
//
// Synthetic households: catalog plans picked at random (any purchasable plan,
// so duplicates, bundles and family-plan chances occur naturally), a random
// payer, shared plans filled with random members up to capacity, and each
// member on a plan logs 1-3 recent sessions with probability 0.7 (otherwise
// none, which makes waste).
'use strict';

const path = require('path');

const ROOT = path.resolve(__dirname, '../..');
const DB = process.env.BENCH_DB || 'subwatch_test';
if (DB === 'subwatch') {
    console.error("refusing to run against the working database 'subwatch'");
    process.exit(2);
}
process.env.PGDATABASE = DB;
require(require.resolve('dotenv', { paths: [path.join(ROOT, 'server')] }))
    .config({ path: path.join(ROOT, 'server/.env'), quiet: true });

const { pool } = require(path.join(ROOT, 'server/db'));
const { optimize } = require(path.join(ROOT, 'server/optimizer'));

const HARD = ['hidden_duplicate', 'consolidation', 'spare_capacity', 'bundle', 'waste'];

function args(argv) {
    const get = (k, d) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : d; };
    const grid = argv.includes('--grid');
    const sizes = grid
        ? [5, 10, 15, 20].flatMap((m) => [10, 20, 30, 40].map((p) => [m, p]))
        : get('--sizes', '5x10,10x20,15x30,20x40').split(',').map((s) => s.split('x').map(Number));
    return { sizes, households: Number(get('--households', 3)), seed: Number(get('--seed', 42)) };
}

function prng(seed) {
    let s = seed >>> 0 || 1;
    return (n) => { s = (Math.imul(s, 1103515245) + 12345) >>> 0; return (s >>> 8) % n; };
}

const ms = (t0) => Math.round(Number(process.hrtime.bigint() - t0) / 1e5) / 10;

async function makeHousehold(c, rnd, tag, members, nSubs, plans) {
    const { rows: [{ household_id: hh }] } = await c.query(
        `INSERT INTO households (name) VALUES ($1) RETURNING household_id`, [`Bench ${tag}`]);
    const users = [];
    for (let i = 0; i < members; i++) {
        const { rows: [{ user_id }] } = await c.query(
            `INSERT INTO users (full_name, email, password_hash) VALUES ($1, $2, 'x') RETURNING user_id`,
            [`B${i} ${tag}`, `bench-${tag}-${i}@example.com`]);
        await c.query(`INSERT INTO household_members (household_id, user_id, role) VALUES ($1, $2, $3)`,
                      [hh, user_id, i === 0 ? 'owner' : 'member']);
        users.push(user_id);
    }
    for (let k = 0; k < nSubs; k++) {
        const plan = plans[rnd(plans.length)];
        const payer = users[rnd(users.length)];
        const { rows: [{ subscription_id: sid }] } = await c.query(
            `INSERT INTO subscriptions (payer_id, plan_id, start_date) VALUES ($1, $2, CURRENT_DATE - $3::int)
             RETURNING subscription_id`, [payer, plan.plan_id, 60 + rnd(300)]);
        const onIt = [payer];
        const extra = plan.max_members > 1 ? rnd(plan.max_members) : 0;
        for (let j = 0; j < extra; j++) {
            const u = users[rnd(users.length)];
            if (onIt.includes(u)) continue;
            await c.query(`INSERT INTO subscription_members (subscription_id, user_id) VALUES ($1, $2)`, [sid, u]);
            onIt.push(u);
        }
        for (const u of onIt) {
            if (rnd(10) >= 7) continue;
            for (let s = 0, n = 1 + rnd(3); s < n; s++) {
                await c.query(
                    `INSERT INTO usage_logs (subscription_id, user_id, used_at, duration_minutes)
                     VALUES ($1, $2, now() - ($3::int * interval '1 hour'), 30)`, [sid, u, 1 + rnd(28 * 24)]);
            }
        }
    }
    return hh;
}

async function v1Saving(c, hh) {
    const spend = async () => Number((await c.query('SELECT household_spend_at($1, CURRENT_DATE) AS s', [hh])).rows[0].s);
    await c.query('SAVEPOINT v1');
    const before = await spend();
    const { rows: alerts } = await c.query(
        `SELECT a.alert_id, array_agg(x.subscription_id) AS subjects
         FROM alerts a JOIN alert_subscriptions x ON x.alert_id = a.alert_id AND x.role = 'subject'
         WHERE a.household_id = $1 AND a.status = 'open' AND a.alert_type = ANY ($2)
         GROUP BY a.alert_id, a.potential_monthly_savings
         ORDER BY a.potential_monthly_savings DESC, a.alert_id`, [hh, HARD]);
    const touched = new Set();
    for (const a of alerts) {
        if (a.subjects.some((s) => touched.has(s))) continue;
        if (!(await c.query(`SELECT 1 FROM alerts WHERE alert_id = $1 AND status = 'open'`, [a.alert_id])).rows.length) continue;
        await c.query('SAVEPOINT fix');
        try {
            await c.query('SELECT apply_alert($1)', [a.alert_id]);
            a.subjects.forEach((s) => touched.add(s));
            await c.query('RELEASE SAVEPOINT fix');
        } catch {
            await c.query('ROLLBACK TO SAVEPOINT fix');
        }
    }
    const saving = Math.round((before - (await spend())) * 100) / 100;
    await c.query('ROLLBACK TO SAVEPOINT v1');
    return { saving, findings: alerts.length };
}

// run the benchmark; returns one row per household
async function benchmark({ sizes, households, seed }, log = console.log) {
    const rnd = prng(seed);
    const rows = [];
    const c = await pool.connect();
    try {
        await c.query('BEGIN');
        const { rows: plans } = await c.query(
            `SELECT plan_id, max_members FROM plans WHERE is_purchasable AND price IS NOT NULL ORDER BY plan_id`);
        for (const [members, nSubs] of sizes) {
            for (let k = 0; k < households; k++) {
                const tag = `${members}x${nSubs}-${k}`;
                const hh = await makeHousehold(c, rnd, tag, members, nSubs, plans);
                await c.query('SELECT lock_household($1)', [hh]);

                let t0 = process.hrtime.bigint();
                await c.query('CALL refresh_alerts($1)', [hh]);
                const v1Ms = ms(t0);
                const v1 = await v1Saving(c, hh);

                t0 = process.hrtime.bigint();
                const { rows: [{ input }] } = await c.query('SELECT optimizer_input($1) AS input', [hh]);
                const loadMs = ms(t0);
                t0 = process.hrtime.bigint();
                const v2 = optimize(input);
                const v2Ms = ms(t0);
                const v2raw = optimize(input, { minSaving: 0 });

                const row = {
                    size: `${members}x${nSubs}`, household: k, v1_findings: v1.findings,
                    v1_ms: v1Ms, v2_load_ms: loadMs, v2_ms: v2Ms,
                    v1_saving: v1.saving, v2_saving: v2.saving, v2_no_threshold: v2raw.saving,
                    optimal: v2.is_optimal && v2raw.is_optimal,
                };
                rows.push(row);
                log(`${row.size} #${k}: v1 ₹${row.v1_saving} in ${row.v1_ms} ms | v2 ₹${row.v2_saving} `
                    + `(₹${row.v2_no_threshold} without MIN_SAVING) in ${row.v2_load_ms} + ${row.v2_ms} ms`
                    + (row.optimal ? '' : ' (time cap hit)'));
            }
        }
    } finally {
        await c.query('ROLLBACK');
        c.release();
    }
    return rows;
}

if (require.main === module) {
    benchmark(args(process.argv))
        .then((rows) => {
            const bySize = new Map();
            for (const r of rows) {
                if (!bySize.has(r.size)) bySize.set(r.size, []);
                bySize.get(r.size).push(r);
            }
            const avg = (xs) => Math.round(xs.reduce((t, x) => t + x, 0) / xs.length * 10) / 10;
            console.table([...bySize].map(([size, rs]) => ({
                size,
                households: rs.length,
                v1_ms: avg(rs.map((r) => r.v1_ms)),
                v2_ms: avg(rs.map((r) => r.v2_load_ms + r.v2_ms)),
                v1_saving: avg(rs.map((r) => r.v1_saving)),
                v2_saving: avg(rs.map((r) => r.v2_saving)),
                v2_beats_or_equals_v1: rs.filter((r) => r.v2_no_threshold >= r.v1_saving - 0.005).length + '/' + rs.length,
                exact: rs.filter((r) => r.optimal).length + '/' + rs.length,
            })));
        })
        .catch((err) => { console.error(err.message); process.exitCode = 1; })
        .finally(() => pool.end());
}

module.exports = { benchmark };
