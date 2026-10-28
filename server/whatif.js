// SubWatch what-if simulator (FR-34, FR-35).
//
// A scenario is one hypothetical change, applied to a copy of the household's
// optimizer_input() document in memory. Live tables are never touched. For
// each scenario it reports:
//   affected_members  who loses access to something (or pays more)
//   coverage_lost     every (member, service) the change takes away, and
//                     whether that member needs it
//   cost              monthly cost today, right after the change, and the
//                     difference
//   repair            the cheapest way back: optimize() on the changed input,
//                     required to restore every lost need, compared with the
//                     household as it is today
//
// Change types (change = { type, ...params }):
//   cancel_subscription { subscription_id }
//   switch_plan         { subscription_id, plan_id }  another plan of the same
//                       service; if it holds fewer people, the payer stays and
//                       the other members with the lowest ids keep their places
//   remove_member       { user_id }  they move out: the plans they pay for go
//                       with them, and they leave everyone else's plans
//   remove_inclusion    { parent_plan_id, included_plan_id }  e.g. the phone plan
//                       drops Prime; coverage is recomputed from the edges
//   raise_price         { plan_id, monthly_price }  a new, higher monthly price
//
// Needs for the service someone deliberately cancels (or switches away from,
// or moves out with) are not restored by the repair; the user chose that.
// Everything else that was needed and covered before must be covered again.
'use strict';

const { optimize } = require('./optimizer');

const CHANGE_TYPES = ['cancel_subscription', 'switch_plan', 'remove_member', 'remove_inclusion', 'raise_price'];

class BadChange extends Error {}

const clone = (x) => JSON.parse(JSON.stringify(x));
const round2 = (x) => Math.round(x * 100) / 100;
const lexLess = (a, b) => {
    for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return a[i] < b[i];
    return a.length < b.length;
};

// every plan's covers, rebuilt from its own service plus the inclusion edges:
// shortest path per service, ties to the smaller path, exactly as
// optimizer_input() does in SQL (DISTINCT ON ... ORDER BY depth, path)
function recomputeCovers(input) {
    const edges = new Map();
    for (const e of input.inclusions) {
        if (!edges.has(e.parent_plan_id)) edges.set(e.parent_plan_id, []);
        edges.get(e.parent_plan_id).push(e);
    }
    for (const p of input.plans) {
        const best = new Map();
        const consider = (s, path) => {
            const cur = best.get(s);
            if (!cur || path.length < cur.length || (path.length === cur.length && lexLess(path, cur))) best.set(s, path);
        };
        if (p.is_purchasable) consider(p.service_id, [p.plan_id]);
        const walk = (planId, path) => {
            for (const e of edges.get(planId) || []) {
                if (path.includes(e.included_plan_id)) continue;
                const next = [...path, e.included_plan_id];
                consider(e.included_service_id, next);
                walk(e.included_plan_id, next);
            }
        };
        walk(p.plan_id, [p.plan_id]);
        p.covers = [...best.entries()]
            .sort((a, b) => a[0] - b[0])
            .map(([s, path]) => ({ service_id: s, depth: path.length - 1, path }));
    }
}

// (member, service) pairs anyone can use through an active subscription
function access(input) {
    const plans = new Map(input.plans.map((p) => [p.plan_id, p]));
    const pairs = new Set();
    for (const s of input.subscriptions) {
        for (const c of plans.get(s.plan_id).covers) {
            for (const u of s.member_ids) pairs.add(u + ':' + c.service_id);
        }
    }
    return pairs;
}

const costOf = (input) => {
    const plans = new Map(input.plans.map((p) => [p.plan_id, p]));
    return round2(input.subscriptions.reduce((t, s) => t + Number(plans.get(s.plan_id).monthly_price), 0));
};

