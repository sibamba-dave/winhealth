# Pure parsing / analysis functions. No system access here so they can be
# unit tested on any platform (see tests/).

function ConvertFrom-WHSleepStates {
    # Parses `powercfg /a`. Returns available state names and whether the
    # machine uses Modern Standby (S0 Low Power Idle) instead of classic S3.
    param([string[]]$Lines)
    $available = [System.Collections.Generic.List[string]]::new()
    $unavailable = [System.Collections.Generic.List[string]]::new()
    $section = $null
    foreach ($raw in $Lines) {
        $line = $raw.TrimEnd()
        if ($line -match '^\S.*are available') { $section = 'available'; continue }
        if ($line -match '^\S.*not available') { $section = 'unavailable'; continue }
        if ($line -match '^\s{4}(\S.*)$' -and $line -notmatch '^\s{8}') {
            $state = $Matches[1].Trim()
            if ($section -eq 'available') { $available.Add($state) }
            elseif ($section -eq 'unavailable') { $unavailable.Add($state) }
        }
    }
    [pscustomobject]@{
        Available      = @($available)
        Unavailable    = @($unavailable)
        ModernStandby  = [bool]($available | Where-Object { $_ -match 'S0 Low Power Idle' })
        S3             = [bool]($available | Where-Object { $_ -match '\(S3\)' })
        Hibernate      = [bool]($available | Where-Object { $_ -match '^Hibernate' })
        HybridSleep    = [bool]($available | Where-Object { $_ -match '^Hybrid Sleep' })
        FastStartup    = [bool]($available | Where-Object { $_ -match '^Fast Startup' })
    }
}

function ConvertFrom-WHPowerRequests {
    # Parses `powercfg /requests` into objects: Type (DISPLAY, SYSTEM, ...),
    # Kind (PROCESS, DRIVER, SERVICE, ...), Name and Reason.
    param([string[]]$Lines)
    $result = [System.Collections.Generic.List[object]]::new()
    $type = $null
    $current = $null
    foreach ($raw in $Lines) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line -match '^([A-Z]+):$') {
            $type = $Matches[1]; $current = $null; continue
        }
        if ($line -eq 'None.') { $current = $null; continue }
        if ($line -match '^\[([A-Z]+)\]\s*(.*)$') {
            $current = [pscustomobject]@{ Type = $type; Kind = $Matches[1]; Name = $Matches[2].Trim(); Reason = '' }
            $result.Add($current)
            continue
        }
        if ($current) {
            if ($current.Reason) { $current.Reason += ' ' }
            $current.Reason += $line
        }
    }
    @($result)
}

function ConvertFrom-WHDeviceList {
    # Parses `powercfg /devicequery wake_armed` (one device per line, or NONE).
    param([string[]]$Lines)
    @($Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'NONE' })
}

function ConvertFrom-WHWakeTimers {
    # Parses `powercfg /waketimers`. Each timer block starts with "Timer set by".
    param([string[]]$Lines)
    $result = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($raw in $Lines) {
        $line = $raw.Trim()
        if ($line -match '^Timer set by (.+?)(?: expires at (.+?))?\.?$') {
            $current = [pscustomobject]@{ Owner = $Matches[1].Trim(); Expires = "$($Matches[2])".Trim(); Reason = '' }
            $result.Add($current)
            continue
        }
        if ($current -and $line -match '^Reason:\s*(.*)$') { $current.Reason = $Matches[1].Trim() }
    }
    @($result)
}

function ConvertFrom-WHPowerSettingQuery {
    # Parses `powercfg /q SCHEME SUB SETTING` and returns AC/DC indexes as ints.
    param([string[]]$Lines)
    $ac = $null; $dc = $null
    foreach ($line in $Lines) {
        if ($line -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $ac = [Convert]::ToInt32($Matches[1], 16) }
        if ($line -match 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $dc = [Convert]::ToInt32($Matches[1], 16) }
    }
    [pscustomobject]@{ AC = $ac; DC = $dc }
}

