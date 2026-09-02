[English](README.md) | 日本語 | [简体中文](README.zh-CN.md)

# scripts/ — フィードバックハーネスの実行エンジン

フィードバックハーネスの実行スクリプトを置くディレクトリです。プロジェクトルートに README.md がある場合は、ハーネス全体の概要をそちらで説明します。この文書では、各スクリプトの**役割・仕様・利用方法**を説明します。

スクリプトと蓄積データ(`.feedback/`)は **Claude Code / Codex 両環境で完全共有**。環境固有なのは「誰が・いつスクリプトを起動するか」のエントリポイントだけ(後述)。

## 構成

```text
scripts/
├── check.sh          # フルチェック: スタック自動検出 → 8ステージと横断検査、要約出力
├── checks/*.sh       # stack・横断runner(共通実行coreはcheck.shに残す)
├── check_file.sh     # 単一ファイル高速チェック: 拡張子ベースの静的チェック
├── lib.sh            # check.sh / check_file.sh の共有ユーティリティ(has() ほか)
├── harness_config.py # 設定(.feedback/config.yaml)の唯一のパーサ(YAMLサブセット・スキーマ検証・3層解決)
├── feedback_store.py # repository lock・atomic write・中断transaction回復
├── feedback.sh       # OS共通のフィードバックCLI入口（Python executableを解決）
├── feedback_log.py   # フィードバックCLI実装: 記録・昇華・棚卸し・集計・期間レポート
├── audit.sh          # オンデマンド脆弱性監査(ハーネスが意図して通信する専用検査。Stopフックからは呼ばれない)
├── init.sh           # 導入スクリプト(Hooks 非対応環境向け資産の展開。導入先にはコピーされない)
└── hooks/
    ├── on_session_start.sh  # Claude Code / Codex SessionStart → .feedback/ の初回シード
    ├── post_edit.sh         # Claude Code / Codex PostToolUse → check_file.sh
    └── on_stop.sh           # Claude Code / Codex Stop → check.sh
```

3系統に分かれる:

| 系統 | スクリプト | 役割 |
|------|-----------|------|
| 自動チェック | `check.sh`, `check_file.sh`, `hooks/*` | 依存取得やリモート参照を追加せず lint/test/build 結果をエージェントに返し、自己修正させる |
| フィードバック蓄積・測定 | `feedback.sh` | 人間の指摘を記録・一般化し、次セッションに引き継ぐ。数字と期間ダイジェストを出す |
| オンデマンド監査(ネットワーク) | `audit.sh` | 依存の脆弱性を調べる。フックからは呼ばれない |

配布のされ方が2通りある。**プラグイン導入**では全ファイルがプラグイン側に置かれる。Codex は `PLUGIN_ROOT`（Hooks では互換変数 `CLAUDE_PLUGIN_ROOT` も設定）、Claude Code は `CLAUDE_PLUGIN_ROOT` を使う。**`init.sh` 導入**では `check.sh` / `checks/*.sh` / `check_file.sh` / `lib.sh` / `feedback.sh` / `audit.sh` / `harness_config.py` / `feedback_store.py` / `feedback_log.py` / このREADMEの英語版・日本語版・簡体字中国語版が導入先の `scripts/` にコピーされる（`hooks/` と `init.sh` 自身はコピーされない — 前者はプラグイン専用、後者は配布元から実行するもの）。

## 設計思想(共通)

1. **出力はエージェント向け**: 検査ごとの結果と最終状態を簡潔に表示し、失敗の詳細は末尾の指定行数だけを表示する。長大なログ全文は出力しない。
2. **寛容な検出**: ツール未インストールのステージは `SKIP` で、失敗扱いにしない。ハーネス側でスタックを強要しない。
3. **宣言の有無で強度を決める**: プロジェクトが設定ファイルで宣言した検査は `FAIL`(完了をブロック)、ハーネスが推測で走らせる検査は `WARN`(報告のみ・exit 0)。宣言していない検査で完了不能にすると、導入初日の既存プロジェクトが作業できなくなる。WARN は `events.jsonl` に記録され `stats` / `report` の「頻出WARN」に現れる。
4. **ツールを自動インストールしない**: 未導入は `SKIP` と理由表示に留める。インストールは環境を変える行為であり、導入の判断はユーザーが行う。
5. **スタック非依存**: プロジェクト種別をマニフェスト(`pyproject.toml`/`package.json`/…)から自動検出。設定不要。
6. **状態を分離する**: スクリプト自身には状態を埋め込まず、すべて `.feedback/` 配下のファイルへ保存する。`rules.md` や `log/` などの共有データは Git で追跡できる。一方、`events.jsonl`、`.last-check`、`.last-retro`、`.last-audit`、`.state.lock`、`.transaction.json` などの実行時状態は `.gitignore` の対象であり、端末間では共有しない。lockは全processが同じinodeを使うため意図的に残し、中断transactionのjournalは次回CLI実行時に再適用する。

