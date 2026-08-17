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
| `check.sh` は Stop フックで毎ターン走り `timeout 300` を共有する。ネットワークや重い解析を入れると 2026-08-12 に解消した過剰実行問題が再発する | 脆弱性監査・API契約差分・カバレッジ | 当初は **M2 遅延実行** を設計したが **2026-08-17 に廃止**。改訂後: 脆弱性監査は**オンデマンド限定**(check.sh の外)、API契約差分は**宣言ゲート**で Stop フックに載せる、カバレッジは **M3 相乗り** |
| 既存プロジェクトが未整備の領域(未フォーマット・未使用コード)を一律 FAIL にすると、導入初日から完了不能になる(shellcheck 重大度で過去に扱った問題) | フォーマット・デッドコード・カバレッジ閾値 | **M1 WARN 結果クラス**(宣言していない検査は報告のみ) |

## 1.3 ツール導入に関する原則(非交渉)

**P-A. ハーネスは決してツールを自動インストールしない。** 未導入は SKIP と理由表示に留め、導入の判断と実行はユーザーが行う。インストールは環境を変える行為であり、エージェントが黙って行ってよいものではない。この原則は既存実装に埋め込まれている(`npx --no-install` を選び、ネットワークからの取得を避けた判断)。新規検査もこれを守る。

**P-B. OS依存の導入手段を前提にしない。** Homebrew や apt を必要とするツールは「あれば使う」に留め、必須にしない。優先順位:

1. **追加インストール不要** — python3 / node / git など既にある実行環境で自前実装できるもの(構文検証・内部リンク検証)
2. **横断ツールは npm** — OSに依存せず `npm i -D` で入るNode製ツール
3. **スタック固有の検査は、そのスタックのパッケージマネージャ** — Pythonプロジェクトには pip、Goには go、Rustには cargo が既にある。追加の導入経路を増やさない
4. **OS固有バイナリは任意扱い** — PATH にあれば使い、無ければ SKIP

**P-C. 依存を推奨する前にレジストリで素性を確認する。** 名前が一致するだけの別物・名前予約の空パッケージが実在する(§8.1 に実例)。公式リポジトリ・最終更新日・ダウンロード数を確認してから設計に載せる。

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

### M2. ~~遅延実行~~ → **廃止(2026-08-17 改訂)**

当初は「入力ハッシュが変わったときだけ走らせる」機構(.feedback/.check-cache/ にハッシュ+前回結果を記録)を設計した。**P3 着手前の再検討で廃止する。** 理由:

1. **ネットワークの不定性は遅延で解けない** — M2 が解くのは「重さ」だけ。レジストリ障害・遅延・オフライン環境(機内・閉域網)で Stop フックの `timeout 300` を侵食し、他ステージの結果ごと死ぬリスクは残る。check.sh が一貫して守ってきた「ネットワーク不使用」原則を、このためだけに崩す価値がない
2. **キャッシュ管理という新しい障害面** — ハッシュ計算・スタンプ破損・前回FAIL再実行の条件は、それ自体がバグの住処になる。ネットワーク検査を Stop フックから外せば、この機構は不要になる
3. **代替で足りる** — 脆弱性監査はオンデマンド限定(下記)とし、最終実行日を `report`/`stats` に載せて可視する。**WARN 機構と同じ哲学**(ブロックせず、溜まったら見える)の適用である

重いがオフラインで完結する検査(cargo-semver-checks のビルド等)は、M2 の代わりに**宣言ゲート**(設定を書いたプロジェクトだけがコストを払う)で扱う。

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
| CI設定 | `.github/workflows/*.y*ml` が存在 | 上記のYAML構文検証が適用される(必須ツール無し) | lint | FAIL |
| CI設定(深) | 同上 + `actionlint` が PATH にある | `actionlint` | lint | FAIL。Go製バイナリのため任意扱い(P-B4)。npm の `actionlint` はWASM移植で2022年更新停止のため既定では使わない |
| Dockerfile | Dockerfile + `dockerfilelint` 実行可能(npm) | `npx --no-install dockerfilelint <files>` | lint | FAIL |
| Dockerfile(代替) | Dockerfile + `hadolint` が PATH にある | `hadolint <files>` | lint | FAIL。任意扱い(P-B4) |

