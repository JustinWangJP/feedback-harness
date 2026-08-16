# 自動フィードバックの適用範囲拡張 設計

- 日付: 2026-08-16
- 動機: ハーネス自体の汎用強化(特定プロジェクトの不足を埋めるのではなく、どの導入先でも効く検査を増やす)
- 採用範囲(ユーザー確定): **全11系統**。当初案の Tier 0 + Tier B 3系統に加え、ユーザー指示により**依存の脆弱性・実在性 / フォーマット / カバレッジ / API契約・破壊的変更 / デッドコード / ドキュメント整合性**を追加
- ステータス: 設計済み・未実装

---

## 1. 背景

現在の自動フィードバックは **4ステージ(lint / typecheck / test / build)× 2粒度 × 7スタック**で、実質「言語処理系とその標準ツールが検出できる欠陥」に限定されている。カバーしているのは*正しさの検証*(動くか)だけで、セキュリティ・設計整合性・保守性・運用設定という次元が空いている。

### 1.1 調査で判明した既存欠陥

| # | 欠陥 | 箇所 | 影響 |
|---|---|---|---|
| D1 | `check.sh` に YAML/JSON 検証ステージが無い(`check_file.sh` にはある) | `check.sh` 全体 | Bash経由・外部エディタで壊された設定ファイルが完了前チェックをすり抜ける。過去に Shell ステージを追加したときと同じ非対称性(`check.sh:167` のコメント参照) |
| D2 | JSON検証が `json.load` のみ | `check_file.sh:55` | コメント付きJSON(`tsconfig.json`・`.vscode/settings.json`・`devcontainer.json` は慣例的に JSONC)を編集すると誤ブロック |
| D3 | YAML検証が `safe_load`(単一文書・標準タグのみ) | `check_file.sh:61` | 複数文書YAML(`---` 区切りのk8sマニフェスト等)とカスタムタグ(CloudFormation `!Ref` 等)で誤ブロック |

D2・D3 を直さずに D1 を横展開すると、誤検出が単一ファイルからリポジトリ全体へ拡大する。よって**既存欠陥の修正を最初のフェーズに置く**。

### 1.2 拡張が突き当たる2つの制約と、その解き方

当初、以下は「毎ターンの遅延」「導入初日の全FAIL」を理由に見送る設計だった。ユーザー判断により全採用へ変更し、除外ではなく**機構で解く**方針を採る。

| 制約 | 誰が当たるか | 解決機構 |
|---|---|---|
| `check.sh` は Stop フックで毎ターン走り `timeout 300` を共有する。ネットワークや重い解析を入れると 2026-08-12 に解消した過剰実行問題が再発する | 脆弱性監査・API契約差分・カバレッジ | **M2 遅延実行**(入力ハッシュが変わったときだけ)+ **M3 相乗り**(既存 test ステージにカバレッジを同居させる) |
| 既存プロジェクトが未整備の領域(未フォーマット・未使用コード)を一律 FAIL にすると、導入初日から完了不能になる(shellcheck 重大度で過去に扱った問題) | フォーマット・デッドコード・カバレッジ閾値 | **M1 WARN 結果クラス**(宣言していない検査は報告のみ) |

## 2. 実行モデルの拡張(3機構)

### M1. WARN — 非ブロッキングの第3の結果クラス

現在の結果は PASS / FAIL / SKIP の3つ。ここに **WARN**(問題は見つかったが完了をブロックしない)を追加する。

**判定原則 — 宣言の有無で強度を決める:**

> **プロジェクトが設定ファイルで意図を宣言している検査は FAIL(ブロック)。ハーネスが推測で走らせる検査は WARN(報告のみ)。**

これは既存の設計判断の一般化である(mypy は `[tool.mypy]` がある時だけ実行する、import-linter は設定がある時だけ実行する)。設定を書いた=チームがその制約を選んだということなので、FAIL にしても誤検出にならない。設定が無い場合はハーネスの押し付けになるため WARN に留める。

**出力と exit code:**
- WARN は結果行 `WARN  <label> (<理由の要約>)` として表示し、**exit code は 0 のまま**(FAIL のみが exit 1)
- 最終行に件数を添える: `ALL PASS (2件WARN・3件SKIP — 未検証/未対応の項目があります)`
- WARN の詳細ログは FAIL と同様に末尾へ出す(ただし FAIL とは節を分ける)

**WARN をフィードバックループに載せる(重要):**

