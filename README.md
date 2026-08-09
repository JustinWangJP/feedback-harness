# feedback-harness

Claude Code / Codex 両対応のフィードバックハーネス。2つのループを提供する:

1. **自動フィードバックループ** — lint / typecheck / test / build の結果をエージェントに自動で返し、自己修正させる
2. **人間フィードバックの蓄積** — レビュー指摘を記録・一般化し、次回以降のセッションに反映する

## 仕組み

| 環境 | 自動チェック | ルール反映 |
|------|-------------|-----------|
| Claude Code | Hooks (`.claude/settings.json`): 編集直後に `check_file.sh`、応答完了前に `check.sh`。失敗時はexit 2でエージェントに差し戻し | `apply-feedback` スキル + CLAUDE.md ポインタ |
| Codex ほか | AGENTS.md の規約: 変更ごとに `check_file.sh`、完了前に `check.sh` を実行 | AGENTS.md の規約で `.feedback/rules.md` を必読化 |

スクリプトとフィードバック蓄積(`.feedback/`)は両環境で完全共有。環境固有なのはエントリポイント(CLAUDE.md / AGENTS.md)とHooks設定だけ。

## 構成

```
scripts/
  check.sh          # スタック自動検出 (Python/Node/Go/Rust/Java/Make) → lint/test/build、要約出力
  check_file.sh     # 単一ファイルの高速チェック (拡張子ベース)
  feedback_log.py   # フィードバック記録CLI (add / list / search / promote / rules)
  hooks/            # Claude Code Hooks ラッパー (PostToolUse / Stop)
.claude/
  settings.json     # Hooks設定
  agents/           # feedback-curator (ルール昇華) / harness-qa (整合性検証)
  skills/           # feedback-loop (オーケストレーター) / capture-feedback / apply-feedback
.feedback/
  rules.md          # 一般化された恒久ルール (エージェント必読)
  log/              # 生のフィードバックエントリ (frontmatter付きMarkdown)
```

## 他プロジェクトへの導入

```bash
bash install.sh /path/to/your-project
cd /path/to/your-project && bash scripts/check.sh   # スタック検出の確認
```

既存の CLAUDE.md / AGENTS.md には追記、既存の settings.json には `.suggested` を生成する(手動マージ)。

## フィードバック運用フロー

```
人間の指摘 → feedback_log.py add (capture-feedbackスキル)
           → open エントリが溜まる
           → feedback-curator が一般化して promote (feedback-loopスキル)
           → .feedback/rules.md に追記
           → 次セッションの開始時に反映 (apply-feedbackスキル / AGENTS.md規約)
```
