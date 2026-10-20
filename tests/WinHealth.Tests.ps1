BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    foreach ($lib in 'Common', 'Parsers', 'Checks', 'Fixes', 'Report') {
        . (Join-Path $root "lib/$lib.ps1")
    }

    function New-FakeEvent {
        param([string]$Provider, [int]$Id, [datetime]$Time, [System.Collections.IDictionary]$Data = @{}, [string]$Message = '')
        $dataXml = ($Data.GetEnumerator() | ForEach-Object { "<Data Name='$($_.Key)'>$([System.Security.SecurityElement]::Escape([string]$_.Value))</Data>" }) -join ''
        $xml = "<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><Provider Name='$Provider'/><EventID>$Id</EventID></System><EventData>$dataXml</EventData></Event>"
        $o = [pscustomobject]@{ ProviderName = $Provider; Id = $Id; TimeCreated = $Time; Message = $Message; Xml = $xml }
        $o | Add-Member -MemberType ScriptMethod -Name ToXml -Value { $this.Xml }
        $o
    }
}

Describe 'Get-WHEventDataMap' {
    It 'reads named data' {
        $e = New-FakeEvent -Provider P -Id 1 -Time (Get-Date) -Data ([ordered]@{ SleepInProgress = '4'; BugcheckCode = '0' })
        $m = Get-WHEventDataMap $e
        $m['SleepInProgress'] | Should -Be '4'
        $m['BugcheckCode'] | Should -Be '0'
    }
    It 'keys unnamed data as ParamN and reads UserData' {
        $e = [pscustomobject]@{}
        $e | Add-Member ScriptMethod ToXml { "<Event xmlns='x'><System/><EventData><Data>a</Data><Data>b</Data></EventData></Event>" }
        $m = Get-WHEventDataMap $e
        $m['Param0'] | Should -Be 'a'; $m['Param1'] | Should -Be 'b'

        $u = [pscustomobject]@{}
        $u | Add-Member ScriptMethod ToXml { "<Event xmlns='x'><System/><UserData><Foo><Bar>1</Bar><Baz>2</Baz></Foo></UserData></Event>" }
        $m = Get-WHEventDataMap $u
        $m['Bar'] | Should -Be '1'; $m['Baz'] | Should -Be '2'
    }
}

Describe 'ConvertTo-WHInt' {
    It 'parses leniently' {
        ConvertTo-WHInt '' | Should -Be 0
        ConvertTo-WHInt 'false' | Should -Be 0
        ConvertTo-WHInt 'true' | Should -Be 1
        ConvertTo-WHInt '0x9F' | Should -Be 159
        ConvertTo-WHInt '133' | Should -Be 133
        ConvertTo-WHInt 'junk' | Should -Be 0
    }
}

