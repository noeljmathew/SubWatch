// SubWatch household optimizer (FR-29 to FR-32).
//
// Input: one household as optimizer_input() returns it (db/detection.sql).
// Output: the cheapest set of subscriptions that still covers every need, as
// ordered steps (start / switch / add_member / cancel) with a reason and a
// reason path each, and a verdict on every open v1 finding.
//
// The problem is a capacity-limited weighted set cover, so the search is
// branch and bound:
//   * a configuration is a list of plan instances, each with its members:
//     current subscriptions we keep (with their members, possibly plus a few)
//     and new plans we start
//   * every node picks the uncovered need with the fewest ways to cover it and
//     branches over those ways: join a kept plan with a free spot, keep a
//     current subscription, or start a new plan
//   * the upper bound starts at today's configuration (always valid) and a
//     greedy answer; a branch stops once its cost plus a lower bound can't
//     beat the best answer
//   * the search is time-boxed; when the cap hits, the best answer found so
//     far is returned with isOptimal = false
// Ties go to fewer changes, then to lower plan ids, so the same data always
// gives the same answer.
//
// Rules (from the PRD and the v1 detectors):
//   * every need covered today stays covered (needs no current plan covers are
//     reported, not acted on: the optimizer never suggests a new service)
//   * a passive subscription (phone plan, cloud storage) is never cancelled
//     outright: it may only go if each of its members still reaches that
//     service through another plan
//   * plan capacity is respected and only household members are placed
//   * no splitting: a service never ends up with more plans than it has now
//     (one shared Netflix never becomes four Mobile plans); a service with no
//     plan today, such as a bundle, may get one
//   * student plans are never recommended (there is no eligibility data, as
//     in v1); an existing student plan can be kept
//   * new plans in passive categories aren't suggested (v1's bundle rule)
//   * a change that saves less than MIN_SAVING a month isn't worth making
//
// Money is handled in paise (integers) inside, rupees outside.

'use strict';

// ₹/month: a group of changes that saves less than this is left out
const MIN_SAVING = 10;
// the exact search stops after this long and returns its best answer so far
const TIME_CAP_MS = 1500;

const KIND_ORDER = { join: 0, keep: 1, keepJoin: 2, new: 3 };

const paise = (x) => Math.round(Number(x) * 100);
const rupees = (p) => Math.round(p) / 100;

function inr(p) {
    return '₹' + Math.round(p / 100).toLocaleString('en-IN');
}

function humanList(items) {
    if (items.length <= 1) return items.join('');
    return items.slice(0, -1).join(', ') + ' and ' + items[items.length - 1];
}

