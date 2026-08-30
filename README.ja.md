[English](README.md) | 日本語 | [简体中文](README.zh-CN.md)

# feedback-harness

Claude Code と Codex の両方で使えるフィードバックハーネスです。次の2つの仕組みを提供します。

1. **自動フィードバックループ** — lint / typecheck / test / build の結果をエージェントへ自動で返し、問題を自分で修正できるようにする
2. **人間フィードバックの蓄積** — レビューで受けた指摘や有効だった進め方を記録して共通ルールにまとめ、次回以降の作業に反映する

## 必要な環境

- **必須:** `bash`、Python 3.10 以上（`python3` または `python`）
- **任意:** プロジェクトで使う lint、型検査、テスト、ビルドなどのツール

任意のツールは、すでに導入されているものだけを使います。見つからないツールは理由を示して `SKIP` し、ハーネスが自動でインストールすることはありません。

Windows では Git for Windows に付属する **Git Bash** を使います。既存の `*.sh` を Git Bash からそのまま実行し、`python3` が無ければ `python` を自動選択します。通常の利用に PowerShell 用スクリプトは不要です。

### このリポジトリの開発

このリポジトリ自身の検査依存は、ハーネスの実行要件とは分けてバージョン固定しています。`make install-dev-tools` を実行すると、`requirements-dev.txt` の PyYAMLとRuff、`scripts/dev_tool_versions.sh` で宣言したactionlintを、リポジトリ内の `.venv` へ導入します。`scripts/check.sh` を直接実行する前は、Linux/macOS では `source .venv/bin/activate`、Windows の Git Bash では `source .venv/Scripts/activate` を実行してください。`make test` はこのローカルツールを自動的に優先します。Linux CI は固定した検査ツールを確認し、Windows CI は Git Bash と Windows Python で同じ回帰テストを実行します。導入先プロジェクトでハーネスがツールを自動インストールすることはありません。

## 仕組み

| 環境 | 自動チェック | ルール反映 |
|------|-------------|-----------|
| Claude Code（プラグイン導入） | プラグインの `hooks/hooks.json` が Hooks を提供する。ファイルを編集した直後に `check_file.sh`、応答を終える前に `check.sh` を実行する（`check.sh` は、前回の検査成功後に変更がある場合のみ実行）。失敗時は exit code 2 で結果をエージェントへ返す。設定ファイル（JSON/YAML）の構文、秘密情報、内部リンク、依存関係、CI 設定も検査する。設定で明示していない検査の指摘は WARN（処理を止めない警告）として `events.jsonl` に記録する。必要なツールが入っていない場合は SKIP とし、ハーネスが自動でインストールすることはない | `apply-feedback` スキルが `.feedback/rules.md` と未整理の指摘を読む |
| Claude Code（`init.sh` のみ） | CLAUDE.md の規約に従い、変更ごとに `check_file.sh`、完了前に `check.sh` をエージェント自身が実行する | CLAUDE.md の規約により、作業前に `.feedback/rules.md` と未整理の指摘を読む |
| Codex（プラグイン導入） | 同じ `hooks/hooks.json` を Codex Hooks として読み込む。`apply_patch` のパッチ内容から対象ファイルを見つけてすぐに検査し、Stop の前に全体を検査する | `apply-feedback` スキルが `.feedback/rules.md` と未整理の指摘を読む |
| Codex IDE 拡張・汎用エージェント（`scripts/init.sh` で導入） | AGENTS.md の規約に従い、変更ごとに `check_file.sh`、完了前に `check.sh` をエージェント自身が実行する | AGENTS.md の規約により、作業前に `.feedback/rules.md` を必ず読む |

フィードバックは、どの環境でも各プロジェクトの `.feedback/` に保存します。Claude Code、ChatGPT デスクトップアプリの Codex、Codex CLI では、プラグインの Hooks が検査を自動実行します。`init.sh` だけで導入する場合は、Claude Code では CLAUDE.md、Codex IDE 拡張や汎用エージェントでは AGENTS.md の規約に従い、エージェント自身が検査を実行します。Codex では、初回に `/hooks` を開いて内容を確認し、信頼済みとして有効にする必要があります。このリポジトリの `.claude/settings.json` は Claude Code で開発するための設定であり、導入先には配布されません。

## 機能一覧