Describe 'powercfg parsers' {
    It 'detects Modern Standby from powercfg /a' {
        $lines = @(
            'The following sleep states are available on this system:'
            '    Standby (S0 Low Power Idle) Network Connected'
            '    Hibernate'
            '    Fast Startup'
            ''
            'The following sleep states are not available on this system:'
            '    Standby (S1)'
            '        The system firmware does not support this standby state.'
            '        This standby state is disabled when S0 low power idle is supported.'
            '    Standby (S3)'
            '        This standby state is disabled when S0 low power idle is supported.'
        )
        $s = ConvertFrom-WHSleepStates $lines
        $s.ModernStandby | Should -BeTrue
        $s.S3 | Should -BeFalse
        $s.Hibernate | Should -BeTrue
        $s.FastStartup | Should -BeTrue
        $s.Unavailable | Should -Contain 'Standby (S3)'
        $s.Unavailable | Should -Not -Contain 'This standby state is disabled when S0 low power idle is supported.'
    }

    It 'detects classic S3' {
        $s = ConvertFrom-WHSleepStates @('The following sleep states are available on this system:', '    Standby (S3)', '    Hibernate', '    Hybrid Sleep')
        $s.ModernStandby | Should -BeFalse
        $s.S3 | Should -BeTrue
        $s.HybridSleep | Should -BeTrue
    }

    It 'parses powercfg /requests' {
        $lines = @(
            'DISPLAY:', 'None.', '',
            'SYSTEM:', '[DRIVER] Realtek High Definition Audio (HDAUDIO\FUNC_01&VEN_10EC)', 'An audio stream is currently in use.', '',
            'AWAYMODE:', 'None.', '',
            'EXECUTION:', '[PROCESS] \Device\HarddiskVolume3\Program Files\App\app.exe', '',
            'PERFBOOST:', 'None.'
        )
        $r = ConvertFrom-WHPowerRequests $lines
        $r.Count | Should -Be 2
        $r[0].Type | Should -Be 'SYSTEM'
        $r[0].Kind | Should -Be 'DRIVER'
        $r[0].Reason | Should -Be 'An audio stream is currently in use.'
        $r[1].Type | Should -Be 'EXECUTION'
        $r[1].Name | Should -Match 'app.exe$'
    }

    It 'parses wake timers' {
        $lines = @(
            'Timer set by [SERVICE] \Device\HarddiskVolume2\Windows\System32\svchost.exe (SystemEventsBroker) expires at 8:30:12 PM on 10/21/2026.',
            '  Reason: Windows will execute ''NT TASK\Microsoft\Windows\UpdateOrchestrator\Reboot'' scheduled task that requested waking the computer.'
        )
        $t = ConvertFrom-WHWakeTimers $lines
        $t.Count | Should -Be 1
        $t[0].Owner | Should -Match 'SystemEventsBroker'
        $t[0].Expires | Should -Be '8:30:12 PM on 10/21/2026'
        $t[0].Reason | Should -Match 'UpdateOrchestrator'
        (ConvertFrom-WHWakeTimers @('There are no active wake timers in the system.')).Count | Should -Be 0
    }

    It 'parses wake-armed devices' {
        ConvertFrom-WHDeviceList @('HID Keyboard Device', 'Intel(R) Ethernet Connection', '') | Should -HaveCount 2
        ConvertFrom-WHDeviceList @('NONE', '') | Should -HaveCount 0
    }

    It 'parses power setting indexes' {
        $q = ConvertFrom-WHPowerSettingQuery @('    Current AC Power Setting Index: 0x00000001', '    Current DC Power Setting Index: 0x00000000')
        $q.AC | Should -Be 1
        $q.DC | Should -Be 0
    }
}

Describe 'shutdown timeline analysis' {
    BeforeAll {
        $t0 = [datetime]'2026-10-01 22:00:00'
        function New-Rec($min, $kind, $detail = '') { [pscustomobject]@{ Time = $t0.AddMinutes($min); Kind = $kind; Detail = $detail } }
    }

    It 'flags a restart that never finished and was power-cycled' {
        $timeline = @(
            (New-Rec 0 Requested 'restart requested by TrustedInstaller'),
            (New-Rec 30 Boot), (New-Rec 30.1 Dirty)  # boot + Kernel-Power 41 written together at startup
        )
        $h = Find-WHIncompleteShutdown $timeline
        $h.Count | Should -Be 1
        $h[0].Detail | Should -Match 'TrustedInstaller'
        $h[0].EndedBy | Should -Be 'Dirty'
    }

    It 'ignores clean restarts' {
        $timeline = @((New-Rec 0 Requested 'x'), (New-Rec 0.5 Clean), (New-Rec 0.6 Clean), (New-Rec 1 Boot))
        (Find-WHIncompleteShutdown $timeline).Count | Should -Be 0
        $d = Measure-WHShutdownDuration $timeline
        $d.Count | Should -Be 1
        $d[0].Seconds | Should -Be 30
    }

    It 'handles unsorted input' {
        $timeline = @((New-Rec 5 Boot), (New-Rec 0 Requested 'x'))
        (Find-WHIncompleteShutdown $timeline).Count | Should -Be 1
    }
}

