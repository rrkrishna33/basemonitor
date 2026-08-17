# Collector: TempDB health
# Captures TempDB file usage and allocation breakdown to spot version store, internal objects, and space pressure

function Get-TempDbStats {
    param(
        [string]$ConnectionString,
        [int]$InstanceId
    )

    $collectedAt = [DateTime]::UtcNow

    $sql = @"
SELECT
    DB_NAME()                                                          AS DatabaseName,
    df.file_id                                                         AS FileId,
    df.type_desc                                                       AS FileType,
    df.name                                                            AS FileName,
    df.physical_name                                                   AS PhysicalName,
    CAST(df.size * 8.0 / 1024 AS BIGINT)                               AS FileSizeMB,
    CAST(fsu.unallocated_extent_page_count * 8.0 / 1024 AS BIGINT)    AS UnallocatedSpaceMB,
    CAST(fsu.user_object_reserved_page_count * 8.0 / 1024 AS BIGINT)  AS UserObjectMB,
    CAST(fsu.internal_object_reserved_page_count * 8.0 / 1024 AS BIGINT) AS InternalObjectMB,
    CAST(fsu.version_store_reserved_page_count * 8.0 / 1024 AS BIGINT) AS VersionStoreMB,
    CAST(fsu.mixed_extent_page_count * 8.0 / 1024 AS BIGINT)          AS MixedExtentMB,
    CAST(df.growth * 8.0 / 1024 AS BIGINT)                              AS GrowthMB,
    CASE WHEN df.max_size = -1 THEN NULL ELSE CAST(df.max_size * 8.0 / 1024 AS BIGINT) END AS MaxSizeMB,
    CASE WHEN df.is_percent_growth = 1 THEN 1 ELSE 0 END               AS IsPercentGrowth
FROM tempdb.sys.database_files AS df
LEFT JOIN tempdb.sys.dm_db_file_space_usage AS fsu
    ON fsu.file_id = df.file_id
ORDER BY df.file_id;
"@

    try {
        $conn = New-Object Microsoft.Data.SqlClient.SqlConnection($ConnectionString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $sql
        $cmd.CommandTimeout = 30

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $reader = $cmd.ExecuteReader()

        $safeLong = {
            param($Reader, [string]$ColumnName)
            $ordinal = $Reader.GetOrdinal($ColumnName)
            if ($Reader.IsDBNull($ordinal)) { return $null }
            $value = $Reader[$ColumnName]
            if ($value -is [string] -and [string]::IsNullOrWhiteSpace([string]$value)) { return $null }
            return [long]$value
        }

        while ($reader.Read()) {
            $results.Add([PSCustomObject]@{
                InstanceId             = $InstanceId
                CollectedAt            = $collectedAt
                DatabaseName           = [string]$reader["DatabaseName"]
                FileId                 = [int]$reader["FileId"]
                FileType               = [string]$reader["FileType"]
                FileName               = [string]$reader["FileName"]
                PhysicalName           = [string]$reader["PhysicalName"]
                FileSizeMB             = & $safeLong $reader "FileSizeMB"
                UnallocatedSpaceMB     = & $safeLong $reader "UnallocatedSpaceMB"
                UserObjectMB           = & $safeLong $reader "UserObjectMB"
                InternalObjectMB       = & $safeLong $reader "InternalObjectMB"
                VersionStoreMB         = & $safeLong $reader "VersionStoreMB"
                MixedExtentMB          = & $safeLong $reader "MixedExtentMB"
                GrowthMB               = & $safeLong $reader "GrowthMB"
                MaxSizeMB              = & $safeLong $reader "MaxSizeMB"
                IsPercentGrowth        = if ($reader.IsDBNull($reader.GetOrdinal("IsPercentGrowth"))) { 0 } else { [int]$reader["IsPercentGrowth"] }
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