### 3.2 セキュリティ

| 検査 | 検出条件 | コマンド | ステージ | 判定 |
|---|---|---|---|---|
| 秘密情報(主) | `secretlint` 実行可能(npm)**かつ `.secretlintrc.*` が存在** | `npx --no-install secretlint "**/*"` | security | FAIL。設定が無ければ **SKIP**(理由: `.secretlintrc.* 未設定`)— §8.3 の実測により、設定なしでは exit 2 で実行できないため WARN にできない。マスクは既定で有効(`--maskSecrets` というオプションは存在しない) |
| 秘密情報(代替) | `gitleaks` が PATH にある | `gitleaks detect --no-git --redact --no-banner -s .` | security | FAIL。OS固有バイナリのため任意扱い(P-B4)。**npm の `gitleaks` は別物なので使わない**(§8.1) |
| 脆弱性(Python) | `pip-audit` あり | `pip-audit` | —(check.sh 外) | **オンデマンド限定**(2026-08-17 改訂)。check.sh には入れない |
| 脆弱性(Node) | `package-lock.json` + npm | `npm audit --audit-level=high` | —(check.sh 外) | **オンデマンド限定**。`npm audit` が読めるのは `package-lock.json` だけで、`pnpm-lock.yaml` / `yarn.lock` しか無いと ENOLOCK で exit 1 になる(2026-08-17 実測)。誤FAILを避けるため npm 以外の lockfile は理由付き SKIP とし、`pnpm audit` / `yarn npm audit` の直接実行を案内する |
| 脆弱性(Go) | `govulncheck` あり | `govulncheck ./...` | —(check.sh 外) | **オンデマンド限定** |
| 脆弱性(Rust) | `cargo-audit` あり | `cargo audit` | —(check.sh 外) | **オンデマンド限定** |

**オンデマンド監査の実行経路(2026-08-17 改訂)**: 監査は `feedback-loop` スキル等からの明示実行に限定する(check.sh の外)。`report` / `stats` には **最終監査日**(`.feedback/.last-audit` スタンプ)を表示し、規定の間隔(例: 7日)を過ぎていれば「監査を推奨」行を出す — WARN 機構と同じ「ブロックせず、溜まったら見える」哲学の適用。監査実行時に判定結果は FAIL なら `feedback_log.py add --source hook` 相当で記録し、ループに載せる。

**値のマスクは必須** — `check.sh` の失敗ログはエージェントのコンテキストと `failures.txt` に入るため、秘密の値をそのまま出力すると別の場所へ拡散する。secretlint は**既定でマスクする**(`--no-maskSecrets` を**渡してはならない**)。gitleaks は `--redact` を省略不可とする。§8.3 で実際に値が `****` に伏せられることを確認済み。

### 3.3 依存の実在性・整合性(オフライン)

「AIが存在しないパッケージ名を書く」「宣言と実体がずれる」を**ネットワーク無しで**捕まえる。脆弱性監査(§3.2)とは別物であり、遅延実行は不要なほど速い。

