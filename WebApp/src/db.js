const sql = require('mssql');
const path = require('path');
const fs = require('fs');

const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'config.json'), 'utf8'));

const poolPromise = new sql.ConnectionPool({
    server: cfg.db.server,
    database: cfg.db.database,
    user: cfg.db.user,
    password: cfg.db.password,
    options: cfg.db.options
}).connect();

// Attach a handler directly to poolPromise (not a derived chain) so Node does not
// treat a failed startup connection as an unhandled rejection and exit the process.
poolPromise.then(
    () => console.log(`[db] Connected to ${cfg.db.server}/${cfg.db.database}`),
    err => console.error('[db] Connection failed:', err.message)
);

async function query(text, params = {}) {
    const pool = await poolPromise;
    const request = pool.request();
    for (const [key, val] of Object.entries(params)) {
        if (typeof val === 'number' && Number.isInteger(val)) {
            request.input(key, sql.Int, val);
        } else {
            request.input(key, val);
        }
    }
    const result = await request.query(text);
    return result.recordset;
}

module.exports = { query, config: cfg };
