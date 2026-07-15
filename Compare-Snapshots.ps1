<#
.SYNOPSIS
    Compares two snapshots taken with Take-Snapshot.ps1 and reports every change.

.DESCRIPTION
    Diffs registry exports, services, power settings, scheduled tasks, TCP globals,
    network adapter properties, startup items and bcdedit output between two snapshots.

    Produces:
      - A markdown diff report (diff-report-*.md)
      - An undo .reg file (undo-*.reg) that restores the registry values recorded in
        the BEFORE snapshot. Review it before importing; import with:  reg import <file>

    Known-noisy registry areas (MRU lists, RNG seed, BAM, DHCP lease timers, ...) are
    filtered out by default. Use -NoNoiseFilter to see everything, and -IgnorePattern
    to add your own regex filters.

.EXAMPLE
    .\Compare-Snapshots.ps1 -Before before -After after

.EXAMPLE
    .\Compare-Snapshots.ps1 -Before before -After after -NoNoiseFilter -IgnorePattern '\\MyNoisyApp\\'
#>
[CmdletBinding()]
param(
    # Snapshot name (under .\snapshots) or full path to the BEFORE snapshot folder.
    [Parameter(Mandatory = $true)][string]$Before,

    # Snapshot name (under .\snapshots) or full path to the AFTER snapshot folder.
    [Parameter(Mandatory = $true)][string]$After,

    # Output path of the markdown report. Default: .\reports\diff-report-<before>-vs-<after>.md
    [string]$ReportPath,

    # Output path of the undo .reg file. Default: .\reports\undo-<before>-vs-<after>.reg
    [string]$UndoPath,

    # Output path of the machine-readable diff. Default: .\reports\diff-data-<before>-vs-<after>.json
    [string]$JsonPath,

    # Disable the built-in noise filter.
    [switch]$NoNoiseFilter,

    # Additional key-path regex patterns to ignore.
    [string[]]$IgnorePattern
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# --- Resolve snapshot folders -------------------------------------------------------
function Resolve-Snapshot([string]$NameOrPath) {
    if (Test-Path $NameOrPath) { return (Resolve-Path $NameOrPath).Path }
    $candidate = Join-Path (Join-Path $PSScriptRoot 'snapshots') $NameOrPath
    if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    throw "Snapshot not found: '$NameOrPath' (looked for a path and for snapshots\$NameOrPath)"
}

$beforeDir = Resolve-Snapshot $Before
$afterDir  = Resolve-Snapshot $After
$beforeName = Split-Path $beforeDir -Leaf
$afterName  = Split-Path $afterDir -Leaf

$reportDir = Join-Path $PSScriptRoot 'reports'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
if (-not $ReportPath) { $ReportPath = Join-Path $reportDir "diff-report-$beforeName-vs-$afterName.md" }
if (-not $UndoPath)   { $UndoPath   = Join-Path $reportDir "undo-$beforeName-vs-$afterName.reg" }
if (-not $JsonPath)   { $JsonPath   = Join-Path $reportDir "diff-data-$beforeName-vs-$afterName.json" }

# --- Noise filter -------------------------------------------------------------------
# Key-path patterns for registry areas that churn constantly and are never tweaks.
$keyNoisePatterns = @(
    '\\Explorer\\(RecentDocs|UserAssist|RunMRU|ComDlg32|SessionInfo|FeatureUsage|MountPoints2|StreamMRU|Streams|BagMRU|Bags)',
    '\\Cryptography\\RNG$',
    '\\Services\\bam\\State',
    '\\CloudStore\\Store',
    '\\CurrentVersion\\Prefetcher',
    '\\CurrentVersion\\NetworkList\\',
    '\\Notifications\\Data',
    '\\CurrentVersion\\CloudExperienceHost',
    '\\CurrentVersion\\Search\\(JumplistData|RecentApps)',
    '\\GameConfigStore\\Children\\',
    '\\SharedAccess\\Epoch2?$',
    '\\Services\\W32Time\\(SecureTimeLimits|Config)',
    '\\CurrentVersion\\Group Policy\\(History|State|DataStore)',
    '\\CurrentVersion\\IrisService',
    '\\ContentDeliveryManager\\(Creative|SuggestedApps)',
    '\\CurrentVersion\\UFH\\SHC',
    '\\CurrentVersion\\Authentication\\LogonUI',
    '\\Control\\DeviceContainers',
    '\\AppCompatFlags\\Compatibility Assistant\\Store',
    '\\AppModel\\SystemAppData\\',
    '\\Windows\\Shell\\(BagMRU|Bags)',
    '\\MuiCache',
    '\\SystemCertificates\\AuthRoot\\AutoUpdate',
    # "Open with" MRU tracking (the sibling UserChoice key is a real default-app
    # setting, so only OpenWithList is filtered)
    '\\FileExts\\[^\\]+\\OpenWithList',
    '\\ProfileService\\References\\',
    '\\CurrentVersion\\VFUProvider$',
    '\\TIP\\AggregateResults',
    # WMI provider-host tracking; churns whenever anything (including SnapDiff's own
    # snapshot queries) uses WMI/CIM
    '\\Wbem\\Tracing\\',
    # OneSettings remote-config sync timestamps
    '\\CurrentVersion\\Wosc\\',
    # Task Scheduler internal bookkeeping (last-run info, dynamic triggers). Task
    # enable/disable state is captured separately via Get-ScheduledTask, so nothing
    # of value is lost.
    '\\Schedule\\TaskCache\\',
    # Windows Error Reporting process-termination records (WER *settings* stay visible)
    '\\Windows Error Reporting\\TermReason'
)
# Value names that churn inside otherwise-interesting keys (checked alongside
# $valueNoisePatterns below):
#   ServiceSessionId - Windows licensing service rotates this every session
# Value-name patterns that churn inside otherwise interesting keys (e.g. DHCP lease timers
# inside Tcpip\Parameters\Interfaces, where TcpAckFrequency tweaks also live).
$valueNoisePatterns = @(
    '^(LeaseObtainedTime|LeaseTerminatesTime|T1|T2)$',
    '^ActiveTimeBias$',
    '^PendingFileRenameOperations',
    # ConsentStore usage timestamps churn, but the Allow/Deny 'Value' entries in the
    # same keys are real privacy tweaks - so only the timestamps are filtered.
    '^LastUsedTime(Start|Stop)$',
    # OneSettings-style sync attempt timestamps
    '^Last(Refresh|Action|Sync)(Attempted|Succeeded)$',
    # Software Protection Platform (licensing) session id, rotates per service session
    '^ServiceSessionId$'
)
if ($IgnorePattern) { $keyNoisePatterns += $IgnorePattern }
$keyNoiseRegex   = [regex]::new(($keyNoisePatterns -join '|'), 'IgnoreCase')
$valueNoiseRegex = [regex]::new(($valueNoisePatterns -join '|'), 'IgnoreCase')

$script:noiseSuppressed = 0
# Classifies a change as noise. Always evaluates the patterns; $NoNoiseFilter only
# controls whether noise is *shown*, never whether it can enter the undo file.
function Test-NoiseRaw([string]$Key, [string]$ValueName) {
    if ($keyNoiseRegex.IsMatch($Key)) { return $true }
    if ($ValueName -and $valueNoiseRegex.IsMatch($ValueName)) { return $true }
    return $false
}
# Display-time noise gate: honours -NoNoiseFilter and counts suppressions.
function Test-Noise([string]$Key, [string]$ValueName) {
    if ($NoNoiseFilter) { return $false }
    if (Test-NoiseRaw $Key $ValueName) { $script:noiseSuppressed++; return $true }
    return $false
}

# --- Protected keys (never safe to auto-roll-back) -----------------------------------
# Device, driver, and security state. Reverting these via a blunt registry re-import is
# what corrupts drivers: deleting a freshly-created device key or restoring stale driver
# state leaves the on-disk driver and the registry out of sync. These are shown in the
# report but EXCLUDED from the undo file, with a warning.
$protectedPatterns = @(
    '\\Control\\Class\\\{[0-9A-Fa-f\-]+\}',   # driver class keys (audio, GPU, network, ...)
    '\\Enum\\',                                # device instance/enumeration state (PCI, USB, HDAUDIO...)
    '\\MMDevices\\Audio',                      # audio endpoints
    '\\DriverDatabase\\',                      # driver store index
    '\\Services\\[^\\]+\\(Enum|Parameters\\Wdf)', # driver enum + WDF state under services
    '\\SECURITY(\\|$)',                        # security hive
    '\\SAM(\\|$)',                             # account database
    '\\Control\\DeviceGuard\\',                # VBS/HVCI state - reverting can strand policy
    '\\Policies\\Microsoft\\FVE'               # BitLocker
)
$protectedRegex = [regex]::new(($protectedPatterns -join '|'), 'IgnoreCase')
$script:protectedSkipped = 0
function Test-Protected([string]$Key) {
    if ($protectedRegex.IsMatch($Key)) { return $true }
    return $false
}

# --- Snapshot elevation metadata -----------------------------------------------------
# A key exported by an elevated snapshot but not by an unelevated one shows up as
# "added"/"removed" purely due to ACL visibility, not a real change. Rolling those back
# means deleting real system keys. Detect the mismatch so the undo can protect HKLM.
function Get-SnapshotIsAdmin([string]$Dir) {
    $metaPath = Join-Path $Dir 'meta.json'
    if (Test-Path $metaPath) {
        try {
            $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
            if ($null -ne $meta.IsAdmin) { return [bool]$meta.IsAdmin }
        } catch { }
    }
    return $null
}
$beforeAdmin = Get-SnapshotIsAdmin $beforeDir
$afterAdmin  = Get-SnapshotIsAdmin $afterDir
$elevationMismatch = ($null -ne $beforeAdmin -and $null -ne $afterAdmin -and $beforeAdmin -ne $afterAdmin)
if ($elevationMismatch) {
    Write-Warning "Elevation mismatch: before(admin=$beforeAdmin) vs after(admin=$afterAdmin). HKLM 'added/removed key' differences may be ACL artifacts; they will be EXCLUDED from the undo file."
}

# --- .reg export parser ---------------------------------------------------------------
# Returns Dictionary<keyPath, Dictionary<valueName, rawData>>. Value names are kept in
# their escaped .reg form so they can be re-emitted verbatim into the undo file.
# Multi-line hex continuations are joined into a single line (valid for reg import).
function Read-RegExport([string]$Path) {
    $result = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.Dictionary[string,string]]' ([System.StringComparer]::OrdinalIgnoreCase)
    $currentVals = $null
    $pendingName = $null
    $sb = $null
    $valueRegex = [regex]'^"((?:\\.|[^"\\])*)"=(.*)$'

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ($null -ne $pendingName) {
            $t = $line.Trim()
            if ($t.EndsWith('\')) { [void]$sb.Append($t.Substring(0, $t.Length - 1)) }
            else { [void]$sb.Append($t); $currentVals[$pendingName] = $sb.ToString(); $pendingName = $null }
            continue
        }
        if ($line.Length -eq 0) { continue }
        $c = $line[0]
        if ($c -eq '[') {
            $keyName = $line.Trim()
            if ($keyName.Length -lt 3) { continue }
            $keyName = $keyName.Substring(1, $keyName.Length - 2)
            $currentVals = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $result[$keyName] = $currentVals
            continue
        }
        if ($null -eq $currentVals) { continue }   # file header

        $name = $null; $data = $null
        if ($c -eq '"') {
            $m = $valueRegex.Match($line)
            if (-not $m.Success) { continue }
            $name = $m.Groups[1].Value
            $data = $m.Groups[2].Value
        }
        elseif ($c -eq '@') {
            if ($line.Length -lt 2 -or $line[1] -ne '=') { continue }
            $name = '@'
            $data = $line.Substring(2)
        }
        else { continue }

        $t = $data.TrimEnd()
        if ($t.EndsWith('\')) {
            $pendingName = $name
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append($t.Substring(0, $t.Length - 1))
        }
        else {
            $currentVals[$name] = $data
        }
    }
    return $result
}

# --- Registry diff --------------------------------------------------------------------
$keysAdded     = New-Object System.Collections.Generic.List[object]   # {Key, Values}
$keysRemoved   = New-Object System.Collections.Generic.List[object]   # {Key, Values}
$valuesAdded   = New-Object System.Collections.Generic.List[object]   # {Key, Name, New}
$valuesRemoved = New-Object System.Collections.Generic.List[object]   # {Key, Name, Old}
$valuesChanged = New-Object System.Collections.Generic.List[object]   # {Key, Name, Old, New}

$beforeRegDir = Join-Path $beforeDir 'registry'
$afterRegDir  = Join-Path $afterDir 'registry'
$beforeFiles = @{}
if (Test-Path $beforeRegDir) {
    Get-ChildItem $beforeRegDir -Filter *.reg | ForEach-Object { $beforeFiles[$_.Name] = $_.FullName }
}
$afterFiles = @{}
if (Test-Path $afterRegDir) {
    Get-ChildItem $afterRegDir -Filter *.reg | ForEach-Object { $afterFiles[$_.Name] = $_.FullName }
}

$allRegNames = @($beforeFiles.Keys) + @($afterFiles.Keys) | Sort-Object -Unique
foreach ($regName in $allRegNames) {
    if (-not $beforeFiles.ContainsKey($regName)) { Write-Warning "Only in AFTER snapshot, skipping: $regName"; continue }
    if (-not $afterFiles.ContainsKey($regName))  { Write-Warning "Only in BEFORE snapshot, skipping: $regName"; continue }

    Write-Host "[*] Diffing $regName" -ForegroundColor Cyan
    $b = Read-RegExport $beforeFiles[$regName]
    $a = Read-RegExport $afterFiles[$regName]

    foreach ($key in $a.Keys) {
        if (-not $b.ContainsKey($key)) {
            if (-not (Test-Noise $key $null)) {
                $keysAdded.Add([pscustomobject]@{ Key = $key; Values = $a[$key] })
            }
            continue
        }
        $bv = $b[$key]; $av = $a[$key]
        foreach ($n in $av.Keys) {
            if (-not $bv.ContainsKey($n)) {
                if (-not (Test-Noise $key $n)) { $valuesAdded.Add([pscustomobject]@{ Key = $key; Name = $n; New = $av[$n] }) }
            }
            elseif ($bv[$n] -cne $av[$n]) {
                if (-not (Test-Noise $key $n)) { $valuesChanged.Add([pscustomobject]@{ Key = $key; Name = $n; Old = $bv[$n]; New = $av[$n] }) }
            }
        }
        foreach ($n in $bv.Keys) {
            if (-not $av.ContainsKey($n)) {
                if (-not (Test-Noise $key $n)) { $valuesRemoved.Add([pscustomobject]@{ Key = $key; Name = $n; Old = $bv[$n] }) }
            }
        }
    }
    foreach ($key in $b.Keys) {
        if (-not $a.ContainsKey($key)) {
            if (-not (Test-Noise $key $null)) {
                $keysRemoved.Add([pscustomobject]@{ Key = $key; Values = $b[$key] })
            }
        }
    }
    $b = $null; $a = $null
}

# --- Non-registry diffs -----------------------------------------------------------------
function Read-JsonDict([string]$Path, [scriptblock]$KeySelector, [scriptblock]$ValueSelector) {
    $dict = @{}
    if (-not (Test-Path $Path)) { return $dict }
    $items = Get-Content $Path -Raw | ConvertFrom-Json
    foreach ($item in @($items)) {
        if ($null -eq $item) { continue }
        $dict[(& $KeySelector $item)] = (& $ValueSelector $item)
    }
    return $dict
}

function Diff-Dict([hashtable]$B, [hashtable]$A) {
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($k in ($A.Keys | Sort-Object)) {
        if (-not $B.ContainsKey($k))      { $changes.Add([pscustomobject]@{ Item = $k; Before = '(not present)'; After = $A[$k] }) }
        elseif ("$($B[$k])" -cne "$($A[$k])") { $changes.Add([pscustomobject]@{ Item = $k; Before = $B[$k]; After = $A[$k] }) }
    }
    foreach ($k in ($B.Keys | Sort-Object)) {
        if (-not $A.ContainsKey($k)) { $changes.Add([pscustomobject]@{ Item = $k; Before = $B[$k]; After = '(removed)' }) }
    }
    return $changes
}

# Services: start mode is configuration (what tweaks change) and is always reported.
# Running-state-only changes are runtime churn (services start/stop on their own) and
# are treated as noise unless -NoNoiseFilter is set.
function Read-ServiceMap([string]$Path) {
    $dict = @{}
    if (-not (Test-Path $Path)) { return $dict }
    foreach ($item in @((Get-Content $Path -Raw | ConvertFrom-Json))) {
        if ($null -eq $item -or -not $item.Name) { continue }
        $dict[$item.Name] = $item
    }
    return $dict
}
$svcB = Read-ServiceMap (Join-Path $beforeDir 'services.json')
$svcA = Read-ServiceMap (Join-Path $afterDir 'services.json')
$svcChanges = New-Object System.Collections.Generic.List[object]
foreach ($k in ($svcA.Keys | Sort-Object)) {
    if (-not $svcB.ContainsKey($k)) {
        $svcChanges.Add([pscustomobject]@{ Item = $k; Before = '(not present)'; After = "$($svcA[$k].StartMode) / $($svcA[$k].State)" })
        continue
    }
    $b0 = $svcB[$k]; $a0 = $svcA[$k]
    if ("$($b0.StartMode)" -cne "$($a0.StartMode)") {
        $svcChanges.Add([pscustomobject]@{ Item = $k; Before = "$($b0.StartMode) / $($b0.State)"; After = "$($a0.StartMode) / $($a0.State)" })
    }
    elseif ("$($b0.State)" -cne "$($a0.State)") {
        if ($NoNoiseFilter) {
            $svcChanges.Add([pscustomobject]@{ Item = $k; Before = "$($b0.StartMode) / $($b0.State)"; After = "$($a0.StartMode) / $($a0.State)" })
        } else { $script:noiseSuppressed++ }
    }
}
foreach ($k in ($svcB.Keys | Sort-Object)) {
    if (-not $svcA.ContainsKey($k)) {
        $svcChanges.Add([pscustomobject]@{ Item = $k; Before = "$($svcB[$k].StartMode) / $($svcB[$k].State)"; After = '(removed)' })
    }
}
# Plain array: this PowerShell 5.1 build throws "Argument types do not match" when a
# generic List is wrapped in @(...) further down.
$svcChanges = $svcChanges.ToArray()

# Scheduled tasks: only enable/disable transitions are interesting (Ready<->Running is churn)
$taskSel = { param($i) $i.Task }
$taskVal = { param($i) $i.State }
$taskChangesAll = Diff-Dict (Read-JsonDict (Join-Path $beforeDir 'tasks.json') $taskSel $taskVal) `
                            (Read-JsonDict (Join-Path $afterDir  'tasks.json') $taskSel $taskVal)
$taskChanges = @($taskChangesAll | Where-Object { "$($_.Before)" -eq 'Disabled' -or "$($_.After)" -eq 'Disabled' -or "$($_.Before)" -eq '(not present)' -or "$($_.After)" -eq '(removed)' })

# Network adapter advanced properties
$netSel = { param($i) "$($i.Adapter) :: $($i.Property)" }
$netVal = { param($i) $i.Value }
$netChanges = Diff-Dict (Read-JsonDict (Join-Path $beforeDir 'netadapters.json') $netSel $netVal) `
                        (Read-JsonDict (Join-Path $afterDir  'netadapters.json') $netSel $netVal)

# Startup items
$stSel = { param($i) "$($i.Location) :: $($i.Name)" }
$stVal = { param($i) $i.Command }
$startupChanges = Diff-Dict (Read-JsonDict (Join-Path $beforeDir 'startup.json') $stSel $stVal) `
                            (Read-JsonDict (Join-Path $afterDir  'startup.json') $stSel $stVal)

# Power: parse powercfg /query into (subgroup / setting / AC|DC) -> index
function Read-PowerQuery([string]$Path) {
    $dict = @{}
    if (-not (Test-Path $Path)) { return $dict }
    $subgroup = ''
    $setting = ''
    foreach ($line in Get-Content $Path) {
        if ($line -match 'Subgroup GUID:\s*([0-9a-fA-F-]+)\s*(?:\((.+)\))?') {
            $subgroup = if ($Matches[2]) { $Matches[2] } else { $Matches[1] }
        }
        elseif ($line -match 'Power Setting GUID:\s*([0-9a-fA-F-]+)\s*(?:\((.+)\))?') {
            $setting = if ($Matches[2]) { $Matches[2] } else { $Matches[1] }
        }
        elseif ($line -match 'Current (AC|DC) Power Setting Index:\s*(\S+)') {
            $dict["$subgroup / $setting ($($Matches[1]))"] = $Matches[2]
        }
    }
    return $dict
}
$powerChanges = Diff-Dict (Read-PowerQuery (Join-Path $beforeDir 'power-query.txt')) `
                          (Read-PowerQuery (Join-Path $afterDir  'power-query.txt'))

$beforeScheme = if (Test-Path (Join-Path $beforeDir 'power-activescheme.txt')) { (Get-Content (Join-Path $beforeDir 'power-activescheme.txt') -Raw).Trim() } else { '' }
$afterScheme  = if (Test-Path (Join-Path $afterDir  'power-activescheme.txt')) { (Get-Content (Join-Path $afterDir  'power-activescheme.txt') -Raw).Trim() } else { '' }
$schemeChanged = ($beforeScheme -cne $afterScheme)

# TCP globals: parse "name : value" lines
function Read-KVText([string]$Path) {
    $dict = @{}
    if (-not (Test-Path $Path)) { return $dict }
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*(.+?)\s+:\s+(.+?)\s*$') { $dict[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    return $dict
}
$tcpChanges = Diff-Dict (Read-KVText (Join-Path $beforeDir 'tcp-global.txt')) `
                        (Read-KVText (Join-Path $afterDir  'tcp-global.txt'))

# bcdedit: parse entries into (identifier :: option) -> value
function Read-Bcd([string]$Path) {
    $dict = @{}
    if (-not (Test-Path $Path)) { return $dict }
    $id = ''
    foreach ($line in Get-Content $Path) {
        if ($line -match '^identifier\s+(.+)$') { $id = $Matches[1].Trim(); continue }
        if ($line -match '^([a-zA-Z][\w]*)\s{2,}(.+)$') { $dict["$id :: $($Matches[1])"] = $Matches[2].Trim() }
    }
    return $dict
}
$bcdBefore = Read-Bcd (Join-Path $beforeDir 'bcdedit.txt')
$bcdAfter  = Read-Bcd (Join-Path $afterDir 'bcdedit.txt')
$bcdChanges = @()
if ($bcdBefore.Count -gt 0 -and $bcdAfter.Count -gt 0) { $bcdChanges = Diff-Dict $bcdBefore $bcdAfter }

# --- Undo .reg generation ----------------------------------------------------------------
# Restores the BEFORE state: changed/removed values get their old data back, added
# values are deleted ("name"=-), added keys are deleted ([-key]), removed keys are
# recreated with their old values.
#
# SAFETY RULES (hardened after a driver-corruption incident):
#   1. The undo is ALWAYS built from the noise-filtered set, even when the report was
#      generated with -NoNoiseFilter. Churn must never be re-imported over live state.
#   2. Protected device/driver/security keys are NEVER written to the undo file - a
#      blunt registry re-import cannot safely revert driver state.
#   3. On an elevation mismatch, HKLM key add/remove diffs are treated as ACL artifacts
#      and excluded (deleting them could remove real system keys).
$undoLinesByKey = New-Object 'System.Collections.Specialized.OrderedDictionary'
function Add-UndoLine([string]$Key, [string]$Line) {
    if (-not $undoLinesByKey.Contains($Key)) {
        $undoLinesByKey[$Key] = New-Object System.Collections.Generic.List[string]
    }
    $undoLinesByKey[$Key].Add($Line)
}
function Format-RegValueLine([string]$Name, [string]$Data) {
    if ($Name -eq '@') { return "@=$Data" } else { return "`"$Name`"=$Data" }
}

$script:undoNoiseSkipped     = 0
$script:undoProtectedSkipped = 0
$script:undoElevationSkipped = 0
$excludedKeys = New-Object System.Collections.Generic.List[object]  # {Key, Reason}

# Returns $true if this key/value must be kept OUT of the undo file, recording why.
function Test-UndoExcluded([string]$Key, [string]$ValueName) {
    if (Test-NoiseRaw $Key $ValueName) { $script:undoNoiseSkipped++; return $true }
    if (Test-Protected $Key) {
        $script:undoProtectedSkipped++
        $excludedKeys.Add([pscustomobject]@{ Key = $Key; Reason = 'protected (driver/device/security)' })
        return $true
    }
    return $false
}

foreach ($v in $valuesChanged) { if (-not (Test-UndoExcluded $v.Key $v.Name)) { Add-UndoLine $v.Key (Format-RegValueLine $v.Name $v.Old) } }
foreach ($v in $valuesRemoved) { if (-not (Test-UndoExcluded $v.Key $v.Name)) { Add-UndoLine $v.Key (Format-RegValueLine $v.Name $v.Old) } }
foreach ($v in $valuesAdded)   { if (-not (Test-UndoExcluded $v.Key $v.Name)) { Add-UndoLine $v.Key (Format-RegValueLine $v.Name '-') } }
foreach ($k in $keysRemoved) {
    if (Test-UndoExcluded $k.Key $null) { continue }
    if ($elevationMismatch -and $k.Key -match '^HKEY_LOCAL_MACHINE') { $script:undoElevationSkipped++; $excludedKeys.Add([pscustomobject]@{ Key = $k.Key; Reason = 'HKLM key, elevation mismatch' }); continue }
    foreach ($n in $k.Values.Keys) { Add-UndoLine $k.Key (Format-RegValueLine $n $k.Values[$n]) }
    if ($k.Values.Count -eq 0) { Add-UndoLine $k.Key '; (key had no values)' }
}

# Key-delete directives ([-key]) are the most destructive lines - guard them hardest.
$undoKeyDeletes = New-Object System.Collections.Generic.List[string]
foreach ($k in $keysAdded) {
    if (Test-Protected $k.Key) { $script:undoProtectedSkipped++; $excludedKeys.Add([pscustomobject]@{ Key = $k.Key; Reason = 'protected key deletion blocked' }); continue }
    if ($elevationMismatch -and $k.Key -match '^HKEY_LOCAL_MACHINE') { $script:undoElevationSkipped++; $excludedKeys.Add([pscustomobject]@{ Key = $k.Key; Reason = 'HKLM key deletion blocked (elevation mismatch)' }); continue }
    $undoKeyDeletes.Add($k.Key)
}

$undoContent = New-Object System.Text.StringBuilder
[void]$undoContent.AppendLine('Windows Registry Editor Version 5.00')
[void]$undoContent.AppendLine('')
[void]$undoContent.AppendLine("; Undo file generated by Compare-Snapshots.ps1")
[void]$undoContent.AppendLine("; Restores registry state of snapshot '$beforeName' (relative to '$afterName')")
[void]$undoContent.AppendLine("; Excluded from this file for safety: $($script:undoProtectedSkipped) protected, $($script:undoElevationSkipped) elevation-artifact, $($script:undoNoiseSkipped) noise entries.")
[void]$undoContent.AppendLine("; REVIEW BEFORE IMPORTING:  reg import `"$UndoPath`"")
[void]$undoContent.AppendLine('')
foreach ($k in $undoKeyDeletes) {
    [void]$undoContent.AppendLine("[-$k]")
    [void]$undoContent.AppendLine('')
}
foreach ($key in $undoLinesByKey.Keys) {
    [void]$undoContent.AppendLine("[$key]")
    foreach ($line in $undoLinesByKey[$key]) { [void]$undoContent.AppendLine($line) }
    [void]$undoContent.AppendLine('')
}

$regChangeCount = $keysAdded.Count + $keysRemoved.Count + $valuesAdded.Count + $valuesRemoved.Count + $valuesChanged.Count
$undoLineCount = $undoKeyDeletes.Count + $undoLinesByKey.Keys.Count
if ($undoLineCount -gt 0) {
    Set-Content -Path $UndoPath -Value $undoContent.ToString() -Encoding Unicode
}

# --- Machine-readable diff (consumed by the GUI results view) -------------------------------
$diffRows = New-Object System.Collections.Generic.List[object]
function Add-DiffRow([string]$Area, [string]$Item, [string]$B, [string]$A) {
    $diffRows.Add([pscustomobject]@{ Area = $Area; Item = $Item; Before = $B; After = $A })
}
# Registry rows get a "(protected)" area suffix when the change is device/driver/security
# state that was deliberately excluded from the undo file.
function Reg-Area([string]$base, [string]$key) {
    if (Test-Protected $key) { return "$base (protected)" } else { return $base }
}
foreach ($v in $valuesChanged) { Add-DiffRow (Reg-Area 'Registry (changed)' $v.Key) "$($v.Key) :: $($v.Name)" $v.Old $v.New }
foreach ($v in $valuesAdded)   { Add-DiffRow (Reg-Area 'Registry (added)' $v.Key)   "$($v.Key) :: $($v.Name)" '(not present)' $v.New }
foreach ($v in $valuesRemoved) { Add-DiffRow (Reg-Area 'Registry (removed)' $v.Key) "$($v.Key) :: $($v.Name)" $v.Old '(removed)' }
foreach ($k in $keysAdded) {
    $ka = Reg-Area 'Registry (key added)' $k.Key
    if ($k.Values.Count -eq 0) { Add-DiffRow $ka $k.Key '(not present)' '(empty key)' }
    foreach ($n in $k.Values.Keys) { Add-DiffRow $ka "$($k.Key) :: $n" '(not present)' $k.Values[$n] }
}
foreach ($k in $keysRemoved) {
    $kr = Reg-Area 'Registry (key removed)' $k.Key
    if ($k.Values.Count -eq 0) { Add-DiffRow $kr $k.Key '(empty key)' '(removed)' }
    foreach ($n in $k.Values.Keys) { Add-DiffRow $kr "$($k.Key) :: $n" $k.Values[$n] '(removed)' }
}
if ($schemeChanged) { Add-DiffRow 'Power scheme' 'Active scheme' $beforeScheme $afterScheme }
foreach ($c in $svcChanges)     { Add-DiffRow 'Service'          $c.Item "$($c.Before)" "$($c.After)" }
foreach ($c in $taskChanges)    { Add-DiffRow 'Scheduled task'   $c.Item "$($c.Before)" "$($c.After)" }
foreach ($c in $powerChanges)   { Add-DiffRow 'Power setting'    $c.Item "$($c.Before)" "$($c.After)" }
foreach ($c in $tcpChanges)     { Add-DiffRow 'TCP global'       $c.Item "$($c.Before)" "$($c.After)" }
foreach ($c in $netChanges)     { Add-DiffRow 'Network adapter'  $c.Item "$($c.Before)" "$($c.After)" }
foreach ($c in $startupChanges) { Add-DiffRow 'Startup item'     $c.Item "$($c.Before)" "$($c.After)" }
foreach ($c in $bcdChanges)     { Add-DiffRow 'Boot config'      $c.Item "$($c.Before)" "$($c.After)" }

[pscustomobject]@{
    Before             = $beforeName
    After              = $afterName
    Generated          = (Get-Date).ToString('o')
    NoiseSuppressed    = $script:noiseSuppressed
    UndoWritten        = (Test-Path $UndoPath)
    ProtectedExcluded  = $script:undoProtectedSkipped
    ElevationExcluded  = $script:undoElevationSkipped
    ElevationMismatch  = [bool]$elevationMismatch
    Rows               = $diffRows
} | ConvertTo-Json -Depth 4 | Set-Content -Path $JsonPath -Encoding UTF8

# --- Markdown report -----------------------------------------------------------------------
function Escape-Md([string]$s) {
    if ($null -eq $s) { return '' }
    $s = $s -replace '\|', '\|'
    if ($s.Length -gt 160) { $s = $s.Substring(0, 157) + '...' }
    return $s
}

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Snapshot diff: ``$beforeName`` vs ``$afterName``")
[void]$md.AppendLine('')
[void]$md.AppendLine("Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'). Noise filter: $(if ($NoNoiseFilter) { 'OFF' } else { "ON ($script:noiseSuppressed entries suppressed)" })")
[void]$md.AppendLine('')

[void]$md.AppendLine('## Summary')
[void]$md.AppendLine('')
[void]$md.AppendLine("| Area | Changes |")
[void]$md.AppendLine("| --- | --- |")
[void]$md.AppendLine("| Registry keys added / removed | $($keysAdded.Count) / $($keysRemoved.Count) |")
[void]$md.AppendLine("| Registry values added / removed / changed | $($valuesAdded.Count) / $($valuesRemoved.Count) / $($valuesChanged.Count) |")
[void]$md.AppendLine("| Services | $($svcChanges.Count) |")
[void]$md.AppendLine("| Scheduled tasks (enable/disable) | $($taskChanges.Count) |")
[void]$md.AppendLine("| Power settings | $($powerChanges.Count + [int]$schemeChanged) |")
[void]$md.AppendLine("| TCP global settings | $($tcpChanges.Count) |")
[void]$md.AppendLine("| Network adapter properties | $($netChanges.Count) |")
[void]$md.AppendLine("| Startup items | $($startupChanges.Count) |")
[void]$md.AppendLine("| Boot configuration (bcdedit) | $($bcdChanges.Count) |")
[void]$md.AppendLine('')

if ($valuesChanged.Count -gt 0) {
    [void]$md.AppendLine('## Registry: changed values')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Key | Value | Before | After |')
    [void]$md.AppendLine('| --- | --- | --- | --- |')
    foreach ($v in ($valuesChanged | Sort-Object Key, Name)) {
        [void]$md.AppendLine("| $(Escape-Md $v.Key) | $(Escape-Md $v.Name) | ``$(Escape-Md $v.Old)`` | ``$(Escape-Md $v.New)`` |")
    }
    [void]$md.AppendLine('')
}
if ($valuesAdded.Count -gt 0) {
    [void]$md.AppendLine('## Registry: added values')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Key | Value | Data |')
    [void]$md.AppendLine('| --- | --- | --- |')
    foreach ($v in ($valuesAdded | Sort-Object Key, Name)) {
        [void]$md.AppendLine("| $(Escape-Md $v.Key) | $(Escape-Md $v.Name) | ``$(Escape-Md $v.New)`` |")
    }
    [void]$md.AppendLine('')
}
if ($valuesRemoved.Count -gt 0) {
    [void]$md.AppendLine('## Registry: removed values')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Key | Value | Old data |')
    [void]$md.AppendLine('| --- | --- | --- |')
    foreach ($v in ($valuesRemoved | Sort-Object Key, Name)) {
        [void]$md.AppendLine("| $(Escape-Md $v.Key) | $(Escape-Md $v.Name) | ``$(Escape-Md $v.Old)`` |")
    }
    [void]$md.AppendLine('')
}
if ($keysAdded.Count -gt 0) {
    [void]$md.AppendLine('## Registry: added keys')
    [void]$md.AppendLine('')
    foreach ($k in ($keysAdded | Sort-Object Key)) {
        [void]$md.AppendLine("- ``$($k.Key)``")
        foreach ($n in $k.Values.Keys) {
            [void]$md.AppendLine("    - $(Escape-Md $n) = ``$(Escape-Md $k.Values[$n])``")
        }
    }
    [void]$md.AppendLine('')
}
if ($keysRemoved.Count -gt 0) {
    [void]$md.AppendLine('## Registry: removed keys')
    [void]$md.AppendLine('')
    foreach ($k in ($keysRemoved | Sort-Object Key)) {
        [void]$md.AppendLine("- ``$($k.Key)``")
        foreach ($n in $k.Values.Keys) {
            [void]$md.AppendLine("    - $(Escape-Md $n) was ``$(Escape-Md $k.Values[$n])``")
        }
    }
    [void]$md.AppendLine('')
}

function Append-DictSection([string]$Title, $Changes) {
    if (-not $Changes -or @($Changes).Count -eq 0) { return }
    [void]$md.AppendLine("## $Title")
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Item | Before | After |')
    [void]$md.AppendLine('| --- | --- | --- |')
    foreach ($c in $Changes) {
        [void]$md.AppendLine("| $(Escape-Md $c.Item) | $(Escape-Md "$($c.Before)") | $(Escape-Md "$($c.After)") |")
    }
    [void]$md.AppendLine('')
}

if ($schemeChanged) {
    [void]$md.AppendLine('## Active power scheme')
    [void]$md.AppendLine('')
    [void]$md.AppendLine("- Before: $beforeScheme")
    [void]$md.AppendLine("- After:  $afterScheme")
    [void]$md.AppendLine('')
}
Append-DictSection 'Services (start mode / state)' $svcChanges
Append-DictSection 'Scheduled tasks (enabled/disabled)' $taskChanges
Append-DictSection 'Power settings' $powerChanges
Append-DictSection 'TCP global settings' $tcpChanges
Append-DictSection 'Network adapter advanced properties' $netChanges
Append-DictSection 'Startup items' $startupChanges
Append-DictSection 'Boot configuration (bcdedit)' $bcdChanges

if ($excludedKeys.Count -gt 0) {
    [void]$md.AppendLine('## Excluded from rollback (undo file)')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('These changes appear above but were deliberately left OUT of the undo file because auto-reverting them can corrupt drivers or system state. Revert them manually if needed (e.g. reinstall the driver, or use System Restore).')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Key | Reason |')
    [void]$md.AppendLine('| --- | --- |')
    foreach ($e in ($excludedKeys | Sort-Object Key -Unique)) {
        [void]$md.AppendLine("| $(Escape-Md $e.Key) | $(Escape-Md $e.Reason) |")
    }
    [void]$md.AppendLine('')
}

Set-Content -Path $ReportPath -Value $md.ToString() -Encoding UTF8

# --- Console summary --------------------------------------------------------------------------
$totalOther = @($svcChanges).Count + @($taskChanges).Count + @($powerChanges).Count + @($tcpChanges).Count + @($netChanges).Count + @($startupChanges).Count + @($bcdChanges).Count + [int]$schemeChanged
Write-Host ""
Write-Host "Diff complete in $([math]::Round($sw.Elapsed.TotalSeconds,1)) s." -ForegroundColor Green
Write-Host "  Registry changes: $regChangeCount  (keys +$($keysAdded.Count)/-$($keysRemoved.Count), values +$($valuesAdded.Count)/-$($valuesRemoved.Count)/~$($valuesChanged.Count))"
Write-Host "  Other changes:    $totalOther  (services $(@($svcChanges).Count), tasks $(@($taskChanges).Count), power $(@($powerChanges).Count + [int]$schemeChanged), tcp $(@($tcpChanges).Count), net $(@($netChanges).Count), startup $(@($startupChanges).Count), bcd $(@($bcdChanges).Count))"
if (-not $NoNoiseFilter) {
    Write-Host "  Noise suppressed: $script:noiseSuppressed entries (re-run with -NoNoiseFilter to see them)"
}
if ($script:undoProtectedSkipped -gt 0 -or $script:undoElevationSkipped -gt 0) {
    Write-Host "  Excluded from undo (safety): $($script:undoProtectedSkipped) protected, $($script:undoElevationSkipped) elevation-artifact entries" -ForegroundColor Yellow
}
if ($elevationMismatch) {
    Write-Host "  WARNING: snapshots differ in elevation - HKLM key add/remove excluded from undo" -ForegroundColor Yellow
}
Write-Host "  Report: $ReportPath"
if (Test-Path $UndoPath) {
    Write-Host "  Undo:   $UndoPath  (review, then 'reg import' to roll back registry changes)"
} elseif ($regChangeCount -gt 0) {
    Write-Host "  Undo:   none written - all $regChangeCount registry change(s) were excluded for safety" -ForegroundColor Yellow
}