---

## 各スクリプトの仕様

### `check.sh` — フルチェック(完了前 / CI用)

```bash
bash scripts/check.sh [プロジェクトルート]          # 省略時はカレントディレクトリ
FEEDBACK_CHECK_SKIP="test build" bash scripts/check.sh   # 特定ステージをスキップ
bash scripts/check.sh --list-checks   # 検査ID・実効判定・「出所」を一覧(検査コマンドは実行しない)
bash scripts/check.sh --list-checks --json   # 同じ内容を JSON で出力
bash scripts/check.sh --help          # 使い方を表示(exit 0)
```

配布する各スクリプト(`check.sh` / `check_file.sh` / `feedback.sh` / `audit.sh` / `init.sh` / `harness_config.py` / `feedback_log.py`)は `--help` / `-h` で使い方を表示して `exit 0` する。`check.sh` / `audit.sh` / `init.sh` は不明なオプションを **`exit 2`** で拒否する — 未知のオプションをプロジェクトルート扱いすると「ディレクトリが見つかりません」となり、原因が引数だと気づけないため。`check_file.sh` だけは例外で、`--help` 以外の `-` 始まりもファイル名として扱う(このスクリプトの非0は PostToolUse の差し戻しに直結するため)。

**動作:** 検出したスタックごとにステージを走らせ、スタック非依存の横断チェックも実行して、`PASS`/`FAIL`/`WARN`/`SKIP` の要約を出す。

**ステージ別の実行内容**(ツールが無ければ理由付き `SKIP`):

| ステージ | Python | Node | Go | Rust | Java | Shell |
|---|---|---|---|---|---|---|
| `lint` | `ruff check` | `run lint` / `npm ls --all` | `go vet` / `go mod verify` | `clippy` / `cargo metadata --offline` | — | `bash -n` / `shellcheck` |
| `typecheck` | `mypy`(宣言時) | `run typecheck` / `tsc --noEmit` | — | — | — | — |
| `test` | `pytest`(+`--cov`) | `test` または `test:coverage` | `go test -cover` | `cargo test` | `./mvnw` または `mvn verify` / `gradle check` | — |
| `build` | — | `run build` | `go build` | `cargo check`(clippy 不在時) | — | — |
| `format` | `ruff format` | `prettier`(宣言時) | `gofmt -l` | `cargo fmt` | — | — |
| `contract` | — | — | — | `cargo semver-checks`(`[lib]`) | — | — |

**横断チェック**(スタック非依存・`security` / `docs` / `lint` / `contract` ステージ): 設定ファイル構文・内部リンク・秘密情報・CI設定・Dockerfile・OpenAPI 契約差分。

**このスクリプトがしないこと:**

- **ハーネス自身からネットワークアクセスを開始しない** — 脆弱性監査は `audit.sh` に分離。`npx` は必ず `--no-install` を付け、未導入なら取得せず `SKIP`。ただし、プロジェクト定義のコマンドや外部ツールは自身の設定に応じて通信する場合がある
- **ツールを導入しない** — 未導入は `SKIP` と理由表示に留める
- **テストを2回走らせない** — カバレッジは既存 test コマンドへの計装(または `test:coverage` への差し替え)で賄う
- **宣言していない検査で完了をブロックしない** — 該当する失敗は `WARN`(exit 0)
- **リモートを参照しない** — 契約差分のベースラインは `git merge-base HEAD <FEEDBACK_CONTRACT_BASE:-main>`、解決不能なら `HEAD`

