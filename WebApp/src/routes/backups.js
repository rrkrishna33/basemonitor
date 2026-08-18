const express = require('express');
const router = express.Router();
const { query } = require('../db');

// GET /api/instances/:id/backups - latest collection cycle, worst backup age first
router.get('/instances/:id/backups', async (req, res) => {
    try {
        const rows = await query(
            `DECLARE @id INT = @instanceId;
             DECLARE @latest DATETIME2 = (SELECT MAX(CollectedAt) FROM dbo.BackupStatus WHERE InstanceId = @id);
             SELECT DatabaseName, RecoveryModel, LastFullBackupAt, LastDiffBackupAt, LastLogBackupAt,
                    FullBackupAgeHours, DiffBackupAgeHours, LogBackupAgeHours, CollectedAt
             FROM dbo.BackupStatus
             WHERE InstanceId = @id AND CollectedAt = @latest
             ORDER BY FullBackupAgeHours DESC`,
            { instanceId: Number(req.params.id) }
        );
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

module.exports = router;
