# プロジェクト設定ファイル(config.yaml)設計

> **履歴資料:** この文書で設計した `.feedback/config.yaml` は実装済みです。現在の設定方法は[設定ガイド](../../configuration.md)を参照してください。

- 日付: 2026-08-17
- 動機: 導入先の環境ごとにハーネスの挙動を調整可能にする。現在の可変点は環境変数3つだけで、チームで共有(commit)できない
- ステータス: 実装済み（設計時点の記録として保存）

---

## 1. 背景

現在プロジェクトが変えられるのは環境変数3つ(`FEEDBACK_CHECK_SKIP` / `FEEDBACK_SHELLCHECK_SEVERITY` / `FEEDBACK_CONTRACT_BASE`)だけで、それ以外は実装にハードコードされている(`vulture --min-confidence 80`、`tail -n 40`、`AUDIT_INTERVAL_DAYS = 7`、`npm audit --audit-level=high`、open 件数のしきい値 3)。

環境変数には2つの限界がある:

1. **共有できない** — シェルの起動方法に依存するため、チーム全員に同じ設定を配るにはドキュメントで「これを export してください」と頼むしかない。リポジトリに入らない設定は必ずドリフトする
2. **宣言ゲートを上書きできない** — 「設定ファイルがあれば FAIL、無ければ WARN」という判定の強度は実装に固定されており、プロジェクト側が「うちは format も FAIL にしたい」と決められない

### 1.1 ユーザーが挙げた動機(2026-08-17 確認)

- 検査の実行制御(ステージ・対象パス)
- 判定の強度(WARN / FAIL の切替)
- 閾値・パラメータの調整
- 設定の共有(環境変数だと運用しづらい)

4つすべてが選択された。本設計はこの4つを満たす範囲に限定する。

## 2. 決定事項

| 論点 | 決定 | 理由 |
|---|---|---|
| 配置 | `.feedback/config.yaml` | `.feedback/` は既にハーネスの名前空間。リポジトリ直下にドットファイルを増やさない |
| 優先順位 | **環境変数 > 検査単位 > スタック単位 > 全体 > 既定値**(項目単位・最も具体的な指定が勝つ) | config はチームの既定値(commit)、環境変数はその場の一時上書き(CI・調査中)。既存の環境変数運用を壊さない。3層にする理由は §3 |
| YAML パーサ | **最小サブセットを自前実装**(python3 標準ライブラリのみ) | PyYAML はこのハーネスが任意扱いにしている依存で、**開発機にも入っていない**(2026-08-17 実測)。PyYAML 必須にすると設定が読めない環境が生まれ、「設定が黙って効かない」という最悪の失敗モードになる |
| 壊れた config | **行番号付きで FAIL を立てる**(黙って既定値に落とさない) | 設定が効いていないことに気づけない状態は、検査が SKIP されるより危険。ハーネスの既存原則(SKIP には必ず理由を出す)の延長。FAIL を立てたうえで残りの検査は既定値で続行する(§6) |
| 雛形 | `config.example.yaml` を配布し `config.yaml` は**自動生成しない** | 空の雛形が commit されると「設定した」のか「置いただけ」なのか区別できなくなる |

### 2.1 非目標

- **グローバル設定・ユーザー設定は持たない。** 探索順は「プロジェクトの1ファイルだけ」。階層設定は解決順の説明コストが高く、今回の動機(プロジェクト環境への追従)には不要
- **ツールの実行コマンドそのものは設定させない。** 任意のコマンドを設定ファイルから実行できると、リポジトリを clone しただけで任意コード実行になる。設定できるのは既定のコマンドに渡す**パラメータ**に限る

## 3. スキーマ(v1)

### 3.0 なぜ3層か

ステージ単位だけでは粒度が粗すぎる。実測(2026-08-17)で `check.sh` には**個別の検査が41個**あり、そのうち **21個が `lint` ステージに同居**している。`warn_on: [lint]` と書くと、`shell: bash -n`(構文エラー)や `config: json 構文` まで一斉に WARN へ落ちてしまう。

また `skip` の語彙は全スタック共通のため、「Python の test だけ外す」「Node の build は動かさない」といったモノレポで頻出する要求を表現できない。