- **検出対象**: Python(`pyproject.toml`/`setup.py`/`requirements.txt`、無くても `*.py` があれば `ruff` のみ実行) / Node(`package.json`) / Go(`go.mod`) / Rust(`Cargo.toml`) / Java(`pom.xml`/`build.gradle`) / Shell(`*.sh`) / 汎用(`Makefile` の `check` ターゲット)
- **Maven project**: ルートに `pom.xml` があれば reactor の入口として `verify` を1回だけ実行する。ルート POM が無ければ、検出した各 `pom.xml` を `-f` で個別実行する。POM ごとに、同じディレクトリの `mvnw`、リポジトリルートの `mvnw`、グローバル `mvn` の順で選ぶ。wrapper が存在しても実行不可なら、黙ってフォールバックせず `SKIP` と表示する。Maven の `verify` は、プロジェクトで設定されたコンパイル・テスト・パッケージング・integration-test lifecycle を含み、プロジェクト設定に従って依存や plugin をリポジトリから解決する場合がある。ルート POM 無しで検出した各モジュールは `mvn-<モジュールslug>` という独立した検査IDを持つ(例 `services/api/pom.xml` → `mvn-services-api`。slug が衝突する場合は連番が付く)。判定は「その派生IDの明示設定 → `mvn` の設定」の順に解決するため、`check.skip: [test]` は全モジュールへ届き、`checks.mvn-tools-cli.severity: skip` はそのモジュールだけを止める
- **横断チェック(スタック非依存)**: `*.json` / `*.yaml` / `*.yml` の構文検証。`tsconfig*.json` / `jsconfig*.json` / `devcontainer.json` / `.vscode/` 配下はコメント付き(JSONC)が慣例のため対象外。YAML は複数文書(`---` 区切り)に対応し、未知のカスタムタグ(`!Ref` 等)は構文エラーとして扱わない。PyYAML 未導入なら YAML は理由付き `SKIP`。JSON 構文と内部リンクの検証は Python を使うため、Python 3.10+ を解決できない環境ではこちらも理由付き `SKIP` になる(検証していないものを `PASS` として報告しない)
- **ドキュメント整合性**: Markdown の内部リンク切れを検出する(`docs` ステージ)。外部URL・`mailto:`・アンカーのみ・絶対パスは対象外(ネットワークを使わない原則)。コードブロック・コードスパン内のリンク風記述は検証しない
- **秘密情報**(`security` ステージ): `.secretlintrc.*` があれば `secretlint` を実行する。**設定が無ければ SKIP** — secretlint は設定なしでは起動できないため。値は既定でマスクされ、失敗ログに秘密が出ることはない。`gitleaks` が PATH にあれば併用する(`--no-git --redact` に対応する版のみ)
- **CI設定・Dockerfile**: `.github/workflows/*.y*ml` があれば `actionlint`、`Dockerfile*` があれば `dockerfilelint`(無ければ `hadolint`)を実行する。いずれも未導入なら SKIP
- **依存の実在性**(ネットワーク不使用): Node は `npm ls --all`(npm のときのみ。`node_modules` があるときのみ)、Go は `go mod verify`、Rust は `cargo metadata --offline`、Python は `deptry`。「存在しないパッケージ名」「宣言と実体のずれ」を検出する
- **API契約・破壊的変更**(`contract` ステージ): `openapi.yaml`/`openapi.json`(ルートまたは `api/`)があれば `oasdiff breaking` をベースライン(`git merge-base HEAD <FEEDBACK_CONTRACT_BASE:-main>`、解決不能なら `HEAD`)との差分で実行する。Rust は `[lib]` を持つ crate で `cargo semver-checks check-release --baseline-rev <git由来のSHA>` を実行する。どちらもリモートやレジストリを参照せず、オフラインで完結する
- **カバレッジ相乗り**: テストを2回走らせず計装フラグを足すだけ — Python は pytest-cov 検出時に `--cov --cov-report=term-missing`(設定の `--cov-fail-under` が自動的に FAIL ゲートになる)、Go は `go test -cover`、Node は `test:coverage` スクリプトがあればそれを `test` の**代わりに**実行する(両方走らせるとテストが2回動くため)
- **設定ファイル**: `.feedback/config.yaml`(commit して共有)でステージの skip / FAIL・WARN の切替、検査対象の除外(`exclude`)、ログ行数、ツールの閾値(shellcheck の重大度・vulture の confidence・oasdiff のベースライン)、監査間隔等を調整できる。優先順位は**環境変数 > 検査単位(`checks.<id>`) > スタック単位(`check.<stack>`) > 全体(`check`) > 既定値** — `FEEDBACK_CHECK_SKIP` 等の環境変数は config より優先される一時上書き。設定ファイルは2層あり、`.feedback/local/config.yaml`(`.gitignore` 済み・この端末だけの設定)は共有設定より優先される — 共有設定を書き換えずに手元の事情(未使用ツールの検査を切る等)を反映するためのもの。個人設定で決まった項目は出所が `local.` で始まる。全項目の一覧は配布元プラグインの設定ガイド `docs/configuration.ja.md` を参照(この scripts/ は docs/ 無しで配布されるため、ここにはリンクを張らない)
- **`--list-checks`**: 検査ID・ラベル・ステージ・実効判定・**出所**(どの層で判定が決まったか)を一覧する。検査コマンドは実行しない。適用対象になった検査は、ツール未導入でも `skip` と理由を表示する。左端の検査IDはそのまま `checks:` のキーとして利用できる。`--json` を併用すると機械可読な形式で出力する。壊れた config では表を既定値で出した後に stderr へエラーを出し exit 1 する
- **ステージの上限秒**: `check.stage_timeout_seconds`(既定 `0` = ハーネスに任せる)で1ステージを打ち切れる。`0` のとき、CLI / CI からの実行は無制限で、Stop フックからの実行だけがフック側の制限より短い既定(240秒)で打ち切る(`--stage-timeout=<秒>` はフックが渡す口で、config の指定が優先される)。打ち切りは `FAIL` ではなく `TIMEOUT` として報告し、`severity: warn` の検査は `WARN` に留める。`timeout(1)` が無い・`--kill-after` に非対応の環境では打ち切らず従来どおり動く
- **ステージスキップ**: `FEEDBACK_CHECK_SKIP` に指定できるステージ名は `lint` / `typecheck` / `test` / `build` / `format` / `security` / `docs` / `contract`。空白区切りで複数指定できる(config の `check.skip` と同じ語彙)
- **make再帰ガード**: `make check` 実行時のみ `FEEDBACK_CHECK_RECURSION_GUARD` を子孫に伝え、その中で起動された check.sh は make フォールバックを `SKIP` する。フック実行時に `CLAUDE_PROJECT_DIR` が伝播し、テスト内の check.sh がルートを本リポジトリに解決し直して make check がテストを再実行する無限再帰(Stop フックの timeout を食い潰す)を断つためのもの。**通常の make 実行・直接ステージ(lint/test/build)には影響しない**
- **SKIPの理由**: 出力に必ず理由が付く — `(<tool> 未インストール)` / `(<tool> 起動不可 — 環境を確認してください)` / `(実行不可)` / 環境変数由来のスキップは `(env.FEEDBACK_CHECK_SKIP)`、config 由来は `(config: <キーのパス>)`、およびスタック単位でまとめた `(<stack>: 全ステージ …)`。**ツールが無い・壊れているだけの状態を `FAIL` にしない**(ユーザーのコードの問題ではないため)
- **検査対象ファイル**: Gitリポジトリなら `git ls-files --cached --others --exclude-standard`。**未コミットの新規ファイルも検査し**、`.gitignore` 済みは除外する
- **ツールを暗黙に取得しない**: Node の typecheck フォールバックは `npx --no-install tsc`。`typescript` が未導入なら取得を試みず `SKIP` にする。ただし Maven の `verify` などプロジェクト定義のコマンドは、宣言済みの依存や plugin を解決する場合がある
- **shellcheck の重大度**: 既定は `warning`(`-S warning`)。`style`/`info` まで拾うと導入初日のプロジェクトが既存コードで詰まるため。`FEEDBACK_SHELLCHECK_SEVERITY=style` で引き上げられる
- **失敗出力**: `FAIL` したステージは末尾40行のログを `failures.txt` に集約し、最後にまとめて表示する
- **最終行**(FAIL時を除く。いずれも exit 0):

  | 最終行 | 意味 |
  |--------|------|
  | `ALL PASS` | 全ステージ成功 |
  | `ALL PASS (N件WARN — 未対応の指摘があります)` | 成功したがブロックしない指摘あり。WARN内容を確認する |
  | `ALL PASS (N件WARN・M件SKIP — 未検証/未対応の項目があります)` | 成功したが未対応の指摘と未検証あり |
  | `ALL PASS (N件SKIP — 未検証の項目があります)` | 成功したが未検証あり |
  | `実行できたステージがありません(すべてSKIP)` | 何も検証できていない |
  | `検出できたスタックがありません …` | 対応マニフェスト・対象ファイルなし |

  全SKIPや部分SKIPを無印の `ALL PASS` と偽らない。
