[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PlanPath,
    [switch]$DryRun,
    [switch]$StopOnError,
    [string]$RecordDir
)

$ErrorActionPreference = 'Stop'

function Stop-Plan([string]$Message) {
    [Console]::Error.WriteLine('ERROR: ' + $Message)
    exit 1
}

$planFull = [IO.Path]::GetFullPath($PlanPath)
if (-not (Test-Path -LiteralPath $planFull)) { Stop-Plan "Plan not found: $PlanPath" }

$plan = Get-Content -LiteralPath $planFull -Raw -Encoding UTF8 | ConvertFrom-Json

if ($plan.root) {
    $r = [string]$plan.root
    if (-not [IO.Path]::IsPathRooted($r)) {
        $r = Join-Path (Split-Path -Parent $planFull) $r
    }
    $rootFull = [IO.Path]::GetFullPath($r)
} else {
    $rootFull = [IO.Path]::GetFullPath((Get-Location).Path)
}

if (-not (Test-Path -LiteralPath $rootFull)) { Stop-Plan "Root not found: $rootFull" }
if (-not (Get-Item -LiteralPath $rootFull).PSIsContainer) { Stop-Plan "Root is not a directory: $rootFull" }

$rootPrefix = $rootFull.TrimEnd('\') + '\'
$moves = @($plan.moves)
if ($moves.Count -eq 0) { Stop-Plan 'Plan contains no moves.' }

function Resolve-Rel([string]$Rel) {
    if ([string]::IsNullOrWhiteSpace($Rel)) { Stop-Plan 'Empty path in plan.' }
    if ([IO.Path]::IsPathRooted($Rel)) { Stop-Plan "Absolute paths are not allowed: $Rel" }

    $parts = $Rel -split '[\\/]'
    if ($parts -contains '..') { Stop-Plan "Parent traversal is not allowed: $Rel" }

    $full = [IO.Path]::GetFullPath((Join-Path $rootFull $Rel))
    if ($full -eq $rootFull) { Stop-Plan "Cannot move the root itself: $Rel" }
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Plan "Path escapes root: $Rel"
    }
    $full
}

$planned = New-Object System.Collections.ArrayList
$seenFrom = @{}
$seenTo = @{}
$seq = 0

