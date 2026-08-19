# feedback-harness

Claude Code と Codex の両方で利用できるフィードバックハーネスです。次の2つのループを提供します。

1. **自動フィードバックループ** — lint / typecheck / test / build の結果をエージェントに自動で返し、自己修正させる
2. **人間フィードバックの蓄積** — レビュー指摘や有効だった進め方を記録・一般化し、次回以降のセッションに反映する

## 仕組み

| 環境 | 自動チェック | ルール反映 |
|------|-------------|-----------|
| Claude Code（プラグイン導入） | プラグインの `hooks/hooks.json` が Hooks を提供する。編集直後に `check_file.sh`、応答完了前に `check.sh` を実行する（後者は、前回の成功検査以降に変更がある場合のみ）。失敗時は exit code 2 でエージェントに差し戻す。設定ファイル（JSON/YAML）の構文、秘密情報、内部リンク、依存関係、CI 設定も検査する。宣言していない検査の指摘は WARN（非ブロッキング）として `events.jsonl` に記録する。未導入のツールは SKIP とし、ハーネスが自動で導入することはない | `apply-feedback` スキル + CLAUDE.md ポインタ（プラグインが提供） |
| Codex（プラグイン導入） | 同じ `hooks/hooks.json` を Codex Hooks として読み込む。`apply_patch` のパッチ本文から対象ファイルを抽出して即時チェックし、Stop 前にフルチェックする | `apply-feedback` スキル + AGENTS.md の規約 |
| Codex IDE 拡張・汎用エージェント（`scripts/init.sh` で導入） | AGENTS.md の規約: 変更ごとに `check_file.sh`、完了前に `check.sh` をエージェント自身が実行 | AGENTS.md の規約で `.feedback/rules.md` を必読化 |

スクリプトとフィードバックの保存先（`.feedback/`）は各環境で共通です。Claude Code と Codex app / CLI はプラグインの Hooks を自動実行し、Codex IDE 拡張や汎用エージェントでは `init.sh` が展開する AGENTS.md の規約に従ってエージェントが実行します。Codex では初回に `/hooks` で内容を確認して信頼する必要があります。このリポジトリの `.claude/settings.json` は開発時の Claude Code 用設定であり、導入先には配布されません。

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
  plugin.json       # Claude Code プラグイン定義
  marketplace.json  # Claude Code / Codex が読めるレガシーカタログ
.codex-plugin/
  plugin.json       # Codex プラグイン定義
skills/             # feedback-loop (オーケストレーター) / capture-feedback / apply-feedback
agents/             # feedback-curator (ルール昇華) / harness-qa (整合性検証)
commands/
  init.md           # /feedback-harness:init — Hooks 非対応環境向け資産の展開
hooks/
  hooks.json        # Claude Code / Codex 共通の配布用 Hooks 定義
scripts/
  check.sh          # スタック自動検出 (Python/Node/Go/Rust/Java/Shell/Make) → 8ステージ + 横断チェック
  check_file.sh     # 単一ファイルの高速チェック (拡張子ベース)
  audit.sh          # オンデマンド脆弱性監査 (唯一のネットワーク検査・Stopフック対象外)
  lib.sh            # 共有ユーティリティ (has / harness_project_root / harness_tree_changed /
                    #   harness_validate_json|yaml / harness_check_md_links / harness_log_event|warn)
  feedback_log.py   # フィードバック記録CLI (add / list / search / promote / merge / close /
                    #   retire / rules / stats / report)
  init.sh           # 導入スクリプト (Hooks 非対応環境向け資産の展開)
  hooks/            # Claude Code / Codex Hooks ラッパー (SessionStart / PostToolUse / Stop)
.feedback/
  rules.md          # 一般化された恒久ルール (エージェント必読・失敗由来/成功由来の2セクション)
  rules.template.md # rules.md のシード (導入時・再生成時に使う雛形)
  config.yaml       # プロジェクト設定 (任意・commitして共有。config.example.yaml から始める)
  config.example.yaml # config.yaml の雛形 (全項目をコメント付きで並べたもの)
  log/              # 生のフィードバックエントリ (frontmatter付きMarkdown)
  .last-check       # Stopフックの検査スタンプ (mtime比較用のローカル状態・gitignore対象)
  .last-retro       # 振り返りの基点 (report --mark が更新・gitignore対象)
  .last-audit       # 脆弱性監査の最終実行日 (audit.sh が成功時のみ更新・gitignore対象)
  events.jsonl      # フック合否とWARNのイベントログ (stats/report用のローカル状態・gitignore対象)
