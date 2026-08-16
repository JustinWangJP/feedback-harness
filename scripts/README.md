# scripts/ — フィードバックハーネスの実行エンジン

フィードバックハーネスを動かす全スクリプトを置くディレクトリ。上位の [README](../README.md) がハーネス全体の概要、このファイルはスクリプト単位の**役割・設計仕様・利用方法**を扱う。

スクリプトと蓄積データ(`.feedback/`)は **Claude Code / Codex 両環境で完全共有**。環境固有なのは「誰が・いつスクリプトを起動するか」のエントリポイントだけ(後述)。

## 構成

```text
scripts/
├── check.sh          # フルチェック: スタック自動検出 → lint/typecheck/test/build、要約出力
├── check_file.sh     # 単一ファイル高速チェック: 拡張子ベースの静的チェック
├── lib.sh            # check.sh / check_file.sh の共有ユーティリティ(has() ほか)
├── feedback_log.py   # フィードバック記録CLI: add/list/search/promote/merge/close/retire/rules
└── hooks/
    ├── post_edit.sh  # Claude Code PostToolUse(Edit|Write) ラッパ → check_file.sh
    └── on_stop.sh    # Claude Code Stop ラッパ → check.sh
```

2系統に分かれる:

| 系統 | スクリプト | 役割 |
|------|-----------|------|
| 自動チェック | `check.sh`, `check_file.sh`, `hooks/*` | lint/test/build 結果をエージェントに返し、自己修正させる |
| フィードバック蓄積 | `feedback_log.py` | 人間の指摘を記録・一般化し、次セッションに引き継ぐ |

## 設計思想(共通)

1. **出力はエージェント向け**: 成功は1行、失敗は末尾要約のみ。長大なログ全文は吐かない(トークンを食うため)。
2. **寛容な検出**: ツール未インストールのステージは `SKIP` で、失敗扱いにしない。ハーネス側でスタックを強要しない。
3. **宣言の有無で強度を決める**: プロジェクトが設定ファイルで宣言した検査は `FAIL`(完了をブロック)、ハーネスが推測で走らせる検査は `WARN`(報告のみ・exit 0)。宣言していない検査で完了不能にすると、導入初日の既存プロジェクトが作業できなくなる。WARN は `events.jsonl` に記録され `stats` / `report` の「頻出WARN」に現れる。
4. **ツールを自動インストールしない**: 未導入は `SKIP` と理由表示に留める。インストールは環境を変える行為であり、導入の判断はユーザーが行う。
5. **スタック非依存**: プロジェクト種別をマニフェスト(`pyproject.toml`/`package.json`/…)から自動検出。設定不要。
6. **ステートレス**: スクリプト自身は状態を持たない。すべての状態は `.feedback/`(ファイル)に置かれ、Gitで追跡・共有される。

---

## 各スクリプトの仕様

### `check.sh` — フルチェック(完了前 / CI用)

```bash
bash scripts/check.sh [プロジェクトルート]          # 省略時はカレントディレクトリ
FEEDBACK_CHECK_SKIP="test build" bash scripts/check.sh   # 特定ステージをスキップ
```

**動作:** 検出したスタックごとに `lint` / `typecheck` / `test` / `build` / `format` を走らせ、スタック非依存の横断チェック(設定ファイルの構文)も実行して、`PASS`/`FAIL`/`WARN`/`SKIP` の要約を出す。

