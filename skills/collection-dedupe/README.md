# collection-dedupe

把网页收藏夹/合集/列表页的条目导出成 CSV，解析出原名、社团、编号等字段并聚类判定\"同款\"，输出带分组、判定依据、建议动作和待核清单的 xlsx。

> 模板: upload-skill-to-repo

## 何时使用

- 用户提到 `collection-dedupe`，或任务与它描述的场景一致。
- 需要一套固定流程，而不是每次临时发挥。

## 它做什么

详见 [`SKILL.md`](SKILL.md)。脚本与长文档在 `scripts/`、`references/` 下（如有）。

## 安装

把 `skills/collection-dedupe` 复制或链接到 agent 的 skills 目录：

```powershell
Copy-Item -Recurse .\skills\collection-dedupe "$env:DSH_HOME\skills\collection-dedupe"
```

## License

MIT。
