<#
.SYNOPSIS
  把一个「已安装」的 skill 上传到指定 Git 仓库分支。

.DESCRIPTION
  用户只给两个东西：仓库名 + skill 名。skill 本体由脚本从 DSH 的 skill 根目录里查找：
    1. <项目根>/.dsh/skills       （project-dsh,   优先级最高）
    2. <项目根>/.agents/skills    （project-agents）
    3. <DSH_HOME>/skills          （user-dsh，即全局安装位置）
    4. ~/.agents/skills           （user-agents）
  同一个 skill 名在多个根里出现时，按上面的顺序取第一个；脚本会打印全部命中位置。

  然后：校验 SKILL.md → 克隆仓库 → 切/建分支 → 复制到 <DestDir>/<skill-name>/ → 提交 → 推送。

  被上传的 skill 必须是已安装的（在某个根里）；不跨根、不把别的目录硬塞进来，
  除非显式用 -LocalPath 指定（逃生口）。

.PARAMETER Repo
  owner/repo、https://github.com/owner/repo(.git)、git@github.com:owner/repo.git，
  或任意 https/ssh/file URL。

.PARAMETER Skill
  skill 名（小写 kebab-case），等于它所在文件夹名或 SKILL.md 里的 name。
  用 -ShowList 可查看当前机器上所有可上传的 skill。

.PARAMETER ShowList
  只列出可上传的 skill（名字、来源根、路径），不上传。

.PARAMETER Branch
  目标分支，默认 main；不存在时从远端默认分支新建。

.PARAMETER DestDir
  仓库内的父目录，默认 skills。最终路径 <DestDir>/<skill-name>。

.PARAMETER Mode
  create（默认）= 仓库已有同名就停；update = 覆盖。

.PARAMETER LocalPath
  逃生口：直接指定 skill 文件夹，跳过根目录查找。

.PARAMETER ShowAll
  同名 skill 在多个根里都有时，报错并列出全部命中，而不是静默取第一个。

.PARAMETER CommitMessage
  默认 "feat(skill): add|update <name>"。

.PARAMETER WorkDir
  临时克隆目录，默认 %TEMP%\dsh-upload-skill，不可写时退回 .scratch。

.PARAMETER DryRun
  只校验并打印计划，不复制、不提交、不推送。

.PARAMETER Force
  允许覆盖同名 skill；推送时附加 --force-with-lease。

.PARAMETER Json
  输出结构化 JSON。

.EXAMPLE
  ./upload-skill.ps1 -ShowList

.EXAMPLE
  ./upload-skill.ps1 -Repo me/my-skills -Skill pdf-tools -DryRun

.EXAMPLE
  ./upload-skill.ps1 -Repo me/my-skills -Skill pdf-tools -Branch skills/pdf-tools -Mode update
