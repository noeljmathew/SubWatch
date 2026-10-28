// Unit tests for optimizer.js on small hand-built households (no database).
//   node --test server/
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { optimize } = require('./optimizer');

// Build an optimizer_input-shaped document.
//   services: [id, name, passive?]
//   plans:    { id, service, name, tier, max, price, includes: [[serviceId, path]], purchasable }
//   subs:     [id, payer, plan, [members]]
//   needs:    [user, service]
function household({ users, services, plans, subs, needs, alerts = [] }) {
    return {
        household_id: 1,
        evaluated_on: '2026-10-28',
        users: users.map(([id, name]) => ({ user_id: id, name })),
        services: services.map(([id, name, passive]) => ({ service_id: id, name, is_passive: !!passive })),
        needs: needs.map(([u, s]) => ({ user_id: u, service_id: s, source: 'usage', covered_today: true })),
        subscriptions: subs.map(([id, payer, plan, members]) => ({
            subscription_id: id, payer_id: payer, plan_id: plan, member_ids: members,
        })),
        plans: plans.map((p) => ({
            plan_id: p.id, service_id: p.service, name: p.name, tier: p.tier || 'individual',
            max_members: p.max || 1, is_purchasable: p.purchasable !== false, monthly_price: p.price,
            covers: [{ service_id: p.service, depth: 0, path: [p.id] },
                     ...(p.includes || []).map(([s, path]) => ({ service_id: s, depth: path.length - 1, path }))],
        })),
        alerts,
    };
}

const strip = (r) => ({ ...r, elapsed_ms: 0, nodes: 0 });

// the PRD's worked example: Prime (₹299) includes Prime Video, standalone
// Prime Video ₹179, two YouTube Individual ₹149, Spotify ₹119
const PRD_SERVICES = [[1, 'Amazon Prime'], [2, 'Prime Video'], [3, 'YouTube Premium'], [4, 'Spotify']];
const PRD_PLANS = [
    { id: 10, service: 1, name: 'Monthly', tier: 'duo', max: 2, price: 299, includes: [[2, [10, 11]]] },
    { id: 11, service: 2, name: 'Included with Prime', tier: 'included', price: 0, purchasable: false },
    { id: 12, service: 2, name: 'Standalone', price: 179 },
    { id: 20, service: 3, name: 'Individual', price: 149 },
    { id: 21, service: 3, name: 'Family', tier: 'family', max: 5, price: 299 },
    { id: 30, service: 4, name: 'Individual', price: 119 },
];

test('PRD example: drops the covered Prime Video, keeps two YouTube Individual plans', () => {
    const r = optimize(household({
        users: [[1, 'Asha A'], [2, 'Bala B']],
        services: PRD_SERVICES,
        plans: PRD_PLANS,
        subs: [[100, 1, 10, [1]], [101, 1, 12, [1]], [102, 1, 20, [1]], [103, 2, 20, [2]], [104, 1, 30, [1]]],
        needs: [[1, 1], [1, 2], [1, 3], [2, 3], [1, 4]],
    }));
    assert.equal(r.cost_after, 299 + 149 + 149 + 119);
    assert.equal(r.steps.length, 1);
    assert.deepEqual([r.steps[0].action, r.steps[0].subscription_id], ['cancel', 101]);
    assert.deepEqual(r.steps[0].reason_path, [10, 11]);
    assert.equal(r.is_optimal, true);
});

test('PRD example: with a third YouTube member the Family plan wins', () => {
    const r = optimize(household({
        users: [[1, 'Asha A'], [2, 'Bala B'], [3, 'Chitra C']],
        services: PRD_SERVICES,
        plans: PRD_PLANS,
        subs: [[100, 1, 10, [1]], [101, 1, 12, [1]], [102, 1, 20, [1]], [103, 2, 20, [2]],
               [104, 1, 30, [1]], [105, 3, 20, [3]]],
        needs: [[1, 1], [1, 2], [1, 3], [2, 3], [3, 3], [1, 4]],
    }));
    assert.equal(r.cost_after, 299 + 299 + 119);
    const start = r.steps.find((s) => s.action === 'start');
    assert.equal(start.plan_id, 21);
    assert.deepEqual(start.user_ids, [1, 2, 3]);
    assert.ok(r.steps.find((s) => s.action === 'cancel' && s.subscription_id === 101), 'Prime Video still dropped');
});