| 検査 | 検出条件 | コマンド | ステージ | 判定 |
|---|---|---|---|---|
| Node | `node_modules` が存在**かつ PM が npm** | `npm ls --all` | lint | FAIL(宣言と実体の不一致・欠損を検出)。`node_modules` 不在時は SKIP(未インストールを欠陥と呼ばない)。`--all` は npm 固有で pnpm には無く Yarn Berry には `ls` 自体が無いため、他PMでは健全なプロジェクトが usage error で FAIL する — よって npm 以外は SKIP(2026-08-17 実装時に修正) |
| Python | `deptry` あり | `deptry .` | lint | 宣言(`[tool.deptry]`)あり → FAIL / 無し → **WARN**。§8.2 のとおり誤検出率が未知のため宣言ゲートを敷く(2026-08-17 実装時に確定) |
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
| Node | `package.json` に `test:coverage` スクリプト | `npm run test:coverage`(`npm test` の**差し替え**) | スクリプトを書いた=宣言 → FAIL |

閾値が宣言されていない場合にカバレッジ低下で FAIL にしない理由: 初期段階のプロジェクトが常時ブロックされるため。数値は WARN として `events.jsonl` に載るので、傾向は `stats` で追える。

**2026-08-17 の実装調整**: 「閾値なし → 数値を WARN で報告」は実装しない。数値の抽出にはテストの2回実行(M3 違反)か run_stage 内部ログの解析(実装詳細への結合)が必要で、割に合わないため。計装(pytest-cov 検出時の `--cov`、Go の `-cover`、Node の `test:coverage` スクリプト)と閾値ゲート(pytest-cov が `--cov-fail-under` を exit code で強制)のみを実装し、数値はステージログに現れる。

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
| OpenAPI | `openapi.yaml`/`openapi.json`(または `api/` 配下の同名)+ `oasdiff` が PATH にある | ベースライン版を一時ファイルへ取り出し `oasdiff breaking <base> <current>` | contract | FAIL。**宣言ゲート**(spec ファイルの存在=宣言)。オフラインで完結するため Stop フックに載せる(M2廃止後も変更なし)。Go製バイナリのため任意扱い(P-B4)。**npm の `oasdiff` は中身の無い名前予約なので使わない**(§8.1) |
| Rust ライブラリ | `cargo-semver-checks` あり + `[lib]` を持つ crate | `cargo semver-checks check-release` | contract | FAIL。**宣言ゲート**(cargo-semver-checks の設定/導入自体が宣言)。ビルドを伴い重いが、導入を選んだプロジェクトだけがコストを払う(M2廃止に伴い宣言ゲートで扱う) |

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
| `scripts/lib.sh` | `harness_has_pyyaml` / `harness_validate_json` / `harness_validate_yaml` / `harness_check_md_links` |
| `scripts/check_file.sh` | JSON/YAML 分岐を共有関数へ置換(D2・D3 修正) |
| `scripts/check.sh` | WARN 結果クラス(集計・表示・exit code)、横断チェック節、各スタック節への検査追加、M3 相乗り |
| `scripts/hooks/on_stop.sh` | WARN 件数を `events.jsonl` に記録 |
| `scripts/feedback_log.py` | `stats` / `report` に WARN 集計を追加(頻出WARNの表示) |
| `.gitignore` | `.feedback/.last-audit`(監査の最終実行日スタンプ) |
| `scripts/README.md` | ステージ表・検査一覧・結果クラス(WARN)・必要ツール・オンデマンド監査の案内 |
| `README.md` | 仕組み・必要ツール |
| `AGENTS.md` / `docs/pointer_agents.md` | 最終行の意味表に WARN 付きの行を追加(規約3) |
| `CLAUDE.md` | 変更履歴 |
| `.claude-plugin/plugin.json` | **0.3.0 → 0.4.0**。P1〜P3 は実装中に 0.4.0 / 0.5.0 / 0.6.0 と刻んだが、外部に配るのは3フェーズをまとめた1リリースであり、中間の版は公開されない。よってリリース時に 0.4.0 へ統一する(各フェーズの計画書には当時の刻みが残る) |
| `tests/` | 新規4本(§7) |

## 7. テスト方針

既存規約(`tests/test_*.sh` + `assert.sh`、期待値はリテラル、判定は自前カウンタと `assert_summary`)に従う。外部ツールは **PATH に偽実行ファイルを置いて**駆動する(`test_on_stop_skip.sh` が確立した手法)。

