# Collector: Disk I/O Statistics

function Get-DiskIOStats {
    param(
        [string]$ConnectionString,
        [int]$InstanceId
    )

    $collectedAt = [DateTime]::UtcNow

    # Column name changed in SQL Server 2022: io_stall_read_ms / io_stall_write_ms
    # Older versions use: io_stall_read / io_stall_write
    # Detect at runtime using dynamic SQL

    $sql = @"
DECLARE @ReadCol  SYSNAME = 'io_stall_read';
DECLARE @WriteCol SYSNAME = 'io_stall_write';

-- SQL Server 2022+ renamed these columns
IF EXISTS (
    SELECT 1 FROM sys.system_objects o
    JOIN sys.system_columns c ON o.object_id = c.object_id
    WHERE o.name = 'dm_io_virtual_file_stats' AND c.name = 'io_stall_read_ms'
)
BEGIN
    SET @ReadCol  = 'io_stall_read_ms';
    SET @WriteCol = 'io_stall_write_ms';
END

DECLARE @sql NVARCHAR(MAX) = N'
SELECT
    DB_NAME(vfs.database_id)    AS DatabaseName,
    mf.physical_name            AS PhysicalName,
    CASE mf.type WHEN 0 THEN ''DATA'' WHEN 1 THEN ''LOG'' ELSE ''OTHER'' END AS FileType,
    vfs.' + @ReadCol  + N'            AS ReadStallMs,
    vfs.' + @WriteCol + N'           AS WriteStallMs,
    vfs.io_stall                  AS TotalStallMs,
    vfs.num_of_reads              AS NumReads,
    vfs.num_of_writes             AS NumWrites,
    vfs.num_of_bytes_read         AS BytesRead,
    vfs.num_of_bytes_written      AS BytesWritten,
    CASE WHEN vfs.num_of_reads  = 0 THEN 0
         ELSE vfs.' + @ReadCol  + N' / vfs.num_of_reads  END AS AvgReadLatencyMs,
    CASE WHEN vfs.num_of_writes = 0 THEN 0
         ELSE vfs.' + @WriteCol + N' / vfs.num_of_writes END AS AvgWriteLatencyMs
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf
    ON vfs.database_id = mf.database_id
   AND vfs.file_id     = mf.file_id
ORDER BY vfs.io_stall DESC';

EXEC sp_executesql @sql;
"@

    try {
        $conn = New-Object Microsoft.Data.SqlClient.SqlConnection($ConnectionString)
        $conn.Open()
        $cmd  = $conn.CreateCommand()
        $cmd.CommandText    = $sql
        $cmd.CommandTimeout = 30

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $reader  = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $results.Add([PSCustomObject]@{
                InstanceId        = $InstanceId
                CollectedAt       = $collectedAt
                DatabaseName      = if ($reader.IsDBNull($reader.GetOrdinal("DatabaseName"))) { "Unknown" } else { [string]$reader["DatabaseName"] }
                PhysicalName      = [string]$reader["PhysicalName"]
                FileType          = [string]$reader["FileType"]
                ReadStallMs       = [long]$reader["ReadStallMs"]
                WriteStallMs      = [long]$reader["WriteStallMs"]
                TotalStallMs      = [long]$reader["TotalStallMs"]
                NumReads          = [long]$reader["NumReads"]
                NumWrites         = [long]$reader["NumWrites"]
                BytesRead         = [long]$reader["BytesRead"]
                BytesWritten      = [long]$reader["BytesWritten"]
                AvgReadLatencyMs  = [long]$reader["AvgReadLatencyMs"]
                AvgWriteLatencyMs = [long]$reader["AvgWriteLatencyMs"]
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
