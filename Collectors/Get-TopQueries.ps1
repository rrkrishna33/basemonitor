# Collector: Top Queries by CPU, Duration, I/O
# Captures top 50 queries from plan cache

function Get-TopQueries {
    param(
        [string]$ConnectionString,
        [int]$InstanceId
    )

    $collectedAt = [DateTime]::UtcNow

    $sql = @"
SELECT TOP 50
    DB_NAME(qt.dbid)                                    AS DatabaseName,
    OBJECT_SCHEMA_NAME(qt.objectid, qt.dbid)             AS ProcedureSchema,
    OBJECT_NAME(qt.objectid, qt.dbid)                    AS ProcedureName,
    SUBSTRING(qt.text, (qs.statement_start_offset/2)+1,
        ((CASE qs.statement_end_offset
            WHEN -1 THEN DATALENGTH(qt.text)
            ELSE qs.statement_end_offset
         END - qs.statement_start_offset)/2)+1)         AS QueryText,
    qs.total_worker_time    / qs.execution_count        AS AvgCpuUs,
    qs.total_worker_time                                AS TotalCpuUs,
    qs.execution_count                                  AS ExecutionCount,
    qs.total_elapsed_time   / qs.execution_count        AS AvgDurationUs,
    qs.total_logical_reads  / qs.execution_count        AS AvgLogicalReads,
    qs.total_physical_reads / qs.execution_count        AS AvgPhysicalReads,
    qs.total_logical_writes / qs.execution_count        AS AvgLogicalWrites,
    qs.last_execution_time                              AS LastExecutedAt,
    qs.creation_time                                    AS PlanCreatedAt
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
WHERE qs.execution_count > 0
ORDER BY qs.total_worker_time DESC;
"@

    try {
        $conn = New-Object Microsoft.Data.SqlClient.SqlConnection($ConnectionString)
        $conn.Open()
        $cmd  = $conn.CreateCommand()
        $cmd.CommandText    = $sql
        $cmd.CommandTimeout = 60

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $reader  = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $results.Add([PSCustomObject]@{
                InstanceId        = $InstanceId
                CollectedAt       = $collectedAt
                DatabaseName      = if ($reader.IsDBNull($reader.GetOrdinal("DatabaseName"))) { $null } else { [string]$reader["DatabaseName"] }
                ProcedureSchema   = if ($reader.IsDBNull($reader.GetOrdinal("ProcedureSchema"))) { $null } else { [string]$reader["ProcedureSchema"] }
                ProcedureName     = if ($reader.IsDBNull($reader.GetOrdinal("ProcedureName"))) { $null } else { [string]$reader["ProcedureName"] }
                QueryText         = if ($reader.IsDBNull($reader.GetOrdinal("QueryText")))    { $null } else { [string]$reader["QueryText"] }
                AvgCpuUs          = [long]$reader["AvgCpuUs"]
                TotalCpuUs        = [long]$reader["TotalCpuUs"]
                ExecutionCount    = [long]$reader["ExecutionCount"]
                AvgDurationUs     = [long]$reader["AvgDurationUs"]
                AvgLogicalReads   = [long]$reader["AvgLogicalReads"]
                AvgPhysicalReads  = [long]$reader["AvgPhysicalReads"]
                AvgLogicalWrites  = [long]$reader["AvgLogicalWrites"]
                LastExecutedAt    = if ($reader.IsDBNull($reader.GetOrdinal("LastExecutedAt"))) { $null } else { [datetime]$reader["LastExecutedAt"] }
                PlanCreatedAt     = if ($reader.IsDBNull($reader.GetOrdinal("PlanCreatedAt")))  { $null } else { [datetime]$reader["PlanCreatedAt"] }
            })
        }
        $reader.Close()
        $conn.Close()
        return $results
    }
    catch {
        Write-Warning "[$($MyInvocation.MyCommand)] Instance $InstanceId : $_"
        return @()
    }
    finally {
        if ($conn.State -ne 'Closed') { $conn.Close() }
    }
}
