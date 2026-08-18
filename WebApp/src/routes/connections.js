const express = require('express');
const router = express.Router();
const { query } = require('../db');

// GET /api/instances/:id/connections - latest snapshot + blocking chains
router.get('/instances/:id/connections', async (req, res) => {
    try {
        const id = Number(req.params.id);

        const snapshotRows = await query(
            `SELECT TOP 1 TotalSessions, ActiveRequests, BlockedSessions, CollectedAt
             FROM dbo.ConnectionSnapshots WHERE InstanceId = @id ORDER BY CollectedAt DESC`,
            { id }
        );

        const blocking = await query(
            `DECLARE @id INT = @instanceId;
             DECLARE @latest DATETIME2 = (SELECT MAX(CollectedAt) FROM dbo.BlockingChains WHERE InstanceId = @id);
             SELECT BlockingSessionId, BlockedSessionId, WaitType, WaitTimeMs, BlockingStatement, BlockedStatement, CollectedAt
             FROM dbo.BlockingChains
             WHERE InstanceId = @id AND CollectedAt = @latest
             ORDER BY WaitTimeMs DESC`,
            { instanceId: id }
        );

        res.json({ snapshot: snapshotRows[0] || null, blocking });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

module.exports = router;