- **検出対象**: Python(`pyproject.toml`/`setup.py`/`requirements.txt`、無くても `*.py` があれば `ruff` のみ実行) / Node(`package.json`) / Go(`go.mod`) / Rust(`Cargo.toml`) / Java(`pom.xml`/`build.gradle`) / Shell(`*.sh`) / 汎用(`Makefile` の `check` ターゲット)
- **横断チェック(スタック非依存)**: `*.json` / `*.yaml` / `*.yml` の構文検証。`tsconfig*.json` / `jsconfig*.json` / `devcontainer.json` / `.vscode/` 配下はコメント付き(JSONC)が慣例のため対象外。YAML は複数文書(`---` 区切り)に対応し、未知のカスタムタグ(`!Ref` 等)は構文エラーとして扱わない。PyYAML 未導入なら YAML は理由付き `SKIP`
- **ステージスキップ**: `FEEDBACK_CHECK_SKIP` に指定できるステージ名は `lint` / `typecheck` / `test` / `build` / `format`
- **make再帰ガード**: `make check` 実行時のみ `FEEDBACK_CHECK_RECURSION_GUARD` を子孫に伝え、その中で起動された check.sh は make フォールバックを `SKIP` する。フック実行時に `CLAUDE_PROJECT_DIR` が伝播し、テスト内の check.sh がルートを本リポジトリに解決し直して make check がテストを再実行する無限再帰(Stop フックの timeout を食い潰す)を断つためのもの。**通常の make 実行・直接ステージ(lint/test/build)には影響しない**
- **SKIPの理由**: 出力に必ず理由が付く — `(<tool> 未インストール)` / `(<tool> 起動不可 — 環境を確認してください)` / `(実行不可)` / `(FEEDBACK_CHECK_SKIP)`、およびスタック単位でまとめた `(<stack>: 全ステージ …)`。**ツールが無い・壊れているだけの状態を `FAIL` にしない**(ユーザーのコードの問題ではないため)
- **検査対象ファイル**: Gitリポジトリなら `git ls-files --cached --others --exclude-standard`。**未コミットの新規ファイルも検査し**、`.gitignore` 済みは除外する
- **ネットワークを使わない**: Node の typecheck フォールバックは `npx --no-install tsc`。`typescript` が未導入なら取得を試みず `SKIP` にする
- **shellcheck の重大度**: 既定は `warning`(`-S warning`)。`style`/`info` まで拾うと導入初日のプロジェクトが既存コードで詰まるため。`FEEDBACK_SHELLCHECK_SEVERITY=style` で引き上げられる
- **失敗出力**: `FAIL` したステージは末尾40行のログを `failures.txt` に集約し、最後にまとめて表示する
- **最終行**(FAIL時を除く。いずれも exit 0):

  | 最終行 | 意味 |
  |--------|------|
  | `ALL PASS` | 全ステージ成功 |
  | `ALL PASS (N件SKIP — 未検証の項目があります)` | 成功したが未検証あり |
  | `実行できたステージがありません(すべてSKIP)` | 何も検証できていない |
  | `検出できたスタックがありません …` | 対応マニフェスト・対象ファイルなし |

  全SKIPや部分SKIPを無印の `ALL PASS` と偽らない。
- **WARN**: 完了をブロックしない指摘。exit code は `0` のまま。最終行に件数が付く(`ALL PASS (1件WARN — 未対応の指摘があります)`)。現在の産出源は `python: ruff format`(`pyproject.toml` に `[tool.ruff` の宣言があれば `FAIL` に切り替わる)
- **exit code**: `0` = FAILなし(全SKIP・スタック未検出を含む) / `1` = FAILあり / `2` = ルートディレクトリ不正。**エージェントは最終行の文字列ではなく exit code で判定すること**

### `check_file.sh` — 単一ファイル高速チェック(編集直後用)

```bash
bash scripts/check_file.sh <ファイルパス>
```

**動作:** 拡張子でディスパッチし、フルビルドなしの静的チェックのみ(数秒)を行う。

| 拡張子 | チェック内容 |
|--------|-------------|
| `.py` | `ruff check`(無ければ `python3 -m py_compile`) |
| `.ts`/`.tsx`/`.js`/`.jsx`/`.mjs`/`.cjs` | ESLint設定があれば `eslint`、無ければ `.js`/`.mjs`/`.cjs` を `node --check` |
| `.go` | `gofmt -l`(未フォーマットを検出) |
| `.rs` | `rustfmt --check` |
| `.sh` | `bash -n` + `shellcheck`(あれば) |
| `.json`/`.yaml`/`.yml` | `python3` でパース検証 |

- **exit code**: `0` = 問題なし(またはファイル未指定・不存在) / `1` = 問題あり(内容を出力)

### `feedback_log.py` — フィードバック記録CLI

```bash
python3 scripts/feedback_log.py <サブコマンド> [引数]
```

エントリは `.feedback/log/` に frontmatter 付き Markdown、一般化ルールは `.feedback/rules.md` に昇華される。**logファイルを直接作成・編集せず、必ずこのCLIを使うこと**(frontmatter形式が揃わないと `list`/`promote` が壊れる)。

