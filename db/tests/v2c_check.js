// SubWatch — v2c checks (FR-34 to FR-36): the what-if simulator.
//
//   node db/tests/v2c_check.js            rebuilds subwatch_test (regress.sh), then checks
//   node db/tests/v2c_check.js --no-rebuild
//
// For every household, every scenario that can be built from its data
// (cancel each subscription, switch each to every other plan of its service,
// each member moving out, each inclusion of a held plan removed, each held
// plan 20% dearer):
//   1. live tables are byte-for-byte the same afterwards (row counts + hashes)
//   2. the repair covers every need the change took away and every need that
//      was still covered, checked by replaying its steps independently
//   3. the same scenario gives the same answer twice
// plus: removing an inclusion reports exactly the members who lose coverage
// (checked against v_member_coverage), what-if runs can't be applied, and the
// HTTP API (what-if, scenarios, compare, stale detection) works end to end.
'use strict';

const path = require('path');
const { execFileSync, spawn } = require('child_process');
const assert = require('assert/strict');

const ROOT = path.resolve(__dirname, '../..');
const DB = process.env.V2C_DB || 'subwatch_test';
if (DB === 'subwatch') {
    console.error("refusing to run against the working database 'subwatch'");
    process.exit(2);
}
process.env.PGDATABASE = DB;
require(require.resolve('dotenv', { paths: [path.join(ROOT, 'server')] }))
    .config({ path: path.join(ROOT, 'server/.env'), quiet: true });

if (!process.argv.includes('--no-rebuild')) {
    execFileSync(path.join(ROOT, 'db/tests/regress.sh'), [DB], { stdio: ['ignore', 'inherit', 'ignore'] });
}

const { pool } = require(path.join(ROOT, 'server/db'));
const { simulate } = require(path.join(ROOT, 'server/whatif'));
const { evaluateIn } = require(path.join(ROOT, 'server/routes/whatif'));

let passed = 0;
function check(ok, label) {
    assert.ok(ok, 'FAIL: ' + label);
    passed++;
    console.log('PASS: ' + label);
}

// every table a what-if must not change
const LIVE_TABLES = ['users', 'households', 'household_members', 'categories', 'services', 'plan_catalog',
    'plan_price_history', 'plan_inclusion_history', 'subscriptions', 'subscription_members', 'usage_logs',
    'member_needs', 'alerts', 'alert_subscriptions', 'merchant_aliases', 'statement_imports',
    'bank_transactions', 'scenarios'];

async function liveFingerprint() {
    const out = {};
    for (const t of LIVE_TABLES) {
        const { rows: [r] } = await pool.query(
            `SELECT COUNT(*)::int AS n, md5(COALESCE(string_agg(t::text, '|' ORDER BY t::text), '')) AS h FROM ${t} t`);
        out[t] = r.n + ':' + r.h;
    }
    const { rows: [o] } = await pool.query(`SELECT COUNT(*)::int AS n FROM optimization_runs WHERE kind = 'optimize'`);
    out.optimize_runs = o.n;
    return out;
}

// every scenario the household's own data allows
function scenariosFor(input) {
    const plans = new Map(input.plans.map((p) => [p.plan_id, p]));
    const held = new Set(input.subscriptions.map((s) => s.plan_id));
    const list = [];
    for (const s of input.subscriptions) {
        list.push({ type: 'cancel_subscription', subscription_id: s.subscription_id });
        const from = plans.get(s.plan_id);
        for (const p of input.plans) {
            if (p.service_id === from.service_id && p.plan_id !== from.plan_id && p.is_purchasable && p.monthly_price != null) {
                list.push({ type: 'switch_plan', subscription_id: s.subscription_id, plan_id: p.plan_id });
            }
        }
    }
    for (const u of input.users) list.push({ type: 'remove_member', user_id: u.user_id });
    for (const e of input.inclusions) {
        if (held.has(e.parent_plan_id) || input.plans.some((p) => p.covers.some((c) => c.path.includes(e.parent_plan_id))
                                                              && held.has(p.plan_id))) {
            list.push({ type: 'remove_inclusion', parent_plan_id: e.parent_plan_id, included_plan_id: e.included_plan_id });
        }
    }
    for (const id of held) {
        const p = plans.get(id);
        list.push({ type: 'raise_price', plan_id: id, monthly_price: Math.round(Number(p.monthly_price) * 120) / 100 + 1 });
    }
    return list;
}

// which (member, service) pairs a set of subscriptions gives access to
function accessOf(plans, subs) {
    const pairs = new Set();
    for (const s of subs) for (const c of plans.get(s.plan_id).covers) for (const u of s.member_ids) pairs.add(u + ':' + c.service_id);
    return pairs;
}

