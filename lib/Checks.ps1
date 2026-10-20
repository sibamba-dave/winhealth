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
#     disk 7/51/153, Ntfs 55/98/140  storage errors
#     Kernel-Power 506/507           entering / leaving Modern Standby
#     WHEA-Logger 1/17/18/19/47      hardware errors (CPU, memory, PCIe)
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
    $records = @($failures | ForEach-Object {
            $d = Get-WHEventDataMap $_
            [pscustomobject]@{ Title = Get-WHMapValue $d 'updateTitle', 'Param1'; Code = Get-WHMapValue $d 'errorCode', 'Param0'; Time = $_.TimeCreated }
        })
    $storeFails = @($records | Where-Object { Test-WHStoreAppUpdate $_.Title })
    $osFails = @($records | Where-Object { -not (Test-WHStoreAppUpdate $_.Title) })
    $failGroups = @($osFails | Group-Object Title | Sort-Object Count -Descending)
    $describe = {
        "$($_.Name): failed $($_.Count)x, error $(($_.Group | Select-Object -ExpandProperty Code -Unique) -join ', ')"
    }

    if ($failGroups.Count -gt 0) {
        $repeated = @($failGroups | Where-Object { $_.Count -ge 2 })
        $sev = if ($repeated.Count) { 'Critical' } else { 'Warning' }
        New-WHFinding -Id 'update-failures' -Category Updates -Severity $sev -Title "Windows Update failures ($($osFails.Count))" `
            -Detail 'Updates that fail and retry are a classic cause of "Restarting..." screens that hang or "Undoing changes" loops. Resetting the Windows Update cache and repairing system files usually clears it.' `
            -Evidence ($failGroups | Select-Object -First 10 | ForEach-Object $describe) -FixIds 'ResetWindowsUpdate', 'RepairSystemFiles'
    }
    if ($storeFails.Count -gt 0) {
        New-WHFinding -Id 'store-update-failures' -Category Updates -Severity Info -Title "Microsoft Store app updates failed ($($storeFails.Count))" `
            -Detail 'These are Store apps, not Windows itself, and do not affect shutdown or restart. They usually succeed on a later try; otherwise update them from the Store app.' `
            -Evidence ($storeFails | Group-Object Title | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object $describe)
    }

    if ($pending.Count -gt 0) {
        New-WHFinding -Id 'pending-reboot' -Category Updates -Severity Warning -Title 'A restart is pending to finish installing updates' `
            -Detail 'Windows has work queued for the next restart. If restarts keep hanging, that queued work may be what is stuck. Let one restart run for 20-30 minutes; if it still hangs, run the Windows Update reset.' `
            -Evidence $pending -FixIds 'ResetWindowsUpdate'
    } elseif ($failGroups.Count -eq 0) {
        New-WHFinding -Id 'updates-ok' -Category Updates -Severity OK -Title 'No pending restart or failed updates'
    }
}

function Find-WHDebugger {
    # kd.exe/cdb.exe from WinDbg (Store/winget) or the Windows SDK, if installed.
    $candidates = @(
        (Join-Path "${env:ProgramFiles(x86)}" 'Windows Kits\10\Debuggers\x64\kd.exe'),
        (Join-Path $env:ProgramFiles 'Windows Kits\10\Debuggers\x64\kd.exe')
    )
    try {
        $pkg = Get-AppxPackage -Name 'Microsoft.WinDbg*' -ErrorAction Stop | Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation) {
            $candidates += @(Get-ChildItem -Path $pkg.InstallLocation -Filter 'kd.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                    Where-Object { $_.DirectoryName -match 'amd64|x64' } | ForEach-Object FullName)
        }
    } catch {
        Write-Verbose "Get-AppxPackage unavailable: $($_.Exception.Message)"
    }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command kd.exe, cdb.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $null
}

