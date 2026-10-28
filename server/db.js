const { Pool } = require('pg');
require('dotenv').config({ quiet: true });

const pool = new Pool({
    host: process.env.PGHOST,
    port: process.env.PGPORT,
    database: process.env.PGDATABASE,
    user: process.env.PGUSER,
    password: process.env.PGPASSWORD,
    options: '-c jit=off', // see the note at the end of schema.sql
});

pool.on('error', (err) => console.error('Unexpected error on idle Postgres client', err));

// Run a change to one household as a single transaction:
//   BEGIN → take the household lock → make the change → re-run the optimizer → COMMIT
// Taking the lock first means two changes to the same household queue up
// instead of deadlocking on each other's rows (see lock_household in detection.sql).
// If anything throws, everything is rolled back, including the change itself.
async function withHousehold(householdId, fn) {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        await client.query('SELECT lock_household($1)', [householdId]);
        const result = await fn(client);
        await client.query('CALL refresh_alerts($1)', [householdId]);
        await client.query('COMMIT');
        return result;
    } catch (err) {
        await client.query('ROLLBACK');
        throw err;
    } finally {
        client.release();
    }
}

// household that a subscription belongs to (via its payer)
async function householdOfSubscription(subscriptionId) {
    const { rows } = await pool.query(
        `SELECT hm.household_id FROM subscriptions s
         JOIN household_members hm ON hm.user_id = s.payer_id
         WHERE s.subscription_id = $1`,
        [subscriptionId]
    );
    return rows[0] ? rows[0].household_id : null;
}

module.exports = { pool, withHousehold, householdOfSubscription };
