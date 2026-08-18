const express = require('express');
const router = express.Router();
const { query } = require('../db');

// GET /api/instances/:id/system-metrics?hours=24
router.get('/instances/:id/system-metrics', async (req, res) => {
    try {
        const hours = Math.min(Math.max(Number(req.query.hours) || 24, 1), 720);
        const rows = await query(
            `SELECT CollectedAt, SqlCpuPercent, SystemCpuPercent, TotalMemoryMB, AvailableMemoryMB, SqlMemoryUsedMB
             FROM dbo.SystemMetrics
             WHERE InstanceId = @id AND CollectedAt >= DATEADD(HOUR, -${hours}, SYSUTCDATETIME())
             ORDER BY CollectedAt ASC`,
            { id: Number(req.params.id) }
        );
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// GET /api/instances/:id/wait-stats?top=10 - top waits from the latest collection cycle
router.get('/instances/:id/wait-stats', async (req, res) => {
    try {
        const top = Math.min(Math.max(Number(req.query.top) || 10, 1), 100);
        const rows = await query(
            `DECLARE @id INT = @instanceId;
             DECLARE @latest DATETIME2 = (SELECT MAX(CollectedAt) FROM dbo.WaitStats WHERE InstanceId = @id);
             SELECT TOP (${top}) WaitType, WaitingTasksCount, WaitTimeMs, MaxWaitTimeMs, SignalWaitTimeMs, CollectedAt
             FROM dbo.WaitStats
             WHERE InstanceId = @id AND CollectedAt = @latest
             ORDER BY WaitTimeMs DESC`,
            { instanceId: Number(req.params.id) }
        );
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// GET /api/instances/:id/databases - latest size snapshot per database
router.get('/instances/:id/databases', async (req, res) => {
    try {
        const rows = await query(
            `WITH Ranked AS (
                SELECT *, ROW_NUMBER() OVER (PARTITION BY DatabaseName ORDER BY CollectedAt DESC) AS rn
                FROM dbo.DatabaseSizes WHERE InstanceId = @id
             )
             SELECT DatabaseName, State, RecoveryModel, DataSizeMB, LogSizeMB, FileCount, CollectedAt
             FROM Ranked WHERE rn = 1
             ORDER BY DataSizeMB DESC`,
            { id: Number(req.params.id) }
        );
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// GET /api/instances/:id/disk-io - latest collection cycle, worst latency first
router.get('/instances/:id/disk-io', async (req, res) => {
    try {
        const rows = await query(
            `DECLARE @id INT = @instanceId;
             DECLARE @latest DATETIME2 = (SELECT MAX(CollectedAt) FROM dbo.DiskIOStats WHERE InstanceId = @id);
             SELECT DatabaseName, PhysicalName, FileType, ReadStallMs, WriteStallMs, TotalStallMs,
                    NumReads, NumWrites, BytesRead, BytesWritten, AvgReadLatencyMs, AvgWriteLatencyMs, CollectedAt
             FROM dbo.DiskIOStats
             WHERE InstanceId = @id AND CollectedAt = @latest
             ORDER BY (AvgReadLatencyMs + AvgWriteLatencyMs) DESC`,
            { instanceId: Number(req.params.id) }
        );
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// GET /api/instances/:id/tempdb - latest collection cycle
router.get('/instances/:id/tempdb', async (req, res) => {
    try {
        const rows = await query(
            `DECLARE @id INT = @instanceId;
             DECLARE @latest DATETIME2 = (SELECT MAX(CollectedAt) FROM dbo.TempDbStats WHERE InstanceId = @id);
             SELECT FileName, PhysicalName, FileType, FileSizeMB, UnallocatedSpaceMB, UserObjectMB,
                    InternalObjectMB, VersionStoreMB, MixedExtentMB, GrowthMB, MaxSizeMB, IsPercentGrowth, CollectedAt
             FROM dbo.TempDbStats
             WHERE InstanceId = @id AND CollectedAt = @latest
             ORDER BY FileSizeMB DESC`,
            { instanceId: Number(req.params.id) }
        );
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// GET /api/instances/:id/log-stats - latest collection cycle
router.get('/instances/:id/log-stats', async (req, res) => {
    try {
        const rows = await query(
            `DECLARE @id INT = @instanceId;
             DECLARE @latest DATETIME2 = (SELECT MAX(CollectedAt) FROM dbo.LogFileStats WHERE InstanceId = @id);
             SELECT DatabaseName, FileName, RecoveryModel, LogSizeMB, LogUsedMB, VlfCount, GrowthMB, MaxSizeMB, IsPercentGrowth, CollectedAt
             FROM dbo.LogFileStats
             WHERE InstanceId = @id AND CollectedAt = @latest
             ORDER BY VlfCount DESC`,
            { instanceId: Number(req.params.id) }
        );
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

module.exports = router;