`on_stop.sh` は成功時(exit 0)に出力を捨てるため、WARN はそのままではエージェントに届かない。そこで **WARN を `events.jsonl` に記録する**:

```json
{"ts":"...","hook":"stop","result":"warn","check":"format","count":3}
```

これにより:
- `stats` / `report` に「頻出WARN」として現れる(直前の Step 4 で作った測定基盤をそのまま使う)
- 反復する WARN は Flywheel の失敗シグナルそのものになる — チームが「設定を入れて FAIL に昇格させる」か「無視すると決める」かを、データを見て判断できる

WARN は「今は直さないが、溜まったら見える」ための仕組みであり、握り潰しではない。

### M2. 遅延実行 — 入力ハッシュが変わったときだけ走らせる

重い検査・ネットワークを使う検査は、**入力が変わっていなければ結果も変わらない**。入力のハッシュをスタンプに残し、一致する間はスキップする。

- スタンプ: `.feedback/.check-cache/<検査名>` に「入力ハッシュ + 前回結果」を記録(gitignore 対象のローカル状態)
- 入力ハッシュの定義は検査ごとに宣言する(下表参照)。例: 脆弱性監査の入力は lockfile
- 前回が PASS ならスキップ時に `SKIP  security: pip-audit (前回から lockfile 変更なし)` と理由を明示する。**前回が FAIL なら必ず再実行する**(直っていない可能性があるため、スキップは「壊れたまま完了できる」側の誤りになる)
- キャッシュを無視して強制実行する手段: `FEEDBACK_CHECK_FORCE=1`

これで脆弱性監査は「lockfile を更新したターンだけ走る」= 定常状態では実質ゼロコストになる。

### M3. 相乗り — カバレッジは既存の test ステージに同居させる

カバレッジ計測のために**テストを2回走らせない**。既存の test ステージのコマンドを差し替え、計測プラグインが利用可能なときだけ計装付きで実行する(`pytest --cov` / `go test -cover` / `jest --coverage`)。追加コストは計装のオーバーヘッド(概ね10〜30%)であり、実行時間の倍増ではない。

`cargo llvm-cov` のようにビルドをやり直す実装は相乗りにならないため対象外(SKIP)。

## 3. 検査カタログ

「宣言」列は M1 の判定原則の適用結果 — その設定があれば FAIL、無ければ WARN(または SKIP)。

### 3.1 構文・設定(Tier 0 / 既存欠陥の解消)

| 検査 | 検出条件 | コマンド | ステージ | 判定 |
|---|---|---|---|---|
| JSON構文 | `*.json` が存在 | 共有関数(§4.1) | lint | 常に FAIL(構文エラーは疑いようがない) |
| YAML構文 | `*.yaml`/`*.yml` が存在・PyYAML あり | 共有関数(§4.1) | lint | 常に FAIL |
| CI設定 | `.github/workflows/*.y*ml` + `actionlint` | `actionlint` | lint | FAIL |
| Dockerfile | Dockerfile + `hadolint` | `hadolint <files>` | lint | FAIL |

### 3.2 セキュリティ

| 検査 | 検出条件 | コマンド | ステージ | 判定 |
|---|---|---|---|---|
| 秘密情報 | `gitleaks` あり | `gitleaks detect --no-git --redact --no-banner -s .` | security | FAIL |
| 脆弱性(Python) | `pip-audit` あり | `pip-audit` | security | **M2遅延**(入力: `requirements*.txt` / `poetry.lock` / `uv.lock` / `pyproject.toml`)。FAIL |
| 脆弱性(Node) | `package-lock.json` 等 + npm | `npm audit --audit-level=high` | security | **M2遅延**(入力: lockfile)。FAIL |
| 脆弱性(Go) | `govulncheck` あり | `govulncheck ./...` | security | **M2遅延**(入力: `go.sum`)。FAIL |
| 脆弱性(Rust) | `cargo-audit` あり | `cargo audit` | security | **M2遅延**(入力: `Cargo.lock`)。FAIL |

`--redact` は必須 — `check.sh` の失敗ログはエージェントのコンテキストと `failures.txt` に入るため、秘密の値を出力すると別の場所へ拡散する。

### 3.3 依存の実在性・整合性(オフライン)

「AIが存在しないパッケージ名を書く」「宣言と実体がずれる」を**ネットワーク無しで**捕まえる。脆弱性監査(§3.2)とは別物であり、遅延実行は不要なほど速い。

