const express = require('express');
const router = express.Router();
const { query } = require('../db');

// GET /api/instances/:id/agent-jobs - latest collection cycle, failed jobs first
router.get('/instances/:id/agent-jobs', async (req, res) => {
    try {
        const rows = await query(
            `DECLARE @id INT = @instanceId;
             DECLARE @latest DATETIME2 = (SELECT MAX(CollectedAt) FROM dbo.AgentJobHealth WHERE InstanceId = @id);
             SELECT JobName, JobId, LastRunStatus, LastRunAt, LastRunMessage, CollectedAt
             FROM dbo.AgentJobHealth
             WHERE InstanceId = @id AND CollectedAt = @latest
             ORDER BY CASE WHEN LastRunStatus = 0 THEN 0 ELSE 1 END, JobName`,
            { instanceId: Number(req.params.id) }
        );
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

module.exports = router;
