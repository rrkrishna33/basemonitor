<#
.SYNOPSIS
    SQL Server Metrics Collection Service — main loop
.DESCRIPTION
    Collects CPU, memory, wait stats, top queries, database sizes,
    connections/blocking, disk I/O, and index fragmentation from
    multiple SQL Server instances in PARALLEL and stores them in a
    central database. Supports 70+ instances with parallel collection.
.NOTES
    Run directly: .\Start-MetricsService.ps1
    Run as Windows Scheduled Task: use Install-ScheduledTask.ps1
    Requires PowerShell 7+ for parallel execution.
#>

param(
    [string]$ConfigPath    = "$PSScriptRoot\Config\config.json",
    [int]$ParallelBatchSize = 50   # max concurrent instances
)

$ErrorActionPreference = "Continue"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or higher is required. Install from: https://aka.ms/powershell"
}

# ------------------------------------------------------------------
# Bootstrap: load required assembly and scripts
# ------------------------------------------------------------------

# Prefer the SqlServer module (bundles Microsoft.Data.SqlClient)
if (Get-Module -ListAvailable -Name SqlServer -ErrorAction SilentlyContinue) {
    Import-Module SqlServer -ErrorAction Stop
}

# Verify the type is now available; if not, try locating the net6 copy shipped
# with the SQL Server module. The default WindowsPowerShell module bundle can
# load an incompatible SqlClient assembly in PowerShell 7.
if (-not ([System.Management.Automation.PSTypeName]'Microsoft.Data.SqlClient.SqlConnection').Type) {
    $candidatePaths = @(
        "C:\Program Files\WindowsPowerShell\Modules\SqlServer\*\coreclr\runtimes\win\lib\net6.0\Microsoft.Data.SqlClient.dll",
        "C:\Program Files\PowerShell\Modules\SqlServer\*\coreclr\runtimes\win\lib\net6.0\Microsoft.Data.SqlClient.dll",
        "$env:USERPROFILE\.nuget\packages\microsoft.data.sqlclient\**\Microsoft.Data.SqlClient.dll",
        "C:\Program Files\dotnet\shared\**\Microsoft.Data.SqlClient.dll"
    )

    $assemblyPath = $null
    foreach ($pattern in $candidatePaths) {
        $matches = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if ($matches) {
            $assemblyPath = $matches
            break
        }
    }

    if ($assemblyPath) {
        Add-Type -Path $assemblyPath
    } else {
        throw "Cannot find Microsoft.Data.SqlClient. Install the SqlServer module: Install-Module SqlServer -Scope AllUsers"
    }
}

# Load helper scripts
. "$PSScriptRoot\Collectors\Get-SystemMetrics.ps1"
. "$PSScriptRoot\Collectors\Get-WaitStats.ps1"
. "$PSScriptRoot\Collectors\Get-TopQueries.ps1"
. "$PSScriptRoot\Collectors\Get-DatabaseSizes.ps1"
. "$PSScriptRoot\Collectors\Get-Connections.ps1"
. "$PSScriptRoot\Collectors\Get-DiskIOStats.ps1"
. "$PSScriptRoot\Collectors\Get-IndexFragmentation.ps1"
. "$PSScriptRoot\Storage\Save-Metrics.ps1"

# ------------------------------------------------------------------
# Load config
# ------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$centralConnStr   = $cfg.CentralConnectionString
$intervalSec      = [int]$cfg.CollectionIntervalSeconds
$queryIntervalSec = [int]$cfg.QueryCollectionIntervalSeconds
$databaseSizeIntervalSec = if ($cfg.DatabaseSizeIntervalSeconds) { [int]$cfg.DatabaseSizeIntervalSeconds } else { 300 }
$diskIoIntervalSec = if ($cfg.DiskIOIntervalSeconds) { [int]$cfg.DiskIOIntervalSeconds } else { 300 }
$tempDbIntervalSec = if ($cfg.TempDbIntervalSeconds) { [int]$cfg.TempDbIntervalSeconds } else { 300 }
$logStatsIntervalSec = if ($cfg.LogStatsIntervalSeconds) { [int]$cfg.LogStatsIntervalSeconds } else { 300 }
$backupHealthIntervalSec = if ($cfg.BackupHealthIntervalSeconds) { [int]$cfg.BackupHealthIntervalSeconds } else { 300 }
$agentHealthIntervalSec = if ($cfg.AgentHealthIntervalSeconds) { [int]$cfg.AgentHealthIntervalSeconds } else { 300 }
$indexHealthIntervalSec = if ($cfg.IndexHealthIntervalSeconds) { [int]$cfg.IndexHealthIntervalSeconds } else { 3600 }
$fragIntervalSec      = [int]$cfg.FragmentationIntervalSeconds
$fragDbTimeoutSec     = if ($cfg.FragmentationDbTimeoutSeconds) { [int]$cfg.FragmentationDbTimeoutSeconds } else { 600 }
$fragMinPageCount     = if ($cfg.FragmentationMinPageCount)      { [int]$cfg.FragmentationMinPageCount      } else { 200 }
$fragExcludeDbs       = if ($cfg.FragmentationExcludeDatabases)  { [string[]]$cfg.FragmentationExcludeDatabases } else { @() }
$retentionDays    = [int]$cfg.RetentionDays
$instances        = $cfg.MonitoredInstances

