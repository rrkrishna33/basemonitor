# Collector: Backup status and SQL Agent health
# Captures backup freshness and recent job execution health

function Get-BackupAndAgentHealth {
    param(
        [string]$ConnectionString,
        [int]$InstanceId
    )

    $collectedAt = [DateTime]::UtcNow

    $backupSql = @"
WITH LatestBackup AS (
    SELECT
        database_name,
        type,
        backup_finish_date,
        ROW_NUMBER() OVER (PARTITION BY database_name, type ORDER BY backup_finish_date DESC) AS rn
    FROM msdb.dbo.backupset
    WHERE backup_finish_date IS NOT NULL
)
SELECT
    d.name                                                       AS DatabaseName,
    d.recovery_model_desc                                        AS RecoveryModel,
    MAX(CASE WHEN lb.type = 'D' AND lb.rn = 1 THEN lb.backup_finish_date END) AS LastFullBackupAt,
    MAX(CASE WHEN lb.type = 'I' AND lb.rn = 1 THEN lb.backup_finish_date END) AS LastDiffBackupAt,
    MAX(CASE WHEN lb.type = 'L' AND lb.rn = 1 THEN lb.backup_finish_date END) AS LastLogBackupAt
FROM sys.databases AS d
LEFT JOIN LatestBackup AS lb
    ON lb.database_name = d.name
GROUP BY d.name, d.recovery_model_desc
ORDER BY d.name;
"@

    $jobSql = @"
WITH LatestJobRuns AS (
    SELECT
        h.job_id,
        h.run_status,
        h.run_date,
        h.run_time,
        h.message,
        h.instance_id,
        ROW_NUMBER() OVER (PARTITION BY h.job_id ORDER BY h.instance_id DESC) AS rn
    FROM msdb.dbo.sysjobhistory AS h
)
SELECT
    j.name                                                       AS JobName,
    j.job_id                                                     AS JobId,
    lrun.run_status                                              AS LastRunStatus,
    CAST(CAST(lrun.run_date AS VARCHAR(8)) + ' ' +
         STUFF(STUFF(RIGHT('000000' + CAST(lrun.run_time AS VARCHAR(6)), 6), 3, 0, ':'), 6, 0, ':') AS DATETIME) AS LastRunAt,
    lrun.message                                                 AS LastRunMessage
FROM msdb.dbo.sysjobs AS j
LEFT JOIN LatestJobRuns AS lrun
    ON lrun.job_id = j.job_id
   AND lrun.rn = 1
ORDER BY j.name;
"@

    try {
        $conn = New-Object Microsoft.Data.SqlClient.SqlConnection($ConnectionString)
        $conn.Open()

        $backupStatus = [System.Collections.Generic.List[PSCustomObject]]::new()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $backupSql
        $cmd.CommandTimeout = 30
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $lastFull = if ($reader.IsDBNull($reader.GetOrdinal("LastFullBackupAt"))) { $null } else { [datetime]$reader["LastFullBackupAt"] }
            $lastDiff = if ($reader.IsDBNull($reader.GetOrdinal("LastDiffBackupAt"))) { $null } else { [datetime]$reader["LastDiffBackupAt"] }
            $lastLog = if ($reader.IsDBNull($reader.GetOrdinal("LastLogBackupAt"))) { $null } else { [datetime]$reader["LastLogBackupAt"] }

            $backupStatus.Add([PSCustomObject]@{
                InstanceId           = $InstanceId
                CollectedAt          = $collectedAt
                DatabaseName         = [string]$reader["DatabaseName"]
                RecoveryModel        = [string]$reader["RecoveryModel"]
                LastFullBackupAt     = $lastFull
                LastDiffBackupAt     = $lastDiff
                LastLogBackupAt      = $lastLog
                FullBackupAgeHours   = if ($lastFull) { [double]((New-TimeSpan -Start $lastFull -End $collectedAt).TotalHours) } else { [double]::NaN }
                DiffBackupAgeHours   = if ($lastDiff) { [double]((New-TimeSpan -Start $lastDiff -End $collectedAt).TotalHours) } else { [double]::NaN }
                LogBackupAgeHours    = if ($lastLog) { [double]((New-TimeSpan -Start $lastLog -End $collectedAt).TotalHours) } else { [double]::NaN }
            })
        }
        $reader.Close()

        $jobHealth = [System.Collections.Generic.List[PSCustomObject]]::new()
        $cmd.CommandText = $jobSql
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $jobHealth.Add([PSCustomObject]@{
                InstanceId           = $InstanceId
                CollectedAt          = $collectedAt
                JobName              = [string]$reader["JobName"]
                JobId                = if ($reader.IsDBNull($reader.GetOrdinal("JobId"))) { $null } else { [guid]$reader["JobId"] }
                LastRunStatus        = if ($reader.IsDBNull($reader.GetOrdinal("LastRunStatus"))) { $null } else { [int]$reader["LastRunStatus"] }
                LastRunAt            = if ($reader.IsDBNull($reader.GetOrdinal("LastRunAt"))) { $null } else { [datetime]$reader["LastRunAt"] }
                LastRunMessage       = if ($reader.IsDBNull($reader.GetOrdinal("LastRunMessage"))) { $null } else { [string]$reader["LastRunMessage"] }
            })
        }
        $reader.Close()
        $conn.Close()

        return [PSCustomObject]@{
            BackupStatus = $backupStatus
            AgentJobs = $jobHealth
        }
    }
    catch {
        Write-Warning "[$($MyInvocation.MyCommand)] Instance $InstanceId : $_"
        return [PSCustomObject]@{ BackupStatus = @(); AgentJobs = @() }
    }
    finally {
        if ($conn.State -ne 'Closed') { $conn.Close() }
    }
}