- **WARN**: 完了をブロックしない指摘。exit code は `0` のまま。最終行に件数が付く(`ALL PASS (1件WARN — 未対応の指摘があります)`)。産出源は宣言(設定ファイル)が無い検査 — `python: ruff format`(`[tool.ruff` があれば FAIL)、`python: deptry` / `python: vulture`(`[tool.deptry` / `[tool.vulture` があれば FAIL)、`rust: cargo fmt`(`rustfmt.toml` があれば FAIL)
- **exit code**: `0` = FAILなし(全SKIP・スタック未検出を含む) / `1` = FAILあり / `2` = ルートディレクトリ不正。**エージェントは最終行の文字列ではなく exit code で判定すること**

### `check_file.sh` — 単一ファイル高速チェック(編集直後用)

```bash
bash scripts/check_file.sh <ファイルパス>
```

**動作:** 拡張子に応じて、フルビルドを伴わない静的チェックだけを実行する。`.feedback/config.yaml` の検査単位の判定を反映し、`skip` は実行せず、`warn` は内容を表示して exit code 0、`fail` は exit code 1 とする。config 自体に設定エラーがある場合も、内容を表示して exit code 1 とする。

| 拡張子 | チェック内容 |
|--------|-------------|
| `.py` | `ruff check`(無ければ選択した Python の `-m py_compile`) |
| `.ts`/`.tsx`/`.js`/`.jsx`/`.mjs`/`.cjs` | ESLint設定があれば `eslint`、無ければ `.js`/`.mjs`/`.cjs` を `node --check` |
| `.go` | `gofmt -l`(未フォーマットを検出) |
| `.rs` | `rustfmt --check` |
| `.sh` | `bash -n` + `shellcheck`(あれば) |
| `.json`/`.yaml`/`.yml` | 選択した Python でパース検証 |

