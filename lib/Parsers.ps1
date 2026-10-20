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
