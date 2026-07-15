<#
.SYNOPSIS
    GUI front-end for Take-Snapshot.ps1 / Compare-Snapshots.ps1.

.DESCRIPTION
    WPF app (no dependencies beyond Windows PowerShell 5.1). Take snapshots, browse
    them, compare two, open the diff report, and import the undo .reg to roll back.
    Snapshot/compare work runs in a child PowerShell process so the UI stays responsive;
    child output is streamed into the log pane.

    Launch: right-click this file > "Run with PowerShell", or from a prompt:
        powershell -ExecutionPolicy Bypass -File .\SnapDiff-GUI.ps1
#>
[CmdletBinding()]
param(
    # Internal: build the window and exit without showing it (used for automated testing).
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

if (-not ('SnapItem' -as [type])) {
    Add-Type -TypeDefinition @"
public class SnapItem {
    public string Name { get; set; }
    public string Created { get; set; }
    public string SizeMB { get; set; }
}
public class DiffRow {
    public string Area { get; set; }
    public string Item { get; set; }
    public string Before { get; set; }
    public string After { get; set; }
}
"@
}

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$snapshotsDir = Join-Path $scriptDir 'snapshots'
$reportsDir   = Join-Path $scriptDir 'reports'
$takeScript   = Join-Path $scriptDir 'Take-Snapshot.ps1'
$compareScript = Join-Path $scriptDir 'Compare-Snapshots.ps1'
New-Item -ItemType Directory -Path $snapshotsDir, $reportsDir -Force | Out-Null

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- XAML -----------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SnapDiff - System Snapshot and Compare"
        Height="760" Width="980" MinHeight="600" MinWidth="820"
        WindowStartupLocation="CenterScreen" Background="#F4F4F4">
  <Window.Resources>
    <Style TargetType="GroupBox">
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Padding" Value="8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="12,0,0,0"/>
      <Setter Property="FontWeight" Value="Normal"/>
    </Style>
    <Style TargetType="Label">
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="FontWeight" Value="Normal"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="MinWidth" Value="200"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="FontWeight" Value="Normal"/>
    </Style>
  </Window.Resources>
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="185"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border x:Name="AdminBanner" Grid.Row="0" Background="#FFF4CE" BorderBrush="#E0C560"
            BorderThickness="1" CornerRadius="3" Padding="10,6" Margin="0,0,0,10" Visibility="Collapsed">
      <DockPanel>
        <Button x:Name="RestartAdminBtn" DockPanel.Dock="Right" Content="Restart as Administrator"/>
        <TextBlock VerticalAlignment="Center"
                   Text="Not elevated: bcdedit is skipped and some protected registry keys may be missing from snapshots."/>
      </DockPanel>
    </Border>

    <GroupBox Grid.Row="1" Header="1. Take snapshot">
      <DockPanel>
        <Button x:Name="TakeBtn" DockPanel.Dock="Right" Content="Take snapshot" FontWeight="SemiBold"/>
        <TextBlock DockPanel.Dock="Right" Text="&#x24D8;" FontSize="15" Foreground="#2B6CB0"
                   VerticalAlignment="Center" Margin="12,0,12,0" Cursor="Help"
                   ToolTipService.ShowDuration="60000" ToolTipService.InitialShowDelay="200">
          <TextBlock.ToolTip>
            <ToolTip>
              <StackPanel Margin="6">
                <TextBlock FontWeight="SemiBold" Text="Each snapshot captures:" Margin="0,0,0,6"/>
                <TextBlock FontWeight="Normal" Text="&#8226; Registry: entire HKLM + HKCU hives (all system, driver and user settings)"/>
                <TextBlock FontWeight="Normal" Text="&#8226; Services: start mode and running state"/>
                <TextBlock FontWeight="Normal" Text="&#8226; Power: active plan and every power setting (AC/DC)"/>
                <TextBlock FontWeight="Normal" Text="&#8226; Scheduled tasks: enabled/disabled state"/>
                <TextBlock FontWeight="Normal" Text="&#8226; Network: TCP global settings and adapter advanced properties"/>
                <TextBlock FontWeight="Normal" Text="&#8226; Startup items: Run keys and Startup folders"/>
                <TextBlock FontWeight="Normal" Text="&#8226; Boot configuration: bcdedit output (requires administrator)"/>
              </StackPanel>
            </ToolTip>
          </TextBlock.ToolTip>
        </TextBlock>
        <Label Content="Name:"/>
        <TextBox x:Name="NameBox" VerticalContentAlignment="Center" Margin="4,0,0,0"/>
      </DockPanel>
    </GroupBox>

    <GroupBox Grid.Row="2" Header="2. Snapshots">
      <DockPanel>
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
          <Button x:Name="SetBeforeBtn" Content="Use as Before"/>
          <Button x:Name="SetAfterBtn" Content="Use as After"/>
          <Button x:Name="DeleteBtn" Content="Delete"/>
          <Button x:Name="OpenFolderBtn" Content="Open folder"/>
          <Button x:Name="RefreshBtn" Content="Refresh"/>
        </StackPanel>
        <ListView x:Name="SnapList" FontWeight="Normal">
          <ListView.View>
            <GridView>
              <GridViewColumn Header="Name" Width="320" DisplayMemberBinding="{Binding Name}"/>
              <GridViewColumn Header="Created" Width="220" DisplayMemberBinding="{Binding Created}"/>
              <GridViewColumn Header="Size (MB)" Width="100" DisplayMemberBinding="{Binding SizeMB}"/>
            </GridView>
          </ListView.View>
        </ListView>
      </DockPanel>
    </GroupBox>

    <GroupBox Grid.Row="3" Header="3. Compare">
      <StackPanel Orientation="Horizontal">
        <Label Content="Before:"/>
        <ComboBox x:Name="BeforeBox"/>
        <Label Content="After:" Margin="12,0,0,0"/>
        <ComboBox x:Name="AfterBox"/>
        <CheckBox x:Name="NoFilterCheck" Content="Show noise"/>
        <Button x:Name="CompareBtn" Content="Compare" FontWeight="SemiBold"/>
        <Button x:Name="OpenReportBtn" Content="Open report" IsEnabled="False"/>
        <Button x:Name="UndoBtn" Content="Roll back (import undo)" IsEnabled="False"/>
      </StackPanel>
    </GroupBox>

    <TabControl x:Name="ResultTabs" Grid.Row="4" Margin="0,0,0,4">
      <TabItem Header="Results">
        <DockPanel Margin="4">
          <DockPanel DockPanel.Dock="Top" Margin="0,2,0,6">
            <Label Content="Filter:" Padding="0,0,6,0"/>
            <TextBlock x:Name="ResultSummary" DockPanel.Dock="Right" VerticalAlignment="Center"
                       Margin="12,0,4,0" Foreground="#555" Text=""/>
            <TextBox x:Name="FilterBox" VerticalContentAlignment="Center"/>
          </DockPanel>
          <ListView x:Name="DiffList" FontWeight="Normal">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="Area" Width="150" DisplayMemberBinding="{Binding Area}"/>
                <GridViewColumn Header="Item" Width="430" DisplayMemberBinding="{Binding Item}"/>
                <GridViewColumn Header="Before" Width="160" DisplayMemberBinding="{Binding Before}"/>
                <GridViewColumn Header="After" Width="160" DisplayMemberBinding="{Binding After}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>
      </TabItem>
      <TabItem Header="Log">
        <TextBox x:Name="LogBox" IsReadOnly="True" FontFamily="Consolas" FontSize="12"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                 Background="#1E1E1E" Foreground="#DCDCDC" BorderThickness="0" TextWrapping="NoWrap"/>
      </TabItem>
    </TabControl>

    <TextBlock x:Name="StatusText" Grid.Row="5" Margin="2,6,0,0" Foreground="#555" Text="Ready."/>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
foreach ($name in @('AdminBanner','RestartAdminBtn','TakeBtn','NameBox','SnapList',
                    'SetBeforeBtn','SetAfterBtn','DeleteBtn','OpenFolderBtn','RefreshBtn',
                    'BeforeBox','AfterBox','NoFilterCheck','CompareBtn','OpenReportBtn','UndoBtn',
                    'LogBox','StatusText','ResultTabs','FilterBox','DiffList','ResultSummary')) {
    Set-Variable -Name $name -Value $window.FindName($name)
}

if (-not $isAdmin) { $AdminBanner.Visibility = 'Visible' }

# --- Helpers -----------------------------------------------------------------------------
function New-DefaultName { "snap-" + (Get-Date -Format "yyyyMMdd-HHmmss") }

function Get-Snapshots {
    $items = @()
    if (Test-Path $snapshotsDir) {
        foreach ($dir in (Get-ChildItem $snapshotsDir -Directory | Sort-Object Name)) {
            $created = $dir.CreationTime.ToString('yyyy-MM-dd HH:mm:ss')
            $metaPath = Join-Path $dir.FullName 'meta.json'
            if (Test-Path $metaPath) {
                try {
                    $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
                    if ($meta.Created) { $created = ([datetime]$meta.Created).ToString('yyyy-MM-dd HH:mm:ss') }
                } catch { }
            }
            $size = [math]::Round((Get-ChildItem $dir.FullName -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 1)
            $item = New-Object SnapItem
            $item.Name = $dir.Name
            $item.Created = $created
            $item.SizeMB = "$size"
            $items += $item
        }
    }
    return $items
}

function Refresh-Snapshots {
    # @() guards against PowerShell unrolling single-element arrays into a bare item,
    # which ItemsSource (expecting IEnumerable) would reject.
    $items = @(Get-Snapshots)
    $SnapList.ItemsSource = $items
    $beforeSel = $BeforeBox.SelectedItem
    $afterSel  = $AfterBox.SelectedItem
    $names = @($items | ForEach-Object { $_.Name })
    $BeforeBox.ItemsSource = $names
    $AfterBox.ItemsSource  = $names
    if ($beforeSel -and $names -contains $beforeSel) { $BeforeBox.SelectedItem = $beforeSel }
    if ($afterSel  -and $names -contains $afterSel)  { $AfterBox.SelectedItem  = $afterSel }
    $StatusText.Text = "$($names.Count) snapshot(s)."
}

function Append-Log([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return }
    $LogBox.AppendText($Text)
    if (-not $Text.EndsWith("`n")) { $LogBox.AppendText("`r`n") }
    $LogBox.ScrollToEnd()
}

function Set-Busy([bool]$Busy) {
    foreach ($b in @($TakeBtn, $CompareBtn, $DeleteBtn, $RefreshBtn, $SetBeforeBtn, $SetAfterBtn, $UndoBtn, $OpenReportBtn)) {
        $b.IsEnabled = -not $Busy
    }
    if ($Busy) { $OpenReportBtn.IsEnabled = $false; $UndoBtn.IsEnabled = $false }
}

# Child-process plumbing: run a PowerShell command asynchronously, stream its output
# (written to a temp log file) into the log pane via a DispatcherTimer.
$script:activeProc = $null
$script:activeLogFile = $null
$script:logOffset = 0
$script:onDone = $null

function Start-Work([string]$Command, [string]$StatusMsg, [scriptblock]$OnDone) {
    $script:activeLogFile = [System.IO.Path]::GetTempFileName()
    $script:logOffset = 0
    $script:onDone = $OnDone
    $full = "& { $Command } *>&1 | Out-File -FilePath '$($script:activeLogFile)' -Encoding utf8"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$($full -replace '"','\"')`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:activeProc = [System.Diagnostics.Process]::Start($psi)
    Set-Busy $true
    $StatusText.Text = $StatusMsg
    Append-Log ">>> $StatusMsg"
}

function Drain-Log {
    if (-not $script:activeLogFile -or -not (Test-Path $script:activeLogFile)) { return }
    try {
        $fs = [System.IO.File]::Open($script:activeLogFile, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -gt $script:logOffset) {
                $fs.Seek($script:logOffset, 'Begin') | Out-Null
                $sr = New-Object System.IO.StreamReader($fs)
                $newText = $sr.ReadToEnd()
                $script:logOffset = $fs.Length
                Append-Log $newText
            }
        } finally { $fs.Close() }
    } catch { }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$timer.Add_Tick({
    if ($script:activeProc -and $script:activeProc.HasExited) {
        Drain-Log
        Remove-Item $script:activeLogFile -Force -ErrorAction SilentlyContinue
        $script:activeProc = $null
        $script:activeLogFile = $null
        Set-Busy $false
        $StatusText.Text = 'Done.'
        Refresh-Snapshots
        # Clear onDone BEFORE invoking so a callback that chains another Start-Work
        # (e.g. rollback -> redo generation) can set a fresh onDone that survives.
        if ($script:onDone) { $cb = $script:onDone; $script:onDone = $null; & $cb }
    }
    elseif ($script:activeProc) {
        Drain-Log
    }
})
$timer.Start()

# --- Diff results view -----------------------------------------------------------------------
$script:allRows = @()

function Update-DiffView {
    $f = $FilterBox.Text.Trim()
    $rows = $script:allRows
    if ($f) {
        $rows = $rows | Where-Object {
            $_.Area -like "*$f*" -or $_.Item -like "*$f*" -or $_.Before -like "*$f*" -or $_.After -like "*$f*"
        }
    }
    $rows = @($rows)
    $DiffList.ItemsSource = $rows
    $shown = $rows.Count
    $total = @($script:allRows).Count
    $ResultSummary.Text = if ($f) { "$shown of $total changes" } else { "$total change(s)" }
}

function Load-DiffJson([string]$Path) {
    $script:allRows = @()
    if (Test-Path $Path) {
        try {
            $data = Get-Content $Path -Raw | ConvertFrom-Json
            $script:allRows = @(foreach ($r in @($data.Rows)) {
                if ($null -eq $r) { continue }
                $row = New-Object DiffRow
                $row.Area = "$($r.Area)"; $row.Item = "$($r.Item)"
                $row.Before = "$($r.Before)"; $row.After = "$($r.After)"
                $row
            })
        } catch {
            Append-Log "Could not read diff data: $($_.Exception.Message)"
        }
    }
    Update-DiffView
}

$FilterBox.Add_TextChanged({ Update-DiffView })

# --- Event handlers ------------------------------------------------------------------------
$script:lastReport = $null
$script:lastUndo = $null
$script:lastJson = $null

$RestartAdminBtn.Add_Click({
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$scriptDir\SnapDiff-GUI.ps1`"")
        $window.Close()
    } catch {
        # UAC prompt cancelled - keep the window open
    }
})

