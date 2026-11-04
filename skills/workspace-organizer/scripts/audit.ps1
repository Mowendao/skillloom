[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Path,
    [string[]]$RootAllow = @('README.md', 'AGENTS.md', 'CLAUDE.md'),
    [string]$OutputDirName = '_output',
    [string]$InputDirName = '_input',
    [string]$ArchiveDirName = '_archive',
    [int]$StaleTempDays = 7,
    [int]$MaxDepth = 8
)

$ErrorActionPreference = 'Stop'

$rootFull = (Resolve-Path -LiteralPath $Root).Path
$rootPrefix = $rootFull.TrimEnd('\') + '\'

if ($Path) {
    $scanFull = (Resolve-Path -LiteralPath $Path).Path
} else {
    $scanFull = $rootFull
}
if (-not $scanFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and $scanFull -ne $rootFull) {
    throw "Path is outside the workspace root: $scanFull"
}

$protectedNames = @('.git', '.svn', '.hg', '.dsh', '.dsh-im', '.agents', '.claude', '.cursor',
                    '.acl-recovery', 'node_modules', '.venv', 'venv', '__pycache__',
                    '.next', 'dist', 'build', '.npm-cache')

function Test-Protected([string]$FullPath) {
    if (-not $FullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $rel = $FullPath.Substring($rootPrefix.Length)
    foreach ($s in ($rel -split '[\\/]')) {
        if ($protectedNames -contains $s) { return $true }
    }
    return $false
}

function Get-Relative([string]$FullPath) {
    if ($FullPath -eq $rootFull) { return '.' }
    $FullPath.Substring($rootPrefix.Length)
}

$violations = New-Object System.Collections.ArrayList
$stats = [ordered]@{
    rootFiles = 0
    rootDirs = 0
    scannedFiles = 0
    scannedDirs = 0
    emptyDirs = 0
}

$topEntries = @(Get-ChildItem -LiteralPath $rootFull -Force | Sort-Object Name)
$topDirs = @($topEntries | Where-Object { $_.PSIsContainer })
$topFiles = @($topEntries | Where-Object { -not $_.PSIsContainer })
$stats.rootFiles = $topFiles.Count
$stats.rootDirs = $topDirs.Count

$misc = $topDirs | Where-Object { $_.Name -match '^99_' } | Select-Object -First 1
if (-not $misc) { $misc = $null }

if ($scanFull -eq $rootFull) {
    foreach ($f in $topFiles) {
        if ($RootAllow -contains $f.Name) { continue }
        [void]$violations.Add([pscustomobject]@{
            code      = 'root-file'
            path      = $f.Name
            message   = 'Loose file in workspace root.'
            suggested = $(if ($misc) { Join-Path $misc.Name $f.Name } else { '' })
        })
    }

    foreach ($d in $topDirs) {
        if (Test-Protected $d.FullName) { continue }
        if ($d.Name -match '^\d{2}_' -or $d.Name -match '^99_') { continue }
        [void]$violations.Add([pscustomobject]@{
            code      = 'top-dir-name'
            path      = $d.Name
            message   = 'Top-level directory must be numbered as NN_<topic> or 99_<misc>.'
            suggested = 'NN_' + $d.Name
        })
    }
}

$outputPattern = '^\d{4}-\d{2}-\d{2}_.+_v\d+$'
$strayNames = @('*.tmp', '*.temp', '~$*', '*.crdownload', '*.part', '*.partial', '.DS_Store', 'Thumbs.db', 'desktop.ini')
$roleDirNames = @($OutputDirName, $InputDirName, $ArchiveDirName)

$queue = New-Object System.Collections.Queue
$queue.Enqueue([pscustomobject]@{ Path = $scanFull; Depth = 0 })

while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    $children = @(Get-ChildItem -LiteralPath $current.Path -Force -ErrorAction SilentlyContinue)

    if ($children.Count -eq 0 -and $current.Path -ne $scanFull) {
        $leaf = Split-Path -Leaf $current.Path
        if (($roleDirNames -notcontains $leaf) -and ($leaf -ne 'tmp')) {
            $stats.emptyDirs++
            [void]$violations.Add([pscustomobject]@{
                code      = 'empty-dir'
                path      = (Get-Relative $current.Path)
                message   = 'Empty directory.'
                suggested = $(if ($misc) { Join-Path $misc.Name 'archive' } else { '' })
            })
        }
    }

    foreach ($child in $children) {
        if ($child.PSIsContainer) {
            if (Test-Protected $child.FullName) { continue }
            $stats.scannedDirs++
            if ($current.Depth -lt $MaxDepth) {
                $queue.Enqueue([pscustomobject]@{ Path = $child.FullName; Depth = $current.Depth + 1 })
            }
            continue
        }

        if (Test-Protected $child.FullName) { continue }
        $stats.scannedFiles++

        $rel = Get-Relative $child.FullName
        $base = [IO.Path]::GetFileNameWithoutExtension($child.Name)
        $segments = @($rel -split '[\\/]')

        if ($segments -contains $OutputDirName) {
            if ($base -notmatch $outputPattern) {
                [void]$violations.Add([pscustomobject]@{
                    code      = 'output-name'
                    path      = $rel
                    message   = 'Output file name must match YYYY-MM-DD_<topic>_<description>_v<N>.'
                    suggested = ''
                })
            }
        }

        foreach ($pattern in $strayNames) {
            if ($child.Name -like $pattern) {
                [void]$violations.Add([pscustomobject]@{
                    code      = 'stray-temp'
                    path      = $rel
                    message   = 'Temporary or OS junk file.'
                    suggested = $(if ($misc) { Join-Path $misc.Name 'archive' } else { '' })
                })
                break
            }
        }
    }
}

if ($misc) {
    $tmpDir = Join-Path $misc.FullName 'tmp'
    if (Test-Path -LiteralPath $tmpDir) {
        $cutoff = (Get-Date).AddDays(-$StaleTempDays)
        foreach ($f in (Get-ChildItem -LiteralPath $tmpDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            if ($f.LastWriteTime -lt $cutoff) {
                [void]$violations.Add([pscustomobject]@{
                    code      = 'stale-tmp'
                    path      = (Get-Relative $f.FullName)
                    message   = "Temp file older than $StaleTempDays days."
                    suggested = ''
                })
            }
        }
    }
}

$result = [pscustomobject]@{
    root       = $rootFull
    scanned    = $scanFull
    ok         = ($violations.Count -eq 0)
    violations = @($violations)
    stats      = [pscustomobject]$stats
}

$result | ConvertTo-Json -Depth 5

if ($violations.Count -gt 0) { exit 1 }
