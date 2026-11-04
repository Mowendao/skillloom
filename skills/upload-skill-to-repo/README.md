# upload-skill-to-repo

把一个已安装的 skill（按名字从 DSH 的 skill 根目录查找，默认全局 ~/.

> 模板: upload-skill-to-repo

## 何时使用

- 用户提到 `upload-skill-to-repo`，或任务与它描述的场景一致。
- 需要一套固定流程，而不是每次临时发挥。

## 它做什么

详见 [`SKILL.md`](SKILL.md)。脚本与长文档在 `scripts/`、`references/` 下（如有）。

## 安装

把 `skills/upload-skill-to-repo` 复制或链接到 agent 的 skills 目录：

```powershell
Copy-Item -Recurse .\skills\upload-skill-to-repo "$env:DSH_HOME\skills\upload-skill-to-repo"
```

## License

MIT。