foreach ($m in $moves) {
    $seq++
    $fromRel = [string]$m.from
    $toRel = [string]$m.to
    $from = Resolve-Rel $fromRel
    $to = Resolve-Rel $toRel

    if ($seenFrom.ContainsKey($from)) { Stop-Plan "Duplicate source: $fromRel" }
    if ($seenTo.ContainsKey($to)) { Stop-Plan "Duplicate destination: $toRel" }
    $seenFrom[$from] = $true
    $seenTo[$to] = $true

    if ($to.StartsWith($from + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Plan "Cannot move a directory into itself: $fromRel -> $toRel"
    }

    [void]$planned.Add([pscustomobject]@{
        seq     = $seq
        fromRel = $fromRel
        toRel   = $toRel
        from    = $from
        to      = $to
    })
}

# Reject plans where one source sits inside another source: the parent move would
# make the child path disappear before its own turn.
for ($i = 0; $i -lt $planned.Count; $i++) {
    for ($j = 0; $j -lt $planned.Count; $j++) {
        if ($i -eq $j) { continue }
        $child = $planned[$i].from
        $parent = $planned[$j].from
        if ($child.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Plan ("Source is nested inside another source: {0} is under {1}" -f $planned[$i].fromRel, $planned[$j].fromRel)
        }
    }
}

$preview = New-Object System.Collections.ArrayList
$counts = [ordered]@{ ready = 0; conflict = 0; missing = 0; already = 0 }

foreach ($p in $planned) {
    $fromExists = Test-Path -LiteralPath $p.from
    $toExists = Test-Path -LiteralPath $p.to
    if ($fromExists -and $toExists) { $status = 'conflict' }
    elseif ($fromExists) { $status = 'ready' }
    elseif ($toExists) { $status = 'already' }
    else { $status = 'missing' }

    $counts[$status] = $counts[$status] + 1

    [void]$preview.Add([pscustomobject]@{
        seq    = $p.seq
        status = $status
        from   = $p.fromRel
        to     = $p.toRel
    })
}

if ($DryRun) {
    [pscustomobject]@{
        dryRun = $true
        root   = $rootFull
        total  = $planned.Count
        counts = $counts
        items  = @($preview)
    } | ConvertTo-Json -Depth 4
    return
}

if (-not $RecordDir) {
    if ($plan.recordDir) { $RecordDir = [string]$plan.recordDir } else { $RecordDir = '.organize-record' }
}
if (-not [IO.Path]::IsPathRooted($RecordDir)) { $RecordDir = Join-Path $rootFull $RecordDir }
$RecordDir = [IO.Path]::GetFullPath($RecordDir)

$baseRunName = 'run-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$runDir = Join-Path $RecordDir $baseRunName
$suffix = 1
while (Test-Path -LiteralPath $runDir) {
    $runDir = Join-Path $RecordDir ($baseRunName + '-' + $suffix)
    $suffix++
}
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$results = New-Object System.Collections.ArrayList

foreach ($p in $planned) {
    $fromExists = Test-Path -LiteralPath $p.from
    $toExists = Test-Path -LiteralPath $p.to

    $kind = ''
    if ($fromExists) {
        $item = Get-Item -LiteralPath $p.from -Force
        if ($item.PSIsContainer) { $kind = 'dir' } else { $kind = 'file' }
    }

    $status = ''
    $errorText = ''

    if (-not $fromExists -and $toExists) {
        $status = 'already'
    } elseif (-not $fromExists) {
        $status = 'missing'
        $errorText = 'Source does not exist'
    } elseif ($toExists) {
        $status = 'conflict'
        $errorText = 'Destination already exists'
    } else {
        try {
            $parent = Split-Path -Parent $p.to
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Move-Item -LiteralPath $p.from -Destination $p.to -ErrorAction Stop
            $status = 'moved'
        } catch {
            $status = 'failed'
            $errorText = $_.Exception.Message
        }
    }

    [void]$results.Add([pscustomobject]@{
        seq    = $p.seq
        status = $status
        kind   = $kind
        from   = $p.fromRel
        to     = $p.toRel
        error  = $errorText
    })

    if ($StopOnError -and $status -in @('failed', 'conflict', 'missing')) { break }
}

$moved = 0; $failed = 0; $conflict = 0; $missing = 0; $already = 0
foreach ($r in $results) {
    switch ($r.status) {
        'moved'    { $moved++ }
        'failed'   { $failed++ }
        'conflict' { $conflict++ }
        'missing'  { $missing++ }
        'already'  { $already++ }
    }
}

$manifestPath = Join-Path $runDir 'manifest.csv'
$results | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8

$rollbackPath = Join-Path $runDir 'rollback.ps1'
$rollback = New-Object System.Collections.ArrayList
[void]$rollback.Add('# Generated by workspace-organizer. Undo the moves in reverse order.')
[void]$rollback.Add('$ErrorActionPreference = ''Stop''')
[void]$rollback.Add('$root = ' + "'" + ($rootFull -replace "'", "''") + "'")
for ($i = $results.Count - 1; $i -ge 0; $i--) {
    $r = $results[$i]
    if ($r.status -ne 'moved') { continue }
    $oldRel = ([string]$r.from) -replace "'", "''"
    $newRel = ([string]$r.to) -replace "'", "''"
    $line = "if ((Test-Path -LiteralPath (Join-Path `$root '$newRel')) -and -not (Test-Path -LiteralPath (Join-Path `$root '$oldRel'))) { Move-Item -LiteralPath (Join-Path `$root '$newRel') -Destination (Join-Path `$root '$oldRel') }"
    [void]$rollback.Add($line)
}
$rollback | Set-Content -LiteralPath $rollbackPath -Encoding UTF8

$summary = [pscustomobject]@{
    root      = $rootFull
    recordDir = $runDir
    manifest  = $manifestPath
    rollback  = $rollbackPath
    total     = $results.Count
    moved     = $moved
    failed    = $failed
    conflict  = $conflict
    missing   = $missing
    already   = $already
}

$summary | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $runDir 'summary.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 3

if (($failed + $conflict + $missing) -gt 0) { exit 1 }
