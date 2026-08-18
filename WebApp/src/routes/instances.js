const express = require('express');
const router = express.Router();
const { query, config } = require('../db');

function statusFor(row, th) {
    let status = 'Healthy';
    if (row.SqlCpuPercent >= th.cpuCriticalPercent) status = 'Critical';
    else if (row.SqlCpuPercent >= th.cpuWarningPercent && status === 'Healthy') status = 'Warning';

    if (row.WorstFullBackupAgeHours != null) {
        if (row.WorstFullBackupAgeHours >= th.fullBackupCriticalHours) status = 'Critical';
        else if (row.WorstFullBackupAgeHours >= th.fullBackupWarningHours && status !== 'Critical') status = 'Warning';
    }

    if (row.FailedJobCount > 0) status = 'Critical';

    if (row.BlockedSessions > 0 && status !== 'Critical') status = 'Warning';

    return status;
}

// GET /api/instances - overview list with latest health summary per instance
router.get('/instances', async (req, res) => {
    try {
        const rows = await query(`
            SELECT i.InstanceId, i.InstanceName, i.Tags, i.LastSeenAt,
                   sm.SqlCpuPercent, sm.SystemCpuPercent, sm.SqlMemoryUsedMB, sm.CollectedAt AS MetricsCollectedAt,
                   cs.TotalSessions, cs.BlockedSessions,
                   bk.WorstFullBackupAgeHours,
                   aj.FailedJobCount
            FROM dbo.MonitoredInstances i
            OUTER APPLY (
                SELECT TOP 1 SqlCpuPercent, SystemCpuPercent, SqlMemoryUsedMB, CollectedAt
                FROM dbo.SystemMetrics WHERE InstanceId = i.InstanceId ORDER BY CollectedAt DESC
            ) sm
            OUTER APPLY (
                SELECT TOP 1 TotalSessions, BlockedSessions
                FROM dbo.ConnectionSnapshots WHERE InstanceId = i.InstanceId ORDER BY CollectedAt DESC
            ) cs
            OUTER APPLY (
                SELECT MAX(FullBackupAgeHours) AS WorstFullBackupAgeHours
                FROM dbo.BackupStatus b
                WHERE b.InstanceId = i.InstanceId
                  AND b.CollectedAt = (SELECT MAX(CollectedAt) FROM dbo.BackupStatus b2 WHERE b2.InstanceId = i.InstanceId)
            ) bk
            OUTER APPLY (
                SELECT COUNT(*) AS FailedJobCount
                FROM dbo.AgentJobHealth a
                WHERE a.InstanceId = i.InstanceId
                  AND a.CollectedAt = (SELECT MAX(CollectedAt) FROM dbo.AgentJobHealth a2 WHERE a2.InstanceId = i.InstanceId)
                  AND a.LastRunStatus = 0
            ) aj
            ORDER BY i.InstanceName;
        `);

        const th = config.thresholds;
        const result = rows.map(r => ({ ...r, Status: statusFor(r, th) }));
        res.json(result);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// GET /api/instances/:id - single instance header info
router.get('/instances/:id', async (req, res) => {
    try {
        const rows = await query(
            `SELECT InstanceId, InstanceName, Tags, FirstSeenAt, LastSeenAt FROM dbo.MonitoredInstances WHERE InstanceId = @id`,
            { id: Number(req.params.id) }
        );
        if (!rows.length) return res.status(404).json({ error: 'Instance not found' });
        res.json(rows[0]);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// GET /api/instances/:id/health-snapshot - latest triage summary for one instance
router.get('/instances/:id/health-snapshot', async (req, res) => {
    try {
        const id = Number(req.params.id);
        const rows = await query(
            `SELECT i.InstanceId, i.InstanceName, i.Tags, i.LastSeenAt,
                    sm.SqlCpuPercent, sm.SystemCpuPercent, sm.SqlMemoryUsedMB, sm.CollectedAt AS MetricsCollectedAt,
                    cs.TotalSessions, cs.ActiveRequests, cs.BlockedSessions,
                    bk.WorstFullBackupAgeHours,
                    aj.FailedJobCount
             FROM dbo.MonitoredInstances i
             OUTER APPLY (
                 SELECT TOP 1 SqlCpuPercent, SystemCpuPercent, SqlMemoryUsedMB, CollectedAt
                 FROM dbo.SystemMetrics WHERE InstanceId = i.InstanceId ORDER BY CollectedAt DESC
             ) sm
             OUTER APPLY (
                 SELECT TOP 1 TotalSessions, ActiveRequests, BlockedSessions
                 FROM dbo.ConnectionSnapshots WHERE InstanceId = i.InstanceId ORDER BY CollectedAt DESC
             ) cs
             OUTER APPLY (
                 SELECT MAX(FullBackupAgeHours) AS WorstFullBackupAgeHours
                 FROM dbo.BackupStatus b
                 WHERE b.InstanceId = i.InstanceId
                   AND b.CollectedAt = (SELECT MAX(CollectedAt) FROM dbo.BackupStatus b2 WHERE b2.InstanceId = i.InstanceId)
             ) bk
             OUTER APPLY (
                 SELECT COUNT(*) AS FailedJobCount
                 FROM dbo.AgentJobHealth a
                 WHERE a.InstanceId = i.InstanceId
                   AND a.CollectedAt = (SELECT MAX(CollectedAt) FROM dbo.AgentJobHealth a2 WHERE a2.InstanceId = i.InstanceId)
                   AND a.LastRunStatus = 0
             ) aj
             WHERE i.InstanceId = @id`,
            { id }
        );

        if (!rows.length) return res.status(404).json({ error: 'Instance not found' });
        const row = rows[0];
        row.Status = statusFor(row, config.thresholds || {});
        res.json(row);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// GET /api/incidents?hours=24&top=60 - recent fleet incidents for timeline strip
router.get('/incidents', async (req, res) => {
    try {
        const hours = Math.max(1, Math.min(168, Number(req.query.hours) || 24));
        const top = Math.max(10, Math.min(200, Number(req.query.top) || 60));
        const th = config.thresholds || {};

        const rows = await query(`
            DECLARE @from DATETIME2 = DATEADD(HOUR, -@hours, SYSUTCDATETIME());

            SELECT TOP (@top)
                i.InstanceName,
                e.EventAt,
                e.EventType,
                e.Severity,
                e.Summary
            FROM (
                SELECT
                    aj.InstanceId,
                    aj.CollectedAt AS EventAt,
                    CAST('Agent Job Failure' AS NVARCHAR(64)) AS EventType,
                    CAST('Critical' AS NVARCHAR(16)) AS Severity,
                    CONCAT(COUNT(1), ' failed job', CASE WHEN COUNT(1) > 1 THEN 's' ELSE '' END) AS Summary
                FROM dbo.AgentJobHealth aj
                WHERE aj.CollectedAt >= @from
                  AND aj.LastRunStatus = 0
                GROUP BY aj.InstanceId, aj.CollectedAt

                UNION ALL

                SELECT
                    cs.InstanceId,
                    cs.CollectedAt AS EventAt,
                    CAST('Blocking Spike' AS NVARCHAR(64)) AS EventType,
                    CAST(CASE WHEN cs.BlockedSessions >= 5 THEN 'Critical' ELSE 'Warning' END AS NVARCHAR(16)) AS Severity,
                    CONCAT(cs.BlockedSessions, ' blocked session', CASE WHEN cs.BlockedSessions > 1 THEN 's' ELSE '' END) AS Summary
                FROM dbo.ConnectionSnapshots cs
                WHERE cs.CollectedAt >= @from
                  AND cs.BlockedSessions > 0

                UNION ALL

                SELECT
                    sm.InstanceId,
                    sm.CollectedAt AS EventAt,
                    CAST('SQL CPU High' AS NVARCHAR(64)) AS EventType,
                    CAST(CASE WHEN sm.SqlCpuPercent >= @cpuCrit THEN 'Critical' ELSE 'Warning' END AS NVARCHAR(16)) AS Severity,
                    CONCAT('SQL CPU ', sm.SqlCpuPercent, '%') AS Summary
                FROM dbo.SystemMetrics sm
                WHERE sm.CollectedAt >= @from
                  AND sm.SqlCpuPercent >= @cpuWarn

                UNION ALL

                SELECT
                    bs.InstanceId,
                    bs.CollectedAt AS EventAt,
                    CAST('Backup Staleness' AS NVARCHAR(64)) AS EventType,
                    CAST(CASE WHEN MAX(bs.FullBackupAgeHours) >= @fullCrit THEN 'Critical' ELSE 'Warning' END AS NVARCHAR(16)) AS Severity,
                    CONCAT('Oldest full backup age ', CAST(ROUND(MAX(bs.FullBackupAgeHours), 1) AS NVARCHAR(32)), 'h') AS Summary
                FROM dbo.BackupStatus bs
                WHERE bs.CollectedAt >= @from
                GROUP BY bs.InstanceId, bs.CollectedAt
                HAVING MAX(bs.FullBackupAgeHours) >= @fullWarn
            ) e
            JOIN dbo.MonitoredInstances i ON i.InstanceId = e.InstanceId
            ORDER BY e.EventAt DESC;
        `, {
            hours,
            top,
            cpuWarn: Number(th.cpuWarningPercent ?? 60),
            cpuCrit: Number(th.cpuCriticalPercent ?? 80),
            fullWarn: Number(th.fullBackupWarningHours ?? 20),
            fullCrit: Number(th.fullBackupCriticalHours ?? 24)
        });

        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

module.exports = router;
