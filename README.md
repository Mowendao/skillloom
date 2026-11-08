<div align="center">

# skillloom

**一组可以直接拿来用的 Agent Skills。**<br>
把文件夹放进 agent 的 skills 目录，它就能在合适的时候按固定流程做事。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Skills](https://img.shields.io/badge/skills-5-blue.svg)](#包含哪些-skills)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](#参与贡献)

</div>

## 目录

- [这个仓库是做什么的](#这个仓库是做什么的)
- [包含哪些 Skills](#包含哪些-skills)
- [安装](#安装)
- [使用](#使用)
- [目录结构](#目录结构)
- [参与贡献](#参与贡献)
- [兼容性](#兼容性)
- [License](#license)

## 这个仓库是做什么的

`skillloom` 是一个 **Agent Skills 合集**：把可复用的工作流程写成一份 `SKILL.md`，让 AI agent 在遇到对应任务时，按同一套步骤执行，而不是每次临时发挥。

一个 skill 就是一个文件夹：

```text
skills/<name>/
├─ SKILL.md      # 给 agent 看的说明书（必需）
├─ README.md     # 给人看的说明
├─ scripts/      # 可选：辅助脚本
└─ references/   # 可选：长文档
```

它不绑定某个平台。DSH、Claude Code、Codex，或者任何能读取 `SKILL.md` 的 agent 都可以用。没有包管理器、没有构建步骤，复制文件夹即可。

**适合谁：**

- 经常整理文件、写报告、做重复性工作的人；
- 想让 agent 每次都按同一套规范做事的人；
- 想把自己的工作流沉淀下来、分享给别人的人。

## 包含哪些 Skills

| Skill | 一句话说明 | 状态 |
|---|---|---|
| [workspace-organizer](skills/workspace-organizer/) | 把杂乱的工作区按主题整理好，并留下迁移清单和回滚脚本 | ✅ stable |
| [upload-skill-to-repo](skills/upload-skill-to-repo/) | 把一个已安装的 skill（按名字从 DSH 的 skill 根目录查找，默认全局 ~/.dsh/skills）上传到指... | 🧪 beta |
| [collection-dedupe](skills/collection-dedupe/) | 把网页收藏夹/合集/列表页的条目导出成 CSV，解析出原名、社团、编号等字段并聚类判定\"同款\"，输出带分组、判定依据... | 🧪 beta |
| [five-stage-learning](skills/five-stage-learning/) | 用斯科特·杨的五阶段（获取/理解/扩展/应用/纠错）带用户在 DSH 里学一个具体知识点：每阶段给出目标、步骤、可复制的... | 🧪 beta |
| [obsidian-output-loop](skills/obsidian-output-loop/) | 仅在用户明确调用时运行。触发词：调用 obsidian-output-loop / 考我 / 抽查 → 出题评判改笔记；... | 🧪 beta |

### workspace-organizer

如果你经常面对这样的目录：

```text
Downloads/
├─ 新建文件夹 (3)/
├─ 报告最终版_v2.docx
├─ 截图 2026-11-04 21.35.12.png
├─ a.pdf  a.txt  a-1.pdf
└─ ...
```

`workspace-organizer` 会：

1. **先盘点**，不急着搬文件；
2. 给你一份分类方案，确认后再动手；
3. 按 `_输入` / `_产出` / `_归档` 归档；
4. 生成 `迁移清单.csv`、`rollback.ps1`、`整理说明.md`；
5. 最后跑一遍自检，确认没有覆盖、没有漏文件。

**安全默认：** 不覆盖已有文件、不删除用户文件、不跨出工作区、批量移动前必须确认。

[查看完整说明 →](skills/workspace-organizer/README.md)

## 安装

### 第 1 步：拿到仓库

```bash
git clone https://github.com/Mowendao/skillloom.git
cd skillloom
```

### 第 2 步：把 skill 放进 agent 的 skills 目录

先找到你的 agent 的 skills 目录：

| Agent | Windows | macOS / Linux |
|---|---|---|
| DSH | `%USERPROFILE%\.dsh\skills` | `~/.dsh/skills` |
| Claude Code | `%USERPROFILE%\.claude\skills` | `~/.claude/skills` |
| Codex | `%USERPROFILE%\.codex\skills` | `~/.codex/skills` |

> 如果 DSH 设置了 `DSH_HOME`，用 `$env:DSH_HOME\skills` 代替 `%USERPROFILE%\.dsh\skills`。

然后复制整个 `workspace-organizer` 文件夹过去。

**Windows PowerShell（DSH）：**

```powershell
$dst = "$env:USERPROFILE\.dsh\skills"
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item -Recurse .\skills\workspace-organizer $dst
```

**macOS / Linux（DSH）：**

```bash
mkdir -p ~/.dsh/skills
cp -R skills/workspace-organizer ~/.dsh/skills/
```

把路径换成 Claude Code / Codex 的目录即可。

> 如果目标目录里已经有同名 skill，先备份或改用链接，避免覆盖你本地的修改。

> **想跟着仓库更新？** 用链接代替复制：
>
> Windows：
>
> ```powershell
> New-Item -ItemType Junction `
>   -Path "$env:USERPROFILE\.dsh\skills\workspace-organizer" `
>   -Target "$PWD\skills\workspace-organizer"
> ```
>
> macOS / Linux：
>
> ```bash
> ln -s "$PWD/skills/workspace-organizer" ~/.dsh/skills/workspace-organizer
> ```
>
> 以后 `git pull` 就会同步；如果移动了仓库目录，需要重建链接。

### 第 3 步：验证

新开一个 agent 会话，输入：

```text
/workspace-organizer
```

如果能加载出说明，就安装成功了。也可以直接说「帮我把这个目录整理一下」。

## 使用

**显式调用：**

```text
/workspace-organizer 只整理根目录，不动现有文件夹
```

**自然语言：**

```text
工作区太乱了，帮我按主题整理一下
```

**它会先给方案，不会直接乱搬：**

```text
我先盘点了一下，建议这样分：
01_考研/ 02_项目/ 03_文档/ 99_临时与杂项/
预计移动 42 个文件、8 个文件夹；有 2 个重名文件，建议保留两个版本。
要按这个方案执行吗？
```

确认后它才会移动，并在 `99_临时与杂项/整理记录/` 下留下记录。

## 目录结构

```text
skillloom/
├─ README.md                 # 你正在看的文件
├─ LICENSE                   # MIT
├─ CHANGELOG.md              # 仓库级变更
├─ skills/                   # 所有 skill 都在这里，每个占一个目录
│  └─ workspace-organizer/
│     ├─ SKILL.md            # agent 入口（必需）
│     ├─ README.md           # 人读说明
│     ├─ metadata.yaml       # 版本 / 许可 / 标签
│     ├─ CHANGELOG.md        # 该 skill 的变更
│     ├─ references/         # 长文档
│     └─ scripts/            # PowerShell 辅助脚本
└─ templates/
   └─ AGENTS.md              # 可选：工作区常驻规则模板
```

新增 skill 时，只需要在 `skills/` 下加一个目录，不需要改注册表或构建配置。

## 参与贡献

欢迎 issue 和 PR。你可以：

- 报告 bug、提改进建议；
- 分享你想要的 skill；
- 直接提交一个新的 skill。

### 新增一个 skill

1. Fork 仓库，切一个分支：

   ```bash
   git switch -c skill/<name>
   ```

2. 新建 `skills/<name>/`，目录名用 kebab-case，和 `SKILL.md` 里的 `name` 一致。

3. 写 `SKILL.md`，frontmatter 至少包含：

   ```yaml
   ---
   name: <name>
   description: "一句话说明什么时候用它"
   ---
   ```

4. 补上 `README.md`、`metadata.yaml`、`CHANGELOG.md`（可以参考 `workspace-organizer`）。

5. 在根 README 的 Skills 表里加一行。

6. 用一个真实任务测一遍，确认 agent 能加载、脚本能跑。

7. 提交并发起 PR：

   ```bash
   git add skills/<name> README.md
   git commit -m "feat(skill): add <name>"
   git push origin skill/<name>
   ```

### 提交前检查

- [ ] 目录名与 `name` 一致，kebab-case
- [ ] `SKILL.md` 有 `name`、`description`
- [ ] 没有密钥、个人绝对路径、机器特定配置
- [ ] 脚本有参数说明，不硬编码本机路径
- [ ] 已在真实 agent 会话里试过
- [ ] 根 README 的 Skills 表已更新

不确定怎么加？先开一个 issue，描述你想解决的问题，我们可以一起设计。

## 兼容性

核心只有 `SKILL.md` 和普通文件；`README.md`、`metadata.yaml`、`CHANGELOG.md` 是文档层，agent 可以忽略。

| Agent | 支持情况 |
|---|---|
| DSH | ✅ 原生支持 `SKILL.md` |
| Claude Code | ✅ 放到 `~/.claude/skills` |
| Codex | ✅ 放到 `~/.codex/skills` |
| 其他 | ✅ 任何能读取 `<skills-root>/<name>/SKILL.md` 的 agent |

`workspace-organizer` 的脚本目前以 PowerShell 为主，Windows 体验最完整；在 macOS / Linux 上可以只用它的流程说明和审计脚本（需要 PowerShell 7）。

## License

[MIT](LICENSE)。每个 skill 可以在 `metadata.yaml` 中声明不同许可；以该 skill 目录内的许可文件为准。