// ---------------------------------------------------------------------------
// model: the input turned into maps and indexes the search can use
// ---------------------------------------------------------------------------
// opts.require: needs that must be covered even though no current plan covers
// them (a what-if repair restoring what a change took away). One that no
// plan in the input can cover at all is reported as unrepairable instead.
function buildModel(input, opts = {}) {
    const users = new Map(input.users.map((u) => [u.user_id, u.name]));
    const services = new Map(input.services.map((s) => [s.service_id, { name: s.name, isPassive: s.is_passive }]));

    const plans = new Map();
    for (const p of input.plans) {
        plans.set(p.plan_id, {
            id: p.plan_id,
            serviceId: p.service_id,
            name: p.name,
            tier: p.tier,
            max: p.max_members,
            purchasable: p.is_purchasable,
            price: p.monthly_price == null ? null : paise(p.monthly_price),
            covers: new Map((p.covers || []).map((c) => [c.service_id, { depth: c.depth, path: c.path }])),
        });
    }

    const subs = input.subscriptions
        .map((s) => {
            const plan = plans.get(s.plan_id);
            return {
                id: s.subscription_id,
                payer: s.payer_id,
                plan,
                members: new Set(s.member_ids),
                price: plan.price,
                passive: services.get(plan.serviceId).isPassive,
            };
        })
        .sort((a, b) => a.id - b.id);

    const coveredBySubs = (u, s) => subs.some((sub) => sub.members.has(u) && sub.plan.covers.has(s));

    // hard needs: everything covered today, plus "same service for the same
    // people" for every passive subscription
    const needs = [];
    const seen = new Set();
    const uncovered = [];
    const addNeed = (u, s, source) => {
        const key = u + ':' + s;
        if (seen.has(key)) return;
        seen.add(key);
        needs.push({ idx: needs.length, u, s, source });
    };
    // plans that may be started new, per service they cover
    const candidatesByService = new Map();
    const candidates = [...plans.values()]
        .filter((p) => p.purchasable && p.price != null && p.tier !== 'student'
                       && !services.get(p.serviceId).isPassive)
        .sort((a, b) => a.id - b.id);
    for (const p of candidates) {
        for (const s of p.covers.keys()) {
            if (!candidatesByService.has(s)) candidatesByService.set(s, []);
            candidatesByService.get(s).push(p);
        }
    }

    const required = new Set((opts.require || []).map((n) => n.user_id + ':' + n.service_id));
    const unrepairable = [];
    for (const n of input.needs) {
        const key = n.user_id + ':' + n.service_id;
        if (coveredBySubs(n.user_id, n.service_id)) {
            addNeed(n.user_id, n.service_id, n.source);
        } else if (required.has(key)) {
            if (candidatesByService.has(n.service_id) || subs.some((s) => s.plan.covers.has(n.service_id))) {
                addNeed(n.user_id, n.service_id, n.source);
            } else {
                unrepairable.push({ user_id: n.user_id, service_id: n.service_id, source: n.source });
            }
        } else {
            uncovered.push({ user_id: n.user_id, service_id: n.service_id, source: n.source });
        }
    }
    for (const sub of subs) {
        if (!sub.passive) continue;
        for (const m of [...sub.members].sort((a, b) => a - b)) addNeed(m, sub.plan.serviceId, 'passive_subscription');
    }

    const needsByUser = new Map();
    for (const n of needs) {
        if (!needsByUser.has(n.u)) needsByUser.set(n.u, []);
        needsByUser.get(n.u).push(n);
    }

    // no splitting: a service never ends up with more plans than it has
    // today. A service with none today (a bundle like Apple One) may get one.
    const planLimit = new Map();
    for (const sub of subs) planLimit.set(sub.plan.serviceId, (planLimit.get(sub.plan.serviceId) || 0) + 1);
    const limitOf = (serviceId) => Math.max(planLimit.get(serviceId) || 0, 1);

    const currentCost = subs.reduce((t, s) => t + s.price, 0);
    const currentValid = needs.every((n) => coveredBySubs(n.u, n.s));
    return { input, users, services, plans, subs, needs, needsByUser, candidatesByService, uncovered,
             unrepairable, currentCost, currentValid, limitOf };
}

// ---------------------------------------------------------------------------
// search state: chosen instances and how many of them cover each need
// ---------------------------------------------------------------------------
class State {
    constructor(model) {
        this.model = model;
        this.chosen = [];                     // { plan, members: Set, sub: existing sub or null, added: [] }
        this.chosenSubs = new Set();
        this.cover = new Int32Array(model.needs.length);
        this.perService = new Map();          // chosen plans per service (the no-splitting rule)
    }

    roomFor(plan) {
        return (this.perService.get(plan.serviceId) || 0) < this.model.limitOf(plan.serviceId);
    }

    bump(inst, users, d) {
        for (const u of users) {
            for (const n of this.model.needsByUser.get(u) || []) {
                if (inst.plan.covers.has(n.s)) this.cover[n.idx] += d;
            }
        }
    }

    // ways to cover need n, cheapest first, in a fixed order
    options(n, dominance = true) {
        const opts = [];
        for (const inst of this.chosen) {
            if (inst.plan.covers.has(n.s) && !inst.members.has(n.u) && inst.members.size < inst.plan.max) {
                opts.push({ kind: 'join', inst, cost: 0, changes: inst.sub ? 1 : 0, planId: inst.plan.id, subId: inst.sub ? inst.sub.id : 0 });
            }
        }
        for (const sub of this.model.subs) {
            if (this.chosenSubs.has(sub.id) || !sub.plan.covers.has(n.s) || !this.roomFor(sub.plan)) continue;
            if (sub.members.has(n.u)) {
                opts.push({ kind: 'keep', sub, cost: sub.price, changes: 0, planId: sub.plan.id, subId: sub.id });
            } else if (sub.members.size < sub.plan.max) {
                opts.push({ kind: 'keepJoin', sub, cost: sub.price, changes: 1, planId: sub.plan.id, subId: sub.id });
            }
        }
        for (const plan of this.model.candidatesByService.get(n.s) || []) {
            if (!this.roomFor(plan)) continue;
            // a second copy of a plan we already started, while that one still
            // has room, can't do better than joining it
            if (dominance && this.chosen.some((i) => !i.sub && i.plan === plan && i.members.size < plan.max)) continue;
            opts.push({ kind: 'new', plan, cost: plan.price, changes: 1, planId: plan.id, subId: 0 });
        }
        opts.sort((a, b) => a.cost - b.cost || KIND_ORDER[a.kind] - KIND_ORDER[b.kind]
                            || a.planId - b.planId || a.subId - b.subId);
        return opts;
    }

