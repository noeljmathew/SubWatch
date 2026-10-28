// SubWatch — v2d checks (FR-39 to FR-42): evidence, confidence, data quality.
//
//   node db/tests/v2d_check.js            rebuilds subwatch_test (regress.sh), then checks
//   node db/tests/v2d_check.js --no-rebuild
//
//   1. every open finding has evidence rows, and its confidence is what the
//      documented rule gives for them (recomputed here in JS)
//   2. on the demo data: coverage findings High, falling usage / overlap
//      Medium, long-unused waste High; the totals equal the v1 baseline
//   3. 45 days of silence (Vikram's recent logs removed, rolled back): his
//      usage-based findings drop to Low with a silence row, and Low findings
//      are left out of "savings found" and moved to "worth a look"
//   4. optimizer steps: a downgrade is Medium; with the silence, the cancel
//      that rests on missing usage is Low and left out of the counted saving
//   5. constraints, the household lock and jit = off on the new routines
//   6. benchmark mode (FR-42): v2 never saves less than v1 on generated
//      households, and leaves the database unchanged
'use strict';

const path = require('path');
const fs = require('fs');
const { execFileSync } = require('child_process');
const assert = require('assert/strict');

const ROOT = path.resolve(__dirname, '../..');
const DB = process.env.V2D_DB || 'subwatch_test';
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
const { optimize } = require(path.join(ROOT, 'server/optimizer'));
const { createRun, readRun } = require(path.join(ROOT, 'server/routes/optimizer'));
const { benchmark } = require(path.join(ROOT, 'db/tests/benchmark'));

const HARD = ['hidden_duplicate', 'consolidation', 'spare_capacity', 'bundle', 'waste'];
const USAGE_BASED = ['waste', 'churn_risk', 'overlap'];
let passed = 0;
function check(ok, label) {
    assert.ok(ok, 'FAIL: ' + label);
    passed++;
    console.log('PASS: ' + label);
}

// the rule from detection.sql (v_finding_confidence), written out again
function confidenceOf(rows) {
    if (rows.some((r) => r.evidence_type === 'silence')) return 'Low';
    const best = new Map();
    for (const r of rows) best.set(r.evidence_type, Math.max(best.get(r.evidence_type) ?? -99, r.weight));
    const score = [...best.values()].reduce((t, w) => t + w, 0);
    return score >= 3 ? 'High' : score === 2 ? 'Medium' : 'Low';
}

async function openAlerts(c, hh = null) {
    const { rows } = await c.query(
        `SELECT a.alert_id, a.household_id, a.alert_type, a.fingerprint, a.confidence, a.counts_toward_savings,
                a.potential_monthly_savings::float AS savings,
                COALESCE((SELECT json_agg(json_build_object('evidence_type', e.evidence_type, 'weight', e.weight,
                                                            'value', e.value, 'source_ref', e.source_ref))
                          FROM finding_evidence e WHERE e.alert_id = a.alert_id), '[]') AS evidence
         FROM alerts a WHERE a.status = 'open' AND ($1::int IS NULL OR a.household_id = $1)
         ORDER BY a.alert_id`, [hh]);
    return rows;
}

async function totals(c, hh) {
    const { rows: [t] } = await c.query(
        `SELECT monthly_spend::float AS spend, savings_found::float AS found, worth_a_look::float AS look,
                low_confidence_findings AS low
         FROM v_household_savings WHERE household_id = $1`, [hh]);
    return t;
}

// the totals rule from FR-41, computed independently from the alert rows
function expectedTotals(alerts, spend) {
    const round = (x) => Math.round(x * 100) / 100;
    const counted = alerts.filter((a) => HARD.includes(a.alert_type) && a.confidence !== 'Low');
    const rest = alerts.filter((a) => !counted.includes(a));
    return {
        found: round(Math.min(spend, counted.reduce((t, a) => t + a.savings, 0))),
        look: round(rest.reduce((t, a) => t + a.savings, 0)),
        low: alerts.filter((a) => a.confidence === 'Low').length,
    };
}