そこで**最も具体的な指定が勝つ**3層にする:

```yaml
check:
  skip: [contract]              # ① 全体 — 全スタックに効く
  python:
    skip: [test]                # ② スタック単位 — Python の test だけ外す
  node:
    warn_on: [lint]             # Node の lint 群だけ WARN に落とす

checks:                          # ③ 検査単位 — 最も具体的
  vulture:
    severity: skip              # この検査だけ実行しない
    min_confidence: 60          # ツール固有パラメータもここに置く
  deptry:
    severity: fail              # 宣言が無くても FAIL に上げる
  shellcheck:
    severity: warn              # FAIL を WARN に落とす
    min_severity: style         # shellcheck -S に渡す値
```

**glob パターン(`"python: *"` のような書き方)は採らない。** 任意の文字列が有効なキーになり、`vultrue` のような打ち間違いを検出できなくなる。§5.3 で「未知キーはエラー」を要件にした以上、キーは閉じた集合でなければならない。

**②のキーはスタックに限る**(`python` / `node` / `go` / `rust` / `java` / `shell`)。横断検査の群名(`config` / `docs` / `security` / `ci` / `docker` / `contract`)を②に許すと、`docs` / `security` / `contract` がステージ語彙と衝突して同じ語が2つの意味を持つ。横断検査は群あたりの数が少ないので③で個別に指定すれば足りる。

### 3.1 全体像

```yaml
version: 1                      # スキーマ版。省略時は 1

check:
  # ① 全体
  skip: []                      # 実行しないステージ
  fail_on: []                   # 宣言が無くても FAIL にするステージ
  warn_on: []                   # FAIL を WARN に落とすステージ
  exclude: []                   # 検査対象から外すパス glob
  log_tail_lines: 40            # 失敗ログの表示行数

  # ② スタック単位(python / node / go / rust / java / shell)
  python:
    skip: []
    fail_on: []
    warn_on: []

# ③ 検査単位(検査IDは §3.4)
checks:
  vulture:
    severity: warn              # fail | warn | skip
    min_confidence: 80

audit:
  interval_days: 7              # 「監査を推奨」を出すまでの日数
  npm_audit_level: high         # low | moderate | high | critical

feedback:
  open_threshold: 3             # promote を促す open エントリ件数
```

### 3.2 各項目の意味と既定値

**① 全体(`check`)**

| キー | 型 | 既定値 | 対応する環境変数 | 効果 |
|---|---|---|---|---|
| `skip` | ステージリスト | `[]` | `FEEDBACK_CHECK_SKIP` | 指定ステージを飛ばす。語彙は `lint` / `typecheck` / `test` / `build` / `format` / `security` / `docs` / `contract` |
| `fail_on` | ステージリスト | `[]` | — | 宣言が無くても WARN ではなく FAIL にする |
| `warn_on` | ステージリスト | `[]` | — | FAIL するステージを WARN に落とす |
| `exclude` | glob リスト | `[]` | — | ハーネスが列挙するファイルから除外する(§3.5 に限界) |
| `log_tail_lines` | 整数 | `40` | — | FAIL / WARN 時に出すログ行数。エージェントの文脈量に直結する |

**② スタック単位(`check.<stack>`)**

`skip` / `fail_on` / `warn_on` の3キーのみ。①と同じ意味で、そのスタックの検査にだけ効く。スタックは `python` / `node` / `go` / `rust` / `java` / `shell`。

**③ 検査単位(`checks.<id>`)**

| キー | 型 | 既定値 | 効果 |
|---|---|---|---|
| `severity` | `fail` \| `warn` \| `skip` | 検査ごと(現行の宣言ゲートの結果) | この検査の判定。`skip` は実行しない |
| ツール固有キー | — | — | 下表 |

| 検査ID | 固有キー | 型 | 既定値 | 対応する環境変数 |
|---|---|---|---|---|
| `shellcheck` | `min_severity` | `style`\|`info`\|`warning`\|`error` | `warning` | `FEEDBACK_SHELLCHECK_SEVERITY` |
| `vulture` | `min_confidence` | 整数 0-100 | `80` | — |
| `oasdiff` | `base` | 文字列 | `main` | `FEEDBACK_CONTRACT_BASE` |

