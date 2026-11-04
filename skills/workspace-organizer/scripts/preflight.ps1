[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [Parameter(Mandatory = $true)][string]$Target,
    [ValidateSet('output', 'input', 'archive', 'temp', 'project')][string]$Kind = 'output',
    [string]$Source,
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [string]$OutputDirName = '_output',
    [string]$InputDirName = '_input',
    [string]$ArchiveDirName = '_archive',
    [string]$TempDirName = 'tmp'
)

$ErrorActionPreference = 'Stop'

$rootFull = (Resolve-Path -LiteralPath $Root).Path
$rootPrefix = $rootFull.TrimEnd('\') + '\'

if ([IO.Path]::IsPathRooted($Target)) {
    $targetFull = [IO.Path]::GetFullPath($Target)
} else {
    $targetFull = [IO.Path]::GetFullPath((Join-Path $rootFull $Target))
}

$blockers = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList
$messages = New-Object System.Collections.ArrayList

function Add-Blocker([string]$Code, [string]$Text) {
    [void]$blockers.Add([pscustomobject]@{ code = $Code; message = $Text })
    [void]$messages.Add($Text)
}

function Add-Warning([string]$Code, [string]$Text) {
    [void]$warnings.Add([pscustomobject]@{ code = $Code; message = $Text })
}

$protectedNames = @('.git', '.svn', '.hg', '.dsh', '.dsh-im', '.agents', '.claude', '.cursor',
                    '.acl-recovery', 'node_modules', '.venv', 'venv', '__pycache__',
                    '.next', 'dist', 'build', '.npm-cache')

if (-not $targetFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    Add-Blocker 'outside-root' "Target is outside the workspace root: $targetFull"
}
if ($targetFull -eq $rootFull) {
    Add-Blocker 'is-root' 'Target is the workspace root itself.'
}

$relative = ''
if ($targetFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    $relative = $targetFull.Substring($rootPrefix.Length)
}
$segments = @($relative -split '[\\/]' | Where-Object { $_ -ne '' })

foreach ($s in $segments) {
    if ($protectedNames -contains $s) {
        Add-Blocker 'protected-dir' "Target is inside a protected directory: $s"
    }
}

$fileName = Split-Path -Leaf $targetFull
$extension = [IO.Path]::GetExtension($fileName)
$baseName = [IO.Path]::GetFileNameWithoutExtension($fileName)

$reserved = @('CON', 'PRN', 'AUX', 'NUL') +
    @(1..9 | ForEach-Object { 'COM' + $_ }) +
    @(1..9 | ForEach-Object { 'LPT' + $_ })
if ($reserved -contains $baseName.ToUpperInvariant()) {
    Add-Blocker 'reserved-name' "Target uses a reserved Windows device name: $baseName"
}

function Get-SafeName([string]$Name) {
    $safe = $Name -replace '[<>:"/\\|?*\x00-\x1F]', '_'
    $safe = $safe.Trim()
    $safe = $safe.TrimEnd([char[]]@('.', ' '))
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'file' }
    $safe
}

function Get-NextVersion([string]$Path) {
    $dir = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $ext = [IO.Path]::GetExtension($leaf)
    $stem = [IO.Path]::GetFileNameWithoutExtension($leaf)
    $start = 1
    if ($stem -match '^(?<stem>.+)_v(?<n>\d+)$') {
        $stem = $Matches['stem']
        $start = [int]$Matches['n']
    }
    for ($i = $start + 1; $i -lt 1000; $i++) {
        $candidate = Join-Path $dir ($stem + '_v' + $i + $ext)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

$outputPattern = '^\d{4}-\d{2}-\d{2}_.+_v\d+$'
$compliantPath = $targetFull

if ($Kind -eq 'output' -and $baseName -notmatch $outputPattern) {
    $safe = Get-SafeName $baseName
    $compliantName = $Date + '_' + $safe + '_v1' + $extension
    $compliantPath = Join-Path (Split-Path -Parent $targetFull) $compliantName
    Add-Blocker 'output-name' "Output name must match YYYY-MM-DD_<topic>_<description>_v<N>$extension"
}

$expectedRole = switch ($Kind) {
    'output' { $OutputDirName }
    'input' { $InputDirName }
    'archive' { $ArchiveDirName }
    'temp' { $TempDirName }
    default { '' }
}
if ($expectedRole -and ($segments -notcontains $expectedRole)) {
    Add-Warning 'role-dir' "Target is not under the expected '$expectedRole' directory."
}

$exists = Test-Path -LiteralPath $targetFull
$action = 'create'
$suggested = $targetFull
$isDirectory = $false

if ($exists) {
    $item = Get-Item -LiteralPath $targetFull -Force
    if ($item.PSIsContainer) {
        $isDirectory = $true
        Add-Blocker 'is-directory' "Target already exists as a directory: $targetFull"
        $action = 'blocked'
    } elseif ($Source -and (Test-Path -LiteralPath $Source)) {
        $sourceItem = Get-Item -LiteralPath $Source -Force
        if (-not $sourceItem.PSIsContainer) {
            $h1 = (Get-FileHash -LiteralPath $targetFull -Algorithm SHA256).Hash
            $h2 = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
            if ($h1 -eq $h2) {
                $action = 'reuse'
                $suggested = $targetFull
            } else {
                $action = 'version'
                $next = Get-NextVersion $compliantPath
                if ($next) { $suggested = $next }
            }
        } else {
            Add-Blocker 'source-directory' "Source is a directory; compare files instead: $Source"
        }
    } else {
        $action = 'version'
        $next = Get-NextVersion $compliantPath
        if ($next) { $suggested = $next }
    }
} elseif ($compliantPath -ne $targetFull) {
    $suggested = $compliantPath
}

if (-not $exists -and $action -eq 'create' -and $compliantPath -ne $targetFull) {
    $action = 'create'
    $suggested = $compliantPath
}

$parent = Split-Path -Parent $targetFull
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    Add-Warning 'parent-missing' "Parent directory does not exist yet: $parent"
}

$ok = ($blockers.Count -eq 0 -and $action -in @('create', 'reuse'))
if ($action -in @('version', 'blocked')) { $ok = $false }

$hardCodes = @('outside-root', 'is-root', 'protected-dir', 'reserved-name', 'is-directory', 'source-directory')
$hardBlocked = @($blockers | Where-Object { $hardCodes -contains $_.code }).Count -gt 0
if ($hardBlocked) {
    $action = 'blocked'
    $suggested = ''
    $ok = $false
}

$result = [pscustomobject]@{
    ok        = $ok
    root      = $rootFull
    target    = $targetFull
    relative  = $relative
    kind      = $Kind
    exists    = $exists
    isDirectory = $isDirectory
    action    = $action
    suggested = $suggested
    blockers  = @($blockers)
    warnings  = @($warnings)
    messages  = @($messages)
}

$result | ConvertTo-Json -Depth 5

if (-not $ok) { exit 1 }
