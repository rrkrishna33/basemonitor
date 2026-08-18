const express = require('express');
const router = express.Router();
const { query } = require('../db');

// GET /api/instances/:id/top-queries - latest collection cycle, highest total CPU first
router.get('/instances/:id/top-queries', async (req, res) => {
    try {
        const rows = await query(
            `DECLARE @id INT = @instanceId;
             DECLARE @latest DATETIME2 = (SELECT MAX(CollectedAt) FROM dbo.TopQueries WHERE InstanceId = @id);
             SELECT TOP (50) DatabaseName, QueryText, AvgCpuUs, TotalCpuUs, ExecutionCount, AvgDurationUs,
                    AvgLogicalReads, AvgPhysicalReads, AvgLogicalWrites, LastExecutedAt, CollectedAt
             FROM dbo.TopQueries
             WHERE InstanceId = @id AND CollectedAt = @latest
             ORDER BY TotalCpuUs DESC`,
            { instanceId: Number(req.params.id) }
        );
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

module.exports = router;