**その他のセクション**

| キー | 型 | 既定値 | 効果 |
|---|---|---|---|
| `audit.interval_days` | 整数 | `7` | `stats` / `report` が「監査を推奨」を出すまでの経過日数 |
| `audit.npm_audit_level` | 文字列 | `high` | `npm audit --audit-level=<値>` |
| `feedback.open_threshold` | 整数 | `3` | `add` / `stats` / `report` が promote を促す open 件数 |

### 3.3 判定の解決規則

現在の判定は呼び出し側で `run_stage`(FAIL)と `run_stage_soft`(WARN)を選び分けている。config はこの選択を上書きする。**最も具体的な指定が勝つ**:

1. `checks.<id>.severity` があればそれを使う
2. 無ければ `check.<stack>` の `fail_on` / `warn_on` / `skip` を見る
3. 無ければ `check`(全体)の同キーを見る
4. どれも無ければ呼び出し側の既定(宣言ゲートの結果)

同じ層で `fail_on` と `warn_on` の両方に同じステージを書いた場合は `fail_on` を優先する(安全側)。

`warn_on` は `skip` より弱い緩和手段である点に注意する — `skip` は検査自体を行わないが、`warn_on` は検査して報告だけする。「今は直せないが見えていてほしい」ときに使う。

### 3.4 検査ID(41件)

表示ラベルは ID に使えない。Node のラベルは `node: $PM run lint` のようにパッケージマネージャで変動するため。各呼び出し箇所に安定 ID を明示的に持たせる。

**この表を暗記させない。** 実際に使うときは `--list-checks`(§4.5)が対象プロジェクトの検査IDと現在の判定を並べるので、そこからコピーする。以下は全体像の把握と、実装時の突き合わせ用。

| スタック/群 | 検査ID |
|---|---|
| python | `ruff` / `ruff-format` / `mypy` / `pytest` / `deptry` / `vulture` / `import-linter` |
| node | `node-lint` / `node-typecheck` / `tsc` / `node-test` / `node-test-coverage` / `node-build` / `npm-ls` / `prettier` / `knip` |
| go | `go-vet` / `go-build` / `go-test` / `go-mod-verify` / `gofmt` |
| rust | `clippy` / `cargo-check` / `cargo-test` / `cargo-metadata` / `cargo-fmt` / `cargo-semver-checks` |
| java | `mvn` / `gradle` |
| shell | `bash-syntax` / `shellcheck` |
| 横断 | `json-syntax` / `yaml-syntax` / `md-links` / `secretlint` / `gitleaks` / `actionlint` / `dockerfilelint` / `hadolint` / `oasdiff` / `make-check` |

`gradle` は `./gradlew check` と `gradle check` の両方を指す(起動方法の違いであって別の検査ではない)。

### 3.5 `exclude` の適用範囲(重要な限界)

`exclude` が効くのは**ハーネス自身がファイルを列挙する検査**に限る:

- 効く: `*.py` フォールバック / `*.sh` / `*.md`(内部リンク)/ `*.json` / `*.yaml` / `Dockerfile*`
- **効かない**: 自分でツリーを歩くツール(`ruff check .` / `pytest` / `vulture .` / `go vet ./...` / `cargo` / `npm run *`)

後者はそれぞれの無視設定(`.ruffignore` / `pyproject.toml` の `exclude` / `.gitignore` 等)に従う。ハーネスが各ツールの除外構文へ翻訳することはしない — ツールごとに意味が違い、翻訳は必ずずれるため。この限界は設定ガイドに明記する。

なお `exclude` はスタック検出(`[[ -f pyproject.toml ]]` 等)には影響しない。スタックの有無はマニフェストの存在で決まる。

glob の照合対象は**リポジトリ相対パス**(先頭に `./` も `/` も付かない)で統一する。ファイル列挙は git 環境では `git ls-files`、非git環境では `find .` が担うが、後者は `./foo.sh` 形式で返すため、そのまま照合すると同じパターンが git 管理下かどうかで効いたり効かなかったりする。利用者にはこの違いが見えないため、列挙側で先頭の `./` を落としてから `exclude` と照合する(`lib.sh` の `harness_is_jsonc` も同じ形式を前提にしている)。