Describe 'Diagnostics-Performance helpers' {
    It 'reads durations from messages' {
        Get-WHDurationFromMessage "Windows has shutdown`r`n`tShutdown Duration`t:`t95123ms" 'Shutdown Duration' | Should -Be 95123
        Get-WHDurationFromMessage 'nothing here' | Should -BeNullOrEmpty
    }
    It 'ranks culprits by total delay' {
        $r = Group-WHCulprit @(
            [pscustomobject]@{ Name = 'A'; DelayMs = 1000 },
            [pscustomobject]@{ Name = 'B'; DelayMs = 9000 },
            [pscustomobject]@{ Name = 'A'; DelayMs = 2000 }
        )
        $r[0].Name | Should -Be 'B'
        $r[1].Count | Should -Be 2
        $r[1].TotalMs | Should -Be 3000
    }
}

Describe 'Test-WHShutdownHistory (mocked event log)' {
    It 'reports hung restarts and hangs during sleep' {
        $t0 = [datetime]'2026-10-10 08:00:00'
        $events = @(
            New-FakeEvent -Provider 'User32' -Id 1074 -Time $t0 -Data ([ordered]@{ param1 = 'C:\Windows\servicing\TrustedInstaller.exe'; param2 = 'PC'; param3 = 'Operating System: Upgrade (Planned)'; param4 = '0x80020003'; param5 = 'restart' })
            New-FakeEvent -Provider 'EventLog' -Id 6005 -Time $t0.AddMinutes(20)
            New-FakeEvent -Provider 'Microsoft-Windows-Kernel-Power' -Id 41 -Time $t0.AddMinutes(20) -Data ([ordered]@{ BugcheckCode = '0'; SleepInProgress = '0'; PowerButtonTimestamp = '133' })
            New-FakeEvent -Provider 'Microsoft-Windows-Kernel-Power' -Id 41 -Time $t0.AddDays(2) -Data ([ordered]@{ BugcheckCode = '0'; SleepInProgress = '4'; PowerButtonTimestamp = '0' })
        )
        Mock Get-WHEvent { $events }
        $f = @(Test-WHShutdownHistory -Since $t0.AddDays(-1))
        $hung = $f | Where-Object Id -EQ 'hung-shutdowns'
        $hung.Severity | Should -Be 'Critical'
        $hung.Evidence[0] | Should -Match 'TrustedInstaller.*forced power-off'
        $unexpected = $f | Where-Object Id -EQ 'unexpected-reboots'
        $unexpected.Detail | Should -Match '1 of them happened while the PC was going to sleep'
        $unexpected.FixIds | Should -Contain 'RebuildHibernation'
    }

    It 'reports OK when everything shut down cleanly' {
        $t0 = [datetime]'2026-10-10 08:00:00'
        $events = @(
            New-FakeEvent -Provider 'User32' -Id 1074 -Time $t0 -Data ([ordered]@{ param1 = 'explorer.exe'; param5 = 'power off' })
            New-FakeEvent -Provider 'EventLog' -Id 6006 -Time $t0.AddSeconds(8)
            New-FakeEvent -Provider 'EventLog' -Id 6005 -Time $t0.AddHours(8)
        )
        Mock Get-WHEvent { $events }
        $f = @(Test-WHShutdownHistory -Since $t0.AddDays(-1))
        ($f | Where-Object Severity -In 'Critical', 'Warning') | Should -BeNullOrEmpty
        ($f | Where-Object Id -EQ 'shutdown-speed').Title | Should -Match '8s'
    }
}

