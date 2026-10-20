# Diagnostic checks. Each Test-WH* function returns zero or more findings
# (see New-WHFinding). They read system state but never change it.
#
# Event IDs used:
#   System log
#     User32 1074                    shutdown/restart requested (by whom, why)
#     EventLog 6005/6006/6008        log started / clean stop / unexpected stop
#     Kernel-General 12/13           OS start / OS shutdown
#     Kernel-Power 41                rebooted without clean shutdown (hang, power loss, crash)
#     Kernel-Power 42 / 107          entering sleep / resumed from sleep
#     Power-Troubleshooter 1         returned from low power state (wake source, init times)
#     Service Control Manager 7011/7043/7031/7034  service timeouts and crashes
#     WindowsUpdateClient 20         update installation failure
#     WER-SystemErrorReporting 1001  bugcheck (BSOD)
#     disk 7/51/153, Ntfs 55/98      storage errors
#   Application log
#     Winlogon 6005/6006             notification subscriber slow on logoff/shutdown
#   Microsoft-Windows-Diagnostics-Performance/Operational
#     100/200/300                    boot / shutdown / standby duration
#     101-110/201-210/301-310        components that slowed them down

function Get-WHSystemInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $build = Get-WHRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion'
    $ubr = Get-WHRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'UBR'
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        OS           = "$($os.Caption) $build (build $($os.BuildNumber).$ubr)"
        Model        = "$($cs.Manufacturer) $($cs.Model)".Trim()
        BIOS         = "$($bios.SMBIOSBIOSVersion) ($(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { 'unknown date' }))"
        BIOSDate     = $bios.ReleaseDate
        LastBoot     = $os.LastBootUpTime
        Uptime       = (Get-Date) - $os.LastBootUpTime
        MemoryGB     = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        GeneratedAt  = Get-Date
    }
}