// apply one change to a copy of the input. Returns the changed copy, a
// description, the (member, service) needs given up on purpose, and members
// who pay more without losing anything
function applyChange(input, change) {
    if (!change || !CHANGE_TYPES.includes(change.type)) {
        throw new BadChange(`change.type must be one of ${CHANGE_TYPES.join(', ')}`);
    }
    const changed = clone(input);
    const users = new Map(input.users.map((u) => [u.user_id, u.name]));
    const services = new Map(input.services.map((s) => [s.service_id, s.name]));
    const plans = new Map(changed.plans.map((p) => [p.plan_id, p]));
    const first = (u) => users.get(u).split(' ')[0];
    const label = (p) => `${services.get(p.service_id)} ${p.name}`;
    const findSub = (id) => {
        const s = changed.subscriptions.find((x) => x.subscription_id === Number(id));
        if (!s) throw new BadChange(`Subscription ${id} is not an active subscription in this household`);
        return s;
    };
    const givenUp = new Set();
    const paysMore = new Set();
    let description;

    switch (change.type) {
    case 'cancel_subscription': {
        const s = findSub(change.subscription_id);
        const p = plans.get(s.plan_id);
        changed.subscriptions = changed.subscriptions.filter((x) => x !== s);
        s.member_ids.forEach((u) => givenUp.add(u + ':' + p.service_id));
        description = `Cancel ${first(s.payer_id)}'s ${label(p)}`;
        break;
    }
    case 'switch_plan': {
        const s = findSub(change.subscription_id);
        const from = plans.get(s.plan_id);
        const to = plans.get(Number(change.plan_id));
        if (!to || !to.is_purchasable || to.monthly_price == null) {
            throw new BadChange(`Plan ${change.plan_id} can't be bought by this household`);
        }
        if (to.service_id !== from.service_id) throw new BadChange('switch_plan switches to another plan of the same service');
        if (to.plan_id === from.plan_id) throw new BadChange('That is already the plan');
        const others = s.member_ids.filter((u) => u !== s.payer_id).sort((a, b) => a - b);
        const keep = [s.payer_id, ...others.slice(0, to.max_members - 1)].sort((a, b) => a - b);
        s.member_ids.filter((u) => !keep.includes(u)).forEach((u) => givenUp.add(u + ':' + from.service_id));
        s.member_ids = keep;
        s.plan_id = to.plan_id;
        if (Number(to.monthly_price) > Number(from.monthly_price)) keep.forEach((u) => paysMore.add(u));
        description = `Switch ${first(s.payer_id)}'s ${services.get(from.service_id)} from ${from.name} to ${to.name}`;
        break;
    }
    case 'remove_member': {
        const u = Number(change.user_id);
        if (!users.has(u)) throw new BadChange(`User ${change.user_id} is not in this household`);
        if (changed.users.length === 1) throw new BadChange('The last member of a household cannot move out');
        const leaving = changed.subscriptions.filter((s) => s.payer_id === u);
        changed.subscriptions = changed.subscriptions.filter((s) => s.payer_id !== u);
        for (const s of changed.subscriptions) s.member_ids = s.member_ids.filter((m) => m !== u);
        changed.users = changed.users.filter((x) => x.user_id !== u);
        changed.needs = changed.needs.filter((n) => n.user_id !== u);
        description = `${first(u)} moves out` + (leaving.length
            ? `, taking ${leaving.map((s) => label(plans.get(s.plan_id))).join(', ')}` : '');
        break;
    }
    case 'remove_inclusion': {
        const parent = Number(change.parent_plan_id);
        const included = Number(change.included_plan_id);
        const before = changed.inclusions.length;
        changed.inclusions = changed.inclusions.filter((e) => !(e.parent_plan_id === parent && e.included_plan_id === included));
        if (changed.inclusions.length === before) throw new BadChange(`Plan ${parent} does not include plan ${included}`);
        recomputeCovers(changed);
        const inc = input.inclusions.find((e) => e.parent_plan_id === parent && e.included_plan_id === included);
        const parentPlan = plans.get(parent);
        description = `${parentPlan ? label(parentPlan) : 'Plan ' + parent} stops including ${services.get(inc.included_service_id)}`;
        break;
    }
    case 'raise_price': {
        const p = plans.get(Number(change.plan_id));
        if (!p || p.monthly_price == null) throw new BadChange(`Plan ${change.plan_id} has no price in this household's data`);
        const price = Number(change.monthly_price);
        if (!(price > Number(p.monthly_price))) {
            throw new BadChange(`monthly_price must be higher than the current ₹${p.monthly_price}`);
        }
        description = `${label(p)} goes from ₹${p.monthly_price} to ₹${price} a month`;
        p.monthly_price = price;
        changed.subscriptions.filter((s) => s.plan_id === p.plan_id).forEach((s) => s.member_ids.forEach((u) => paysMore.add(u)));
        break;
    }
    }
    return { changed, description, givenUp, paysMore };
}

