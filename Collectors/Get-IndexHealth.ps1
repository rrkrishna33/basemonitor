# Collector: Missing and unused indexes
# Combines missing-index recommendations with index usage stats to highlight performance tuning opportunities

function Get-IndexHealth {
    param(
        [string]$ConnectionString,
        [int]$InstanceId
    )

    $collectedAt = [DateTime]::UtcNow

    $missingSql = @"
SELECT TOP 50
    DB_NAME(mid.database_id)                               AS DatabaseName,
    mid.statement                                          AS StatementText,
    mid.equality_columns                                   AS EqualityColumns,
    mid.inequality_columns                                 AS InequalityColumns,
    mid.included_columns                                   AS IncludedColumns,
    migs.user_seeks                                        AS UserSeeks,
    migs.unique_compiles                                   AS UniqueCompiles,
    migs.avg_total_user_cost                               AS AvgTotalUserCost,
    migs.avg_user_impact                                   AS AvgUserImpact,
    migs.last_user_seek                                    AS LastUserSeek,
    migs.last_user_scan                                    AS LastUserScan
FROM sys.dm_db_missing_index_details AS mid
JOIN sys.dm_db_missing_index_groups AS mig
    ON mig.index_handle = mid.index_handle
JOIN sys.dm_db_missing_index_group_stats AS migs
    ON migs.group_handle = mig.index_group_handle
ORDER BY (migs.user_seeks * migs.avg_total_user_cost) DESC;
"@

    $unusedSql = @"
SELECT TOP 100
    DB_NAME(ius.database_id)                               AS DatabaseName,
    s.name                                                 AS SchemaName,
    o.name                                                 AS TableName,
    i.name                                                 AS IndexName,
    i.type_desc                                            AS IndexType,
    ius.user_seeks                                         AS UserSeeks,
    ius.user_scans                                         AS UserScans,
    ius.user_lookups                                       AS UserLookups,
    ius.user_updates                                       AS UserUpdates,
    ius.last_user_seek                                     AS LastUserSeek,
    ius.last_user_scan                                     AS LastUserScan,
    ius.last_user_lookup                                   AS LastUserLookup,
    ius.last_user_update                                   AS LastUserUpdate,
    CAST(p.row_count AS BIGINT)                            AS [RowCount]
FROM sys.dm_db_index_usage_stats AS ius
JOIN sys.indexes AS i
    ON i.object_id = ius.object_id
   AND i.index_id = ius.index_id
JOIN sys.objects AS o
    ON o.object_id = i.object_id
JOIN sys.schemas AS s
    ON s.schema_id = o.schema_id
JOIN sys.dm_db_partition_stats AS p
    ON p.object_id = i.object_id
   AND p.index_id = i.index_id
WHERE ius.database_id = DB_ID()
  AND i.is_hypothetical = 0
  AND i.index_id > 1
  AND ius.user_seeks = 0
  AND ius.user_scans = 0
  AND ius.user_lookups = 0
ORDER BY ius.user_updates DESC;
"@

    try {
        $conn = New-Object Microsoft.Data.SqlClient.SqlConnection($ConnectionString)
        $conn.Open()

        $missing = [System.Collections.Generic.List[PSCustomObject]]::new()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $missingSql
        $cmd.CommandTimeout = 30
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $missing.Add([PSCustomObject]@{
                InstanceId        = $InstanceId
                CollectedAt       = $collectedAt
                DatabaseName      = [string]$reader["DatabaseName"]
                StatementText     = if ($reader.IsDBNull($reader.GetOrdinal("StatementText"))) { $null } else { [string]$reader["StatementText"] }
                EqualityColumns   = if ($reader.IsDBNull($reader.GetOrdinal("EqualityColumns"))) { $null } else { [string]$reader["EqualityColumns"] }
                InequalityColumns = if ($reader.IsDBNull($reader.GetOrdinal("InequalityColumns"))) { $null } else { [string]$reader["InequalityColumns"] }
                IncludedColumns   = if ($reader.IsDBNull($reader.GetOrdinal("IncludedColumns"))) { $null } else { [string]$reader["IncludedColumns"] }
                UserSeeks         = [long]$reader["UserSeeks"]
                UniqueCompiles    = [long]$reader["UniqueCompiles"]
                AvgTotalUserCost  = [double]$reader["AvgTotalUserCost"]
                AvgUserImpact     = [double]$reader["AvgUserImpact"]
                LastUserSeek      = if ($reader.IsDBNull($reader.GetOrdinal("LastUserSeek"))) { $null } else { [datetime]$reader["LastUserSeek"] }
                LastUserScan      = if ($reader.IsDBNull($reader.GetOrdinal("LastUserScan"))) { $null } else { [datetime]$reader["LastUserScan"] }
            })
        }
        $reader.Close()

        $unused = [System.Collections.Generic.List[PSCustomObject]]::new()
        $cmd.CommandText = $unusedSql
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $unused.Add([PSCustomObject]@{
                InstanceId        = $InstanceId
                CollectedAt       = $collectedAt
                DatabaseName      = [string]$reader["DatabaseName"]
                SchemaName        = [string]$reader["SchemaName"]
                TableName         = [string]$reader["TableName"]
                IndexName         = [string]$reader["IndexName"]
                IndexType         = [string]$reader["IndexType"]
                UserSeeks         = [long]$reader["UserSeeks"]
                UserScans         = [long]$reader["UserScans"]
                UserLookups       = [long]$reader["UserLookups"]
                UserUpdates       = [long]$reader["UserUpdates"]
                LastUserSeek      = if ($reader.IsDBNull($reader.GetOrdinal("LastUserSeek"))) { $null } else { [datetime]$reader["LastUserSeek"] }
                LastUserScan      = if ($reader.IsDBNull($reader.GetOrdinal("LastUserScan"))) { $null } else { [datetime]$reader["LastUserScan"] }
                LastUserLookup    = if ($reader.IsDBNull($reader.GetOrdinal("LastUserLookup"))) { $null } else { [datetime]$reader["LastUserLookup"] }
                LastUserUpdate    = if ($reader.IsDBNull($reader.GetOrdinal("LastUserUpdate"))) { $null } else { [datetime]$reader["LastUserUpdate"] }
                RowCount          = [long]$reader["RowCount"]
            })
        }
        $reader.Close()
        $conn.Close()

        return [PSCustomObject]@{
            Missing = $missing
            Unused = $unused
        }
    }
    catch {
        Write-Warning "[$($MyInvocation.MyCommand)] Instance $InstanceId : $_"
        return [PSCustomObject]@{ Missing = @(); Unused = @() }
    }
    finally {
        if ($conn.State -ne 'Closed') { $conn.Close() }
    }
}
