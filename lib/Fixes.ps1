# Repair actions. Nothing here runs unless the user picks it (interactive
# menu or -Fix). Each fix is reversible or low-risk; Undo text says how.

function Get-WHFixCatalog {
    [ordered]@{
        DisableFastStartup       = @{
            Title  = 'Turn off Fast Startup'
            Why    = 'Makes "Shut down" a real shutdown so drivers are fully reset. The single most common fix for hangs on shutdown/restart.'
            Undo   = 'Control Panel > Power Options > Choose what the power buttons do > tick "Turn on fast startup".'
            Reboot = $false
            Action = {
                Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord
            }
        }
        RebuildHibernation       = @{
            Title  = 'Rebuild the hibernation file'
            Why    = 'Deletes and recreates hiberfil.sys. A damaged hibernation file can make sleep, wake and Fast Startup hang.'
            Undo   = 'Nothing to undo (hibernation stays enabled).'
            Reboot = $false
            Action = {
                Invoke-WHFixNative 'powercfg.exe' '/hibernate', 'off'
                Invoke-WHFixNative 'powercfg.exe' '/hibernate', 'on'
            }
        }
        DisableWakeTimers        = @{
            Title  = 'Stop scheduled tasks from waking the PC'
            Why    = 'Sets "Allow wake timers" to Disable on battery and plugged in for the active power plan.'
            Undo   = 'powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 (and /setdcvalueindex), then powercfg /setactive SCHEME_CURRENT'
            Reboot = $false
            Action = {
                Invoke-WHFixNative 'powercfg.exe' '/setacvalueindex', 'SCHEME_CURRENT', 'SUB_SLEEP', 'RTCWAKE', '0'
                Invoke-WHFixNative 'powercfg.exe' '/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_SLEEP', 'RTCWAKE', '0'
                Invoke-WHFixNative 'powercfg.exe' '/setactive', 'SCHEME_CURRENT'
            }
        }
        DisarmWakeDevices        = @{
            Title  = 'Stop mice / network adapters from waking the PC'
            Why    = 'Asks about each device allowed to wake the PC. Keyboards are kept so you can still wake it.'
            Undo   = 'powercfg /deviceenablewake "<device name>"  or Device Manager > device > Power Management.'
            Reboot = $false
            Action = {
                param([bool]$Unattended)
                $armed = ConvertFrom-WHDeviceList (Invoke-WHNative 'powercfg.exe' '/devicequery', 'wake_armed')
                foreach ($dev in $armed) {
                    if ($dev -match 'keyboard') { Write-Host "    keeping $dev"; continue }
                    $go = $Unattended
                    if (-not $Unattended) { $go = (Read-Host "    Stop '$dev' waking the PC? [y/N]") -match '^y' }
                    if ($go) { Invoke-WHFixNative 'powercfg.exe' '/devicedisablewake', $dev }
                }
            }
        }
        DisableStandbyNetwork    = @{
            Title  = 'Disconnect network during Modern Standby'
            Why    = 'Stops Wi-Fi/Ethernet staying active while asleep (Modern Standby PCs). Reduces background wake activity, battery drain and slow wake. You will not get mail/notifications while asleep.'
            Undo   = 'powercfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONNECTIVITYINSTANDBY 1 (and /setdcvalueindex), then powercfg /setactive SCHEME_CURRENT'
            Reboot = $false
            Action = {
                # "Networking connectivity in Standby": 0 = Disable, 1 = Enable, 2 = Managed by Windows
                $sub = 'fea3413e-7e05-4911-9a71-700331f1c294'
                $setting = 'f15576e8-98b7-4186-b944-eafa664402d9'
                Invoke-WHFixNative 'powercfg.exe' '/setacvalueindex', 'SCHEME_CURRENT', $sub, $setting, '0'
                Invoke-WHFixNative 'powercfg.exe' '/setdcvalueindex', 'SCHEME_CURRENT', $sub, $setting, '0'
                Invoke-WHFixNative 'powercfg.exe' '/setactive', 'SCHEME_CURRENT'
            }
        }
        ReduceServiceKillTimeout = @{
            Title  = 'Limit how long shutdown waits for hung services'
            Why    = 'Sets WaitToKillServiceTimeout to the Windows default of 5 seconds, so one stuck service cannot hold up shutdown for minutes.'
            Undo   = 'Set HKLM\SYSTEM\CurrentControlSet\Control\WaitToKillServiceTimeout back to the previous value (logged below).'
            Reboot = $true
            Action = {
                $key = 'HKLM:\SYSTEM\CurrentControlSet\Control'
                $old = Get-WHRegistryValue $key 'WaitToKillServiceTimeout'
                Write-Host "    previous value: $old"
                Set-ItemProperty -Path $key -Name WaitToKillServiceTimeout -Value '5000' -Type String
            }
        }
        ResetWindowsUpdate       = @{
            Title  = 'Reset Windows Update components'
            Why    = 'Stops update services, renames the SoftwareDistribution and catroot2 caches (kept as backups) and restarts the services. Clears stuck or corrupt downloads that make restarts hang. Update history display is reset; installed updates are not removed.'
            Undo   = 'Stop wuauserv/bits/cryptsvc, delete the new folders and rename the *.winhealth-* backups back.'
            Reboot = $true
            Action = {
                $services = 'wuauserv', 'bits', 'cryptsvc', 'msiserver', 'usosvc'
                foreach ($s in $services) {
                    if (Get-Service $s -ErrorAction SilentlyContinue) { Stop-Service $s -Force -ErrorAction SilentlyContinue }
                }
                $stamp = Get-Date -Format 'yyyyMMddHHmmss'
                try {
                    foreach ($dir in (Join-Path $env:SystemRoot 'SoftwareDistribution'), (Join-Path $env:SystemRoot 'System32\catroot2')) {
                        if (Test-Path $dir) {
                            $leaf = Split-Path $dir -Leaf
                            Rename-Item -Path $dir -NewName "$leaf.winhealth-$stamp" -ErrorAction Stop
                            Write-Host "    renamed $dir -> $leaf.winhealth-$stamp"
                        }
                    }
                } finally {
                    foreach ($s in 'cryptsvc', 'bits', 'wuauserv') {
                        Start-Service $s -ErrorAction SilentlyContinue
                    }
                }
            }
        }
        RepairSystemFiles        = @{
            Title  = 'Repair Windows system files (DISM + SFC)'
            Why    = 'Runs DISM /RestoreHealth then sfc /scannow to repair corrupted system files. Takes 10-30 minutes and needs internet.'
            Undo   = 'Not needed; only restores original Windows files.'
            Reboot = $true
            Action = {
                Invoke-WHFixNative 'DISM.exe' '/Online', '/Cleanup-Image', '/RestoreHealth' -Stream
                Invoke-WHFixNative 'sfc.exe' '/scannow' -Stream -AllowExitCodes 0, 1
            }
        }
        ScheduleDiskCheck        = @{
            Title  = 'Check the system drive at next restart'
            Why    = 'Schedules chkdsk /f on the system drive. It runs before Windows starts and can take a while.'
            Undo   = 'chkntfs /x C:  (cancels the scheduled check)'
            Reboot = $true
            Action = {
                $out = cmd.exe /c "echo Y| chkdsk $env:SystemDrive /f" 2>&1
                $out | Select-Object -Last 3 | ForEach-Object { Write-Host "    $_" }
            }
        }
        RestoreDefaultPowerPlans = @{
            Title  = 'Reset power plans to Windows defaults'
            Why    = 'Restores all power plans and settings to defaults. Fixes plans corrupted by OEM tools or tweaks. Custom plans are deleted.'
            Undo   = 'Re-apply any custom settings by hand.'
            Reboot = $false
            Action = { Invoke-WHFixNative 'powercfg.exe' '-restoredefaultschemes' }
        }
    }
}

