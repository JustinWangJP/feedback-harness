# feedback-harness

Claude Code / Codex 両対応のフィードバックハーネス。2つのループを提供する:

1. **自動フィードバックループ** — lint / typecheck / test / build の結果をエージェントに自動で返し、自己修正させる
2. **人間フィードバックの蓄積** — レビュー指摘や有効だった進め方を記録・一般化し、次回以降のセッションに反映する

## 仕組み

| 環境 | 自動チェック | ルール反映 |
|------|-------------|-----------|
| Claude Code(プラグイン導入) | Hooks(プラグインの `hooks/hooks.json` が提供): 編集直後に `check_file.sh`、応答完了前に `check.sh`(前回の成功検査以降に変更があるときだけ)。失敗時はexit 2でエージェントに差し戻し | `apply-feedback` スキル + CLAUDE.md ポインタ(プラグインが提供) |
| Codex ほか(`scripts/init.sh` で導入) | AGENTS.md の規約: 変更ごとに `check_file.sh`、完了前に `check.sh` をエージェント自身が実行 | AGENTS.md の規約で `.feedback/rules.md` を必読化 |

スクリプトとフィードバック蓄積(`.feedback/`)は両環境で完全共有。環境固有なのはエントリポイント(CLAUDE.md / AGENTS.md)と、Hooksの提供元(プラグイン、または `init.sh` 導入時はAGENTS.mdの手動規約)だけ。このリポジトリ自身の `.claude/settings.json` は開発用のHooks設定であり、導入先には配布されない(「構成」節を参照)。

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
  lib.sh            # 共有ユーティリティ (has / SHELLCHECK_SEVERITY / harness_project_root / harness_tree_changed)
  feedback_log.py   # フィードバック記録CLI (add / list / search / promote / merge / close / retire / rules)
  init.sh           # 導入スクリプト (Codex 向け資産の展開)
  hooks/            # Claude Code Hooks ラッパー (SessionStart / PostToolUse / Stop)
.feedback/
  rules.md          # 一般化された恒久ルール (エージェント必読)
  rules.template.md # rules.md のシード (導入時・再生成時に使う雛形)
  log/              # 生のフィードバックエントリ (frontmatter付きMarkdown)
  .last-check       # Stopフックの検査スタンプ (mtime比較用のローカル状態・gitignore対象)
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
[記録]  人間の指摘・修正 / 有効だった進め方 / 反復する check 失敗 / 完了前の自省
          → feedback_log.py add   (capture-feedback スキル / AGENTS.md規約)
             失敗系は根因を --detail に1行: 文脈欠落 | 指示欠陥 | モデル限界
                ↓
[open]  ├─ 昇華を待たず、次の作業の開始時に参照される (apply-feedback スキル)
        └─ feedback-curator が根因を見て昇華先を選ぶ (feedback-loop スキル)
             promote → .feedback/rules.md へ新規ルール      (指示欠陥・モデル限界)
             merge   → 既存ルールへ統合。再発なら文言を強化
             close   → 一般化できない一回限りの指摘を処理済みに
             提案    → CLAUDE.md 追記案 (文脈欠落) / lint・テスト追加案
                       ※ rules.md 以外は提案止まり、反映は人間が承認する
                ↓
[反映]  .feedback/rules.md → 次セッションの作業開始前に適用
                ↓
[棚卸]  定期審査 (feedback-loop Phase 4) → 陳腐化したルールは retire で撤去
```

記録は promote を待たずにその時点から次の作業に効く。「溜めてから一括で昇華する」設計にすると、昇華までの間に同じ指摘が再発する。

昇華先を rules.md に一本化しないのは、信号の種類ごとに直すべき制品が違うため — 知識の欠落はプライミング文書(CLAUDE.md)で埋め、機械的に検出できる失敗は散文のルールより lint・テストにした方が強い護欄になる(参考: [Feedback Flywheel](docs/references/fowler-feedback-flywheel-translation.md))。
