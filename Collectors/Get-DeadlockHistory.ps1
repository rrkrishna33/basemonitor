# Collector: Deadlock history
# Reads deadlock events from the system_health XEvent session when available

function Get-DeadlockHistory {
    param(
        [string]$ConnectionString,
        [int]$InstanceId
    )

    $collectedAt = [DateTime]::UtcNow

    $sql = @"
SELECT TOP 20
    CAST(event_data AS XML) AS EventData,
    CAST(timestamp_utc AS DATETIME2) AS EventTime,
    object_name
FROM sys.fn_xe_file_target_read_file('system_health*.xel', NULL, NULL, NULL)
WHERE object_name = 'xml_deadlock_report'
ORDER BY timestamp_utc DESC;
"@

    try {
        $conn = New-Object Microsoft.Data.SqlClient.SqlConnection($ConnectionString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $sql
        $cmd.CommandTimeout = 120

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $xml = $null
            try {
                $xml = [xml]$reader["EventData"]
            }
            catch {
                $xml = $null
            }

            $victimSessionId = $null
            if ($xml) {
                $victimNode = $xml.SelectSingleNode("//*[local-name()='victim-list']/*[local-name()='victimProcess']")
                if ($victimNode) {
                    $victimSessionId = $victimNode.GetAttribute("id")
                }
            }

            $results.Add([PSCustomObject]@{
                InstanceId        = $InstanceId
                CollectedAt       = $collectedAt
                EventTime         = if ($reader.IsDBNull($reader.GetOrdinal("EventTime"))) { $null } else { [datetime]$reader["EventTime"] }
                VictimSessionId   = $victimSessionId
                DeadlockGraphXml  = if ($xml) { $xml.OuterXml } else { $null }
                ObjectName        = if ($reader.IsDBNull($reader.GetOrdinal("object_name"))) { $null } else { [string]$reader["object_name"] }
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
