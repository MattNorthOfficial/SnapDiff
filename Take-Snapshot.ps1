<#
.SYNOPSIS
    Captures a point-in-time snapshot of Windows configuration state for before/after comparison.

.DESCRIPTION
    Captures the areas of the system that tweaking tools typically modify:
      - Registry (targeted high-signal roots by default, or entire HKLM+HKCU with -Full)
      - Services (start mode + state)
      - Power settings (active scheme + full setting dump)
      - Scheduled tasks (enabled/disabled state)
      - TCP global parameters (netsh)
      - Network adapter advanced properties
      - Startup items
      - Boot configuration (bcdedit, admin only)

    Run as Administrator for full coverage. Compare two snapshots with Compare-Snapshots.ps1.

.EXAMPLE
    .\Take-Snapshot.ps1 -Name before
    # ...apply a tweak...
    .\Take-Snapshot.ps1 -Name after
    .\Compare-Snapshots.ps1 -Before before -After after

.EXAMPLE
    .\Take-Snapshot.ps1 -Name full-before -Full
    # Entire HKLM + HKCU. Slower and produces large files, but catches everything.
#>
[CmdletBinding()]
param(
    # Snapshot name; becomes the folder name under -OutputRoot.
    [string]$Name = ("snap-" + (Get-Date -Format "yyyyMMdd-HHmmss")),

    # Where snapshot folders are stored.
    [string]$OutputRoot = (Join-Path $PSScriptRoot "snapshots"),

    # Export the entire HKLM and HKCU hives instead of the targeted default roots.
    [switch]$Full,

    # Override the registry roots to export (e.g. "HKCU\SOFTWARE\MyApp").
    [string[]]$RegistryRoots,

    # Skip registry export entirely (captures only services/power/tasks/network/startup).
    [switch]$SkipRegistry
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$errors = New-Object System.Collections.Generic.List[string]

function Write-Step([string]$msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }

function Invoke-Capture {
    param([string]$Label, [scriptblock]$Action)
    Write-Step $Label
    try { & $Action }
    catch {
        $msg = "$Label failed: $($_.Exception.Message)"
        Write-Warning $msg
        $errors.Add($msg) | Out-Null
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Not running as Administrator. bcdedit will be skipped and some protected registry keys may be missing."
}

$snapDir = Join-Path $OutputRoot $Name
if (Test-Path $snapDir) { throw "Snapshot folder already exists: $snapDir  (pick a different -Name)" }
$regDir = Join-Path $snapDir 'registry'
New-Item -ItemType Directory -Path $regDir -Force | Out-Null

# --- Registry roots -----------------------------------------------------------
if (-not $RegistryRoots -or $RegistryRoots.Count -eq 0) {
    if ($Full) {
        $RegistryRoots = @('HKLM\SOFTWARE', 'HKLM\SYSTEM', 'HKCU')
    }
    else {
        # High-signal areas that gaming/latency tweaks actually touch.
        $RegistryRoots = @(
            'HKLM\SYSTEM\CurrentControlSet\Control',            # scheduler, session manager, power, device classes
            'HKLM\SYSTEM\CurrentControlSet\Services',           # all service config + driver parameters (Tcpip, NDIS...)
            'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion',   # run keys, policies, delivery optimization...
            'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion', # Multimedia SystemProfile, Image File Execution Options...
            'HKLM\SOFTWARE\Policies',                           # group-policy style tweaks
            'HKCU\Control Panel',                               # mouse, desktop, visual effects
            'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion',   # per-user run keys, ContentDeliveryManager...
            'HKCU\SOFTWARE\Microsoft\GameBar',                  # Game Bar / Game Mode
            'HKCU\System\GameConfigStore'                       # Game DVR, fullscreen optimizations
        )
    }
}

if (-not $SkipRegistry) {
    foreach ($root in $RegistryRoots) {
        $fileName = ($root -replace '[\\/:]', '_') + '.reg'
        $dest = Join-Path $regDir $fileName
        Write-Step "Exporting registry: $root"
        $null = & reg.exe export $root $dest /y 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dest)) {
            $msg = "Registry export failed for '$root' (exit $LASTEXITCODE). Key may not exist or access was denied."
            Write-Warning $msg
            $errors.Add($msg) | Out-Null
        }
    }
}