| 検査 | 検出条件 | コマンド | ステージ | 判定 |
|---|---|---|---|---|
| Node | `node_modules` が存在 | `npm ls --all` | lint | FAIL(宣言と実体の不一致・欠損を検出)。`node_modules` 不在時は SKIP(未インストールを欠陥と呼ばない) |
| Python | `deptry` あり | `deptry .` | lint | FAIL(宣言に無い import・未使用依存) |
| Go | `go.sum` が存在 | `go mod verify` | lint | FAIL |
| Rust | `Cargo.lock` が存在 | `cargo metadata --offline --format-version 1 >/dev/null` | lint | FAIL |

### 3.4 フォーマット

| 検査 | 検出条件 | コマンド | ステージ | 判定 |
|---|---|---|---|---|
| Python | `ruff` あり | `ruff format --check .` | format | 宣言(`[tool.ruff.format]` または `[tool.ruff]`)あり → FAIL / 無し → **WARN** |
| Node | `prettier` 実行可能 | `npx --no-install prettier --check .` | format | 宣言(`.prettierrc*` / `package.json` の `prettier` キー)あり → FAIL / 無し → SKIP(設定なしの prettier は既定スタイルの押し付けになるため走らせない) |
| Go | `gofmt` あり | `gofmt -l <files>` | format | 常に FAIL(gofmt は言語標準であり、Goコミュニティの普遍的合意) |
| Rust | `rustfmt` あり | `cargo fmt --check` | format | 宣言(`rustfmt.toml`)あり → FAIL / 無し → **WARN** |

Go だけ扱いが違うのは、gofmt が事実上の言語仕様であり「宣言しないと従わない」性質のものではないため。

### 3.5 カバレッジ(M3 相乗り)

| 対象 | 条件 | コマンド | 判定 |
|---|---|---|---|
| Python | `pytest-cov` が import 可能 | `pytest -q -x --cov --cov-report=term-missing` | 閾値宣言(`--cov-fail-under` が設定ファイルにある)→ その閾値で FAIL / 無し → 数値を **WARN** で報告 |
| Go | 常に(標準機能) | `go test -cover ./...` | 閾値の標準的な宣言方法が無いため常に **WARN**(数値報告) |
| Node | `package.json` に `test:coverage` スクリプト | `npm run test:coverage` | スクリプトを書いた=宣言 → FAIL |

閾値が宣言されていない場合にカバレッジ低下で FAIL にしない理由: 初期段階のプロジェクトが常時ブロックされるため。数値は WARN として `events.jsonl` に載るので、傾向は `stats` で追える。

### 3.6 デッドコード

| 検査 | 検出条件 | コマンド | ステージ | 判定 |
|---|---|---|---|---|
| Python | `vulture` あり | `vulture . --min-confidence 80` | lint | 宣言(`.vulture` / `[tool.vulture]`)あり → FAIL / 無し → **WARN**。`--min-confidence 80` は誤検出(動的呼び出し・フレームワークのフック)を抑えるため |
| Node | `knip` 実行可能 | `npx --no-install knip` | lint | 宣言(`knip.json` / `package.json` の `knip` キー)あり → FAIL / 無し → SKIP(設定なしの knip はエントリポイント推定を誤り、大量の誤検出を出すため) |
| Go | `go vet` に含まれず、汎用ツールが弱い | — | — | 対象外 |

### 3.7 API契約・破壊的変更

ベースラインは**gitから取る**(ネットワーク不要・自己完結)。比較元は `git merge-base HEAD <既定ブランチ>`、解決できなければ `HEAD`(=作業ツリーの未コミット変更のみ)を使う。

| 検査 | 検出条件 | コマンド | ステージ | 判定 |
|---|---|---|---|---|
| OpenAPI | `openapi.yaml`/`openapi.json`(または `api/` 配下の同名)+ `oasdiff` あり | ベースライン版を一時ファイルへ取り出し `oasdiff breaking <base> <current>` | contract | **M2遅延**(入力: spec ファイルのハッシュ + ベースラインSHA)。FAIL |
| Rust ライブラリ | `cargo-semver-checks` あり + `[lib]` を持つ crate | `cargo semver-checks check-release` | contract | **M2遅延**。ビルドを伴い重いため、遅延必須。FAIL |

ツールが無ければ SKIP。破壊的変更の判定は本質的にツール依存であり、自前実装はしない。