| サブコマンド | 引数 | 説明 |
|-------------|------|------|
| `add` | `--category <cat>` `--summary "<要約>"` `[--detail "<詳細>"]` `[--source human\|hook\|agent]` `[--signal <context\|instruction\|workflow\|failure>]` | エントリを記録。`open` が3件以上で promote 候補の通知を出す。`--signal` は信号種(省略時は detail/category から推論。昇華先ルーティングの軸) |
| `list` | `[--status open\|promoted\|closed\|retired\|all]` `[--category <cat>]` | エントリ一覧(既定は `open`) |
| `search` | `<キーワード>` | エントリの全文検索 |
| `promote` | `<entry-id>` `--rule "<一般化ルール1行>"` | `rules.md` に**新規ルールを追記**し、対象エントリを `promoted` に更新 |
| `merge` | `<entry-id>` `--into <既存ルールの出典id>` `[--rule "<更新後の本文>"]` | 既存ルールの**出典に追記**し(新規行を増やさない)、対象を `promoted` に更新。同じ原則の指摘が再発したとき用 |
| `close` | `<entry-id>` `[--reason "<理由>"]` | 昇華せず `closed` に更新。一般化できない一回限りの指摘用 |
| `retire` | `<出典entry-id>` `--reason "<退役理由>"` | 昇華済みルールを **rules.md から撤去**し、出典エントリ(merge済みの分も含む)を `retired` に更新。棚卸しで人間が裁定した後に使う |
| `rules` | (なし) | 現在の `rules.md` を表示 |
| `stats` | `[--since <日付>]` `[--days <N>]` | フック合否とログの集計。PostToolUse 初回通過率・平均再チェック回数・Stop 初回通過率・失敗上位・signal/根因別件数・**再発候補**(昇華後に同カテゴリの失敗系が再記録されたルール) |
| `report` | `--since <日付\|yesterday>` または `--last`、`[--mark]` | 期間ダイジェスト(新規エントリ/昇華/close・retire/open 棚卸し/再発候補/数字)。`--last` は `.feedback/.last-retro` 基点。`--mark` で実施後に基点を更新 |

- **category**: `style` / `architecture` / `testing` / `naming` / `workflow` / `domain`
- **entry-id**: 記録時刻 `%Y%m%d-%H%M%S`。同一秒に複数記録した場合は `-2`, `-3` … を付けて一意にする(重複すると `promote` が先頭の1件しか掴めず、残りが昇華不能になるため)

### `hooks/` — Claude Code Hooks ラッパ

Claude Code の Hooks から起動される薄いラッパ。判定・実行は `check_file.sh` / `check.sh` に委譲し、フック固有の処理(stdin JSONのパース、exit code 2 によるエージェントへの差し戻し、無限ループ防止)だけを担う。

- **`post_edit.sh`** (PostToolUse: `Edit|Write`): stdin の `tool_input.file_path` を取り出し `check_file.sh` でチェック。問題あれば **`exit 2` + stderr** で Claude にフィードバックし、自己修正ループを起動する。
  - 合否(成功・失敗の両方)を `.feedback/events.jsonl` に1行追記する(`stats` の初回通過率の原料。ローカル状態で共有しない)
- **`on_stop.sh`** (Stop): 応答完了前に `check.sh` を実行。失敗すれば **`exit 2`** で完了をブロックし失敗内容を返す。`stop_hook_active` が `true`(2周目以降)のときは何もせず `exit 0` し、**無限ループを防止**する。
  - **検査の実行条件**: 前回の成功検査(`.feedback/.last-check` のmtime)以降に作業ツリーが変わっているときだけ走る。無条件だと、ファイルを1つも編集しない質問応答のターンでも導入先のフルビルド(`mvn verify` / `npm run build` 等)が毎回動く。判定は mtime なので Edit/Write だけでなく Bash 経由の編集も拾い、判定できないときは必ず「実行する」側に倒す。
  - スタンプを進めるのは**検査が成功したときだけ**。失敗を記録すると、直さないまま次のターンで「変更なし」と判定され壊れたまま完了できてしまう。
  - 2周目で `check.sh` を再実行しないのは、`exit 0` で返す出力がエージェントに渡らず、重い導入先では最も待たされる場面で時間だけを失うため。
  - `check.sh` を実行したときだけ合否を `events.jsonl` に記録する(スキップ時は無記録)

---

## 使い方: Claude Code と Codex で何が違うか

スクリプトは同じだが、**起動のタイミングと主体が異なる**。

### Claude Code — Hooks 駆動(自動)

Claude Code はプラグインが提供する Hooks(`hooks/hooks.json`)を起動ドライバとするため、**エージェントが明示的にスクリプトを呼ぶ必要はない**。