function Test-WHShutdownHistory {
    param([datetime]$Since)
    $events = Get-WHEvent @{ LogName = 'System'; Id = 1074, 6005, 6006, 6008, 12, 13, 41; StartTime = $Since } -MaxEvents 2000
    $timeline = [System.Collections.Generic.List[object]]::new()
    $kp41 = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $events) {
        $kind = $null; $detail = ''
        switch ("$($e.ProviderName)|$($e.Id)") {
            'User32|1074' {
                $d = Get-WHEventDataMap $e
                $proc = Get-WHMapValue $d 'param1', 'Param0'
                $action = Get-WHMapValue $d 'param5', 'Param4'
                $reason = Get-WHMapValue $d 'param3', 'Param2'
                $kind = 'Requested'; $detail = "$action requested by $proc ($reason)"
            }
            'EventLog|6006' { $kind = 'Clean' }
            'Microsoft-Windows-Kernel-General|13' { $kind = 'Clean' }
            'EventLog|6008' { $kind = 'Dirty'; $detail = 'previous shutdown was unexpected' }
            'Microsoft-Windows-Kernel-Power|41' { $kind = 'Dirty'; $kp41.Add($e) }
            'EventLog|6005' { $kind = 'Boot' }
            'Microsoft-Windows-Kernel-General|12' { $kind = 'Boot' }
        }
        if ($kind) { $timeline.Add([pscustomobject]@{ Time = $e.TimeCreated; Kind = $kind; Detail = $detail }) }
    }

    # Kernel-Power 41: classify each unexpected reboot.
    if ($kp41.Count -gt 0) {
        $duringSleep = 0; $crash = 0; $powerButton = 0
        $evidence = foreach ($e in ($kp41 | Sort-Object TimeCreated -Descending)) {
            $d = Get-WHEventDataMap $e
            $bug = ConvertTo-WHInt (Get-WHMapValue $d 'BugcheckCode')
            $sleep = ConvertTo-WHInt (Get-WHMapValue $d 'SleepInProgress')
            $button = ConvertTo-WHInt (Get-WHMapValue $d 'PowerButtonTimestamp')
            $tags = @()
            if ($sleep -ne 0) { $duringSleep++; $tags += "hung while sleeping/resuming (sleep state $sleep)" }
            if ($bug -ne 0) { $crash++; $tags += ('blue screen 0x{0:X}' -f $bug) }
            if ($button -ne 0) { $powerButton++; $tags += 'power button held' }
            if (-not $tags) { $tags += 'no clean shutdown (hard reset or power loss)' }
            "$(Format-WHTime $e.TimeCreated): $($tags -join ', ')"
        }
        $sev = if ($kp41.Count -ge 3) { 'Critical' } else { 'Warning' }
        $detail = "Windows restarted $($kp41.Count) time(s) without shutting down cleanly. This is what you see when a restart or wake hangs and the machine has to be powered off by hand."
        if ($duringSleep) { $detail += " $duringSleep of them happened while the PC was going to sleep or waking up, which points at a driver or firmware problem with sleep." }
        if ($powerButton) { $detail += " The power button was held down $powerButton time(s)." }
        if ($crash) { $detail += " $crash were blue-screen crashes (see Stability)." }
        $fixes = @('DisableFastStartup')
        if ($duringSleep) { $fixes += 'RebuildHibernation' }
        New-WHFinding -Id 'unexpected-reboots' -Category Shutdown -Severity $sev -Title 'Unexpected reboots / hard power-offs' -Detail $detail -Evidence $evidence -FixIds $fixes
    }

    $hung = Find-WHIncompleteShutdown -Timeline $timeline
    if ($hung.Count -gt 0) {
        $evidence = $hung | Sort-Object RequestedAt -Descending | ForEach-Object {
            "$(Format-WHTime $_.RequestedAt): $($_.Detail) -> never finished; next event was $(if ($_.EndedBy -eq 'Dirty') { 'a forced power-off' } else { 'a fresh boot' }) at $(Format-WHTime $_.EndedAt)"
        }
        New-WHFinding -Id 'hung-shutdowns' -Category Shutdown -Severity Critical -Title "$($hung.Count) shutdown/restart(s) never completed" `
            -Detail 'A shutdown or restart was requested but Windows never recorded finishing it. The process that asked is listed; look for a pattern (e.g. always Windows Update / TrustedInstaller).' `
            -Evidence $evidence -FixIds 'DisableFastStartup', 'ReduceServiceKillTimeout'
    }

    $durations = Measure-WHShutdownDuration -Timeline $timeline
    $slow = @($durations | Where-Object { $_.Seconds -ge 60 })
    if ($slow.Count -gt 0) {
        $evidence = $slow | Sort-Object Seconds -Descending | Select-Object -First 15 | ForEach-Object {
            "$(Format-WHTime $_.RequestedAt): took $($_.Seconds)s - $($_.Detail)"
        }
        $sev = if (($slow | Measure-Object Seconds -Maximum).Maximum -ge 180) { 'Critical' } else { 'Warning' }
        New-WHFinding -Id 'slow-shutdowns' -Category Shutdown -Severity $sev -Title "Slow shutdowns ($($slow.Count) over 60 seconds)" `
            -Detail 'Time from the shutdown/restart request until Windows finished shutting down. See "Shutdown slowed by" and "Services timing out" for what is holding it up.' `
            -Evidence $evidence -FixIds 'ReduceServiceKillTimeout'
    } elseif ($durations.Count -gt 0) {
        $avg = [math]::Round(($durations | Measure-Object Seconds -Average).Average, 1)
        New-WHFinding -Id 'shutdown-speed' -Category Shutdown -Severity OK -Title "Completed shutdowns are fast (average ${avg}s)" -Detail "$($durations.Count) clean shutdowns measured."
    }

    if ($kp41.Count -eq 0 -and $hung.Count -eq 0) {
        New-WHFinding -Id 'no-unexpected-reboots' -Category Shutdown -Severity OK -Title 'No forced power-offs recorded' -Detail 'Every recorded shutdown in the period completed cleanly.'
    }
}

