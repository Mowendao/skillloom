---
name: upload-skill-to-repo
description: 把一个已安装的 skill（按名字从 DSH 的 skill 根目录查找，默认全局 ~/.dsh/skills）上传到指定 Git 仓库的指定分支；上传前自动读取仓库规范（必备文档、根 README 表格、CHANGELOG、目录与提交格式）并自动补齐。Use when the user gives a repo plus a skill name and asks to publish, upload, push, share or 上传/发布/提交 that skill; no local folder path needed.
whenToUse: 用户说"把 <skill名> 传到 <仓库>" / "发布到 GitHub" / "推到我的 skills 仓库" / "更新仓库里的 <skill名>"，且只给了仓库和 skill 名
---

# 上传已安装的 skill 到 Git 仓库

用户只给**仓库名 + skill 名**。skill 本体由脚本从 DSH 的 skill 根目录里自动查找；上传前**自动读取并遵循目标仓库的规范**，缺什么补什么。

## 何时触发

用户给出（或要求选择）一个仓库，并表达以下任一意图：

- 把本机已安装的某个 skill 上传 / 发布 / 分享 / 推送到仓库；
- 更新仓库里已存在的某个 skill；
- 把 skill 提交到指定分支、"帮我 push 上去"。

**不触发**：把 skill 装到本机（用 `dsh-skill-install.ps1`，方向相反）；skill 尚未安装且用户没给路径（先安装或给 `-LocalPath`）。

## 需要用户提供的参数

| 参数 | 必填 | 默认 | 说明 |
|---|---|---|---|
| 仓库名 `Repo` | 是 | — | `owner/repo`、`https://github.com/owner/repo`、`git@github.com:owner/repo.git`，或其他 https/ssh/file URL |
| skill 名 `Skill` | 是 | — | 小写 kebab-case，等于 skill 文件夹名或 `SKILL.md` 里的 `name` |
| 目标分支 `Branch` | 否 | `main` | 不存在时从远端默认分支新建 |
| 仓库内目录 `DestDir` | 否 | `skills` | 最终路径 `<DestDir>/<skill-name>/` |
| 覆盖策略 `Mode` | 否 | `create` | 仓库已有同名时：`create` 报错停止，`update` 覆盖 |

**只问 2 个必填项。** 用户只给仓库时，先跑 `-ShowList` 把本机可上传的 skill 列出来让他选，不要自己猜。
用户没说分支就用 `main`，并在汇报里写明"用了 main"。
私有仓库要求本机已有 git 凭据（credential helper、SSH key 或 `gh auth login`）；脚本不会索要、也不会保存 token。

**skill 从哪找**（按 DSH 加载优先级，同名取第一个）：

| 优先级 | 根 | 说明 |
|---|---|---|
| 100 | `<项目根>/.dsh/skills` | 当前项目的 skill |
| 200 | `<项目根>/.agents/skills` | 当前项目共享的 agent skill |
| 400 | `<DSH_HOME>/skills` | **全局安装位置**，通常是 `C:\Users\<你>\.dsh\skills` |
| 500 | `~/.agents/skills` | 共享 agent skill |

同名 skill 在多个根都存在时，脚本用优先级最高的那个并警告；加 `-ShowAll` 则改为报错并列出全部位置。

## 仓库规范：自动检查 + 自动补齐

脚本在**克隆仓库后、复制文件前**先读一遍目标仓库，判断"这个仓库的 skill 长什么样"：

| 检查项 | 怎么判断 | 不满足时 |
|---|---|---|
| 必备文档 | 看 `<DestDir>` 下已有 skill，统计 README.md / metadata.yaml / CHANGELOG.md 出现率，过半即视为惯例 | 在 skill 目录内生成缺失的文档 |
| 根 README 表格 | 根 README 是否有 `\| [name](skills/name/) \| ... \|` 行 | 在最后一条 skill 行后插入 |
| 根 README 徽章 | 是否有 `skills-<数字>-blue` | 数字 +1 |
| 根 CHANGELOG | 是否有仓库级 CHANGELOG.md | 在 `## [Unreleased]` 下补一条 Added |
| 目录与命名 | `<DestDir>/<kebab-case>/` | 按 frontmatter `name` 落位 |
| 提交信息 | 仓库历史里 `feat(skill): ...` 的写法 | 默认 `feat(skill): add\|update <name>` |

**自动补的只是文档层，不碰 `SKILL.md` 和 `scripts/`。** 生成内容带标记（README 首行 `> 模板: upload-skill-to-repo`）。提交前会打印"自动生成: ..."，请把这行复述给用户并提醒他审阅。

三个开关：

| 开关 | 作用 |
|---|---|
| 默认 | 检查 + 自动补齐 |
| `-CheckRepo` | 只输出规范对照报告（`Issues` / `MissingDocs` / `RowExists` / `BadgeCount`），不上传、不改动 |
| `-NoConvention` | 跳过规范检查，原样上传 |