// replay repair steps on the changed input, independently of the optimizer
function replay(changed, steps) {
    let subs = changed.subscriptions.map((s) => ({ ...s, member_ids: [...s.member_ids] }));
    for (const st of steps) {
        if (st.action === 'start') subs.push({ subscription_id: 'new' + st.step_no, payer_id: st.payer_id, plan_id: st.plan_id, member_ids: st.user_ids });
        if (st.action === 'switch') {
            const s = subs.find((x) => x.subscription_id === st.subscription_id);
            Object.assign(s, { plan_id: st.plan_id, member_ids: st.user_ids });
        }
        if (st.action === 'add_member') subs.find((x) => x.subscription_id === st.subscription_id).member_ids.push(st.user_ids[0]);
        if (st.action === 'cancel') subs = subs.filter((x) => x.subscription_id !== st.subscription_id);
    }
    return subs;
}

const strip = (r) => JSON.stringify({ ...r, repair: { ...r.repair, elapsed_ms: 0 } });

async function main() {
    const { rows: households } = await pool.query('SELECT household_id, name FROM households ORDER BY household_id');

    // ---------------------------------------------------------------- 1-3
    const before = await liveFingerprint();
    let total = 0;
    for (const { household_id: hh, name } of households) {
        const { rows: [{ input }] } = await pool.query('SELECT optimizer_input($1) AS input', [hh]);
        const scenarios = scenariosFor(input);
        let restoredAll = true;
        let sameTwice = true;
        let failures = [];
        for (const change of scenarios) {
            await evaluateIn(hh, change);                      // the API path: stores a what-if run
            const r = simulate(input, change);
            const plans = new Map(r._changed.plans.map((p) => [p.plan_id, p]));
            const beforeRepair = accessOf(plans, r._changed.subscriptions);
            const afterRepair = accessOf(plans, replay(r._changed, r.repair.steps));
            const mustHave = [
                ...r._required.map((n) => n.user_id + ':' + n.service_id),
                ...r._changed.needs.map((n) => n.user_id + ':' + n.service_id).filter((k) => beforeRepair.has(k)),
            ];
            const missing = mustHave.filter((k) => !afterRepair.has(k));
            if (missing.length || r.repair.needs_not_restored.length) {
                restoredAll = false;
                failures.push(JSON.stringify(change) + ' missing ' + missing.join(','));
            }
            if (strip(simulate(input, change)) !== strip(r)) sameTwice = false;
        }
        total += scenarios.length;
        check(restoredAll, `${name}: all ${scenarios.length} repairs leave no need uncovered`
                           + (failures.length ? ' — ' + failures.slice(0, 3).join('; ') : ''));
        check(sameTwice, `${name}: every scenario gives the same answer twice`);
    }
    const after = await liveFingerprint();
    const changedTables = LIVE_TABLES.filter((t) => before[t] !== after[t]);
    check(changedTables.length === 0 && before.optimize_runs === after.optimize_runs,
          `${total} what-ifs left all ${LIVE_TABLES.length} live tables unchanged (row counts and hashes)`
          + (changedTables.length ? ' — changed: ' + changedTables.join(', ') : ''));
    const { rows: [w] } = await pool.query(`SELECT COUNT(*)::int AS n FROM optimization_runs WHERE kind = 'what_if'`);
    check(w.n === total, `each what-if was stored as a what_if run (${w.n})`);

    // ---------------------------------------------------------------- inclusion
    const { rows: [{ input: sharma }] } = await pool.query('SELECT optimizer_input(1) AS input');
    const { rows: [edge] } = await pool.query(
        `SELECT pc.plan_id AS parent, ip.plan_id AS included
         FROM plan_catalog pc JOIN services s ON s.service_id = pc.service_id,
              plan_catalog ip JOIN services s2 ON s2.service_id = ip.service_id
         WHERE s.name = 'Airtel Postpaid' AND pc.name = 'Family 1199' AND s2.name = 'Amazon Prime' AND ip.name = 'Included'`);
    const r = simulate(sharma, { type: 'remove_inclusion', parent_plan_id: edge.parent, included_plan_id: edge.included });
    // expected: (member, service) pairs whose every way in runs through that edge
    const { rows: expected } = await pool.query(
        `SELECT mc.user_id, mc.service_id
         FROM v_member_coverage mc
         WHERE mc.household_id = 1
         GROUP BY mc.user_id, mc.service_id
         HAVING bool_and(COALESCE(array_position(mc.path, $1) + 1 = array_position(mc.path, $2), false))
         ORDER BY 1, 2`, [edge.parent, edge.included]);
    check(JSON.stringify(r.coverage_lost.map((l) => [l.user_id, l.service_id]))
          === JSON.stringify(expected.map((e) => [e.user_id, e.service_id])) && expected.length > 0,
          `Airtel dropping Prime: coverage lost matches v_member_coverage (${expected.length} member-services)`);
    check(JSON.stringify(r.affected_members.map((a) => a.name)) === JSON.stringify(['Priya Sharma', 'Arjun Sharma']),
          `...affected members: ${r.affected_members.map((a) => `${a.name} (${a.services_lost.join(', ')})`).join('; ')}`);

    // ---------------------------------------------------------------- not applicable
    const { rows: [wr] } = await pool.query(`SELECT run_id FROM optimization_runs WHERE kind = 'what_if' LIMIT 1`);
    let refused = false;
    const c = await pool.connect();
    try {
        await c.query('BEGIN');
        await c.query('SELECT apply_optimization($1)', [wr.run_id]);
    } catch (e) {
        refused = /cannot be applied/.test(e.message);
    } finally {
        await c.query('ROLLBACK');
        c.release();
    }
    check(refused, 'a what-if run cannot be applied');

    // ---------------------------------------------------------------- HTTP API
    const port = 4100 + Math.floor(Math.random() * 500);
    const server = spawn(process.execPath, ['index.js'], {
        cwd: path.join(ROOT, 'server'), env: { ...process.env, PORT: String(port) }, stdio: 'ignore',
    });
    try {
        const base = `http://localhost:${port}/api`;
        for (let i = 0; i < 50; i++) {
            try { await fetch(base + '/health'); break; } catch { await new Promise((ok) => setTimeout(ok, 100)); }
        }
        const call = async (method, url, body) => {
            const res = await fetch(base + url, {
                method, headers: { 'Content-Type': 'application/json' }, body: body && JSON.stringify(body),
            });
            return { status: res.status, body: res.status === 204 ? null : await res.json() };
        };

        const wi = await call('POST', '/households/1/what-if', { type: 'remove_member', user_id: 1 });
        check(wi.status === 200 && wi.body.repair.needs_restored === 4 && !('_changed' in wi.body),
              `POST what-if: Priya moving out restores 4 needs, repaired cost ₹${wi.body.repair.cost_after}`);
        check((await call('POST', '/households/1/what-if', { type: 'nope' })).status === 400, 'POST what-if: bad change is 400');
        check((await call('POST', '/households/999/what-if', { type: 'remove_member', user_id: 1 })).status === 404,
              'POST what-if: unknown household is 404');

        const sa = await call('POST', '/households/1/scenarios',
                              { name: 'Airtel drops Prime', change: { type: 'remove_inclusion', parent_plan_id: edge.parent, included_plan_id: edge.included } });
        const sb = await call('POST', '/households/1/scenarios',
                              { name: 'Priya moves out', change: { type: 'remove_member', user_id: 1 } });
        check(sa.status === 201 && sb.status === 201, 'POST scenarios: two saved');
        check((await call('POST', '/households/1/scenarios', { name: 'Airtel drops Prime', change: { type: 'remove_member', user_id: 2 } })).status === 409,
              'POST scenarios: duplicate name is 409');
        check((await call('POST', '/households/1/scenarios', { name: 'bad', change: { type: 'raise_price', plan_id: 1, monthly_price: 0 } })).status === 400,
              'POST scenarios: a change that cannot be simulated is not saved (400)');
        const list = await call('GET', '/households/1/scenarios');
        check(list.body.map((s) => s.name).join('|') === 'Airtel drops Prime|Priya moves out', 'GET scenarios lists them');

        const open1 = await call('GET', `/scenarios/${sa.body.scenario.scenario_id}`);
        check(open1.status === 200 && open1.body.previous_run && open1.body.previous_run.stale === false,
              'GET scenario: re-opened, last run not stale');

        const cmp = await call('GET', `/scenarios/compare?a=${sa.body.scenario.scenario_id}&b=${sb.body.scenario.scenario_id}`);
        check(cmp.status === 200 && cmp.body.comparison.a.name === 'Airtel drops Prime'
              && ['a', 'b', 'same'].includes(cmp.body.comparison.cheaper_after_repair),
              `GET compare: ₹${cmp.body.comparison.a.repaired_cost} vs ₹${cmp.body.comparison.b.repaired_cost} after repair`);

        // live data changes -> the stored run is stale when the scenario is re-opened
        await pool.query(`SELECT set_member_need(3, (SELECT service_id FROM services WHERE name = 'Audible'), true)`);
        const open2 = await call('GET', `/scenarios/${sa.body.scenario.scenario_id}`);
        check(open2.body.previous_run.stale === true, 'GET scenario after a household change: previous run is stale, result is fresh');

        check((await call('DELETE', `/scenarios/${sb.body.scenario.scenario_id}`)).status === 204
              && (await call('GET', `/scenarios/${sb.body.scenario.scenario_id}`)).status === 404, 'DELETE scenario');
    } finally {
        server.kill();
    }

    console.log(`v2c checks: all ${passed} passed`);
}

main()
    .catch((err) => { console.error(err.message); process.exitCode = 1; })
    .finally(() => pool.end());