function Invoke-WHDumpAnalysis {
    # Runs "!analyze -v" on a crash dump. Needs internet for symbols; the full
    # debugger output is saved next to the report.
    param([string]$Debugger, [System.IO.FileInfo]$Dump, [string]$OutputPath, [int]$TimeoutSeconds = 240)
    $symbols = Join-Path $env:TEMP 'WinHealthSymbols'
    $outFile = Join-Path $OutputPath "analyze-$($Dump.BaseName).txt"
    $dbgArgs = @('-z', "`"$($Dump.FullName)`"", '-y', "`"srv*$symbols*https://msdl.microsoft.com/download/symbols`"", '-c', '"!analyze -v; q"')
    $p = Start-Process -FilePath $Debugger -ArgumentList $dbgArgs -RedirectStandardOutput $outFile -NoNewWindow -PassThru
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { Write-Verbose 'debugger already exited' }
        return $null
    }
    $parsed = ConvertFrom-WHAnalyzeOutput (Get-Content $outFile -ErrorAction SilentlyContinue)
    $parsed | Add-Member -NotePropertyName OutputFile -NotePropertyValue $outFile -PassThru
}

function Test-WHStability {
    param([datetime]$Since, [string]$OutputPath)
    $bugchecks = Get-WHEvent @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $Since } -MaxEvents 100
    $dumpDir = Join-Path $env:SystemRoot 'Minidump'
    $dumps = @()
    if (Test-Path $dumpDir) { $dumps = @(Get-ChildItem $dumpDir -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $Since }) }
    if ($bugchecks.Count -gt 0 -or $dumps.Count -gt 0) {
        $names = [System.Collections.Generic.List[string]]::new()
        $evidence = @($bugchecks | ForEach-Object {
                $code = if ($_.Message -match '(0x[0-9a-fA-F]+)\s*\(') { $Matches[1] } else { '' }
                $info = Get-WHBugcheckInfo $code
                if ($info.Name -and -not $names.Contains($info.Name)) { $names.Add($info.Name) }
                if ($info.Name) { "$(Format-WHTime $_.TimeCreated): $($info.Code) $($info.Name) - $($info.Hint)" }
                else { "$(Format-WHTime $_.TimeCreated): bugcheck $(if ($code) { $info.Code } else { 'unknown' })" }
            })

        $debugger = Find-WHDebugger
        $recent = @($dumps | Sort-Object LastWriteTime -Descending | Select-Object -First 3)
        foreach ($dump in $recent) {
            $line = "Dump file: $($dump.FullName)"
            if ($debugger -and $OutputPath) {
                Write-Progress -Activity 'WinHealth analysis' -Status "Analysing crash dump $($dump.Name) (can take a few minutes the first time)"
                $a = Invoke-WHDumpAnalysis -Debugger $debugger -Dump $dump -OutputPath $OutputPath
                if ($a -and ($a.Process -or $a.Module -or $a.Bucket)) {
                    $parts = @()
                    if ($a.Process) { $parts += "process $($a.Process)" }
                    if ($a.Module) { $parts += "driver/module $($a.Module)" }
                    if ($a.Bucket) { $parts += "bucket $($a.Bucket)" }
                    $line += " -> $($parts -join ', ') (full output: $($a.OutputFile))"
                } else {
                    $line += ' -> debugger could not analyse it (no internet for symbols?)'
                }
            }
            $evidence += $line
        }
        $evidence += @($dumps | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | ForEach-Object { "Dump file: $($_.FullName)" })
        if ($dumps.Count -and -not $debugger) {
            $evidence += 'To name the crashing process/driver automatically, install WinDbg (winget install Microsoft.WinDbg) and run WinHealth again.'
        }

        $count = [math]::Max($bugchecks.Count, $dumps.Count)
        $title = "Blue-screen crashes ($count)"
        if ($names.Count) { $title += ": $($names -join ', ')" }
        New-WHFinding -Id 'bugchecks' -Category Stability -Severity Critical -Title $title `
            -Detail 'The code says what kind of failure it was; the dump analysis (when available) names the process or driver involved. Driver bugs are the usual cause, but CRITICAL_PROCESS_DIED, KERNEL_DATA_INPAGE_ERROR and WHEA errors often mean disk or memory/overclock instability instead.' `
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

function Test-WHHardwareErrors {
    param([datetime]$Since)
    $events = Get-WHEvent @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $Since } -MaxEvents 1000
    if ($events.Count -eq 0) {
        New-WHFinding -Id 'whea' -Category Stability -Severity OK -Title 'No hardware errors reported (WHEA)'
        return
    }
    $worst = 'Warning'
    $evidence = foreach ($g in ($events | Group-Object Id | Sort-Object Count -Descending)) {
        $info = Get-WHWheaInfo ([int]$g.Name)
        if ($info.Severity -eq 'Critical') { $worst = 'Critical' }
        $latest = $g.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
        $where = @()
        if ($latest.Message -match 'Component:\s*(.+)') { $where += $Matches[1].Trim() }
        if ($latest.Message -match 'Error Source:\s*(.+)') { $where += $Matches[1].Trim() }
        "$($info.Text): $($g.Count)x, last $(Format-WHTime $latest.TimeCreated)$(if ($where) { " [$($where -join '; ')]" })"
    }
    New-WHFinding -Id 'whea' -Category Stability -Severity $worst -Title "Hardware errors reported ($($events.Count))" `
        -Detail 'The CPU, memory or PCIe bus reported errors. This is the classic cause of random freezes and reboots that no driver update fixes. Most common on enthusiast PCs: turn off memory overclocks (EXPO/XMP) and CPU tuning (PBO, Curve Optimizer, undervolts) in the BIOS, update the BIOS, then test memory. For PCI Express errors, reseat the graphics card and NVMe drives.' `
        -Evidence $evidence
}