#>
[CmdletBinding()]
param(
    [string]$Repo,

    [string]$Skill,

    [switch]$ShowList,

    [string]$Branch = 'main',

    [string]$DestDir = 'skills',

    [ValidateSet('create', 'update')]
    [string]$Mode = 'create',

    [string]$LocalPath,

    [string]$CommitMessage,

    [string]$AuthorName,
    [string]$AuthorEmail,

    [switch]$ShowAll,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Json,

    [string]$WorkDir,

    [switch]$CheckRepo,
    [switch]$NoConvention,
    [switch]$KeepClone
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Result = [ordered]@{
    status     = 'failed'
    repo       = $Repo
    branch     = $Branch
    repoPath   = $null
    skill      = $Skill
    sourceRoot = $null
    sourcePath = $null
    commit     = $null
    pushed     = $false
    fileCount  = 0
    totalBytes = 0
    files      = @()
    warnings   = @()
    error      = $null
    convention = $null
    nextSteps  = @()
}

function Write-Step([string]$m) { if (-not $Json) { Write-Host "==> $m" -ForegroundColor Cyan } }
function Write-Ok([string]$m) { if (-not $Json) { Write-Host "  OK  $m" -ForegroundColor Green } }
function Write-Note([string]$m) { if (-not $Json) { Write-Host "  ..  $m" -ForegroundColor DarkGray } }
function Write-Warn2([string]$m) {
    $script:Result.warnings += $m
    if (-not $Json) { Write-Host "  !!  $m" -ForegroundColor Yellow }
}
function Write-Err2([string]$m) { if (-not $Json) { Write-Host "  XX  $m" -ForegroundColor Red } }

function Fail([string]$message) {
    $script:Result.status = 'failed'
    $script:Result.error = $message
    throw $message
}

# ---------- 工作目录 ----------
function Resolve-WorkBase([string]$explicit) {
    if ($explicit) {
        if (-not (Test-Path -LiteralPath $explicit)) { New-Item -ItemType Directory -Path $explicit -Force | Out-Null }
        return (Resolve-Path -LiteralPath $explicit).Path
    }
    $candidate = Join-Path ([System.IO.Path]::GetTempPath()) 'dsh-upload-skill'
    try {
        if (-not (Test-Path -LiteralPath $candidate)) { New-Item -ItemType Directory -Path $candidate -Force | Out-Null }
        $probe = Join-Path $candidate ('.probe-' + [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $probe -Value 'ok' -Encoding ascii -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $candidate
    }
    catch {
        $fallback = Join-Path (Get-Location).Path '.scratch'
        if (-not (Test-Path -LiteralPath $fallback)) { New-Item -ItemType Directory -Path $fallback -Force | Out-Null }
        return $fallback
    }
}

# ---------- 找项目根：最近含 .git 的祖先，否则当前目录 ----------
function Get-ProjectRoot {
    $cur = (Get-Location).Path
    while ($cur) {
        if (Test-Path (Join-Path $cur '.git')) { return $cur }
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return (Get-Location).Path
}

function Read-Frontmatter([string]$skillMd) {
    $raw = Get-Content -LiteralPath $skillMd -Raw -Encoding UTF8
    if ($raw -notmatch '(?s)^\uFEFF?---\s*\r?\n(.*?)\r?\n---') { return $null }
    return $Matches[1]
}

function Get-Field([string]$frontmatter, [string]$key) {
    foreach ($line in ($frontmatter -split "`r?`n")) {
        if ($line -match ('^{0}\s*:\s*(.*)$' -f [regex]::Escape($key))) {
            $v = $Matches[1].Trim()
            $v = $v -replace '\s+#.*$', ''
            if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
                $v = $v.Substring(1, $v.Length - 2)
                # 双引号值里的 YAML 转义必须还原；否则 \" 会带着反斜杠进入生成的文档，
                # 再被转义一次就成了 \\"，直接把 metadata.yaml 写成非法 YAML。
                $v = $v.Replace('\"', '"').Replace('\\', '\').Replace('\n', ' ').Replace('\t', ' ')
            }
            elseif ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) {
                $v = $v.Substring(1, $v.Length - 2).Replace("''", "'")
            }
            return $v.Trim()
        }
    }
    return $null
}

# ---------- 枚举 DSH 的 skill 根 ----------
function Get-SkillRoots {
    $dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
    $agentsHome = if ($env:DSH_AGENTS_HOME) { $env:DSH_AGENTS_HOME } else { Join-Path $HOME '.agents' }
    $projectRoot = Get-ProjectRoot
    $roots = @(
        [pscustomobject]@{ Rank = 100; Name = 'project-dsh'; Path = (Join-Path $projectRoot '.dsh/skills') },
        [pscustomobject]@{ Rank = 200; Name = 'project-agents'; Path = (Join-Path $projectRoot '.agents/skills') },
        [pscustomobject]@{ Rank = 400; Name = 'user-dsh'; Path = (Join-Path $dshHome 'skills') },
        [pscustomobject]@{ Rank = 500; Name = 'user-agents'; Path = (Join-Path $agentsHome 'skills') }
    )
    return @($roots | Where-Object { Test-Path -LiteralPath $_.Path })
}

function Find-Skills([string]$wanted) {
    $hits = @()
    foreach ($root in (Get-SkillRoots)) {
        $entries = @(Get-ChildItem -LiteralPath $root.Path -Directory -Force -ErrorAction SilentlyContinue)
        foreach ($dir in $entries) {
            if ($dir.Name -eq '.system') { continue }
            $md = Join-Path $dir.FullName 'SKILL.md'
            if (-not (Test-Path -LiteralPath $md)) { continue }
            $fm = Read-Frontmatter $md
            $fmName = if ($fm) { Get-Field $fm 'name' } else { $null }
            $candidateNames = @($dir.Name)
            if ($fmName) { $candidateNames += $fmName }
            if ($wanted -and -not ($candidateNames -contains $wanted)) { continue }
            $hits += [pscustomobject]@{
                Folder  = $dir.Name
                Name    = if ($fmName) { $fmName } else { $dir.Name }
                Root    = $root.Name
                Rank    = $root.Rank
                Path    = $dir.FullName
                SkillMd = $md
                HasFm   = [bool]$fm
            }
        }
    }
    return @($hits | Sort-Object Rank, Folder)
}

#region Convention
function Get-OneLine([string]$text, [int]$max = 120) {
    if (-not $text) { return '' }
    $line = ($text -split '\r?\n')[0].Trim()
    $line = $line -replace '^#+\s*', ''
    # 表格单元格里的 | 必须转义，否则整行会被切列
    $line = $line -replace '\|', '\|'
    if ($line.Length -gt $max) { $line = $line.Substring(0, $max) + '...' }
    return $line
}

# 生成 YAML 双引号字符串：先转义反斜杠，再转义双引号，保证结果可被 yaml 解析
function ConvertTo-YamlString([string]$s) {
    $e = ($s -replace '\s+', ' ').Trim()
    $e = $e -replace '\\', '\\'
    $e = $e -replace '"', '\"'
    return '"' + $e + '"'
}

function Read-TextFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8)
}

function Write-TextFile([string]$path, [string]$content) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-SkillSummaryMap([string]$repo, [string]$skillsDirName) {
    $map = @{}
    $root = Join-Path $repo $skillsDirName
    if (-not (Test-Path -LiteralPath $root)) { return $map }
    foreach ($sib in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $md = Join-Path $sib.FullName 'SKILL.md'
        $fm = if (Test-Path -LiteralPath $md) { Read-Frontmatter $md } else { $null }
        $map[$sib.Name] = [pscustomobject]@{
            Name = $sib.Name
            Desc = if ($fm) { Get-Field $fm 'description' } else { '' }
        }
    }
    return $map
}

function Test-RepoConvention([string]$repo, [string]$skillsDirName, [string]$skillName, [string]$sourceDir) {
    $root = Join-Path $repo $skillsDirName
    $siblings = @()
    if (Test-Path -LiteralPath $root) {
        $siblings = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })
    }
    $docs = @('README.md', 'metadata.yaml', 'CHANGELOG.md')
    $peers = @($siblings)                     # 含目标，用于统计“这个仓库普遍带哪些文档”
    $siblings = @($siblings | Where-Object { $_.Name -ne $skillName })
    $hits = [ordered]@{}
    foreach ($d in $docs) {
        $n = 0
        foreach ($s in $peers) { if (Test-Path -LiteralPath (Join-Path $s.FullName $d)) { $n++ } }
        $hits[$d] = $n
    }
    $required = @()
    if ($siblings.Count -ge 1) {
        $need = [Math]::Max(1, [Math]::Ceiling($siblings.Count / 2))
        $required = @($docs | Where-Object { $hits[$_] -ge $need })
    }
    elseif ($peers.Count -eq 1) {
        $required = @($docs | Where-Object { $hits[$_] -ge 1 })
    }

    $targetDir = Join-Path $root $skillName
    $missing = @()
    if (Test-Path -LiteralPath $targetDir) {
        $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $targetDir $_)) })
    }
    # 源目录缺哪些仓库要求的文档 —— 新 skill 一个文档都没有时，
    # 旧逻辑只查目标目录（还不存在），于是永远报 MissingDocs = {}，把「要生成三个文档」藏了起来。
    $sourceMissing = @()
    if ($sourceDir) {
        $sourceMissing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $sourceDir $_)) })
    }
    $willGenerate = @(if (Test-Path -LiteralPath $targetDir) { $missing } else { $sourceMissing })

    $readme = Read-TextFile (Join-Path $repo 'README.md')
    $hasTable = $false
    $rowExists = $false
    $badgeCount = 0
    if ($readme) {
        $m = [regex]::Match($readme, 'skills-(\d+)-blue')
        if ($m.Success) { $badgeCount = [int]$m.Groups[1].Value }
        $rowPattern = '(?m)^\|\s*\[[^\]]+\]\((?:\./)?' + [regex]::Escape($skillsDirName) + '/' + [regex]::Escape($skillName) + '/\)'
        $hasTable = [regex]::IsMatch($readme, '(?m)^\|\s*\[[^\]]+\]\((?:\./)?' + [regex]::Escape($skillsDirName) + '/')
        $rowExists = [regex]::IsMatch($readme, $rowPattern)
    }

    $issues = @()
    if ($siblings.Count -gt 0) {
        foreach ($m in $missing) { $issues += ('MISSING_' + $m) }
        if ($sourceMissing.Count -gt 0) { $issues += 'SOURCE_MISSING_DOC' }
        if ($hasTable -and -not $rowExists) { $issues += 'ROOT_TABLE' }
        $rootCl = Join-Path $repo 'CHANGELOG.md'
        if (Test-Path -LiteralPath $rootCl) {
            $clText = Read-TextFile $rootCl
            if ($clText -and -not $clText.Contains($skillName)) { $issues += 'ROOT_CHANGELOG' }
        }
    }

    return [pscustomobject]@{
        SkillsDir       = $skillsDirName
        SiblingCount    = $siblings.Count
        DocHits         = $hits
        RequiredDocs    = $required
        MissingDocs     = $missing
        SourceMissingDocs = $sourceMissing
        WillGenerate    = $willGenerate
        HasRootReadme   = [bool]$readme
        HasTable        = $hasTable
        RowExists       = $rowExists
        BadgeCount      = $badgeCount
        Issues          = $issues
    }
}