    apply(opt, n) {
        if (opt.kind === 'join') {
            opt.inst.members.add(n.u);
            if (opt.inst.sub) opt.inst.added.push(n.u);
            this.bump(opt.inst, [n.u], 1);
            return () => {
                this.bump(opt.inst, [n.u], -1);
                opt.inst.members.delete(n.u);
                if (opt.inst.sub) opt.inst.added.pop();
            };
        }
        let inst;
        if (opt.kind === 'keep' || opt.kind === 'keepJoin') {
            inst = { plan: opt.sub.plan, members: new Set(opt.sub.members), sub: opt.sub, added: [] };
            if (opt.kind === 'keepJoin') { inst.members.add(n.u); inst.added.push(n.u); }
            this.chosenSubs.add(opt.sub.id);
        } else {
            inst = { plan: opt.plan, members: new Set([n.u]), sub: null, added: [] };
        }
        this.chosen.push(inst);
        this.perService.set(inst.plan.serviceId, (this.perService.get(inst.plan.serviceId) || 0) + 1);
        this.bump(inst, inst.members, 1);
        return () => {
            this.bump(inst, inst.members, -1);
            this.perService.set(inst.plan.serviceId, this.perService.get(inst.plan.serviceId) - 1);
            this.chosen.pop();
            if (inst.sub) this.chosenSubs.delete(inst.sub.id);
        };
    }

    keepSub(sub) {
        return this.apply({ kind: 'keep', sub }, null);
    }

    uncoveredNeeds() {
        return this.model.needs.filter((n) => this.cover[n.idx] === 0);
    }

    snapshot(cost, changes) {
        const config = this.chosen.map((i) => ({
            plan: i.plan,
            sub: i.sub,
            members: [...i.members].sort((a, b) => a - b),
            added: [...i.added].sort((a, b) => a - b),
        }));
        const key = config.map((i) => i.plan.id).sort((a, b) => a - b);
        return { cost, changes, key, config };
    }
}

function better(a, b) {
    if (!b) return true;
    if (a.cost !== b.cost) return a.cost < b.cost;
    if (a.changes !== b.changes) return a.changes < b.changes;
    for (let i = 0; i < Math.min(a.key.length, b.key.length); i++) {
        if (a.key[i] !== b.key[i]) return a.key[i] < b.key[i];
    }
    return a.key.length < b.key.length;
}

// today's configuration: always valid, costs what the household pays now
function currentConfig(model) {
    const st = new State(model);
    for (const sub of model.subs) st.keepSub(sub);
    return st.snapshot(model.currentCost, 0);
}

function leafChanges(model, st, changes) {
    return changes + (model.subs.length - st.chosenSubs.size);
}

// greedy: keep taking the way of covering needs with the lowest cost per
// newly covered need until nothing is left uncovered
function greedy(model, pinned) {
    const st = new State(model);
    let cost = 0;
    let changes = 0;
    for (const sub of model.subs) if (pinned.has(sub.id)) { st.keepSub(sub); cost += sub.price; }
    for (;;) {
        const open = st.uncoveredNeeds();
        if (!open.length) break;
        let best = null;
        for (const n of open) {
            for (const opt of st.options(n)) {
                const users = opt.kind === 'keep' ? opt.sub.members
                    : opt.kind === 'keepJoin' ? new Set([...opt.sub.members, n.u]) : new Set([n.u]);
                const plan = opt.kind === 'join' ? opt.inst.plan : opt.kind === 'new' ? opt.plan : opt.sub.plan;
                let gain = 0;
                for (const u of users) {
                    for (const m of model.needsByUser.get(u) || []) {
                        if (st.cover[m.idx] === 0 && plan.covers.has(m.s)) gain++;
                    }
                }
                const score = opt.cost / gain;
                if (!best || score < best.score || (score === best.score && opt.cost < best.opt.cost)) {
                    best = { score, opt, n };
                }
            }
        }
        if (!best) return null;
        st.apply(best.opt, best.n);
        cost += best.opt.cost;
        changes += best.opt.changes;
    }
    return st.snapshot(cost, leafChanges(model, st, changes));
}