# --- Services ------------------------------------------------------------------
Invoke-Capture "Capturing services" {
    Get-CimInstance Win32_Service |
        Select-Object Name, DisplayName, StartMode, State, PathName |
        Sort-Object Name |
        ConvertTo-Json -Depth 3 |
        Set-Content -Path (Join-Path $snapDir 'services.json') -Encoding UTF8
}

# --- Power settings ------------------------------------------------------------
Invoke-Capture "Capturing power settings" {
    (& powercfg /getactivescheme) | Set-Content -Path (Join-Path $snapDir 'power-activescheme.txt') -Encoding UTF8
    (& powercfg /query)           | Set-Content -Path (Join-Path $snapDir 'power-query.txt') -Encoding UTF8
}

# --- Scheduled tasks -------------------------------------------------------------
Invoke-Capture "Capturing scheduled tasks" {
    Get-ScheduledTask | ForEach-Object {
        [pscustomobject]@{ Task = ($_.TaskPath + $_.TaskName); State = "$($_.State)" }
    } | Sort-Object Task | ConvertTo-Json -Depth 2 |
        Set-Content -Path (Join-Path $snapDir 'tasks.json') -Encoding UTF8
}

# --- TCP global parameters -------------------------------------------------------
Invoke-Capture "Capturing TCP global settings" {
    (& netsh int tcp show global) | Set-Content -Path (Join-Path $snapDir 'tcp-global.txt') -Encoding UTF8
}

# --- Network adapter advanced properties ----------------------------------------
Invoke-Capture "Capturing network adapter properties" {
    Get-NetAdapterAdvancedProperty -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ Adapter = $_.Name; Property = $_.DisplayName; Value = "$($_.DisplayValue)" }
    } | Sort-Object Adapter, Property | ConvertTo-Json -Depth 2 |
        Set-Content -Path (Join-Path $snapDir 'netadapters.json') -Encoding UTF8
}

# --- Startup items ----------------------------------------------------------------
Invoke-Capture "Capturing startup items" {
    Get-CimInstance Win32_StartupCommand |
        Select-Object Name, Command, Location, User |
        Sort-Object Location, Name |
        ConvertTo-Json -Depth 2 |
        Set-Content -Path (Join-Path $snapDir 'startup.json') -Encoding UTF8
}

# --- Boot configuration (admin only) ---------------------------------------------
if ($isAdmin) {
    Invoke-Capture "Capturing boot configuration (bcdedit)" {
        $bcd = & bcdedit /enum 2>&1
        if ($LASTEXITCODE -eq 0) {
            $bcd | Set-Content -Path (Join-Path $snapDir 'bcdedit.txt') -Encoding UTF8
        } else { throw "bcdedit exited with $LASTEXITCODE" }
    }
}

# --- Metadata ---------------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
[pscustomobject]@{
    Name            = $Name
    Created         = (Get-Date).ToString('o')
    Computer        = $env:COMPUTERNAME
    User            = $env:USERNAME
    IsAdmin         = $isAdmin
    OS              = $os.Caption
    OSVersion       = $os.Version
    RegistryRoots   = $RegistryRoots
    Full            = [bool]$Full
    Errors          = $errors
    DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
} | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $snapDir 'meta.json') -Encoding UTF8

$sizeMB = [math]::Round((Get-ChildItem $snapDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Host ""
Write-Host "Snapshot '$Name' complete." -ForegroundColor Green
Write-Host "  Folder:   $snapDir"
Write-Host "  Size:     $sizeMB MB"
Write-Host "  Duration: $([math]::Round($sw.Elapsed.TotalSeconds,1)) s"
if ($errors.Count -gt 0) {
    Write-Host "  Warnings: $($errors.Count) (see meta.json)" -ForegroundColor Yellow
}
