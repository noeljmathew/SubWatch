const express = require('express');
const cors = require('cors');
const path = require('path');
require('dotenv').config({ quiet: true });

const { pool } = require('./db');

const app = express();
app.use(cors());
app.use(express.json({ limit: '5mb' }));   // bank statements can be a few thousand rows

app.use('/api/households', require('./routes/households'));
app.use('/api', require('./routes/subscriptions'));
app.use('/api', require('./routes/alerts'));
app.use('/api', require('./routes/insights'));
app.use('/api', require('./routes/catalog'));
app.use('/api', require('./routes/imports'));

app.get('/api/health', async (req, res) => {
    try {
        await pool.query('SELECT 1');
        res.json({ status: 'ok', db: 'connected' });
    } catch (err) {
        res.status(500).json({ status: 'error', db: 'unreachable', detail: err.message });
    }
});

app.use(express.static(path.join(__dirname, '..', 'public')));

// Database rule violations (from triggers and constraints) come back as 4xx
// with the database's own message, so the UI can show "this plan is full" etc.
const PG_ERRORS = {
    '23514': 409, // check_violation (also raised by our triggers)
    '23505': 409, // unique_violation
    '23503': 400, // foreign_key_violation
    '22P02': 400, // invalid input syntax
    '22007': 400, // invalid date format
    '22008': 400, // date out of range
};

app.use((err, req, res, next) => {
    const status = PG_ERRORS[err.code];
    if (status) return res.status(status).json({ error: err.message });
    console.error(err);
    res.status(500).json({ error: 'Internal server error', detail: err.message });
});

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => {
    console.log(`SubWatch running on http://localhost:${PORT}`);
});
