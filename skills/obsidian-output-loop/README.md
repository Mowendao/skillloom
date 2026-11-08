# obsidian-output-loop

仅在用户明确调用时运行。

> 模板: upload-skill-to-repo

## 何时使用

- 用户提到 `obsidian-output-loop`，或任务与它描述的场景一致。
- 需要一套固定流程，而不是每次临时发挥。

## 它做什么

详见 [`SKILL.md`](SKILL.md)。脚本与长文档在 `scripts/`、`references/` 下（如有）。

## 安装

把 `skills/obsidian-output-loop` 复制或链接到 agent 的 skills 目录：

```powershell
Copy-Item -Recurse .\skills\obsidian-output-loop "$env:DSH_HOME\skills\obsidian-output-loop"
```

## License

MIT。