function Test-WHSleepHistory {
    param([datetime]$Since)
    $events = Get-WHEvent @{ LogName = 'System'; Id = 1, 12, 41, 42, 107, 506, 507, 6005, 6008; StartTime = $Since } -MaxEvents 3000
    $timeline = foreach ($e in $events) {
        $kind = $null; $detail = ''; $state = ''
        switch ("$($e.ProviderName)|$($e.Id)") {
            'Microsoft-Windows-Kernel-Power|42' {
                $state = Get-WHMapValue (Get-WHEventDataMap $e) 'TargetState'
                $kind = 'Sleep'; $detail = Get-WHSleepStateName $state
            }
            'Microsoft-Windows-Kernel-Power|506' { $kind = 'Sleep'; $detail = 'Modern Standby' }
            'Microsoft-Windows-Kernel-Power|107' { $kind = 'Resume' }
            'Microsoft-Windows-Kernel-Power|507' { $kind = 'Resume' }
            'Microsoft-Windows-Power-Troubleshooter|1' { $kind = 'Resume' }
            'EventLog|6005' { $kind = 'Boot' }
            'Microsoft-Windows-Kernel-General|12' { $kind = 'Boot' }
            'EventLog|6008' { $kind = 'Dirty' }
            'Microsoft-Windows-Kernel-Power|41' { $kind = 'Dirty' }
        }
        if ($kind) { [pscustomobject]@{ Time = $e.TimeCreated; Kind = $kind; Detail = $detail; State = "$state" } }
    }
    $outcomes = @(Find-WHSleepOutcome -Timeline @($timeline))
    if ($outcomes.Count -eq 0) {
        New-WHFinding -Id 'sleep-history' -Category Sleep -Severity Info -Title 'The PC has not gone to sleep in this period' `
            -Detail 'Windows recorded no sleep at all. If the screen goes dark and the PC then will not respond, that is the display turning off while the PC freezes, not a sleep problem; see the unexpected reboots and hardware error findings.'
        return
    }
    # Fast Startup "shutdown" is a hibernate that ends in a normal boot; that is not a failed wake.
    $failed = @($outcomes | Where-Object { $_.Outcome -eq 'NeverResumed' -and -not ($_.State -eq '5' -and $_.EndedBy -eq 'Boot') })
    $resumed = @($outcomes | Where-Object { $_.Outcome -eq 'Resumed' })
    if ($failed.Count -gt 0) {
        $evidence = $failed | Sort-Object SleptAt -Descending | ForEach-Object {
            "$(Format-WHTime $_.SleptAt): went to $($_.Detail) -> never woke up; next event was $(if ($_.EndedBy -eq 'Dirty') { 'a forced power-off' } else { 'a fresh boot' }) at $(Format-WHTime $_.EndedAt)"
        }
        New-WHFinding -Id 'sleep-history' -Category Sleep -Severity Critical -Title "$($failed.Count) of $($outcomes.Count) sleeps never woke up" `
            -Detail "The PC went to sleep and Windows never recorded waking up; the next thing in the log is a restart. ($($resumed.Count) sleeps did resume normally.) Usual causes: graphics, USB or network drivers, BIOS sleep bugs, or unstable memory/CPU settings that only fail on wake." `
            -Evidence $evidence -FixIds 'RebuildHibernation', 'DisarmWakeDevices'
    } else {
        New-WHFinding -Id 'sleep-history' -Category Sleep -Severity OK -Title "All $($resumed.Count) recorded sleeps woke up normally"
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

    # Storage cmdlets (Get-PhysicalDisk, Get-Disk) can hang when the storage
    # stack is misbehaving, so query CIM directly with a timeout.
    try {
        $physical = @(Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName MSFT_PhysicalDisk -OperationTimeoutSec 20 -ErrorAction Stop)
        $bad = @($physical | Where-Object { $_.HealthStatus -ne 0 })
        if ($bad.Count -gt 0) {
            New-WHFinding -Id 'disk-health' -Category Storage -Severity Critical -Title 'A physical disk reports a health problem' `
                -Detail 'Back up your data now. A failing disk causes slow wake, hangs and corrupted updates.' `
                -Evidence ($bad | ForEach-Object { "$($_.FriendlyName): $(ConvertTo-WHHealthName $_.HealthStatus)" })
        }
    } catch {
        New-WHFinding -Id 'disk-query-timeout' -Category Storage -Severity Warning -Title 'Windows storage management did not respond' `
            -Detail 'Asking Windows for disk information timed out or failed. That itself suggests a storage driver or disk problem (see the NVMe driver and storage error findings).' `
            -Evidence "$($_.Exception.Message)"
    }

    $records = @(Get-WHStorageErrorRecord -Since $Since)
    foreach ($g in ($records | Group-Object Volume | Sort-Object Count -Descending)) {
        $vol = $g.Name
        $label = if ($vol) { $vol } else { 'a disk (no drive letter in the log)' }
        $evidence = @($g.Group | Group-Object Provider, Id | Sort-Object Count -Descending | ForEach-Object {
                $first = $_.Group[0]
                "$($first.Provider) $($first.Id): $($_.Count)x, last $(Format-WHTime (($_.Group | Sort-Object Time -Descending)[0].Time)) - $($first.Text)"
            })
        $bus = $null
        if ($vol) {
            $disk = Get-WHDriveDisk $vol
            if ($disk) {
                $bus = $disk.Bus
                $evidence = @("$vol is on $($disk.Name) (connected via $bus, health $($disk.Health))") + $evidence
            }
        }
        $detail = "Errors writing to or reading from $label. "
        if (@($g.Group | Where-Object { $_.Id -eq 140 }).Count) {
            $detail += 'Event 140 means Windows could not write to the drive at all - the drive or its connection dropped out for a moment. '
        }
        if ($bus -eq 'USB') {
            $detail += 'It is a USB drive: plug it directly into a rear motherboard port (not a hub or front panel), try another cable, and use "Safely remove" before unplugging. '
        } else {
            $detail += 'Check the drive health (e.g. CrystalDiskInfo), reseat its cable or the NVMe drive, and update SSD firmware and storage drivers. '
        }
        $detail += 'A drive that drops out can freeze the whole PC, stall shutdown and crash Windows processes. Back up anything important on it.'
        $sev = if ($g.Count -ge 10) { 'Critical' } else { 'Warning' }
        $id = if ($vol) { "disk-errors-$($vol.TrimEnd(':').ToLower())" } else { 'disk-errors' }
        New-WHFinding -Id $id -Category Storage -Severity $sev -Title "Storage errors on $label ($($g.Count))" `
            -Detail $detail -Evidence $evidence -FixIds 'ScheduleDiskCheck'
    }
}

