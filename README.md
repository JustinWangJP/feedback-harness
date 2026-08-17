# feedback-harness

Claude Code / Codex 両対応のフィードバックハーネス。2つのループを提供する:

1. **自動フィードバックループ** — lint / typecheck / test / build の結果をエージェントに自動で返し、自己修正させる
2. **人間フィードバックの蓄積** — レビュー指摘や有効だった進め方を記録・一般化し、次回以降のセッションに反映する

## 仕組み

| 環境 | 自動チェック | ルール反映 |
|------|-------------|-----------|
| Claude Code(プラグイン導入) | Hooks(プラグインの `hooks/hooks.json` が提供): 編集直後に `check_file.sh`、応答完了前に `check.sh`(前回の成功検査以降に変更があるときだけ)。失敗時はexit 2でエージェントに差し戻し。設定ファイル(JSON/YAML)の構文も横断的に検査し、宣言していない検査の指摘は WARN(非ブロッキング)として `events.jsonl` に記録される。秘密情報・内部リンク・依存整合性・CI設定も検査する(ツール未導入は SKIP。ハーネスがツールを勝手に導入することはない) | `apply-feedback` スキル + CLAUDE.md ポインタ(プラグインが提供) |
| Codex ほか(`scripts/init.sh` で導入) | AGENTS.md の規約: 変更ごとに `check_file.sh`、完了前に `check.sh` をエージェント自身が実行 | AGENTS.md の規約で `.feedback/rules.md` を必読化 |

スクリプトとフィードバック蓄積(`.feedback/`)は両環境で完全共有。環境固有なのはエントリポイント(CLAUDE.md / AGENTS.md)と、Hooksの提供元(プラグイン、または `init.sh` 導入時はAGENTS.mdの手動規約)だけ。このリポジトリ自身の `.claude/settings.json` は開発用のHooks設定であり、導入先には配布されない(「構成」節を参照)。

## 機能一覧

検査は**スタックを自動検出**して走る。設定は不要で、ツールが無ければ理由付きで `SKIP` する(勝手に導入しない)。

| ステージ | 検査内容 | 対象 |
|---|---|---|
| `lint` | 静的解析 | ruff / eslint / go vet / clippy / shellcheck・bash -n |
| `typecheck` | 型検査 | mypy(`[tool.mypy]` 宣言時)/ tsc |
| `test` | テスト(**カバレッジ計装を相乗り**) | pytest(`--cov`)/ go test `-cover` / npm `test:coverage` / cargo test / mvn verify |
| `build` | ビルド | go build / npm run build / cargo check |
| `format` | 整形崩れ | ruff format / prettier / gofmt / cargo fmt |
| `security` | 秘密情報の混入 | secretlint(`.secretlintrc.*` 宣言時)/ gitleaks |
| `docs` | Markdown の内部リンク切れ | 自前実装(python3 のみ) |
| `contract` | API の破壊的変更 | oasdiff(OpenAPI)/ cargo semver-checks(`[lib]` crate) |
| — | 設定ファイルの構文 | `*.json` / `*.yaml`(JSONC・複数文書YAMLを誤検出しない) |
| — | 依存の実在性・整合性 | npm ls / go mod verify / cargo metadata / deptry |
| — | CI設定・Dockerfile | actionlint / dockerfilelint・hadolint |
| — | デッドコード・アーキ制約 | vulture / knip / import-linter(いずれも宣言時) |

蓄積側の機能:

| 機能 | コマンド | 用途 |
|---|---|---|
| 指摘の記録 | `feedback_log.py add` | 人間の指摘・成功パターンをその場で記録(signal 付き) |
| ルール昇華 | `promote` / `merge` / `close` / `retire` | `rules.md` への昇華・統合・退役 |
| 測定 | `stats` | 初回通過率・平均再チェック回数・頻出WARN・**再発候補** |
| 報告 | `report` | 朝会/振り返り用の期間ダイジェスト(前期間との比較つき) |
| 脆弱性監査 | `audit.sh` | オンデマンド実行(唯一ネットワークを使う) |

## できること / できないこと

意図的に**やらない**ことがある。以下は設計判断であり、未実装ではない。

