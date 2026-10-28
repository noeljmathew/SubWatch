// Unit tests for whatif.js on small hand-built households (no database).
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { simulate, recomputeCovers, BadChange } = require('./whatif');
const { household } = require('./test-helpers');

// a phone plan (passive) that includes Prime, which includes Prime Video
const SERVICES = [[1, 'Phone', true], [2, 'Amazon Prime'], [3, 'Prime Video'], [4, 'Netflix']];
const PLANS = [
    { id: 1, service: 1, name: 'Family', tier: 'family', max: 4, price: 999,
      includes: [[2, [1, 2]], [3, [1, 2, 3]]] },
    { id: 2, service: 2, name: 'Included', tier: 'included', price: 0, purchasable: false,
      includes: [[3, [2, 3]]] },
    { id: 3, service: 3, name: 'Included', tier: 'included', price: 0, purchasable: false },
    { id: 4, service: 2, name: 'Monthly', tier: 'duo', max: 2, price: 299, includes: [[3, [4, 3]]] },
    { id: 5, service: 3, name: 'Standalone', price: 179 },
    { id: 6, service: 4, name: 'Premium', tier: 'family', max: 4, price: 649 },
    { id: 7, service: 4, name: 'Mobile', price: 149 },
];
const base = () => household({
    users: [[1, 'Asha A'], [2, 'Bala B'], [3, 'Chitra C']],
    services: SERVICES,
    plans: PLANS,
    subs: [[10, 1, 1, [1, 2]], [11, 3, 6, [1, 2, 3]]],
    needs: [[1, 3], [2, 4], [1, 4], [3, 4]],          // Asha watches Prime Video; everyone Netflix
});

test('the input is never modified', () => {
    const input = base();
    const copy = JSON.parse(JSON.stringify(input));
    for (const change of [
        { type: 'remove_inclusion', parent_plan_id: 1, included_plan_id: 2 },
        { type: 'remove_member', user_id: 3 },
        { type: 'cancel_subscription', subscription_id: 11 },
        { type: 'raise_price', plan_id: 6, monthly_price: 699 },
    ]) simulate(input, change);
    assert.deepEqual(input, copy);
});

test('removing an inclusion shows who loses what, and repairs the needed part', () => {
    const r = simulate(base(), { type: 'remove_inclusion', parent_plan_id: 1, included_plan_id: 2 });
    assert.deepEqual(r.affected_members.map((a) => [a.user_id, a.services_lost.sort()]),
                     [[1, ['Amazon Prime', 'Prime Video']], [2, ['Amazon Prime', 'Prime Video']]]);
    assert.deepEqual(r.coverage_lost.filter((l) => l.needed).map((l) => [l.user_id, l.service]), [[1, 'Prime Video']]);
    assert.equal(r.cost.change, 0);
    assert.equal(r.repair.needs_restored, 1);
    assert.deepEqual(r.repair.needs_not_restored, []);
    // cheapest way back for Asha alone: standalone Prime Video (₹179) beats Prime (₹299)
    assert.ok(r.repair.steps.some((s) => s.action === 'start' && s.plan_id === 5));
});

test('a member moving out takes their plans; the others get theirs back', () => {
    const r = simulate(base(), { type: 'remove_member', user_id: 3 });     // Chitra pays for Netflix
    assert.deepEqual(r.coverage_lost.filter((l) => l.needed).map((l) => [l.user_id, l.service]),
                     [[1, 'Netflix'], [2, 'Netflix']]);
    assert.equal(r.cost.after_change, 999);
    assert.equal(r.repair.needs_restored, 2);
    // no splitting: one Netflix plan for both of them, not two Mobile plans
    assert.deepEqual(r.repair.steps.filter((s) => s.action === 'start').map((s) => [s.plan_id, s.user_ids]), [[6, [1, 2]]]);
});

test('a phone plan that leaves with its payer is restored for the others', () => {
    const input = base();
    // as in the database: everyone on a passive plan has a passive need for it
    input.needs.push({ user_id: 1, service_id: 1, source: 'passive', covered_today: true },
                     { user_id: 2, service_id: 1, source: 'passive', covered_today: true });
    const r = simulate(input, { type: 'remove_member', user_id: 1 });     // Asha pays for the phone plan
    assert.ok(r.coverage_lost.some((l) => l.user_id === 2 && l.service === 'Phone' && l.needed));
    assert.deepEqual(r.repair.needs_not_restored, []);
    assert.ok(r.repair.steps.some((s) => s.action === 'start' && s.plan_id === 1 && s.user_ids.includes(2)));
});

test('cancelling on purpose does not bring the service back', () => {
    const r = simulate(base(), { type: 'cancel_subscription', subscription_id: 11 });
    assert.ok(r.coverage_lost.filter((l) => l.service === 'Netflix').every((l) => l.given_up));
    assert.equal(r.repair.needs_restored, 0);
    assert.ok(!r.repair.steps.some((s) => s.action === 'start'));
});

test('a price rise marks who pays more', () => {
    const r = simulate(base(), { type: 'raise_price', plan_id: 6, monthly_price: 699 });
    assert.equal(r.cost.change, 50);
    assert.deepEqual(r.affected_members.map((a) => [a.user_id, a.pays_more]), [[1, true], [2, true], [3, true]]);
});

test('switching to a smaller plan keeps the payer and the lowest ids', () => {
    const r = simulate(base(), { type: 'switch_plan', subscription_id: 11, plan_id: 7 });
    assert.deepEqual(r.affected_members.map((a) => a.user_id), [1, 2]);       // Chitra (payer) keeps it
    assert.ok(r.coverage_lost.every((l) => l.given_up));
});

test('invalid changes are refused', () => {
    assert.throws(() => simulate(base(), { type: 'nope' }), BadChange);
    assert.throws(() => simulate(base(), { type: 'cancel_subscription', subscription_id: 99 }), BadChange);
    assert.throws(() => simulate(base(), { type: 'raise_price', plan_id: 6, monthly_price: 600 }), BadChange);
    assert.throws(() => simulate(base(), { type: 'remove_inclusion', parent_plan_id: 6, included_plan_id: 2 }), BadChange);
    assert.throws(() => simulate(base(), { type: 'switch_plan', subscription_id: 11, plan_id: 5 }), BadChange);
});

test('recomputed coverage equals the input coverage when nothing changed', () => {
    const input = base();
    const copy = JSON.parse(JSON.stringify(input));
    recomputeCovers(copy);
    const norm = (ps) => ps.map((p) => [p.plan_id, p.covers.map((c) => [c.service_id, c.depth, c.path])]);
    assert.deepEqual(norm(copy.plans), norm(input.plans));
});