### 3.8 ドキュメント整合性

ネットワークを使わない範囲に限定する — **内部リンク切れ**の検出。これは「AIがREADMEに書いたパスが実在しない」「ファイルを移動してリンクが腐る」という実際に頻出する欠陥を、外部依存ゼロで捕まえられる。

| 検査 | 検出条件 | コマンド | ステージ | 判定 |
|---|---|---|---|---|
| 内部リンク | `*.md` が存在 | 共有関数(§4.2、python3 実装) | docs | 常に **FAIL**(リンク先が実在しないのは事実誤りであり、好みの問題ではない) |

- 対象: Markdown のリンク `[text](path)` および画像 `![alt](path)` のうち、**相対パス**のもの
- 対象外: `http://` / `https://` / `mailto:`(ネットワークが要る)、アンカーのみ(`#section`)、絶対パス(`/...` はサイト設計依存)
- パスに `#anchor` が付く場合はファイル部分のみ検証する(見出しの正規化はツールごとに揺れるため踏み込まない)

## 4. 共有実装

### 4.1 設定ファイル構文検証(D1〜D3 の解消)

`check_file.sh` と `check.sh` が同じ判定を独立に持つとドリフトする(`lib.sh` の冒頭が記録する `has()` の実例)。ロジックは `lib.sh` に置き両者から呼ぶ。

```bash
harness_has_pyyaml()                  # PyYAML が import できるか
harness_validate_json <file...>       # 壊れていれば "path: 理由" を出力し非0
harness_validate_yaml <file...>       # 同上
```

- `harness_validate_json`: **JSONC 除外リスト**に一致するファイルは検証しない(D2)。除外は basename が `tsconfig*.json` / `jsconfig*.json` / `devcontainer.json`、およびパスに `/.vscode/` を含むもの。理由: コメント付きが慣例で、標準JSONパーサでは原理的に検証できない
- `harness_validate_yaml`: `yaml.safe_load_all` で**複数文書**に対応し(D3)、`yaml.constructor.ConstructorError`(未知のカスタムタグ)は**構文エラーではない**ため PASS 扱いにする。捕捉するのはパーサ・スキャナ由来の `yaml.YAMLError` に限る
- python3 不在時、PyYAML 不在時(YAMLのみ)は**検証せず成功**を返す — 環境の問題をユーザーのコードの失敗として報告しない(既存原則)

### 4.2 内部リンク検証

`lib.sh` に `harness_check_md_links <file...>` を置く。python3 のみで実装し、リンク先を各Markdownファイルからの相対パスで解決して存在確認する。

### 4.3 `check.sh` の構造

現行はスタック別セクションの並びだが、新規検査の多くはスタック非依存である。節を分ける:

```
# ---------- 横断チェック(スタック非依存) ----------   ← 構文・秘密情報・ドキュメント
```

スタック依存の追加検査(フォーマット・依存整合性・カバレッジ・脆弱性)は、既存の該当スタック節の中に置く。ファイル肥大の懸念があるため、**検査カタログが1スタックあたり6項目を超えたら** `check.sh` をスタック別ファイルへ分割する(今回は超えないため分割しない)。

## 5. ステージ語彙とスキップ契約

既存の `lint` / `typecheck` / `test` / `build` に4語を追加する:

| 新ステージ | 対象 |
|---|---|
| `security` | 秘密情報・脆弱性監査 |
| `format` | フォーマット検証 |
| `contract` | API契約・破壊的変更 |
| `docs` | ドキュメント整合性 |

`FEEDBACK_CHECK_SKIP="security format"` のように従来どおり除外できる(`skipped()` は部分文字列一致のため後方互換)。カバレッジは独立ステージにせず `test` に含める(M3 相乗りの帰結)。依存整合性・デッドコードは `lint` に含める。

## 6. 影響範囲

