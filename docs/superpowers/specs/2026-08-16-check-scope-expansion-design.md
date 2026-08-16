# 自動フィードバックの適用範囲拡張 設計

- 日付: 2026-08-16
- 動機: ハーネス自体の汎用強化(特定プロジェクトの不足を埋めるのではなく、どの導入先でも効く検査を増やす)
- 採用範囲(ユーザー確定): **Tier 0(既存の穴)+ Tier B 3系統(秘密情報・アーキ制約・IaC/CI lint)**。Tier C(依存監査・カバレッジ)は効果測定後に別途判断
- ステータス: 設計済み・未実装

---

## 1. 現状と問題

現在の自動フィードバックは **4ステージ(lint / typecheck / test / build)× 2粒度 × 7スタック**で、実質「言語処理系とその標準ツールが検出できる欠陥」に限定されている。カバーしているのは*正しさの検証*(動くか)だけで、セキュリティ・設計整合性・運用設定という次元が空いている。

加えて、調査で**既存の欠陥3件**が判明した。拡張の前提としてこれらを直す。

| # | 欠陥 | 箇所 | 影響 |
|---|---|---|---|
| D1 | `check.sh` に YAML/JSON 検証ステージが無い(`check_file.sh` にはある) | `check.sh` 全体 | Bash経由・外部エディタで壊された設定ファイルが完了前チェックをすり抜ける。過去に Shell ステージを追加したときと同じ非対称性(`check.sh:167` のコメント参照) |
| D2 | JSON検証が `json.load` のみ | `check_file.sh:55` | コメント付きJSON(`tsconfig.json`・`.vscode/settings.json`・`devcontainer.json` は慣例的に JSONC)を編集すると誤ブロック |
| D3 | YAML検証が `safe_load`(単一文書・標準タグのみ) | `check_file.sh:61` | 複数文書YAML(`---` 区切りのk8sマニフェスト等)とカスタムタグ(CloudFormation `!Ref` 等)で誤ブロック |

D2・D3 を直さずに D1 を横展開すると、誤検出が単一ファイルからリポジトリ全体へ拡大する。

## 2. スコープ

### 採用

| 層 | 検査 | 検出条件 | ツール |
|---|---|---|---|
| Tier 0 | YAML/JSON 構文検証 | 対象ファイルが存在 | 不要(python3 / PyYAML があれば YAML も) |
| Tier B | 秘密情報スキャン | `gitleaks` がある | gitleaks |
| Tier B | アーキ制約(Python) | import-linter の設定がある | import-linter (`lint-imports`) |
| Tier B | CI設定 lint | `.github/workflows/*.y*ml` がある | actionlint |
| Tier B | Dockerfile lint | `Dockerfile*` がある | hadolint |

### 非採用(理由を明記して残す)

| 対象 | 不採用の理由 |
|---|---|
| フォーマット検証(prettier / ruff format --check) | 既存プロジェクトがフォーマッタ未使用だと全ファイルFAILになり、導入初日に完了不能になる。`check_file.sh` が編集時に gofmt/rustfmt で部分的にカバー済み。リスク>価値 |
| kubeconform(k8sマニフェスト) | 「どのYAMLがk8sか」を確実に判定できず、スキーマ取得にネットワークが要る(ネットワーク不使用の原則に反する) |
| tflint / terraform | プラグイン初期化(`tflint --init`)が要る構成が多く、未初期化での誤FAILリスクが高い |
| アーキ制約(Node: dependency-cruiser) | 対象パス指定が必須で自動検出が困難。Node は `npm run lint` 経由で既にプロジェクト側から実行できる(既存経路に委ねる) |
| 依存監査(pip-audit / npm audit / govulncheck) | ネットワークを使い、Stopフックの `timeout 300` を共有する。毎ターン実行は 2026-08-12 に解消した過剰実行問題の再発。**Tier C として後日判断** |
| カバレッジ・複雑度・デッドコード | 遅い、または汎用ツールが弱い |
| `.feedback/checks.toml` による検査の設定化 | 「設定不要・自動検出」という設計哲学を壊す。YAGNI |

## 3. Tier 0 設計 — 設定ファイル構文検証

### 3.1 共有関数(ドリフト防止)

`check_file.sh` と `check.sh` が同じ判定を独立に持つとドリフトする(`lib.sh` の冒頭コメントが記録する `has()` の実例)。検証ロジックは `lib.sh` に置き、両者から呼ぶ。

