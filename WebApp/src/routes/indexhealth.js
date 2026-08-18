const express = require('express');
const router = express.Router();
const { query } = require('../db');

// GET /api/instances/:id/index-health - missing + unused + fragmentation, latest cycle each
router.get('/instances/:id/index-health', async (req, res) => {
    try {
        const id = Number(req.params.id);

        const missing = await query(
            `DECLARE @id INT = @instanceId;
             DECLARE @latest DATETIME2 = (SELECT MAX(CollectedAt) FROM dbo.MissingIndexStats WHERE InstanceId = @id);
             SELECT TOP (50) DatabaseName, EqualityColumns, InequalityColumns, IncludedColumns,
                    UserSeeks, AvgTotalUserCost, AvgUserImpact, LastUserSeek, CollectedAt
             FROM dbo.MissingIndexStats
             WHERE InstanceId = @id AND CollectedAt = @latest
             ORDER BY AvgUserImpact DESC`,
            { instanceId: id }
        );

        const unused = await query(
            `DECLARE @id INT = @instanceId;
             DECLARE @latest DATETIME2 = (SELECT MAX(CollectedAt) FROM dbo.UnusedIndexStats WHERE InstanceId = @id);
             SELECT TOP (50) DatabaseName, SchemaName, TableName, IndexName, IndexType,
                    UserSeeks, UserScans, UserLookups, UserUpdates, [RowCount], CollectedAt
             FROM dbo.UnusedIndexStats
             WHERE InstanceId = @id AND CollectedAt = @latest
             ORDER BY UserUpdates DESC`,
            { instanceId: id }
        );

        const fragmentation = await query(
            `DECLARE @id INT = @instanceId;
             DECLARE @latest DATETIME2 = (SELECT MAX(CollectedAt) FROM dbo.IndexFragStats WHERE InstanceId = @id);
             SELECT TOP (50) DatabaseName, TableName, IndexName, IndexType, FragmentationPercent, PageCount, RecordCount, CollectedAt
             FROM dbo.IndexFragStats
             WHERE InstanceId = @id AND CollectedAt = @latest
             ORDER BY FragmentationPercent DESC`,
            { instanceId: id }
        );

        res.json({ missing, unused, fragmentation });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

module.exports = router;