検査は、プロジェクトの**技術スタックを自動検出**して実行します。事前設定は不要です。必要なツールがなければ理由を示して `SKIP` し、自動でインストールすることはありません。

| ステージ | 検査内容 | 対象 |
|---|---|---|
| `lint` | 静的解析 | ruff / eslint / go vet / clippy / shellcheck・bash -n |
| `typecheck` | 型検査 | mypy(`[tool.mypy]` 宣言時)/ tsc |
| `test` | テスト（既存のテスト実行に**カバレッジ計測を追加**） | pytest(`--cov`)/ go test `-cover` / npm `test:coverage` / cargo test / `./mvnw` または `mvn verify` |
| `build` | ビルド | go build / npm run build / cargo check |
| `format` | コード整形のずれ | ruff format / prettier / gofmt / cargo fmt |
| `security` | 秘密情報の混入 | secretlint(`.secretlintrc.*` 宣言時)/ gitleaks |
| `docs` | Markdown の内部リンク切れ | 自前実装(Python のみ) |
| `contract` | API の破壊的変更 | oasdiff(OpenAPI)/ cargo semver-checks(`[lib]` crate) |
| — | 設定ファイルの構文 | `*.json` / `*.yaml`(JSONC・複数文書YAMLを誤検出しない) |
| — | 依存関係の存在・整合性 | npm ls / go mod verify / cargo metadata / deptry |
| — | CI設定・Dockerfile | actionlint / dockerfilelint・hadolint |
| — | 未使用コード・アーキテクチャ制約 | vulture / knip / import-linter(いずれも宣言時) |

フィードバックを蓄積する機能は次のとおりです。

| 機能 | コマンド | 用途 |
|---|---|---|
| 指摘の記録 | `feedback.sh add` | 人間からの指摘や、うまくいった進め方をその場で記録（signal も保存） |
| ルール化 | `promote` / `merge` / `close` / `retire` | `rules.md` へのルール追加・統合・処理済み化・廃止 |
| 測定 | `stats` | この作業コピー内だけの初回通過率・平均再チェック回数・よく出る WARN・**再発候補** |
| 報告 | `report` | この作業コピー内だけの、朝会や振り返りに使う期間別の要約（前の期間との比較付き） |
| 脆弱性監査 | `audit.sh` | 必要なときだけ実行（ハーネスが意図して通信する専用処理） |

curator が `rules.md` 以外への自動化を提案するときは、`automation_candidates`（`candidate` / `evidence` / `recommended_check` / `human_decision`）という構造化契約を使い、人間が承認するまで保留にする。

## できること / できないこと

このハーネスには、意図的に**行わないこと**があります。以下は未実装の機能ではなく、設計上の判断です。

| できること | できないこと(と、その理由) |
|---|---|
| 検査の失敗をエージェントへ自動で返し、問題を自分で修正できるようにする | **完了を強制しない** — WARN（設定で明示していない検査の指摘）は exit 0 のままとし、処理を止めるのは FAIL だけ |
| ツールがあれば使い、なければ SKIP して理由を示す | **ツールを自動インストールしない**。環境を変更するかどうかはユーザーが決める |
| 依存取得やリモート参照をハーネス側から追加せず検査する | **`check.sh` 自身は意図的なネットワークアクセスを開始しない**。ただし、プロジェクト定義のコマンドや外部ツールは設定に応じて通信する場合がある。脆弱性監査は `audit.sh` に分離し、Stop フックからは呼ばない |
| カバレッジを計測する | **テストを2回実行しない**。既存の test コマンドにカバレッジ計測を追加する（または `test:coverage` に切り替える）だけ |
| 破壊的変更を git ベースラインとの差分で検出する | **リモートを参照しない**。比較元は `git merge-base HEAD <既定ブランチ>`、解決できなければ `HEAD` |
| `apply-feedback` スキルが記録済みの指摘を読み、次の作業へ反映する | **共有ファイルを無断で書き換えない**。`rules.md` 以外への変更（CLAUDE.md への追記・lint の追加）は提案のみとし、人間が承認してから反映する |
| 数値を出す（`stats` / `report`） | **ダッシュボードを作らない**。バックグラウンドで動き続ける処理やグラフ、外部へのデータ送信は行わず、求められたときだけテキストで出力する |
| 秘密情報を検出する | **値そのものは出力しない**（secretlint は標準でマスクし、gitleaks では `--redact` を必須にする）。失敗ログはエージェントへ渡されるため |