## 4. 読み込みの実装

### 4.1 パーサは1つだけ置く

bash 3本(`check.sh` / `check_file.sh` / `audit.sh`)と Python 1本(`feedback_log.py`)が同じ設定を読む。**両者に別々のパーサを持たせると必ずドリフトする**(`has()` で実際に起きた問題であり、`lib.sh` の冒頭がその教訓を記録している)。

```
scripts/harness_config.py     # 唯一のパーサ・スキーマ・既定値の置き場
  ├─ --shell [root]  → bash が eval する KEY=VALUE を出力
  ├─ --json  [root]  → デバッグ・テスト用
  └─ --keys          → スキーマのキーと既定値(雛形・ガイドのドリフト検出に使う)
lib.sh: harness_load_config [root]   # 上記を eval する薄いラッパ
```

`feedback_log.py` は `harness_config` を **import** して使う(サブプロセスを起こさない)。

### 4.2 シェルへの受け渡し

3層を bash 側で解決させると解決規則が2箇所(Python と bash)に散る。**解決はローダー側で済ませ、bash には解決済みの値だけを渡す**:

```
# 壊れた config のエラー(None なら空文字)。check.sh はこれを見て FAIL を立てる
HARNESS_CONFIG_ERROR=''

# 判定は「ID:判定:出所」の解決済みマップ(空白区切り)。全体・スタック層の
# ステージ集合もここへ展開済み — bash 側にステージの解決規則を置かないため
HARNESS_CHECK_SEVERITY='vulture:skip:checks.vulture ruff:skip:env.FEEDBACK_CHECK_SKIP'

# ツール固有パラメータと全体設定
HARNESS_SHELLCHECK_MIN_SEVERITY='warning'
HARNESS_VULTURE_MIN_CONFIDENCE='80'
HARNESS_OASDIFF_BASE='main'
HARNESS_LOG_TAIL_LINES='40'
HARNESS_EXCLUDE='vendor/**
dist/**'
HARNESS_AUDIT_INTERVAL_DAYS='7'
HARNESS_AUDIT_NPM_LEVEL='high'
HARNESS_FEEDBACK_OPEN_THRESHOLD='3'
```

`run_stage` は自分の `<id>` で `HARNESS_CHECK_SEVERITY` を引く(見つからなければ呼び出し側の既定)という**参照だけ**を行う。検査・スタック・全体の3層と環境変数の優先順位判断はすべてローダーが済ませて1つのマップへ折りたたむ — ステージ集合を bash 側で再解決させると規則が2箇所に散るため、設計段階で検討した「スタック別のステージ変数」は作らないことにした。

出力される値は**必ず `shlex.quote` で括る**。config はリポジトリ内のファイルであり、その値が `eval` に渡る以上、引用を怠るとファイルの中身がシェルコードとして実行される。

リスト値の区切りは2種類を使い分ける:

- **判定マップ**(`HARNESS_CHECK_SEVERITY`)は**空白区切り**。検査ID・severity・出所はいずれも閉じた語彙(スキーマ検証済み)で空白を含みえない
- **`exclude`** は**改行区切り**。ユーザーが書く任意の glob には空白を含むパスがありえ、空白区切りだと `vendor dir/**` が2件に割れる。読む側は `while IFS= read -r` で回す

`shlex.quote` は改行を含む値も安全に括るため、`eval` 経由でも壊れない。

**既定値は必ずこの出力に含める** — config が無くても全変数が定義された状態にする。lib.sh 側に既定値を書くと2箇所管理になるため。

### 4.3 優先順位の実現

環境変数は config の3層すべてに優先する。ローダーが `os.environ` を最初に見て解決するため、bash 側は解決済みの値を使うだけでよい:

```bash
SHELLCHECK_SEVERITY="$HARNESS_SHELLCHECK_MIN_SEVERITY"   # FEEDBACK_CHECK_SKIP は
                                                          # ローダーが判定マップへ解決済み
```

