[English](README.md) | 日本語 | [简体中文](README.zh-CN.md)

# ドキュメント案内

このディレクトリには、現在の利用方法を説明する文書と、過去の設計判断を残す履歴資料があります。目的に応じて参照先を選んでください。

## 現在の仕様を確認する

| 文書 | 内容 |
|---|---|
| [プロジェクト概要](../README.ja.md) | 機能、導入方法、日常の利用方法 |
| [設定ガイド](configuration.md) | `.feedback/config.yaml` の設定方法とトラブルシューティング |
| [スクリプト仕様](../scripts/README.ja.md) | 各スクリプトの役割、実行内容、終了コード |
| [Codex / 汎用エージェント向け規約](pointer_agents.md) | Codex Plugin Hooks と手動フォールバックを両立する、導入先 AGENTS.md 用の規約 |
| [Claude Code 向け規約](pointer_claude.md) | Claude Code プラグインの Hooks と init-only の手動フォールバックを両立する、導入先 CLAUDE.md 用の規約 |

## 履歴資料を確認する

| ディレクトリ | 位置づけ |
|---|---|
| `proposals/` | 実装前の提案。未採用案や、後から変更された案を含む |
| `superpowers/specs/` | 設計時点の仕様と判断理由 |
| `superpowers/plans/` | 実装時の作業計画と検証手順 |
| `references/` | 設計の背景として参照した外部資料の翻訳・要約。現在収録している Feedback Flywheel は中国語訳（`zh-CN`） |

日付付きの履歴資料は、その時点の判断を保存することが目的です。現在の実装と異なる場合は、「現在の仕様を確認する」に挙げた文書と実装を優先してください。
