# Collector: Index Fragmentation
# Only collects indexes with > 100 pages to avoid excessive overhead

function Get-IndexFragmentation {
    param(
        [string]$ConnectionString,
        [int]$InstanceId,
        [int]$DbTimeoutSeconds  = 600,
        [int]$MinPageCount      = 200,
        [string[]]$ExcludeDatabases = @()
    )

    $collectedAt = [DateTime]::UtcNow

    # Enumerate online databases first, then query each
    $sqlDatabases = @"
SELECT name FROM sys.databases
WHERE state = 0
  AND name NOT IN ('master','tempdb','model','msdb')
ORDER BY name;
"@

    $fragSql = @"
SELECT
    DB_NAME()                               AS DatabaseName,
    OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS TableName,
    i.name                                  AS IndexName,
    i.type_desc                             AS IndexType,
    ips.avg_fragmentation_in_percent        AS FragmentationPercent,
    ips.page_count                          AS PageCount,
    ips.record_count                        AS RecordCount
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS ips
JOIN sys.indexes AS i
    ON i.object_id = ips.object_id
   AND i.index_id  = ips.index_id
WHERE ips.page_count > @MinPageCount
  AND ips.index_type_desc <> 'HEAP'
ORDER BY ips.avg_fragmentation_in_percent DESC;
"@

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        # Get database list
        $connMaster = New-Object Microsoft.Data.SqlClient.SqlConnection($ConnectionString)
        $connMaster.Open()
        $cmdDb = $connMaster.CreateCommand()
        $cmdDb.CommandText = $sqlDatabases
        $cmdDb.CommandTimeout = 15
        $databases = [System.Collections.Generic.List[string]]::new()
        $rdr = $cmdDb.ExecuteReader()
        while ($rdr.Read()) { $databases.Add($rdr.GetString(0)) }
        $rdr.Close()
        $connMaster.Close()

        foreach ($db in $databases) {
            # Skip explicitly excluded databases
            if ($ExcludeDatabases -contains $db) {
                Write-Verbose "[Get-IndexFragmentation] Skipping excluded DB: $db (instance $InstanceId)"
                continue
            }

            # Build a connection string for this specific database
            $builder = New-Object Microsoft.Data.SqlClient.SqlConnectionStringBuilder($ConnectionString)
            $builder["Initial Catalog"] = $db
            $dbConn = New-Object Microsoft.Data.SqlClient.SqlConnection($builder.ConnectionString)
            try {
                $dbConn.Open()
                $cmd = $dbConn.CreateCommand()
                $cmd.CommandText    = $fragSql
                $cmd.CommandTimeout = $DbTimeoutSeconds
                $p = $cmd.Parameters.Add('@MinPageCount', [System.Data.SqlDbType]::Int)
                $p.Value = $MinPageCount

                $reader = $cmd.ExecuteReader()
                while ($reader.Read()) {
                    $results.Add([PSCustomObject]@{
                        InstanceId           = $InstanceId
                        CollectedAt          = $collectedAt
                        DatabaseName         = [string]$reader["DatabaseName"]
                        TableName            = if ($reader.IsDBNull($reader.GetOrdinal("TableName")))            { $null   } else { [string]$reader["TableName"] }
                        IndexName            = if ($reader.IsDBNull($reader.GetOrdinal("IndexName")))            { $null   } else { [string]$reader["IndexName"] }
                        IndexType            = [string]$reader["IndexType"]
                        FragmentationPercent = if ($reader.IsDBNull($reader.GetOrdinal("FragmentationPercent"))) { 0.0    } else { [double]$reader["FragmentationPercent"] }
                        PageCount            = if ($reader.IsDBNull($reader.GetOrdinal("PageCount")))            { 0L    } else { [long]$reader["PageCount"] }
                        RecordCount          = if ($reader.IsDBNull($reader.GetOrdinal("RecordCount")))          { 0L    } else { [long]$reader["RecordCount"] }
                    })
                }
                $reader.Close()
            }
            catch {
                $msg = $_.Exception.Message
                if ($msg -match 'Timeout|timeout') {
                    Write-Warning "[Get-IndexFragmentation] TIMEOUT on DB '$db' (instance $InstanceId, limit=${DbTimeoutSeconds}s). Add to FragmentationExcludeDatabases in config.json to suppress."
                } else {
                    Write-Warning "[Get-IndexFragmentation] DB '$db' on instance $InstanceId : $msg"
                }
            }
            finally { if ($dbConn.State -ne 'Closed') { $dbConn.Close() } }
        }
        return $results
    }
    catch {
        Write-Warning "[$($MyInvocation.MyCommand)] Instance $InstanceId : $_"
        return @()
    }
}
