# Shared helpers: findings, event log access, small parsers.
# Everything here must stay compatible with Windows PowerShell 5.1.

$script:SeverityOrder = @{ Critical = 0; Warning = 1; Info = 2; OK = 3 }

function New-WHFinding {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Shutdown', 'Sleep', 'Updates', 'Stability', 'Storage', 'System')][string]$Category,
        [Parameter(Mandatory)][ValidateSet('Critical', 'Warning', 'Info', 'OK')][string]$Severity,
        [Parameter(Mandatory)][string]$Title,
        [string]$Detail = '',
        [string[]]$Evidence = @(),
        [string[]]$FixIds = @()
    )
    [pscustomobject]@{
        Id       = $Id
        Category = $Category
        Severity = $Severity
        Title    = $Title
        Detail   = $Detail
        Evidence = @($Evidence | Where-Object { $_ })
        FixIds   = @($FixIds | Where-Object { $_ })
    }
}

function Get-WHEvent {
    # Get-WinEvent wrapper that returns an empty array instead of throwing
    # when nothing matches or the log does not exist on this machine.
    param(
        [Parameter(Mandatory)][hashtable]$Filter,
        [int]$MaxEvents = 500
    )
    try {
        @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $MaxEvents -ErrorAction Stop)
    } catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound|NoMatchingLogsFound|NoMatchingProvidersFound') {
            @()
        } elseif ($_.Exception.Message -match 'No events were found|There is not an event log') {
            @()
        } else {
            throw
        }
    }
}

function Get-WHEventDataMap {
    # Flattens an event's EventData/UserData into an ordered name->value map.
    # Unnamed <Data> elements are keyed Param0, Param1, ...
    param([Parameter(Mandatory)]$EventRecord)
    $map = [ordered]@{}
    $xml = [xml]$EventRecord.ToXml()
    $nodes = @()
    foreach ($section in $xml.DocumentElement.ChildNodes) {
        if ($section.LocalName -eq 'EventData') {
            $nodes = $section.ChildNodes
        } elseif ($section.LocalName -eq 'UserData' -and $section.FirstChild) {
            $nodes = $section.FirstChild.ChildNodes
        }
    }
    $i = 0
    foreach ($n in $nodes) {
        if ($n.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        $name = $n.GetAttribute('Name')
        if (-not $name) {
            if ($n.LocalName -ne 'Data') { $name = $n.LocalName } else { $name = "Param$i" }
        }
        $map[$name] = $n.InnerText
        $i++
    }
    $map
}

function Get-WHMapValue {
    # Returns the first non-empty value among the given keys.
    param($Map, [string[]]$Keys)
    foreach ($k in $Keys) {
        if ($Map.Contains($k) -and "$($Map[$k])" -ne '') { return $Map[$k] }
    }
    $null
}

function Invoke-WHNative {
    # Runs a native command and returns its output lines (stdout + stderr).
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    # Windows PowerShell 5.1 turns redirected stderr into terminating errors
    # when ErrorActionPreference is Stop.
    $ErrorActionPreference = 'Continue'
    $out = & $FilePath @ArgumentList 2>&1
    @($out | ForEach-Object { "$_" })
}

function ConvertTo-WHInt {
    # Lenient integer parse for event data (handles "", "true"/"false", hex).
    param($Value)
    $s = "$Value".Trim()
    if ($s -eq '' -or $s -eq 'false') { return [int64]0 }
    if ($s -eq 'true') { return [int64]1 }
    $n = [int64]0
    if ($s -match '^0x([0-9a-fA-F]+)$') { return [Convert]::ToInt64($Matches[1], 16) }
    if ([int64]::TryParse($s, [ref]$n)) { return $n }
    [int64]0
}

function Format-WHDuration {
    param([double]$Milliseconds)
    if ($Milliseconds -ge 60000) { return ('{0:N1} min' -f ($Milliseconds / 60000)) }
    if ($Milliseconds -ge 1000) { return ('{0:N1} s' -f ($Milliseconds / 1000)) }
    '{0:N0} ms' -f $Milliseconds
}

function Format-WHTime {
    param([datetime]$Time)
    $Time.ToString('yyyy-MM-dd HH:mm:ss')
}

function Get-WHRegistryValue {
    param([string]$Path, [string]$Name)
    try {
        (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
    } catch {
        $null
    }
}

function Test-WHAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WHSortedFinding {
    param([object[]]$Finding)
    $Finding | Sort-Object @{ Expression = { $script:SeverityOrder[$_.Severity] } }, Category, Title
}
