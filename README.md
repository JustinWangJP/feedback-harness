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
.claude-plugin/
  plugin.json       # プラグイン定義
  marketplace.json  # カタログ(このリポジトリ自身を配布する)
skills/             # feedback-loop (オーケストレーター) / capture-feedback / apply-feedback
agents/             # feedback-curator (ルール昇華) / harness-qa (整合性検証)
commands/
  init.md           # /feedback-harness:init — Codex 向け資産の展開
hooks/
  hooks.json        # 配布用 Hooks 定義 (${CLAUDE_PLUGIN_ROOT} 基準)
scripts/
  check.sh          # スタック自動検出 (Python/Node/Go/Rust/Java/Shell/Make) → lint/test/build、要約出力
  check_file.sh     # 単一ファイルの高速チェック (拡張子ベース)
  lib.sh            # 共有ユーティリティ (has / SHELLCHECK_SEVERITY / harness_project_root)
  feedback_log.py   # フィードバック記録CLI (add / list / search / promote / rules)
  init.sh           # 導入スクリプト (Codex 向け資産の展開)
  hooks/            # Claude Code Hooks ラッパー (SessionStart / PostToolUse / Stop)
.feedback/
  rules.md          # 一般化された恒久ルール (エージェント必読)
  rules.template.md # rules.md のシード (導入時・再生成時に使う雛形)
  log/              # 生のフィードバックエントリ (frontmatter付きMarkdown)
tests/              # bash テスト (make check → check.sh から自動実行される)
docs/
  pointer_claude.md # 導入先の CLAUDE.md へ追記する断片
  pointer_agents.md # 導入先の AGENTS.md へ追記する断片
.claude/
  settings.json     # このリポジトリ自身の開発用 Hooks (配布対象外)
```

ハーネス自身も `check.sh` の検査対象になる(`*.sh` と `*.py` を検出)。

## 他プロジェクトへの導入

### Claude Code だけで使う場合

```
/plugin marketplace add JustinWangJP/feedback-harness
/plugin install feedback-harness@feedback-harness
```

導入先に置かれるのは `.feedback/`(蓄積データ)だけ。スクリプト・スキル・エージェント・Hooks はプラグイン側にあり、マーケットプレイスの自動更新で追従する。

チーム全員に配りたい場合は、導入先の `.claude/settings.json` に次を書いておくと、フォルダを信頼した時点でインストールを促される:

```json
{
  "extraKnownMarketplaces": {
    "feedback-harness": {
      "source": { "source": "github", "repo": "JustinWangJP/feedback-harness" }
    }
  }
}
```

### Codex や他の汎用エージェントも使う場合

Claude Code から:

```
/feedback-harness:init
```

Claude Code を使わない場合は直接:

```bash
git clone https://github.com/JustinWangJP/feedback-harness
bash feedback-harness/scripts/init.sh /path/to/your-project
cd /path/to/your-project && bash scripts/check.sh   # スタック検出の確認
```

`scripts/` と `AGENTS.md` が導入先に展開される。`CLAUDE.md` / `AGENTS.md` が既存なら `docs/pointer_*.md` の断片を追記する(重複追記はしない)。`.feedback/rules.md` は空のテンプレートから始まる。

### 更新

| 導入形態 | 更新方法 |
|---------|---------|
| プラグイン | 自動(Claude Code がマーケットプレイスを `git pull` する) |
| `init.sh` でベンダリングした `scripts/` | `init.sh` を再実行する(冪等) |

## フィードバック運用フロー

```
人間の指摘 → feedback_log.py add (capture-feedbackスキル)
           → open エントリが溜まる
           → feedback-curator が一般化して promote (feedback-loopスキル)
           → .feedback/rules.md に追記
           → 次セッションの開始時に反映 (apply-feedbackスキル / AGENTS.md規約)
```
