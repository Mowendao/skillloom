# collection-dedupe

把网页收藏夹 / 合集 / 列表页里「一堆标题混乱的条目」，变成按作品归组、可以直接照着删的 xlsx。

## 何时使用

- 给你一个收藏夹 / 合集 / 列表页，问「哪些是同一款」；
- 已经导出 CSV，要做去重；
- 说「同款判定」「挑出重复」「这些是不是同一款游戏」。

不适用：纯文本比较（没有结构化字段）、单条内容判断。

## 它做什么

1. **判断能不能直接抓**：DNS → TLS → 代理 → 无头浏览器逐层检查，遇到 Cloudflare 验证就改成「让用户在自己的浏览器里导出」。
2. **导出并核对**：浏览器控制台脚本自动滚动导出 CSV，同时核对「实际条数 vs 页面自报条数」，差额写进结论。
3. **解析字段**：从标题和卡片文本榨出 条目 id / 厂商编号 / 日文原名 / 社团 / 中文名 / 版本 / 容量 / 标签。
4. **聚类判定**：主键优先级为 厂商编号 > 日文原名 > 中文名+社团 > 包含关系 > 模糊相似；0.90 以上自动合并，0.80~0.90 只记为候选。
5. **输出判定表**：五表 xlsx —— 重复组汇总、重复组明细、全量明细、拿不准与待核、说明。

## 三条底线

- **中文译名不能当主键**：同一部作品可能有「极道无赖:横滨按摩店篇」=「情欲古式按摩店」这种完全不同的译名。
- **宁可标待核，不要硬判**：判错（删错文件）的代价远高于多留一条。
- **合集不是重复**：合集与其内含作品的单独帖是「包含关系」，不能按普通重复删除。

## 文件

| 文件 | 作用 |
|---|---|
| `SKILL.md` | 完整流程与判据（agent 读的） |
| `scripts/export_list.js` | 浏览器 Console 脚本：自动滚动到底、导出 CSV、打印捕获到的 API 接口表 |
| `scripts/dedupe.py` | 解析字段并聚类，产出 `rows.json` / `groups.json` |
| `scripts/make_xlsx.py` | 由上面两个 json 生成五表判定 xlsx |

## 典型流程

```text
用户在目标页 F12 → Console 粘贴 export_list.js → 得到 list.csv
python scripts/dedupe.py --csv list.csv --out ./work
python scripts/make_xlsx.py --rows work/rows.json --groups work/groups.json --out 去重判定.xlsx
```

## 安装

把 `skills/collection-dedupe` 复制或链接到 agent 的 skills 目录：

```powershell
Copy-Item -Recurse .\skills\collection-dedupe "$env:DSH_HOME\skills\collection-dedupe"
```

脚本依赖 Python 3 与 `openpyxl`。

## License

MIT。