- **exit code**: `0` = 問題なし、WARN のみ、ファイル未指定、または対象ファイルが存在しない / `1` = FAIL、または config の設定エラー(内容を出力)

### `feedback.sh` — フィードバック記録CLI

```bash
bash scripts/feedback.sh <サブコマンド> [引数]
```

エントリは `.feedback/log/` に frontmatter 付き Markdown、一般化ルールは `.feedback/rules.md` に昇華される。**logファイルを直接作成・編集せず、必ずこのCLIを使うこと**(frontmatter形式が揃わないと `list`/`promote` が壊れる)。

| サブコマンド | 引数 | 説明 |
|-------------|------|------|
| `add` | `--category <cat>` `--summary "<要約>"` `[--detail "<詳細>"]` `[--source human\|hook\|agent]` `[--signal <context\|instruction\|workflow\|failure>]` | エントリを記録。`open` が3件以上で promote 候補の通知を出す。`--signal` は信号種（省略時は detail/category から推論）。`根因:` 行がある場合は、定義済み5分類のいずれか1件だけを許可する |
| `list` | `[--status open\|promoted\|closed\|retired\|all]` `[--category <cat>]` `[--signal <context\|instruction\|workflow\|failure\|unknown>]` | エントリ一覧(既定は `open`)。`--signal unknown` は signal を持たない旧エントリを拾う |
| `search` | `<キーワード>` | エントリの全文検索 |
| `promote` | `<entry-id>` `--rule "<一般化ルール1行>"` | `rules.md` に**新規ルールを追記**し、対象エントリを `promoted` に更新 |
| `merge` | `<entry-id>` `--into <既存ルールの出典id>` `[--rule "<更新後の本文>"]` | 既存ルールの**出典に追記**し(新規行を増やさない)、対象を `promoted` に更新。同じ原則の指摘が再発したとき用 |
| `close` | `<entry-id>` `[--reason "<理由>"]` | 昇華せず `closed` に更新。一般化できない一回限りの指摘用 |
| `retire` | `<出典entry-id>` `--reason "<退役理由>"` | 昇華済みルールを **rules.md から撤去**し、出典エントリ(merge済みの分も含む)を `retired` に更新。棚卸しで人間が裁定した後に使う |
| `rules` | (なし) | 現在の `rules.md` を表示 |
| `stats` | `[--since <日付>]` `[--days <N>]` | この作業コピー内のローカルデータだけを集計する。PostToolUse 初回通過率・平均再チェック回数・Stop 初回通過率・失敗上位・signal/根因別件数・**再発候補**(昇華後に同カテゴリの失敗系が記録されたルール — これは**判定結果ではなく調査対象**で、同じ原則の再発かどうかは本文を読むエージェントが判断する。各候補に添う数値は表面的な文字の重なりで、読む順のヒントに過ぎない)。頻出WARN と失敗上位には**最終発生日**が付き、`feedback.stale_days`(既定7日)以上再発していない項目には注記が出る。スクラッチパッド等の一時ファイルは集計対象外。**最終監査日**と**最終棚卸し日**も表示し、それぞれ `audit.interval_days`(既定7日)・`feedback.retro_interval_days`(既定90日 = 四半期の目安)を超過すると推奨行が出る |
| `report` | `--since <日付\|yesterday>` または `--last`、`[--mark]` | この作業コピー内だけの期間ダイジェスト(新規エントリ/昇華/close・retire/open 棚卸し/再発候補/数字)。`--last` は `.feedback/.last-retro` 基点。`--mark` で実施後に基点を更新 |

