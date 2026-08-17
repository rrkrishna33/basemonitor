# Storage: Save all collected metrics to the central SQL Server

function Invoke-SqlNonQuery {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, [string]$Sql, [hashtable]$Params = @{})
    $cmd = $Conn.CreateCommand()
    $cmd.CommandText    = $Sql
    $cmd.CommandTimeout = 60
    foreach ($kv in $Params.GetEnumerator()) {
        $p = $cmd.CreateParameter()
        $p.ParameterName = "@$($kv.Key)"
        $p.Value = if ($null -eq $kv.Value) { [DBNull]::Value } else { $kv.Value }
        $cmd.Parameters.Add($p) | Out-Null
    }
    $cmd.ExecuteNonQuery() | Out-Null
}

function Invoke-SqlScalar {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, [string]$Sql, [hashtable]$Params = @{})
    $cmd = $Conn.CreateCommand()
    $cmd.CommandText    = $Sql
    $cmd.CommandTimeout = 30
    foreach ($kv in $Params.GetEnumerator()) {
        $p = $cmd.CreateParameter()
        $p.ParameterName = "@$($kv.Key)"
        $p.Value = if ($null -eq $kv.Value) { [DBNull]::Value } else { $kv.Value }
        $cmd.Parameters.Add($p) | Out-Null
    }
    return $cmd.ExecuteScalar()
}

# ------------------------------------------------------------------
# Ensure (or update) an instance record; return its InstanceId
# ------------------------------------------------------------------
function Get-OrCreateInstanceId {
    param(
        [Microsoft.Data.SqlClient.SqlConnection]$Conn,
        [string]$InstanceName,
        [string]$Tags
    )

    $mergeSql = @"
MERGE dbo.MonitoredInstances AS target
USING (SELECT @InstanceName AS InstanceName, @Tags AS Tags) AS src
ON target.InstanceName = src.InstanceName
WHEN MATCHED THEN
    UPDATE SET LastSeenAt = SYSUTCDATETIME(), Tags = src.Tags
WHEN NOT MATCHED THEN
    INSERT (InstanceName, Tags) VALUES (src.InstanceName, src.Tags);
SELECT InstanceId FROM dbo.MonitoredInstances WHERE InstanceName = @InstanceName;
"@
    return [int](Invoke-SqlScalar -Conn $Conn -Sql $mergeSql -Params @{ InstanceName = $InstanceName; Tags = $Tags })
}

# ------------------------------------------------------------------
# Save-SystemMetric
# ------------------------------------------------------------------
function Save-SystemMetric {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Metric)
    if (-not $Metric) { return }
    $sql = @"
INSERT INTO dbo.SystemMetrics
    (InstanceId,CollectedAt,SystemCpuPercent,SqlCpuPercent,TotalMemoryMB,
     AvailableMemoryMB,SqlMemoryUsedMB,SqlMemoryTargetMB,MemoryState,PageFaults)
VALUES
    (@InstanceId,@CollectedAt,@SystemCpuPercent,@SqlCpuPercent,@TotalMemoryMB,
     @AvailableMemoryMB,@SqlMemoryUsedMB,@SqlMemoryTargetMB,@MemoryState,@PageFaults);
"@
    Invoke-SqlNonQuery -Conn $Conn -Sql $sql -Params @{
        InstanceId        = $Metric.InstanceId
        CollectedAt       = $Metric.CollectedAt
        SystemCpuPercent  = $Metric.SystemCpuPercent
        SqlCpuPercent     = $Metric.SqlCpuPercent
        TotalMemoryMB     = $Metric.TotalMemoryMB
        AvailableMemoryMB = $Metric.AvailableMemoryMB
        SqlMemoryUsedMB   = $Metric.SqlMemoryUsedMB
        SqlMemoryTargetMB = $Metric.SqlMemoryTargetMB
        MemoryState       = $Metric.MemoryState
        PageFaults        = $Metric.PageFaults
    }
}