function Test-WHDiagnosticsPerformance {
    param([datetime]$Since)
    $log = 'Microsoft-Windows-Diagnostics-Performance/Operational'
    # Filter ids client-side: FilterHashtable only accepts ~23 ids. The log is small.
    $ids = @(100, 200, 300) + (101..110) + (201..210) + (301..310)
    $events = @(Get-WHEvent @{ LogName = $log; StartTime = $Since } -MaxEvents 5000 | Where-Object { $ids -contains $_.Id })
    if ($events.Count -eq 0) {
        New-WHFinding -Id 'diagperf-empty' -Category System -Severity Info -Title 'No boot/shutdown performance data' `
            -Detail "The $log log has no entries for this period (it may be disabled). Shutdown/standby culprit analysis is unavailable."
        return
    }

    $phases = @(
        @{ Id = 200; Range = 201..210; Name = 'Shutdown'; Category = 'Shutdown'; Warn = 30000; Crit = 90000 },
        @{ Id = 300; Range = 301..310; Name = 'Standby'; Category = 'Sleep'; Warn = 10000; Crit = 30000 },
        @{ Id = 100; Range = 101..110; Name = 'Boot'; Category = 'System'; Warn = 90000; Crit = 180000 }
    )
    foreach ($p in $phases) {
        $totals = @($events | Where-Object { $_.Id -eq $p.Id } | ForEach-Object {
                $ms = Get-WHDurationFromMessage $_.Message "$($p.Name) Duration"
                if ($null -eq $ms) {
                    $d = Get-WHEventDataMap $_
                    $ms = Get-WHMapValue $d "$($p.Name)Time", 'TotalTime'
                }
                if ($null -ne $ms) { [pscustomobject]@{ Time = $_.TimeCreated; Ms = [double]$ms } }
            })
        $culprits = @($events | Where-Object { $p.Range -contains $_.Id } | ForEach-Object {
                $d = Get-WHEventDataMap $_
                $name = Get-WHMapValue $d 'FriendlyName', 'Name', 'FileName'
                $file = Get-WHMapValue $d 'FileName', 'Name'
                if ($file -and $name -and $file -ne $name) { $name = "$name ($file)" }
                $delay = Get-WHMapValue $d 'DegradationTime', 'TotalTime'
                if ($null -eq $delay) { $delay = Get-WHDurationFromMessage $_.Message 'Degradation Time' }
                if ($null -eq $delay) { $delay = 0 }
                [pscustomobject]@{ Name = $name; DelayMs = [double]$delay }
            })

        if ($totals.Count -gt 0) {
            $avg = ($totals | Measure-Object Ms -Average).Average
            $max = ($totals | Measure-Object Ms -Maximum).Maximum
            $sev = if ($avg -ge $p.Crit) { 'Critical' } elseif ($avg -ge $p.Warn -or $max -ge $p.Crit) { 'Warning' } else { 'OK' }
            $evidence = $totals | Sort-Object Ms -Descending | Select-Object -First 10 | ForEach-Object { "$(Format-WHTime $_.Time): $(Format-WHDuration $_.Ms)" }
            New-WHFinding -Id "diagperf-$($p.Name.ToLower())-time" -Category $p.Category -Severity $sev `
                -Title "$($p.Name) takes $(Format-WHDuration $avg) on average (worst $(Format-WHDuration $max))" `
                -Detail "Measured by Windows over $($totals.Count) $($p.Name.ToLower())(s)." -Evidence $evidence
        }

        $ranked = @(Group-WHCulprit -Records $culprits)
        if ($ranked.Count -gt 0) {
            $evidence = $ranked | ForEach-Object { "$($_.Name): slowed $($_.Count) time(s), total $(Format-WHDuration $_.TotalMs), worst $(Format-WHDuration $_.MaxMs)" }
            $fixes = @()
            if ($p.Name -eq 'Shutdown') { $fixes += 'ReduceServiceKillTimeout' }
            New-WHFinding -Id "diagperf-$($p.Name.ToLower())-culprits" -Category $p.Category -Severity Warning `
                -Title "$($p.Name) slowed by: $(($ranked | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ', ')" `
                -Detail "Windows flagged these apps, services or drivers as delaying $($p.Name.ToLower()). Update or uninstall the top offenders, or check the vendor's site for a newer driver." `
                -Evidence $evidence -FixIds $fixes
        }
    }
}