test('no splitting: shared Netflix and YouTube Family are never broken into individual plans', () => {
    const netflix = optimize(household({
        users: [[1, 'A A'], [2, 'B B'], [3, 'C C'], [4, 'D D']],
        services: [[1, 'Netflix']],
        plans: [{ id: 1, service: 1, name: 'Premium', tier: 'family', max: 4, price: 649 },
                { id: 2, service: 1, name: 'Mobile', price: 149 }],
        subs: [[10, 1, 1, [1, 2, 3, 4]]],
        needs: [[1, 1], [2, 1], [3, 1], [4, 1]],
    }), { minSaving: 0 });
    assert.equal(netflix.steps.length, 0, 'four Mobile plans (₹596) would be cheaper, but that is a split');

    const youtube = optimize(household({
        users: [[1, 'A A'], [2, 'B B']],
        services: [[1, 'YouTube Premium']],
        plans: [{ id: 1, service: 1, name: 'Family', tier: 'family', max: 5, price: 299 },
                { id: 2, service: 1, name: 'Individual', price: 149 }],
        subs: [[10, 1, 1, [1, 2]]],
        needs: [[1, 1], [2, 1]],
    }), { minSaving: 0 });
    assert.equal(youtube.steps.length, 0, 'two Individual plans (₹298) would be a split');
});

test('MIN_SAVING: a change under ₹10/mo is skipped, and taken when the threshold is 0', () => {
    const input = household({
        users: [[1, 'A A'], [2, 'B B']],
        services: [[1, 'Spotify']],
        plans: [{ id: 1, service: 1, name: 'Individual', price: 119 },
                { id: 2, service: 1, name: 'Duo', tier: 'duo', max: 2, price: 229 }],
        subs: [[10, 1, 1, [1]], [11, 2, 1, [2]]],
        needs: [[1, 1], [2, 1]],
    });
    assert.equal(optimize(input).steps.length, 0, 'Duo saves only ₹9');
    const r = optimize(input, { minSaving: 0 });
    assert.equal(r.cost_after, 229);
});

test('passive: never cancelled outright; replaced only when the same people keep it', () => {
    const plans = [
        { id: 1, service: 1, name: 'Individual', price: 99 },
        { id: 2, service: 2, name: 'Monthly', price: 99 },
        { id: 3, service: 3, name: '50 GB', price: 75 },
        { id: 4, service: 4, name: 'Individual', price: 195,
          includes: [[1, [4, 5]], [2, [4, 6]], [3, [4, 7]]] },
    ];
    const services = [[1, 'Apple Music'], [2, 'Apple TV+'], [3, 'iCloud+', true], [4, 'Apple One']];

    // nobody "needs" the cloud plan (no usage logged), it still stays
    const alone = optimize(household({
        users: [[1, 'R R']], services, plans: plans.slice(0, 3),
        subs: [[10, 1, 3, [1]]], needs: [],
    }));
    assert.equal(alone.steps.length, 0);

    // one person: Apple One covers iCloud+ for them, so it may replace it
    const bundle = optimize(household({
        users: [[1, 'R R']], services, plans,
        subs: [[10, 1, 1, [1]], [11, 1, 2, [1]], [12, 1, 3, [1]]],
        needs: [[1, 1], [1, 2]],
    }));
    assert.equal(bundle.cost_after, 195);
    assert.deepEqual(bundle.steps.find((s) => s.subscription_id === 12).reason_path, [4, 7]);

    // two people on the cloud plan: Apple One Individual can't hold both, so
    // iCloud+ stays and the bundle isn't worth it
    const shared = optimize(household({
        users: [[1, 'R R'], [2, 'S S']], services,
        plans: [...plans.slice(0, 2), { ...plans[2], max: 2 }, plans[3]],
        subs: [[10, 1, 1, [1]], [11, 1, 2, [1]], [12, 1, 3, [1, 2]]],
        needs: [[1, 1], [1, 2]],
    }));
    assert.ok(!shared.steps.some((s) => s.subscription_id === 12), 'iCloud+ kept for both');
});

test('student plans are never recommended', () => {
    const r = optimize(household({
        users: [[1, 'A A']],
        services: [[1, 'Spotify']],
        plans: [{ id: 1, service: 1, name: 'Individual', price: 119 },
                { id: 2, service: 1, name: 'Student', tier: 'student', price: 59 }],
        subs: [[10, 1, 1, [1]]],
        needs: [[1, 1]],
    }));
    assert.equal(r.steps.length, 0);
});

test('downgrades are labelled', () => {
    const r = optimize(household({
        users: [[1, 'Dev D'], [2, 'Arjun A']],
        services: [[1, 'JioHotstar']],
        plans: [{ id: 1, service: 1, name: 'Super', tier: 'duo', max: 2, price: 99.67 },
                { id: 2, service: 1, name: 'Mobile', price: 49.67 }],
        subs: [[10, 1, 1, [1, 2]]],
        needs: [[1, 1]],                      // Arjun stopped using it
    }));
    assert.equal(r.steps.length, 1);
    assert.equal(r.steps[0].action, 'switch');
    assert.match(r.steps[0].reason, /^Downgrade: /);
    assert.equal(r.saving, 50);
});