# ------------------------------------------------------------------
# Save-WaitStats  (bulk insert via DataTable + SqlBulkCopy)
# ------------------------------------------------------------------
function Save-WaitStats {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $dt = New-Object System.Data.DataTable
    @("InstanceId","CollectedAt","WaitType","WaitingTasksCount","WaitTimeMs","MaxWaitTimeMs","SignalWaitTimeMs") |
        ForEach-Object { $dt.Columns.Add($_) | Out-Null }

    foreach ($r in $Rows) {
        $dt.Rows.Add($r.InstanceId,$r.CollectedAt,$r.WaitType,$r.WaitingTasksCount,$r.WaitTimeMs,$r.MaxWaitTimeMs,$r.SignalWaitTimeMs) | Out-Null
    }
    $bcp = New-Object Microsoft.Data.SqlClient.SqlBulkCopy($Conn)
    $bcp.DestinationTableName = "dbo.WaitStats"
    $bcp.BulkCopyTimeout = 60
    foreach ($col in $dt.Columns) { $bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName) | Out-Null }
    $bcp.WriteToServer($dt)
}

# ------------------------------------------------------------------
# Save-TopQueries
# ------------------------------------------------------------------
function Save-TopQueries {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $dt = New-Object System.Data.DataTable
    @("InstanceId","CollectedAt","DatabaseName","QueryText","AvgCpuUs","TotalCpuUs",
      "ExecutionCount","AvgDurationUs","AvgLogicalReads","AvgPhysicalReads","AvgLogicalWrites",
      "LastExecutedAt","PlanCreatedAt") | ForEach-Object { $dt.Columns.Add($_) | Out-Null }

    foreach ($r in $Rows) {
        $dt.Rows.Add(
            $r.InstanceId,$r.CollectedAt,$r.DatabaseName,$r.QueryText,
            $r.AvgCpuUs,$r.TotalCpuUs,$r.ExecutionCount,$r.AvgDurationUs,
            $r.AvgLogicalReads,$r.AvgPhysicalReads,$r.AvgLogicalWrites,
            $(if ($r.LastExecutedAt) { $r.LastExecutedAt } else { [DBNull]::Value }),
            $(if ($r.PlanCreatedAt)  { $r.PlanCreatedAt  } else { [DBNull]::Value })
        ) | Out-Null
    }
    $bcp = New-Object Microsoft.Data.SqlClient.SqlBulkCopy($Conn)
    $bcp.DestinationTableName = "dbo.TopQueries"
    $bcp.BulkCopyTimeout = 60
    foreach ($col in $dt.Columns) { $bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName) | Out-Null }
    $bcp.WriteToServer($dt)
}

# ------------------------------------------------------------------
# Save-DatabaseSizes
# ------------------------------------------------------------------
function Save-DatabaseSizes {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $dt = New-Object System.Data.DataTable
    @("InstanceId","CollectedAt","DatabaseName","State","RecoveryModel","DataSizeMB","LogSizeMB","FileCount") |
        ForEach-Object { $dt.Columns.Add($_) | Out-Null }

    foreach ($r in $Rows) {
        $dt.Rows.Add($r.InstanceId,$r.CollectedAt,$r.DatabaseName,$r.State,$r.RecoveryModel,$r.DataSizeMB,$r.LogSizeMB,$r.FileCount) | Out-Null
    }
    $bcp = New-Object Microsoft.Data.SqlClient.SqlBulkCopy($Conn)
    $bcp.DestinationTableName = "dbo.DatabaseSizes"
    $bcp.BulkCopyTimeout = 60
    foreach ($col in $dt.Columns) { $bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName) | Out-Null }
    $bcp.WriteToServer($dt)
}

# ------------------------------------------------------------------
# Save-ConnectionSnapshot + Blockings
# ------------------------------------------------------------------
function Save-ConnectionSnapshot {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Snapshot)
    if (-not $Snapshot) { return }
    $sql = @"
INSERT INTO dbo.ConnectionSnapshots
    (InstanceId,CollectedAt,TotalSessions,ActiveRequests,BlockedSessions,SessionDetailsJson)