// branch and bound. opts.bound = false and opts.dominance = false turn it into
// an exhaustive search over the same branching (used by the tests as a check)
function search(model, pinned, deadline, opts = {}) {
    const useBound = opts.bound !== false;
    const dominance = opts.dominance !== false;
    // today's configuration is the first upper bound, unless a required need
    // (what-if repair) means it no longer covers everything
    let best = model.currentValid ? currentConfig(model) : null;
    const g = greedy(model, pinned);
    if (g && better(g, best)) best = g;

    const st = new State(model);
    let rootCost = 0;
    for (const sub of model.subs) if (pinned.has(sub.id)) { st.keepSub(sub); rootCost += sub.price; }

    let nodes = 0;
    let timedOut = false;

    const dfs = (cost, changes) => {
        if (timedOut) return;
        if ((++nodes & 255) === 0 && Date.now() > deadline) { timedOut = true; return; }

        let pick = null;
        let lb = 0;
        for (const n of model.needs) {
            if (st.cover[n.idx] !== 0) continue;
            const o = st.options(n, dominance);
            if (!o.length) return;                          // this need can no longer be covered
            if (o[0].cost > lb) lb = o[0].cost;
            if (!pick || o.length < pick.opts.length) pick = { n, opts: o };
        }
        if (!pick) {
            const cand = st.snapshot(cost, leafChanges(model, st, changes));
            if (better(cand, best)) best = cand;
            return;
        }
        if (useBound && best && (cost + lb > best.cost || (cost + lb === best.cost && changes >= best.changes))) return;

        for (const o of pick.opts) {
            const undo = st.apply(o, pick.n);
            dfs(cost + o.cost, changes + o.changes);
            undo();
            if (timedOut) return;
        }
    };

    if (Date.now() > deadline) timedOut = true;
    else dfs(rootCost, 0);
    return { best, optimal: !timedOut, nodes };
}

// ---------------------------------------------------------------------------
// which instance covers each need in a final configuration
// ---------------------------------------------------------------------------
function coveringInstance(config, u, s) {
    // prefer a plan kept as it is, then the shortest path, then config order
    let best = null;
    for (const inst of config) {
        if (!inst.members.includes(u) || !inst.plan.covers.has(s)) continue;
        const rank = [inst.sub && !inst.added.length ? 0 : 1, inst.plan.covers.get(s).depth];
        if (!best || rank[0] < best.rank[0] || (rank[0] === best.rank[0] && rank[1] < best.rank[1])) {
            best = { inst, rank };
        }
    }
    return best && best.inst;
}

// group the changes: a dropped subscription belongs with the new or extended
// plan that now covers what it used to cover
function changeGroups(model, config) {
    const keptIds = new Set(config.filter((i) => i.sub).map((i) => i.sub.id));
    const dropped = model.subs.filter((s) => !keptIds.has(s.id));
    const parent = new Map();
    const find = (x) => (parent.get(x) === x ? x : (parent.set(x, find(parent.get(x))), parent.get(x)));
    const union = (a, b) => parent.set(find(a), find(b));
    const unitOf = (inst) => (inst.sub ? 'k' + inst.sub.id : 'n' + config.indexOf(inst));

    for (const d of dropped) parent.set('d' + d.id, 'd' + d.id);
    for (const inst of config) {
        if (!inst.sub || inst.added.length) parent.set(unitOf(inst), unitOf(inst));
    }
    const links = new Map();     // dropped sub id -> instances that took over its needs
    for (const d of dropped) {
        links.set(d.id, []);
        for (const u of d.members) {
            for (const n of model.needsByUser.get(u) || []) {
                if (!d.plan.covers.has(n.s)) continue;
                const inst = coveringInstance(config, u, n.s);
                if (!inst) continue;
                if (!links.get(d.id).includes(inst)) links.get(d.id).push(inst);
                if (!inst.sub || inst.added.includes(u)) union('d' + d.id, unitOf(inst));
            }
        }
    }

    const groups = new Map();
    for (const unit of parent.keys()) {
        const root = find(unit);
        if (!groups.has(root)) groups.set(root, { dropped: [], created: [], saving: 0 });
        const g = groups.get(root);
        if (unit[0] === 'd') {
            const d = dropped.find((s) => 'd' + s.id === unit);
            g.dropped.push(d);
            g.saving += d.price;
        } else if (unit[0] === 'n') {
            const inst = config[Number(unit.slice(1))];
            g.created.push(inst);
            g.saving -= inst.plan.price;
        }
    }
    return { groups: [...groups.values()], dropped, links };
}