$TakeBtn.Add_Click({
    $name = $NameBox.Text.Trim() -replace '[^\w\-. ]', ''
    if (-not $name) { $name = New-DefaultName }
    if (Test-Path (Join-Path $snapshotsDir $name)) {
        [System.Windows.MessageBox]::Show("A snapshot named '$name' already exists.", 'SnapDiff', 'OK', 'Warning') | Out-Null
        return
    }
    $cmd = "& '$takeScript' -Name '$($name.Replace("'","''"))'"
    Start-Work $cmd "Taking snapshot '$name'..." {
        $NameBox.Text = New-DefaultName
    }
})

$RefreshBtn.Add_Click({ Refresh-Snapshots })
$OpenFolderBtn.Add_Click({ Start-Process explorer.exe $snapshotsDir })

$SetBeforeBtn.Add_Click({ if ($SnapList.SelectedItem) { $BeforeBox.SelectedItem = $SnapList.SelectedItem.Name } })
$SetAfterBtn.Add_Click({ if ($SnapList.SelectedItem) { $AfterBox.SelectedItem = $SnapList.SelectedItem.Name } })

$DeleteBtn.Add_Click({
    $sel = $SnapList.SelectedItem
    if (-not $sel) { return }
    $res = [System.Windows.MessageBox]::Show("Delete snapshot '$($sel.Name)'?", 'SnapDiff', 'YesNo', 'Question')
    if ($res -eq 'Yes') {
        Remove-Item (Join-Path $snapshotsDir $sel.Name) -Recurse -Force
        Refresh-Snapshots
        Append-Log "Deleted snapshot '$($sel.Name)'."
    }
})