## 構成

```
.claude-plugin/
  plugin.json       # Claude Code プラグイン定義
  marketplace.json  # Claude Code のマーケットプレイス兼 Codex 互換カタログ
.codex-plugin/
  plugin.json       # Codex プラグイン定義
skills/             # feedback-loop (オーケストレーター) / capture-feedback / apply-feedback
agents/             # feedback-curator (ルール化) / harness-qa (整合性検証)
commands/
  init.md           # /feedback-harness:init — Hooks 非対応環境向け資産の展開
hooks/
  hooks.json        # Claude Code / Codex 共通の配布用 Hooks 定義
scripts/
  check.sh          # スタック自動検出 (Python/Node/Go/Rust/Java/Shell/Make) → 8ステージ + 横断チェック
  checks/*.sh       # stack・横断runner（共通実行coreはcheck.shに残す）
  check_file.sh     # 単一ファイルの高速チェック (拡張子ベース)
  audit.sh          # 必要なときに実行する脆弱性監査 (意図的に通信する専用検査・Stopフック対象外)
  lib.sh            # 共有ユーティリティ (has / harness_project_root / harness_tree_changed /
                    #   harness_node_pm / harness_validate_json|yaml / harness_check_md_links /
                    #   harness_log_event|warn)
  harness_config.py # .feedback/config.yaml の読み込みと検査設定の解決
  feedback_store.py # repository lock・atomic write・中断transaction回復
  feedback.sh       # OS共通のフィードバックCLI入口（Python executableを解決）
  feedback_log.py   # フィードバックCLI実装 (add / list / search / promote / merge / close /
                    #   retire / rules / stats / report)
  init.sh           # 導入スクリプト (Hooks 非対応環境向け資産の展開)
  README.md         # 各スクリプトの詳しい仕様と必要ツール
  README.ja.md      # スクリプト仕様の日本語版
  README.zh-CN.md   # スクリプト仕様の簡体字中国語版
  hooks/            # Claude Code / Codex Hooks ラッパー (SessionStart / PostToolUse / Stop)
.feedback/
  rules.md          # 一般化された恒久ルール (エージェント必読・失敗由来/成功由来の2セクション)
  rules.template.md # rules.md の初期ファイル (導入時・再生成時に使う雛形)
  config.yaml       # プロジェクト設定 (任意・Git にコミットして共有。config.example.yaml から始める)
  config.example.yaml # config.yaml の雛形 (全項目をコメント付きで並べたもの)
  local/config.yaml # この端末だけの個人設定 (共有設定より優先・Git 管理外)
  log/              # 記録したフィードバック (先頭にメタデータを持つ Markdown)
  .last-check       # Stop フックの検査記録 (更新日時の比較に使うローカル状態・Git 管理外)
  .last-retro       # 振り返り期間の開始点 (report --mark が更新・Git 管理外)
  .last-audit       # 脆弱性監査の最終実行日 (audit.sh が成功した場合のみ更新・Git 管理外)
  .state.lock       # feedback CLIのrepository-wide lock (永続・Git管理外)
  .transaction.json # 中断した更新を回復するjournal (通常完了時は存在しない・Git管理外)
  events.jsonl      # フックの実行結果と WARN のログ (stats/report 用のローカル状態・Git 管理外)
package.json        # 検査ツール(secretlint 等)を npx --no-install で解決するためだけの宣言
tests/              # bash テスト (make check → check.sh から自動実行される)
docs/
  README.md         # ドキュメント案内 (現在の仕様と履歴資料の索引)
  README.ja.md      # ドキュメント案内の日本語版
  README.zh-CN.md   # ドキュメント案内の簡体字中国語版
  configuration.md  # 設定ガイド (config.yaml の全項目とトラブルシューティング)
  configuration.ja.md    # 設定ガイドの日本語版
  configuration.zh-CN.md # 設定ガイドの簡体字中国語版
  pointer_claude.md # 導入先の CLAUDE.md に追加する案内文
  pointer_agents.md # 導入先の AGENTS.md に追加する案内文
  proposals/        # 実装前の提案 (履歴資料)
  references/       # 設計の背景として参照した外部資料 (履歴資料)
  superpowers/      # 設計書 (specs/) と実装計画 (plans/) — 履歴資料
review/             # 日付付きのコードレビュー記録 (履歴資料)
.claude/
  settings.json     # このリポジトリでプラグインを有効化する開発用設定 (配布対象外)
```

