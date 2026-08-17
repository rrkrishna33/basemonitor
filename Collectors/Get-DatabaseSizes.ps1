# Collector: Database Sizes and Growth

function Get-DatabaseSizes {
    param(
        [string]$ConnectionString,
        [int]$InstanceId
    )

    $collectedAt = [DateTime]::UtcNow

    $sql = @"
SELECT
    d.name                                                                AS DatabaseName,
    d.state_desc                                                          AS State,
    d.recovery_model_desc                                                 AS RecoveryModel,
    SUM(CASE WHEN mf.type = 0 THEN CAST(mf.size AS BIGINT) * 8 / 1024 ELSE 0 END) AS DataSizeMB,
    SUM(CASE WHEN mf.type = 1 THEN CAST(mf.size AS BIGINT) * 8 / 1024 ELSE 0 END) AS LogSizeMB,
    COUNT(mf.file_id)                                                     AS FileCount
FROM sys.databases AS d
LEFT JOIN sys.master_files AS mf ON d.database_id = mf.database_id
WHERE d.state = 0  -- ONLINE only
GROUP BY d.name, d.state_desc, d.recovery_model_desc
ORDER BY DataSizeMB DESC;
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
                InstanceId    = $InstanceId
                CollectedAt   = $collectedAt
                DatabaseName  = [string]$reader["DatabaseName"]
                State         = [string]$reader["State"]
                RecoveryModel = [string]$reader["RecoveryModel"]
                DataSizeMB    = [long]$reader["DataSizeMB"]
                LogSizeMB     = [long]$reader["LogSizeMB"]
                FileCount     = [int]$reader["FileCount"]
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