function Test-WHServiceShutdown {
    param([datetime]$Since)
    $scm = Get-WHEvent @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7011, 7043, 7031, 7034; StartTime = $Since } -MaxEvents 1000
    if ($scm.Count -gt 0) {
        $records = foreach ($e in $scm) {
            $d = Get-WHEventDataMap $e
            $svc = if ($e.Id -eq 7011) { Get-WHMapValue $d 'param2', 'Param1' } else { Get-WHMapValue $d 'param1', 'Param0' }
            $what = switch ($e.Id) { 7011 { 'timed out responding' } 7043 { 'did not stop in time at shutdown' } default { 'crashed' } }
            [pscustomobject]@{ Service = $svc; What = $what; Time = $e.TimeCreated }
        }
        $groups = $records | Group-Object Service, What | Sort-Object Count -Descending
        $evidence = $groups | Select-Object -First 15 | ForEach-Object {
            $last = ($_.Group | Sort-Object Time -Descending | Select-Object -First 1).Time
            "$($_.Group[0].Service) $($_.Group[0].What) - $($_.Count)x (last $(Format-WHTime $last))"
        }
        $shutdownRelated = @($records | Where-Object { $_.What -ne 'crashed' }).Count
        $sev = if ($shutdownRelated -ge 5) { 'Warning' } else { 'Info' }
        New-WHFinding -Id 'service-timeouts' -Category Shutdown -Severity $sev -Title 'Services timing out or crashing' `
            -Detail 'Services that do not respond in time can stall shutdown/restart for minutes. Repeat offenders that belong to third-party software are good candidates to update or remove.' `
            -Evidence $evidence -FixIds 'ReduceServiceKillTimeout'
    }

    $winlogon = Get-WHEvent @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-Winlogon'; Id = 6005, 6006; StartTime = $Since } -MaxEvents 500
    if ($winlogon.Count -gt 0) {
        $records = foreach ($e in $winlogon) {
            $sub = if ($e.Message -match 'subscriber <(.+?)>') { $Matches[1] } else { Get-WHMapValue (Get-WHEventDataMap $e) 'Param0' }
            $evt = if ($e.Message -match 'event \((.+?)\)') { $Matches[1] } else { '' }
            [pscustomobject]@{ Name = "$sub during $evt"; Time = $e.TimeCreated }
        }
        $evidence = $records | Group-Object Name | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { "$($_.Name): $($_.Count)x" }
        New-WHFinding -Id 'winlogon-slow' -Category Shutdown -Severity Warning -Title 'Logon/logoff components responding slowly' `
            -Detail 'Winlogon reported notification subscribers taking a long time (e.g. during Logoff or Shutdown). "SessionEnv", "Profiles" or "GPClient" here often mean a network/profile problem; third-party names point at that software.' `
            -Evidence $evidence
    }

    $kill = Get-WHRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control' 'WaitToKillServiceTimeout'
    if ($kill -and [int]$kill -gt 20000) {
        New-WHFinding -Id 'kill-timeout' -Category Shutdown -Severity Warning -Title "Windows waits $([int]$kill / 1000)s for each hung service at shutdown" `
            -Detail 'WaitToKillServiceTimeout has been raised above the default (5 s on Windows 10/11), usually by installed software. A single stuck service can then hold shutdown up for that long.' `
            -Evidence "HKLM\SYSTEM\CurrentControlSet\Control\WaitToKillServiceTimeout = $kill" -FixIds 'ReduceServiceKillTimeout'
    }
}

function Test-WHFastStartup {
    $hiberboot = Get-WHRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
    $hibernate = Get-WHRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
    if ($hiberboot -eq 1 -and $hibernate -ne 0) {
        New-WHFinding -Id 'fast-startup' -Category Shutdown -Severity Warning -Title 'Fast Startup is on' `
            -Detail 'With Fast Startup, "Shut down" actually hibernates the kernel and drivers. Driver state is never fully reset, which is a very common cause of hangs on shutdown/restart, odd wake behaviour, and updates that need repeated restarts. Turning it off costs a few seconds of boot time.' `
            -Evidence 'HiberbootEnabled = 1' -FixIds 'DisableFastStartup'
    } else {
        New-WHFinding -Id 'fast-startup' -Category Shutdown -Severity OK -Title 'Fast Startup is off'
    }
}

