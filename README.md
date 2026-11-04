# skillloom

> A curated collection of portable agent skills. Plain `SKILL.md`, no platform lock-in.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![skills](https://img.shields.io/badge/skills-1-blue.svg)](#skills)

## 这是什么

`skillloom` 是一个可复用的 Agent Skills 仓库。每个 skill 是一个自包含目录，核心只有 `SKILL.md` 和普通文件，不依赖特定框架、包管理器或构建步骤。

可用于 DSH、Claude Code、Codex，以及任何支持 `SKILL.md` 约定的 agent。

## Skills

| Skill | 用途 | 标签 | 版本 | 状态 |
|---|---|---|---|---|
| [workspace-organizer](skills/workspace-organizer/) | 统一文件读写、目录整理、命名与自检 | files, workflow, self-check | 1.0.0 | stable |

## 快速开始

### 1. 克隆

```bash
git clone https://github.com/Mowendao/skillloom.git
cd skillloom
```

### 2. 安装到 agent 的 skills 目录

DSH（Windows，推荐用 junction）：

```powershell
$src = Resolve-Path .\skills\workspace-organizer
$dst = Join-Path $env:DSH_HOME 'skills\workspace-organizer'
New-Item -ItemType Junction -Path $dst -Target $src
```

DSH（复制）：

```powershell
Copy-Item -Recurse .\skills\workspace-organizer "$env:DSH_HOME\skills\workspace-organizer"
```

Claude Code / Codex：

```bash
ln -s "$PWD/skills/workspace-organizer" ~/.claude/skills/workspace-organizer
ln -s "$PWD/skills/workspace-organizer" ~/.codex/skills/workspace-organizer
```

Windows 上可把 `ln -s` 换成 `New-Item -ItemType Junction`。

### 3. 验证

```bash
ls -l ~/.dsh/skills
```

然后在 agent 中输入 `/workspace-organizer`，或直接描述任务。

## 使用

显式调用：

```text
/workspace-organizer 只整理根目录，不动现有文件夹
```

自然语言：

```text
帮我把这个工作区按主题整理一下
```

`workspace-organizer` 会走：盘点 → 方案确认 → 计划 → 试运行 → 迁移 → 校验 → 整理说明。

## 常驻规则（可选）

如果希望 agent 在每次文件任务中自动遵守规范，把 `templates/AGENTS.md` 复制到工作区根目录。它提供 7 条常驻底线；`skills/workspace-organizer/SKILL.md` 提供完整流程。

## 目录结构

```text
skillloom/
├─ README.md
├─ LICENSE
├─ CHANGELOG.md
├─ skills/
│  └─ workspace-organizer/
│     ├─ SKILL.md          # 模型入口
│     ├─ README.md         # 人读说明
│     ├─ metadata.yaml     # 版本/许可/标签
│     ├─ CHANGELOG.md
│     ├─ references/       # 长文档
│     └─ scripts/          # 辅助脚本
└─ templates/
   └─ AGENTS.md            # 工作区常驻规则模板
```

## 新增 skill

1. 新建 `skills/<name>/`，目录名与 `SKILL.md` 的 `name` 一致（kebab-case）。
2. 写 `SKILL.md`：frontmatter 至少包含 `name`、`description`。
3. 写 `README.md`、`metadata.yaml`、`CHANGELOG.md`。
4. 需要时长文档放 `references/`，脚本放 `scripts/`，静态资源放 `assets/`。
5. 更新本 README 的 Skills 表。
6. 提交并打 tag：`skill/<name>/v1.0.0`。

每个 skill 自包含；跨 skill 依赖必须写进 `metadata.yaml` 的 `requires`。

## 约定

- 目录名 = frontmatter `name`，统一 kebab-case。
- 版本用语义化版本，放在 `metadata.yaml` 和 git tag，不放进目录名。
- 核心指令只依赖 `SKILL.md`；`metadata.yaml`、`README.md`、`CHANGELOG.md` 是文档层，agent 可以忽略。
- 平台适配放 `agents/`，删掉后核心仍可用。
- 不提交密钥、个人绝对路径、机器特定配置。

## 兼容性

| Agent | Skills 目录 |
|---|---|
| DSH | `$DSH_HOME/skills` |
| Claude Code | `~/.claude/skills` |
| Codex | `~/.codex/skills` |
| 通用 | 任意包含 `<name>/SKILL.md` 的目录 |

## License

MIT，见 [LICENSE](LICENSE)。每个 skill 可以在 `metadata.yaml` 中声明不同许可；以该 skill 目录内的许可文件为准。