| テスト | 検証内容 |
|---|---|
| `tests/test_config_syntax.sh` | 壊れたJSON/YAMLを検出 / 複数文書YAML・カスタムタグYAMLを**誤検出しない**(D3回帰)/ JSONC除外(D2回帰)/ PyYAML不在でSKIP / `check_file.sh` と `check.sh` で同判定 |
| `tests/test_check_warn.sh` | WARN が exit 0 のままであること / 最終行に件数が出ること / FAIL と混在したときは exit 1 になること / 宣言(設定ファイル)の有無で FAIL/WARN が切り替わること |
| `tests/test_audit.sh`(実装時に `test_audit_ondemand.sh` から改称) | 監査コマンドが check.sh を実行しないこと / 最終監査日スタンプの更新(成功時のみ)/ ツール不在・npm以外のlockfileで SKIP。report/stats の推奨行は `test_stats.sh` が検証する |
| `tests/test_check_p2.sh` / `tests/test_check_p3.sh`(実装時に `test_check_extended.sh` から分割) | 偽ツールで各検査の (a) 検出条件 (b) FAIL伝播 (c) ツール不在でSKIP (d) gitleaks に `--redact` が渡ること。内部リンクは `test_md_links.sh` が担当 |

`bash scripts/check.sh` が `ALL PASS` であることを完了条件とする。

## 8. 検証状況(正直な記録)

### 8.1 確認済み — npm パッケージの素性(2026-08-16 に `npm view` で照会)

| パッケージ | 実体 | 採否 |
|---|---|---|
| `secretlint` 13.0.4 | 公式 `secretlint/secretlint`、週約100万DL、2026-07更新 | **採用**(秘密情報の主手段) |
| `dockerfilelint` 1.8.0 | 公式 `replicatedhq/dockerfilelint`、週約8.9千DL | **採用**(Dockerfileの主手段) |
| `knip` 6.32.2 | 公式・活発 | **採用**(Nodeデッドコード) |
| `prettier` 3.9.6 | 公式 | **採用**(Nodeフォーマット) |
| `actionlint` 2.0.6 | 「Actionlint as wasm」(xing.com)、2022-12で更新停止 | **不採用**。本家Go版が PATH にあるときのみ使う |
| `gitleaks` 1.0.0 | `ycjcl868/gitleaks`。説明「> custom rules」、2022-05停止、本家(`gitleaks/gitleaks` v8系・Go製)と**無関係の別物**。週約1.3万DLは誤インストールと推測 | **不採用**。npm経由では絶対に入れない |
| `oasdiff` 0.0.1-security | 「Reserved name placeholder. No functionality.」= npm の名前予約 | **不採用**。中身が無い |

後半3件は、本設計が導入しようとしている「依存の実在性」検査(§3.3)が防ぐべき事象そのものであり、原則 P-C の実例として記録する。

### 8.3 実測 — npm ツールの実挙動(2026-08-17、ユーザー承認のうえ検証目的で導入)

`package.json`(private・devDependencies のみ)を作り `npm install` で secretlint 13.0.4 / dockerfilelint 1.8.0 / knip 6.32.2 / prettier 3.9.6 を導入し、実際に走らせて確認した。**設計の記述と食い違った点があり、上表はこの実測に合わせて修正済み**。