Python 側(`feedback_log.py`)も同じローダーを import するため、解決規則は1箇所にしか存在しない。

### 4.4 呼び出し箇所と実行コスト

`harness_load_config` は `check.sh` / `check_file.sh` / `audit.sh` の冒頭(ルート解決後)で呼ぶ。`check_file.sh` は現在ルートを解決していないため、`harness_project_root` による解決を追加する。

python3 の空起動は実測 **約26ms**(2026-08-17)。`check_file.sh` は毎編集で走るが、同スクリプトは既に ruff / eslint / shellcheck(数百ms)を起動しており、26ms は誤差の範囲。キャッシュ機構は導入しない(スタンプ破損・無効化条件という新しい障害面を作る割に得るものが小さい)。

### 4.4.1 将来の「個人設定レイヤ」に備える構造(先行対応)

`.feedback/local/config.yaml`(個人の上書き・gitignore)を後から足すことが決まっている(§11)。そのとき解決規則を書き直さずに済むよう、**ローダーの解決関数は最初から「設定レイヤの列」を受け取る形にする**:

```
resolve(layers=[shared_config], env=os.environ)      # v1
resolve(layers=[local_config, shared_config], env=…) # 個人レイヤ追加後
```

レイヤ内の3層(検査 > スタック > 全体)の解決は各レイヤで行い、レイヤ間は「先に来たレイヤが勝つ」だけにする。v1 でレイヤは1つだけだが、`for layer in layers` のループを最初から書いておけば拡張時の変更は呼び出し側の1行で済む。

この構造にしない場合、個人レイヤ追加時に解決関数の全面書き直しになり、`出所`(§4.5)の表示も作り直しになる。

### 4.5 実効設定の表示(`--list-checks`)

3層にした以上、**「なぜこの判定になっているのか」を見る手段が無いと調査不能になる**。また出力ラベル(`python: vulture`)と設定キー(`vulture`)は別物で、41件の対応を暗記させるのは無理がある。両方を1つのコマンドで解決する。

```
$ bash scripts/check.sh --list-checks

検査ID       ラベル               ステージ  判定  出所
ruff         python: ruff         lint      fail  既定
ruff-format  python: ruff format  format    warn  既定
pytest       python: pytest       test      warn  check.python.warn_on
vulture      python: vulture      lint      skip  checks.vulture
deptry       python: deptry       lint      fail  checks.deptry
shellcheck   shell: shellcheck    lint      fail  既定
```

- **左端の列がそのまま設定キー**になる(コピーして `checks:` の下に貼れる)
- **`出所` 列**が3層のどこで決まったかを答える。`既定` / `<キーのパス>`(例: `check.python.warn_on`) / `env.<変数名>` の3種。config 由来であることの接頭辞は付けない — 一覧自体が config の診断であるため
- 設定を書いた後にもう一度叩けば、意図どおり効いたかが確認できる

**列挙するのは、このプロジェクトで実際に対象になる検査だけ**とする(Python リポジトリで `cargo-fmt` を並べても読みにくくなるだけ)。ツール存在確認は通常実行と同じ2段階(`command -v` で未インストール、`has` で起動不可)を通すため、どちらも `skip` として現れる。検査コマンド自体は実行しない。

実装で確定した追加の挙動:

- **壊れた config では表を出したうえで stderr にエラーを出し exit 1 する**。一覧が「すべて既定」で整っていると、打ち間違いを調べに来た利用者に最も知りたい情報が見えないままになるため
- **`--json` 単独の指定は exit 2 で弾く**(`--list-checks --json` のみ有効)。診断系のつもりの引数が黙ってフル検査を起動するのを防ぐ
- 既知の限界: 呼び出し側で `if has <tool>` の外側にゲートされた検査(vulture / deptry / prettier 等)は、ツール未導入だと**行自体が一覧へ出ない**。「プロジェクトに該当しない」のか「ツールが無いだけ」かの区別は今後の課題(設定ガイドの「効かないとき」に明記)

