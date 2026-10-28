// Shared builder for the optimizer and what-if unit tests.
'use strict';

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
            // like optimizer_input(): only a purchasable plan covers its own service
            covers: [...(p.purchasable === false ? [] : [{ service_id: p.service, depth: 0, path: [p.id] }]),
                     ...(p.includes || []).map(([s, path]) => ({ service_id: s, depth: path.length - 1, path }))],
        })),
        alerts,
        inclusions: inclusionsOf(plans),
    };
}

// the entitlement edges implied by every includes path
function inclusionsOf(plans) {
    const serviceOf = new Map(plans.map((p) => [p.id, p.service]));
    const edges = new Map();
    for (const p of plans) {
        for (const [, path] of p.includes || []) {
            for (let i = 0; i + 1 < path.length; i++) {
                edges.set(path[i] + ':' + path[i + 1], {
                    parent_plan_id: path[i], included_plan_id: path[i + 1],
                    included_service_id: serviceOf.get(path[i + 1]),
                });
            }
        }
    }
    return [...edges.values()].sort((a, b) => a.parent_plan_id - b.parent_plan_id || a.included_plan_id - b.included_plan_id);
}

module.exports = { household };