VALUES
    (@InstanceId,@CollectedAt,@TotalSessions,@ActiveRequests,@BlockedSessions,@SessionDetailsJson);
"@
    Invoke-SqlNonQuery -Conn $Conn -Sql $sql -Params @{
        InstanceId         = $Snapshot.InstanceId
        CollectedAt        = $Snapshot.CollectedAt
        TotalSessions      = $Snapshot.TotalSessions
        ActiveRequests     = $Snapshot.ActiveRequests
        BlockedSessions    = $Snapshot.BlockedSessions
        SessionDetailsJson = $Snapshot.SessionDetailsJson
    }
}

function Save-BlockingChains {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $dt = New-Object System.Data.DataTable
    @("InstanceId","CollectedAt","BlockingSessionId","BlockedSessionId","WaitType","WaitTimeMs","BlockingStatement","BlockedStatement") |
        ForEach-Object { $dt.Columns.Add($_) | Out-Null }

    foreach ($r in $Rows) {
        $dt.Rows.Add($r.InstanceId,$r.CollectedAt,$r.BlockingSessionId,$r.BlockedSessionId,
            $(if ($r.WaitType)          { $r.WaitType          } else { [DBNull]::Value }),
            $r.WaitTimeMs,
            $(if ($r.BlockingStatement) { $r.BlockingStatement } else { [DBNull]::Value }),
            $(if ($r.BlockedStatement)  { $r.BlockedStatement  } else { [DBNull]::Value })
        ) | Out-Null
    }
    $bcp = New-Object Microsoft.Data.SqlClient.SqlBulkCopy($Conn)
    $bcp.DestinationTableName = "dbo.BlockingChains"
    $bcp.BulkCopyTimeout = 60
    foreach ($col in $dt.Columns) { $bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName) | Out-Null }
    $bcp.WriteToServer($dt)
}

# ------------------------------------------------------------------
# Save-DiskIOStats
# ------------------------------------------------------------------
function Save-DiskIOStats {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $dt = New-Object System.Data.DataTable
    @("InstanceId","CollectedAt","DatabaseName","PhysicalName","FileType",
      "ReadStallMs","WriteStallMs","TotalStallMs","NumReads","NumWrites",
      "BytesRead","BytesWritten","AvgReadLatencyMs","AvgWriteLatencyMs") |
        ForEach-Object { $dt.Columns.Add($_) | Out-Null }

    foreach ($r in $Rows) {
        $dt.Rows.Add($r.InstanceId,$r.CollectedAt,$r.DatabaseName,$r.PhysicalName,$r.FileType,
            $r.ReadStallMs,$r.WriteStallMs,$r.TotalStallMs,$r.NumReads,$r.NumWrites,
            $r.BytesRead,$r.BytesWritten,$r.AvgReadLatencyMs,$r.AvgWriteLatencyMs) | Out-Null
    }
    $bcp = New-Object Microsoft.Data.SqlClient.SqlBulkCopy($Conn)
    $bcp.DestinationTableName = "dbo.DiskIOStats"
    $bcp.BulkCopyTimeout = 60
    foreach ($col in $dt.Columns) { $bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName) | Out-Null }
    $bcp.WriteToServer($dt)
}

# ------------------------------------------------------------------
# Save-IndexFragStats
# ------------------------------------------------------------------
function Save-IndexFragStats {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $dt = New-Object System.Data.DataTable
    @("InstanceId","CollectedAt","DatabaseName","TableName","IndexName","IndexType",
      "FragmentationPercent","PageCount","RecordCount") |
        ForEach-Object { $dt.Columns.Add($_) | Out-Null }

    foreach ($r in $Rows) {
        $dt.Rows.Add($r.InstanceId,$r.CollectedAt,$r.DatabaseName,
            $(if ($r.TableName) { $r.TableName } else { [DBNull]::Value }),
            $(if ($r.IndexName) { $r.IndexName } else { [DBNull]::Value }),
            $r.IndexType,$r.FragmentationPercent,$r.PageCount,$r.RecordCount) | Out-Null
    }
    $bcp = New-Object Microsoft.Data.SqlClient.SqlBulkCopy($Conn)
    $bcp.DestinationTableName = "dbo.IndexFragStats"
    $bcp.BulkCopyTimeout = 120
    foreach ($col in $dt.Columns) { $bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName) | Out-Null }
    $bcp.WriteToServer($dt)
}