**実装**: `run_stage` に「実行せず行を出力する」モードを設ける。行(ID・ラベル・ステージ)は `check.sh` が持ち、判定と出所は `harness_config.py` が解決する。整形も後者が行う — ラベルに日本語(`config: json 構文` 等)が含まれ、bash の `printf %-20s` はバイト数で数えるため桁がずれる。Python 側で `unicodedata.east_asian_width` を見て揃える。

`--list-checks --json` で機械可読な形も出す(テストがこの出力を突き合わせる)。

## 5. YAML サブセット

### 5.1 解釈する記法

- コメント(`#` 始まり、および値の後ろ)
- 入れ子マップ(スペースインデント。深さ制限なし)
- スカラー: 裸文字列 / `'...'` / `"..."` / 整数 / `true`・`false` / 空(= null)
- リスト: ブロック形式(`- item`)とフロー形式(`[a, b]`)、空リスト `[]`

### 5.2 解釈しない記法(明示エラー)

アンカー・エイリアス(`&` / `*`)、複数文書(`---`)、複数行文字列(`|` / `>`)、リスト要素の入れ子(マップやリストを要素に持つリスト)、タブインデント。

いずれも**行番号と理由を付けて FAIL** にする。黙って無視すると「書いたのに効かない」という最悪の状態になる。

### 5.3 妥当性検証

パースの後に**スキーマ検証**を行う:

- **未知キーはエラー** — `shelcheck_severity` のような打ち間違いを黙って無視しない。既知キーの一覧をエラーに添える
- 型不一致はエラー(`interval_days: "seven"` 等)
- 列挙値の検証(`severity` / `checks.shellcheck.min_severity` / `audit.npm_audit_level` / ステージ名 / スタック名 / 検査ID)
- `version` が 1 より大きければエラー(「このハーネスは version 1 まで対応」)

## 6. エラー処理

`config.yaml` が壊れている場合、`check.sh` は他のステージと同じ形式で FAIL を出す:

```
FAIL  config: .feedback/config.yaml
  4行目: 未対応の記法です(アンカー '&' は使えません)
```

`harness_load_config` はローダーの非0終了を検出したら、その旨を `RESULTS` に FAIL として積み**設定は既定値のまま続行する**。理由: 設定が壊れているからといって他の検査まで止めると、直すべき箇所が見えなくなる。FAIL は立つので完了はブロックされる。

`feedback_log.py` は集計系(`stats` / `report`)なので、壊れた config ではエラーメッセージを stderr に出して既定値で続行する(記録・集計を止めない)。

## 7. 影響範囲

| ファイル | 変更 |
|---|---|
| `scripts/harness_config.py` | **新規**。パーサ・スキーマ・既定値・shell/JSON 出力・判定と出所の解決・`--list-checks` の表整形(日本語ラベルの桁揃え) |
| `scripts/lib.sh` | `harness_load_config` を追加。`SHELLCHECK_SEVERITY` の既定値解決を config 経由に変更 |
| `scripts/check.sh` | 冒頭で config を読む。**46箇所の `run_stage` 呼び出しに検査IDを追加**(論理的な検査は41件 — 宣言ゲートの if/else で1つの検査が2箇所に分かれるため、同じIDを両方に付ける)。`skip` / `exclude` / 判定解決 / ツール固有パラメータ / `log_tail_lines` を反映 |
| `scripts/check_file.sh` | ルート解決と config 読み込みを追加 |
| `scripts/audit.sh` | `npm_audit_level` を反映 |
| `scripts/feedback_log.py` | `harness_config` を import し `interval_days` / `open_threshold` を反映 |
| `scripts/init.sh` | `harness_config.py` と `config.example.yaml` を配布物に追加 |
| `.feedback/config.example.yaml` | **新規**。全項目をコメント付きで並べた雛形 |
| `docs/configuration.md` | **新規**。設定ガイド |
| `README.md` / `scripts/README.md` | 設定ファイルの節と、環境変数表への優先順位の追記 |
| `tests/test_config.sh` | **新規** |
| `.claude-plugin/plugin.json` | **変更しない(0.4.0 のまま)**。main は 0.3.0 で 0.4.0 はまだ公開されていないため、設定ファイルも同じ 0.4.0 リリースに含める。公開前の中間の版を刻まないのは P1〜P3 と同じ扱い |

