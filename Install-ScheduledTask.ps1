<#
.SYNOPSIS
    Registers the SQL Metrics Service as a Windows Scheduled Task.
.DESCRIPTION
    - Installs the Microsoft.Data.SqlClient NuGet package (via nuget.exe or dotnet)
    - Creates a Scheduled Task that runs Start-MetricsService.ps1 at startup
      and repeats every minute, running as SYSTEM (or a specified service account).
.PARAMETER ServiceAccount
    Domain\Username to run the task as. Defaults to SYSTEM (no password needed).
.PARAMETER Password
    Password for ServiceAccount. Not needed when using SYSTEM.
.EXAMPLE
    .\Install-ScheduledTask.ps1
    .\Install-ScheduledTask.ps1 -ServiceAccount "DOMAIN\svc_sqlmon" -Password "P@ssw0rd"
#>
param(
    [string]$ServiceAccount = "SYSTEM",
    [string]$Password       = ""
)

#Requires -RunAsAdministrator

$scriptRoot  = $PSScriptRoot
$taskName    = "SqlMetricsService"
$description = "Collects SQL Server performance metrics from monitored instances"
$scriptPath  = Join-Path $scriptRoot "Start-MetricsService.ps1"

# ------------------------------------------------------------------
# Step 1: Ensure Microsoft.Data.SqlClient is available
# Try via SqlServer module first (most widely available)
# ------------------------------------------------------------------
Write-Host "[Setup] Checking Microsoft.Data.SqlClient availability..."

$sqlClientAvailable = $false

# Option A: SqlServer PowerShell module
if (Get-Module -ListAvailable -Name SqlServer -ErrorAction SilentlyContinue) {
    Write-Host "[Setup] SqlServer module found. SqlClient is available."
    $sqlClientAvailable = $true
} else {
    Write-Host "[Setup] SqlServer module not found. Attempting to install..."
    try {
        Install-Module -Name SqlServer -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Write-Host "[Setup] SqlServer module installed."
        $sqlClientAvailable = $true
    }
    catch {
        Write-Warning "[Setup] Could not install SqlServer module: $_"
    }
}

# Option B: dotnet tool / NuGet fallback
if (-not $sqlClientAvailable) {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($dotnet) {
        Write-Host "[Setup] Downloading Microsoft.Data.SqlClient via dotnet..."
        $tempDir = Join-Path $env:TEMP "sqlclient_nuget"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        & dotnet nuget install Microsoft.Data.SqlClient --output $tempDir 2>&1 | Out-Null
        $dll = Get-ChildItem $tempDir -Recurse -Filter "Microsoft.Data.SqlClient.dll" |
               Where-Object { $_.FullName -match "net6|net8|netstandard2" } | Select-Object -Last 1
        if ($dll) {
            Write-Host "[Setup] Found SqlClient DLL at: $($dll.FullName)"
            $sqlClientAvailable = $true
        }
    }
}

if (-not $sqlClientAvailable) {
    Write-Warning @"
[Setup] WARNING: Could not auto-install Microsoft.Data.SqlClient.
The service needs it at runtime. Options:
  1. Install-Module SqlServer -Scope AllUsers
  2. Install dotnet SDK and re-run this script
  3. Place Microsoft.Data.SqlClient.dll in $scriptRoot\lib\
"@
}

# ------------------------------------------------------------------
# Step 2: Register the Scheduled Task
# ------------------------------------------------------------------
Write-Host "[Setup] Registering Scheduled Task '$taskName'..."

$psExe  = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $psExe) { $psExe = (Get-Command powershell).Source }

$action = New-ScheduledTaskAction `
    -Execute  $psExe `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`"" `
    -WorkingDirectory $scriptRoot

# Trigger: at system startup, with 1-minute repeat indefinitely
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.RepetitionInterval = [TimeSpan]::FromSeconds(60)
$trigger.RepetitionDuration = [TimeSpan]::MaxValue

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances    IgnoreNew `
    -ExecutionTimeLimit   ([TimeSpan]::Zero) `
    -RestartCount         3 `
    -RestartInterval      ([TimeSpan]::FromMinutes(1)) `
    -RunOnlyIfNetworkAvailable

if ($ServiceAccount -eq "SYSTEM") {
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
} else {
    $principal = New-ScheduledTaskPrincipal -UserId $ServiceAccount -LogonType Password -RunLevel Highest
}

# Remove existing task if present
Unregister-ScheduledTask -TaskName $taskName -TaskPath "\" -Confirm:$false -ErrorAction SilentlyContinue

$regParams = @{
    TaskName    = $taskName
    TaskPath    = "\"
    Description = $description
    Action      = $action
    Trigger     = $trigger
    Settings    = $settings
    Principal   = $principal
    Force       = $true
}

if ($ServiceAccount -ne "SYSTEM" -and $Password -ne "") {
    $regParams["Password"] = $Password
}

Register-ScheduledTask @regParams | Out-Null

Write-Host "[Setup] Scheduled Task '$taskName' registered successfully."
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Edit Config\config.json with your SQL Server details"
Write-Host "  2. Run SQL\Create-Schema.sql on your central metrics database"
Write-Host "  3. Start the task: Start-ScheduledTask -TaskName '$taskName'"
Write-Host "  4. Monitor logs at: $(($null -ne (Get-Content Config\config.json -Raw | ConvertFrom-Json).LogPath) ? (Get-Content Config\config.json -Raw | ConvertFrom-Json).LogPath : 'C:\Logs\SqlMetricsService')"