function Test-WHSleep {
    param([datetime]$Since, [string]$OutputPath)

    $states = ConvertFrom-WHSleepStates (Invoke-WHNative 'powercfg.exe' '/a')
    $mode = if ($states.ModernStandby) { 'Modern Standby (S0 Low Power Idle)' } elseif ($states.S3) { 'classic S3 sleep' } else { 'unknown' }
    $stateFixes = @()
    $stateDetail = "Sleep uses $mode. Available: $($states.Available -join '; ')."
    if ($states.ModernStandby) {
        $stateDetail += ' Modern Standby keeps the PC partially awake (like a phone). Slow or failed wake on these machines is usually a driver/firmware problem (graphics, Wi-Fi, Intel/AMD chipset) or network activity in standby. Check the sleep study report and update BIOS + chipset + graphics drivers from the PC maker.'
        $stateFixes += 'DisableStandbyNetwork'
    }
    New-WHFinding -Id 'sleep-mode' -Category Sleep -Severity Info -Title "Sleep mode: $mode" -Detail $stateDetail -FixIds $stateFixes

    if ($states.ModernStandby -and $OutputPath) {
        $study = Join-Path $OutputPath 'sleepstudy.html'
        $null = Invoke-WHNative 'powercfg.exe' '/sleepstudy', '/output', $study, '/duration', '7'
        if (Test-Path $study) {
            New-WHFinding -Id 'sleep-study' -Category Sleep -Severity Info -Title 'Sleep study report saved' `
                -Detail 'Open sleepstudy.html next to this report to see each standby session, how much of it was spent in low power, and the top offending components.' -Evidence $study
        }
    }

    # Wake events: what woke the PC and how long resume took.
    $wakes = Get-WHEvent @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1; StartTime = $Since } -MaxEvents 500
    if ($wakes.Count -gt 0) {
        $records = foreach ($e in $wakes) {
            $d = Get-WHEventDataMap $e
            $src = if ($e.Message -match 'Wake Source:\s*(.+)') { $Matches[1].Trim() } else { Get-WHMapValue $d 'WakeSourceText' }
            $bios = Get-WHMapValue $d 'BiosInitDuration'
            $drv = Get-WHMapValue $d 'DriverInitDuration'
            [pscustomobject]@{ Time = $e.TimeCreated; Source = $src; BiosMs = $bios; DriverMs = $drv }
        }
        $evidence = @($records | Group-Object Source | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { "Woken by '$($_.Name)': $($_.Count)x" })
        New-WHFinding -Id 'wake-sources' -Category Sleep -Severity Info -Title "$($wakes.Count) wake-ups recorded" `
            -Detail 'What brought the PC out of sleep. "Unknown" or a timer/network device you did not touch means something is waking it on its own.' -Evidence $evidence

        $timed = @($records | Where-Object { $null -ne $_.DriverMs -and "$($_.DriverMs)" -ne '' } | ForEach-Object {
                $_ | Add-Member -NotePropertyName TotalMs -NotePropertyValue ([double]$_.DriverMs + [double]("0$($_.BiosMs)")) -PassThru
            })
        if ($timed.Count -gt 0) {
            $avg = ($timed | Measure-Object TotalMs -Average).Average
            $slowWakes = @($timed | Where-Object { $_.TotalMs -ge 5000 })
            $sev = if ($avg -ge 10000) { 'Critical' } elseif ($slowWakes.Count -gt 0) { 'Warning' } else { 'OK' }
            $evidence = $timed | Sort-Object TotalMs -Descending | Select-Object -First 10 | ForEach-Object {
                "$(Format-WHTime $_.Time): firmware $(Format-WHDuration ([double]("0$($_.BiosMs)"))), drivers $(Format-WHDuration ([double]$_.DriverMs)) (woken by $($_.Source))"
            }
            New-WHFinding -Id 'resume-time' -Category Sleep -Severity $sev -Title "Waking takes $(Format-WHDuration $avg) on average" `
                -Detail 'Firmware (BIOS/UEFI) plus driver initialisation time on resume. Long driver time = a driver is slow to come back (update graphics, storage, chipset, Wi-Fi drivers). Long firmware time = update the BIOS.' -Evidence $evidence
        }
    } else {
        New-WHFinding -Id 'wake-sources' -Category Sleep -Severity Info -Title 'No wake-from-sleep events recorded' -Detail 'Either the PC has not slept in this period, or it is not resuming successfully (see unexpected reboots).'
    }

    # Things currently stopping sleep.
    $requests = @(ConvertFrom-WHPowerRequests (Invoke-WHNative 'powercfg.exe' '/requests') | Where-Object { $_.Type -in 'SYSTEM', 'AWAYMODE', 'EXECUTION' })
    if ($requests.Count -gt 0) {
        New-WHFinding -Id 'power-requests' -Category Sleep -Severity Warning -Title "$($requests.Count) program(s)/driver(s) are currently blocking sleep" `
            -Detail 'These hold the PC awake right now. A stuck request (e.g. a media player, a driver like "Legacy Kernel Caller", or an audio stream) stops sleep entirely or makes it fall back to idle.' `
            -Evidence ($requests | ForEach-Object { "[$($_.Type)] $($_.Kind) $($_.Name)$(if ($_.Reason) { " - $($_.Reason)" })" })
    }

    # Things allowed to wake the PC.
    $timers = ConvertFrom-WHWakeTimers (Invoke-WHNative 'powercfg.exe' '/waketimers')
    $rtc = ConvertFrom-WHPowerSettingQuery (Invoke-WHNative 'powercfg.exe' '/q', 'SCHEME_CURRENT', 'SUB_SLEEP', 'RTCWAKE')
    if ($rtc.AC -ne 0 -or $rtc.DC -ne 0) {
        $ev = @("Allow wake timers: AC=$($rtc.AC) DC=$($rtc.DC) (0=off, 1=on, 2=important only)")
        $ev += $timers | ForEach-Object { "Timer: $($_.Owner) at $($_.Expires) - $($_.Reason)" }
        New-WHFinding -Id 'wake-timers' -Category Sleep -Severity $(if ($timers.Count) { 'Warning' } else { 'Info' }) -Title "Wake timers are allowed ($($timers.Count) active)" `
            -Detail 'Scheduled tasks (often Windows Update / maintenance) may wake the PC from sleep. Waking in a bag or overnight, then sleeping again, can leave it in a state where it is slow to respond.' `
            -Evidence $ev -FixIds 'DisableWakeTimers'
    }

    $armed = ConvertFrom-WHDeviceList (Invoke-WHNative 'powercfg.exe' '/devicequery', 'wake_armed')
    if ($armed.Count -gt 0) {
        New-WHFinding -Id 'wake-devices' -Category Sleep -Severity Info -Title "$($armed.Count) device(s) can wake the PC" `
            -Detail 'Mice and network adapters commonly cause random wake-ups. Keep the keyboard armed so you can still wake it.' `
            -Evidence $armed -FixIds 'DisarmWakeDevices'
    }

    $last = Invoke-WHNative 'powercfg.exe' '/lastwake'
    $lastText = ($last | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() }) -join ' | '
    if ($lastText) {
        New-WHFinding -Id 'last-wake' -Category Sleep -Severity Info -Title 'Last wake source' -Evidence $lastText
    }

    $hybrid = ConvertFrom-WHPowerSettingQuery (Invoke-WHNative 'powercfg.exe' '/q', 'SCHEME_CURRENT', 'SUB_SLEEP', 'HYBRIDSLEEP')
    if ($hybrid.AC -eq 1 -or $hybrid.DC -eq 1) {
        New-WHFinding -Id 'hybrid-sleep' -Category Sleep -Severity Info -Title 'Hybrid sleep is on' `
            -Detail 'Hybrid sleep writes memory to disk before sleeping. If the hibernation file is damaged this can slow sleep and wake; rebuilding it is cheap.' -FixIds 'RebuildHibernation'
    }
}

function Test-WHUpdates {
    param([datetime]$Since)
    $pending = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending += 'Component Based Servicing: RebootPending' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending += 'Windows Update: RebootRequired' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending') { $pending += 'Component Based Servicing: PackagesPending' }
    $renames = Get-WHRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations'
    if ($renames) { $pending += "PendingFileRenameOperations: $(@($renames | Where-Object { $_ }).Count) entries" }

    $failures = Get-WHEvent @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 20; StartTime = $Since } -MaxEvents 500
    $failGroups = @()
    if ($failures.Count -gt 0) {
        $failGroups = @($failures | ForEach-Object {
                $d = Get-WHEventDataMap $_
                [pscustomobject]@{ Title = Get-WHMapValue $d 'updateTitle', 'Param1'; Code = Get-WHMapValue $d 'errorCode', 'Param0'; Time = $_.TimeCreated }
            } | Group-Object Title | Sort-Object Count -Descending)
    }

    if ($failGroups.Count -gt 0) {
        $repeated = @($failGroups | Where-Object { $_.Count -ge 2 })
        $evidence = $failGroups | Select-Object -First 10 | ForEach-Object {
            "$($_.Name): failed $($_.Count)x, error $(($_.Group | Select-Object -ExpandProperty Code -Unique) -join ', ')"
        }
        $sev = if ($repeated.Count) { 'Critical' } else { 'Warning' }
        New-WHFinding -Id 'update-failures' -Category Updates -Severity $sev -Title "Windows Update failures ($($failures.Count))" `
            -Detail 'Updates that fail and retry are a classic cause of "Restarting..." screens that hang or "Undoing changes" loops. Resetting the Windows Update cache and repairing system files usually clears it.' `
            -Evidence $evidence -FixIds 'ResetWindowsUpdate', 'RepairSystemFiles'
    }

    if ($pending.Count -gt 0) {
        New-WHFinding -Id 'pending-reboot' -Category Updates -Severity Warning -Title 'A restart is pending to finish installing updates' `
            -Detail 'Windows has work queued for the next restart. If restarts keep hanging, that queued work may be what is stuck. Let one restart run for 20-30 minutes; if it still hangs, run the Windows Update reset.' `
            -Evidence $pending -FixIds 'ResetWindowsUpdate'
    } elseif ($failGroups.Count -eq 0) {
        New-WHFinding -Id 'updates-ok' -Category Updates -Severity OK -Title 'No pending restart or failed updates'
    }
}

function Test-WHStability {
    param([datetime]$Since)
    $bugchecks = Get-WHEvent @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $Since } -MaxEvents 100
    $dumpDir = Join-Path $env:SystemRoot 'Minidump'
    $dumps = @()
    if (Test-Path $dumpDir) { $dumps = @(Get-ChildItem $dumpDir -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $Since }) }
    if ($bugchecks.Count -gt 0 -or $dumps.Count -gt 0) {
        $evidence = @($bugchecks | ForEach-Object {
                $code = if ($_.Message -match '(0x[0-9a-fA-F]+)\s*\(') { $Matches[1] } else { 'unknown' }
                "$(Format-WHTime $_.TimeCreated): bugcheck $code"
            })
        $evidence += $dumps | ForEach-Object { "Dump file: $($_.FullName)" }
        New-WHFinding -Id 'bugchecks' -Category Stability -Severity Critical -Title "Blue-screen crashes ($([math]::Max($bugchecks.Count, $dumps.Count)))" `
            -Detail 'Crashes during sleep/resume or shutdown (e.g. 0x9F DRIVER_POWER_STATE_FAILURE, 0x133 DPC_WATCHDOG_VIOLATION) are almost always driver bugs. Searching the bugcheck code plus your PC model usually finds the driver; the dump files can be opened with WinDbg (!analyze -v) or BlueScreenView.' `
            -Evidence $evidence -FixIds 'RepairSystemFiles'
    } else {
        New-WHFinding -Id 'bugchecks' -Category Stability -Severity OK -Title 'No blue-screen crashes recorded'
    }

    $problem = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue)
    if ($problem.Count -gt 0) {
        New-WHFinding -Id 'problem-devices' -Category Stability -Severity Warning -Title "$($problem.Count) device(s) with driver problems" `
            -Detail 'Devices Device Manager shows with a warning. A device that fails to stop/start can block shutdown or resume. Reinstall or update their drivers (code 28 = no driver, 10 = cannot start, 43 = device reported a problem).' `
            -Evidence ($problem | ForEach-Object { "$($_.Name) - error code $($_.ConfigManagerErrorCode)" })
    }

    $cutoff = (Get-Date).AddYears(-2)
    $drivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object {
            $_.DeviceClass -in 'DISPLAY', 'NET', 'HDC', 'SCSIADAPTER' -and $_.DriverDate -and $_.DeviceName -and $_.DriverProviderName -ne 'Microsoft'
        })
    if ($drivers.Count -gt 0) {
        $old = @($drivers | Where-Object { $_.DriverDate -lt $cutoff })
        $evidence = $drivers | Sort-Object DriverDate | ForEach-Object {
            "$($_.DeviceClass): $($_.DeviceName) - $($_.DriverProviderName) $($_.DriverVersion) ($($_.DriverDate.ToString('yyyy-MM-dd')))"
        }
        $sev = if ($old.Count) { 'Warning' } else { 'Info' }
        $title = if ($old.Count) { "$($old.Count) key driver(s) are over 2 years old" } else { 'Key drivers' }
        New-WHFinding -Id 'driver-age' -Category Stability -Severity $sev -Title $title `
            -Detail 'Graphics, network and storage drivers are the usual suspects for sleep/shutdown hangs. Get current versions from your PC maker (or Intel/AMD/NVIDIA) rather than relying on Windows Update.' -Evidence $evidence
    }
}

function Test-WHBios {
    param($SystemInfo)
    if ($SystemInfo.BIOSDate -and $SystemInfo.BIOSDate -lt (Get-Date).AddYears(-2)) {
        New-WHFinding -Id 'bios-age' -Category System -Severity Warning -Title "BIOS/UEFI firmware is from $($SystemInfo.BIOSDate.ToString('yyyy-MM'))" `
            -Detail "Sleep, resume and power-off are handled jointly by firmware and Windows. PC makers ship BIOS updates specifically to fix sleep/wake bugs. Check $($SystemInfo.Model) support downloads." -Evidence $SystemInfo.BIOS
    }
    if ($SystemInfo.Uptime.TotalDays -ge 7) {
        New-WHFinding -Id 'uptime' -Category System -Severity Info -Title "No full restart for $([int]$SystemInfo.Uptime.TotalDays) days" `
            -Detail 'With Fast Startup on, "Shut down" does not reset uptime; only Restart does. Long uptime lets driver/memory problems build up, which can make sleep and wake slower.'
    }
}

function Test-WHStorage {
    param([datetime]$Since)
    $sysDrive = $env:SystemDrive
    $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDrive'"
    if ($vol -and $vol.Size) {
        $freeGB = [math]::Round($vol.FreeSpace / 1GB, 1)
        $pct = [math]::Round(100 * $vol.FreeSpace / $vol.Size, 0)
        if ($freeGB -lt 15 -or $pct -lt 10) {
            New-WHFinding -Id 'disk-space' -Category Storage -Severity Warning -Title "Low disk space on $sysDrive ($freeGB GB, $pct% free)" `
                -Detail 'Updates, the hibernation file and the page file all need room. Low space can make updates fail and restarts hang. Run Disk Cleanup (cleanmgr) including "Clean up system files".'
        }
    }

    $dirty = Invoke-WHNative 'fsutil.exe' 'dirty', 'query', $sysDrive
    if (($dirty -join ' ') -match 'is Dirty' -and ($dirty -join ' ') -notmatch 'is NOT Dirty') {
        New-WHFinding -Id 'disk-dirty' -Category Storage -Severity Warning -Title "$sysDrive is flagged for a disk check" `
            -Detail 'The file system was not shut down cleanly. A disk check at next boot will repair it.' -Evidence ($dirty -join ' ') -FixIds 'ScheduleDiskCheck'
    }

    if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        $bad = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.HealthStatus -ne 'Healthy' })
        if ($bad.Count -gt 0) {
            New-WHFinding -Id 'disk-health' -Category Storage -Severity Critical -Title 'A physical disk reports a health problem' `
                -Detail 'Back up your data now. A failing disk causes slow wake, hangs and corrupted updates.' `
                -Evidence ($bad | ForEach-Object { "$($_.FriendlyName): $($_.HealthStatus) / $($_.OperationalStatus)" })
        }
    }

    # Filter providers client-side: naming a provider that is not installed
    # makes Get-WinEvent return nothing at all.
    $errors = @(Get-WHEvent @{ LogName = 'System'; Id = 7, 11, 51, 129, 153, 55, 98, 140; Level = 1, 2, 3; StartTime = $Since } -MaxEvents 500)
    $relevant = @($errors | Where-Object { $_.ProviderName -in 'disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'storahci', 'stornvme', 'iaStorA', 'iaStorAC', 'iaStorAVC', 'nvme' })
    if ($relevant.Count -gt 0) {
        $evidence = $relevant | Group-Object ProviderName, Id | Sort-Object Count -Descending | ForEach-Object {
            $first = $_.Group[0]
            $msg = ("$($first.Message)" -split "`n")[0]
            "$($first.ProviderName) $($first.Id): $($_.Count)x - $msg"
        }
        New-WHFinding -Id 'disk-errors' -Category Storage -Severity Warning -Title "Storage errors in the event log ($($relevant.Count))" `
            -Detail 'Disk timeouts (129, 153) and resets during resume make wake slow or hang. Update the storage/NVMe driver and SSD firmware; if bad blocks (7) appear, back up and check the drive.' `
            -Evidence $evidence -FixIds 'ScheduleDiskCheck'
    }
}

