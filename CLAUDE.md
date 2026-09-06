# feedback-harness — Claude Code 向け補足

## 共通規約

作業を始める前に [AGENTS.md](AGENTS.md) を読み、そこにある全エージェント共通の規約に従う。AGENTS.md が指定するフィードバック由来ルールと、作業に必要な参照文書も読む。

## Claude Code 固有の設定

このリポジトリの `.claude/settings.json` は開発用プラグインを有効化する。Hooks はプラグインの `hooks/hooks.json` が提供するため、`.claude/settings.json` に重複定義しない。