`-CheckRepo` 报告示例：

```text
Issues        : {MISSING_README.md, MISSING_metadata.yaml, ROOT_TABLE, ROOT_CHANGELOG}
MissingDocs   : {README.md, metadata.yaml}
RowExists     : False
BadgeCount    : 1
```

## 执行步骤

### 1. 收集参数

从用户消息里抽出仓库名和 skill 名。缺 skill 名就先列清单：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<本 skill 目录>\scripts\upload-skill.ps1" -ShowList
```

### 2. 先看仓库规范（推荐）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<本 skill 目录>\scripts\upload-skill.ps1" `
  -Repo "<owner/repo>" -Skill "<skill-name>" -CheckRepo
```

把 `Issues` 的缺口和脚本打算补的东西告诉用户：**"这个仓库要求 README+metadata+CHANGELOG，会自动补上，并在根 README 加一行"**。

### 3. DryRun

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<本 skill 目录>\scripts\upload-skill.ps1" `
  -Repo "<owner/repo>" -Skill "<skill-name>" -Branch "<branch>" -DryRun
```

### 4. 正式上传

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<本 skill 目录>\scripts\upload-skill.ps1" `
  -Repo "<owner/repo>" -Skill "<skill-name>" -Branch "<branch>" -Mode update
```

`-Mode update` 只在用户明确同意覆盖时加。需要提交身份加 `-AuthorName` / `-AuthorEmail`。

### 5. 汇报

必须包含：定位到的 skill（来源根 + 路径）、规范检查结果、**自动生成了哪些文件**、根 README/CHANGELOG 改了什么、仓库内路径、提交 SHA、可打开的链接。
失败时按下表说明原因，不要只说"失败了"。

## 脚本做了什么

`scripts/upload-skill.ps1`（`-Json` 可拿结构化结果）：

1. **定位 skill**：四个根按优先级扫描，匹配文件夹名或 frontmatter `name`；找不到列全部可用项。
2. **格式校验**：frontmatter 必须存在；`name` 小写 kebab-case；`description` 必填；拒绝 `disableModelInvocation` / `modelInvocable` / `userInvocable`。
3. **安全检查**：排除 `.git`、`node_modules`、`__pycache__`、`dist`、`build`；>2MB 警告、>20MB 拒绝；扫 `ghp_`、`github_pat_`、`sk-`、`AKIA`、`xox[baprs]-`、私钥头；有 `.env` 拒绝。
4. **克隆**：临时目录 `%TEMP%\dsh-upload-skill`（`-WorkDir` 可改；本地路径直接复制）。
5. **读规范 + 补文档**：见上节。
6. **写入与提交**：复制到 `<DestDir>/<name>/`；只 add 目标目录和根 README/CHANGELOG。
7. **推送**：`git push --set-upstream origin HEAD:refs/heads/<Branch>`。
8. **清理**：删除临时克隆（`-KeepClone` 保留，便于检查）。

## 失败处理

| 现象 | 原因 | 处理 |
|---|---|---|
| `本机没有名为 ... 的已安装 skill` | 名字不对或没装 | 先 `-ShowList` 对名字 |
| `规范缺口: MISSING_...` | 仓库要求而 skill 缺文档 | 默认自动补；不想补加 `-NoConvention` |
| `自动生成: ...` 后提交失败 | 多为 git 身份或网络 | 看下一行具体报错 |
| `拒绝上传 upload-skill-to-repo 自身` | 自保护 | 加 `-LocalPath` 指向本目录 |
| `克隆失败` + 网络 | 代理/断网 | 开代理；或先手工 clone |
| `克隆失败` + `sh.exe`/`signal pipe` | 环境限制 git 子进程 | 改普通终端 |
| `Authentication failed` | 私有仓库未登录 | `gh auth login`；不要贴 token |
| `protected branch` | 分支保护 | 换分支 |
| `仓库中已存在 ...` | 目标同名 | 确认后 `-Mode update` |
| `git commit 失败` | 缺 `user.name`/`user.email` | 加 `-AuthorName`/`-AuthorEmail` |
| `疑似机密内容` | 命中 token/私钥 | 删除或改占位符 |

## 硬性约束

1. **只收两个参数**：仓库名 + skill 名；skill 没装就明说，不拿别的目录凑数。
2. **自动补的只是文档**，不改 `SKILL.md`、不删脚本；生成内容要提醒用户审阅。
3. **先 CheckRepo/DryRun 再真推**；用户没明确说"推"时不做推送。
4. **只 add 目标目录和根 README/CHANGELOG**，不裹挟仓库其他改动。
5. **不外泄凭据**；**不静默改内容**：校验失败就报错。
6. **同名多根按优先级取用并告知**。