- **category**: `style` / `architecture` / `testing` / `naming` / `workflow` / `domain`
- **entry-id**: 記録時刻 `%Y%m%d-%H%M%S`。同一秒に複数記録した場合は `-2`, `-3` … を付けて一意にする(重複すると `promote` が先頭の1件しか掴めず、残りが昇華不能になるため)

### `audit.sh` — オンデマンド脆弱性監査(明示実行専用)

```bash
bash scripts/audit.sh [プロジェクトルート]
```

`check.sh` と異なり**ネットワークを使う**(pip-audit / npm audit --audit-level=high / govulncheck / cargo audit)。Node は PM 判定(`lib.sh` の `harness_node_pm` — `check.sh` と共通)が npm を返し、かつ `package-lock.json` があるときだけ実行する — `npm audit` は他PMの lockfile を読めず ENOLOCK で落ちるため、`pnpm-lock.yaml` / `yarn.lock` がある場合は SKIP して `pnpm audit` / `yarn npm audit` の直接実行を案内する。移行中などで `package-lock.json` が併存していても npm 以外と判定する(テストが pnpm で走るのに監査だけ npm audit が動くと、実際の依存解決と違うツリーを監査するため)。Stop フックからは呼ばれず、`feedback-loop` スキル等からの明示実行専用。成功時のみ `.feedback/.last-audit` に日付を書き、`stats` / `report` が「最終監査日」を表示する — **7日を超過するか未実行なら推奨行が出る**(WARN と同じ「ブロックせず、溜まったら見える」哲学)。失敗時にスタンプを書かないため、脆弱性が残っている間は推奨が消えない。

### `hooks/` — Claude Code / Codex Hooks ラッパ

Claude Code / Codex の Hooks から起動される薄いラッパ。判定・実行は `check_file.sh` / `check.sh` に委譲し、フック固有の処理(stdin JSONのパース、exit code 2 によるエージェントへの差し戻し、無限ループ防止)だけを担う。**`init.sh` 導入ではコピーされない**（プラグインから実行するため）。

- **`on_session_start.sh`** (SessionStart): `.feedback/log/` と `rules.md` をテンプレートから初回シードする。プラグインだけで導入したプロジェクトでは `init.sh` を実行しないため、Hooks 側が初期化を担う。**既存の `.feedback/` には一切触れず**、失敗してもセッションをブロックしない。
- **`post_edit.sh`** (PostToolUse: `Edit|Write|MultiEdit`): Claude Code では stdin の `tool_input.file_path`、Codex の `apply_patch` では `tool_input.command` のパッチヘッダーから対象ファイルを取り出し、`check_file.sh` でチェックする。問題があれば **`exit 2` + stderr** でエージェントにフィードバックし、自己修正ループを起動する。対象ファイルが取れないときは何も記録しない。
  - 合否(成功・失敗の両方)を `.feedback/events.jsonl` に1行追記する(`stats` の初回通過率の原料。ローカル状態で共有しない)
