[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [Parameter(Mandatory = $true)][string]$ManifestCsv,
    [string[]]$IgnoreTopLevel = @()
)

$ErrorActionPreference = 'Stop'

$rootFull = (Resolve-Path -LiteralPath $Root).Path
if (-not (Test-Path -LiteralPath $ManifestCsv)) { throw "Manifest not found: $ManifestCsv" }

$rows = @(Import-Csv -LiteralPath $ManifestCsv)

$missingDst = New-Object System.Collections.ArrayList
$leftSrc = New-Object System.Collections.ArrayList
$expected = @{}

foreach ($r in $rows) {
    if ($r.status -ne 'moved') { continue }

    $dst = Join-Path $rootFull ([string]$r.to)
    $src = Join-Path $rootFull ([string]$r.from)

    if (-not (Test-Path -LiteralPath $dst)) { [void]$missingDst.Add([string]$r.to) }
    if (Test-Path -LiteralPath $src) { [void]$leftSrc.Add([string]$r.from) }

    $first = ([string]$r.to -split '[\\/]')[0]
    if ($first) { $expected[$first] = $true }
}

$nested = New-Object System.Collections.ArrayList
$dirs = Get-ChildItem -LiteralPath $rootFull -Directory -Recurse -Force -ErrorAction SilentlyContinue
foreach ($d in $dirs) {
    if ($d.Parent -and $d.Name -eq $d.Parent.Name) {
        $rel = $d.FullName.Substring($rootFull.Length).TrimStart('\')
        [void]$nested.Add($rel)
    }
}

$protectedNames = @('.git', '.svn', '.hg', '.dsh', '.agents', '.claude', '.cursor',
                    '.acl-recovery', 'node_modules', '.venv', 'venv', '__pycache__',
                    '.next', 'dist', 'build', '.organize-record')
$unreferenced = New-Object System.Collections.ArrayList

foreach ($entry in (Get-ChildItem -LiteralPath $rootFull -Force | Sort-Object Name)) {
    if ($protectedNames -contains $entry.Name) { continue }
    if ($IgnoreTopLevel -contains $entry.Name) { continue }
    if ($expected.ContainsKey($entry.Name)) { continue }
    [void]$unreferenced.Add($entry.Name)
}

$ok = ($missingDst.Count -eq 0 -and $leftSrc.Count -eq 0)

$result = [pscustomobject]@{
    root              = $rootFull
    manifest          = (Resolve-Path -LiteralPath $ManifestCsv).Path
    checkedMoves      = @($rows | Where-Object { $_.status -eq 'moved' }).Count
    ok                = $ok
    missingDestinations = @($missingDst)
    leftoverSources     = @($leftSrc)
    nestedSameNameDirs  = @($nested)
    unreferencedTopLevel = @($unreferenced)
}

$result | ConvertTo-Json -Depth 4

if (-not $ok) { exit 1 }