ハーネス自身も `check.sh` の検査対象です（`*.sh` と `*.py` を検出します）。

### ドキュメントの位置づけ

現在の使い方は、この README、[設定ガイド](docs/configuration.ja.md)、[スクリプト仕様](scripts/README.ja.md)を参照してください。日付付きの `docs/proposals/`・`docs/superpowers/`・`review/` は、提案・設計・レビューを行った時点の判断を残す履歴資料です。現在の仕様と内容が異なる場合は、先に挙げた3つの文書と実装を優先してください。文書の一覧は[ドキュメント案内](docs/README.ja.md)にまとめています。

Codex 側の現在の仕様は、OpenAI 公式の[プラグイン利用ガイド](https://learn.chatgpt.com/docs/plugins)、[プラグインのパッケージ仕様](https://developers.openai.com/plugins/build/plugins)、[Hooks 仕様](https://developers.openai.com/codex/hooks)を参照してください。Claude Code 側は、Anthropic 公式の[プラグイン導入ガイド](https://code.claude.com/docs/en/discover-plugins)を参照してください。

## 他プロジェクトへの導入

### Claude Code だけで使う場合

```
/plugin marketplace add JustinWangJP/feedback-harness
/plugin install feedback-harness@feedback-harness
```

導入先に置かれるのは、蓄積データを保存する `.feedback/` だけです。スクリプト、スキル、エージェント、Hooks はプラグイン側にあります。Anthropic 公式以外のマーケットプレイス（第三者マーケットプレイス）は、自動更新が標準では無効です。利用者が自動更新を有効にした場合にのみ、起動時に最新版へ更新されます。

チーム全員に配布する場合は、導入先の `.claude/settings.json` に次の設定を書きます。利用者がフォルダを信頼すると、プラグインのインストールが案内されます。

```json
{
  "extraKnownMarketplaces": {
    "feedback-harness": {
      "source": { "source": "github", "repo": "JustinWangJP/feedback-harness" },
      "autoUpdate": true
    }
  }
}
```

### ChatGPT デスクトップアプリの Codex / Codex CLI で使う場合

```bash
codex plugin marketplace add JustinWangJP/feedback-harness
```

マーケットプレイスを登録したら、次のどちらかでプラグインをインストールします。

- ChatGPT デスクトップアプリでは「Plugins」を開き、`feedback-harness` をインストールする
- Codex CLI では `/plugins` を開き、`feedback-harness` をインストールして有効にする

インストール後は新しいセッションを開始します。Codex で `/hooks` を開き、`SessionStart` / `PostToolUse` / `Stop` の各 Hook の内容を確認して、信頼済みとして有効にしてください。Codex IDE 拡張はプラグインに対応していないため、次の `init.sh` を使います。

### `init.sh` で手動運用する場合（Claude Code / Codex IDE 拡張 / 汎用エージェント）

Claude Code プラグインから `init.sh` を併用する場合:

```
/feedback-harness:init
```

プラグインを使わない場合、または Claude Code 以外から導入する場合は直接:

```bash
git clone https://github.com/JustinWangJP/feedback-harness
bash feedback-harness/scripts/init.sh /path/to/your-project
cd /path/to/your-project && bash scripts/check.sh   # スタック検出の確認
```

導入先の `scripts/` にスクリプト一式がコピーされます。`CLAUDE.md` / `AGENTS.md` はコピーではなく、feedback-harness が管理する範囲を示すコメント（管理マーカー）付きの案内文を追記します（ファイルが無ければ作成します）。`init.sh` を再実行すると、管理マーカーの内側だけを最新版に置き換え、外側にある利用者の記述は残します。`.feedback/rules.md` は空のテンプレートから始まります。

### 導入形態ごとの配布物

| 資産 | プラグイン | `init.sh` |
|---|---|---|
| `scripts/check.sh` `checks/*.sh` `check_file.sh` `feedback.sh` `audit.sh` `lib.sh` `harness_config.py` `feedback_store.py` `feedback_log.py` `README.md` `README.ja.md` `README.zh-CN.md` | プラグイン側に置かれる。Codex は `PLUGIN_ROOT`（Hooks では互換用の変数 `CLAUDE_PLUGIN_ROOT` も設定）、Claude Code は `CLAUDE_PLUGIN_ROOT` を使って実行する | 導入先の `scripts/` にファイルをコピー |
| Hooks(`hooks.json`) | ○（有効化後に自動起動） | ✗（CLAUDE.md / AGENTS.md の規約が代替） |
| skills | ○（Claude Code / Codex） | ✗（CLAUDE.md / AGENTS.md の規約が代替） |
| agents / commands | Claude Code のみ | ✗ |
| `scripts/hooks/*`・`init.sh` 自身 | ○ | ✗ |
| `.feedback/`（蓄積データ） | SessionStart フックが初回に作成 | `init.sh` が初回に作成 |
| `CLAUDE.md` / `AGENTS.md` への案内文 | ✗（必要な場合は `init.sh` 方式を併用） | 両方（再実行時は管理マーカー内だけを更新し、マーカー外は保持） |

### 更新

| 導入形態 | 更新方法 |
|---------|---------|
| Claude Code プラグイン | 第三者マーケットプレイスの自動更新は標準で無効。`/plugin` → `Marketplaces` で `Enable auto-update` を選ぶか、`/plugin marketplace update feedback-harness` と `/plugin update feedback-harness@feedback-harness` を実行する |
| Codex プラグイン | `codex plugin marketplace upgrade feedback-harness` でマーケットプレイスを更新し、`/plugins` でプラグインを確認する。更新後は新しいセッションを開始する |
| `init.sh` でコピーした `scripts/` | 配布元の feedback-harness リポジトリを最新版へ更新してから、そのリポジトリの `init.sh` を再実行する。スクリプトに加え、CLAUDE.md / AGENTS.md の管理マーカー内も最新版に置き換え、マーカー外にある利用者の記述は残す |

## Skills / Agents / Commands の使い方（プラグイン導入時）

マーケットプレイスから導入すると、Claude Code と Codex の両方で **3つの Skill** を使えます。**2つの Agent と1つの Command は Claude Code 専用**です。Codex の `feedback-loop` スキルは、Codex のサブエージェント機能を使います。`init.sh` で導入する場合はこれらを含めず、CLAUDE.md / AGENTS.md に追加される規約と、コピーされたスクリプトで同じ運用を行います。

### 呼び出され方の違い

| 種別 | 起動のしかた | 誰が起動するか |
|---|---|---|
| **Skill** | 依頼の内容に応じて**自動で起動**する。明示的に使う場合は、スキル名を指定して頼む（例: 「apply-feedback スキルでルールを反映して」） | Claude / Codex 自身 |
| **Agent** | `feedback-loop` スキルが環境のサブエージェント機能で起動する（Claude Code の配布 Agent 定義も利用） | スキル(**直接呼ぶ必要はない**) |
| **Command** | `/feedback-harness:init` と入力する | ユーザー |

**プラグイン方式では、普段は特別な操作をする必要はありません。** 各 Skill は依頼の内容に応じて自動で起動します。`init.sh` 方式では Skill をコピーしないため、CLAUDE.md / AGENTS.md に追加される規約に従って、対応するスクリプトを直接実行します。以下は、プラグインの Skill を明示的に動かしたい場合の手順です。

### Skill 1: `apply-feedback` — 作業前に過去のルールを反映する

**いつ起動するか**: 実装・編集・レビュー・設計を始める前。「過去の指摘を踏まえて」「前回のフィードバックを反映して」「ルールに従って」と言ったとき、およびやり直し・修正の依頼のとき。

**何をするか**:

1. `.feedback/rules.md` を読む(**失敗由来**=守るべき制約 / **成功由来**=再現すべき正例 の2セクション)
2. まだルール化していない open エントリも `list --status open` で確認する（ルール化まで使われない状態を避けるため）
3. 今回の作業カテゴリに一致するルールを特定し、方針に組み込んでから実装を始める
4. ルールと今回の指示が矛盾する場合は**今回の指示を優先**し、矛盾があったことを伝える（ルールを見直す機会になる）

```
あなた: 認証まわりをリファクタして
  → apply-feedback が自動起動し、rules.md を読んでから着手する
```

### Skill 2: `capture-feedback` — 指摘や成功パターンを記録する

**いつ起動するか**: あなたが成果物を修正・指摘した、「こうして」「次からはこうやって」と言った、方針を訂正した — そのすべて。うまくいった進め方を残したいときにも使う。

**何をするか**:

1. 指摘を1文の要約に整理する
2. 失敗に関する指摘なら、根因を1行で分類する（`文脈欠落` / `指示欠陥` / `実行誤り` / `モデル限界` / `未判定`）
3. signal（起きた出来事の種類）を決める。誤った出力や行動への指摘は、根因にかかわらず `failure` とする（省略した場合は CLI が自動で判断する）
4. カテゴリを選び `feedback.sh add` で記録する
5. open が3件以上になったら、共通ルールへの整理（`feedback-loop`）を提案する

```
あなた: エラーメッセージは日本語で書いて。次からもそうして
  → capture-feedback が自動起動し、根因も付けて記録する
```

根因は、次の基準で判断します。

| 根因 | 判断基準 |
|---|---|
| `文脈欠落` | 判断時に必要な事実・ルール・バージョン情報が、読み込まれた文脈に存在しなかった。参照できた情報を見落とした場合は含めない |
| `指示欠陥` | 期待結果・制約・受け入れ条件・手順が不足、曖昧、または矛盾しており、通常の品質基準だけでは一意に判断できなかった。個別の禁止事項がなかっただけの通常の不具合は含めない |
| `実行誤り` | 必要な文脈と十分明確な指示はあったが、見落とし、違反、推論ミス、実装ミスが起きた。単発の失敗では最初に検討する |
| `モデル限界` | 文脈・指示・利用可能なツール・妥当な再試行をそろえても、同種の失敗を安定して避けられない。単発の見落としだけでは判定しない |
| `未判定` | 証拠が不足している、または複数の原因を分離できない。無理に決めず、追加情報を待つ |

`根因:` 行は1件だけ記録します。未定義の分類は CLI が拒否し、上の5分類から選び直すよう案内します。

### Skill 3: `feedback-loop` — 全体の処理を振り分ける

**いつ起動するか**: 「フィードバックを整理して」「ルール化して」「ハーネスを点検して」「○○プロジェクトに導入して」「ルールを棚卸しして」「調子はどう?」「監査して」など。

依頼の内容から **Phase を自動で判断**して実行します。

| 依頼の例 | Phase | 実行内容 |
|---|---|---|
| 「フィードバックを整理して」「ルール化して」 | 1 | **feedback-curator エージェント**を起動し、promote / merge / close のどれを使うか判断 |
| 「ハーネスを点検して」「検証して」 | 2 | **harness-qa エージェント**を起動し、整合性レポートを `_workspace/` に出力 |
| 「このハーネスを ○○ に導入して」 | 3 | `init.sh` を実行し、導入先で `check.sh` を1回流して確認 |
| 「ルールを棚卸しして」「定期審査」 | 4 | `stats` を基に、各ルールを 維持 / 文言強化 / 廃止候補 に分類して提示 |
| 「調子は?」「初回通過率は?」「振り返りの議題」 | — | `stats` / `report --last`（実施後は `--mark` で振り返り期間の開始点を更新） |
| 「監査して」「脆弱性チェック」 | — | `audit.sh` を実行(ネットワークを使うためフックでは走らない) |

```
あなた: 溜まったフィードバックを整理してルールにして
  → feedback-loop が Phase 1 と判断 → feedback-curator を起動
  → ルール化の結果と rules.md の差分を提示（採用するかどうかはあなたが決める）
```

### Agents（スキル経由で起動される）

直接呼び出す必要はありませんが、それぞれの役割を知っておくと結果を理解しやすくなります。Codex では、同名の Markdown を作業ルールとして読み、Codex のサブエージェントへ渡します。

| Agent | 起動元 | 役割 | 出力 |
|---|---|---|---|
| `feedback-curator` | `feedback-loop` Phase 1（Phase 4 では起動せず、判断の考え方だけを使う） | 指摘を共通ルールにまとめる。signal（指摘の種類）を基に反映先を振り分け、失敗に関する指摘は根本原因によってさらに振り分ける | `promote`/`merge`/`close` の実行結果と判断の要約。`rules.md` 以外への反映案（CLAUDE.md への追記・lint の追加）は**提案のみ** |
| `harness-qa` | `feedback-loop` Phase 2 | スクリプトが動くか、Hooks の設定が正しいか、CLAUDE.md / AGENTS.md / rules.md が一致しているかを横断して検証する | `_workspace/qa_report_{日付}.md` に PASS/FAIL/SKIP レポート |

どちらも**共有ファイルを自動では書き換えません**。`rules.md` 以外への変更は提案として示し、実際に反映するかどうかはユーザーが決めます。

### Command: `/feedback-harness:init`

Codex や他の汎用エージェントと**併用する**場合に、現在のプロジェクトへ `scripts/` をコピーし、`CLAUDE.md` / `AGENTS.md` へ管理マーカー付きの案内文を追記します。Claude Code だけで使う場合は必要ありません（スクリプトはプラグイン側にあるため）。

```
/feedback-harness:init
```

### 導入できているかの確認

```
/plugin                      # Claude Code: feedback-harness が enabled になっているか
/plugins                     # Codex: feedback-harness がインストール・有効化されているか
/hooks                       # Codex: 3つの Hook が信頼済みになっているか
```

スキルが使われているかどうかは、応答中に該当する Skill の使用表示が出ることで確認できます。Hooks が動いているかどうかは、ファイルを1つ編集し、`.feedback/events.jsonl` に新しい行が増えることで確認できます。

## 使い方

### 日常の開発（Claude Code / Codex プラグイン）

検査は自動で実行されるため、通常は**手動で何かを実行する必要はありません**。ファイルを編集すると `check_file.sh` が、応答を終える前には `check.sh` が動きます。検査に失敗すると、その結果が自動でエージェントへ返されます。

次のコマンドは、このリポジトリ内で作業する場合、または `init.sh` で `scripts/` をコピーしたプロジェクトで手動実行する場合に使います。プラグインだけで導入したプロジェクトには `scripts/` をコピーしないため、通常は Hooks に任せます。

```bash
bash scripts/check.sh                    # 完了前の全体確認(CIでも同じものを使う)
bash scripts/check.sh /path/to/project   # 別プロジェクトを検査
FEEDBACK_CHECK_SKIP="test build" bash scripts/check.sh   # 重いステージを外す
bash scripts/audit.sh                    # 脆弱性監査(ネットワークを使うので手動)
```

### 指摘を記録する

```bash
# 人間から指摘を受けたとき（失敗に関する指摘には根本原因を1行添える）
bash scripts/feedback.sh add --category style --source human \
  --summary "エラーメッセージは日本語で書く" \
  --detail "日本語で統一する要件が指示になかった。根因: 指示欠陥"

# うまくいった進め方や指示の言い回しを残すとき（signal は省略時に自動で判断される）
bash scripts/feedback.sh add --category workflow --source agent \
  --summary "設計を固めてから実装すると手戻りが無い"
```

Claude Code / Codex プラグインでは `capture-feedback` スキルが同じ処理を行うため、コマンドを直接実行する必要はありません。

### 溜まった指摘を整理する

```bash
bash scripts/feedback.sh list                    # open エントリ一覧
bash scripts/feedback.sh list --signal failure   # 失敗系だけ絞る
bash scripts/feedback.sh promote <id> --rule "<一般化した1行>"
bash scripts/feedback.sh merge <id> --into <既存ルールの出典id>   # 再発時
bash scripts/feedback.sh retire <出典id> --reason "<退役理由>"    # 棚卸し
```

### 効果を測る・共有する

```bash
bash scripts/feedback.sh stats                 # 初回通過率・再発候補・最終監査日
bash scripts/feedback.sh report --since yesterday   # 朝会の1問
bash scripts/feedback.sh report --last --mark       # 振り返り後に次の集計期間の開始点を更新
```

### 環境変数

環境変数は、**config より優先される一時的な設定**です。CI や調査中に、その場限りで設定を変える場合に使います。Git にコミットしてチームで共有する設定は、設定ファイルに書きます。

| 変数 | 既定 | 効果 |
|---|---|---|
| `FEEDBACK_CHECK_SKIP` | (空) | 空白区切りでステージを除外(`lint typecheck test build format security docs contract`) |
| `FEEDBACK_SHELLCHECK_SEVERITY` | `warning` | shellcheck の重大度しきい値。`style` で厳しくする |
| `FEEDBACK_CONTRACT_BASE` | `main` | API 契約差分のベースラインブランチ |
| `CLAUDE_PROJECT_DIR` | (自動) | Claude Code が設定する検査対象ルート。Codex では Hook 実行時のカレントディレクトリから解決する |
| `HARNESS_PYTHON` | (自動) | 実行する Python の executable(既定は `python3` → `python` の順に解決)。Git Bash や仮想環境で名前・パスが異なる場合に明示する |

### 設定ファイル

`.feedback/config.yaml` にプロジェクトの設定を書き、Git にコミットして共有できます。ステージの skip、FAIL・WARN の切り替え、検査対象の除外（`exclude`）、ログの行数、ツールのしきい値、監査間隔などを、環境変数を使わずに調整できます。記載しなかった項目には既定値が使われます。

```bash
cp .feedback/config.example.yaml .feedback/config.yaml   # 雛形から始める
bash scripts/check.sh --list-checks           # 検査ID・実効判定・「出所」を一覧（検査は実行しない）
bash scripts/check.sh --list-checks --json    # 同じ内容を機械可読な JSON で出力
```

設定ファイルは2層あります。共有する `.feedback/config.yaml` に対し、`.feedback/local/config.yaml`（`.gitignore` 済み・この端末だけの設定）が優先されます。未導入ツールの検査を切るといった手元の事情を、チームの設定を書き換えずに反映するためのものです。個人設定で決まった項目は、`--list-checks` の「出所」が `local.` で始まります。

設定の優先順位は、環境変数 > 検査単位 > スタック単位 > 全体 > 既定値です（同じ層では個人設定が共有設定に優先します）。書き方とすべての項目は、[設定ガイド](docs/configuration.ja.md)を参照してください。

## フィードバック運用フロー

```
[記録]  人間からの指摘・修正 / 有効だった進め方 / 繰り返す check 失敗 / 完了前の振り返り
→ feedback.sh add       (capture-feedback スキル / AGENTS.md の規約)
             失敗に関する指摘は根因を --detail に1行:
               文脈欠落 | 指示欠陥 | 実行誤り | モデル限界 | 未判定
             signal(--signal)は出来事の種類:
               誤った出力・行動は根因にかかわらず failure。省略時は CLI が自動判断する
                ↓
[open]  ├─ ルール化を待たず、次の作業を始めるときに参照する (apply-feedback スキル)
        └─ feedback-curator が根本原因を見て反映先を選ぶ (feedback-loop スキル)
             promote → .feedback/rules.md へ新規ルール      (主に指示欠陥)
             merge   → 既存ルールへ統合。再発なら文言を強化
             close   → 共通ルールにできない一回限りの指摘を処理済みにする
             提案    → 文脈欠落: CLAUDE.md などへの前提情報追加案
                       実行誤り: lint・テスト・チェックリスト追加案
                       モデル限界: 人間確認・決定的ツールへの切り替え案（再現証拠が必要）
                       未判定: open のまま追加情報を待つ
                       ※ rules.md 以外は提案止まり、反映は人間が承認する
                ↓
[反映]  .feedback/rules.md → 次セッションの作業開始前に適用
                ↓
[棚卸]  定期審査 (feedback-loop Phase 4) → 古くなったルールは retire で廃止
[測定]  feedback.sh stats            — 初回通過率・再発候補(要求時のみ・テキスト出力)
[報告]  feedback.sh report --last → 朝会/振り返りの5分議題(実施後に --mark で集計期間の開始点を更新)
[監査]  bash scripts/audit.sh          — 脆弱性監査(必要なときに手動実行・ネットワーク使用)
                                          成功時のみ .last-audit を更新 → report が期限を見る
```

記録した内容は、promote によるルール化を待たず、次の作業から参照されます。記録を溜めてからまとめてルール化する方式では、ルール化するまでの間に同じ指摘が繰り返されるためです。

測定は、Feedback Flywheel における「変化の測定」に当たります。ダッシュボードは作りません。`stats` は求められたときだけテキストを出力し、数値は `report` の「数字」セクションにのみ表示します。`events.jsonl`（フックの実行結果）と `.last-retro`（振り返り期間の開始点）は、端末内だけで使う状態ファイルであり、Git では共有しません。

反映先を rules.md だけに限定しないのは、シグナルの種類によって改善すべき共有ファイルが異なるためです。知識の不足は、前提情報を示す文書（CLAUDE.md）で補います。機械的に検出できる失敗は lint やテストに組み込む方が、文章のルールだけで防ぐよりも確実です（参考: [Feedback Flywheel](docs/references/fowler-feedback-flywheel-translation.md)）。

## ライセンス

[MIT License](LICENSE) で公開しています。