- **`on_stop.sh`** (Stop): 応答完了前に `check.sh` を実行。失敗すれば **`exit 2`** で完了をブロックし失敗内容を返す。`stop_hook_active` が `true`(2周目以降)のときは何もせず `exit 0` し、**無限ループを防止**する。
  - **検査の実行条件**: 前回の成功検査(`.feedback/.last-check` のmtime)以降に作業ツリーが変わっているときだけ走る。無条件だと、ファイルを1つも編集しない質問応答のターンでも導入先のフルビルド(`mvn verify` / `npm run build` 等)が毎回動く。判定は mtime なので Edit/Write だけでなく Bash 経由の編集も拾い、判定できないときは必ず「実行する」側に倒す。
  - スタンプを進めるのは**検査が成功したときだけ**。失敗を記録すると、直さないまま次のターンで「変更なし」と判定され壊れたまま完了できてしまう。
  - 2周目で `check.sh` を再実行しないのは、`exit 0` で返す出力がエージェントに渡らず、重い導入先では最も待たされる場面で時間だけを失うため。
  - `check.sh` を実行したときだけ合否を `events.jsonl` に記録する(スキップ時は無記録)

---

## 使い方: プラグインと手動フォールバックの違い

スクリプトは同じだが、**プラグイン対応環境かどうか**で起動の主体が異なる。

### Claude Code / Codex app・CLI — Hooks 駆動（自動）

Claude Code と Codex app / CLI は、プラグインが提供する Hooks (`hooks/hooks.json`) を起動ドライバとするため、**エージェントが明示的にスクリプトを呼ぶ必要はない**。Codex は初回に `/hooks` で内容を確認して信頼する。

| タイミング | Hook | 実行チェイン | 効果 |
|-----------|------|-------------|------|
| ファイル編集直後 | `PostToolUse` (`Edit\|Write\|MultiEdit`) | `post_edit.sh` → `check_file.sh` | Claude の Edit/Write と Codex の `apply_patch` を検出。問題があれば `exit 2` で即時差し戻し → 自動修正 |
| 応答完了前 | `Stop` | `on_stop.sh` → `check.sh` | FAILがあれば完了をブロック → 修正を継続(前回の成功検査以降に変更が無ければ検査自体を省略) |

- **ルールの反映**: `apply-feedback` スキルが `.feedback/rules.md` を読み込む。`init.sh` を併用している場合は、`CLAUDE.md` / `AGENTS.md` の規約が Hooks 無効時の手動手順も示す。
- **指摘の記録**: `capture-feedback` / `feedback-loop` スキルが `feedback.sh` を呼ぶ。
- スキル・エージェントの起動条件と手順はプロジェクトルート README.md の「Skills / Agents / Commands の使い方（プラグイン導入時）」節を参照（`init.sh` 導入では配られず、下記の規約駆動が代替）。
- **設定ファイル**: プラグインの `hooks/hooks.json` + `skills/`。Claude Code は `.claude-plugin/plugin.json`、Codex は `.codex-plugin/plugin.json` を読む。`CLAUDE.md` / `AGENTS.md` の規約は `init.sh` 併用時に追加される。

### Claude Code の init-only / Codex IDE 拡張 / 汎用エージェント — 規約駆動（手動）

`init.sh` だけで導入した環境や Hooks が無効・未信頼の環境では、Claude Code は `CLAUDE.md`、Codex IDE 拡張と汎用エージェントは `AGENTS.md` の規約を自動ループの代替とする。エージェント自身が規約に従ってスクリプトを呼ぶ（自動ではない）。

| タイミング | 実行コマンド | 根拠 |
|-----------|-------------|------|
| セッション開始時 | `bash scripts/feedback.sh rules` | ルールを作業方針に反映 (§1) |
| コード変更のたび | `bash scripts/check_file.sh <編集したファイル>` | 即時チェック、問題あれば修正 (§2) |
| 完了前 | `bash scripts/check.sh` | `ALL PASS` を確認してから完了。FAILのまま報告してはならない (§3) |
| 指摘を受けたら | `bash scripts/feedback.sh add --category … --summary … --source human` | その場で記録(引き継ぐ唯一の手段) (§4) |
| 振り返り・朝会 | `bash scripts/feedback.sh report --last --mark` | 期間ダイジェストを議題にし、実施後に基点を更新 |
| 監査を促されたら | `bash scripts/audit.sh` | `stats`/`report` が「監査を推奨」を出したとき(7日超過・未実行) |