# ------------------------------------------------------------------
# Save-TempDbStats
# ------------------------------------------------------------------
function Save-TempDbStats {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $dt = New-Object System.Data.DataTable
    @("InstanceId","CollectedAt","DatabaseName","FileId","FileType","FileName","PhysicalName",
      "FileSizeMB","UnallocatedSpaceMB","UserObjectMB","InternalObjectMB","VersionStoreMB",
      "MixedExtentMB","GrowthMB","MaxSizeMB","IsPercentGrowth") |
        ForEach-Object { $dt.Columns.Add($_) | Out-Null }

    foreach ($r in $Rows) {
        $dt.Rows.Add(
            $r.InstanceId,$r.CollectedAt,$r.DatabaseName,$r.FileId,$r.FileType,$r.FileName,$r.PhysicalName,
            $r.FileSizeMB,$r.UnallocatedSpaceMB,$r.UserObjectMB,$r.InternalObjectMB,$r.VersionStoreMB,
            $r.MixedExtentMB,$r.GrowthMB,$r.MaxSizeMB,$r.IsPercentGrowth
        ) | Out-Null
    }
    $bcp = New-Object Microsoft.Data.SqlClient.SqlBulkCopy($Conn)
    $bcp.DestinationTableName = "dbo.TempDbStats"
    $bcp.BulkCopyTimeout = 60
    foreach ($col in $dt.Columns) { $bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName) | Out-Null }
    $bcp.WriteToServer($dt)
}

# ------------------------------------------------------------------
# Save-DeadlockHistory
# ------------------------------------------------------------------
function Save-DeadlockHistory {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $dt = New-Object System.Data.DataTable
    @("InstanceId","CollectedAt","EventTime","VictimSessionId","DeadlockGraphXml","ObjectName") |
        ForEach-Object { $dt.Columns.Add($_) | Out-Null }

    foreach ($r in $Rows) {
        $dt.Rows.Add(
            $r.InstanceId,$r.CollectedAt,
            $(if ($r.EventTime) { $r.EventTime } else { [DBNull]::Value }),
            $(if ($r.VictimSessionId) { $r.VictimSessionId } else { [DBNull]::Value }),
            $(if ($r.DeadlockGraphXml) { $r.DeadlockGraphXml } else { [DBNull]::Value }),
            $(if ($r.ObjectName) { $r.ObjectName } else { [DBNull]::Value })
        ) | Out-Null
    }
    $bcp = New-Object Microsoft.Data.SqlClient.SqlBulkCopy($Conn)
    $bcp.DestinationTableName = "dbo.DeadlockHistory"
    $bcp.BulkCopyTimeout = 60
    foreach ($col in $dt.Columns) { $bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName) | Out-Null }
    $bcp.WriteToServer($dt)
}

# ------------------------------------------------------------------
# Save-LogFileStats
# ------------------------------------------------------------------
function Save-LogFileStats {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $dt = New-Object System.Data.DataTable
    @("InstanceId","CollectedAt","DatabaseName","FileName","PhysicalName","FileType",
      "FileSizeMB","MaxSizeMB","GrowthMB","IsPercentGrowth","RecoveryModel",
      "LogSizeMB","LogUsedMB","VlfCount","FileId") |
        ForEach-Object { $dt.Columns.Add($_) | Out-Null }

    foreach ($r in $Rows) {
        $dt.Rows.Add(
            $r.InstanceId,$r.CollectedAt,$r.DatabaseName,$r.FileName,$r.PhysicalName,$r.FileType,
            $r.FileSizeMB,$r.MaxSizeMB,$r.GrowthMB,$r.IsPercentGrowth,$r.RecoveryModel,
            $r.LogSizeMB,$r.LogUsedMB,$r.VlfCount,$r.FileId
        ) | Out-Null
    }
    $bcp = New-Object Microsoft.Data.SqlClient.SqlBulkCopy($Conn)
    $bcp.DestinationTableName = "dbo.LogFileStats"
    $bcp.BulkCopyTimeout = 60
    foreach ($col in $dt.Columns) { $bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName) | Out-Null }
    $bcp.WriteToServer($dt)
}

