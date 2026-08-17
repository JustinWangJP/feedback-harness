# プロジェクト設定ファイル(config.yaml)設計

- 日付: 2026-08-17
- 動機: 導入先の環境ごとにハーネスの挙動を調整可能にする。現在の可変点は環境変数3つだけで、チームで共有(commit)できない
- ステータス: 設計済み・未実装

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
| 優先順位 | **環境変数 > config > 既定値**(項目単位) | config はチームの既定値(commit)、環境変数はその場の一時上書き(CI・調査中)。既存の環境変数運用を壊さない |
| YAML パーサ | **最小サブセットを自前実装**(python3 標準ライブラリのみ) | PyYAML はこのハーネスが任意扱いにしている依存で、**開発機にも入っていない**(2026-08-17 実測)。PyYAML 必須にすると設定が読めない環境が生まれ、「設定が黙って効かない」という最悪の失敗モードになる |
| 壊れた config | **行番号付きで FAIL を立てる**(黙って既定値に落とさない) | 設定が効いていないことに気づけない状態は、検査が SKIP されるより危険。ハーネスの既存原則(SKIP には必ず理由を出す)の延長。FAIL を立てたうえで残りの検査は既定値で続行する(§6) |
| 雛形 | `config.example.yaml` を配布し `config.yaml` は**自動生成しない** | 空の雛形が commit されると「設定した」のか「置いただけ」なのか区別できなくなる |

### 2.1 非目標

- **グローバル設定・ユーザー設定は持たない。** 探索順は「プロジェクトの1ファイルだけ」。階層設定は解決順の説明コストが高く、今回の動機(プロジェクト環境への追従)には不要
- **ツールの実行コマンドそのものは設定させない。** 任意のコマンドを設定ファイルから実行できると、リポジトリを clone しただけで任意コード実行になる。設定できるのは既定のコマンドに渡す**パラメータ**に限る

## 3. スキーマ(v1)

```yaml
version: 1                      # スキーマ版。省略時は 1

check:
  skip: []                      # 実行しないステージ
  exclude: []                   # 検査対象から外すパス glob
  fail_on: []                   # 宣言が無くても FAIL にするステージ
  warn_on: []                   # FAIL を WARN に落とすステージ
  shellcheck_severity: warning  # style | info | warning | error
  vulture_min_confidence: 80    # 0-100
  contract_base: main           # API契約差分のベースラインブランチ
  log_tail_lines: 40            # 失敗ログの表示行数

audit:
  interval_days: 7              # 「監査を推奨」を出すまでの日数
  npm_audit_level: high         # low | moderate | high | critical

feedback:
  open_threshold: 3             # promote を促す open エントリ件数
```

### 3.1 各項目の意味と既定値

| キー | 型 | 既定値 | 対応する環境変数 | 効果 |
|---|---|---|---|---|
| `check.skip` | 文字列リスト | `[]` | `FEEDBACK_CHECK_SKIP` | 指定ステージを `SKIP (FEEDBACK_CHECK_SKIP)` として飛ばす。語彙は `lint` / `typecheck` / `test` / `build` / `format` / `security` / `docs` / `contract` |
| `check.exclude` | glob リスト | `[]` | — | ハーネスが列挙するファイルから除外する(§3.3 に限界を明記) |
| `check.fail_on` | 文字列リスト | `[]` | — | 宣言(設定ファイル)が無くても WARN ではなく FAIL にするステージ |
| `check.warn_on` | 文字列リスト | `[]` | — | FAIL するステージを WARN に落とす。`skip` より弱い緩和手段 |
| `check.shellcheck_severity` | 文字列 | `warning` | `FEEDBACK_SHELLCHECK_SEVERITY` | shellcheck `-S` に渡す重大度 |
| `check.vulture_min_confidence` | 整数 | `80` | — | vulture の誤検出しきい値。下げると検出が増える |
| `check.contract_base` | 文字列 | `main` | `FEEDBACK_CONTRACT_BASE` | `git merge-base HEAD <値>` のベースライン |
| `check.log_tail_lines` | 整数 | `40` | — | FAIL / WARN 時に出すログ行数。エージェントの文脈量に直結する |
| `audit.interval_days` | 整数 | `7` | — | `stats` / `report` が「監査を推奨」を出すまでの経過日数 |
| `audit.npm_audit_level` | 文字列 | `high` | — | `npm audit --audit-level=<値>` |
| `feedback.open_threshold` | 整数 | `3` | — | `add` / `stats` / `report` が promote を促す open 件数 |

### 3.2 `fail_on` / `warn_on` の適用規則

