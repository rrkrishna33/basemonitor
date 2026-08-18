const express = require('express');
const fs = require('fs');
const path = require('path');
const { config } = require('../db');

const router = express.Router();

const webConfigPath = path.join(__dirname, '..', '..', 'config.json');
const monitorConfigPath = path.join(__dirname, '..', '..', '..', 'Config', 'config.json');

function readJson(filePath) {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeJson(filePath, obj) {
    fs.writeFileSync(filePath, JSON.stringify(obj, null, 2));
}

function normalizeServer(server) {
    return {
        Name: String(server.Name || '').trim(),
        ConnectionString: String(server.ConnectionString || '').trim(),
        Tags: String(server.Tags || '').trim()
    };
}

router.get('/settings', (req, res) => {
    try {
        const monitorCfg = readJson(monitorConfigPath);
        const webCfg = readJson(webConfigPath);
        res.json({
            servers: (monitorCfg.MonitoredInstances || []).map(normalizeServer),
            alerts: webCfg.thresholds || {}
        });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

router.post('/settings/servers', (req, res) => {
    try {
        const name = String(req.body?.name || '').trim();
        const connectionString = String(req.body?.connectionString || '').trim();
        const tags = String(req.body?.tags || '').trim();

        if (!name) return res.status(400).json({ error: 'Server name is required.' });
        if (!connectionString) return res.status(400).json({ error: 'Connection string is required.' });

        const monitorCfg = readJson(monitorConfigPath);
        const servers = monitorCfg.MonitoredInstances || [];

        const exists = servers.some(s => String(s.Name || '').toLowerCase() === name.toLowerCase());
        if (exists) return res.status(409).json({ error: 'Server name already exists.' });

        servers.push({ Name: name, ConnectionString: connectionString, Tags: tags });
        monitorCfg.MonitoredInstances = servers;
        writeJson(monitorConfigPath, monitorCfg);

        res.json({ ok: true, servers: servers.map(normalizeServer) });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

router.delete('/settings/servers/:name', (req, res) => {
    try {
        const serverName = String(req.params.name || '').trim();
        const monitorCfg = readJson(monitorConfigPath);
        const servers = monitorCfg.MonitoredInstances || [];

        const filtered = servers.filter(s => String(s.Name || '').toLowerCase() !== serverName.toLowerCase());
        if (filtered.length === servers.length) {
            return res.status(404).json({ error: 'Server not found.' });
        }

        monitorCfg.MonitoredInstances = filtered;
        writeJson(monitorConfigPath, monitorCfg);

        res.json({ ok: true, servers: filtered.map(normalizeServer) });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

router.put('/settings/alerts', (req, res) => {
    try {
        const payload = req.body || {};
        const nextThresholds = {
            cpuWarningPercent: Number(payload.cpuWarningPercent),
            cpuCriticalPercent: Number(payload.cpuCriticalPercent),
            fullBackupWarningHours: Number(payload.fullBackupWarningHours),
            fullBackupCriticalHours: Number(payload.fullBackupCriticalHours),
            logBackupWarningHours: Number(payload.logBackupWarningHours),
            blockingCriticalMs: Number(payload.blockingCriticalMs)
        };

        const invalid = Object.values(nextThresholds).some(v => Number.isNaN(v));
        if (invalid) return res.status(400).json({ error: 'All alert threshold values must be numeric.' });

        const webCfg = readJson(webConfigPath);
        webCfg.thresholds = nextThresholds;
        writeJson(webConfigPath, webCfg);

        // Keep runtime config in sync so changes apply without restart.
        config.thresholds = nextThresholds;

        res.json({ ok: true, alerts: nextThresholds });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

module.exports = router;