function Find-WHIncompleteShutdown {
    # Walks a timeline of power events (oldest first) and reports each
    # shutdown/restart request that was never followed by a clean shutdown
    # before the next boot or power loss, i.e. a hung shutdown/restart that
    # needed the power button.
    #
    # Each input record: @{ Time = [datetime]; Kind = 'Requested'|'Clean'|'Dirty'|'Boot'; Detail = '...' }
    #   Requested - User32 1074 (someone asked for shutdown/restart)
    #   Clean     - EventLog 6006 / Kernel-General 13 (OS finished shutting down)
    #   Dirty     - Kernel-Power 41 / EventLog 6008 (unexpected power loss)
    #   Boot      - EventLog 6005 / Kernel-General 12 (system started)
    param([object[]]$Timeline)
    $result = [System.Collections.Generic.List[object]]::new()
    $pending = $null
    foreach ($e in ($Timeline | Sort-Object Time)) {
        switch ($e.Kind) {
            'Requested' { if (-not $pending) { $pending = $e } }
            'Clean' {
                if ($pending) {
                    $pending | Add-Member -NotePropertyName CleanAt -NotePropertyValue $e.Time -Force
                }
                $pending = $null
            }
            { $_ -eq 'Dirty' -or $_ -eq 'Boot' } {
                if ($pending -and -not $pending.PSObject.Properties['CleanAt']) {
                    $result.Add([pscustomobject]@{
                            RequestedAt = $pending.Time
                            Detail      = $pending.Detail
                            EndedBy     = $e.Kind
                            EndedAt     = $e.Time
                        })
                }
                $pending = $null
            }
        }
    }
    # Boot (6005/12) and power-loss (41/6008) events are written together at
    # startup in no fixed order; call it a forced power-off if one is nearby.
    $sorted = @($Timeline | Sort-Object Time)
    foreach ($r in $result) {
        $forced = $sorted | Where-Object { $_.Kind -eq 'Dirty' -and $_.Time -ge $r.EndedAt -and $_.Time -le $r.EndedAt.AddMinutes(5) }
        if ($forced) { $r.EndedBy = 'Dirty' }
    }
    @($result)
}

function Measure-WHShutdownDuration {
    # Pairs each shutdown request with the following clean OS shutdown and
    # returns the elapsed time. Long gaps mean something is holding shutdown up.
    param([object[]]$Timeline)
    $result = [System.Collections.Generic.List[object]]::new()
    $pending = $null
    foreach ($e in ($Timeline | Sort-Object Time)) {
        if ($e.Kind -eq 'Requested') {
            if (-not $pending) { $pending = $e }
        } elseif ($e.Kind -eq 'Clean') {
            if ($pending) {
                $result.Add([pscustomobject]@{
                        RequestedAt = $pending.Time
                        Detail      = $pending.Detail
                        Seconds     = [math]::Round(($e.Time - $pending.Time).TotalSeconds, 1)
                    })
            }
            $pending = $null
        } else {
            $pending = $null
        }
    }
    @($result)
}

function Get-WHDurationFromMessage {
    # Pulls "<Something> Duration : 12345ms" out of a Diagnostics-Performance
    # event message. Returns $null if not found.
    param([string]$Message, [string]$Label = 'Duration')
    if ($Message -match "$Label\s*:\s*(\d+)\s*ms") { return [double]$Matches[1] }
    $null
}

function Group-WHCulprit {
    # Aggregates culprit records (Name, DelayMs) into a ranked summary.
    param([object[]]$Records, [int]$Top = 10)
    $Records | Where-Object { $_.Name } | Group-Object Name | ForEach-Object {
        $delays = @($_.Group | ForEach-Object { [double]$_.DelayMs })
        [pscustomobject]@{
            Name    = $_.Name
            Count   = $_.Count
            TotalMs = ($delays | Measure-Object -Sum).Sum
            MaxMs   = ($delays | Measure-Object -Maximum).Maximum
        }
    } | Sort-Object @{ Expression = 'TotalMs'; Descending = $true }, @{ Expression = 'Count'; Descending = $true } | Select-Object -First $Top
}

function Test-WHStoreAppUpdate {
    # Microsoft Store app updates show up in WindowsUpdateClient events with a
    # 12-character Store product id prefix, e.g. "9NKSQGP7F2NH-5319275A.WhatsAppDesktop".
    # They have nothing to do with OS updates or restarts.
    param([string]$Title)
    $Title -match '^[0-9][A-Z0-9]{11}-'
}