`.gitignore` は変更しない — `config.yaml` は**共有する設定**であり、`events.jsonl` 等のローカル状態とは性質が違う。

## 8. テスト方針

既存規約(`tests/test_*.sh` + `assert.sh`、期待値はリテラル、判定は自前カウンタと `assert_summary`)に従う。

| 検証内容 | 理由 |
|---|---|
| config 不在で全項目が既定値になる | 最も多い状態。ここが壊れると全導入先が壊れる |
| config の値が反映される | 基本機能 |
| **環境変数が config に勝つ** | 優先順位の中核。逆転すると CI の一時上書きができなくなる |
| 未設定項目だけ既定値に落ちる(部分指定) | 「全項目書かないと動かない」設定ファイルは使われない |
| 未知キー・型不一致・列挙外の値でエラー | 打ち間違いを黙って無視しない契約。**未知の検査ID・スタック名**も含む |
| **層の優先順位: 検査 > スタック > 全体** | 3層の中核。`check.skip: [test]` と `checks.pytest.severity: fail` が同時にあるとき後者が勝つ |
| スタック層が他スタックに漏れない | `check.python.skip: [test]` で Go の test が消えないこと |
| **検査IDの一覧が実装と一致する** | ID は46箇所に散る。`--keys` の出力と `check.sh` の呼び出しを突き合わせ、追加漏れ・重複を機械的に防ぐ |
| **`--list-checks` の `出所` が正しい** | 3層のどこで決まったかを誤ると調査手段そのものが嘘になる。既定 / config の各層 / 環境変数 の4通りを固定する |
| `--list-checks` が検査コマンドを実行しない | 一覧表示で `pytest` や `mvn verify` が走ると使い物にならない |
| `--list-checks` が対象外スタックを並べない | Python リポジトリに `cargo-fmt` が出ないこと |
| 未対応記法で行番号付きエラー | サブセットの境界を固定する |
| **値にシェルメタ文字を入れても実行されない** | `eval` を使う以上、引用の回帰は致命的 |
| `exclude` が実際に検査対象を減らす(check.sh 経由) | 単体のパーサテストでは配線を検証できない |
| `fail_on` / `warn_on` が exit code を切り替える(check.sh 経由) | 同上 |
| **雛形とガイドがスキーマと一致する** | `--keys` の出力と `config.example.yaml` / `docs/configuration.md` を突き合わせ、文書ドリフトを機械的に防ぐ |

## 9. 設定ガイド(`docs/configuration.md`)の構成

項目の羅列は読まれない。**動機から引ける形**にする — 「困っていること」から入って、書くべき YAML にたどり着く順で構成する。

1. **3分で始める** — `--list-checks` で現状を見る → 雛形をコピー → 1項目だけ変える → もう一度 `--list-checks` で `出所` が変わったことを確認する。この往復を最初に体験させる
2. **困りごとから引く**(本体) — 各項目に「症状 → 書く YAML → 出力がどう変わるか」を載せる:
   - 導入初日、既存コードが大量に FAIL する → `warn_on` で段階的に返済する
   - 誤検出の多い検査を止めたい → `checks.<id>.severity: skip`
   - モノレポで言語ごとに事情が違う → `check.<stack>`
   - 生成物・ベンダコードを見せたくない → `exclude`(効かない範囲の注意つき)
   - CI だけ厳しくしたい → 環境変数で config を被せる
   - 特定のツールだけ絶対に止めたい → `checks.<id>.severity: fail`
3. **優先順位** — 環境変数 > 検査 > スタック > 全体 > 既定値。「commit したい設定は config、その場限りは環境変数」という使い分けの指針を添える
4. **項目リファレンス** — 全項目の「既定値 / 型 / 意味 / 変えるとどうなるか」。ここは辞書として引く章であり、通読させない
5. **効かないとき** — `--list-checks` で `出所` を見る手順を最初に置く。次に優先順位の確認、サポート外記法の一覧
6. **YAML サブセットの仕様** — 書ける記法・書けない記法

**設定ファイルの差分が負債返済の記録になる**という運用上の含意も書く — `warn_on: [lint]` を消せたことが、その負債を返した証拠になる。

