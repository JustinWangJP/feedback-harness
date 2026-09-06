[English](README.md) | [日本語](README.ja.md) | 简体中文

# 文档导航

本目录包含介绍当前使用方法的文档，以及保留过去设计决策的历史资料。请根据目的选择相应的参考资料。

## 查看当前规范

| 文档 | 内容 |
|---|---|
| [共通开发规则](../AGENTS.md) | 在本仓库工作的所有代理必须遵守的规则（日文） |
| [开发指南](development-guide.md) | 判断背景、实现示例与规则迁移对照表（日文） |
| [项目概览](../README.zh-CN.md) | 功能、安装方法和日常使用方法 |
| [配置指南](configuration.zh-CN.md) | `.feedback/config.yaml` 的配置方法和故障排除 |
| [脚本参考](../scripts/README.zh-CN.md) | 各脚本的职责、执行内容和退出码 |
| [面向 Codex 和通用代理的规则](pointer_agents.md) | 写入目标项目 AGENTS.md 的规则，同时支持 Codex Plugin Hooks 和手动回退流程 |
| [面向 Claude Code 的规则](pointer_claude.md) | 写入目标项目 CLAUDE.md 的规则，同时支持 Claude Code 插件 Hooks 和仅使用 init 的手动回退流程 |

## 查看历史资料

| 目录 | 定位 |
|---|---|
| [开发历史](history/development-history.md) (`history/`) | 按日期记录的开发决策和变更（日文） |
| `proposals/` | 实现前的提案，包括未采用的方案以及后来发生变更的方案 |
| `superpowers/specs/` | 设计时的规范和决策理由 |
| `superpowers/plans/` | 实现时的工作计划和验证步骤 |
| `references/` | 设计时参考的外部资料的翻译和摘要。目前收录的 Feedback Flywheel 为简体中文译文（`zh-CN`） |
| `../review/` | 带日期的代码评审记录。评审意见均已处理完毕，其中的数量和行号均为评审当时的快照 |

带日期的历史资料用于保存当时的决策。如果其内容与当前实现不一致，请以“查看当前规范”中列出的文档和实际实现为准。
