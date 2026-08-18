const express = require('express');
const path = require('path');
const { config } = require('./src/db');

const app = express();

app.use(express.json());

app.use('/api', require('./src/routes/instances'));
app.use('/api', require('./src/routes/metrics'));
app.use('/api', require('./src/routes/backups'));
app.use('/api', require('./src/routes/agent'));
app.use('/api', require('./src/routes/queries'));
app.use('/api', require('./src/routes/indexhealth'));
app.use('/api', require('./src/routes/connections'));
app.use('/api', require('./src/routes/settings'));

app.get('/api/config', (req, res) => {
    res.json({ refreshIntervalSeconds: config.refreshIntervalSeconds, thresholds: config.thresholds });
});

app.use(express.static(path.join(__dirname, 'public')));

const port = config.port || 3000;
app.listen(port, () => {
    console.log(`SQL Monitor web dashboard running at http://localhost:${port}`);
});