function ConvertTo-WHHealthName {
    param($Value)
    switch ([int]$Value) { 0 { 'Healthy' } 1 { 'Warning' } 2 { 'Unhealthy' } default { 'Unknown' } }
}

function Get-WHDriveDisk {
    # Disk behind a drive letter via CIM with a timeout (Get-Partition | Get-Disk can hang).
    param([string]$Letter)
    $busNames = @{ 1 = 'SCSI'; 3 = 'ATA'; 7 = 'USB'; 8 = 'RAID'; 10 = 'SAS'; 11 = 'SATA'; 12 = 'SD'; 17 = 'NVMe' }
    try {
        $part = Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName MSFT_Partition -Filter "DriveLetter='$($Letter[0])'" -OperationTimeoutSec 20 -ErrorAction Stop | Select-Object -First 1
        if (-not $part) { return $null }
        $disk = Get-CimAssociatedInstance -InputObject $part -ResultClassName MSFT_Disk -OperationTimeoutSec 20 -ErrorAction Stop | Select-Object -First 1
        if (-not $disk) { return $null }
        $bus = if ($busNames.ContainsKey([int]$disk.BusType)) { $busNames[[int]$disk.BusType] } else { "bus type $($disk.BusType)" }
        [pscustomobject]@{ Name = $disk.FriendlyName; Bus = $bus; Health = ConvertTo-WHHealthName $disk.HealthStatus }
    } catch {
        Write-Verbose "No disk info for ${Letter}: $($_.Exception.Message)"
        $null
    }
}