function Get-SkillSummary([string]$description, [int]$max = 80) {
    if (-not $description) { return '' }
    $s = $description.Trim()
    $cut = [regex]::Split($s, '(?i)\bUse when\b|\bUse it when\b')
    if ($cut.Count -gt 0 -and $cut[0].Trim().Length -gt 0) { $s = $cut[0].Trim() }
    $sentences = @($s -split '(?<=[。！？.!?])' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    # 「仅在用户明确调用时运行。」这类元描述说明的是调用约束，不是 skill 干什么；
    # 拿它当摘要会让整条描述信息归零，所以跳过它取下一句。
    while ($sentences.Count -gt 1 -and $sentences[0] -match '^(仅在|只在|仅当)[^，。]{0,18}(时|才)') {
        $sentences = @($sentences | Select-Object -Skip 1)
    }
    $s = if ($sentences.Count) { $sentences[0] } else { $s }
    if ($s.Length -gt $max) {
        # 尽量在标点处收口，避免出现「…验证...」这种半句
        $soft = [regex]::Match($s.Substring(0, $max), '^.*(?=[：；，、])')
        if ($soft.Success -and $soft.Value.Length -ge [int]($max / 2)) { $s = $soft.Value + '…' }
        else { $s = $s.Substring(0, $max) + '...' }
    }
    return $s
}
function New-MetaYaml([string]$skillName, [string]$description, [string]$author) {
    $summary = Get-SkillSummary $description
    $esc = ConvertTo-YamlString $summary
    $body = 'name: ' + $skillName + "`n" +
    'version: 1.0.0' + "`n" +
    'summary: ' + $esc + "`n" +
    'author: "' + ($author -replace '"', '\"') + '"' + "`n" +
    'license: MIT' + "`n" +
    'tags:' + "`n" +
    '  - skills' + "`n" +
    'status: beta' + "`n" +
    'requires: []' + "`n" +
    'platforms:' + "`n" +
    '  - windows' + "`n" +
    '  - macos' + "`n" +
    '  - linux' + "`n" +
    'entrypoint: SKILL.md' + "`n" +
    'source: ""' + "`n"
    return $body
}

function New-SubReadme([string]$skillName, [string]$description) {
    $tw = [char]0x6A21 + [char]0x677F
    $body = '# ' + $skillName + "`n`n" +
    (Get-SkillSummary $description 200) + "`n`n" +
    '> ' + $tw + ': upload-skill-to-repo' + "`n`n" +
    '## 何时使用' + "`n`n" +
    '- 用户提到 `' + $skillName + '`，或任务与它描述的场景一致。' + "`n" +
    '- 需要一套固定流程，而不是每次临时发挥。' + "`n`n" +
    '## 它做什么' + "`n`n" +
    '详见 [`SKILL.md`](SKILL.md)。脚本与长文档在 `scripts/`、`references/` 下（如有）。' + "`n`n" +
    '## 安装' + "`n`n" +
    '把 `skills/' + $skillName + '` 复制或链接到 agent 的 skills 目录：' + "`n`n" +
    '```powershell' + "`n" +
    'Copy-Item -Recurse .\skills\' + $skillName + ' "$env:DSH_HOME\skills\' + $skillName + '"' + "`n" +
    '```' + "`n`n" +
    '## License' + "`n`n" +
    'MIT。' + "`n"
    return $body
}

function Add-SubChangelog([string]$path, [string]$version, [string]$note) {
    $date = Get-Date -Format 'yyyy-MM-dd'
    $head = '# Changelog' + "`n`n" + 'All notable changes to this skill are documented here.' + "`n`n"
    $entry = '## [' + $version + '] - ' + $date + "`n`n" + '### Added' + "`n`n" + '- ' + $note + "`n`n"
    $cur = Read-TextFile $path
    if (-not $cur) { Write-TextFile $path ($head + $entry); return }
    $i = [regex]::Match($cur, '(?m)^## \[')
    if ($i.Success) {
        Write-TextFile $path ($cur.Substring(0, $i.Index) + $entry + $cur.Substring($i.Index))
    }
    else {
        Write-TextFile $path ($cur.TrimEnd() + "`n`n" + $entry)
    }
}

function Update-RootReadme([string]$repo, [string]$skillsDirName, [string]$skillName, [string]$description) {
    $path = Join-Path $repo 'README.md'
    $text = Read-TextFile $path
    if (-not $text) { return @() }
    $changed = @()
    $oneLine = Get-OneLine $description 60
    $row = '| [' + $skillName + '](' + $skillsDirName + '/' + $skillName + '/) | ' + $oneLine + ' | 🧪 beta |'
    $rowPattern = '(?m)^\|\s*\[[^\]]+\]\((?:\./)?' + [regex]::Escape($skillsDirName) + '/[^)]+\)'
    $rows = [regex]::Matches($text, $rowPattern)
    $hasRow = [regex]::IsMatch($text, [regex]::Escape($skillsDirName) + '/' + [regex]::Escape($skillName) + '/')
    if ($rows.Count -gt 0 -and -not $hasRow) {
        $last = $rows[$rows.Count - 1]
        $eol = $text.IndexOf("`n", $last.Index)
        if ($eol -lt 0) { $eol = $text.Length }
        $text = $text.Substring(0, $eol) + "`n" + $row + $text.Substring($eol)
        $changed += 'table-row'
    }
    $bm = [regex]::Match($text, 'skills-(\d+)-blue')
    if ($bm.Success -and -not $hasRow) {
        $oldCount = [int]$bm.Groups[1].Value
        $newCount = $oldCount + 1
        $text = $text.Replace($bm.Value, 'skills-' + $newCount + '-blue')
        $changed += ('badge ' + $oldCount + ' -> ' + $newCount)
    }
    Write-TextFile $path $text
    return $changed
}

function Update-RootChangelog([string]$repo, [string]$skillName) {
    $path = Join-Path $repo 'CHANGELOG.md'
    $text = Read-TextFile $path
    if (-not $text) { return @() }
    if ($text.Contains($skillName)) { return @() }
    $date = Get-Date -Format 'yyyy-MM-dd'
    $bullet = '- ' + $skillName + ' skill (' + $date + ', 文档由 upload-skill-to-repo 按仓库规范补齐)'
    $newBlock = '### Added' + "`n`n" + $bullet + "`n`n"

    $unreleased = [regex]::Match($text, '(?m)^## \[Unreleased\]')
    if ($unreleased.Success) {
        $after = $unreleased.Index + $unreleased.Length
        $next = [regex]::Match($text.Substring($after), '(?m)^## \[')
        $sectionEnd = if ($next.Success) { $after + $next.Index } else { $text.Length }
        $section = $text.Substring($after, $sectionEnd - $after)
        # Unreleased 里已有 ### Added 时只追加一条，不再重复建标题（每次上传都建一个会堆成 4 个 ### Added）
        $added = [regex]::Match($section, '(?m)^### Added[ \t]*$')
        if ($added.Success) {
            $blockStart = $after + $added.Index + $added.Length
            $tail = $text.Substring($blockStart)
            $blockEndRel = [regex]::Match($tail, '(?m)^#{2,} ')
            $blockEnd = if ($blockEndRel.Success) { $blockStart + $blockEndRel.Index } else { $text.Length }
            $block = $text.Substring($blockStart, $blockEnd - $blockStart)
            $lastBullet = $null
            foreach ($m in [regex]::Matches($block, '(?m)^- .*$')) { $lastBullet = $m }
            if ($lastBullet) {
                $insertAt = $blockStart + $lastBullet.Index + $lastBullet.Length
                $text = $text.Substring(0, $insertAt) + "`n" + $bullet + $text.Substring($insertAt)
                Write-TextFile $path $text
                return @('unreleased-entry-appended')
            }
            $text = $text.Substring(0, $blockStart) + "`n" + $bullet + "`n" + $text.Substring($blockStart)
            Write-TextFile $path $text
            return @('unreleased-entry')
        }
        $text = $text.Substring(0, $sectionEnd) + $newBlock + $text.Substring($sectionEnd)
        Write-TextFile $path $text
        return @('unreleased-entry')
    }
    $first = [regex]::Match($text, '(?m)^## \[')
    $insertAt = if ($first.Success) { $first.Index } else { $text.Length }
    $text = $text.Substring(0, $insertAt) + $newBlock + $text.Substring($insertAt)
    Write-TextFile $path $text
    return @('unreleased-entry')
}

# 生成物自检：自动补的文档在提交前必须能被下游真正解析，否则等于把坏文件推给别人
function Test-GeneratedDocs([string]$targetDir, [string]$skillName) {
    $problems = @()
    $readme = Join-Path $targetDir 'README.md'
    $meta = Join-Path $targetDir 'metadata.yaml'
    $cl = Join-Path $targetDir 'CHANGELOG.md'

    if (Test-Path -LiteralPath $readme) {
        $t = Read-TextFile $readme
        if ($t -notmatch ('(?m)^#\s+' + [regex]::Escape($skillName))) { $problems += 'README 缺一级标题' }
        if ($t -match '\\"') { $problems += 'README 含未还原的 \" 转义' }
    }
    if (Test-Path -LiteralPath $meta) {
        $t = Read-TextFile $meta
        if ($t -notmatch ('(?m)^name:\s*' + [regex]::Escape($skillName) + '\s*$')) { $problems += 'metadata 的 name 与目录不一致' }
        if ($t -notmatch '(?m)^summary:\s*"(?:[^"\\]|\\.)*"\s*$') { $problems += 'metadata 的 summary 引号不配对（YAML 非法）' }
        $py = Get-Command python -ErrorAction SilentlyContinue
        if ($py) {
            $ErrorActionPreference = 'Continue'
            $pyOut = (& $py.Source -c "import sys,yaml;d=yaml.safe_load(open(sys.argv[1],encoding='utf-8'));print('ok' if isinstance(d,dict) and d.get('name') else 'bad')" $meta 2>&1 | Out-String)
            $ErrorActionPreference = 'Stop'
            if ($pyOut -notmatch '(?m)\bok\b') {
                $lastLine = (($pyOut -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 1)
                $problems += ('metadata YAML 解析失败: ' + $lastLine)
            }
        }
    }
    if (Test-Path -LiteralPath $cl) {
        $t = Read-TextFile $cl
        if ($t -notmatch '(?m)^##\s*\[') { $problems += 'CHANGELOG 缺版本标题' }
        if (([regex]::Matches($t, '(?m)^### Added\s*$')).Count -gt 1) { $problems += 'CHANGELOG 有重复的 ### Added' }
    }
    return $problems
}

function Apply-RepoConvention([string]$repo, [string]$skillsDirName, [string]$skillName, [string]$description, [string]$author, [switch]$Auto) {
    $targetDir = Join-Path $repo ($skillsDirName + '/' + $skillName)
    $missing = @()
    foreach ($f in @('README.md', 'metadata.yaml', 'CHANGELOG.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $targetDir $f))) { $missing += $f }
    }
    $generated = @()
    $rootChanges = @()
    if ($Auto -and $missing.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
        foreach ($f in $missing) {
            switch ($f) {
                'README.md' { Write-TextFile (Join-Path $targetDir $f) (New-SubReadme $skillName $description) }
                'metadata.yaml' { Write-TextFile (Join-Path $targetDir $f) (New-MetaYaml $skillName $description $author) }
                'CHANGELOG.md' { Add-SubChangelog (Join-Path $targetDir $f) '1.0.0' 'Initial release; docs generated to follow the repository convention.' }
            }
            $generated += $f
        }
        $problems = @(Test-GeneratedDocs $targetDir $skillName)
        if ($problems.Count -gt 0) {
            Fail ('自动生成的文档校验失败，已中止（未提交）：' + ($problems -join '; ') + '。请检查 SKILL.md frontmatter 里的 description 是否含未转义的引号')
        }
        $rootChanges += Update-RootReadme $repo $skillsDirName $skillName $description
        $rootChanges += Update-RootChangelog $repo $skillName
    }
    return [pscustomobject]@{
        Missing     = $missing
        Generated   = $generated
        RootChanges = @($rootChanges | Where-Object { $_ })
        AutoApplied = [bool]($Auto -and $missing.Count -gt 0)
    }
}
#endregion

# ---------- 列表模式 ----------
if ($ShowList) {
    $all = @(Find-Skills $null)
    if ($Json) {
        @{ status = 'ok'; skills = $all } | ConvertTo-Json -Depth 4
        exit 0
    }
    if ($all.Count -eq 0) {
        Write-Host '当前机器上没有找到任何已安装的 skill。' -ForegroundColor Yellow
        exit 0
    }
    Write-Host ('可上传的 skill（共 {0} 个，按 DSH 优先级排序）：' -f $all.Count) -ForegroundColor Cyan
    $all | Format-Table @{n = 'Skill'; e = { $_.Name } }, @{n = '来源'; e = { $_.Root } }, @{n = '优先级'; e = { $_.Rank } }, @{n = '路径'; e = { $_.Path } } -AutoSize | Out-String -Width 220 | Write-Host
    Write-Host '用法: upload-skill.ps1 -Repo <owner/repo> -Skill <上面某个 Skill> [-Branch main] [-DryRun]' -ForegroundColor Yellow
    exit 0
}

# ---------- 参数与仓库地址 ----------
function Resolve-RepoUrl([string]$raw) {
    $v = $raw.Trim()
    if ($v -match '^[\w.-]+/[\w.-]+$') { return "https://github.com/$v" }
    if ($v -match '^https?://[^\s]+$') { return $v }
    if ($v -match '^git@[^\s:]+:[^\s]+$') { return $v }
    if ($v -match '^ssh://[^\s]+$') { return $v }
    if ($v -match '^file:///.+$') { return $v }
    if (Test-Path -LiteralPath $v) { return (Resolve-Path -LiteralPath $v).Path }
    throw "无法识别的仓库地址: $raw（支持 owner/repo、https、git@、ssh://、file:// 或本地裸仓库路径）"
}

function Assert-RelativeRepoPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return }
    $norm = $p -replace '\\', '/'
    if ($norm.StartsWith('/')) { throw "DestDir 必须是仓库内的相对路径: $p" }
    if (($norm -split '/') -contains '..') { throw "DestDir 不允许包含 ..: $p" }
    if ($norm -match '[:*?"<>|]') { throw "DestDir 含非法字符: $p" }
}

if ([string]::IsNullOrWhiteSpace($Repo)) { Fail '缺少 -Repo（仓库名，例如 me/my-skills）' }
if (-not $Skill -and -not $LocalPath) { Fail '缺少 -Skill（skill 名）；用 -ShowList 查看本机有哪些，或用 -LocalPath 直接指定文件夹' }

$repoUrl = $null
try { $repoUrl = Resolve-RepoUrl $Repo } catch { Fail $_.Exception.Message }
$script:Result.repo = $repoUrl

# 仓库 owner：生成的 metadata.yaml 用它兜底 author，避免清一色 "unknown"
$repoOwner = $null
if ($repoUrl -match 'github\.com[:/](?<owner>[^/]+)/') { $repoOwner = $Matches['owner'] }

if ([string]::IsNullOrWhiteSpace($Branch)) { Fail 'Branch 不能为空' }
if ($Branch -match '\s' -or $Branch -match '[~^:?*\[\]\\]' -or $Branch.StartsWith('-')) { Fail "分支名不合法: $Branch" }
Assert-RelativeRepoPath $DestDir
$DestDir = ($DestDir -replace '\\', '/').Trim('/')
if ($DestDir -eq '') { $DestDir = '.' }
$allowOverwrite = $Force -or ($Mode -eq 'update')

# ---------- git 输出处理 ----------
# 把 git 的进度噪音滤掉，只留下能对症的几行；否则失败原因会变成一句「To https://...」
function Get-GitErrorSummary([string]$raw) {
    if (-not $raw) { return '' }
    $noise = '^(To |Enumerating|Counting|Compressing|Writing objects|Total |remote: (Resolving|Compressing|Counting)|.*\|\s*\d+%|\s*\d+% )'
    $keep = @($raw -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch $noise })
    $key = @($keep | Where-Object { $_ -match '(?i)error|fatal|rejected|denied|authentication|refusing|not found|no such|hint:' })
    $pick = if ($key.Count) { $key } else { @($keep | Select-Object -Last 3) }
    return (($pick | Select-Object -First 6) -join "`n").Trim()
}