| できること | できないこと(と、その理由) |
|---|---|
| 検査失敗をエージェントに自動で差し戻し、自己修正させる | **完了の強制はしない** — WARN(宣言していない検査の指摘)は exit 0 のままで、ブロックするのは FAIL だけ |
| ツールがあれば使い、無ければ SKIP して理由を出す | **ツールを自動インストールしない**。環境を変える判断はユーザーのもの |
| オフラインで完結する検査を毎ターン走らせる | **`check.sh` はネットワークを使わない**。脆弱性監査だけは `audit.sh` に分離し、Stop フックからは呼ばない |
| カバレッジを計測する | **テストを2回走らせない**。既存の test コマンドに計装を足す(または `test:coverage` に差し替える)だけ |
| 破壊的変更を git ベースラインとの差分で検出する | **リモートを参照しない**。比較元は `git merge-base HEAD <既定ブランチ>`、解決できなければ `HEAD` |
| 指摘を記録し、次セッションで参照させる | **ルールの自動適用はしない**。`rules.md` 以外(CLAUDE.md 追記・lint 追加)は提案止まりで、反映は人間が承認する |
| 数字を出す(`stats` / `report`) | **ダッシュボードを作らない**。常駐プロセス・グラフ・外部送信はなく、要求時のテキスト出力のみ |
| 秘密情報を検出する | **値を出力しない**(secretlint は既定マスク、gitleaks は `--redact` 必須)。失敗ログはエージェントの文脈に入るため |

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
  check.sh          # スタック自動検出 (Python/Node/Go/Rust/Java/Shell/Make) → 8ステージ + 横断チェック
  check_file.sh     # 単一ファイルの高速チェック (拡張子ベース)
  audit.sh          # オンデマンド脆弱性監査 (唯一のネットワーク検査・Stopフック対象外)
  lib.sh            # 共有ユーティリティ (has / harness_project_root / harness_tree_changed /
                    #   harness_validate_json|yaml / harness_check_md_links / harness_log_event|warn)
  feedback_log.py   # フィードバック記録CLI (add / list / search / promote / merge / close /
                    #   retire / rules / stats / report)
  init.sh           # 導入スクリプト (Codex 向け資産の展開)
  hooks/            # Claude Code Hooks ラッパー (SessionStart / PostToolUse / Stop)
.feedback/
  rules.md          # 一般化された恒久ルール (エージェント必読・失敗由来/成功由来の2セクション)
  rules.template.md # rules.md のシード (導入時・再生成時に使う雛形)
  log/              # 生のフィードバックエントリ (frontmatter付きMarkdown)
  .last-check       # Stopフックの検査スタンプ (mtime比較用のローカル状態・gitignore対象)
  .last-retro       # 振り返りの基点 (report --mark が更新・gitignore対象)
  .last-audit       # 脆弱性監査の最終実行日 (audit.sh が成功時のみ更新・gitignore対象)
  events.jsonl      # フック合否とWARNのイベントログ (stats/report用のローカル状態・gitignore対象)
package.json        # 検査ツール(secretlint 等)を npx --no-install で解決するためだけの宣言
tests/              # bash テスト (make check → check.sh から自動実行される)
docs/
  pointer_claude.md # 導入先の CLAUDE.md へ追記する断片
  pointer_agents.md # 導入先の AGENTS.md へ追記する断片
  superpowers/      # 設計書 (specs/) と実装計画 (plans/)
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

### 導入形態ごとの配布物

| 資産 | プラグイン | `init.sh` |
|---|---|---|
| `scripts/check.sh` `check_file.sh` `audit.sh` `lib.sh` `feedback_log.py` | プラグイン側に置かれ `${CLAUDE_PLUGIN_ROOT}` 経由で実行 | 導入先の `scripts/` に実体をコピー |
| Hooks(`hooks.json`) | ○ 自動起動 | ✗(AGENTS.md の規約が代替) |
| skills / agents / commands | ○ | ✗(Claude Code 専用のため) |
| `scripts/hooks/*`・`init.sh` 自身 | ○ | ✗ |
| `.feedback/`(蓄積データ) | SessionStart フックが初回シード | `init.sh` がシード |
| `CLAUDE.md` / `AGENTS.md` ポインタ | CLAUDE.md ポインタのみ | 両方(既存なら追記・重複しない) |

### 更新

| 導入形態 | 更新方法 |
|---------|---------|
| プラグイン | 自動(Claude Code がマーケットプレイスを `git pull` する) |
| `init.sh` でベンダリングした `scripts/` | `init.sh` を再実行する(冪等)。**新しいスクリプトが増えた場合も再実行で追従する** |

