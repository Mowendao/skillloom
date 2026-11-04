# workspace-organizer

把工作区的文件读写、目录整理、命名和自检固化成一套可复用的 Agent Skill。

核心只有一个 `SKILL.md`；`scripts/` 和 `references/` 是按需使用的辅助资源，不依赖第三方包。

## 何时使用

- 用户抱怨工作区、下载目录或项目根目录太乱。
- 需要批量移动、分类归档、重命名文件。
- 希望 agent 每次按同一套标准读写文件：输入归档、产出命名、禁止覆盖、任务结束自检。
- 需要在整理后留下迁移清单、回滚脚本和整理说明。

## 它做什么

`SKILL.md` 定义四个阶段：

1. **自动触发**：任务涉及文件读写/移动/整理时先加载；写入前预检；写入后微校验；收尾审计。
2. **执行步骤**：定位主题 → 接收输入 → 预检 → 写入 → 归档 → 自检 → 汇报。
3. **约束**：不覆盖、不删除用户文件、不进入受保护目录、不跨出工作区、批量移动先确认。
4. **自检**：`audit.ps1` + 人工清单 + 违规修正表，直到 `ok=true`。

### 目录模型

```
<workspace>/
├─ 01_<topic>/
│  ├─ _输入/      # 用户输入，只读
│  ├─ _产出/      # 交付物，YYYY-MM-DD_topic_desc_vN.ext
│  └─ _归档/      # 旧版本
├─ 99_临时与杂项/
│  ├─ tmp/
│  ├─ 未分类/
│  ├─ 重复文件/
│  └─ 整理记录/
└─ 整理说明.md
```

### 脚本

| 脚本 | 用途 |
|---|---|
| `scripts/preflight.ps1` | 写入前检查越界、受保护目录、命名、冲突，给出建议路径 |
| `scripts/inventory.ps1` | 盘点顶层条目、扩展名、体积、子项 |
| `scripts/organize.ps1` | 按 `plan.json` 批量迁移，生成 manifest / rollback / summary |
| `scripts/verify.ps1` | 校验迁移目标存在、源消失、无同名嵌套 |
| `scripts/audit.ps1` | 任务结束审计：根目录散落、顶层编号、产出命名、临时文件、空目录 |

## 安装

### DSH

```powershell
$src = Resolve-Path .\skills\workspace-organizer
$dst = Join-Path $env:DSH_HOME 'skills\workspace-organizer'
New-Item -ItemType Junction -Path $dst -Target $src
```

或者直接复制：

```powershell
Copy-Item -Recurse .\skills\workspace-organizer "$env:DSH_HOME\skills\workspace-organizer"
```

### Claude Code / Codex

把 `skills/workspace-organizer` 复制或链接到对应目录：

- Claude Code：`~/.claude/skills/workspace-organizer`
- Codex：`~/.codex/skills/workspace-organizer`

### 通用

任何支持 `SKILL.md` 约定的 agent，只要能读取 `<skills-root>/workspace-organizer/SKILL.md` 就能使用。

## 使用

显式调用：

```text
/workspace-organizer 只整理根目录，不动现有文件夹
```

或直接描述任务：

```text
帮我把这个工作区按主题整理一下
```

## 常驻规则（可选）

如果希望每次对话都自动遵守文件规范，把仓库根目录的 `templates/AGENTS.md` 复制到工作区根目录。它包含 7 条常驻底线；`SKILL.md` 负责详细流程。

## 依赖

- PowerShell 5.1+（Windows；脚本使用 `-LiteralPath` 和 junction 相关说明）。
- 无第三方 Python/Node 包。

## 安全边界

- 不覆盖已有文件；冲突用版本号或归档解决。
- 不删除用户文件；删除请求先归档并确认。
- 不进入 `.git`、`.dsh`、`node_modules` 等受保护目录。
- 不跨出工作区根目录。
- 批量移动前先出方案并确认。

## License

MIT。见仓库根目录 `LICENSE`。