function Invoke-WHAllChecks {
    param([int]$Days = 30, [string]$OutputPath)
    $since = (Get-Date).AddDays(-$Days)
    $info = Get-WHSystemInfo
    $checks = @(
        @{ Name = 'Shutdown & restart history'; Run = { Test-WHShutdownHistory -Since $since } },
        @{ Name = 'Windows performance diagnostics'; Run = { Test-WHDiagnosticsPerformance -Since $since } },
        @{ Name = 'Services at shutdown'; Run = { Test-WHServiceShutdown -Since $since } },
        @{ Name = 'Fast Startup'; Run = { Test-WHFastStartup } },
        @{ Name = 'Sleep & wake'; Run = { Test-WHSleep -Since $since -OutputPath $OutputPath } },
        @{ Name = 'Windows Update'; Run = { Test-WHUpdates -Since $since } },
        @{ Name = 'Crashes & drivers'; Run = { Test-WHStability -Since $since } },
        @{ Name = 'Firmware & uptime'; Run = { Test-WHBios -SystemInfo $info } },
        @{ Name = 'Storage'; Run = { Test-WHStorage -Since $since } }
    )
    $findings = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($c in $checks) {
        $i++
        Write-Progress -Activity 'WinHealth analysis' -Status $c.Name -PercentComplete (100 * $i / $checks.Count)
        try {
            foreach ($f in @(& $c.Run)) { if ($f) { $findings.Add($f) } }
        } catch {
            $findings.Add((New-WHFinding -Id "error-$i" -Category System -Severity Info -Title "Check '$($c.Name)' could not run" -Detail "$($_.Exception.Message)"))
        }
    }
    Write-Progress -Activity 'WinHealth analysis' -Completed
    [pscustomobject]@{
        SystemInfo = $info
        Days       = $Days
        Findings   = @(Get-WHSortedFinding $findings)
    }
}