function Get-WHVolumeFromMessage {
    # Pulls a drive letter out of a storage event message such as
    # "... Corruption may occur in VolumeId: E:, DeviceName: ..." or
    # "A corruption was discovered in the file system structure on volume E:."
    param([string]$Message)
    if ($Message -match '(?i)\bvolume(?:\s*id)?\s*:?\s*([A-Z]):') { return $Matches[1].ToUpper() + ':' }
    $null
}

function Find-WHSleepOutcome {
    # Pairs each "entering sleep" with what came next. A sleep followed by a
    # resume is fine; one followed by a boot or power loss never woke up.
    #
    # Each input record: @{ Time = [datetime]; Kind = 'Sleep'|'Resume'|'Boot'|'Dirty'; Detail = '...'; State = '4' }
    #   Sleep  - Kernel-Power 42 / 506 (entering sleep / Modern Standby); State = TargetState
    #   Resume - Kernel-Power 107 / 507, Power-Troubleshooter 1
    #   Boot   - EventLog 6005 / Kernel-General 12
    #   Dirty  - Kernel-Power 41 / EventLog 6008
    param([object[]]$Timeline)
    $sorted = @($Timeline | Sort-Object Time)
    $result = [System.Collections.Generic.List[object]]::new()
    $pending = $null
    $new = {
        param($p, $outcome, $endKind, $endTime)
        $state = if ($p.PSObject.Properties['State']) { "$($p.State)" } else { '' }
        [pscustomobject]@{ SleptAt = $p.Time; Detail = $p.Detail; State = $state; Outcome = $outcome; EndedBy = $endKind; EndedAt = $endTime }
    }
    foreach ($e in $sorted) {
        switch ($e.Kind) {
            'Sleep' { if (-not $pending) { $pending = $e } }
            'Resume' {
                if ($pending) { $result.Add((& $new $pending 'Resumed' 'Resume' $e.Time)) }
                $pending = $null
            }
            { $_ -eq 'Boot' -or $_ -eq 'Dirty' } {
                if ($pending) { $result.Add((& $new $pending 'NeverResumed' $e.Kind $e.Time)) }
                $pending = $null
            }
        }
    }
    if ($pending) {
        # Last sleep in the log with nothing after it: the PC is asleep or we are mid-resume.
        $result.Add((& $new $pending 'Unknown' $null $null))
    }
    # Boot and power-loss events are written together at startup in no fixed
    # order; call it a forced power-off if one is nearby.
    foreach ($r in $result) {
        if ($r.Outcome -ne 'NeverResumed') { continue }
        $forced = $sorted | Where-Object { $_.Kind -eq 'Dirty' -and $_.Time -ge $r.EndedAt -and $_.Time -le $r.EndedAt.AddMinutes(5) }
        if ($forced) { $r.EndedBy = 'Dirty' }
    }
    @($result)
}

function Get-WHSleepStateName {
    # Kernel-Power TargetState values (SYSTEM_POWER_STATE).
    param($State)
    switch ("$State") {
        '2' { 'S1 sleep' } '3' { 'S2 sleep' } '4' { 'S3 sleep' } '5' { 'hibernate' } '6' { 'shutdown' }
        default { if ("$State") { "state $State" } else { 'sleep' } }
    }
}