## 使い方

### 日常の開発(Claude Code)

自動で走るため、通常は**何も実行しなくてよい**。ファイルを編集すれば `check_file.sh` が、応答を終えようとすれば `check.sh` が動く。失敗は自動でエージェントに差し戻される。

明示的に使うのは次の場面:

```bash
bash scripts/check.sh                    # 完了前の全体確認(CIでも同じものを使う)
bash scripts/check.sh /path/to/project   # 別プロジェクトを検査
FEEDBACK_CHECK_SKIP="test build" bash scripts/check.sh   # 重いステージを外す
bash scripts/audit.sh                    # 脆弱性監査(ネットワークを使うので手動)
```

### 指摘を記録する

```bash
# 人間から指摘を受けたとき(失敗系は根因を1行添える)
python3 scripts/feedback_log.py add --category style --source human \
  --summary "エラーメッセージは日本語で書く" --detail "根因: 指示欠陥"

# 効いた進め方・措辞を残すとき(signal は省略時に推論される)
python3 scripts/feedback_log.py add --category workflow --source agent \
  --summary "設計を固めてから実装すると手戻りが無い"
```

Claude Code では `capture-feedback` スキルが同じことを行うため、コマンドを直接叩く必要はない。

### 溜まった指摘を整理する

```bash
python3 scripts/feedback_log.py list                    # open エントリ一覧
python3 scripts/feedback_log.py list --signal failure   # 失敗系だけ絞る
python3 scripts/feedback_log.py promote <id> --rule "<一般化した1行>"
python3 scripts/feedback_log.py merge <id> --into <既存ルールの出典id>   # 再発時
python3 scripts/feedback_log.py retire <出典id> --reason "<退役理由>"    # 棚卸し
```

### 効果を測る・共有する

```bash
python3 scripts/feedback_log.py stats                 # 初回通過率・再発候補・最終監査日
python3 scripts/feedback_log.py report --since yesterday   # 朝会の1問
python3 scripts/feedback_log.py report --last --mark       # 振り返り後に基点を更新
```

### 環境変数

| 変数 | 既定 | 効果 |
|---|---|---|
| `FEEDBACK_CHECK_SKIP` | (空) | 空白区切りでステージを除外(`lint typecheck test build format security docs contract`) |
| `FEEDBACK_SHELLCHECK_SEVERITY` | `warning` | shellcheck の重大度しきい値。`style` で厳しくする |
| `FEEDBACK_CONTRACT_BASE` | `main` | API 契約差分のベースラインブランチ |
| `CLAUDE_PROJECT_DIR` | (自動) | 検査対象・状態保存先のルート。フックが設定する |

## フィードバック運用フロー

```
[記録]  人間の指摘・修正 / 有効だった進め方 / 反復する check 失敗 / 完了前の自省
          → feedback_log.py add   (capture-feedback スキル / AGENTS.md規約)
             失敗系は根因を --detail に1行: 文脈欠落 | 指示欠陥 | モデル限界
             signal(--signal)も添える: 省略時は根因と category から推論される
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
[測定]  feedback_log.py stats            — 初回通過率・再発候補(要求時のみ・テキスト出力)
[報告]  feedback_log.py report --last → 朝会/振り返りの5分議題(実施後に --mark で基点更新)
[監査]  bash scripts/audit.sh          — 脆弱性監査(オンデマンド・ネットワーク使用)
                                          成功時のみ .last-audit を更新 → report が期限を見る
```

記録は promote を待たずにその時点から次の作業に効く。「溜めてから一括で昇華する」設計にすると、昇華までの間に同じ指摘が再発する。

測定は Flywheel の「衡量变化」に相当する。ダッシュボードは作らない — `stats` は要求時のテキスト出力で、数字は `report` の「数字」セクションにだけ現れる。`events.jsonl`(フック合否)と `.last-retro`(振り返り基点)はマシンローカルの状態であり、git で共有しない。

昇華先を rules.md に一本化しないのは、信号の種類ごとに直すべき制品が違うため — 知識の欠落はプライミング文書(CLAUDE.md)で埋め、機械的に検出できる失敗は散文のルールより lint・テストにした方が強い護欄になる(参考: [Feedback Flywheel](docs/references/fowler-feedback-flywheel-translation.md))。
