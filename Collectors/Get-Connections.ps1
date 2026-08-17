# Collector: Active Connections, Blocked Sessions, Blocking Chains

function Get-Connections {
    param(
        [string]$ConnectionString,
        [int]$InstanceId
    )

    $collectedAt = [DateTime]::UtcNow

    # --- Summary snapshot ---
    $sqlSummary = @"
SELECT
    COUNT(*)                                                          AS TotalSessions,
    SUM(CASE WHEN s.status = 'running'        THEN 1 ELSE 0 END)     AS ActiveRequests,
    SUM(CASE WHEN r.blocking_session_id > 0   THEN 1 ELSE 0 END)     AS BlockedSessions
FROM sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_requests AS r ON s.session_id = r.session_id
WHERE s.is_user_process = 1;
"@

    # --- Per-session details (JSON-friendly) ---
    $sqlSessions = @"
SELECT
    s.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    DB_NAME(r.database_id)  AS database_name,
    s.status,
    r.blocking_session_id,
    r.wait_type,
    r.wait_time,
    r.cpu_time,
    r.logical_reads,
    s.last_request_start_time,
    SUBSTRING(qt.text, (r.statement_start_offset/2)+1,
        ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text) ELSE r.statement_end_offset END
         - r.statement_start_offset)/2)+1)  AS current_statement
FROM sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_requests AS r ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS qt
WHERE s.is_user_process = 1
ORDER BY r.blocking_session_id DESC, s.session_id;
"@

    # --- Blocking chains ---
    $sqlBlocking = @"
SELECT
    r.blocking_session_id                       AS BlockingSessionId,
    r.session_id                                AS BlockedSessionId,
    r.wait_type                                 AS WaitType,
    r.wait_time                                 AS WaitTimeMs,
    SUBSTRING(btext.text, (br.statement_start_offset/2)+1,
        ((CASE br.statement_end_offset WHEN -1 THEN DATALENGTH(btext.text) ELSE br.statement_end_offset END
         - br.statement_start_offset)/2)+1)     AS BlockingStatement,
    SUBSTRING(qt.text, (r.statement_start_offset/2)+1,
        ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text) ELSE r.statement_end_offset END
         - r.statement_start_offset)/2)+1)      AS BlockedStatement
FROM sys.dm_exec_requests AS r
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS qt
LEFT JOIN sys.dm_exec_requests AS br ON br.session_id = r.blocking_session_id
OUTER APPLY sys.dm_exec_sql_text(br.sql_handle) AS btext
WHERE r.blocking_session_id > 0;
"@

    $snapshot   = $null
    $blockings  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $sessionJson = "[]"

    try {
        $conn = New-Object Microsoft.Data.SqlClient.SqlConnection($ConnectionString)
        $conn.Open()

        # Summary
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $sqlSummary
        $cmd.CommandTimeout = 15
        $reader = $cmd.ExecuteReader()
        if ($reader.Read()) {
            $snapshot = [PSCustomObject]@{
                InstanceId      = $InstanceId
                CollectedAt     = $collectedAt
                TotalSessions   = [int]$reader["TotalSessions"]
                ActiveRequests  = [int]$reader["ActiveRequests"]
                BlockedSessions = [int]$reader["BlockedSessions"]
                SessionDetailsJson = "[]"
            }
        }
        $reader.Close()

        # Sessions detail -> JSON
        $cmd.CommandText = $sqlSessions
        $reader = $cmd.ExecuteReader()
        $sessions = [System.Collections.Generic.List[hashtable]]::new()
        while ($reader.Read()) {
            $row = @{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $row[$reader.GetName($i)] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
            }
            $sessions.Add($row)
        }
        $reader.Close()
        $sessionJson = $sessions | ConvertTo-Json -Compress -Depth 3
        if ($snapshot) { $snapshot.SessionDetailsJson = $sessionJson }

        # Blocking chains
        $cmd.CommandText = $sqlBlocking
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $blockings.Add([PSCustomObject]@{
                InstanceId        = $InstanceId
                CollectedAt       = $collectedAt
                BlockingSessionId = [int]$reader["BlockingSessionId"]
                BlockedSessionId  = [int]$reader["BlockedSessionId"]
                WaitType          = if ($reader.IsDBNull($reader.GetOrdinal("WaitType")))          { $null } else { [string]$reader["WaitType"] }
                WaitTimeMs        = [int]$reader["WaitTimeMs"]
                BlockingStatement = if ($reader.IsDBNull($reader.GetOrdinal("BlockingStatement"))) { $null } else { [string]$reader["BlockingStatement"] }
                BlockedStatement  = if ($reader.IsDBNull($reader.GetOrdinal("BlockedStatement")))  { $null } else { [string]$reader["BlockedStatement"] }
            })
        }
        $reader.Close()
        $conn.Close()

        return [PSCustomObject]@{
            Snapshot  = $snapshot
            Blockings = $blockings
        }
    }
    catch {
        Write-Warning "[$($MyInvocation.MyCommand)] Instance $InstanceId : $_"
        return [PSCustomObject]@{ Snapshot = $null; Blockings = @() }
    }
    finally {
        if ($conn.State -ne 'Closed') { $conn.Close() }
    }
}
