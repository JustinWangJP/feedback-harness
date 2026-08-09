# scripts/ — フィードバックハーネスの実行エンジン

フィードバックハーネスを動かす全スクリプトを置くディレクトリ。上位の [README](../README.md) がハーネス全体の概要、このファイルはスクリプト単位の**役割・設計仕様・利用方法**を扱う。

スクリプトと蓄積データ(`.feedback/`)は **Claude Code / Codex 両環境で完全共有**。環境固有なのは「誰が・いつスクリプトを起動するか」のエントリポイントだけ(後述)。

## 構成

```text
scripts/
├── check.sh          # フルチェック: スタック自動検出 → lint/typecheck/test/build、要約出力
├── check_file.sh     # 単一ファイル高速チェック: 拡張子ベースの静的チェック
├── feedback_log.py   # フィードバック記録CLI: add/list/search/promote/rules
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
3. **スタック非依存**: プロジェクト種別をマニフェスト(`pyproject.toml`/`package.json`/…)から自動検出。設定不要。
4. **ステートレス**: スクリプト自身は状態を持たない。すべての状態は `.feedback/`(ファイル)に置かれ、Gitで追跡・共有される。

---

## 各スクリプトの仕様

### `check.sh` — フルチェック(完了前 / CI用)

```bash
bash scripts/check.sh [プロジェクトルート]          # 省略時はカレントディレクトリ
FEEDBACK_CHECK_SKIP="test build" bash scripts/check.sh   # 特定ステージをスキップ
```

**動作:** 検出したスタックごとに `lint` / `typecheck` / `test` / `build` を走らせ、`PASS`/`FAIL`/`SKIP` の要約を出す。

- **検出対象**: Python(`pyproject.toml`/`setup.py`/`requirements.txt`) / Node(`package.json`) / Go(`go.mod`) / Rust(`Cargo.toml`) / Java(`pom.xml`/`build.gradle`) / 汎用(`Makefile` の `check` ターゲット)
- **ステージスキップ**: 環境変数 `FEEDBACK_CHECK_SKIP` に空白区切りでステージ名(`lint`/`typecheck`/`test`/`build`)を指定すると該当ステージを `SKIP` にする
- **失敗出力**: `FAIL` したステージは末尾40行のログを `failures.txt` に集約し、最後にまとめて表示する
- **exit code**: `0` = ALL PASS(またはスタック未検出) / `1` = FAILあり / `2` = ルートディレクトリ不正

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
| `add` | `--category <cat>` `--summary "<要約>"` `[--detail "<詳細>"]` `[--source human\|hook\|agent]` | エントリを記録。`open` が3件以上で promote 候補の通知を出す |
| `list` | `[--status open\|promoted\|all]` `[--category <cat>]` | エントリ一覧(既定は `open`) |
| `search` | `<キーワード>` | エントリの全文検索 |
| `promote` | `<entry-id>` `--rule "<一般化ルール1行>"` | `rules.md` に追記し、対象エントリを `promoted` に更新 |
| `rules` | (なし) | 現在の `rules.md` を表示 |

- **category**: `style` / `architecture` / `testing` / `naming` / `workflow` / `domain`
- **entry-id**: 記録時刻 `%Y%m%d-%H%M%S`

### `hooks/` — Claude Code Hooks ラッパ

Claude Code の Hooks から起動される薄いラッパ。判定・実行は `check_file.sh` / `check.sh` に委譲し、フック固有の処理(stdin JSONのパース、exit code 2 によるエージェントへの差し戻し、無限ループ防止)だけを担う。

- **`post_edit.sh`** (PostToolUse: `Edit|Write`): stdin の `tool_input.file_path` を取り出し `check_file.sh` でチェック。問題あれば **`exit 2` + stderr** で Claude にフィードバックし、自己修正ループを起動する。
- **`on_stop.sh`** (Stop): 応答完了前に `check.sh` を実行。失敗すれば **`exit 2`** で完了をブロックし失敗内容を返す。`stop_hook_active` が `true`(2周目以降)のときは結果表示のみでブロックせず、**無限ループを防止**する。

---

## 使い方: Claude Code と Codex で何が違うか

スクリプトは同じだが、**起動のタイミングと主体が異なる**。

### Claude Code — Hooks 駆動(自動)

Claude Code は `.claude/settings.json` の Hooks を起動ドライバとするため、**エージェントが明示的にスクリプトを呼ぶ必要はない**。

| タイミング | Hook | 実行チェイン | 効果 |
|-----------|------|-------------|------|
| ファイル編集直後 | `PostToolUse` (`Edit\|Write`) | `post_edit.sh` → `check_file.sh` | 問題があれば `exit 2` で即時差し戻し → 自動修正 |
| 応答完了前 | `Stop` | `on_stop.sh` → `check.sh` | FAILがあれば完了をブロック → 修正を継続 |

- **ルールの反映**: `apply-feedback` スキルが `.feedback/rules.md` を読み込む。`CLAUDE.md` のポインタが作業開始前にスキル使用を促す。
- **指摘の記録**: `capture-feedback` / `feedback-loop` スキルが `feedback_log.py` を呼ぶ。
- **設定ファイル**: `.claude/settings.json`(Hooks) + `.claude/skills/` + `.claude/agents/` + `CLAUDE.md`。

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

`install.sh`(上位ディレクトリ)が `scripts/` を含むハーネス一式を対象プロジェクトへコピーする。`scripts/README.md` も導入先で参照できる。

```bash
bash install.sh /path/to/your-project
cd /path/to/your-project && bash scripts/check.sh   # スタック検出の確認
```
