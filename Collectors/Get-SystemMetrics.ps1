# Collector: System CPU and Memory
# Collects OS-level CPU/Memory AND SQL Server process CPU/memory from ring buffer + DMVs

function Get-SystemMetrics {
    param(
        [string]$ConnectionString,
        [int]$InstanceId
    )

    $collectedAt = [DateTime]::UtcNow

    $sql = @"
-- SQL CPU from ring buffer (most recent scheduler monitor record)
DECLARE @CpuXml XML;
SELECT TOP 1 @CpuXml = CONVERT(XML, record)
FROM sys.dm_os_ring_buffers
WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
ORDER BY timestamp DESC;

DECLARE @SqlCpu  INT = @CpuXml.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int');
DECLARE @SysIdle INT = @CpuXml.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int');
DECLARE @SysCpu  INT = 100 - @SysIdle;

-- Memory from DMVs
SELECT
    @SqlCpu                                                    AS SqlCpuPercent,
    @SysCpu                                                    AS SystemCpuPercent,
    om.total_physical_memory_kb   / 1024                       AS TotalMemoryMB,
    om.available_physical_memory_kb / 1024                     AS AvailableMemoryMB,
    pm.physical_memory_in_use_kb  / 1024                       AS SqlMemoryUsedMB,
    mc.value_in_use                                            AS SqlMemoryTargetMB,
    om.system_memory_state_desc                                AS MemoryState,
    pm.page_fault_count                                        AS PageFaults
FROM sys.dm_os_sys_memory         AS om
CROSS JOIN sys.dm_os_process_memory AS pm
CROSS APPLY (
    SELECT value_in_use
    FROM sys.configurations
    WHERE name = 'max server memory (MB)'
) AS mc;
"@

    try {
        $conn = New-Object Microsoft.Data.SqlClient.SqlConnection($ConnectionString)
        $conn.Open()
        $cmd  = $conn.CreateCommand()
        $cmd.CommandText    = $sql
        $cmd.CommandTimeout = 30

        $reader = $cmd.ExecuteReader()
        $result = $null
        if ($reader.Read()) {
            $result = [PSCustomObject]@{
                InstanceId        = $InstanceId
                CollectedAt       = $collectedAt
                SqlCpuPercent     = [int]$reader["SqlCpuPercent"]
                SystemCpuPercent  = [int]$reader["SystemCpuPercent"]
                TotalMemoryMB     = [long]$reader["TotalMemoryMB"]
                AvailableMemoryMB = [long]$reader["AvailableMemoryMB"]
                SqlMemoryUsedMB   = [long]$reader["SqlMemoryUsedMB"]
                SqlMemoryTargetMB = [long]$reader["SqlMemoryTargetMB"]
                MemoryState       = [string]$reader["MemoryState"]
                PageFaults        = [long]$reader["PageFaults"]
            }
        }
        $reader.Close()
        $conn.Close()
        return $result
    }
    catch {
        Write-Warning "[$($MyInvocation.MyCommand)] Instance $InstanceId : $_"
        return $null
    }
    finally {
        if ($conn.State -ne 'Closed') { $conn.Close() }
    }
}