現在の判定は呼び出し側で `run_stage`(FAIL)と `run_stage_soft`(WARN)を選び分けている。config はこの選択を**ステージ単位で上書き**する:

| 呼び出し | `fail_on` に含む | `warn_on` に含む | どちらにも無い |
|---|---|---|---|
| `run_stage`(宣言あり) | FAIL | **WARN** | FAIL |
| `run_stage_soft`(宣言なし) | **FAIL** | WARN | WARN |

両方に同じステージを書いた場合は `fail_on` を優先する(安全側)。

`warn_on` は `skip` より弱い緩和手段である点に注意する — `skip` は検査自体を行わないが、`warn_on` は検査して報告だけする。「今は直せないが見えていてほしい」ときに使う。

### 3.3 `exclude` の適用範囲(重要な限界)

`exclude` が効くのは**ハーネス自身がファイルを列挙する検査**に限る:

- 効く: `*.py` フォールバック / `*.sh` / `*.md`(内部リンク)/ `*.json` / `*.yaml` / `Dockerfile*`
- **効かない**: 自分でツリーを歩くツール(`ruff check .` / `pytest` / `vulture .` / `go vet ./...` / `cargo` / `npm run *`)

後者はそれぞれの無視設定(`.ruffignore` / `pyproject.toml` の `exclude` / `.gitignore` 等)に従う。ハーネスが各ツールの除外構文へ翻訳することはしない — ツールごとに意味が違い、翻訳は必ずずれるため。この限界は設定ガイドに明記する。

なお `exclude` はスタック検出(`[[ -f pyproject.toml ]]` 等)には影響しない。スタックの有無はマニフェストの存在で決まる。

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

```
HARNESS_CHECK_SKIP='test build'
HARNESS_CHECK_EXCLUDE='vendor/** dist/**'
HARNESS_CHECK_FAIL_ON='format'
HARNESS_CHECK_WARN_ON=''
HARNESS_CHECK_SHELLCHECK_SEVERITY='warning'
HARNESS_CHECK_VULTURE_MIN_CONFIDENCE='80'
HARNESS_CHECK_CONTRACT_BASE='main'
HARNESS_CHECK_LOG_TAIL_LINES='40'
HARNESS_AUDIT_INTERVAL_DAYS='7'
HARNESS_AUDIT_NPM_LEVEL='high'
HARNESS_FEEDBACK_OPEN_THRESHOLD='3'
```

出力される値は**必ず `shlex.quote` で括る**。config はリポジトリ内のファイルであり、その値が `eval` に渡る以上、引用を怠るとファイルの中身がシェルコードとして実行される。

リスト値の区切りは2種類を使い分ける:

- **ステージ名のリスト**(`skip` / `fail_on` / `warn_on`)は**空白区切り**。値は閉じた語彙でスキーマ検証済みのため空白を含みえず、既存の `skipped()`(部分文字列一致)がそのまま使える
- **`exclude`** は**改行区切り**。ユーザーが書く任意の glob には空白を含むパスがありえ、空白区切りだと `vendor dir/**` が2件に割れる。読む側は `while IFS= read -r` で回す

`shlex.quote` は改行を含む値も安全に括るため、`eval` 経由でも壊れない。

**既定値は必ずこの出力に含める** — config が無くても全変数が定義された状態にする。lib.sh 側に既定値を書くと2箇所管理になるため。

### 4.3 優先順位の実現

env > config > 既定値 は、config が既定値を埋めた変数に対して環境変数を被せるだけで実現する:

```bash
SKIP="${FEEDBACK_CHECK_SKIP:-$HARNESS_CHECK_SKIP}"
SHELLCHECK_SEVERITY="${FEEDBACK_SHELLCHECK_SEVERITY:-$HARNESS_CHECK_SHELLCHECK_SEVERITY}"
```

Python 側も同じ順で解決する(`os.environ` → config → 既定値)。

### 4.4 呼び出し箇所と実行コスト

`harness_load_config` は `check.sh` / `check_file.sh` / `audit.sh` の冒頭(ルート解決後)で呼ぶ。`check_file.sh` は現在ルートを解決していないため、`harness_project_root` による解決を追加する。

