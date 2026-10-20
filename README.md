# WinHealth

Finds out why Windows **hangs on shutdown/restart** or is **slow to wake from sleep**, and offers targeted fixes.

It reads the event logs and power settings Windows already keeps, then writes a plain-English HTML report: what went wrong, when, which program/driver/service is involved, and what to do about it. Analysis changes nothing. Fixes run only when you pick them, after a System Restore point is created.

## Quick start

1. Download this repository (Code → Download ZIP) and extract it, e.g. to `C:\WinHealth`.
2. Double-click **`Run-WinHealth.cmd`** and accept the administrator prompt.
3. Wait about a minute. The report opens in your browser and the console offers the recommended fixes. Type numbers (e.g. `1,3`), `a` for all, or press Enter to skip.

Reports are saved in `reports\<date>\` (`report.html`, `report.json`, and on Modern Standby PCs `sleepstudy.html`).

From an administrator PowerShell:

```powershell
cd C:\WinHealth
.\WinHealth.ps1                                   # analyse, open report, offer fixes
.\WinHealth.ps1 -Days 90                          # look further back
.\WinHealth.ps1 -ListFixes                        # what can be fixed
.\WinHealth.ps1 -Fix DisableFastStartup           # apply one fix
.\WinHealth.ps1 -Fix Recommended -WhatIf          # show what would be changed
```

If PowerShell refuses to run the script, use `Run-WinHealth.cmd`, or run `powershell -ExecutionPolicy Bypass -File .\WinHealth.ps1`.

## What it checks

| Area | Looks at | Tells you |
|---|---|---|
| Shutdown & restart | User32 1074, Kernel-Power 41, EventLog 6005/6006/6008, Kernel-General 12/13 | Restarts that never finished and needed the power button, who requested them (e.g. Windows Update), how long shutdowns take |
| Shutdown culprits | Diagnostics-Performance 200-210, Service Control Manager 7011/7043, Winlogon 6005/6006, `WaitToKillServiceTimeout` | Which apps, services or drivers held shutdown up |
| Fast Startup | `HiberbootEnabled` | Whether "Shut down" is really a hibernate (a common cause of hangs) |
| Sleep & wake | `powercfg /a /requests /waketimers /lastwake /devicequery`, Power-Troubleshooter 1, Kernel-Power 41 `SleepInProgress`, Diagnostics-Performance 300-310, sleep study | Modern Standby vs S3, hangs during sleep, wake time (firmware vs drivers), what wakes the PC, what blocks sleep |
| Sleep history | Kernel-Power 42/107/506/507 against boots and power losses | Whether the PC actually sleeps, and which sleeps never woke up |
| Windows Update | Pending-reboot keys, WindowsUpdateClient 20 | Updates failing and retrying on every restart (Store app failures listed separately) |
| Crashes & drivers | Bugchecks 1001, minidumps, Device Manager errors, graphics/network/storage driver dates | Blue screens by name and likely cause; with WinDbg installed, the process/driver from each dump |
| Hardware errors | WHEA-Logger 1/17/18/19/47 | CPU, memory and PCIe errors (overclock/EXPO instability, failing hardware) |
| Firmware | BIOS date, uptime | Old BIOS (vendors often fix sleep bugs there) |
| Storage | Free space, dirty bit, disk health, disk/NTFS/NVMe errors per drive | Which drive is failing or dropping out, and how it is connected |
| NVMe driver | `nvmedisk` service, FeatureManagement overrides | Whether the experimental native NVMe driver has been switched on |

## Fixes

| Id | What it does |
|---|---|
| `DisableFastStartup` | Makes shutdown a real shutdown. Most common fix for shutdown/restart hangs. |
| `RebuildHibernation` | Recreates `hiberfil.sys` (`powercfg /h off` then `on`). |
| `DisableWakeTimers` | Stops scheduled tasks waking the PC. |
| `DisarmWakeDevices` | Asks per device (mouse, network card...) whether it may wake the PC; keyboards are kept. |
| `DisableStandbyNetwork` | Modern Standby only: no network while asleep. |
| `ReduceServiceKillTimeout` | Shutdown waits at most 5 s for a hung service. |
| `ResetWindowsUpdate` | Clears the Windows Update cache (old folders kept as backups). |
| `RepairSystemFiles` | `DISM /RestoreHealth` + `sfc /scannow` (10-30 min). |
| `ScheduleDiskCheck` | Scans every drive named in recent disk errors and repairs it after asking; the system drive is checked at next restart. |
| `DisableExperimentalNvmeDriver` | Removes the overrides that enable the experimental `nvmedisk` driver, so Windows goes back to `stornvme` after a restart. |
| `RestoreDefaultPowerPlans` | Resets power plans to Windows defaults. |

Each applied fix is written to `reports\<date>\fixes.json` with instructions to undo it. Fixes that would change nothing on your PC (e.g. Fast Startup is already off) are not offered.

To have blue-screen dumps analysed automatically, install WinDbg (`winget install Microsoft.WinDbg`); WinHealth then runs `!analyze -v` on the newest dumps and saves the output next to the report.

## Suggested order for "won't restart / slow to wake"

1. Run the analysis and read the **Critical** items first.
2. Apply `DisableFastStartup`, then do one full **Restart** (not Shut down) and give it up to 30 minutes if it is installing updates.
3. If update failures are listed: `ResetWindowsUpdate`, restart, then `RepairSystemFiles`.
4. If sleep/wake is the problem: update BIOS, chipset, graphics and Wi-Fi drivers from your PC maker's support site. On Modern Standby PCs, check `sleepstudy.html` and try `DisableStandbyNetwork`.
5. Run WinHealth again after a few days and compare.

## Development

Requires Windows PowerShell 5.1 or PowerShell 7. Code layout:

- `WinHealth.ps1` - entry point (elevation, menu, orchestration)
- `lib/Checks.ps1` - diagnostics (read-only)
- `lib/Parsers.ps1` - pure parsing/analysis, unit tested
- `lib/Fixes.ps1` - fix catalog and restore point
- `lib/Report.ps1` - console summary, HTML and JSON
- `tests/` - Pester tests (run on any OS: `Invoke-Pester ./tests`)

CI runs PSScriptAnalyzer, Pester, and a real analysis on a Windows runner.