| ツール | 実測結果 | 設計への影響 |
|---|---|---|
| secretlint | `--maskSecrets` オプションは**存在しない**。マスクは**既定で有効**で、無効化する `--no-maskSecrets` がある側。検出時の出力は `found slack token: ****…` と伏せられ、生値は出ない | コマンドから `--maskSecrets` を削除。「`--no-maskSecrets` を渡さない」ことを制約に変更 |
| secretlint | `.secretlintrc.*` が無いと **exit 2**(`secretlint config is not found`)で実行不能。`--secretlintrcJSON` でインライン設定は可能だが、ハーネスが既定ルールを押し付けることになる | 判定を「設定あり→FAIL / 無し→**WARN**」から「設定あり→FAIL / 無し→**SKIP**」へ変更 |
| secretlint | 検出時 exit 1 / 問題なし exit 0。Slack トークン・npm アクセストークン・秘密鍵ヘッダを検出。AWS のドキュメント用ダミー値(`AKIAIOSFODNN7EXAMPLE`)は正しく無視する | 終了コード契約を確認。誤検出耐性も良好 |
| dockerfilelint | 問題あり **exit 2** / 問題なし exit 0(`Issues: None found`) | FAIL 判定は非0で正しい。exit 1 ではなく 2 である点に注意 |
| prettier | 設定なしでも `--check` は動作し exit 0 を返す(既定スタイルで判定) | 「設定なしは SKIP」の判断は据え置き — 動くこと自体が問題で、既定スタイルの押し付けになるため |
| knip | 設定なしで実行すると、**ハーネスが検査ツールとして入れた devDependencies 4件すべてを「Unused」と報告**し exit 1 | 「設定なしは SKIP」の判断が実測で裏付けられた。FAIL にすれば導入直後に完了不能になる |

この検証がなければ、secretlint は起動すらしないコマンドを、knip は即座に全プロジェクトを止める設定を実装するところだった(原則 P-C の実例)。

### 8.2 未検証 — 実ツールとの結合

§8.3 で実測した4ツール(secretlint / dockerfilelint / knip / prettier)を除き、actionlint / hadolint / import-linter / pip-audit / deptry / vulture / oasdiff / cargo-semver-checks は**未導入**(原則 P-A により、許可なく導入しない)。これらのテストは偽実行ファイルで**呼び出し契約**(引数・検出条件・SKIP/FAIL/WARNの分岐)を固定するに留まり、実ツールとの結合は導入済み環境での初回実行が最初の検証機会になる。

特に確認が必要な項目:
- **gitleaks のバージョン差**: v8.19 で `detect` → `dir`/`git` に再編された。`gitleaks detect --help` の出力に `--no-git` と `--redact` の**両方が含まれること**をプローブし、無ければ SKIP する(ヘルプの終了コードだけでは不十分 — 未対応版でもヘルプ自体は成功する)
- `npm ls --all` は `node_modules` 未インストール時に必ず失敗するため、存在確認を前置する
- `oasdiff` の破壊的変更判定の終了コード仕様
- `deptry` / `vulture` の誤検出率は実プロジェクトでの調整が要る可能性がある(WARN 既定または宣言ゲートにしているのはこのため)

## 9. 実装の分割

11系統 + 3機構は単一の実装計画には大きい。**独立して価値が出る3フェーズ**に分け、それぞれ別の計画とする。

| フェーズ | 内容 | 単独での価値 |
|---|---|---|
| **P1: 基盤と既存欠陥** | D1〜D3 修正・共有関数・Tier 0(構文検証)・**M1 WARN機構**・events.jsonl 連携・stats/report の WARN 集計 | 誤ブロックの解消と、以降すべての検査が乗る土台 |
| **P2: 速い検査群** | 秘密情報・CI/Dockerfile lint・アーキ制約・依存整合性・フォーマット・デッドコード・内部リンク | 追加コストほぼゼロで適用範囲が一気に広がる |
| **P3: 重い検査群**(2026-08-17 改訂) | **M3 カバレッジ相乗り**・API契約差分(宣言ゲート)・**脆弱性監査のオンデマンド経路**(実行スクリプト+最終監査日の可視化) | Stop フックはオフライン検査のみを載せたまま、残りの領域を埋める。M2 は廃止 |

P1 → P2 → P3 の順に実施する。P2 の各検査は互いに独立なので、P2 内でさらに分割・並行しても構わない。
