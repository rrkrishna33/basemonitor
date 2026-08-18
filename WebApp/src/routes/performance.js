const express = require('express');
const router = express.Router();
const { query } = require('../db');

router.get('/performance', async (req, res) => {
    try {
        const top = Math.min(Math.max(Number(req.query.top) || 25, 5), 100);
        const [queries, procedures, waits, io] = await Promise.all([
            query(`
                WITH Latest AS (
                    SELECT InstanceId, MAX(CollectedAt) AS CollectedAt
                    FROM dbo.TopQueries GROUP BY InstanceId
                )
                SELECT TOP (${top}) i.InstanceId, i.InstanceName, q.DatabaseName, q.QueryText,
                       q.ExecutionCount, q.AvgCpuUs, q.TotalCpuUs, q.AvgDurationUs,
                       q.AvgLogicalReads, q.AvgPhysicalReads, q.AvgLogicalWrites, q.CollectedAt
                FROM dbo.TopQueries q
                INNER JOIN Latest l ON l.InstanceId = q.InstanceId AND l.CollectedAt = q.CollectedAt
                INNER JOIN dbo.MonitoredInstances i ON i.InstanceId = q.InstanceId
                ORDER BY q.TotalCpuUs DESC`, {}),
            query(`
                WITH Latest AS (
                    SELECT InstanceId, MAX(CollectedAt) AS CollectedAt
                    FROM dbo.TopQueries GROUP BY InstanceId
                )
                SELECT TOP (${top}) i.InstanceId, i.InstanceName, q.DatabaseName,
                       q.ProcedureSchema, q.ProcedureName,
                       SUM(q.TotalCpuUs) AS TotalCpuUs,
                       SUM(q.ExecutionCount) AS ExecutionCount,
                       MAX(q.AvgDurationUs) AS AvgDurationUs,
                       MAX(q.AvgLogicalReads) AS AvgLogicalReads,
                       MAX(q.QueryText) AS QueryText,
                       MAX(q.CollectedAt) AS CollectedAt
                FROM dbo.TopQueries q
                INNER JOIN Latest l ON l.InstanceId = q.InstanceId AND l.CollectedAt = q.CollectedAt
                INNER JOIN dbo.MonitoredInstances i ON i.InstanceId = q.InstanceId
                WHERE q.ProcedureName IS NOT NULL
                GROUP BY i.InstanceId, i.InstanceName, q.DatabaseName, q.ProcedureSchema, q.ProcedureName
                ORDER BY SUM(q.TotalCpuUs) DESC`, {}),
            query(`
                WITH Latest AS (
                    SELECT InstanceId, MAX(CollectedAt) AS CollectedAt
                    FROM dbo.WaitStats GROUP BY InstanceId
                )
                SELECT TOP (${top}) i.InstanceId, i.InstanceName, w.WaitType,
                       w.WaitingTasksCount, w.WaitTimeMs, w.MaxWaitTimeMs, w.SignalWaitTimeMs, w.CollectedAt
                FROM dbo.WaitStats w
                INNER JOIN Latest l ON l.InstanceId = w.InstanceId AND l.CollectedAt = w.CollectedAt
                INNER JOIN dbo.MonitoredInstances i ON i.InstanceId = w.InstanceId
                ORDER BY w.WaitTimeMs DESC`, {}),
            query(`
                WITH Latest AS (
                    SELECT InstanceId, MAX(CollectedAt) AS CollectedAt
                    FROM dbo.DiskIOStats GROUP BY InstanceId
                )
                SELECT TOP (${top}) i.InstanceId, i.InstanceName, d.DatabaseName,
                       d.PhysicalName, d.FileType, d.AvgReadLatencyMs, d.AvgWriteLatencyMs,
                       d.NumReads, d.NumWrites, d.BytesRead, d.BytesWritten, d.CollectedAt
                FROM dbo.DiskIOStats d
                INNER JOIN Latest l ON l.InstanceId = d.InstanceId AND l.CollectedAt = d.CollectedAt
                INNER JOIN dbo.MonitoredInstances i ON i.InstanceId = d.InstanceId
                ORDER BY (d.AvgReadLatencyMs + d.AvgWriteLatencyMs) DESC`, {})
        ]);

        res.json({ queries, procedures, waits, io });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

module.exports = router;
