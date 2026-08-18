# Collector: Backup status
# Captures backup freshness per database

function Get-BackupHealth {
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
        $conn.Close()

        return $backupStatus
    }
    catch {
        Write-Warning "[$($MyInvocation.MyCommand)] Instance $InstanceId : $_"
        return @()
    }
    finally {
        if ($null -ne $conn -and $conn.State -ne 'Closed') { $conn.Close() }
    }
}