test('capacity: a full plan takes nobody else', () => {
    const r = optimize(household({
        users: [[1, 'A A'], [2, 'B B'], [3, 'C C']],
        services: [[1, 'Spotify']],
        plans: [{ id: 1, service: 1, name: 'Individual', price: 119 },
                { id: 2, service: 1, name: 'Duo', tier: 'duo', max: 2, price: 149 }],
        subs: [[10, 1, 2, [1, 2]], [11, 3, 1, [3]]],
        needs: [[1, 1], [2, 1], [3, 1]],
    }));
    assert.equal(r.steps.length, 0);
});

test('same data, same answer', () => {
    const input = household({
        users: [[1, 'Asha A'], [2, 'Bala B'], [3, 'Chitra C']],
        services: PRD_SERVICES,
        plans: PRD_PLANS,
        subs: [[100, 1, 10, [1]], [101, 1, 12, [1]], [102, 1, 20, [1]], [103, 2, 20, [2]],
               [104, 1, 30, [1]], [105, 3, 20, [3]]],
        needs: [[1, 1], [1, 2], [1, 3], [2, 3], [3, 3], [1, 4]],
    });
    assert.deepEqual(strip(optimize(input)), strip(optimize(input)));
});

test('time cap: still returns a valid answer, marked as maybe not the cheapest', () => {
    const r = optimize(household({
        users: [[1, 'Asha A'], [2, 'Bala B']],
        services: PRD_SERVICES,
        plans: PRD_PLANS,
        subs: [[100, 1, 10, [1]], [101, 1, 12, [1]], [102, 1, 20, [1]], [103, 2, 20, [2]], [104, 1, 30, [1]]],
        needs: [[1, 1], [1, 2], [1, 3], [2, 3], [1, 4]],
    }), { timeCapMs: -1 });
    assert.equal(r.is_optimal, false);
    assert.ok(r.cost_after <= r.cost_before);
});

// random small households: branch and bound must find the same cost as the
// same search with no pruning at all
test('matches exhaustive search on 40 random small households', () => {
    let seed = 7;
    const rnd = (n) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; };

    for (let k = 0; k < 40; k++) {
        const nUsers = 2 + rnd(2);
        const users = Array.from({ length: nUsers }, (_, i) => [i + 1, 'U' + (i + 1) + ' X']);
        const services = [[1, 'S1'], [2, 'S2'], [3, 'S3'], [4, 'Cloud', true], [9, 'Bundle']];
        const plans = [];
        let pid = 1;
        const byService = {};
        for (const s of [1, 2, 3, 4]) {
            const base = 50 + rnd(100);
            byService[s] = [pid, pid + 1, pid + 2];
            plans.push({ id: pid++, service: s, name: 'Ind', price: base });
            plans.push({ id: pid++, service: s, name: 'Duo', tier: 'duo', max: 2, price: base + 20 + rnd(80) });
            plans.push({ id: pid++, service: s, name: 'Fam', tier: 'family', max: 4, price: base + 40 + rnd(120) });
        }
        const inc1 = pid++;
        const inc2 = pid++;
        plans.push({ id: inc1, service: 1, name: 'Inc', tier: 'included', price: 0, purchasable: false });
        plans.push({ id: inc2, service: 2, name: 'Inc', tier: 'included', price: 0, purchasable: false });
        const bundle = pid++;
        plans.push({ id: bundle, service: 9, name: 'Bundle', tier: 'family', max: 2 + rnd(3), price: 100 + rnd(150),
                     includes: [[1, [bundle, inc1]], [2, [bundle, inc2]]] });

        const subs = [];
        const needs = [];
        let sid = 100;
        for (const [u] of users) {
            for (const s of [1, 2, 3, 4]) {
                if (rnd(3) === 0) continue;
                subs.push([sid++, u, byService[s][0], [u]]);
                if (s !== 4) needs.push([u, s]);
            }
        }
        if (!subs.length) continue;
        const input = household({ users, services, plans, subs, needs });
        const fast = optimize(input, { minSaving: 0 });
        const slow = optimize(input, { minSaving: 0, exhaustive: true, timeCapMs: 60000 });
        assert.equal(slow.is_optimal, true, `household ${k}: exhaustive search finished`);
        assert.equal(fast.cost_after, slow.cost_after, `household ${k}`);
    }
});
