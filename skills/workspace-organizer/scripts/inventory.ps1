[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$OutFile,
    [int]$SampleChildren = 8
)

$ErrorActionPreference = 'Stop'

$rootFull = (Resolve-Path -LiteralPath $Root).Path
if (-not (Get-Item -LiteralPath $rootFull).PSIsContainer) {
    throw "Root is not a directory: $rootFull"
}

function Get-TreeStats([string]$Path) {
    $files = 0
    $bytes = [long]0
    try {
        $m = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum
        $files = [int]$m.Count
        if ($null -ne $m.Sum) { $bytes = [long]$m.Sum }
    } catch {
        # Keep partial stats; unreadable subtrees are reported through fileCount only.
    }
    [pscustomobject]@{ files = $files; bytes = $bytes }
}

$protectedNames = @('.git', '.svn', '.hg', '.dsh', '.agents', '.claude', '.cursor',
                    '.acl-recovery', 'node_modules', '.venv', 'venv', '__pycache__',
                    '.next', 'dist', 'build')

$items = New-Object System.Collections.ArrayList

foreach ($entry in (Get-ChildItem -LiteralPath $rootFull -Force | Sort-Object Name)) {
    $isDir = $entry.PSIsContainer

    if ($isDir) {
        $stats = Get-TreeStats $entry.FullName
    } else {
        $stats = [pscustomobject]@{ files = 1; bytes = [long]$entry.Length }
    }

    $children = ''
    if ($isDir) {
        $kids = Get-ChildItem -LiteralPath $entry.FullName -Force -ErrorAction SilentlyContinue |
            Select-Object -First $SampleChildren -ExpandProperty Name
        $children = ($kids -join ' | ')
    }

    $protected = $false
    if (($entry.Attributes.ToString()) -match 'Hidden|System') { $protected = $true }
    if ($protectedNames -contains $entry.Name) { $protected = $true }

    [void]$items.Add([pscustomobject]@{
        name      = $entry.Name
        type      = $(if ($isDir) { 'dir' } else { 'file' })
        extension = $(if ($isDir) { '' } else { $entry.Extension.ToLowerInvariant() })
        sizeBytes = $stats.bytes
        fileCount = $stats.files
        lastWrite = $entry.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        protected = $protected
        children  = $children
    })
}

$totalFiles = 0
$totalBytes = [long]0
foreach ($i in $items) {
    $totalFiles += $i.fileCount
    $totalBytes += $i.sizeBytes
}

$extensions = @(
    $items | Where-Object { $_.type -eq 'file' } |
        Group-Object extension |
        Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ extension = $_.Name; count = $_.Count } }
)

$result = [pscustomobject]@{
    root        = $rootFull
    generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    itemCount   = $items.Count
    totalFiles  = $totalFiles
    totalBytes  = $totalBytes
    extensions  = $extensions
    items       = @($items)
}

$json = $result | ConvertTo-Json -Depth 5

if ($OutFile) {
    $outFull = [IO.Path]::GetFullPath($OutFile)
    $parent = Split-Path -Parent $outFull
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json | Set-Content -LiteralPath $outFull -Encoding UTF8
    Write-Host ("Wrote {0} top-level items to {1}" -f $result.itemCount, $outFull)
}

$json