Describe 'Test-WHDiagnosticsPerformance (mocked)' {
    It 'summarises slow shutdowns and culprits' {
        $t0 = [datetime]'2026-10-10 08:00:00'
        $events = @(
            New-FakeEvent -Provider 'Microsoft-Windows-Diagnostics-Performance' -Id 200 -Time $t0 -Message "Windows has shutdown`r`n  Shutdown Duration  :  120000ms"
            New-FakeEvent -Provider 'Microsoft-Windows-Diagnostics-Performance' -Id 203 -Time $t0 -Data ([ordered]@{ Name = 'BadSvc'; FriendlyName = 'Bad Vendor Service'; TotalTime = '60000'; DegradationTime = '58000' })
        )
        Mock Get-WHEvent { $events }
        $f = @(Test-WHDiagnosticsPerformance -Since $t0.AddDays(-1))
        ($f | Where-Object Id -EQ 'diagperf-shutdown-time').Severity | Should -Be 'Critical'
        ($f | Where-Object Id -EQ 'diagperf-shutdown-culprits').Title | Should -Match 'Bad Vendor Service \(BadSvc\)'
    }
}

Describe 'report' {
    It 'recommends fixes from warnings only, most severe first, without duplicates' {
        $f = @(
            New-WHFinding -Id a -Category Sleep -Severity Warning -Title a -FixIds DisableWakeTimers, DisableFastStartup
            New-WHFinding -Id b -Category Shutdown -Severity Critical -Title b -FixIds DisableFastStartup
            New-WHFinding -Id c -Category Sleep -Severity Info -Title c -FixIds DisableStandbyNetwork
        )
        Get-WHRecommendedFix $f | Should -Be @('DisableFastStartup', 'DisableWakeTimers')
    }

    It 'every fix id referenced by checks exists in the catalog' {
        $catalog = Get-WHFixCatalog
        $src = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/Checks.ps1') -Raw
        $ids = [regex]::Matches($src, "(?:-FixIds|\`$fixes \+=|\`$stateFixes \+=|\`$fixes = @\()\s*('[A-Za-z]+'(?:\s*,\s*'[A-Za-z]+')*)") |
            ForEach-Object { [regex]::Matches($_.Groups[1].Value, "'([A-Za-z]+)'") } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $ids.Count | Should -BeGreaterThan 5
        foreach ($id in $ids) { $catalog.Contains($id) | Should -BeTrue -Because "$id is referenced in Checks.ps1" }
    }

    It 'writes HTML and JSON with escaped content' {
        $result = [pscustomobject]@{
            SystemInfo = [pscustomobject]@{ ComputerName = 'PC'; OS = 'Windows 11'; Model = 'Contoso <Laptop>'; BIOS = '1.0'; BIOSDate = $null
                LastBoot = (Get-Date).AddHours(-5); Uptime = New-TimeSpan -Hours 5; MemoryGB = 16; GeneratedAt = Get-Date }
            Days       = 30
            Findings   = @(New-WHFinding -Id x -Category Shutdown -Severity Critical -Title 'Hang <script>' -Evidence 'a & b' -FixIds DisableFastStartup)
        }
        $html = Join-Path $TestDrive 'r.html'; $json = Join-Path $TestDrive 'r.json'
        Export-WHHtmlReport -Result $result -Path $html
        Export-WHJsonReport -Result $result -Path $json
        $content = Get-Content $html -Raw
        $content | Should -Match 'Hang &lt;script&gt;'
        $content | Should -Match 'Contoso &lt;Laptop&gt;'
        $content | Should -Match '-Fix DisableFastStartup'
        (Get-Content $json -Raw | ConvertFrom-Json).Findings[0].Id | Should -Be 'x'
    }

    It 'still writes the report under -WhatIf' {
        $result = [pscustomobject]@{
            SystemInfo = [pscustomobject]@{ ComputerName = 'PC'; OS = 'W'; Model = 'M'; BIOS = '1'; BIOSDate = $null
                LastBoot = Get-Date; Uptime = New-TimeSpan; MemoryGB = 8; GeneratedAt = Get-Date }
            Days = 7; Findings = @()
        }
        $json = Join-Path $TestDrive 'whatif.json'
        $WhatIfPreference = $true
        Export-WHJsonReport -Result $result -Path $json
        $WhatIfPreference = $false
        Test-Path $json | Should -BeTrue
    }
}