### 9.1 運用の流れ(ガイド冒頭に置く図)

```
[導入]   check.sh を1回流す → 落ちるものを把握
   ↓
[調整]   --list-checks で検査IDと現在の判定を見る
   ↓     config.example.yaml をコピーして .feedback/config.yaml へ
[確認]   --list-checks で「出所」が config になっているか確認
   ↓
[共有]   config.yaml を commit → チーム全員に同じ設定が届く
   ↓
[返済]   負債を直したら該当行を削除 → 既定値に戻る
```

## 10. 未採用の選択肢

| 案 | 不採用の理由 |
|---|---|
| PyYAML を必須にする | 開発機にも入っていない実測がある。新しい実行時依存を足さない原則にも反する |
| PyYAML があれば使い、無ければ自前パーサ | 同じ config が環境によって違う解釈になりうる。2経路のドリフトはこのリポジトリが繰り返し痛い目を見ている問題 |
| JSON にする | コメントが書けない。設定ファイルは「なぜこの値なのか」を残せることが運用上の価値の大半を占める |
| config を環境変数より優先する | CI や手元で一時的に上書きする手段が無くなる。config を編集して commit しない限り変えられないのは運用上きつい |
| グローバル設定・ユーザー設定を持つ | 解決順の説明コストに見合わない。今回の動機はプロジェクト環境への追従であり、プロジェクト1階層で足りる |
| 任意コマンドを設定可能にする | clone しただけで任意コード実行になる |

## 11. 本設計に含めない課題(次の設計へ繰り越す)

2026-08-17 の運用実測で見つかった穴。config とは独立に価値が出るため別設計とするが、発見を失わないようここに記録する。

### 11.1 溜まった負債が行動につながらない

このリポジトリ自身の `stats` 実測:

| 指標 | 実測値 | 状態 |
|---|---|---|
| 頻出WARN `python: ruff format` | **36回** | 一度も直されていない |
| open エントリ | **4件** | 「promote/close を検討」の NOTE が出続けているが放置 |
| 再発候補 | **2件** | 「ルールが効いていない」最重要シグナルが放置 |
| 最終監査 | **未実行** | `audit.sh` を作ったが一度も呼ばれていない |

一方 PostToolUse 初回通過率 96% / Stop 94% と、**即時フィードバック(フック)は効いている**。効いていないのは蓄積側だけである。

原因: これらは `stats` / `report` を能動的に叩いたときしか見えない。Stop フックは毎ターン走るのに、そのターンの検査結果しか出さない。

方向性: Stop フックが溜まった負債を**閾値超過かつ前回提示から一定期間経過のときだけ**提示する。毎回出すとノイズになって無視される — 現在の「openが3件以上」NOTE がまさにそうなっている(出続けているが誰も動いていない)。閾値とクールダウンは config で調整できるようにする。

### 11.2 チーム共有の feedback と個人環境の feedback が混在している

現状 `rules.md` と `log/` は全て commit され、ローカル扱いは `events.jsonl` と `.last-*` だけ。「自分の環境だけの事情」を書く場所が無く、書けば全員に配られる。

方向性: `.feedback/local/` を丸ごと gitignore し、config・rules・log すべてを共有/個人の2層にする(gitignore は1行で済む)。競合時は個人が勝つ — config の「最も具体的が勝つ」と同じ原則。

**`stats` / `report` は共有分のみを集計する**(`--include-local` で含める)。初回通過率や再発候補は「チームの共有アーティファクトが効いているか」を測る数字であり、個人の環境ノイズで歪めてはならない。

本設計の §4.4.1 は、この層を後から足せるようローダーの構造を先行して合わせるためのもの。

### 11.3 優先度の低い候補

- `check.sh` の実行時間(このリポジトリで約30秒)。導入先で毎ターン重い。本設計の `skip` / `check.<stack>` で緩和できる見込みがあるため、まず config の効果を見てから判断する
- `promote` に渡す entry-id の手打ち。`--list-checks` と同種のコピー手間
- 組織共通ルールの配布手段(`init.sh` は意図的に空テンプレートから始まる)