# schannel 在部分环境（受限沙箱 / 缺凭证库）里取不到 TLS 凭证；git 支持用环境变量注入配置，
# 子进程会继承，所以切成 openssl 后端后，后续 clone/push 都不用再改命令行。
function Enable-OpenSslBackend {
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = 'http.sslBackend'
    $env:GIT_CONFIG_VALUE_0 = 'openssl'
}

function Invoke-GitProbe([string]$repoUrl) {
    $ErrorActionPreference = 'Continue'
    $out = (& git ls-remote --heads $repoUrl 2>&1 | Out-String)
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    return [pscustomobject]@{ Code = $code; Out = $out }
}

try {
    # ---------- 解析 skill 来源 ----------
    $srcRoot = $null

    if ($LocalPath) {
        if (-not (Test-Path -LiteralPath $LocalPath)) { Fail "本地路径不存在: $LocalPath" }
        $srcRoot = (Resolve-Path -LiteralPath $LocalPath).Path
        if (-not (Test-Path -LiteralPath $srcRoot -PathType Container)) { Fail "本地路径不是文件夹: $srcRoot" }
        $script:Result.sourceRoot = 'local-path'
        Write-Note "使用 -LocalPath 指定的目录: $srcRoot"
    }
    else {
        if ($Skill -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
            Fail "skill 名 '$Skill' 不是小写 kebab-case；用 -ShowList 查看准确名称"
        }
        $hits = @(Find-Skills $Skill)
        if ($hits.Count -eq 0) {
            $available = @(Find-Skills $null | ForEach-Object { $_.Name } | Sort-Object -Unique)
            $availText = if ($available.Count) { $available -join ', ' } else { '（无）' }
            Fail ("本机没有名为 '{0}' 的已安装 skill。当前可用: {1}。也可用 -LocalPath 直接指定文件夹。" -f $Skill, $availText)
        }
        if ($hits.Count -gt 1) {
            $locations = ($hits | ForEach-Object { "  $($_.Root): $($_.Path)" }) -join "`n"
            if ($ShowAll) {
                Fail ("'{0}' 在多个根里都存在，请先删除重复项或用 -LocalPath 指定其一:`n{1}" -f $Skill, $locations)
            }
            Write-Warn2 ("'{0}' 出现 {1} 次，按优先级使用 {2}；其余: {3}" -f $Skill, $hits.Count, $hits[0].Root, (($hits | Select-Object -Skip 1 | ForEach-Object { $_.Root }) -join ', '))
        }
        $pick = $hits[0]
        $srcRoot = $pick.Path
        $script:Result.sourceRoot = $pick.Root
        Write-Ok ("定位到 skill: {0}（来源 {1}, rank {2}）" -f $pick.Name, $pick.Root, $pick.Rank)
        Write-Note $srcRoot
    }

    $skillMd = Join-Path $srcRoot 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMd)) {
        $nested = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Filter 'SKILL.md' -ErrorAction SilentlyContinue)
        if ($nested.Count -eq 1) {
            Write-Warn2 "SKILL.md 不在根部，已自动上提: $($nested[0].FullName)"
            $srcRoot = $nested[0].Directory.FullName
            $skillMd = $nested[0].FullName
        }
        elseif ($nested.Count -gt 1) {
            Fail "该目录下有 $($nested.Count) 个 SKILL.md，无法判断上传哪一个"
        }
        else {
            Fail "目录里没有 SKILL.md: $srcRoot"
        }
    }

    # 自保护：不要把本上传工具自己推出去
    $srcLeaf = Split-Path -Leaf $srcRoot
    if (-not $LocalPath -and $srcLeaf -eq 'upload-skill-to-repo') {
        Fail '拒绝上传 upload-skill-to-repo 自身（这是本工具）；如确实需要，请加 -LocalPath 指向本目录（或一份拷贝）'
    }

    # ---------- 校验 SKILL.md ----------
    $fm = Read-Frontmatter $skillMd
    if (-not $fm) { Fail 'SKILL.md 缺少 YAML frontmatter（需要 --- 包裹 name 与 description）' }
    $skillName = Get-Field $fm 'name'
    $desc = Get-Field $fm 'description'
    if (-not $skillName) { Fail 'SKILL.md frontmatter 缺 name' }
    if ($skillName -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
        Fail "name '$skillName' 不是小写 kebab-case（^[a-z0-9]+(-[a-z0-9]+)*$），DSH 会拒绝加载"
    }
    if (-not $desc -or $desc -in @('>', '|')) { Fail 'SKILL.md frontmatter 缺 description（多行写法请改成单行字符串）' }
    foreach ($legacy in @('disableModelInvocation', 'modelInvocable', 'userInvocable')) {
        if ($fm -match ('(?m)^{0}\s*:' -f $legacy)) {
            Fail "SKILL.md 用了 DSH 不认的字段 '$legacy'，会整条丢弃；请改成 disable-model-invocation / user-invocable"
        }
    }
    if ($srcLeaf -cne $skillName) {
        Write-Warn2 "文件夹名 '$srcLeaf' 与 frontmatter name '$skillName' 不一致；仓库内按 name 命名"
    }
    if ($Skill -and $skillName -cne $Skill) {
        Write-Warn2 "请求的 skill 名 '$Skill' 与 frontmatter name '$skillName' 不一致，按 frontmatter 为准"
    }
    $script:Result.skill = $skillName
    $script:Result.sourcePath = $srcRoot

    # ---------- 文件清单 + 安全检查 ----------
    $excludeDirs = @('.git', 'node_modules', '__pycache__', '.venv', 'venv', 'dist', 'build', '.idea', '.vscode', '.pytest_cache')
    $allFiles = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
            $rel = $_.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
            $parts = $rel -split '[\\/]'
            $skip = $false
            foreach ($p in $parts[0..([Math]::Max(0, $parts.Count - 2))]) {
                if ($excludeDirs -contains $p) { $skip = $true; break }
            }
            -not $skip
        })

    $totalBytes = ($allFiles | Measure-Object -Property Length -Sum).Sum
    if (-not $totalBytes) { $totalBytes = 0 }
    $bigFiles = @($allFiles | Where-Object { $_.Length -gt 2MB })
    if ($bigFiles.Count -gt 0) {
        Write-Warn2 ("有 {0} 个文件超过 2MB: {1}" -f $bigFiles.Count, (($bigFiles | ForEach-Object { "$($_.Name)($([math]::Round($_.Length/1MB,1))MB)" }) -join ', '))
    }
    if ($totalBytes -gt 20MB) { Fail ("skill 目录总计 {0:N1}MB，超过 20MB 上限；请先精简 assets/ 或改用 Git LFS" -f ($totalBytes / 1MB)) }

    $secretHits = @()
    $secretPattern = (
        'gh[pousr]_[A-Za-z0-9]{20,}' + '|' +
        'github_pat_[A-Za-z0-9_]{20,}' + '|' +
        'sk-[A-Za-z0-9]{20,}' + '|' +
        'AKIA[0-9A-Z]{16}' + '|' +
        'xox[baprs]-[A-Za-z0-9-]{10,}' + '|' +
        '-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----'
    )
    foreach ($f in $allFiles) {
        if ($f.Length -gt 1MB) { continue }
        if ($f.Extension -match '^\.(png|jpe?g|gif|webp|ico|pdf|zip|gz|7z|xlsx?|docx?|pptx?|mp[34]|wav|bin|exe|dll|so|dylib)$') { continue }
        try {
            $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop
            if ($text -match $secretPattern) { $secretHits += $f.FullName.Substring($srcRoot.Length).TrimStart('\', '/') }
        }
        catch { Write-Note "跳过无法按文本读取的文件: $($f.Name)" }
    }
    if ($secretHits.Count -gt 0) { Fail ("疑似机密内容，拒绝上传: {0}" -f ($secretHits -join ', ')) }
    if (@($allFiles | Where-Object { $_.Name -match '^\.env' }).Count -gt 0) { Fail '目录中包含 .env 文件，拒绝上传' }

    $script:Result.fileCount = $allFiles.Count
    $script:Result.totalBytes = [int]$totalBytes
    $script:Result.files = @($allFiles | ForEach-Object { $_.FullName.Substring($srcRoot.Length).TrimStart('\', '/') } | Sort-Object)
    Write-Ok ("文件清单: {0} 个文件, {1:N1} KB" -f $allFiles.Count, ($totalBytes / 1KB))

        # ---------- 目标路径 ----------
    $repoRelPath = if ($DestDir -eq '.') { $skillName } else { "$DestDir/$skillName" }
    $script:Result.repoPath = $repoRelPath
    # ---------- 克隆仓库 ----------
    $taskId = 'upload-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $workBase = Resolve-WorkBase $WorkDir
    $workDir = Join-Path $workBase $taskId
    $cloneDir = Join-Path $workDir 'repo'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    $isLocalRepo = (Test-Path -LiteralPath $repoUrl -PathType Container)

    # ---------- 预检：先确认远程可达，再克隆，避免做完一堆解析才发现认证/网络不通 ----------
    if (-not $isLocalRepo) {
        Write-Step '预检：远程可达性 / TLS / 读取权限'
        $probe = Invoke-GitProbe $repoUrl
        if ($probe.Code -ne 0 -and $probe.Out -match '(?i)schannel|SEC_E_NO_CREDENTIALS|AcquireCredentialsHandle') {
            Write-Warn2 'TLS 后端 schannel 不可用（取不到证书凭证），改用 openssl 重试'
            Enable-OpenSslBackend
            $probe = Invoke-GitProbe $repoUrl
            if ($probe.Code -eq 0) { Write-Ok 'openssl 后端可用（已通过 GIT_CONFIG_* 注入，后续 clone/push 复用）' }
        }
        if ($probe.Code -ne 0) {
            $hint = '常见原因：代理未开 / 断网 / 仓库不存在 / 无读权限 / 私有仓库未登录'
            if ($probe.Out -match 'sh\.exe|signal pipe|fatal error - couldn') {
                $hint = 'git 子进程被运行环境限制（sh.exe / signal pipe 失败）：在 DSH 沙箱里通常需要一次 danger-full-access 授权，或在普通终端执行'
            }
            elseif ($probe.Out -match '(?i)could not read Username|Authentication failed|terminal prompts disabled') {
                $hint = '缺少 git 凭据：先 gh auth login，或让 credential helper 能读到已保存的 GitHub 凭据'
            }
            Fail ("远程预检失败（尚未克隆、未改动任何文件）`n{0}`n提示: {1}" -f (Get-GitErrorSummary $probe.Out), $hint)
        }
        Write-Ok '远程可达，TLS 正常'
    }

    Write-Step "克隆目标仓库: $repoUrl"
    if ($isLocalRepo) {
        Copy-Item -LiteralPath $repoUrl -Destination $cloneDir -Recurse -Force
    }
    else {
        $ErrorActionPreference = 'Continue'
        $cloneOut = (& git clone --quiet $repoUrl $cloneDir 2>&1 | Out-String)
        $cloneCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($cloneCode -ne 0) {
            Fail ("克隆失败`n{0}" -f (Get-GitErrorSummary $cloneOut))
        }
    }
    $ErrorActionPreference = 'Continue'
    $remoteHead = (& git -C $cloneDir symbolic-ref --short refs/remotes/origin/HEAD 2>&1 | Out-String).Trim()
    $ErrorActionPreference = 'Stop'
    if (-not $remoteHead) { $remoteHead = (& git -C $cloneDir symbolic-ref --short HEAD 2>$null | Out-String).Trim() }
    if ($remoteHead -match '^origin/(.+)$') { $defaultBranch = $Matches[1] } else { $defaultBranch = 'main' }
    $hasOrigin = (((& git -C $cloneDir remote 2>&1 | Out-String) -replace "`r", '') -match '(?m)^origin$')
    $localExists = ((& git -C $cloneDir branch --list $Branch 2>&1 | Out-String).Trim() -ne '')
    $branchExists = $false
    if ($hasOrigin) {
        $branchExists = ((& git -C $cloneDir branch -r --list "origin/$Branch" 2>&1 | Out-String).Trim() -ne '')
    }

    if ($localExists -or $branchExists) {
        if ($branchExists) {
            & git -C $cloneDir checkout --quiet -B $Branch "origin/$Branch" 2>&1 | Out-Null
        }
        else {
            & git -C $cloneDir checkout --quiet $Branch 2>&1 | Out-Null
        }
        if ($LASTEXITCODE -ne 0) { Fail "切换到分支失败: $Branch" }
        Write-Ok "使用已存在分支: $Branch"
    }
    else {
        if ($hasOrigin) {
            & git -C $cloneDir checkout --quiet -b $Branch "origin/$defaultBranch" 2>&1 | Out-Null
        }
        else {
            & git -C $cloneDir checkout --quiet -b $Branch 2>&1 | Out-Null
        }
        if ($LASTEXITCODE -ne 0) { Fail ("创建分支失败: {0}" -f $Branch) }
        Write-Ok ("新建分支: " + $Branch)
    }
    # ---------- 仓库规范 ----------
    $conv = $null
    if ($CheckRepo -or -not $NoConvention) {
        Write-Step '检查仓库规范'
        $conv = Test-RepoConvention $cloneDir $DestDir $skillName $srcRoot
        if ($conv.Issues.Count -eq 0) { Write-Ok '已符合仓库规范' }
        else { Write-Warn2 ('规范缺口: ' + ($conv.Issues -join ', ')) }
        if ($CheckRepo) {
            $script:Result.convention = $conv
            $script:Result.status = 'repo-check'
            if ($conv.WillGenerate.Count -gt 0) { Write-Note ('将要生成: ' + ($conv.WillGenerate -join ', ')) }
            if ($Json) { $script:Result | ConvertTo-Json -Depth 6 } else { $conv | Format-List | Out-String | Write-Host }
            return
        }
        if (-not $NoConvention) {
            $authorBase = if ($AuthorName) { $AuthorName } elseif ($repoOwner) { $repoOwner } else { 'unknown' }
            $script:Result.convention = $conv
            $toFill = @($conv.MissingDocs) + @($conv.SourceMissingDocs) | Select-Object -Unique
            Write-Note ('待补齐: ' + $(if (@($toFill).Count) { @($toFill) -join ', ' } else { '根 README / CHANGELOG' }))
        }
    }
    if ($conv -and -not $NoConvention) {
        $preRoot = Update-RootReadme $cloneDir $DestDir $skillName $desc
        $preRoot += Update-RootChangelog $cloneDir $skillName
        foreach ($rc in $preRoot) { Write-Note ('根 README: ' + $rc) }
    }
    $destAbs = Join-Path $cloneDir ($repoRelPath -replace '/', [IO.Path]::DirectorySeparatorChar)
    $destExists = Test-Path -LiteralPath $destAbs
    if ($destExists -and -not $allowOverwrite) {
        Fail "仓库中已存在 $repoRelPath。确认要覆盖请加 -Mode update（或 -Force）"
    }
    if ($destExists) { Write-Warn2 "将覆盖仓库中已有的 $repoRelPath" }

    if ($DryRun) {
        Write-Ok "DryRun: 计划写入 $repoRelPath（$($allFiles.Count) 个文件），未提交"
        $script:Result.status = 'dry-run'
        $script:Result.nextSteps = @(
            "确认无误后去掉 -DryRun 再执行一次",
            "目标路径: $repoRelPath @ $Branch"
        )
    }
    else {
        $ErrorActionPreference = 'Continue'
        if ($destExists) { Remove-Item -LiteralPath $destAbs -Recurse -Force }
        New-Item -ItemType Directory -Path $destAbs -Force | Out-Null
        foreach ($f in $allFiles) {
            $rel = $f.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
            $target = Join-Path $destAbs ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item -LiteralPath $f.FullName -Destination $target -Force
        }
        Write-Ok "已复制到 $repoRelPath"

        if (-not $NoConvention) {
            $fix = Apply-RepoConvention $cloneDir $DestDir $skillName $desc $authorBase -Auto
            $script:Result.convention = $fix
            if ($fix.Generated.Count -gt 0) { Write-Ok ('自动生成: ' + ($fix.Generated -join ', ') + ' (请在提交前审阅)') }
        }

        & git -C $cloneDir add -- "$repoRelPath" 2>$null
        if (-not $NoConvention) {
            & git -C $cloneDir add -- README.md CHANGELOG.md 2>$null
            if ($LASTEXITCODE -ne 0) { Write-Warn2 '根 README / CHANGELOG 未能自动暂存，请手动 git add' }
        }
        if ($LASTEXITCODE -ne 0) { Fail "git add 失败: $repoRelPath" }
        $staged = (& git -C $cloneDir diff --cached --name-only | Out-String).Trim()
        if ($staged -eq '') { Fail '没有产生任何改动（内容与仓库中完全一致？）' }

        if (-not $CommitMessage) {
            $verb = if ($destExists) { 'update' } else { 'add' }
            $CommitMessage = "feat(skill): $verb $skillName"
        }
        $identity = @()
        if ($AuthorName) { $identity += @('-c', "user.name=$AuthorName") }
        if ($AuthorEmail) { $identity += @('-c', "user.email=$AuthorEmail") }
        $ErrorActionPreference = 'Continue'
        $commitOut = & git -C $cloneDir @identity -c core.quotepath=false -c core.autocrlf=false commit --quiet -m $CommitMessage 2>&1 | Out-String
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -ne 0) {
            Fail ("git commit 失败（可能未配置 git user.name / user.email）: {0}`n可加 -AuthorName `"Your Name`" -AuthorEmail you@example.com" -f $commitOut.Trim())
        }
        $sha = (& git -C $cloneDir rev-parse --short HEAD | Out-String).Trim()
        $script:Result.commit = $sha
        Write-Ok "已提交: $sha  $CommitMessage"

        Write-Step "推送到 origin/$Branch"
        $pushArgs = @('-C', $cloneDir, 'push', '--set-upstream', 'origin', "HEAD:refs/heads/$Branch")
        if ($Force -and $branchExists) { $pushArgs += '--force-with-lease' }
        $ErrorActionPreference = 'Continue'
        $pushOut = (& git @pushArgs 2>&1 | Out-String)
        $pushCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $headSha = (& git -C $cloneDir rev-parse HEAD | Out-String).Trim()
        $remoteSha = ''
        if ($hasOrigin) {
            $ErrorActionPreference = 'Continue'
            $remoteSha = (& git -C $cloneDir ls-remote origin "refs/heads/$Branch" 2>$null | Out-String).Trim()
            $ErrorActionPreference = 'Stop'
        }
        # 判定标准是「远端分支是否已经包含本次提交」，不是 git 的退出码：
        # git push 一定往 stderr 写进度，旧版在 EAP=Stop 下会把它当成异常，推送成功也报失败。
        $remoteHit = [bool]($headSha -and $remoteSha -match ('^' + [regex]::Escape($headSha)))
        if ($pushCode -ne 0 -and -not $remoteHit) {
            Fail ("推送失败（未登录、无写权限、分支保护或网络问题）`n{0}" -f (Get-GitErrorSummary $pushOut))
        }
        if ($pushCode -ne 0 -and $remoteHit) {
            Write-Warn2 'git push 返回非零，但远端分支已指向本次提交，按成功处理'
        }
        elseif ($pushCode -eq 0 -and -not $remoteHit) {
            Write-Warn2 '推送命令成功，但未能核验远端 ref（可稍后 git ls-remote 复查）'
        }
        $script:Result.pushed = $true
        Write-Ok ("推送成功: {0}（远端 {1}）" -f $Branch, $headSha.Substring(0, 7))

        $webUrl = $repoUrl -replace '\.git$', ''
        if ($webUrl -match '^git@([^:]+):(.+)$') { $webUrl = "https://$($Matches[1])/$($Matches[2])" }
        $script:Result.nextSteps = @(
            "仓库: $webUrl/tree/$Branch/$repoRelPath",
            "在 DSH 里安装: ./dsh-skill-install.ps1 -Source `"$repoUrl`" -Dest user"
        )
        $script:Result.status = 'ok'
    }
}
catch {
    if ($script:Result.status -ne 'dry-run') {
        $script:Result.status = 'failed'
        if (-not $script:Result.error) { $script:Result.error = $_.Exception.Message }
    }
    Write-Err2 $script:Result.error
}
finally {
    $wd = Get-Variable -Name workDir -ErrorAction SilentlyContinue
    if ($wd -and $wd.Value -and (Test-Path -LiteralPath $wd.Value)) {
        if ($KeepClone -or $script:Result.status -eq 'failed') {
            # 失败时保留克隆：本地 commit、生成物、git 输出都在里面，重试或排查都用得上
            if ($script:Result.status -eq 'failed') {
                $script:Result.warnings += "已保留临时克隆便于排查: $($wd.Value)"
                if (-not $Json) { Write-Host ("  ..  已保留临时克隆便于排查: {0}" -f $wd.Value) -ForegroundColor DarkGray }
            }
        }
        else {
            Remove-Item -LiteralPath $wd.Value -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($Json) {
    $script:Result | ConvertTo-Json -Depth 5
}
else {
    Write-Host ''
    Write-Host ("状态: {0}" -f $script:Result.status) -ForegroundColor White
    if ($script:Result.status -eq 'failed') { Write-Host ("原因: {0}" -f $script:Result.error) -ForegroundColor Red }
    if ($script:Result.skill) { Write-Host ("skill: {0}（来源 {1}）" -f $script:Result.skill, $script:Result.sourceRoot) }
    if ($script:Result.repoPath) { Write-Host ("目标路径: {0} @ {1}" -f $script:Result.repoPath, $Branch) }
    if ($script:Result.commit) { Write-Host ("提交: {0}" -f $script:Result.commit) }
    foreach ($s in $script:Result.nextSteps) { Write-Host ("-> {0}" -f $s) -ForegroundColor Yellow }
    if ($script:Result.warnings.Count -gt 0) {
        Write-Host '警告:' -ForegroundColor Yellow
        foreach ($w in $script:Result.warnings) { Write-Host ("  - {0}" -f $w) }
    }
}

if ($script:Result.status -eq 'failed') { exit 1 }
exit 0