// simulate(input, change) — see the top of this file
function simulate(input, change, opts = {}) {
    const { changed, description, givenUp, paysMore } = applyChange(input, change);
    const users = new Map(input.users.map((u) => [u.user_id, u.name]));
    const services = new Map(input.services.map((s) => [s.service_id, s.name]));
    const stillHere = new Set(changed.users.map((u) => u.user_id));
    const needed = new Set(changed.needs.map((n) => n.user_id + ':' + n.service_id));

    const before = access(input);
    const after = access(changed);
    const lost = [...before]
        .filter((k) => !after.has(k))
        .map((k) => k.split(':').map(Number))
        .filter(([u]) => stillHere.has(u))
        .sort((a, b) => a[0] - b[0] || a[1] - b[1])
        .map(([u, s]) => ({
            user_id: u, name: users.get(u), service_id: s, service: services.get(s),
            needed: needed.has(u + ':' + s), given_up: givenUp.has(u + ':' + s),
        }));

    const affected = new Map();
    for (const l of lost) {
        if (!affected.has(l.user_id)) affected.set(l.user_id, { user_id: l.user_id, name: l.name, services_lost: [], pays_more: false });
        affected.get(l.user_id).services_lost.push(l.service);
    }
    for (const u of paysMore) {
        if (!stillHere.has(u)) continue;
        if (!affected.has(u)) affected.set(u, { user_id: u, name: users.get(u), services_lost: [], pays_more: false });
        affected.get(u).pays_more = true;
    }

    const required = lost.filter((l) => l.needed && !l.given_up)
        .map((l) => ({ user_id: l.user_id, service_id: l.service_id }));
    const costBefore = costOf(input);
    const costChanged = costOf(changed);
    const repair = optimize(changed, { ...opts, require: required });
    const requiredKeys = new Set(required.map((n) => n.user_id + ':' + n.service_id));
    const notRestored = repair.final_uncovered.filter((n) => requiredKeys.has(n.user_id + ':' + n.service_id));

    return {
        change,
        description,
        affected_members: [...affected.values()].sort((a, b) => a.user_id - b.user_id),
        coverage_lost: lost,
        cost: {
            today: costBefore,
            after_change: costChanged,
            change: round2(costChanged - costBefore),
        },
        repair: {
            steps: repair.steps,
            cost_after: repair.cost_after,
            saving_vs_change: round2(costChanged - repair.cost_after),
            change_vs_today: round2(repair.cost_after - costBefore),
            needs_restored: required.length - notRestored.length,
            needs_not_restored: notRestored.map((n) => ({ ...n, name: users.get(n.user_id), service: services.get(n.service_id) })),
            is_optimal: repair.is_optimal,
            elapsed_ms: repair.elapsed_ms,
        },
        // the changed input, for callers that store the run (not sent to clients)
        _changed: changed,
        _required: required,
    };
}

module.exports = { simulate, applyChange, recomputeCovers, CHANGE_TYPES, BadChange };