package.json        # 検査ツール(secretlint 等)を npx --no-install で解決するためだけの宣言
tests/              # bash テスト (make check → check.sh から自動実行される)
docs/
  pointer_claude.md # 導入先の CLAUDE.md で管理するポインタ断片
  pointer_agents.md # 導入先の AGENTS.md で管理するポインタ断片
  superpowers/      # 設計書 (specs/) と実装計画 (plans/)
.claude/
  settings.json     # このリポジトリでプラグインを有効化する開発用設定 (配布対象外)
```

ハーネス自身も `check.sh` の検査対象になる(`*.sh` と `*.py` を検出)。

### ドキュメントの位置づけ

現在の利用方法は、この README、[設定ガイド](docs/configuration.md)、[スクリプト仕様](scripts/README.md)を参照してください。日付付きの `docs/proposals/` と `docs/superpowers/` は、提案時・設計時の判断を残す履歴資料です。現在の仕様と異なる場合は、前述の3文書と実装を優先します。文書の一覧は[ドキュメント案内](docs/README.md)にまとめています。

## 他プロジェクトへの導入

### Claude Code だけで使う場合

```
/plugin marketplace add JustinWangJP/feedback-harness
/plugin install feedback-harness@feedback-harness
```

導入先に置かれるのは `.feedback/`(蓄積データ)だけ。スクリプト・スキル・エージェント・Hooks はプラグイン側にある。第三者マーケットプレイスの自動更新は既定で無効のため、利用者が有効化した場合にのみ起動時の更新へ追従する。

チーム全員に配りたい場合は、導入先の `.claude/settings.json` に次を書いておくと、フォルダを信頼した時点でインストールを促される:

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

### Codex app / CLI で使う場合

```bash
codex plugin marketplace add JustinWangJP/feedback-harness
```

Codex を起動して `/plugins` を開き、`feedback-harness` をインストールして有効化する。新しいセッションで `/hooks` を開き、`SessionStart` / `PostToolUse` / `Stop` の各 Hook を確認して信頼する。Codex IDE 拡張はプラグイン非対応のため、次の `init.sh` 方式を使う。

### Codex IDE 拡張や他の汎用エージェントで使う場合

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

`scripts/` と `AGENTS.md` が導入先に展開される。`CLAUDE.md` / `AGENTS.md` のポインタは管理マーカー付きで追加され、再実行時は管理マーカー内だけを最新版へ置換する。マーカー外の利用者記述は保持する。`.feedback/rules.md` は空のテンプレートから始まる。

### 導入形態ごとの配布物

| 資産 | プラグイン | `init.sh` |
|---|---|---|
| `scripts/check.sh` `check_file.sh` `audit.sh` `lib.sh` `feedback_log.py` | プラグイン側に置かれ、Codex は `PLUGIN_ROOT`（Hooks では互換変数 `CLAUDE_PLUGIN_ROOT` も設定）、Claude Code は `CLAUDE_PLUGIN_ROOT` 経由で実行 | 導入先の `scripts/` に実体をコピー |
| Hooks(`hooks.json`) | ○ 自動起動 | ✗(AGENTS.md の規約が代替) |
| skills | ○（Claude Code / Codex） | ✗（AGENTS.md の規約が代替） |
| agents / commands | Claude Code のみ | ✗ |
| `scripts/hooks/*`・`init.sh` 自身 | ○ | ✗ |
| `.feedback/`(蓄積データ) | SessionStart フックが初回シード | `init.sh` がシード |
| `CLAUDE.md` / `AGENTS.md` ポインタ | CLAUDE.md ポインタのみ | 両方（管理マーカー内を再実行時に更新・マーカー外は保持） |

### 更新

| 導入形態 | 更新方法 |
|---------|---------|
| Claude Code プラグイン | 第三者マーケットプレイスは自動更新が既定で無効。`/plugin` → `Marketplaces` で `Enable auto-update` を選ぶか、`/plugin marketplace update feedback-harness` と `/plugin update feedback-harness@feedback-harness` を実行する |
| Codex プラグイン | `/plugins` のプラグイン管理から更新する |
| `init.sh` でベンダリングした `scripts/` | `init.sh` を再実行する(冪等)。スクリプトに加え、CLAUDE.md / AGENTS.md の管理マーカー内も置換更新する。マーカー外の利用者記述は保持する |

## Skills / Agents / Commands の使い方（プラグイン導入時）

マーケットプレイスから導入すると、Claude Code と Codex の両方で **3つの Skill** が使える。**2つの Agent と1つの Command は Claude Code 専用**で、Codex の `feedback-loop` スキルは Codex のサブエージェント機能を使う。`init.sh` 導入にはこれらを含めず、AGENTS.md の規約が代替になる。

### 呼び出され方の違い

| 種別 | 起動のしかた | 誰が起動するか |
|---|---|---|
| **Skill** | 依頼の文面に反応して**自動起動**する。明示したいときは名前を出して頼む(例: 「apply-feedback スキルでルールを反映して」) | Claude / Codex 自身 |
| **Agent** | `feedback-loop` スキルが環境のサブエージェント機能で起動する（Claude Code の配布 Agent 定義も利用） | スキル(**直接呼ぶ必要はない**) |
| **Command** | `/feedback-harness:init` と入力する | ユーザー |

**普段は何も意識しなくてよい。** 導入先の `CLAUDE.md` に置かれるポインタが「実装前は apply-feedback」「指摘を受けたら capture-feedback」と促すため、通常の会話の中で自動的に起動する。以下は「意図して動かしたいとき」の手順。

### Skill 1: `apply-feedback` — 作業前に過去のルールを反映する

**いつ起動するか**: 実装・編集・レビュー・設計を始める前。「過去の指摘を踏まえて」「前回のフィードバックを反映して」「ルールに従って」と言ったとき、およびやり直し・修正の依頼のとき。

**何をするか**:

1. `.feedback/rules.md` を読む(**失敗由来**=守るべき制約 / **成功由来**=再現すべき正例 の2セクション)
2. 未昇華の open エントリも `list --status open` で確認する(昇華待ちで死蔵させないため)
3. 今回の作業カテゴリに一致するルールを特定し、方針に組み込んでから実装を始める
4. ルールと今回の指示が矛盾する場合は**今回の指示を優先**し、矛盾があった旨を伝える(ルール更新の機会になる)

```
あなた: 認証まわりをリファクタして
  → apply-feedback が自動起動し、rules.md を読んでから着手する
```

### Skill 2: `capture-feedback` — 指摘や成功パターンを記録する

**いつ起動するか**: あなたが成果物を修正・指摘した、「こうして」「次からはこうやって」と言った、方針を訂正した — そのすべて。うまくいった進め方を残したいときにも使う。

**何をするか**:

1. 指摘を1文の要約に整理する
2. 失敗系なら根因を1行判定する(`文脈欠落` / `指示欠陥` / `モデル限界`)— 根因が昇華先を決める
3. signal を決める(省略時は CLI が推論)
4. カテゴリを選び `feedback_log.py add` で記録する
5. open が3件以上になったら昇華(`feedback-loop`)を提案する

```
あなた: エラーメッセージは日本語で書いて。次からもそうして
  → capture-feedback が自動起動し、根因つきで記録する
```

### Skill 3: `feedback-loop` — 全体のオーケストレーター

**いつ起動するか**: 「フィードバックを整理して」「ルール化して」「ハーネスを点検して」「○○プロジェクトに導入して」「ルールを棚卸しして」「調子はどう?」「監査して」など。

依頼の内容から **Phase を自動判定**して実行する:

| 依頼の例 | Phase | 実行内容 |
|---|---|---|
| 「フィードバックを整理して」「ルール化して」 | 1 | **feedback-curator エージェント**を起動し、promote / merge / close を判断 |
| 「ハーネスを点検して」「検証して」 | 2 | **harness-qa エージェント**を起動し、整合性レポートを `_workspace/` に出力 |
| 「このハーネスを ○○ に導入して」 | 3 | `init.sh` を実行し、導入先で `check.sh` を1回流して確認 |
| 「ルールを棚卸しして」「定期審査」 | 4 | `stats` を起点に、各ルールを 維持 / 文言強化 / 退役候補 に分類して提示 |
| 「調子は?」「初回通過率は?」「振り返りの議題」 | — | `stats` / `report --last`(実施後は `--mark` で基点更新) |
| 「監査して」「脆弱性チェック」 | — | `audit.sh` を実行(ネットワークを使うためフックでは走らない) |

```
あなた: 溜まったフィードバックを整理してルールにして
  → feedback-loop が Phase 1 と判定 → feedback-curator を起動
  → 昇華結果と rules.md の差分が提示される(採否はあなたが決める)
```

### Agents（スキル経由で起動される）

直接呼ぶ必要はないが、何が動いているかを知っておくと結果を読みやすい。Codex では同名の Markdown を作業原則として読み、Codex のサブエージェントへ渡す。

| Agent | 起動元 | 役割 | 出力 |
|---|---|---|---|
| `feedback-curator` | `feedback-loop` Phase 1(Phase 4 は起動せず判断原則だけ援用する) | 指摘を一般化ルールへ昇華する。signal で昇華先を振り分け、失敗系はさらに根因でサブルーティングする | `promote`/`merge`/`close` の実行結果と判断の要約。`rules.md` 以外への反映案(CLAUDE.md 追記・lint 追加)は**提案止まり** |
| `harness-qa` | `feedback-loop` Phase 2 | ハーネス自体の整合性を境界面クロス比較で検証する(スクリプト実行可否・Hooks 設定・CLAUDE.md/AGENTS.md/rules.md の同期) | `_workspace/qa_report_{日付}.md` に PASS/FAIL/SKIP レポート |

どちらも**共有アーティファクトを勝手に書き換えない**。`rules.md` 以外への変更は提案として提示され、反映するかどうかはユーザーが決める。

### Command: `/feedback-harness:init`

Codex や他の汎用エージェントと**併用する**とき、現在のプロジェクトに `scripts/` と `AGENTS.md` を展開する。Claude Code だけで使うなら不要(スクリプトはプラグイン側にあるため)。

```
/feedback-harness:init
```

### 導入できているかの確認

```
/plugin                      # feedback-harness が enabled になっているか
```

スキルが起動しているかは、応答中に該当スキルが使われた旨の表示で確認できる。フックが動いているかは、ファイルを1つ編集して `.feedback/events.jsonl` に行が増えるかで確認できる。

## 使い方

### 日常の開発（Claude Code / Codex Plugin）

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

Claude Code / Codex Plugin では `capture-feedback` スキルが同じことを行うため、コマンドを直接叩く必要はない。

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

環境変数は**config より優先される**一時上書き(CI や調査中のその場限りの調整用)。commit してチームで共有する設定は設定ファイルに書く。

| 変数 | 既定 | 効果 |
|---|---|---|
| `FEEDBACK_CHECK_SKIP` | (空) | 空白区切りでステージを除外(`lint typecheck test build format security docs contract`) |
| `FEEDBACK_SHELLCHECK_SEVERITY` | `warning` | shellcheck の重大度しきい値。`style` で厳しくする |
| `FEEDBACK_CONTRACT_BASE` | `main` | API 契約差分のベースラインブランチ |
| `CLAUDE_PROJECT_DIR` | (自動) | Claude Code が設定する検査対象ルート。Codex では Hook 実行時のカレントディレクトリから解決する |

### 設定ファイル

`.feedback/config.yaml` にプロジェクトの設定を書ける(commit して共有)。ステージの skip / FAIL・WARN の切替、検査対象の除外(`exclude`)、ログ行数、ツールの閾値、監査間隔等を環境変数なしで調整できる。書かなかった項目はすべて既定値。

```bash
cp .feedback/config.example.yaml .feedback/config.yaml   # 雛形から始める
bash scripts/check.sh --list-checks           # 検査ID・実効判定・「出所」を一覧（検査は実行しない）
bash scripts/check.sh --list-checks --json    # 同じ内容を機械可読な JSON で出力
```

優先順位は 環境変数 > 検査単位 > スタック単位 > 全体 > 既定値。書き方と全項目は[設定ガイド](docs/configuration.md)を参照。

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

測定は Feedback Flywheel における「変化の測定」に相当する。ダッシュボードは作らない — `stats` は要求時にテキストを出力し、数値は `report` の「数字」セクションにだけ表示する。`events.jsonl`（フックの成否）と `.last-retro`（振り返りの基点）は端末内だけで使う状態ファイルであり、Git では共有しない。

反映先を rules.md に一本化しないのは、シグナルの種類によって改善すべき共有成果物が異なるためです。知識の不足は前提情報を与える文書（CLAUDE.md）で補い、機械的に検出できる失敗は lint やテストへ組み込む方が、文章だけのルールより確実な再発防止策になります（参考: [Feedback Flywheel](docs/references/fowler-feedback-flywheel-translation.md)）。