# ------------------------------------------------------------------
# Save-IndexHealth
# ------------------------------------------------------------------
function Save-IndexHealth {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Result)
    if (-not $Result) { return }
    if ($Result.Missing) { Save-MissingIndexStats -Conn $Conn -Rows $Result.Missing }
    if ($Result.Unused) { Save-UnusedIndexStats -Conn $Conn -Rows $Result.Unused }
}

function Save-MissingIndexStats {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $dt = New-Object System.Data.DataTable
    @("InstanceId","CollectedAt","DatabaseName","StatementText","EqualityColumns","InequalityColumns",
      "IncludedColumns","UserSeeks","UniqueCompiles","AvgTotalUserCost","AvgUserImpact",
      "LastUserSeek","LastUserScan") | ForEach-Object { $dt.Columns.Add($_) | Out-Null }

    foreach ($r in $Rows) {
        $dt.Rows.Add($r.InstanceId,$r.CollectedAt,$r.DatabaseName,
            $(if ($r.StatementText) { $r.StatementText } else { [DBNull]::Value }),
            $(if ($r.EqualityColumns) { $r.EqualityColumns } else { [DBNull]::Value }),
            $(if ($r.InequalityColumns) { $r.InequalityColumns } else { [DBNull]::Value }),
            $(if ($r.IncludedColumns) { $r.IncludedColumns } else { [DBNull]::Value }),
            $r.UserSeeks,$r.UniqueCompiles,$r.AvgTotalUserCost,$r.AvgUserImpact,
            $(if ($r.LastUserSeek) { $r.LastUserSeek } else { [DBNull]::Value }),
            $(if ($r.LastUserScan) { $r.LastUserScan } else { [DBNull]::Value })
        ) | Out-Null
    }
    $bcp = New-Object Microsoft.Data.SqlClient.SqlBulkCopy($Conn)
    $bcp.DestinationTableName = "dbo.MissingIndexStats"
    $bcp.BulkCopyTimeout = 60
    foreach ($col in $dt.Columns) { $bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName) | Out-Null }
    $bcp.WriteToServer($dt)
}

function Save-UnusedIndexStats {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $dt = New-Object System.Data.DataTable
    @("InstanceId","CollectedAt","DatabaseName","SchemaName","TableName","IndexName","IndexType",
      "UserSeeks","UserScans","UserLookups","UserUpdates","LastUserSeek","LastUserScan",
      "LastUserLookup","LastUserUpdate","RowCount") | ForEach-Object { $dt.Columns.Add($_) | Out-Null }

    foreach ($r in $Rows) {
        $dt.Rows.Add(
            $r.InstanceId,$r.CollectedAt,$r.DatabaseName,$r.SchemaName,$r.TableName,$r.IndexName,$r.IndexType,
            $r.UserSeeks,$r.UserScans,$r.UserLookups,$r.UserUpdates,
            $(if ($r.LastUserSeek) { $r.LastUserSeek } else { [DBNull]::Value }),
            $(if ($r.LastUserScan) { $r.LastUserScan } else { [DBNull]::Value }),
            $(if ($r.LastUserLookup) { $r.LastUserLookup } else { [DBNull]::Value }),
            $(if ($r.LastUserUpdate) { $r.LastUserUpdate } else { [DBNull]::Value }),
            $r.RowCount
        ) | Out-Null
    }
    $bcp = New-Object Microsoft.Data.SqlClient.SqlBulkCopy($Conn)
    $bcp.DestinationTableName = "dbo.UnusedIndexStats"
    $bcp.BulkCopyTimeout = 60
    foreach ($col in $dt.Columns) { $bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName) | Out-Null }
    $bcp.WriteToServer($dt)
}