function Get-WHBugcheckInfo {
    # Plain-English meaning for common bugcheck codes, with a hint at the usual cause.
    param([string]$Code)
    $n = ConvertTo-WHInt $Code
    $known = @{
        0x0A  = @('IRQL_NOT_LESS_OR_EQUAL', 'a driver touched memory it should not; driver bug or unstable memory')
        0x19  = @('BAD_POOL_HEADER', 'kernel memory corrupted; driver bug or unstable memory')
        0x1A  = @('MEMORY_MANAGEMENT', 'memory corruption; test RAM and disable EXPO/XMP overclock')
        0x1E  = @('KMODE_EXCEPTION_NOT_HANDLED', 'a driver crashed')
        0x3B  = @('SYSTEM_SERVICE_EXCEPTION', 'a driver or system component crashed; often graphics or anti-cheat drivers')
        0x50  = @('PAGE_FAULT_IN_NONPAGED_AREA', 'bad memory access; driver bug, unstable RAM or disk')
        0x7A  = @('KERNEL_DATA_INPAGE_ERROR', 'Windows could not read data back from disk; failing disk, cable or storage driver')
        0x7E  = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 'a driver crashed')
        0x9F  = @('DRIVER_POWER_STATE_FAILURE', 'a driver did not handle sleep/wake/shutdown in time')
        0xA0  = @('INTERNAL_POWER_ERROR', 'power management failure, often during sleep or hibernate')
        0xC2  = @('BAD_POOL_CALLER', 'a driver misused kernel memory')
        0xD1  = @('DRIVER_IRQL_NOT_LESS_OR_EQUAL', 'a driver bug (network, storage and anti-cheat drivers are common)')
        0xEF  = @('CRITICAL_PROCESS_DIED', 'an essential Windows process died; often a disk dropping out, unstable RAM, or corrupted system files')
        0xF4  = @('CRITICAL_OBJECT_TERMINATION', 'an essential process ended; often the system disk dropping out')
        0x101 = @('CLOCK_WATCHDOG_TIMEOUT', 'a CPU core stopped responding; CPU overclock/undervolt (PBO, Curve Optimizer) or BIOS')
        0x116 = @('VIDEO_TDR_FAILURE', 'the graphics driver hung and could not recover')
        0x117 = @('VIDEO_TDR_TIMEOUT_DETECTED', 'the graphics driver hung')
        0x124 = @('WHEA_UNCORRECTABLE_ERROR', 'the hardware reported a fatal error; CPU/RAM overclock, voltages or failing hardware')
        0x133 = @('DPC_WATCHDOG_VIOLATION', 'a driver blocked the CPU too long; storage or chipset drivers, SSD firmware')
        0x139 = @('KERNEL_SECURITY_CHECK_FAILURE', 'kernel data corruption; driver bug or unstable memory')
        0x13A = @('KERNEL_MODE_HEAP_CORRUPTION', 'a driver corrupted kernel memory')
        0x154 = @('UNEXPECTED_STORE_EXCEPTION', 'memory compression store failed; disk or RAM problem')
        0x1CA = @('SYNTHETIC_WATCHDOG_TIMEOUT', 'the system stopped responding')
    }
    $hex = '0x{0:X}' -f $n
    if ($known.ContainsKey([int]$n)) {
        [pscustomobject]@{ Code = $hex; Name = $known[[int]$n][0]; Hint = $known[[int]$n][1] }
    } else {
        [pscustomobject]@{ Code = $hex; Name = ''; Hint = '' }
    }
}

function ConvertFrom-WHAnalyzeOutput {
    # Extracts the useful lines from a debugger's "!analyze -v" output.
    param([string[]]$Lines)
    $fields = [ordered]@{}
    foreach ($line in $Lines) {
        if ($line -match '^\s*(BUGCHECK_CODE|PROCESS_NAME|MODULE_NAME|IMAGE_NAME|FAILURE_BUCKET_ID|SYMBOL_NAME|CRITICAL_PROCESS):\s*(.+?)\s*$') {
            if (-not $fields.Contains($Matches[1])) { $fields[$Matches[1]] = $Matches[2] }
        }
    }
    [pscustomobject]@{
        Process  = $(if ($fields.Contains('CRITICAL_PROCESS')) { $fields['CRITICAL_PROCESS'] } else { $fields['PROCESS_NAME'] })
        Module   = $(if ($fields.Contains('IMAGE_NAME')) { $fields['IMAGE_NAME'] } else { $fields['MODULE_NAME'] })
        Bucket   = $fields['FAILURE_BUCKET_ID']
        Symbol   = $fields['SYMBOL_NAME']
    }
}

function Get-WHWheaInfo {
    # What each WHEA-Logger event id means for a home user.
    param([int]$Id)
    switch ($Id) {
        1 { @{ Severity = 'Critical'; Text = 'Fatal hardware error (reported after the reboot it caused)' } }
        18 { @{ Severity = 'Critical'; Text = 'Fatal machine-check error (CPU/memory/cache)' } }
        19 { @{ Severity = 'Warning'; Text = 'Corrected machine-check error (CPU/memory/cache)' } }
        17 { @{ Severity = 'Warning'; Text = 'Corrected PCI Express error (graphics card, NVMe or chipset link)' } }
        47 { @{ Severity = 'Warning'; Text = 'Corrected memory error' } }
        default { @{ Severity = 'Warning'; Text = "Hardware error event $Id" } }
    }
}
