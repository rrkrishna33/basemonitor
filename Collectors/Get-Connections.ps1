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

    # --- Recursive blocking tree ---
    $sqlBlocking = @"
;WITH BlockingTree AS
(
    SELECT r.session_id, r.blocking_session_id,
           CAST(CAST(r.session_id AS VARCHAR(10)) AS VARCHAR(MAX)) AS BlockingChain,
           0 AS LevelNo
    FROM sys.dm_exec_requests r
    WHERE r.blocking_session_id = 0
      AND EXISTS (SELECT 1 FROM sys.dm_exec_requests r2 WHERE r2.blocking_session_id = r.session_id)
    UNION ALL
    SELECT r.session_id, r.blocking_session_id,
           CAST(bt.BlockingChain + ' -> ' + CAST(r.session_id AS VARCHAR(10)) AS VARCHAR(MAX)),
           bt.LevelNo + 1
    FROM sys.dm_exec_requests r
    INNER JOIN BlockingTree bt ON r.blocking_session_id = bt.session_id
)
SELECT
    CASE WHEN bt.LevelNo = 0 THEN 'HEAD BLOCKER' ELSE 'BLOCKED' END AS BlockingLevel,
    bt.BlockingChain,
    CASE WHEN bt.LevelNo = 0 THEN r.session_id ELSE r.blocking_session_id END AS BlockingSessionId,
    CASE WHEN bt.LevelNo = 0 THEN NULL ELSE r.session_id END AS BlockedSessionId,
    s.login_name AS LoginName,
    s.host_name AS HostName,
    s.program_name AS ProgramName,
    DB_NAME(r.database_id) AS DatabaseName,
    r.status AS RequestStatus,
    r.command AS Command,
    r.wait_type AS WaitType,
    r.wait_time AS WaitTimeMs,
    r.wait_time / 1000.0 AS WaitSeconds,
    r.cpu_time AS CpuTimeMs,
    r.total_elapsed_time / 1000.0 AS ElapsedSeconds,
    SUBSTRING(st.text, (r.statement_start_offset/2)+1,
        ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE r.statement_end_offset END
          - r.statement_start_offset)/2)+1) AS RunningStatement,
    st.text AS BatchText,
    st.text AS BlockedStatement
FROM BlockingTree bt
INNER JOIN sys.dm_exec_requests r ON bt.session_id = r.session_id
INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) st
ORDER BY bt.BlockingChain
OPTION (MAXRECURSION 100);
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
                BlockingLevel     = [string]$reader["BlockingLevel"]
                BlockingChain     = [string]$reader["BlockingChain"]
                BlockingSessionId = [int]$reader["BlockingSessionId"]
                BlockedSessionId  = if ($reader.IsDBNull($reader.GetOrdinal("BlockedSessionId"))) { $null } else { [int]$reader["BlockedSessionId"] }
                LoginName         = [string]$reader["LoginName"]
                HostName          = [string]$reader["HostName"]
                ProgramName       = [string]$reader["ProgramName"]
                DatabaseName      = if ($reader.IsDBNull($reader.GetOrdinal("DatabaseName"))) { $null } else { [string]$reader["DatabaseName"] }
                RequestStatus     = [string]$reader["RequestStatus"]
                Command           = [string]$reader["Command"]
                WaitType          = if ($reader.IsDBNull($reader.GetOrdinal("WaitType")))          { $null } else { [string]$reader["WaitType"] }
                WaitTimeMs        = [int]$reader["WaitTimeMs"]
                WaitSeconds       = [double]$reader["WaitSeconds"]
                CpuTimeMs         = [int]$reader["CpuTimeMs"]
                ElapsedSeconds    = [double]$reader["ElapsedSeconds"]
                RunningStatement  = if ($reader.IsDBNull($reader.GetOrdinal("RunningStatement"))) { $null } else { [string]$reader["RunningStatement"] }
                BatchText         = if ($reader.IsDBNull($reader.GetOrdinal("BatchText"))) { $null } else { [string]$reader["BatchText"] }
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
