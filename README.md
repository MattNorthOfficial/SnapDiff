# SnapDiff — system snapshot & before/after comparison

Two PowerShell scripts for capturing Windows configuration state and diffing it — built for
analyzing what tweaking tools and scripts actually change on a system.

## What gets captured

| Area | Source | Notes |
| --- | --- | --- |
| Registry | `reg.exe export` | Targeted high-signal roots by default; `-Full` for all of HKLM + HKCU |
| Services | WMI `Win32_Service` | Start mode + running state |
| Power settings | `powercfg /query` | Active scheme + every setting index (AC/DC) |
| Scheduled tasks | `Get-ScheduledTask` | Enable/disable state |
| TCP globals | `netsh int tcp show global` | RSS, autotuning, ECN, etc. |
| Network adapters | `Get-NetAdapterAdvancedProperty` | Interrupt moderation, offloads, etc. |
| Startup items | WMI `Win32_StartupCommand` | Run keys + startup folders |
| Boot config | `bcdedit /enum` | Admin only (timer/HPET tweaks live here) |

The default registry roots cover the areas gaming/latency tweaks touch: `CurrentControlSet\Control`
(scheduler, session manager, power), `CurrentControlSet\Services` (service config + Tcpip/NDIS
parameters), both `CurrentVersion` trees in HKLM, `HKLM\SOFTWARE\Policies`, `HKCU\Control Panel`,
per-user `CurrentVersion`, Game Bar, and `GameConfigStore`.

## GUI

Right-click `SnapDiff-GUI.ps1` → *Run with PowerShell* (or run it from a PowerShell
prompt). If it starts unelevated, use the in-app "Restart as Administrator" button for
full coverage. The GUI wraps the two scripts: take snapshots, browse/delete them, pick
Before/After, compare, view results in the built-in table, and import the undo `.reg` —
with live progress in the log pane. Everything the GUI does can also be done from the
command line below.

## Command-line usage

Run from an **elevated** PowerShell prompt for full coverage (works unelevated with reduced scope):

```powershell
cd "C:\Users\Matt\Documents\CPG Coding\Tweaker X\snapdiff"

# 1. Baseline
.\Take-Snapshot.ps1 -Name before

# 2. Apply ONE tweak (a toggle in a tweaker app, a script, a Settings change...)

# 3. Capture again and compare
.\Take-Snapshot.ps1 -Name after
.\Compare-Snapshots.ps1 -Before before -After after
```

Outputs land in `reports\`:

- `diff-report-<before>-vs-<after>.md` — human-readable report of every change
- `undo-<before>-vs-<after>.reg` — restores the *before* registry state.
  **Review it first**, then roll back with `reg import <file>`.

## Options

```powershell
# Snapshot the entire HKLM + HKCU (slow, ~100-300 MB, catches everything)
.\Take-Snapshot.ps1 -Name big -Full

# Snapshot only specific registry roots (fast, good for focused experiments)
.\Take-Snapshot.ps1 -Name t1 -RegistryRoots 'HKCU\SOFTWARE\SomeApp','HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl'

# See everything including known-noisy keys (MRU lists, RNG seed, DHCP lease timers...)
.\Compare-Snapshots.ps1 -Before before -After after -NoNoiseFilter

# Add your own noise filters (regex, matched against the key path)
.\Compare-Snapshots.ps1 -Before before -After after -IgnorePattern '\\SomeChattyApp\\'
```

## Tips for clean diffs

- **One tweak per diff.** The shorter the window between snapshots, the less noise.
- Take a **null diff** first (two snapshots with nothing in between) to see your machine's
  baseline churn; add recurring offenders via `-IgnorePattern`.
- Some changes only materialize after a **reboot** — snapshot a third time after rebooting
  if a tweak claims to need one.
- The undo `.reg` only covers the registry. Service start-mode changes, power settings, and
  bcdedit changes must be reverted through their own tools (the report gives you the
  before-values you need).
- Snapshots are plain folders under `snapshots\` — delete them freely.

## Limitations

- Registry data is compared in raw `.reg` export form; binary values show as hex strings.
- Deleting an *added* key via the undo file removes the whole key including any values
  another process wrote to it in the meantime.
- File-system changes are not captured (use Process Monitor for those).