function Invoke-WHFixNative {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$Stream,
        [int[]]$AllowExitCodes = @(0)
    )
    $ErrorActionPreference = 'Continue'
    if ($Stream) {
        & $FilePath @ArgumentList
    } else {
        $out = & $FilePath @ArgumentList 2>&1
        $out | Where-Object { "$_".Trim() } | ForEach-Object { Write-Host "    $_" }
    }
    if ($AllowExitCodes -notcontains $LASTEXITCODE) {
        throw "$FilePath $($ArgumentList -join ' ') exited with code $LASTEXITCODE"
    }
}

function New-WHRestorePoint {
    Write-Host 'Creating a System Restore point...' -ForegroundColor Cyan
    $desc = "WinHealth $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    try {
        if (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue) {
            Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        } else {
            # PowerShell 7 has no Checkpoint-Computer; use Windows PowerShell.
            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "Checkpoint-Computer -Description '$desc' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop"
            if ($LASTEXITCODE -ne 0) { throw 'Checkpoint-Computer failed' }
        }
        Write-Host '  done.' -ForegroundColor Green
        $true
    } catch {
        Write-Warning "Could not create a restore point: $($_.Exception.Message)"
        Write-Warning 'System Restore may be turned off, or Windows only allows one restore point per 24 hours.'
        $false
    }
}

function Invoke-WHFix {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string[]]$FixId,
        [switch]$Unattended,
        [switch]$NoRestorePoint,
        [string]$LogPath
    )
    $catalog = Get-WHFixCatalog
    $unknown = @($FixId | Where-Object { -not $catalog.Contains($_) })
    if ($unknown) { throw "Unknown fix id(s): $($unknown -join ', '). Use -ListFixes to see valid ids." }

    if (-not $NoRestorePoint -and -not $WhatIfPreference) {
        $ok = New-WHRestorePoint
        if (-not $ok -and -not $Unattended) {
            if ((Read-Host 'Continue without a restore point? [y/N]') -notmatch '^y') { return }
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $FixId) {
        $fix = $catalog[$id]
        if (-not $PSCmdlet.ShouldProcess($fix.Title, 'Apply fix')) { continue }
        Write-Host ''
        Write-Host "==> $($fix.Title)" -ForegroundColor Cyan
        $status = 'Applied'; $message = ''
        try {
            & $fix.Action ([bool]$Unattended)
            Write-Host '    OK' -ForegroundColor Green
        } catch {
            $status = 'Failed'; $message = $_.Exception.Message
            Write-Host "    FAILED: $message" -ForegroundColor Red
        }
        $results.Add([pscustomobject]@{ Time = Get-Date; Fix = $id; Title = $fix.Title; Status = $status; Message = $message; Undo = $fix.Undo; NeedsReboot = $fix.Reboot })
    }

    if ($LogPath -and $results.Count) {
        $results | ConvertTo-Json -Depth 3 | Set-Content -Path $LogPath -Encoding UTF8
        Write-Host ''
        Write-Host "Fix log (including how to undo each change): $LogPath"
    }
    if (@($results | Where-Object { $_.NeedsReboot -and $_.Status -eq 'Applied' }).Count) {
        Write-Host ''
        Write-Host 'Restart the PC to finish applying the changes. If the restart is slow this one time, let it run.' -ForegroundColor Yellow
    }
    @($results)
}