Describe 'Get-WHEvent' {
    BeforeAll {
        # Pester can only mock commands that exist; Get-WinEvent is Windows-only.
        if (-not (Get-Command Get-WinEvent -ErrorAction SilentlyContinue)) {
            function global:Get-WinEvent { param($FilterHashtable, $MaxEvents) }
        }
    }
    It 'returns nothing when <Message>' -TestCases @(
        @{ Message = 'No events were found that match the specified selection criteria.' }
        @{ Message = 'The specified providers do not write events to any of the specified logs.' }
        @{ Message = 'There is not an event log on the localhost computer that matches "Foo".' }
    ) {
        Mock Get-WinEvent { throw $Message }
        @(Get-WHEvent @{ LogName = 'Application'; ProviderName = 'X' }).Count | Should -Be 0
    }
    It 'rethrows other errors' {
        Mock Get-WinEvent { throw 'Access is denied' }
        { Get-WHEvent @{ LogName = 'Security' } } | Should -Throw '*Access is denied*'
    }
}

Describe 'new parsers' {
    It 'recognises Microsoft Store app updates' {
        Test-WHStoreAppUpdate '9NKSQGP7F2NH-5319275A.WhatsAppDesktop' | Should -BeTrue
        Test-WHStoreAppUpdate '9PDV73CBV7L8-Microsoft.Ink.Handwriting.Main.en-GB.1.0.1' | Should -BeTrue
        Test-WHStoreAppUpdate '2026-10 Cumulative Update for Windows 11 Version 25H2 (KB5050001)' | Should -BeFalse
        Test-WHStoreAppUpdate 'Security Intelligence Update for Microsoft Defender Antivirus - KB2267602' | Should -BeFalse
    }

    It 'finds the drive letter in storage messages' {
        Get-WHVolumeFromMessage 'The system failed to flush data to the transaction log. Corruption may occur in VolumeId: E:, DeviceName: \Device\HarddiskVolume6.' | Should -Be 'E:'
        Get-WHVolumeFromMessage 'A corruption was discovered in the file system structure on volume D:.' | Should -Be 'D:'
        Get-WHVolumeFromMessage 'The device, \Device\Harddisk2\DR2, has a bad block.' | Should -BeNullOrEmpty
    }

    It 'names bugcheck codes' {
        $i = Get-WHBugcheckInfo '0x000000ef'
        $i.Code | Should -Be '0xEF'
        $i.Name | Should -Be 'CRITICAL_PROCESS_DIED'
        (Get-WHBugcheckInfo '0x00000124').Name | Should -Be 'WHEA_UNCORRECTABLE_ERROR'
        (Get-WHBugcheckInfo '0x12345').Name | Should -Be ''
    }

    It 'parses !analyze -v output' {
        $a = ConvertFrom-WHAnalyzeOutput @(
            'BUGCHECK_CODE:  ef', 'PROCESS_NAME:  svchost.exe', 'CRITICAL_PROCESS:  svchost.exe',
            'IMAGE_NAME:  nvmedisk.sys', 'MODULE_NAME: nvmedisk', 'FAILURE_BUCKET_ID:  0xEF_svchost.exe_BUGCHECK_CRITICAL_PROCESS_123'
        )
        $a.Process | Should -Be 'svchost.exe'
        $a.Module | Should -Be 'nvmedisk.sys'
        $a.Bucket | Should -Match '^0xEF_svchost'
    }
}