$CompareBtn.Add_Click({
    $b = $BeforeBox.SelectedItem
    $a = $AfterBox.SelectedItem
    if (-not $b -or -not $a) {
        [System.Windows.MessageBox]::Show('Select both a Before and an After snapshot.', 'SnapDiff', 'OK', 'Warning') | Out-Null
        return
    }
    if ($b -eq $a) {
        [System.Windows.MessageBox]::Show('Before and After must be different snapshots.', 'SnapDiff', 'OK', 'Warning') | Out-Null
        return
    }
    $script:lastReport = Join-Path $reportsDir "diff-report-$b-vs-$a.md"
    $script:lastUndo   = Join-Path $reportsDir "undo-$b-vs-$a.reg"
    $script:lastJson   = Join-Path $reportsDir "diff-data-$b-vs-$a.json"
    Remove-Item $script:lastUndo, $script:lastJson -Force -ErrorAction SilentlyContinue
    $filterArg = if ($NoFilterCheck.IsChecked) { ' -NoNoiseFilter' } else { '' }
    $cmd = "& '$compareScript' -Before '$b' -After '$a'$filterArg"
    $ResultTabs.SelectedIndex = 1   # show the log while the compare runs
    Start-Work $cmd "Comparing '$b' vs '$a'..." {
        if (Test-Path $script:lastReport) { $OpenReportBtn.IsEnabled = $true }
        if (Test-Path $script:lastUndo) {
            $UndoBtn.IsEnabled = $true
            Append-Log "Undo file available: $($script:lastUndo)"
        } else {
            Append-Log 'No registry changes detected, so no undo file was generated.'
        }
        Load-DiffJson $script:lastJson
        $ResultTabs.SelectedIndex = 0   # switch to the results table
    }
})

