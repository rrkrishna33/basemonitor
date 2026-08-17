# Collector: Wait Statistics
# Returns the top 30 waits by total wait time, excluding benign/idle waits

function Get-WaitStats {
    param(
        [string]$ConnectionString,
        [int]$InstanceId
    )

    $collectedAt = [DateTime]::UtcNow

    $sql = @"
WITH WaitsFiltered AS (
    SELECT
        wait_type,
        waiting_tasks_count,
        wait_time_ms,
        max_wait_time_ms,
        signal_wait_time_ms
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN (
        -- Benign / idle waits to exclude
        'SLEEP_TASK','SLEEP_SYSTEMTASK','SLEEP_DBSTARTUP','SLEEP_DCOMSTARTUP',
        'SLEEP_MASTERMDREADY','SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP',
        'SLEEP_TEMPDBSTARTUP','SNI_HTTP_ACCEPT','DISPATCHER_QUEUE_SEMAPHORE',
        'XE_DISPATCHER_WAIT','XE_TIMER_EVENT','REDO_THREAD_PENDING_WORK',
        'BROKER_TO_FLUSH','BROKER_TASK_STOP','BROKER_EVENTHANDLER',
        'CHECKPOINT_QUEUE','DBMIRROR_EVENTS_QUEUE','SQLTRACE_BUFFER_FLUSH',
        'CLR_AUTO_EVENT','CLR_MANUAL_EVENT','DISPATCHER_QUEUE_SEMAPHORE',
        'FT_IFTS_SCHEDULER_IDLE_WAIT','HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        'HADR_WORK_QUEUE','HADR_TIMER_TASK','HADR_THROTTLE_LOG_RATE_GOVERNOR',
        'ONDEMAND_TASK_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH','RESOURCE_QUEUE',
        'SERVER_IDLE_CHECK','SLEEP_DBSTARTUP','SLEEP_DCOMSTARTUP',
        'SLEEP_MASTERMDREADY','SLEEP_MASTERUPGRADED','SLEEP_MASTERSTARTED',
        'SLEEP_TEMPDBSTARTUP','SNI_HTTP_ACCEPT','SP_SERVER_DIAGNOSTICS_SLEEP',
        'SQLTRACE_INCREMENTAL_FLUSH_SLEEP','WAITFOR','WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
        'XE_DISPATCHER_WAIT','XE_TIMER_EVENT','LAZYWRITER_SLEEP','LOGMGR_QUEUE',
        'DIRTY_PAGE_POLL','HADR_FILESTREAM_IOMGR_IOCOMPLETION'
    )
    AND waiting_tasks_count > 0
)
SELECT TOP 30
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    signal_wait_time_ms
FROM WaitsFiltered
ORDER BY wait_time_ms DESC;
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
                InstanceId          = $InstanceId
                CollectedAt         = $collectedAt
                WaitType            = [string]$reader["wait_type"]
                WaitingTasksCount   = [long]$reader["waiting_tasks_count"]
                WaitTimeMs          = [long]$reader["wait_time_ms"]
                MaxWaitTimeMs       = [long]$reader["max_wait_time_ms"]
                SignalWaitTimeMs    = [long]$reader["signal_wait_time_ms"]
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