```bash
harness_has_pyyaml()                  # PyYAML が import できるか
harness_validate_json <file...>       # 壊れていれば "path: 理由" を出力し非0
harness_validate_yaml <file...>       # 同上
```

- `harness_validate_json`: **JSONC 除外リスト**に一致するファイルは検証しない(D2)。除外対象は basename が `tsconfig*.json` / `jsconfig*.json` / `devcontainer.json`、およびパスに `/.vscode/` を含むもの。理由: これらはコメント付きが慣例で、標準JSONパーサでは原理的に検証できない
- `harness_validate_yaml`: `yaml.safe_load_all` で**複数文書**に対応し(D3)、`yaml.constructor.ConstructorError`(未知のカスタムタグ)は**構文エラーではない**ため PASS 扱いにする。捕捉するのは `yaml.YAMLError` のうちパーサ・スキャナ由来のものに限る
- python3 不在時、および PyYAML 不在時(YAMLのみ)は**検証せず成功**を返す — 環境の問題をユーザーのコードの失敗として報告しない(既存の設計原則)

### 3.2 `check_file.sh` の改修

`*.json` / `*.yaml|*.yml` の分岐を共有関数の呼び出しに置き換える。外形的な振る舞い(問題があれば出力して exit 1、なければ無出力で exit 0)は不変。D2・D3 の誤ブロックが解消される。

### 3.3 `check.sh` への新ステージ

スタック別セクションの後、汎用フォールバックの前に**横断チェック節**を新設する(現行の構成はスタック別だが、これらはスタック非依存であるため節を分ける)。

```
# ---------- 横断チェック(スタック非依存) ----------
```

- 対象ファイルは既存の `list_files` で取得(git 管理下 + 未追跡かつ非 gitignore)。`node_modules` 等は従来どおり除外される
- ステージ名は `lint`(`bash -n` と同じ「構文検証」の位置づけ)
- ファイルが1件も無ければ何も記録しない(`STACK_FOUND` も立てない — 設定ファイルだけの存在を「スタック検出」とは呼ばない)
- PyYAML 不在時は `SKIP  config: yaml 構文 (PyYAML 未インストール)` と理由付きで記録する

## 4. Tier B 設計

### 4.1 秘密情報スキャン

- 検出: `has gitleaks`
- ステージ名: **`security`**(新設。既存の `lint`/`typecheck`/`test`/`build` に1語だけ追加する)
- コマンド: `gitleaks detect --no-git --redact --no-banner -s "$ROOT"`
  - `--no-git`: 履歴ではなく**作業ツリー**を走査する。履歴走査は遅く、過去のコミットを指摘しても現在の作業を直せない
  - `--redact`: **必須**。検出した秘密の値そのものを出力させない。`check.sh` の失敗ログはエージェントのコンテキストと `failures.txt` に入るため、値を出力すると秘密が別の場所へ拡散する
- **バージョン差の扱い**: gitleaks v8 系で `detect --no-git` を前提とする。フラグ非対応版では exit 1(=FAIL)になり誤検出になるため、実行前にプローブする — `gitleaks detect --help` の出力に文字列 `--no-git` と `--redact` の**両方が含まれること**を確認し、含まれなければ `SKIP  security: gitleaks (この版は detect --no-git/--redact に非対応)` とする。ヘルプの終了コードだけでは不十分(未対応版でもヘルプ自体は成功するため)。既存の `npx --no-install tsc --version` プローブと同じ発想
- 既存プロジェクトの初日FAIL: `FEEDBACK_CHECK_SKIP="security"` と gitleaks 自身の `.gitleaksignore` で逃がせる。この逃げ道を README に明記する

### 4.2 アーキ制約(Python)

- 検出: import-linter の設定が存在し(`.importlinter` / `setup.cfg` の `[importlinter]` / `pyproject.toml` の `[tool.importlinter]`)、かつ `has lint-imports`
- ステージ名: `lint`
- コマンド: `lint-imports`
- 設計上の位置づけ: **設定がある時のみ実行**は mypy と同じ既存パターン。設定を書いた=意図的に制約を宣言したということなので、誤検出は原理的に起きない

### 4.3 CI設定・Dockerfile lint

