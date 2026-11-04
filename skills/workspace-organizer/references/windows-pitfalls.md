# Windows 迁移陷阱与处理

## 1. 「拒绝访问」但 ACL 看起来正常：完整性级别

DSH 在 Windows 上以低完整性级别（Low Mandatory Level）运行文件操作。移动一个由沙箱外进程创建的中完整性文件（例如用户手动下载、Office 保存、资源管理器解压出来的文件）时，`Move-Item` 会报：

```
Access to the path is denied.
```

单纯看 `Get-Acl` 可能一切正常，因为缺的是 mandatory label 的写权限，不是 DACL。

**判断**

```powershell
whoami /groups | Select-String 'Mandatory|S-1-16'
cmd /c 'icacls "路径"'
```

- 低完整性文件通常带 `Mandatory Label\Low Mandatory Level:(I)(NW)`。
- 中完整性文件不显示 label，或显示 Medium。

**处理**

用一次更宽的沙箱重试同一批移动，并在说明里写清原因：

- 工具调用参数 `sandbox_permissions: danger-full-access`
- 只重试失败项，不要重跑已成功的部分。

不要用「复制到新文件、再删原文件」绕过：低完整性进程通常也删不掉原文件，而且会留下两份。

## 2. 文件被占用

典型占用者：浏览器（Firefox/Chrome 打开本地 `index.html`）、Office、VS Code、图片查看器、资源管理器预览、杀毒软件、OneDrive 同步。

**判断**

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like '*<路径片段>*' } |
  Select-Object ProcessId, Name, CommandLine
```

目录被占用时，整个目录无法重命名，即使只有一个子文件被打开。

**处理**

- 请用户关闭对应标签页/文档，然后重试。
- 不要直接 `Stop-Process` 杀掉浏览器或编辑器：可能丢失未保存内容。
- 只有用户明确同意时才结束进程。

## 3. 部分移动造成 `name\name` 嵌套

`Move-Item` 在目标已存在时，可能把源目录放进目标内部，形成：

```
目标\name\name\
```

第一次执行失败后重试时尤其常见。

**检查**

```powershell
Get-ChildItem -LiteralPath <root> -Directory -Recurse -Force |
  Where-Object { $_.Parent -and $_.Name -eq $_.Parent.Name }
```

**修复**

1. 确认内层目录为空（或内容已在正确位置）。
2. 删除空的内层/外层目录（仅在确认无误后）。
3. 重新移动源目录到目标路径。

不要直接再次 `Move-Item` 到已存在的目标，否则会继续嵌套。

## 4. ACL 拒绝

如果列目录或写文件失败，且不是完整性级别问题，可能是 DACL 异常。症状：

- `Get-ChildItem` 报拒绝访问。
- 目标目录存在 `Everyone Deny DeleteSubdirectoriesAndFiles`。
- 工作区里有 `.acl-recovery`。

此时加载 `diagnose-windows-sandbox-acl` skill，让 bundled 命令检查路径及所有祖先并修复。不要手动 `icacls /reset` 整个盘。

## 5. 路径与命名

- 一律使用 `-LiteralPath`；`[`、`]`、`*`、`?` 在 `-Path` 下会被当成通配符。
- 中文、空格、`~`、括号、`&` 都是合法字符，不要为了“安全”批量改名。
- 避免路径长度超过 260 字符；深层 node_modules 常见。必要时用 `\\?\` 前缀，或先移动上层目录。
- 目标路径必须以工作区根目录开头；`organize.ps1` 会检查，不要绕过。

## 6. 编码

- Windows PowerShell 5.1 读取无 BOM 的 UTF-8 脚本会按 ANSI 解码，中文变乱码。脚本文件要么保持纯 ASCII，要么保存为 UTF-8 with BOM。
- 项目里的 `.py`/`.js` 可能是 GBK 或 UTF-8。**不要**用 `Get-Content`/`Set-Content` 批量改写内容；只移动文件。
- CSV 用 `Export-Csv -Encoding UTF8`（5.1 会写 BOM），Excel 打开中文才正常。
- JSON 用 `ConvertTo-Json | Set-Content -Encoding UTF8`。

## 7. 符号链接、junction 与跨卷

- 移动前检查 `LinkType`：

```powershell
Get-Item -LiteralPath <path> -Force | Select-Object Name, LinkType, Target
```

- junction/符号链接指向工作区外时，不要跟随、不要递归统计，避免统计到别的盘。
- 跨卷移动是「复制 + 删除」，速度慢且可能中断；尽量在同一卷内整理。
- 移动失败时不要假定源还在：检查源和目标两侧。

## 8. 大目录与耗时

- `Get-ChildItem -Recurse` 统计几万个文件可能很慢；先用 `-Depth 1` 看结构，再决定是否递归。
- `_work`、`node_modules`、`galgame-assets` 这类大目录整体移动是秒级的（同卷重命名），不要逐文件复制。
- 移动前关闭正在写入的进程；移动后校验文件数。

## 9. 完成后检查清单

- [ ] 每个目标存在，每个源不存在。
- [ ] 没有 `x\x` 嵌套。
- [ ] 根目录只剩分类目录、系统目录、`整理说明.md`。
- [ ] 迁移清单、回滚脚本、inventory/plan/summary 都在记录目录。
- [ ] 受影响的脚本路径已列给用户，但没有擅自改写。
- [ ] 重复文件已归档而不是删除。
- [ ] 被占用/失败项已单独说明，没有静默忽略。

## 10. 原子写入与临时文件

生成大文件、二进制、Office 文档或导出物时，直接写最终路径可能留下半个文件。推荐：

1. 先写到 `99_临时与杂项/tmp/<task-id>/` 下；
2. 校验大小、哈希、可打开、页数/工作表数量；
3. 再用 `Move-Item -LiteralPath` 移到 `_产出/`。

如果最终路径已存在，先走 `preflight.ps1` 决定版本号，不要先覆盖再补备份。

文本文件写入后至少读回一次：确认非空、编码正确、开头/结尾没有被截断。编辑大文件时优先用定点替换，避免整文件重写。

## 11. 审计脚本的边界

`audit.ps1` 只检查文件系统层面的规范，不理解业务语义：

- 它会把项目自带目录（如 `fullsave`、`src`）报为 `top-dir-name`，这时应由人判断是改编号还是加例外。
- 它不判断两个文件是否真的重复，只按文件名和位置报告；重复判定用 SHA256。
- 它不检查 `_输入/` 是否被修改；需要对比哈希或备份。
- 它默认跳过受保护目录；如果项目目录本身叫 `dist`/`build`，审计不会进入，这是有意的。

不要把「通过 audit」当成业务正确性的证明；它只证明目录和命名符合本规范。