function Get-WHNvmeOverride {
    # Feature-management overrides that switch Windows to the experimental
    # native NVMe driver (nvmedisk.sys) instead of stornvme.sys.
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides'
    foreach ($name in '735209102', '1853569164', '156965516', '1176759950') {
        if ((Get-WHRegistryValue $key $name) -eq 1) { $name }
    }
}

function Get-WHNvmeDiskDevice {
    # Devices actually bound to the experimental driver. The service can show
    # as running without owning any device, so this is the real test.
    @(Get-CimInstance Win32_PnPEntity -Filter "Service='nvmedisk'" -OperationTimeoutSec 20 -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}

function Test-WHNvmeDriver {
    $overrides = @(Get-WHNvmeOverride)
    $svc = Get-Service -Name nvmedisk -ErrorAction SilentlyContinue
    $running = [bool]($svc -and "$($svc.Status)" -eq 'Running')
    $devices = @(Get-WHNvmeDiskDevice)
    if (-not $overrides.Count -and -not $running -and -not $devices.Count) { return }

    $evidence = @()
    foreach ($d in $devices) { $evidence += "Using nvmedisk: $d" }
    if ($running -and -not $devices.Count) { $evidence += 'nvmedisk service is loaded but no device is using it' }
    if ($overrides.Count) { $evidence += "Feature overrides set: $($overrides -join ', ') under HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides" }
    elseif ($devices.Count) { $evidence += 'None of the usual registry overrides are set, so it was enabled another way (e.g. ViVeTool feature ids). WinHealth cannot switch it off automatically; undo it the same way it was enabled.' }
    $pnp = @(Get-WHEvent @{ LogName = 'Microsoft-Windows-Kernel-PnP/Configuration'; Id = 400, 410 } -MaxEvents 5000 | Where-Object { $_.Message -match 'nvmedisk' })
    if ($pnp.Count) {
        $first = ($pnp | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated
        $evidence += "First seen in use: $(Format-WHTime $first) - compare with when the freezes started"
    }
    if (-not $devices.Count -and -not $overrides.Count) {
        New-WHFinding -Id 'nvme-experimental' -Category Storage -Severity Info -Title 'Experimental NVMe driver is loaded but unused' `
            -Detail 'The nvmedisk driver is loaded, but no drive is using it; drives use the standard driver.' -Evidence $evidence
        return
    }
    $sev = if ($devices.Count) { 'Critical' } else { 'Warning' }
    New-WHFinding -Id 'nvme-experimental' -Category Storage -Severity $sev -Title 'The experimental Windows NVMe driver is enabled' `
        -Detail 'Your NVMe drives are using the native NVMe driver that Microsoft made for Windows Server and that is only switched on in Windows 11 by registry override. It is not supported on Windows 11 and has known problems with some SSDs and tools: drives dropping out, hangs, failed writes and crashes. Switch back to the standard driver, restart, and see whether the freezes stop.' `
        -Evidence $evidence -FixIds 'DisableExperimentalNvmeDriver'
}

function Get-WHStorageErrorRecord {
    param([datetime]$Since)
    # Filter providers client-side: naming a provider that is not installed
    # makes Get-WinEvent return nothing at all.
    $errors = @(Get-WHEvent @{ LogName = 'System'; Id = 7, 11, 51, 129, 153, 55, 98, 140; Level = 1, 2, 3; StartTime = $Since } -MaxEvents 500)
    foreach ($e in $errors) {
        if ($e.ProviderName -notin 'disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'storahci', 'stornvme', 'iaStorA', 'iaStorAC', 'iaStorAVC', 'nvme') { continue }
        [pscustomobject]@{
            Volume   = Get-WHVolumeFromMessage $e.Message
            Provider = $e.ProviderName
            Id       = $e.Id
            Time     = $e.TimeCreated
            Text     = ("$($e.Message)" -split "`r?`n")[0].Trim()
        }
    }
}

function Get-WHDiskCheckTarget {
    # Drives worth checking: the system drive if flagged dirty, plus every
    # drive named in recent storage errors.
    param([int]$Days = 30)
    $targets = [System.Collections.Generic.List[string]]::new()
    $dirty = (Invoke-WHNative 'fsutil.exe' 'dirty', 'query', $env:SystemDrive) -join ' '
    if ($dirty -match 'is Dirty' -and $dirty -notmatch 'is NOT Dirty') { $targets.Add($env:SystemDrive.ToUpper()) }
    foreach ($r in @(Get-WHStorageErrorRecord -Since (Get-Date).AddDays(-$Days))) {
        if ($r.Volume -and -not $targets.Contains($r.Volume)) { $targets.Add($r.Volume) }
    }
    @($targets)
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
        @{ Name = 'Sleep history'; Run = { Test-WHSleepHistory -Since $since } },
        @{ Name = 'Windows Update'; Run = { Test-WHUpdates -Since $since } },
        @{ Name = 'Crashes & drivers'; Run = { Test-WHStability -Since $since -OutputPath $OutputPath } },
        @{ Name = 'Hardware errors'; Run = { Test-WHHardwareErrors -Since $since } },
        @{ Name = 'Firmware & uptime'; Run = { Test-WHBios -SystemInfo $info } },
        @{ Name = 'Storage'; Run = { Test-WHStorage -Since $since } },
        @{ Name = 'NVMe driver'; Run = { Test-WHNvmeDriver } }
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

    # Drop fixes that would change nothing on this PC (e.g. Fast Startup already off).
    $catalog = Get-WHFixCatalog
    $cache = @{}
    foreach ($f in $findings) {
        $f.FixIds = @($f.FixIds | Where-Object { Test-WHFixApplies -Catalog $catalog -Id $_ -Cache $cache })
    }

    [pscustomobject]@{
        SystemInfo = $info
        Days       = $Days
        Findings   = @(Get-WHSortedFinding $findings)
    }
}