- actionlint: `.github/workflows/*.yml|*.yaml` が存在し `has actionlint` → `actionlint`(引数なしで自動的にワークフローを探す)。ステージ `lint`
- hadolint: Dockerfile が存在し `has hadolint` → `hadolint <検出したファイル>`。ステージ `lint`
  - 検出パターンは `list_files 'Dockerfile*'` と `list_files '*/Dockerfile*'` の和集合とする。git pathspec の `*` は `/` を跨ぐため `Dockerfile*` 単独ではルート直下しか当たらず、`docker/Dockerfile` を取りこぼす(`*.py` が全階層に当たるのとは非対称)
- どちらも対象ファイルが無ければ何も記録しない(SKIP行も出さない — 無関係なプロジェクトのノイズになる)

## 5. 出力とスキップ契約

- 新ステージ名 `security` を `FEEDBACK_CHECK_SKIP` の語彙に追加する。`skipped()` は部分文字列一致のため後方互換
- 「ツールが無ければ SKIP」の契約は維持する。ただし**検査を増やすほど SKIP 件数が増える**ため、既存の `ALL PASS (N件SKIP — 未検証の項目があります)` 表示がより重要になる。この表示は変更しない
- SKIP の理由文言は既存の形式(`(<tool> 未インストール)`)に揃える

## 6. 影響範囲

| ファイル | 変更 |
|---|---|
| `scripts/lib.sh` | `harness_has_pyyaml` / `harness_validate_json` / `harness_validate_yaml` を追加 |
| `scripts/check_file.sh` | JSON/YAML 分岐を共有関数へ置換(D2・D3 の修正) |
| `scripts/check.sh` | 横断チェック節を新設(YAML/JSON・gitleaks・import-linter・actionlint・hadolint) |
| `scripts/README.md` | ステージ表に `security` を追加、検査一覧・必要ツール・SKIP理由の記載を更新 |
| `README.md` | 「仕組み」の検査内容、必要ツール(任意)の一覧を更新 |
| `CLAUDE.md` | 変更履歴に1行 |
| `.claude-plugin/plugin.json` | 0.3.0 → 0.4.0 |
| `tests/` | 新規2本(§7) |

`AGENTS.md` / `docs/pointer_*.md` は変更不要 — 最終行の意味(`ALL PASS` 系)と exit code 契約は変わらないため。

## 7. テスト方針

既存規約(`tests/test_*.sh` + `assert.sh`、期待値はリテラル、判定は自前カウンタと `assert_summary`)に従う。外部ツールは**PATH に偽実行ファイルを置いて**駆動する(`test_on_stop_skip.sh` が偽 `check.sh` で確立した手法)。

| テスト | 検証内容 |
|---|---|
| `tests/test_config_syntax.sh` | 壊れたJSON/YAMLを検出する / 正当な複数文書YAMLとカスタムタグYAMLを**誤検出しない**(D3の回帰)/ JSONC除外リストのファイルを検証しない(D2の回帰)/ PyYAML不在を模した場合にYAMLがSKIPされる / `check_file.sh` と `check.sh` の双方で同じ判定になる |
| `tests/test_check_extended.sh` | 偽 `gitleaks`/`actionlint`/`hadolint`/`lint-imports` をPATHに置き、(a) 対象ファイル・設定が無ければ実行されない (b) あれば実行されFAILが伝播する (c) ツール不在ならSKIPになる (d) gitleaks 呼び出しに `--redact` が渡る |

`bash scripts/check.sh` が `ALL PASS` であることを完了条件とする。

## 8. 未検証事項(正直な記録)

開発環境に gitleaks / actionlint / hadolint / import-linter が**いずれも導入されていない**ため、実ツールでの動作確認はできない。テストは偽実行ファイルで**呼び出し契約**(引数・検出条件・SKIP/FAILの分岐)を固定するに留まる。実ツールとの結合は、これらを導入している環境での初回実行が最初の検証機会になる。特に gitleaks のバージョン差(§4.1)は実機確認が必要で、そのためにプローブによる安全側フォールバックを設計に含めている。

## 9. 実装順序

1. **D2・D3 の修正 + 共有関数**(`lib.sh` + `check_file.sh`)— 既存バグの解消が先。ここだけで単独の価値がある
2. **Tier 0**(`check.sh` の横断チェック節に YAML/JSON)— D1 の解消
3. **Tier B**(gitleaks → import-linter → actionlint/hadolint の順。各々独立)
4. ドキュメント・バージョン(0.4.0)・全体チェック

各ステップはテスト先行(TDD)で進める。