python3 の空起動は実測 **約26ms**(2026-08-17)。`check_file.sh` は毎編集で走るが、同スクリプトは既に ruff / eslint / shellcheck(数百ms)を起動しており、26ms は誤差の範囲。キャッシュ機構は導入しない(スタンプ破損・無効化条件という新しい障害面を作る割に得るものが小さい)。

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
- 列挙値の検証(`shellcheck_severity` / `npm_audit_level` / ステージ名)
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
| `scripts/harness_config.py` | **新規**。パーサ・スキーマ・既定値・shell/JSON 出力 |
| `scripts/lib.sh` | `harness_load_config` を追加。`SHELLCHECK_SEVERITY` の既定値解決を config 経由に変更 |
| `scripts/check.sh` | 冒頭で config を読む。`skip` / `exclude` / `fail_on` / `warn_on` / `vulture_min_confidence` / `contract_base` / `log_tail_lines` を反映 |
| `scripts/check_file.sh` | ルート解決と config 読み込みを追加 |
| `scripts/audit.sh` | `npm_audit_level` を反映 |
| `scripts/feedback_log.py` | `harness_config` を import し `interval_days` / `open_threshold` を反映 |
| `scripts/init.sh` | `harness_config.py` と `config.example.yaml` を配布物に追加 |
| `.feedback/config.example.yaml` | **新規**。全項目をコメント付きで並べた雛形 |
| `docs/configuration.md` | **新規**。設定ガイド |
| `README.md` / `scripts/README.md` | 設定ファイルの節と、環境変数表への優先順位の追記 |
| `tests/test_config.sh` | **新規** |
| `.claude-plugin/plugin.json` | 0.4.0 → 0.5.0 |

`.gitignore` は変更しない — `config.yaml` は**共有する設定**であり、`events.jsonl` 等のローカル状態とは性質が違う。

## 8. テスト方針

既存規約(`tests/test_*.sh` + `assert.sh`、期待値はリテラル、判定は自前カウンタと `assert_summary`)に従う。

| 検証内容 | 理由 |
|---|---|
| config 不在で全項目が既定値になる | 最も多い状態。ここが壊れると全導入先が壊れる |
| config の値が反映される | 基本機能 |
| **環境変数が config に勝つ** | 優先順位の中核。逆転すると CI の一時上書きができなくなる |
| 未設定項目だけ既定値に落ちる(部分指定) | 「全項目書かないと動かない」設定ファイルは使われない |
| 未知キー・型不一致・列挙外の値でエラー | 打ち間違いを黙って無視しない契約 |
| 未対応記法で行番号付きエラー | サブセットの境界を固定する |
| **値にシェルメタ文字を入れても実行されない** | `eval` を使う以上、引用の回帰は致命的 |
| `exclude` が実際に検査対象を減らす(check.sh 経由) | 単体のパーサテストでは配線を検証できない |
| `fail_on` / `warn_on` が exit code を切り替える(check.sh 経由) | 同上 |
| **雛形とガイドがスキーマと一致する** | `--keys` の出力と `config.example.yaml` / `docs/configuration.md` を突き合わせ、文書ドリフトを機械的に防ぐ |

## 9. 設定ガイド(`docs/configuration.md`)の構成

運用されることを目的に、以下の順で書く:

1. **3分で始める** — 雛形をコピーし、1項目だけ変えて効果を確認するまで
2. **優先順位** — 環境変数 > config > 既定値。どちらを使うべきかの指針(commit したい設定は config、その場限りは環境変数)
3. **項目リファレンス** — 全項目について「既定値 / 型 / 意味 / 変えるとどうなるか / 典型的な値」
4. **よくある設定例** — 「既存プロジェクトに導入した初日」「CI を厳しくする」「モノレポで一部だけ検査する」など、動機から引ける形
5. **効かないとき** — 優先順位の確認方法、`--json` での実効値の確認、サポート外記法の一覧
6. **YAML サブセットの仕様** — 書ける記法・書けない記法

## 10. 未採用の選択肢

| 案 | 不採用の理由 |
|---|---|
| PyYAML を必須にする | 開発機にも入っていない実測がある。新しい実行時依存を足さない原則にも反する |
| PyYAML があれば使い、無ければ自前パーサ | 同じ config が環境によって違う解釈になりうる。2経路のドリフトはこのリポジトリが繰り返し痛い目を見ている問題 |
| JSON にする | コメントが書けない。設定ファイルは「なぜこの値なのか」を残せることが運用上の価値の大半を占める |
| config を環境変数より優先する | CI や手元で一時的に上書きする手段が無くなる。config を編集して commit しない限り変えられないのは運用上きつい |
| グローバル設定・ユーザー設定を持つ | 解決順の説明コストに見合わない。今回の動機はプロジェクト環境への追従であり、プロジェクト1階層で足りる |
| 任意コマンドを設定可能にする | clone しただけで任意コード実行になる |