async function main() {
    // ------------------------------------------------------------ 1 and 2
    const alerts = await openAlerts(pool);
    check(alerts.length === 15 && alerts.every((a) => a.evidence.length > 0),
          `all ${alerts.length} open findings have evidence rows`);
    const mismatch = alerts.filter((a) => confidenceOf(a.evidence) !== a.confidence);
    check(mismatch.length === 0, 'every confidence equals the documented rule applied to its evidence'
                                 + (mismatch.length ? ': ' + mismatch.map((a) => a.fingerprint).join(', ') : ''));
    check(alerts.every((a) => a.evidence.some((e) => e.evidence_type === 'price')), 'every finding cites a catalog price');
    check(alerts.filter((a) => ['hidden_duplicate', 'consolidation', 'spare_capacity', 'bundle'].includes(a.alert_type))
                .every((a) => a.evidence.some((e) => e.evidence_type === 'coverage')),
          'every coverage finding cites its reason path');
    const level = (types) => [...new Set(alerts.filter((a) => types.includes(a.alert_type)).map((a) => a.confidence))].join(',');
    check(level(['hidden_duplicate', 'consolidation', 'spare_capacity', 'bundle']) === 'High', 'demo: coverage findings are High');
    check(level(['churn_risk', 'overlap']) === 'Medium', 'demo: falling usage and overlap are Medium');
    check(level(['waste']) === 'High', 'demo: waste unused for 60+ days (Audible, LinkedIn) is High');

    const baseline = fs.readFileSync(path.join(ROOT, 'db/tests/v1_baseline/summary.csv'), 'utf8')
        .trim().split('\n').slice(1).map((l) => l.split(','));
    let same = true;
    for (const [id, , , spend, found, look] of baseline) {
        const t = await totals(pool, Number(id));
        if (t.spend !== Number(spend) || t.found !== Number(found) || t.look !== Number(look) || t.low !== 0) same = false;
    }
    check(same, 'demo: no Low findings, so savings found and worth a look equal the v1 baseline');

    // ------------------------------------------------------------ 3 and 4
    const c = await pool.connect();
    try {
        await c.query('BEGIN');
        const { rows: [{ uid }] } = await c.query(`SELECT user_id AS uid FROM users WHERE full_name = 'Vikram Iyer'`);
        const before = await totals(c, 3);
        await c.query(`DELETE FROM usage_logs WHERE user_id = $1 AND used_at > now() - interval '45 days'`, [uid]);
        await c.query('CALL refresh_alerts(3)');

        const { rows: [q] } = await c.query('SELECT days_silent, flagged FROM usage_data_quality WHERE user_id = $1', [uid]);
        check(q.flagged && q.days_silent >= 45, `Vikram flagged after ${q.days_silent} days of silence`);

        const iyer = await openAlerts(c, 3);
        const vikramsUsageBased = [];
        for (const a of iyer.filter((x) => USAGE_BASED.includes(x.alert_type))) {
            const { rows } = await c.query(
                `SELECT 1 FROM alert_subscriptions x JOIN subscription_members sm ON sm.subscription_id = x.subscription_id
                 WHERE x.alert_id = $1 AND x.role = 'subject' AND sm.user_id = $2`, [a.alert_id, uid]);
            if (rows.length) vikramsUsageBased.push(a);
        }
        check(vikramsUsageBased.length >= 1
              && vikramsUsageBased.every((a) => a.confidence === 'Low' && !a.counts_toward_savings
                                                && a.evidence.some((e) => e.evidence_type === 'silence' && e.source_ref === 'user:' + uid)),
              `Vikram's usage-based findings are Low with a silence row (${vikramsUsageBased.map((a) => a.fingerprint).join(', ')})`);
        check(iyer.filter((a) => !USAGE_BASED.includes(a.alert_type)).every((a) => a.confidence === 'High'),
              'coverage-based Iyer findings stay High');

        const after = await totals(c, 3);
        const want = expectedTotals(iyer, after.spend);
        check(after.found === want.found && after.look === want.look && after.low === want.low,
              `Low findings are left out of savings found (₹${before.found} → ₹${after.found}) and counted under worth a look (₹${after.look})`);
        const linkedin = iyer.find((a) => a.fingerprint === 'waste:26');
        check(linkedin.confidence === 'Low' && after.found === Math.round((before.found - linkedin.savings) * 100) / 100,
              `the LinkedIn waste finding (₹${linkedin.savings}) no longer counts toward savings found`);

        // optimizer steps under the same silence
        const { rows: [{ input }] } = await c.query('SELECT optimizer_input(3) AS input');
        check(input.silent_user_ids.includes(uid), 'optimizer input lists Vikram as silent');
        const r = optimize(input);
        const low = r.steps.filter((s) => s.confidence === 'Low');
        const lowSum = low.reduce((t, s) => t + s.saving, 0);
        check(low.length >= 1 && low.every((s) => s.action === 'cancel' && /Nobody on it has used/.test(s.reason)),
              `optimizer: cancels resting on Vikram's missing usage are Low (${low.map((s) => s.description).join('; ')})`);
        check(Math.abs(r.counted_saving - (r.saving - lowSum)) < 0.005 && r.counted_saving < r.saving,
              `optimizer: counted saving ₹${r.counted_saving} leaves out the Low steps (₹${Math.round(lowSum * 100) / 100}) of ₹${r.saving}`);
    } finally {
        await c.query('ROLLBACK');
        c.release();
    }

    const sharma = await readRun(await createRun(1));
    const downgrade = sharma.steps.find((s) => s.action === 'switch' && /^Downgrade/.test(s.reason));
    check(downgrade && downgrade.confidence === 'Medium', 'optimizer: the JioHotstar downgrade step is Medium');
    check(sharma.steps.filter((s) => s !== downgrade).every((s) => s.confidence === 'High')
          && sharma.counted_saving === sharma.monthly_saving,
          `optimizer: Sharma's other steps are High; counted saving ₹${sharma.counted_saving} (Medium still counts)`);

    // ------------------------------------------------------------ 5
    const t = await pool.connect();
    try {
        await t.query('BEGIN');
        await t.query('CALL refresh_usage_data_quality(2)');
        const { rows } = await t.query(
            `SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND classid = 7140 AND objid = 2 AND pid = pg_backend_pid()`);
        check(rows.length === 1, 'refresh_usage_data_quality takes the household lock');
        let rejected = false;
        await t.query('SAVEPOINT s');
        try {
            await t.query(`INSERT INTO finding_evidence (alert_id, evidence_type, source_ref, value, weight)
                           SELECT alert_id, 'silence', 'user:1', 'x', 1 FROM alerts LIMIT 1`);
        } catch (e) { rejected = e.code === '23514'; }
        await t.query('ROLLBACK TO SAVEPOINT s');
        check(rejected, 'a silence row with a positive weight is rejected');
        await t.query('SAVEPOINT s');
        rejected = false;
        try {
            await t.query(`UPDATE alerts SET confidence = 'Sure' WHERE alert_id = (SELECT MIN(alert_id) FROM alerts)`);
        } catch (e) { rejected = e.code === '23514'; }
        await t.query('ROLLBACK TO SAVEPOINT s');
        check(rejected, 'a confidence outside High / Medium / Low is rejected');
    } finally {
        await t.query('ROLLBACK');
        t.release();
    }

    const NEW_ROUTINES = ['monthly_equivalent', 'plans_at', 'entitlements_at', 'check_plan_price', 'household_spend_at',
        'path_label', 'entitlement_closure_at', 'refresh_member_needs', 'set_member_need', 'renewal_forecast',
        'check_run_reconciles', 'optimizer_input', 'optimizer_state_hash', 'apply_optimization',
        'refresh_usage_data_quality'];
    const { rows: jit } = await pool.query(
        `SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = ANY ($1) AND 'jit=off' = ANY (p.proconfig)`, [NEW_ROUTINES]);
    check(jit.length === NEW_ROUTINES.length, `all ${NEW_ROUTINES.length} v2 functions and procedures run with jit = off`);

    // ------------------------------------------------------------ 6. benchmark (FR-42)
    const count = async () => (await pool.query(
        `SELECT (SELECT COUNT(*) FROM households) || '/' || (SELECT COUNT(*) FROM users) || '/'
                || (SELECT COUNT(*) FROM subscriptions) || '/' || (SELECT COUNT(*) FROM usage_logs) AS n`)).rows[0].n;
    const before = await count();
    const rows = await benchmark({ sizes: [[5, 10], [8, 15]], households: 4, seed: 7 }, () => {});
    check(rows.length === 8, 'benchmark: generated 8 synthetic households (5x10 and 8x15)');
    check(rows.every((r) => r.v2_no_threshold >= r.v1_saving - 0.005),
          'benchmark: v2 saves at least as much as v1 on every one ('
          + rows.map((r) => `₹${r.v2_no_threshold} vs ₹${r.v1_saving}`).join(', ') + ')');
    check(rows.filter((r) => r.size === '5x10').every((r) => r.optimal && r.v2_ms < 2000),
          'benchmark: 5-member households are solved exactly, well under 2 s');
    check((await count()) === before, 'benchmark: the database is unchanged afterwards (rolled back)');

    console.log(`v2d checks: all ${passed} passed`);
}

main()
    .catch((err) => { console.error(err.message); process.exitCode = 1; })
    .finally(() => pool.end());