# ------------------------------------------------------------------
# Save-BackupAndAgentHealth
# ------------------------------------------------------------------
function Save-BackupAndAgentHealth {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Result)
    if (-not $Result) { return }
    if ($Result.BackupStatus) { Save-BackupStatus -Conn $Conn -Rows $Result.BackupStatus }
    if ($Result.AgentJobs) { Save-AgentJobHealth -Conn $Conn -Rows $Result.AgentJobs }
}

function Save-BackupStatus {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $dt = New-Object System.Data.DataTable
    @("InstanceId","CollectedAt","DatabaseName","RecoveryModel","LastFullBackupAt","LastDiffBackupAt",
      "LastLogBackupAt","FullBackupAgeHours","DiffBackupAgeHours","LogBackupAgeHours") |
        ForEach-Object { $dt.Columns.Add($_) | Out-Null }

    foreach ($r in $Rows) {
        $dt.Rows.Add(
            $r.InstanceId,$r.CollectedAt,$r.DatabaseName,$r.RecoveryModel,
            $(if ($r.LastFullBackupAt) { $r.LastFullBackupAt } else { [DBNull]::Value }),
            $(if ($r.LastDiffBackupAt) { $r.LastDiffBackupAt } else { [DBNull]::Value }),
            $(if ($r.LastLogBackupAt) { $r.LastLogBackupAt } else { [DBNull]::Value }),
            $r.FullBackupAgeHours,$r.DiffBackupAgeHours,$r.LogBackupAgeHours
        ) | Out-Null
    }
    $bcp = New-Object Microsoft.Data.SqlClient.SqlBulkCopy($Conn)
    $bcp.DestinationTableName = "dbo.BackupStatus"
    $bcp.BulkCopyTimeout = 60
    foreach ($col in $dt.Columns) { $bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName) | Out-Null }
    $bcp.WriteToServer($dt)
}

function Save-AgentJobHealth {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $dt = New-Object System.Data.DataTable
    @("InstanceId","CollectedAt","JobName","JobId","LastRunStatus","LastRunAt","LastRunMessage") |
        ForEach-Object { $dt.Columns.Add($_) | Out-Null }

    foreach ($r in $Rows) {
        $dt.Rows.Add(
            $r.InstanceId,$r.CollectedAt,$r.JobName,
            $(if ($r.JobId) { $r.JobId } else { [DBNull]::Value }),
            $r.LastRunStatus,
            $(if ($r.LastRunAt) { $r.LastRunAt } else { [DBNull]::Value }),
            $(if ($r.LastRunMessage) { $r.LastRunMessage } else { [DBNull]::Value })
        ) | Out-Null
    }
    $bcp = New-Object Microsoft.Data.SqlClient.SqlBulkCopy($Conn)
    $bcp.DestinationTableName = "dbo.AgentJobHealth"
    $bcp.BulkCopyTimeout = 60
    foreach ($col in $dt.Columns) { $bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName) | Out-Null }
    $bcp.WriteToServer($dt)
}

# ------------------------------------------------------------------
# Purge old data
# ------------------------------------------------------------------
function Invoke-Purge {
    param([Microsoft.Data.SqlClient.SqlConnection]$Conn, [int]$RetentionDays)
    $cmd = $Conn.CreateCommand()
    $cmd.CommandText = "EXEC dbo.usp_PurgeOldMetrics @RetentionDays"
    $cmd.CommandTimeout = 300
    $p = $cmd.CreateParameter(); $p.ParameterName = "@RetentionDays"; $p.Value = $RetentionDays
    $cmd.Parameters.Add($p) | Out-Null
    $cmd.ExecuteNonQuery() | Out-Null
}