// ---------------------------------------------------------------------------
// steps: the difference between today and the chosen configuration
// ---------------------------------------------------------------------------
function buildSteps(model, config) {
    const { dropped, links } = changeGroups(model, config);
    const first = (u) => model.users.get(u).split(' ')[0];
    const names = (ids) => humanList(ids.map(first));
    const svc = (plan) => model.services.get(plan.serviceId).name;

    // payer of a new plan: whoever paid for the most expensive plan it replaces
    // (lowest subscription id on ties), otherwise its first member
    const created = config.filter((i) => !i.sub);
    for (const inst of created) {
        const replaced = dropped
            .filter((d) => links.get(d.id).includes(inst) && inst.members.includes(d.payer))
            .sort((a, b) => b.price - a.price || a.id - b.id);
        inst.payer = replaced.length ? replaced[0].payer : inst.members[0];
    }

    const steps = [];
    const switched = new Set();

    for (const inst of [...created].sort((a, b) => a.plan.id - b.plan.id || a.members[0] - b.members[0])) {
        const sameService = dropped.filter((d) => d.plan.serviceId === inst.plan.serviceId
                                                  && links.get(d.id).includes(inst));
        const others = inst.members.filter((u) => u !== inst.payer);
        if (sameService.length === 1 && sameService[0].payer === inst.payer && !switched.has(sameService[0].id)
            && created.filter((c) => links.get(sameService[0].id).includes(c)).length === 1) {
            const d = sameService[0];
            switched.add(d.id);
            const downgrade = inst.plan.max < d.plan.max;
            steps.push({
                action: 'switch', subscription_id: d.id, plan_id: inst.plan.id, payer_id: inst.payer,
                user_ids: inst.members, saving: d.price - inst.plan.price,
                description: `Switch ${first(d.payer)}'s ${svc(d.plan)} from ${d.plan.name} to ${inst.plan.name} (${inr(inst.plan.price)}/mo)`,
                reason: downgrade
                    ? `Downgrade: only ${names(inst.members)} ${inst.members.length === 1 ? 'needs' : 'need'} ${svc(d.plan)}, so the smaller ${inst.plan.name} plan is enough`
                    : `Same service for ${names(inst.members)} on a cheaper plan`,
                reason_path: [inst.plan.id],
            });
            continue;
        }
        const coveredServices = [...new Set(dropped.filter((d) => links.get(d.id).includes(inst)).map((d) => svc(d.plan)))].sort();
        steps.push({
            action: 'start', subscription_id: null, plan_id: inst.plan.id, payer_id: inst.payer,
            user_ids: inst.members, saving: -inst.plan.price,
            description: `Start ${svc(inst.plan)} ${inst.plan.name} (${inr(inst.plan.price)}/mo), paid by ${first(inst.payer)}`
                         + (others.length ? `, shared with ${names(others)}` : ''),
            reason: coveredServices.length > 1
                ? `One plan covers ${humanList(coveredServices)} for ${names(inst.members)}`
                : `Covers ${coveredServices[0] || svc(inst.plan)} for ${names(inst.members)} for less than they pay now`,
            reason_path: [inst.plan.id],
        });
    }

    for (const inst of config.filter((i) => i.sub && i.added.length).sort((a, b) => a.sub.id - b.sub.id)) {
        for (const u of inst.added) {
            steps.push({
                action: 'add_member', subscription_id: inst.sub.id, plan_id: null, payer_id: null,
                user_ids: [u], saving: 0,
                description: `Add ${first(u)} to ${first(inst.sub.payer)}'s ${svc(inst.plan)} ${inst.plan.name}`,
                reason: `It has a free spot (${inst.sub.members.size} of ${inst.plan.max} used), so ${first(u)} doesn't need a separate plan`,
                reason_path: [inst.plan.id],
            });
        }
    }

    for (const d of dropped.filter((x) => !switched.has(x.id)).sort((a, b) => b.price - a.price || a.id - b.id)) {
        // explain with the people who needed this plan's own service, if any
        const own = d.plan.serviceId;
        const needers = [...d.members].filter((u) => (model.needsByUser.get(u) || []).some((n) => n.s === own)).sort((a, b) => a - b);
        let reason;
        let path = null;
        if (needers.length) {
            const insts = needers.map((u) => coveringInstance(config, u, own));
            const inst = insts[0];
            path = inst.plan.covers.get(own).path;
            if (needers.length > 1 && insts.every((i) => !i.sub) && new Set(insts).size === insts.length) {
                reason = `${names(needers)} each get ${svc(d.plan)} on their own new ${inst.plan.name} plan`;
            } else {
                const via = inst.sub
                    ? `${first(inst.sub.payer)}'s ${svc(inst.plan)} (${inst.plan.name})`
                    : `the new ${svc(inst.plan)} ${inst.plan.name}`;
                reason = `${names(needers)} ${needers.length === 1 ? 'gets' : 'get'} ${svc(d.plan)} through ${via}`;
            }
        } else {
            reason = `Nobody on it has used ${svc(d.plan)} in the last 30 days`;
        }
        steps.push({
            action: 'cancel', subscription_id: d.id, plan_id: null, payer_id: null, user_ids: [],
            saving: d.price,
            description: `Cancel ${first(d.payer)}'s ${svc(d.plan)} (${d.plan.name}), ${inr(d.price)}/mo`,
            reason, reason_path: path,
        });
    }

    return steps.map((s, i) => ({ step_no: i + 1, ...s }));
}