Describe 'Find-WHSleepOutcome' {
    BeforeAll {
        $t0 = [datetime]'2026-10-15 23:00:00'
        function New-Ev($min, $kind, $state = '') { [pscustomobject]@{ Time = $t0.AddMinutes($min); Kind = $kind; Detail = 'S3 sleep'; State = $state } }
    }
    It 'separates resumed sleeps from ones that never woke' {
        $o = Find-WHSleepOutcome @(
            (New-Ev 0 Sleep 4), (New-Ev 60 Resume),
            (New-Ev 120 Sleep 4), (New-Ev 600 Boot), (New-Ev 600.2 Dirty)
        )
        $o.Count | Should -Be 2
        $o[0].Outcome | Should -Be 'Resumed'
        $o[1].Outcome | Should -Be 'NeverResumed'
        $o[1].EndedBy | Should -Be 'Dirty'
        $o[1].State | Should -Be '4'
    }
    It 'reports a trailing sleep as unknown' {
        (Find-WHSleepOutcome @((New-Ev 0 Sleep 4)))[0].Outcome | Should -Be 'Unknown'
    }
}

Describe 'Test-WHSleepHistory (mocked)' {
    It 'says the PC never slept when there are no sleep events' {
        Mock Get-WHEvent { @(New-FakeEvent -Provider 'EventLog' -Id 6005 -Time (Get-Date)) }
        $f = Test-WHSleepHistory -Since (Get-Date).AddDays(-30)
        $f.Title | Should -Be 'The PC has not gone to sleep in this period'
    }
    It 'flags a sleep that ended in a forced power-off, but not a Fast Startup hibernate' {
        $t0 = [datetime]'2026-10-15 23:00:00'
        $events = @(
            New-FakeEvent -Provider 'Microsoft-Windows-Kernel-Power' -Id 42 -Time $t0 -Data ([ordered]@{ TargetState = '4' })
            New-FakeEvent -Provider 'Microsoft-Windows-Kernel-General' -Id 12 -Time $t0.AddHours(8)
            New-FakeEvent -Provider 'Microsoft-Windows-Kernel-Power' -Id 41 -Time $t0.AddHours(8).AddSeconds(5)
            New-FakeEvent -Provider 'Microsoft-Windows-Kernel-Power' -Id 42 -Time $t0.AddDays(1) -Data ([ordered]@{ TargetState = '5' })
            New-FakeEvent -Provider 'EventLog' -Id 6005 -Time $t0.AddDays(1).AddHours(1)
        )
        Mock Get-WHEvent { $events }
        $f = Test-WHSleepHistory -Since $t0.AddDays(-1)
        $f.Severity | Should -Be 'Critical'
        $f.Title | Should -Be '1 of 2 sleeps never woke up'
        $f.Evidence[0] | Should -Match 'S3 sleep -> never woke up; next event was a forced power-off'
    }
}

Describe 'Test-WHUpdates (mocked)' {
    It 'keeps Store app failures out of Windows Update failures' {
        Mock Test-Path { $false }
        Mock Get-WHRegistryValue { $null }
        $events = @(
            New-FakeEvent -Provider 'Microsoft-Windows-WindowsUpdateClient' -Id 20 -Time (Get-Date) -Data ([ordered]@{ errorCode = '0x80073d02'; updateTitle = '9NKSQGP7F2NH-5319275A.WhatsAppDesktop' })
        )
        Mock Get-WHEvent { $events }
        $f = @(Test-WHUpdates -Since (Get-Date).AddDays(-1))
        $f | Where-Object Id -EQ 'update-failures' | Should -BeNullOrEmpty
        ($f | Where-Object Id -EQ 'store-update-failures').Severity | Should -Be 'Info'
        ($f | Where-Object Id -EQ 'store-update-failures').FixIds.Count | Should -Be 0
    }
}

Describe 'Test-WHHardwareErrors (mocked)' {
    It 'is OK with no WHEA events' {
        Mock Get-WHEvent { @() }
        (Test-WHHardwareErrors -Since (Get-Date)).Severity | Should -Be 'OK'
    }
    It 'escalates fatal machine checks' {
        $msg = "A fatal hardware error has occurred.`r`n`r`nComponent: Processor Core`r`nError Source: Machine Check Exception"
        Mock Get-WHEvent { @(
                New-FakeEvent -Provider 'Microsoft-Windows-WHEA-Logger' -Id 19 -Time (Get-Date) -Message 'x'
                New-FakeEvent -Provider 'Microsoft-Windows-WHEA-Logger' -Id 18 -Time (Get-Date) -Message $msg
            ) }
        $f = Test-WHHardwareErrors -Since (Get-Date).AddDays(-1)
        $f.Severity | Should -Be 'Critical'
        ($f.Evidence -join ' ') | Should -Match 'Processor Core; Machine Check Exception'
    }
}

