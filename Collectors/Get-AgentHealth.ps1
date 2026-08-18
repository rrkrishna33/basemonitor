# Collector: SQL Agent health
# Captures recent SQL Agent job execution health

function Get-AgentHealth {
    param(
        [string]$ConnectionString,
        [int]$InstanceId
    )

    $collectedAt = [DateTime]::UtcNow

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

        $jobHealth = [System.Collections.Generic.List[PSCustomObject]]::new()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $jobSql
        $cmd.CommandTimeout = 30
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

        return $jobHealth
    }
    catch {
        Write-Warning "[$($MyInvocation.MyCommand)] Instance $InstanceId : $_"
        return @()
    }
    finally {
        if ($null -ne $conn -and $conn.State -ne 'Closed') { $conn.Close() }
    }
}