# ------------------------------------------------------------------
# Logging  (thread-safe via mutex)
# ------------------------------------------------------------------
$logDir   = $cfg.LogPath
$logMutex = [System.Threading.Mutex]::new($false, "SqlMetricsLogMutex")
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } default { 'Cyan' } }
    Write-Host $entry -ForegroundColor $color
    $logFile = Join-Path $logDir "metrics_$(Get-Date -Format 'yyyyMMdd').log"
    try {
        $logMutex.WaitOne(2000) | Out-Null
        Add-Content -Path $logFile -Value $entry -Encoding UTF8
    } finally { $logMutex.ReleaseMutex() }
}

# ------------------------------------------------------------------
# Central DB connection helper
# ------------------------------------------------------------------
function Open-CentralConnection {
    $conn = New-Object Microsoft.Data.SqlClient.SqlConnection($centralConnStr)
    $conn.Open()
    return $conn
}

# ------------------------------------------------------------------
# Timers
# ------------------------------------------------------------------
# NOTE: FragCollect starts at "now" (not MinValue) so cycle #1 does not
# immediately trigger a long, per-database fragmentation scan and block
# the core metrics/backup/agent collection from ever completing.
$lastQueryCollect = [DateTime]::MinValue
$lastDatabaseSizeCollect = [DateTime]::UtcNow
$lastDiskIoCollect = [DateTime]::UtcNow
$lastTempDbCollect = [DateTime]::UtcNow
$lastLogStatsCollect = [DateTime]::UtcNow
$lastBackupHealthCollect = [DateTime]::UtcNow
$lastAgentHealthCollect = [DateTime]::UtcNow
$lastIndexHealthCollect = [DateTime]::UtcNow
$lastFragCollect  = [DateTime]::UtcNow
$lastPurge        = [DateTime]::MinValue

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║        SQL Monitor — Metrics Collection Service                  ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Started    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host "  Instances  : $($instances.Count)" -ForegroundColor White
Write-Host "  Intervals  : Core=${intervalSec}s  |  Query=${queryIntervalSec}s  |  Snapshots=300s  |  IndexHealth=${indexHealthIntervalSec}s  |  Frag=${fragIntervalSec}s" -ForegroundColor White
Write-Host "  Parallel   : $ParallelBatchSize concurrent" -ForegroundColor White
Write-Host "  Log Path   : $logDir" -ForegroundColor DarkGray
Write-Host ""
Write-Log "INFO" "Service started. $($instances.Count) instances registered."

# Pre-register all instances and cache their IDs
$instanceIdMap = [System.Collections.Concurrent.ConcurrentDictionary[string,int]]::new()
try {
    $centralConn = Open-CentralConnection
    foreach ($inst in $instances) {
        $id = Get-OrCreateInstanceId -Conn $centralConn -InstanceName $inst.Name -Tags $inst.Tags
        $instanceIdMap[$inst.Name] = $id
    }
    $centralConn.Close()
    Write-Log "INFO" "Registered $($instanceIdMap.Count) instances in central DB."
}
catch {
    Write-Log "ERROR" "Failed to connect to central DB or register instances: $_"
    exit 1
}

