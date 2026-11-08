# upload-skill-to-repo

把一个**已安装**的 skill 上传到指定 Git 仓库的分支 —— 只给「仓库名 + skill 名」，脚本自己去找 skill、读目标仓库的规范、补齐缺的文档、提交并推送。

```text
./scripts/upload-skill.ps1 -Repo <owner/repo> -Skill <name> [-Branch main] [-Mode update]
```

## 何时使用

- 想把本机某个 skill 发布/分享到仓库；
- 更新仓库里已存在的某个 skill；
- 说「把这个 skill 推到 xxx 仓库」「帮我 push 上去」。

反向操作（把仓库里的 skill 装到本机）不属于这个 skill。

## 它做什么

1. **定位 skill**：按 DSH 的四个 skill 根按优先级扫描（项目 `.dsh` → 项目 `.agents` → `$DSH_HOME/skills` → `~/.agents/skills`），同名取优先级最高的并告知其余位置。
2. **校验格式**：frontmatter 必须存在，`name` 必须 kebab-case，`description` 必填，拒绝 DSH 不认的旧字段。
3. **安全检查**：排除 `.git` / `node_modules` / `dist` 等；>20MB 拒绝；扫 token、私钥头；有 `.env` 拒绝。
4. **远程预检**：克隆前先 `git ls-remote`，TLS 走 schannel 失败时自动切 `http.sslBackend=openssl`；失败就在「还没改任何文件」的阶段停住。
5. **读仓库规范并补齐**：统计兄弟 skill 的 README/metadata/CHANGELOG 出现率（过半即惯例），缺什么补什么，再更新根 README 表格、徽章计数、根 CHANGELOG。
6. **生成物自检**：YAML 可解析、`summary` 引号成对、README 无 `\"` 残留、CHANGELOG 不重复 `### Added`；不过就中止。
7. **提交并推送**：只 add 目标目录和根 README/CHANGELOG；推送结果**以远端 ref 是否包含本次 commit 为准**。

## 常用参数

| 参数 | 说明 |
|---|---|
| `-ShowList` | 列出本机可上传的 skill |
| `-CheckRepo` | 只输出规范对照报告，不上传 |
| `-DryRun` | 校验并打印计划，不提交不推送 |
| `-Mode update` | 覆盖仓库里同名 skill（默认 `create`，同名直接停） |
| `-Branch` | 目标分支，默认 `main` |
| `-DestDir` | 仓库内父目录，默认 `skills` |
| `-LocalPath` | 逃生口：直接指定 skill 文件夹（上传自身时必须用它） |
| `-NoConvention` | 跳过规范检查，原样上传 |
| `-KeepClone` | 保留临时克隆（失败时默认就会保留） |
| `-Json` | 输出结构化结果 |

## 规范检查示例

```text
$ ./scripts/upload-skill.ps1 -Repo me/skills -Skill pdf-tools -CheckRepo
SkillsDir         : skills
SiblingCount      : 2
RequiredDocs      : {README.md, metadata.yaml, CHANGELOG.md}
MissingDocs       : {}
SourceMissingDocs : {README.md, metadata.yaml, CHANGELOG.md}
WillGenerate      : {README.md, metadata.yaml, CHANGELOG.md}
RowExists         : False
BadgeCount        : 2
Issues            : {SOURCE_MISSING_DOC, ROOT_TABLE, ROOT_CHANGELOG}
```

## 1.1.0 修了什么

- **推送成功却报失败**：`EAP=Stop` 下 `git push` 的 stderr 被当成异常，`$LASTEXITCODE` 根本没机会判断；现在以远端 ref 是否指向本次 commit 为准。
- **生成的 `metadata.yaml` 非法**：frontmatter 里的 `\"` 没还原又被转义一次，变成 `\\"`；现在读时解转义、写时正确转义，并在提交前用 YAML 解析器复核。
- **根 CHANGELOG 重复 `### Added`**：每次上传都新建标题；现在追加到已有的 `### Added` 块。
- **`CheckRepo` 报 `MissingDocs: {}`**：新 skill 一个文档都没有却显示"不缺"；新增 `SourceMissingDocs` / `WillGenerate` / `SOURCE_MISSING_DOC`。
- **失败原因只剩 `To https://...`**：现在过滤 git 进度噪音，保留 `fatal:` / `error:` 一类有效行；失败时保留临时克隆。
- **克隆前无预检**：现在先探测远程与 TLS，schannel 失败自动切 openssl。
- **摘要被元描述句占满**：「仅在用户明确调用时运行。」这类句子会被跳过，取真正说明用途的一句。

## 安装

```powershell
Copy-Item -Recurse .\skills\upload-skill-to-repo "$env:DSH_HOME\skills\upload-skill-to-repo"
```

## License

MIT。
