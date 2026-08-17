# Collector: Log file VLF and growth statistics
# Captures transaction log capacity and VLF distribution to spot log pressure and autogrowth risk

function Get-LogFileStats {
    param(
        [string]$ConnectionString,
        [int]$InstanceId
    )

    $collectedAt = [DateTime]::UtcNow

    $baseSql = @"
SELECT
    d.name                                                          AS DatabaseName,
    mf.name                                                         AS FileName,
    mf.physical_name                                                AS PhysicalName,
    mf.type_desc                                                    AS FileType,
    CAST(mf.size * 8.0 / 1024 AS BIGINT)                             AS FileSizeMB,
    CASE WHEN mf.max_size = -1 THEN NULL ELSE CAST(mf.max_size * 8.0 / 1024 AS BIGINT) END AS MaxSizeMB,
    CAST(mf.growth * 8.0 / 1024 AS BIGINT)                            AS GrowthMB,
    CASE WHEN mf.is_percent_growth = 1 THEN 1 ELSE 0 END             AS IsPercentGrowth,
    d.recovery_model_desc                                           AS RecoveryModel,
    mf.file_id                                                      AS FileId
FROM sys.master_files AS mf
JOIN sys.databases AS d
    ON d.database_id = mf.database_id
WHERE mf.type = 1
ORDER BY d.name, mf.file_id;
"@

    try {
        $conn = New-Object Microsoft.Data.SqlClient.SqlConnection($ConnectionString)
        $conn.Open()

        $logSpace = @{}
        $spaceCmd = $conn.CreateCommand()
        $spaceCmd.CommandText = 'DBCC SQLPERF(LOGSPACE);'
        $spaceCmd.CommandTimeout = 30
        $spaceReader = $spaceCmd.ExecuteReader()
        while ($spaceReader.Read()) {
            $dbName = [string]$spaceReader[0]
            $sizeMb = 0
            $usedMb = 0
            try { $sizeMb = [long]([decimal]$spaceReader[1] * 1024 / 1024) } catch { $sizeMb = 0 }
            try { $usedMb = [long](([decimal]$spaceReader[1]) * ([decimal]$spaceReader[2]) / 100.0) } catch { $usedMb = 0 }
            $logSpace[$dbName] = [PSCustomObject]@{ LogSizeMB = $sizeMb; LogUsedMB = $usedMb }
        }
        $spaceReader.Close()

        $vlfMap = @{}
        $dbNames = @()
        $baseCmd = $conn.CreateCommand()
        $baseCmd.CommandText = $baseSql
        $baseCmd.CommandTimeout = 30
        $baseReader = $baseCmd.ExecuteReader()
        while ($baseReader.Read()) {
            $dbNames += [string]$baseReader["DatabaseName"]
        }
        $baseReader.Close()

        foreach ($dbName in ($dbNames | Select-Object -Unique)) {
            try {
                $vlfCmd = $conn.CreateCommand()
                $vlfCmd.CommandText = "USE [$dbName]; DBCC LOGINFO();"
                $vlfCmd.CommandTimeout = 30
                $vlfReader = $vlfCmd.ExecuteReader()
                $count = 0
                while ($vlfReader.Read()) { $count++ }
                $vlfReader.Close()
                $vlfMap[$dbName] = $count
            }
            catch {
                $vlfMap[$dbName] = 0
            }
        }

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $baseReader = $baseCmd.ExecuteReader()
        while ($baseReader.Read()) {
            $dbName = [string]$baseReader["DatabaseName"]
            $logSizeMb = 0
            $logUsedMb = 0
            if ($logSpace.ContainsKey($dbName)) {
                $logSizeMb = [long]$logSpace[$dbName].LogSizeMB
                $logUsedMb = [long]$logSpace[$dbName].LogUsedMB
            }
            $vlfCount = if ($vlfMap.ContainsKey($dbName)) { [int]$vlfMap[$dbName] } else { 0 }

            $results.Add([PSCustomObject]@{
                InstanceId        = $InstanceId
                CollectedAt       = $collectedAt
                DatabaseName      = $dbName
                FileName          = [string]$baseReader["FileName"]
                PhysicalName      = [string]$baseReader["PhysicalName"]
                FileType          = [string]$baseReader["FileType"]
                FileSizeMB        = [long]$baseReader["FileSizeMB"]
                MaxSizeMB         = if ($baseReader.IsDBNull($baseReader.GetOrdinal("MaxSizeMB"))) { $null } else { [long]$baseReader["MaxSizeMB"] }
                GrowthMB          = if ($baseReader.IsDBNull($baseReader.GetOrdinal("GrowthMB"))) { 0 } else { [long]$baseReader["GrowthMB"] }
                IsPercentGrowth   = [int]$baseReader["IsPercentGrowth"]
                RecoveryModel     = [string]$baseReader["RecoveryModel"]
                LogSizeMB         = $logSizeMb
                LogUsedMB         = $logUsedMb
                VlfCount          = $vlfCount
                FileId            = [int]$baseReader["FileId"]
            })
        }
        $baseReader.Close()
        $conn.Close()
        return $results
    }
    catch {
        Write-Warning "[$($MyInvocation.MyCommand)] Instance $InstanceId : $_"
        return @()
    }
    finally {
        if ($null -ne $conn -and $conn.State -ne 'Closed') { $conn.Close() }
    }
}
