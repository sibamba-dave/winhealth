<#
.SYNOPSIS
    Diagnoses (and optionally fixes) Windows shutdown, restart, sleep and wake problems.

.DESCRIPTION
    Reads event logs, power configuration and system state to find out why
    Windows hangs on shutdown/restart or is slow to come out of sleep.
    Writes an HTML + JSON report and, if you choose, applies targeted fixes.
    Analysis never changes anything; fixes run only when you pick them.

.PARAMETER Days
    How far back to look in the event logs. Default 30.

.PARAMETER OutputPath
    Folder for the report. Default: .\reports\<timestamp> next to this script.

.PARAMETER Fix
    Fix ids to apply after analysis (comma separated), or "Recommended" for
    every fix suggested by the findings. See -ListFixes.

.PARAMETER Yes
    Do not ask before each fix (for -Fix). Wake-capable keyboards are kept.

.PARAMETER NoRestorePoint
    Skip creating a System Restore point before fixes.

.PARAMETER NoPrompt
    Do not show the interactive fix menu after analysis.

.PARAMETER NoOpen
    Do not open the HTML report in the browser.

.PARAMETER ListFixes
    List available fixes and exit.

.EXAMPLE
    .\WinHealth.ps1
    Analyse, open the report, then offer fixes.

.EXAMPLE
    .\WinHealth.ps1 -Fix DisableFastStartup,DisableWakeTimers

.EXAMPLE
    .\WinHealth.ps1 -Fix Recommended -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(1, 365)][int]$Days = 30,
    [string]$OutputPath,
    [string[]]$Fix,
    [switch]$Yes,
    [switch]$NoRestorePoint,
    [switch]$NoPrompt,
    [switch]$NoOpen,
    [switch]$ListFixes,
    [Parameter(DontShow)][switch]$PauseAtEnd
)

$ErrorActionPreference = 'Stop'

foreach ($lib in 'Common', 'Parsers', 'Checks', 'Fixes', 'Report') {
    . (Join-Path $PSScriptRoot "lib\$lib.ps1")
}

function Exit-WinHealth {
    param([int]$Code = 0)
    if ($PauseAtEnd) { Read-Host 'Press Enter to close' | Out-Null }
    exit $Code
}

if ($ListFixes) {
    $catalog = Get-WHFixCatalog
    foreach ($id in $catalog.Keys) {
        Write-Host $id -ForegroundColor Cyan -NoNewline
        Write-Host " - $($catalog[$id].Title)"
        Write-Host "    $($catalog[$id].Why)" -ForegroundColor Gray
    }
    return
}

if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    Write-Error 'WinHealth only runs on Windows.'
    return
}

if (-not (Test-WHAdmin)) {
    # Event logs (Security-adjacent, Diagnostics-Performance), powercfg
    # /requests and every fix need admin rights. Relaunch elevated.
    Write-Host 'Administrator rights are needed; asking Windows to elevate...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-PauseAtEnd')
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Key -eq 'PauseAtEnd') { continue }
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" }
        } elseif ($kv.Value -is [array]) {
            $argList += "-$($kv.Key)"; $argList += ($kv.Value -join ',')
        } else {
            $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`""
        }
    }
    $exe = (Get-Process -Id $PID).Path
    try {
        Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs
    } catch {
        Write-Error 'Elevation was cancelled. Right-click PowerShell and choose "Run as administrator", then run WinHealth again.'
    }
    return
}

# -Fix accepts "A,B" as one string from cmd.exe / elevation relaunch.
$fixIds = @()
if ($Fix) { $fixIds = @($Fix | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot ("reports\" + (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
}
$null = New-Item -ItemType Directory -Path $OutputPath -Force
$OutputPath = (Resolve-Path $OutputPath).Path

Write-Host 'Analysing... (this takes about a minute)' -ForegroundColor Cyan
$result = Invoke-WHAllChecks -Days $Days -OutputPath $OutputPath

$htmlPath = Join-Path $OutputPath 'report.html'
$jsonPath = Join-Path $OutputPath 'report.json'
Export-WHHtmlReport -Result $result -Path $htmlPath
Export-WHJsonReport -Result $result -Path $jsonPath
Write-WHSummary -Result $result
Write-Host ''
Write-Host "Full report: $htmlPath" -ForegroundColor Cyan
if (-not $NoOpen) {
    try { Start-Process $htmlPath } catch { Write-Warning "Could not open the report: $($_.Exception.Message)" }
}

$recommended = Get-WHRecommendedFix $result.Findings
$catalog = Get-WHFixCatalog

if ($fixIds -contains 'Recommended') {
    $fixIds = @(@($fixIds | Where-Object { $_ -ne 'Recommended' }) + @($recommended) | Select-Object -Unique)
    if (-not $fixIds) { Write-Host 'No fixes are recommended for the problems found.' -ForegroundColor Green }
}

if (-not $fixIds -and -not $NoPrompt -and $recommended.Count -and [Environment]::UserInteractive) {
    Write-Host ''
    Write-Host 'Recommended fixes:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $recommended.Count; $i++) {
        $fx = $catalog[$recommended[$i]]
        Write-Host ("  {0}. {1}" -f ($i + 1), $fx.Title)
        Write-Host "     $($fx.Why)" -ForegroundColor Gray
    }
    Write-Host ''
    $answer = Read-Host 'Apply which? Numbers like 1,3 - "a" for all - Enter to skip'
    if ($answer -match '^\s*a(ll)?\s*$') {
        $fixIds = $recommended
    } elseif ($answer -match '\d') {
        $fixIds = @($answer -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object {
                $n = [int]$_
                if ($n -ge 1 -and $n -le $recommended.Count) { $recommended[$n - 1] }
            } | Select-Object -Unique)
    }
}

if ($fixIds) {
    $logPath = Join-Path $OutputPath 'fixes.json'
    $null = Invoke-WHFix -FixId $fixIds -Unattended:$Yes -NoRestorePoint:$NoRestorePoint -LogPath $logPath -WhatIf:$WhatIfPreference
}

Exit-WinHealth 0
