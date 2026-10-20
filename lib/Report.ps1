# Console summary and self-contained HTML report.

function ConvertTo-WHHtmlText {
    param([string]$Text)
    [System.Net.WebUtility]::HtmlEncode($Text)
}

function Get-WHRecommendedFix {
    # Unique fix ids referenced by Critical/Warning findings, most urgent first.
    param([object[]]$Findings)
    $seen = [System.Collections.Generic.List[string]]::new()
    foreach ($f in (Get-WHSortedFinding ($Findings | Where-Object { $_.Severity -in 'Critical', 'Warning' }))) {
        foreach ($id in $f.FixIds) { if (-not $seen.Contains($id)) { $seen.Add($id) } }
    }
    @($seen)
}

function Write-WHSummary {
    param($Result)
    $colors = @{ Critical = 'Red'; Warning = 'Yellow'; Info = 'Gray'; OK = 'Green' }
    $si = $Result.SystemInfo
    Write-Host ''
    Write-Host "WinHealth report for $($si.ComputerName) - $($si.Model)" -ForegroundColor Cyan
    Write-Host "$($si.OS); last boot $(Format-WHTime $si.LastBoot); looked back $($Result.Days) days"
    Write-Host ''
    foreach ($f in $Result.Findings) {
        if ($f.Severity -eq 'Info') { continue }
        $tag = ('[{0}]' -f $f.Severity.ToUpper()).PadRight(11)
        Write-Host $tag -ForegroundColor $colors[$f.Severity] -NoNewline
        Write-Host " $($f.Category.PadRight(9)) $($f.Title)"
    }
    $counts = $Result.Findings | Group-Object Severity | ForEach-Object { "$($_.Count) $($_.Name)" }
    Write-Host ''
    Write-Host "Summary: $($counts -join ', ')"
}