// FR-32: what the run decided about each open v1 finding
function alertOutcomes(model, config, steps) {
    const keptIds = new Set(config.filter((i) => i.sub).map((i) => i.sub.id));
    const switchedIds = new Set(steps.filter((s) => s.action === 'switch').map((s) => s.subscription_id));
    const createdPlans = new Set(steps.filter((s) => s.action === 'start' || s.action === 'switch').map((s) => s.plan_id));
    const addedTo = new Map();
    for (const s of steps.filter((x) => x.action === 'add_member')) {
        if (!addedTo.has(s.subscription_id)) addedTo.set(s.subscription_id, new Set());
        addedTo.get(s.subscription_id).add(s.user_ids[0]);
    }
    const subById = new Map(model.subs.map((s) => [s.id, s]));

    return model.input.alerts.map((a) => {
        const kept = a.subject_ids.filter((id) => keptIds.has(id));
        let outcome;
        if (kept.length) {
            outcome = 'rejected';
        } else if (a.alert_type === 'spare_capacity') {
            const sub = subById.get(a.subject_ids[0]);
            const host = a.source_ids[0];
            outcome = sub && addedTo.has(host) && addedTo.get(host).has(sub.payer) ? 'adopted' : 'superseded';
        } else if (a.alert_type === 'consolidation' || a.alert_type === 'bundle') {
            outcome = createdPlans.has(a.recommended_plan_id) ? 'adopted' : 'superseded';
        } else {
            outcome = a.subject_ids.some((id) => switchedIds.has(id)) ? 'superseded' : 'adopted';
        }
        const note = {
            adopted: 'The run makes this change',
            superseded: 'The run replaces these subscriptions in a different, cheaper overall way',
            rejected: `The run keeps subscription${kept.length > 1 ? 's' : ''} ${kept.join(', ')}: someone still needs it, `
                      + 'or the change saves less than ₹' + MIN_SAVING + '/mo',
        }[outcome];
        return { alert_id: a.alert_id, outcome, alert_saving: a.savings == null ? null : Number(a.savings), note };
    });
}