- **ルールの反映**: `CLAUDE.md` / `AGENTS.md` §1 で `.feedback/rules.md` の必読を規定。
- **設定ファイル**: `CLAUDE.md` または `AGENTS.md`（Hooks 不要）。

### 比較まとめ

| 観点 | プラグイン（Claude Code / Codex） | `init.sh`（Claude Code / Codex IDE 拡張 / 汎用） |
|------|-------------|-------------|
| 起動ドライバ | Hooks（自動） | CLAUDE.md / AGENTS.md 規約（エージェント自律） |
| 編集直後チェック | `PostToolUse` で自動 | 都度 `check_file.sh` を手動実行 |
| 完了前チェック | `Stop` で自動（ブロック付き） | 完了前に `check.sh` を手動実行 |
| ルール反映 | `apply-feedback` スキル | `CLAUDE.md` / `AGENTS.md` §1 規約 |
| 指摘記録 | `capture-feedback` / `feedback-loop` スキル | `CLAUDE.md` / `AGENTS.md` §4 手順で手動 |
| 主な設定・指示ファイル | `hooks/hooks.json`、`.claude-plugin/plugin.json` / `.codex-plugin/plugin.json` | `CLAUDE.md` / `AGENTS.md` |
| 共有スクリプト | `scripts/*`, `.feedback/` | ← 同じ |

---

## 必要ツール

- **必須**: `bash`, Python 3.10 以上（`python3` または `python`。Hooks 内の JSON パース・フィードバック CLI・JSON/YAML 検証・内部リンク検証で使用）
- **任意 — スタック標準**(自動検出・未インストールなら `SKIP`): `ruff`, `mypy`, `pytest` / `npm`/`pnpm`/`yarn`, `eslint`, `tsc` / `go`, `gofmt` / `cargo`, `rustfmt`, `clippy` / `mvn`, `gradle` / `shellcheck`
- **任意 — 拡張検査**: `pytest-cov`(カバレッジ)/ `deptry`, `vulture`, `import-linter`(Python の依存・デッドコード・アーキ制約)/ `secretlint`, `dockerfilelint`, `knip`, `prettier`(npm 経由。このリポジトリの `package.json` が例)/ `gitleaks`, `actionlint`, `hadolint`, `oasdiff`, `cargo-semver-checks`(OS固有バイナリのため PATH にあれば使う)
- **任意 — 監査専用**(`audit.sh` のみ・ネットワーク使用): `pip-audit` / `npm` / `govulncheck` / `cargo-audit`

いずれもハーネスが導入することはない。`npx --no-install` を使うのは、未導入時にネットワークから勝手に取得させないため。

Windows では Git for Windows 付属の Git Bash から既存の `*.sh` を実行する。Python の executable 名は共通ランナーが解決するため、PowerShell 用スクリプトは不要。 `python3` / `python` と異なる名前・パスの Python を使う場合は `HARNESS_PYTHON` で明示する。

## 他プロジェクトへの導入

> このセクションは**ハーネス配布元リポジトリ**での操作を説明する。導入先には `scripts/init.sh` 自体と `docs/` はコピーされないため、再導入・更新は配布元から行う。

`scripts/init.sh` が `scripts/`(このファイルの英語版・日本語版・簡体字中国語版を含む)を対象プロジェクトへコピーする。`scripts/README.md`、`scripts/README.ja.md`、`scripts/README.zh-CN.md` は導入先でも参照できる。

導入先に持ち込むのは**ハーネスの仕組みだけ**で、このリポジトリ固有の内容は持ち込まない:

- `.feedback/rules.md` のシードは `.feedback/rules.template.md`(ヘッダのみ)。導入元の promote 済みルールと、導入先に存在しない出典IDは混入しない
- `CLAUDE.md` / `AGENTS.md` へ追加するのは `docs/pointer_claude.md` / `docs/pointer_agents.md` の断片。`feedback-harness:pointer` 管理マーカー内だけを再実行時に置換し、マーカー外の利用者記述は保持する。マーカー導入前の旧ポインタは、既知の見出しと末尾を特定できる場合だけ管理ブロックへ移行する

```bash
bash scripts/init.sh /path/to/your-project
cd /path/to/your-project && bash scripts/check.sh   # スタック検出の確認
```