| タイミング | Hook | 実行チェイン | 効果 |
|-----------|------|-------------|------|
| ファイル編集直後 | `PostToolUse` (`Edit\|Write`) | `post_edit.sh` → `check_file.sh` | 問題があれば `exit 2` で即時差し戻し → 自動修正 |
| 応答完了前 | `Stop` | `on_stop.sh` → `check.sh` | FAILがあれば完了をブロック → 修正を継続(前回の成功検査以降に変更が無ければ検査自体を省略) |

- **ルールの反映**: `apply-feedback` スキルが `.feedback/rules.md` を読み込む。`CLAUDE.md` のポインタが作業開始前にスキル使用を促す。
- **指摘の記録**: `capture-feedback` / `feedback-loop` スキルが `feedback_log.py` を呼ぶ。
- **設定ファイル**: プラグインの `hooks/hooks.json` + `skills/` + `agents/` + 導入先の `CLAUDE.md`。(このリポジトリ自身の開発では、これに加えて自己ドッグフーディング用の `.claude/settings.json` を使う)

### Codex / 汎用エージェント — 規約駆動(手動)

Codex など **Hooks を持たない環境**では、`AGENTS.md` の規約が自動ループの代替となる。エージェント自身が規約に従ってスクリプトを呼ぶ(自動ではない)。

| タイミング | 実行コマンド | 根拠 |
|-----------|-------------|------|
| セッション開始時 | `python3 scripts/feedback_log.py rules` | ルールを作業方針に反映 (§1) |
| コード変更のたび | `bash scripts/check_file.sh <編集したファイル>` | 即時チェック、問題あれば修正 (§2) |
| 完了前 | `bash scripts/check.sh` | `ALL PASS` を確認してから完了。FAILのまま報告してはならない (§3) |
| 指摘を受けたら | `python3 scripts/feedback_log.py add --category … --summary … --source human` | その場で記録(引き継ぐ唯一の手段) (§4) |

- **ルールの反映**: `AGENTS.md` §1 で `.feedback/rules.md` の必読を規定。
- **設定ファイル**: `AGENTS.md` のみ(Hooks 不要)。

### 比較まとめ

| 観点 | Claude Code | Codex / 汎用 |
|------|-------------|-------------|
| 起動ドライバ | Hooks(自動) | AGENTS.md 規約(エージェント自律) |
| 編集直後チェック | `PostToolUse` で自動 | 都度 `check_file.sh` を手動実行 |
| 完了前チェック | `Stop` で自動(ブロック付き) | 完了前に `check.sh` を手動実行 |
| ルール反映 | `apply-feedback` スキル | `AGENTS.md` §1 規約 |
| 指摘記録 | `capture-feedback`/`feedback-loop` スキル | `AGENTS.md` §4 手順で手動 |
| 必須設定ファイル | `.claude/settings.json`, `CLAUDE.md` | `AGENTS.md` のみ |
| 共有スクリプト | `scripts/*`, `.feedback/` | ← 同じ |

---

## 必要ツール

- **必須**: `bash`, `python3`(hooks内のJSONパース・`feedback_log.py`・json/yaml検証で使用)
- **任意**(スタックに応じて自動検出・未インストールなら `SKIP`): `ruff`, `mypy`, `pytest` / `npm`/`pnpm`/`yarn`, `eslint`, `tsc` / `go`, `gofmt` / `cargo`, `rustfmt`, `clippy` / `mvn`, `gradle` / `shellcheck`

## 他プロジェクトへの導入

> このセクションは**ハーネス配布元リポジトリ**での操作を説明する。導入先には `scripts/init.sh` 自体と `docs/` はコピーされないため、再導入・更新は配布元から行う。

`scripts/init.sh` が `scripts/`(このファイルを含む)を対象プロジェクトへコピーする。`scripts/README.md` も導入先で参照できる。

導入先に持ち込むのは**ハーネスの仕組みだけ**で、このリポジトリ固有の内容は持ち込まない:

- `.feedback/rules.md` のシードは `.feedback/rules.template.md`(ヘッダのみ)。導入元の promote 済みルールと、導入先に存在しない出典IDは混入しない
- `CLAUDE.md` / `AGENTS.md` へ追記するのは `docs/pointer_claude.md` / `docs/pointer_agents.md` の断片。導入元のH1(プロジェクト名)や変更履歴は入らない

```bash
bash scripts/init.sh /path/to/your-project
cd /path/to/your-project && bash scripts/check.sh   # スタック検出の確認
```
