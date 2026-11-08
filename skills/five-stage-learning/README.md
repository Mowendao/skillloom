# five-stage-learning

用斯科特·杨的五阶段（获取/理解/扩展/应用/纠错）带用户在 DSH 里学一个具体知识点：每阶段给出目标、步骤、可复制的提问和出口条件；概念型知识用费曼讲解验证，扩展阶段用跨领域同构。

> 模板: upload-skill-to-repo

## 何时使用

- 用户提到 `five-stage-learning`，或任务与它描述的场景一致。
- 需要一套固定流程，而不是每次临时发挥。

## 它做什么

详见 [`SKILL.md`](SKILL.md)。脚本与长文档在 `scripts/`、`references/` 下（如有）。

## 安装

把 `skills/five-stage-learning` 复制或链接到 agent 的 skills 目录：

```powershell
Copy-Item -Recurse .\skills\five-stage-learning "$env:DSH_HOME\skills\five-stage-learning"
```

## License

MIT。