function Export-WHHtmlReport {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Path)
    $catalog = Get-WHFixCatalog
    $si = $Result.SystemInfo
    $recommended = Get-WHRecommendedFix $Result.Findings
    $count = @{}
    foreach ($s in 'Critical', 'Warning', 'Info', 'OK') { $count[$s] = @($Result.Findings | Where-Object { $_.Severity -eq $s }).Count }

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append(@"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WinHealth - $(ConvertTo-WHHtmlText $si.ComputerName)</title>
<style>
:root { --bg:#f6f7f9; --card:#fff; --text:#1d2330; --muted:#5d6675; --line:#e2e5ea;
  --crit:#c62828; --warn:#b26a00; --info:#3b6bb5; --ok:#2e7d32; --code:#eef1f5; }
@media (prefers-color-scheme: dark) { :root { --bg:#14171c; --card:#1c2027; --text:#e6e9ee; --muted:#9aa3b2;
  --line:#2c323c; --crit:#ef6b6b; --warn:#f0b54a; --info:#7aa7f0; --ok:#6cc070; --code:#262b34; } }
* { box-sizing:border-box }
body { margin:0; background:var(--bg); color:var(--text); font:15px/1.5 "Segoe UI",system-ui,sans-serif }
main { max-width:980px; margin:0 auto; padding:24px 16px 64px }
h1 { font-size:24px; margin:0 0 4px } h2 { font-size:18px; margin:32px 0 12px }
.muted { color:var(--muted) }
.meta { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:4px 24px; margin:16px 0;
  background:var(--card); border:1px solid var(--line); border-radius:10px; padding:14px 16px }
.meta b { display:block; font-size:12px; color:var(--muted); font-weight:600; text-transform:uppercase; letter-spacing:.04em }
.tiles { display:flex; gap:12px; flex-wrap:wrap }
.tile { flex:1 1 120px; background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px 16px }
.tile .n { font-size:28px; font-weight:700 } .tile.Critical .n{color:var(--crit)} .tile.Warning .n{color:var(--warn)} .tile.OK .n{color:var(--ok)} .tile.Info .n{color:var(--info)}
.finding { background:var(--card); border:1px solid var(--line); border-left:4px solid var(--info); border-radius:10px; padding:12px 16px; margin:10px 0 }
.finding.Critical{border-left-color:var(--crit)} .finding.Warning{border-left-color:var(--warn)} .finding.OK{border-left-color:var(--ok)}
.finding h3 { font-size:16px; margin:0 0 4px; display:flex; gap:8px; align-items:baseline; flex-wrap:wrap }
.badge { font-size:11px; font-weight:700; padding:2px 8px; border-radius:99px; color:#fff; background:var(--info); text-transform:uppercase; letter-spacing:.04em }
.badge.Critical{background:var(--crit)} .badge.Warning{background:var(--warn)} .badge.OK{background:var(--ok)}
.cat { font-size:12px; color:var(--muted) }
details { margin-top:6px } summary { cursor:pointer; color:var(--muted); font-size:13px }
ul.ev { margin:6px 0 0; padding-left:18px; font-size:13px; font-family:Consolas,ui-monospace,monospace; overflow-wrap:anywhere }
code { background:var(--code); padding:1px 6px; border-radius:4px; font-family:Consolas,ui-monospace,monospace; font-size:13px; overflow-wrap:anywhere }
.fix { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px 16px; margin:10px 0 }
.fix h3 { font-size:15px; margin:0 0 4px } .fixes-inline { font-size:13px; margin-top:6px }
</style>
</head>
<body><main>
<h1>WinHealth report</h1>
<div class="muted">Generated $(Format-WHTime $si.GeneratedAt) &middot; looked back $($Result.Days) days</div>
<div class="meta">
  <div><b>Computer</b>$(ConvertTo-WHHtmlText $si.ComputerName)</div>
  <div><b>Model</b>$(ConvertTo-WHHtmlText $si.Model)</div>
  <div><b>Windows</b>$(ConvertTo-WHHtmlText $si.OS)</div>
  <div><b>BIOS</b>$(ConvertTo-WHHtmlText $si.BIOS)</div>
  <div><b>Last boot</b>$(Format-WHTime $si.LastBoot) ($([int]$si.Uptime.TotalDays)d $($si.Uptime.Hours)h ago)</div>
  <div><b>Memory</b>$($si.MemoryGB) GB</div>
</div>
<div class="tiles">
  <div class="tile Critical"><div class="n">$($count.Critical)</div>Critical</div>
  <div class="tile Warning"><div class="n">$($count.Warning)</div>Warnings</div>
  <div class="tile Info"><div class="n">$($count.Info)</div>Info</div>
  <div class="tile OK"><div class="n">$($count.OK)</div>OK</div>
</div>
"@)

    if ($recommended.Count) {
        $null = $sb.Append('<h2>Recommended fixes</h2><p class="muted">Run from an administrator PowerShell in the WinHealth folder. A restore point is created first.</p>')
        foreach ($id in $recommended) {
            $fx = $catalog[$id]
            $null = $sb.Append("<div class=""fix""><h3>$(ConvertTo-WHHtmlText $fx.Title)</h3><div>$(ConvertTo-WHHtmlText $fx.Why)</div>")
            $null = $sb.Append("<div class=""fixes-inline""><code>.\WinHealth.ps1 -Fix $id</code></div>")
            $null = $sb.Append("<details><summary>How to undo</summary><div class=""fixes-inline"">$(ConvertTo-WHHtmlText $fx.Undo)</div></details></div>")
        }
        $null = $sb.Append("<p class=""fixes-inline"">All of the above: <code>.\WinHealth.ps1 -Fix $($recommended -join ',')</code></p>")
    }

    $categories = [ordered]@{ Shutdown = 'Shutdown &amp; restart'; Sleep = 'Sleep &amp; wake'; Updates = 'Windows Update'; Stability = 'Crashes &amp; drivers'; Storage = 'Storage'; System = 'System' }
    foreach ($cat in $categories.Keys) {
        $items = @($Result.Findings | Where-Object { $_.Category -eq $cat })
        if (-not $items.Count) { continue }
        $null = $sb.Append("<h2>$($categories[$cat])</h2>")
        foreach ($f in $items) {
            $null = $sb.Append("<div class=""finding $($f.Severity)""><h3><span class=""badge $($f.Severity)"">$($f.Severity)</span>$(ConvertTo-WHHtmlText $f.Title)</h3>")
            if ($f.Detail) { $null = $sb.Append("<div>$(ConvertTo-WHHtmlText $f.Detail)</div>") }
            if ($f.FixIds.Count) {
                $names = ($f.FixIds | ForEach-Object { "<code>$_</code>" }) -join ' '
                $null = $sb.Append("<div class=""fixes-inline"">Possible fixes: $names</div>")
            }
            if ($f.Evidence.Count) {
                $open = if ($f.Severity -in 'Critical', 'Warning') { ' open' } else { '' }
                $null = $sb.Append("<details$open><summary>Evidence ($($f.Evidence.Count))</summary><ul class=""ev"">")
                foreach ($e in $f.Evidence) { $null = $sb.Append("<li>$(ConvertTo-WHHtmlText $e)</li>") }
                $null = $sb.Append('</ul></details>')
            }
            $null = $sb.Append('</div>')
        }
    }

    $null = $sb.Append('<h2>All available fixes</h2>')
    foreach ($id in $catalog.Keys) {
        $fx = $catalog[$id]
        $null = $sb.Append("<div class=""fix""><h3>$(ConvertTo-WHHtmlText $fx.Title) <code>$id</code></h3><div>$(ConvertTo-WHHtmlText $fx.Why)</div></div>")
    }
    $null = $sb.Append('</main></body></html>')
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
}

function Export-WHJsonReport {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Path)
    $si = $Result.SystemInfo
    [pscustomobject]@{
        SystemInfo = [pscustomobject]@{
            ComputerName = $si.ComputerName; OS = $si.OS; Model = $si.Model; BIOS = $si.BIOS
            LastBoot = (Format-WHTime $si.LastBoot); UptimeDays = [math]::Round($si.Uptime.TotalDays, 1)
            MemoryGB = $si.MemoryGB; GeneratedAt = (Format-WHTime $si.GeneratedAt)
        }
        Days       = $Result.Days
        Findings   = $Result.Findings
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8 -WhatIf:$false
}