# Build a plain hashtable (serializable across runspaces) from the ConcurrentDictionary
$instanceIdHash = @{}
foreach ($kv in $instanceIdMap.GetEnumerator()) { $instanceIdHash[$kv.Key] = $kv.Value }

# ------------------------------------------------------------------
# Per-instance collector — runs inside parallel runspace
# ------------------------------------------------------------------
$scriptRoot      = $PSScriptRoot
$centralConnStr_ = $centralConnStr   # closure copy

function Invoke-InstanceCollection {
    param(
        [string]  $InstName,
        [string]  $ConnStr,
        [int]     $InstanceId,
        [bool]    $CollectQuery,
        [bool]    $CollectFrag,
        [string]  $ScriptRoot,
        [string]  $CentralConnStr
    )

    $logs = [System.Collections.Generic.List[string]]::new()
    function L([string]$lvl, [string]$msg) { $logs.Add("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$lvl] [$InstName] $msg") }

    # Load scripts in this runspace
    . "$ScriptRoot\Collectors\Get-SystemMetrics.ps1"
    . "$ScriptRoot\Collectors\Get-WaitStats.ps1"
    . "$ScriptRoot\Collectors\Get-TopQueries.ps1"
    . "$ScriptRoot\Collectors\Get-DatabaseSizes.ps1"
    . "$ScriptRoot\Collectors\Get-Connections.ps1"
    . "$ScriptRoot\Collectors\Get-DiskIOStats.ps1"
    . "$ScriptRoot\Collectors\Get-IndexFragmentation.ps1"
            . "$ScriptRoot\Collectors\Get-TempDbStats.ps1"
            . "$ScriptRoot\Collectors\Get-LogFileStats.ps1"
            . "$ScriptRoot\Collectors\Get-IndexHealth.ps1"
            . "$ScriptRoot\Collectors\Get-BackupHealth.ps1"
            . "$ScriptRoot\Collectors\Get-AgentHealth.ps1"
    # Open dedicated central connection for this parallel worker
    $cConn = New-Object Microsoft.Data.SqlClient.SqlConnection($CentralConnStr)
    try {
        $cConn.Open()

        # 1. System CPU + Memory
        try {
            $sysMet = Get-SystemMetrics -ConnectionString $ConnStr -InstanceId $InstanceId
            Save-SystemMetric -Conn $cConn -Metric $sysMet
            L "INFO" "[SystemMetrics] SQL CPU=$($sysMet.SqlCpuPercent)% SysCPU=$($sysMet.SystemCpuPercent)% MemUsed=$($sysMet.SqlMemoryUsedMB)MB"
        } catch { L "WARN" "[SystemMetrics] $_" }

        # 2. Wait Stats
        try {
            $waits = Get-WaitStats -ConnectionString $ConnStr -InstanceId $InstanceId
            Save-WaitStats -Conn $cConn -Rows $waits
            L "INFO" "[WaitStats] Saved $($waits.Count) wait types"
        } catch { L "WARN" "[WaitStats] $_" }

        # 3. Database Sizes
        try {
            $dbSizes = Get-DatabaseSizes -ConnectionString $ConnStr -InstanceId $InstanceId
            Save-DatabaseSizes -Conn $cConn -Rows $dbSizes
            L "INFO" "[DatabaseSizes] Saved $($dbSizes.Count) databases"
        } catch { L "WARN" "[DatabaseSizes] $_" }

        # 4. Connections + Blocking
        try {
            $connData = Get-Connections -ConnectionString $ConnStr -InstanceId $InstanceId
            Save-ConnectionSnapshot -Conn $cConn -Snapshot $connData.Snapshot
            Save-BlockingChains     -Conn $cConn -Rows $connData.Blockings
            L "INFO" "[Connections] Total=$($connData.Snapshot.TotalSessions) Blocked=$($connData.Snapshot.BlockedSessions) BlockingChains=$($connData.Blockings.Count)"
        } catch { L "WARN" "[Connections] $_" }

        # 5. Disk I/O
        try {
            $diskIO = Get-DiskIOStats -ConnectionString $ConnStr -InstanceId $InstanceId
            Save-DiskIOStats -Conn $cConn -Rows $diskIO
            L "INFO" "[DiskIO] Saved $($diskIO.Count) file entries"
        } catch { L "WARN" "[DiskIO] $_" }

        # 6. Top Queries (less frequent)
        if ($CollectQuery) {
            try {
                $queries = Get-TopQueries -ConnectionString $ConnStr -InstanceId $InstanceId
                Save-TopQueries -Conn $cConn -Rows $queries
                L "INFO" "[TopQueries] Saved $($queries.Count) queries"
            } catch { L "WARN" "[TopQueries] $_" }
        }

        # 7. Index Fragmentation (hourly)
        if ($CollectFrag) {
            try {
                L "INFO" "[IndexFrag] Starting scan..."
                $frags = Get-IndexFragmentation -ConnectionString $ConnStr -InstanceId $InstanceId `
                    -DbTimeoutSeconds $fragDbTimeoutSec -MinPageCount $fragMinPageCount -ExcludeDatabases $fragExcludeDbs
                Save-IndexFragStats -Conn $cConn -Rows $frags
                L "INFO" "[IndexFrag] Saved $($frags.Count) index entries"
            } catch { L "WARN" "[IndexFrag] $_" }
        }
    }
    catch { L "ERROR" "Worker failed: $_" }
    finally { if ($cConn.State -ne 'Closed') { $cConn.Close() } }

    return $logs
}

# ------------------------------------------------------------------
# Main collection loop
# ------------------------------------------------------------------
$cycleNum = 0
while ($true) {
    $loopStart    = [DateTime]::UtcNow
    $collectQuery = ($loopStart - $lastQueryCollect).TotalSeconds -ge $queryIntervalSec
    $collectDatabaseSize = ($loopStart - $lastDatabaseSizeCollect).TotalSeconds -ge $databaseSizeIntervalSec
    $collectDiskIo = ($loopStart - $lastDiskIoCollect).TotalSeconds -ge $diskIoIntervalSec
    $collectTempDb = ($loopStart - $lastTempDbCollect).TotalSeconds -ge $tempDbIntervalSec
    $collectLogStats = ($loopStart - $lastLogStatsCollect).TotalSeconds -ge $logStatsIntervalSec
    $collectBackupHealth = ($loopStart - $lastBackupHealthCollect).TotalSeconds -ge $backupHealthIntervalSec
    $collectAgentHealth = ($loopStart - $lastAgentHealthCollect).TotalSeconds -ge $agentHealthIntervalSec
    $collectIndexHealth = ($loopStart - $lastIndexHealthCollect).TotalSeconds -ge $indexHealthIntervalSec
    $collectFrag  = ($loopStart - $lastFragCollect).TotalSeconds  -ge $fragIntervalSec
    $doPurge      = ($loopStart - $lastPurge).TotalSeconds        -ge 86400
    $cycleNum++

    $extras = @()
    if ($collectQuery) { $extras += 'Queries' }
    if ($collectDatabaseSize) { $extras += 'DBSizes' }
    if ($collectDiskIo) { $extras += 'DiskIO' }
    if ($collectTempDb) { $extras += 'TempDB' }
    if ($collectLogStats) { $extras += 'LogStats' }
    if ($collectBackupHealth) { $extras += 'Backups' }
    if ($collectAgentHealth) { $extras += 'Agent' }
    if ($collectIndexHealth) { $extras += 'IndexHealth' }
    if ($collectFrag)  { $extras += 'IndexFrag' }
    $extraTag = if ($extras) { "  +$($extras -join ' +')" } else { '' }

    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────────────────────" -ForegroundColor Magenta
    Write-Host "  │  Cycle #$cycleNum   $(Get-Date -Format 'HH:mm:ss')   $($instances.Count) instances$extraTag" -ForegroundColor Magenta
    Write-Host "  └─────────────────────────────────────────────────────────────────" -ForegroundColor Magenta
    Write-Log "INFO" "Cycle #$cycleNum started — $($instances.Count) instances$extraTag"

    try {
        # Collect all instances in parallel batches of $ParallelBatchSize
        $allLogs = $instances | ForEach-Object -Parallel {
            $inst          = $_
            $idHash        = $using:instanceIdHash
            $instId        = $idHash[$inst.Name]
            $cq            = $using:collectQuery
            $cdb           = $using:collectDatabaseSize
            $cio           = $using:collectDiskIo
            $ctd           = $using:collectTempDb
            $cls           = $using:collectLogStats
            $cbh           = $using:collectBackupHealth
            $cah           = $using:collectAgentHealth
            $cih           = $using:collectIndexHealth
            $cf            = $using:collectFrag
            $sr            = $using:scriptRoot
            $cc            = $using:centralConnStr_

            # Inline the function since parallel runspaces don't inherit functions
            $logs = [System.Collections.Generic.List[string]]::new()
            function L([string]$lvl, [string]$msg) {
                $logs.Add("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$lvl] [$($inst.Name)] $msg")
            }

            . "$sr\Collectors\Get-SystemMetrics.ps1"
            . "$sr\Collectors\Get-WaitStats.ps1"
            . "$sr\Collectors\Get-TopQueries.ps1"
            . "$sr\Collectors\Get-DatabaseSizes.ps1"
            . "$sr\Collectors\Get-Connections.ps1"
            . "$sr\Collectors\Get-DiskIOStats.ps1"
            . "$sr\Collectors\Get-IndexFragmentation.ps1"
            . "$sr\Collectors\Get-TempDbStats.ps1"
            . "$sr\Collectors\Get-LogFileStats.ps1"
            . "$sr\Collectors\Get-IndexHealth.ps1"
            . "$sr\Collectors\Get-BackupHealth.ps1"
            . "$sr\Collectors\Get-AgentHealth.ps1"
            . "$sr\Storage\Save-Metrics.ps1"

            $cConn = New-Object Microsoft.Data.SqlClient.SqlConnection($cc)
            try {
                $cConn.Open()

                try { $s = Get-SystemMetrics  -ConnectionString $inst.ConnectionString -InstanceId $instId; Save-SystemMetric  -Conn $cConn -Metric $s;  L "INFO" "[SystemMetrics] SQL CPU=$($s.SqlCpuPercent)% SysCPU=$($s.SystemCpuPercent)% MemUsed=$($s.SqlMemoryUsedMB)MB"  } catch { L "WARN" "[SystemMetrics] $_" }
                try { $w = Get-WaitStats      -ConnectionString $inst.ConnectionString -InstanceId $instId; Save-WaitStats     -Conn $cConn -Rows $w;     L "INFO" "[WaitStats] Saved $($w.Count) wait types"        } catch { L "WARN" "[WaitStats] $_" }
                if ($cdb) { try { $d = Get-DatabaseSizes  -ConnectionString $inst.ConnectionString -InstanceId $instId; Save-DatabaseSizes -Conn $cConn -Rows $d; L "INFO" "[DatabaseSizes] Saved $($d.Count) databases" } catch { L "WARN" "[DatabaseSizes] $_" } }
                try { $cn = Get-Connections   -ConnectionString $inst.ConnectionString -InstanceId $instId; Save-ConnectionSnapshot -Conn $cConn -Snapshot $cn.Snapshot; Save-BlockingChains -Conn $cConn -Rows $cn.Blockings; L "INFO" "[Connections] Total=$($cn.Snapshot.TotalSessions) Blocked=$($cn.Snapshot.BlockedSessions) Chains=$($cn.Blockings.Count)" } catch { L "WARN" "[Connections] $_" }
                if ($cio) { try { $io = Get-DiskIOStats   -ConnectionString $inst.ConnectionString -InstanceId $instId; Save-DiskIOStats   -Conn $cConn -Rows $io; L "INFO" "[DiskIO] Saved $($io.Count) file entries" } catch { L "WARN" "[DiskIO] $_" } }
                if ($ctd) { try { $tb = Get-TempDbStats -ConnectionString $inst.ConnectionString -InstanceId $instId; Save-TempDbStats -Conn $cConn -Rows $tb; L "INFO" "[TempDB] Saved $($tb.Count) tempdb file entries" } catch { L "WARN" "[TempDB] $_" } }
                if ($cls) { try { $lg = Get-LogFileStats -ConnectionString $inst.ConnectionString -InstanceId $instId; Save-LogFileStats -Conn $cConn -Rows $lg; L "INFO" "[LogStats] Saved $($lg.Count) log file entries" } catch { L "WARN" "[LogStats] $_" } }
                if ($cih) { try { $ih = Get-IndexHealth -ConnectionString $inst.ConnectionString -InstanceId $instId; Save-IndexHealth -Conn $cConn -Result $ih; L "INFO" "[IndexHealth] Missing=$($ih.Missing.Count) Unused=$($ih.Unused.Count)" } catch { L "WARN" "[IndexHealth] $_" } }
                if ($cbh) { try { $bk = Get-BackupHealth -ConnectionString $inst.ConnectionString -InstanceId $instId; Save-BackupStatus -Conn $cConn -Rows $bk; L "INFO" "[BackupStatus] Saved $($bk.Count) backup rows" } catch { L "WARN" "[BackupStatus] $_" } }
                if ($cah) { try { $aj = Get-AgentHealth -ConnectionString $inst.ConnectionString -InstanceId $instId; Save-AgentJobHealth -Conn $cConn -Rows $aj; L "INFO" "[AgentHealth] Saved $($aj.Count) job rows" } catch { L "WARN" "[AgentHealth] $_" } }
                if ($cq) { try { $q = Get-TopQueries -ConnectionString $inst.ConnectionString -InstanceId $instId; Save-TopQueries -Conn $cConn -Rows $q; L "INFO" "[TopQueries] Saved $($q.Count) queries" } catch { L "WARN" "[TopQueries] $_" } }
                if ($cf) { try { $f = Get-IndexFragmentation -ConnectionString $inst.ConnectionString -InstanceId $instId; Save-IndexFragStats -Conn $cConn -Rows $f; L "INFO" "[IndexFrag] Saved $($f.Count) index entries" } catch { L "WARN" "[IndexFrag] $_" } }
            }
            catch { L "ERROR" "Worker error: $_" }
            finally { if ($cConn.State -ne 'Closed') { $cConn.Close() } }

            return $logs

        } -ThrottleLimit $ParallelBatchSize

        # Flush all collected log lines in order (with colour)
        foreach ($logBatch in $allLogs) {
            foreach ($line in $logBatch) {
                $lvl_   = if ($line -match '\[(ERROR|WARN|INFO)\]') { $Matches[1] } else { 'INFO' }
                $color_ = switch ($lvl_) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
                Write-Host $line -ForegroundColor $color_
                try {
                    $logMutex.WaitOne(2000) | Out-Null
                    Add-Content -Path (Join-Path $logDir "metrics_$(Get-Date -Format 'yyyyMMdd').log") -Value $line -Encoding UTF8
                } finally { $logMutex.ReleaseMutex() }
            }
        }

        # Purge old data (daily) — single connection
        if ($doPurge) {
            try {
                $pConn = Open-CentralConnection
                Invoke-Purge -Conn $pConn -RetentionDays $retentionDays
                $pConn.Close()
                Write-Log "INFO" "Purged data older than $retentionDays days"
                $lastPurge = [DateTime]::UtcNow
            }
            catch { Write-Log "WARN" "Purge failed: $_" }
        }
    }
    catch {
        Write-Log "ERROR" "Collection loop error: $_"
    }

    if ($collectQuery) { $lastQueryCollect = [DateTime]::UtcNow }
    if ($collectDatabaseSize) { $lastDatabaseSizeCollect = [DateTime]::UtcNow }
    if ($collectDiskIo) { $lastDiskIoCollect = [DateTime]::UtcNow }
    if ($collectTempDb) { $lastTempDbCollect = [DateTime]::UtcNow }
    if ($collectLogStats) { $lastLogStatsCollect = [DateTime]::UtcNow }
    if ($collectBackupHealth) { $lastBackupHealthCollect = [DateTime]::UtcNow }
    if ($collectAgentHealth) { $lastAgentHealthCollect = [DateTime]::UtcNow }
    if ($collectIndexHealth) { $lastIndexHealthCollect = [DateTime]::UtcNow }
    if ($collectFrag)  { $lastFragCollect  = [DateTime]::UtcNow }

    $elapsed = ([DateTime]::UtcNow - $loopStart).TotalSeconds
    $sleep   = [Math]::Max(1, $intervalSec - $elapsed)
    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────────────────────" -ForegroundColor Green
    Write-Host "  │  ✓ Cycle #$cycleNum complete   Elapsed: $([Math]::Round($elapsed,1))s   Next in: ${sleep}s   $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Green
    Write-Host "  └─────────────────────────────────────────────────────────────────" -ForegroundColor Green
    Write-Log "INFO" "Cycle #$cycleNum done in $([Math]::Round($elapsed,1))s. Next in ${sleep}s."
    Start-Sleep -Seconds $sleep
}