| ファイル | 変更 |
|---|---|
| `scripts/lib.sh` | `harness_has_pyyaml` / `harness_validate_json` / `harness_validate_yaml` / `harness_check_md_links` / M2 のキャッシュ判定 `harness_cache_valid` |
| `scripts/check_file.sh` | JSON/YAML 分岐を共有関数へ置換(D2・D3 修正) |
| `scripts/check.sh` | WARN 結果クラス(集計・表示・exit code)、横断チェック節、各スタック節への検査追加、M2 遅延実行、M3 相乗り |
| `scripts/hooks/on_stop.sh` | WARN 件数を `events.jsonl` に記録 |
| `scripts/feedback_log.py` | `stats` / `report` に WARN 集計を追加(頻出WARNの表示) |
| `.gitignore` | `.feedback/.check-cache/` |
| `scripts/README.md` | ステージ表・検査一覧・結果クラス(WARN)・必要ツール・`FEEDBACK_CHECK_FORCE` |
| `README.md` | 仕組み・必要ツール |
| `AGENTS.md` / `docs/pointer_agents.md` | 最終行の意味表に WARN 付きの行を追加(規約3) |
| `CLAUDE.md` | 変更履歴 |
| `.claude-plugin/plugin.json` | 0.3.0 → 0.4.0 |
| `tests/` | 新規4本(§7) |

## 7. テスト方針

既存規約(`tests/test_*.sh` + `assert.sh`、期待値はリテラル、判定は自前カウンタと `assert_summary`)に従う。外部ツールは **PATH に偽実行ファイルを置いて**駆動する(`test_on_stop_skip.sh` が確立した手法)。

| テスト | 検証内容 |
|---|---|
| `tests/test_config_syntax.sh` | 壊れたJSON/YAMLを検出 / 複数文書YAML・カスタムタグYAMLを**誤検出しない**(D3回帰)/ JSONC除外(D2回帰)/ PyYAML不在でSKIP / `check_file.sh` と `check.sh` で同判定 |
| `tests/test_check_warn.sh` | WARN が exit 0 のままであること / 最終行に件数が出ること / FAIL と混在したときは exit 1 になること / 宣言(設定ファイル)の有無で FAIL/WARN が切り替わること |
| `tests/test_check_cache.sh` | 入力ハッシュ不変ならスキップ / 入力変更で再実行 / **前回FAILなら入力不変でも再実行** / `FEEDBACK_CHECK_FORCE=1` で強制実行 |
| `tests/test_check_extended.sh` | 偽ツールで各検査の (a) 検出条件 (b) FAIL伝播 (c) ツール不在でSKIP (d) gitleaks に `--redact` が渡ること / 内部リンク切れの検出と外部URL・アンカーの除外 |

`bash scripts/check.sh` が `ALL PASS` であることを完了条件とする。

## 8. 未検証事項(正直な記録)

開発環境に gitleaks / actionlint / hadolint / import-linter / pip-audit / deptry / vulture / knip / oasdiff / cargo-semver-checks が**いずれも導入されていない**。テストは偽実行ファイルで**呼び出し契約**(引数・検出条件・SKIP/FAIL/WARNの分岐)を固定するに留まり、実ツールとの結合は導入済み環境での初回実行が最初の検証機会になる。

特に確認が必要な項目:
- gitleaks のサブコマンド構成はバージョン差が大きい(v8.19 で `detect` → `dir`/`git` に再編)。`gitleaks detect --help` の出力に `--no-git` と `--redact` の**両方が含まれること**をプローブし、無ければ SKIP する(ヘルプの終了コードだけでは不十分 — 未対応版でもヘルプ自体は成功する)
- `npm ls --all` は `node_modules` 未インストール時に必ず失敗するため、存在確認を前置する
- `oasdiff` の破壊的変更判定の終了コード仕様
- `deptry` / `vulture` の誤検出率は実プロジェクトでの調整が要る可能性がある(WARN 既定にしているのはこのため)

## 9. 実装の分割

11系統 + 3機構は単一の実装計画には大きい。**独立して価値が出る3フェーズ**に分け、それぞれ別の計画とする。

| フェーズ | 内容 | 単独での価値 |
|---|---|---|
| **P1: 基盤と既存欠陥** | D1〜D3 修正・共有関数・Tier 0(構文検証)・**M1 WARN機構**・events.jsonl 連携・stats/report の WARN 集計 | 誤ブロックの解消と、以降すべての検査が乗る土台 |
| **P2: 速い検査群** | 秘密情報・CI/Dockerfile lint・アーキ制約・依存整合性・フォーマット・デッドコード・内部リンク | 追加コストほぼゼロで適用範囲が一気に広がる |
| **P3: 重い検査群** | **M2 遅延実行機構**・脆弱性監査・**M3 カバレッジ相乗り**・API契約差分 | 定常状態でのコストを抑えたまま、残りの領域を埋める |

P1 → P2 → P3 の順に実施する。P2 の各検査は互いに独立なので、P2 内でさらに分割・並行しても構わない。