// a configuration must cover every hard need, respect capacity, and only
// place household members; anything else is a bug, so it throws
function validate(model, config) {
    for (const n of model.needs) {
        if (!coveringInstance(config, n.u, n.s)) {
            throw new Error(`optimizer bug: need (${n.u}, ${n.s}) left uncovered`);
        }
    }
    for (const inst of config) {
        if (inst.members.length > inst.plan.max) throw new Error(`optimizer bug: plan ${inst.plan.id} over capacity`);
        if (inst.members.some((u) => !model.users.has(u))) throw new Error('optimizer bug: member outside the household');
        if (inst.sub && !inst.members.includes(inst.sub.payer)) throw new Error('optimizer bug: payer removed');
    }
    const perService = new Map();
    for (const inst of config) perService.set(inst.plan.serviceId, (perService.get(inst.plan.serviceId) || 0) + 1);
    for (const [s, count] of perService) {
        if (count > model.limitOf(s)) throw new Error(`optimizer bug: service ${s} split into ${count} plans`);
    }
}

// ---------------------------------------------------------------------------
// optimize — the entry point
//   opts.minSaving  ₹/month (default MIN_SAVING)
//   opts.timeCapMs  default TIME_CAP_MS
//   opts.exhaustive true: no bounds or dominance pruning (tests only)
// ---------------------------------------------------------------------------
function optimize(input, opts = {}) {
    const started = Date.now();
    const minSaving = paise(opts.minSaving ?? MIN_SAVING);
    const deadline = started + (opts.timeCapMs ?? TIME_CAP_MS);
    const searchOpts = opts.exhaustive ? { bound: false, dominance: false } : {};
    const model = buildModel(input, opts);

    // MIN_SAVING: every subscription the answer drops must be worth dropping
    // on its own. Its marginal saving is what the best answer costs with that
    // subscription kept ("pinned"), minus what it costs now. A plain
    // cancellation (nothing else had to change for it) saves exactly its
    // price; one that was replaced needs another search to measure. Under
    // MIN_SAVING, it stays pinned. Subscriptions are tried in id order and the
    // scan restarts after each pin, so the result doesn't depend on timing.
    const pinned = new Set();
    let optimal = true;
    let nodes = 0;
    let r = search(model, pinned, deadline, searchOpts);
    nodes += r.nodes;
    optimal = r.optimal;
    if (!r.best) throw new Error('optimizer: no configuration covers every required need within the plan limits');
    let changed = true;
    while (changed && Date.now() <= deadline) {
        changed = false;
        const { dropped, links } = changeGroups(model, r.best.config);
        for (const d of dropped) {
            if (pinned.has(d.id)) continue;
            const replaced = links.get(d.id).some((inst) => !inst.sub || inst.added.length);
            let alt = null;
            let marginal = d.price;
            if (replaced) {
                alt = search(model, new Set([...pinned, d.id]), deadline, searchOpts);
                nodes += alt.nodes;
                optimal = optimal && alt.optimal;
                if (!alt.best) continue;           // keeping it leaves no valid configuration
                marginal = alt.best.cost - r.best.cost;
            }
            if (marginal < minSaving) {
                pinned.add(d.id);
                r = alt || search(model, pinned, deadline, searchOpts);
                if (!alt) { nodes += r.nodes; optimal = optimal && r.optimal; }
                changed = true;
                break;
            }
        }
    }
    const result = r.best;

    validate(model, result.config);
    const steps = buildSteps(model, result.config);
    const costAfter = result.config.reduce((t, i) => t + i.plan.price, 0);
    const stepSaving = steps.reduce((t, s) => t + s.saving, 0);
    if (stepSaving !== model.currentCost - costAfter) throw new Error('optimizer bug: steps do not add up');

    return {
        household_id: input.household_id,
        evaluated_on: input.evaluated_on,
        cost_before: rupees(model.currentCost),
        cost_after: rupees(costAfter),
        saving: rupees(model.currentCost - costAfter),
        is_optimal: optimal,
        elapsed_ms: Date.now() - started,
        nodes,
        steps: steps.map((s) => ({ ...s, saving: rupees(s.saving) })),
        outcomes: alertOutcomes(model, result.config, steps),
        uncovered_needs: model.uncovered,
        unrepairable_needs: model.unrepairable,
        // every need in the input that the final configuration leaves uncovered
        final_uncovered: input.needs
            .filter((n) => !coveringInstance(result.config, n.user_id, n.service_id))
            .map((n) => ({ user_id: n.user_id, service_id: n.service_id, source: n.source })),
    };
}

module.exports = { optimize, MIN_SAVING, TIME_CAP_MS };
