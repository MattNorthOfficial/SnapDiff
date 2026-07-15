# SnapDiff — system snapshot & before/after comparison

Two PowerShell scripts for capturing Windows configuration state and diffing it — built for
analyzing what tweaking tools and scripts actually change on a system.

## What gets captured

| Area | Source | Notes |
| --- | --- | --- |
| Registry | `reg.exe export` | Entire HKLM + HKCU (override with `-RegistryRoots` for focused experiments) |
| Services | WMI `Win32_Service` | Start mode + running state |
| Power settings | `powercfg /query` | Active scheme + every setting index (AC/DC) |
| Scheduled tasks | `Get-ScheduledTask` | Enable/disable state |
| TCP globals | `netsh int tcp show global` | RSS, autotuning, ECN, etc. |
| Network adapters | `Get-NetAdapterAdvancedProperty` | Interrupt moderation, offloads, etc. |
| Startup items | WMI `Win32_StartupCommand` | Run keys + startup folders |
| Boot config | `bcdedit /enum` | Admin only (timer/HPET tweaks live here) |

The registry capture covers the entire machine hive and current-user hive, so anything a
tweak could write — scheduler settings, service/driver parameters, GPU driver class keys,
Game Bar/Game DVR, vendor software, Classes/COM, WOW6432Node — is included. Expect a few
hundred MB per snapshot; delete old snapshots freely.

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
# Snapshot only specific registry roots (fast, good for focused experiments)
.\Take-Snapshot.ps1 -Name t1 -RegistryRoots 'HKCU\SOFTWARE\SomeApp','HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl'

# See everything including known-noisy keys (MRU lists, RNG seed, DHCP lease timers...)
.\Compare-Snapshots.ps1 -Before before -After after -NoNoiseFilter

# Add your own noise filters (regex, matched against the key path)
.\Compare-Snapshots.ps1 -Before before -After after -IgnorePattern '\\SomeChattyApp\\'
```

## Rollback safety

Rolling back is only safe for **setting-style** changes (a registry value that *is* the whole
change). It is the wrong tool for reverting installs, updates, or driver changes, where the
registry entries only index files that a re-import cannot restore. To protect against
driver/system corruption, the undo file is built with these guardrails:

- **Protected keys are never included.** Device/driver/security areas — driver class keys
  (`Control\Class\{…}`), device enumeration (`Enum\`), audio endpoints (`MMDevices\Audio`),
  the driver store, `SECURITY`/`SAM`, Device Guard, and BitLocker — are shown in the report
  but excluded from the undo file, and listed under "Excluded from rollback". Revert those
  manually (reinstall the driver, or use System Restore).
- **Noise is never rolled back**, even when the report was generated with `-NoNoiseFilter`.
- **Elevation-mismatch protection.** If the two snapshots were taken at different elevation
  levels, HKLM key add/remove differences are treated as ACL visibility artifacts and
  excluded (deleting them could remove real system keys). Take both snapshots at the same
  elevation for a clean comparison.
- **In the GUI**, a rollback first takes an automatic `pre-rollback-*` safety snapshot and
  then generates a **redo** file (so the rollback itself can be undone), refuses to run an
  HKLM rollback unless elevated, and reports the real `reg import` success/failure.

Always keep a **System Restore point** (or VM checkpoint) as the real safety net —
SnapDiff's undo covers the registry only.

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
- The undo file covers the registry only (minus protected/excluded keys). Service start-mode,
  power, and bcdedit changes are reported with their before-values but reverted manually.
- File-system changes are not captured (use Process Monitor for those).
