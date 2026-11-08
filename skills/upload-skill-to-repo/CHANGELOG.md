# Changelog

All notable changes to this skill are documented here.

## [1.1.0] - 2026-11-08

### Fixed

- 推送成功却报失败：`$ErrorActionPreference='Stop'` 下 `git push` 的 stderr 被 PowerShell 5.1 当成终止错误，`$LASTEXITCODE` 未被判断；改为以远端 ref 是否包含本次 commit 判定，并输出远端 SHA。
- 自动生成的 `metadata.yaml` 非法 YAML：frontmatter 的 `\"` 未还原即被二次转义成 `\\"`；现在读取时解转义、写入时用 `ConvertTo-YamlString` 正确转义。
- 根 `CHANGELOG.md` 每次上传都新建 `### Added`，多次上传后堆出重复标题；改为追加到 `Unreleased` 下已有的 `### Added` 块。
- `-CheckRepo` 对新 skill 报 `MissingDocs: {}`（目标目录不存在即判"不缺"）；新增 `SourceMissingDocs`、`WillGenerate` 与 `SOURCE_MISSING_DOC`。
- 推送失败的原因只剩 `To https://...` 一行进度噪音；现在过滤进度行，保留 `fatal:` / `error:`。
- `hasOrigin` 判定用了 `^origin$`，复制来的仓库输出含 `\r` 导致恒为 false，进而跳过远端分支检测；现在先归一化 EOL。
- README 表格行的摘要未转义 `|`，描述里含竖线会切列。

### Added

- 克隆前的远程预检：`git ls-remote` 探测可达性；遇 `schannel` / `SEC_E_NO_CREDENTIALS` 自动用 `GIT_CONFIG_*` 注入 `http.sslBackend=openssl` 重试。
- 生成物自检：YAML 可解析、`summary` 引号成对、README 无 `\"` 残留、CHANGELOG 段内不重复 `### Added`；不通过就中止提交。
- 失败时保留临时克隆并打印路径（此前无条件删除，本地 commit 一起丢失）。
- `metadata.yaml` 的 `author` 依次回退：`-AuthorName` → 仓库 owner → `unknown`。
- 摘要生成会跳过「仅在用户明确调用时运行。」这类元描述句，并在标点处收口。

## [1.0.0] - 2026-11-04

### Added

- Initial release; docs generated to follow the repository convention.