$OpenReportBtn.Add_Click({
    if ($script:lastReport -and (Test-Path $script:lastReport)) {
        try { Invoke-Item $script:lastReport } catch { Start-Process notepad.exe "`"$($script:lastReport)`"" }
    }
})

$UndoBtn.Add_Click({
    if (-not ($script:lastUndo -and (Test-Path $script:lastUndo))) { return }

    # Does the undo touch HKLM? Those lines need administrator rights; importing them
    # unelevated silently half-applies (HKCU succeeds, HKLM fails).
    $undoText = Get-Content $script:lastUndo -Raw
    $touchesHKLM = $undoText -match '(?im)^\[-?HKEY_LOCAL_MACHINE'
    if ($touchesHKLM -and -not $isAdmin) {
        [System.Windows.MessageBox]::Show(
            "This rollback modifies HKEY_LOCAL_MACHINE, which requires administrator rights. Importing it now would only partially apply and could leave the registry inconsistent.`n`nUse 'Restart as Administrator' first, then re-run the compare and rollback.",
            'Rollback needs elevation', 'OK', 'Warning') | Out-Null
        return
    }

    $res = [System.Windows.MessageBox]::Show(
        "Roll back the registry to the '$($BeforeBox.SelectedItem)' state?`n`nBefore importing, SnapDiff will take a safety snapshot and write a REDO file so this rollback can itself be undone.`n`nUndo file:`n$($script:lastUndo)",
        'Confirm rollback', 'YesNo', 'Warning')
    if ($res -ne 'Yes') { return }

    # 1. Safety snapshot of the current (pre-rollback) state.
    $safetyName = "pre-rollback-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    Append-Log ">>> Taking safety snapshot '$safetyName' before rollback..."
    $cmd = "& '$takeScript' -Name '$safetyName'"
    Start-Work $cmd "Safety snapshot before rollback..." {
        # 2. After the safety snapshot completes, import the undo, capturing the real exit code.
        Append-Log ">>> Importing undo file..."
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'reg.exe'
        $psi.Arguments = "import `"$($script:lastUndo)`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        Append-Log (($stdout + $stderr).Trim())
        if ($proc.ExitCode -eq 0) {
            Append-Log "Rollback SUCCEEDED (reg import exit 0)."
            $StatusText.Text = "Rollback complete. Safety snapshot '$safetyName' saved."
            # 3. Generate a REDO file. The system is now at the 'Before' state; the redo
            #    must take it back to the pre-rollback (safety) state, i.e. an undo that
            #    "restores <safety> relative to <Before>". So: -Before <safety> -After <Before>.
            $target = $BeforeBox.SelectedItem
            Append-Log ">>> Generating redo file (compare '$safetyName' vs '$target')..."
            $rcmd = "& '$compareScript' -Before '$safetyName' -After '$target'"
            Start-Work $rcmd "Generating redo file..." {
                $redoUndo = Join-Path $reportsDir "undo-$safetyName-vs-$target.reg"
                if (Test-Path $redoUndo) { Append-Log "REDO file (re-applies what the rollback reverted): $redoUndo" }
            }
        } else {
            Append-Log "Rollback FAILED or partial (reg import exit $($proc.ExitCode)). Your safety snapshot '$safetyName' captured the state just before this attempt."
            $StatusText.Text = "Rollback failed - see log. Safety snapshot saved."
        }
    }
})

# --- Init -------------------------------------------------------------------------------------
$NameBox.Text = New-DefaultName
Refresh-Snapshots
$ResultTabs.SelectedIndex = 1   # start on the Log tab; Results fills after a compare
Append-Log "SnapDiff ready. Snapshots folder: $snapshotsDir"
if (-not $isAdmin) { Append-Log 'Running without elevation - snapshots will skip bcdedit and some protected keys.' }

if ($SelfTest) {
    $timer.Stop()
    Write-Output 'SELFTEST OK'
    exit 0
}

$window.ShowDialog() | Out-Null
$timer.Stop()