Describe 'storage error records (mocked)' {
    It 'tags each record with its drive and ignores other providers' {
        Mock Get-WHEvent { @(
                New-FakeEvent -Provider 'Microsoft-Windows-Ntfs' -Id 140 -Time (Get-Date) -Message "The system failed to flush data to the transaction log. Corruption may occur in VolumeId: E:, DeviceName: \Device\HarddiskVolume6.`r`n(A device which does not exist was specified.)"
                New-FakeEvent -Provider 'SomethingElse' -Id 7 -Time (Get-Date) -Message 'not storage'
            ) }
        $r = @(Get-WHStorageErrorRecord -Since (Get-Date).AddDays(-1))
        $r.Count | Should -Be 1
        $r[0].Volume | Should -Be 'E:'
        $r[0].Text | Should -Match '^The system failed to flush'
    }
}

Describe 'Test-WHNvmeDriver (mocked)' {
    BeforeAll {
        if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
            function global:Get-Service { param($Name, $ErrorAction) }
        }
    }
    It 'reports nothing when the standard driver is used' {
        Mock Get-WHNvmeOverride { }
        Mock Get-Service { $null }
        Test-WHNvmeDriver | Should -BeNullOrEmpty
    }
    It 'flags the experimental driver and when it was first used' {
        Mock Get-WHNvmeOverride { '735209102', '1853569164' }
        Mock Get-Service { [pscustomobject]@{ Name = 'nvmedisk'; Status = 'Running' } }
        Mock Get-WHEvent { @(
                New-FakeEvent -Provider 'Microsoft-Windows-Kernel-PnP' -Id 400 -Time ([datetime]'2026-10-14') -Message 'Driver Name: nvmedisk.inf'
                New-FakeEvent -Provider 'Microsoft-Windows-Kernel-PnP' -Id 400 -Time ([datetime]'2026-10-13 09:00') -Message 'Driver Name: nvmedisk.inf'
            ) }
        $f = Test-WHNvmeDriver
        $f.Severity | Should -Be 'Critical'
        $f.FixIds | Should -Be @('DisableExperimentalNvmeDriver')
        ($f.Evidence -join ' ') | Should -Match 'First seen in use: 2026-10-13 09:00'
    }
}

Describe 'Test-WHFixApplies' {
    It 'drops fixes that would change nothing and caches the answer' {
        $script:calls = 0
        $catalog = [ordered]@{
            Needed    = @{ Applies = { $script:calls++; $true } }
            NotNeeded = @{ Applies = { $false } }
            Always    = @{ }
            Broken    = @{ Applies = { throw 'boom' } }
        }
        $cache = @{}
        Test-WHFixApplies -Catalog $catalog -Id Needed -Cache $cache | Should -BeTrue
        Test-WHFixApplies -Catalog $catalog -Id Needed -Cache $cache | Should -BeTrue
        $script:calls | Should -Be 1
        Test-WHFixApplies -Catalog $catalog -Id NotNeeded -Cache $cache | Should -BeFalse
        Test-WHFixApplies -Catalog $catalog -Id Always -Cache $cache | Should -BeTrue
        Test-WHFixApplies -Catalog $catalog -Id Broken -Cache $cache | Should -BeTrue
        Test-WHFixApplies -Catalog $catalog -Id Missing -Cache $cache | Should -BeFalse
    }
    It 'does not offer turning off Fast Startup when it is already off' {
        Mock Get-WHRegistryValue { 0 }
        Test-WHFixApplies -Catalog (Get-WHFixCatalog) -Id DisableFastStartup -Cache @{} | Should -BeFalse
    }
}
