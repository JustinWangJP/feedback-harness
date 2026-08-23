# 設定ガイド（config.yaml）

ハーネスの挙動は `.feedback/config.yaml` で調整できる。このファイルは**リポジトリに入る**ため、チーム全員に同じ設定が届き、環境変数の「各自で export してください」という頼み事が不要になる。書かなかった項目はすべて既定値。全部書く必要はない。

[雛形](../.feedback/config.example.yaml)を `.feedback/config.yaml` にコピーして使い始める:

```bash
cp .feedback/config.example.yaml .feedback/config.yaml
```

### 運用の流れ

```
[導入]   check.sh を1回実行する → 現在の失敗項目を把握
   ↓
[調整]   --list-checks で検査IDと現在の判定を見る
   ↓     config.example.yaml をコピーして .feedback/config.yaml へ
[確認]   --list-checks で「出所」が config になっているか確認
   ↓
[共有]   config.yaml を commit → チーム全員に同じ設定が届く
   ↓
[返済]   負債を直したら該当行を削除 → 既定値に戻る
```

**config の差分が負債返済の記録になる。** `warn_on: [format]` を消せたことは、その負債を返した証拠であり、diff がそのまま記録になる。だから一時しのぎの緩和も config に書く(シェルの履歴や個人の環境変数ではなく)。

## 3分で始める

まず現在の設定を確認する。このコマンドは検査自体を実行しないため、安全に利用できる。

```bash
bash scripts/check.sh --list-checks
```

出力(このリポジトリ feedback-harness 自身での例。並ぶ行はプロジェクトのスタック構成とツール導入状況で変わる):

```
検査ID       ラベル               ステージ  判定  出所
ruff         python: ruff         lint      fail  既定
ruff-format  python: ruff format  format    warn  既定
npm-ls       node: npm ls         lint      fail  既定
bash-syntax  shell: bash -n       lint      fail  既定
shellcheck   shell: shellcheck    lint      fail  既定
json-syntax  config: json 構文    lint      fail  既定
md-links     docs: 内部リンク     docs      fail  既定
make-check   make check           test      fail  既定
```

**左端の列がそのまま設定キー**。`ruff-format` が `warn` なのが気になるなら、コピーした config に1行足す:

```yaml
checks:
  ruff-format:
    severity: fail
```

もう一度 `--list-checks` を実行すると、判定と**出所**が変わる。

```
ruff-format  python: ruff format  format    fail  checks.ruff-format
```

出所が `既定` から `checks.ruff-format` に変わったことで、書いた設定が効いていることが確認できる。この「書く → `--list-checks` で出所を確認する」の往復が、config のすべての作業の基本形。

## 困りごとから引く

### 導入初日、既存コードが大量に FAIL する

**症状**: ハーネスを導入したら format や lint が大量 FAIL で、何も完了できない。

**書く YAML**:

```yaml
check:
  warn_on: [format]   # FAIL を WARN に落とす。検査はするが完了をブロックしない
```

**出力がどう変わるか**: `--list-checks` の判定列が `fail` → `warn` に並ぶ。`check.sh` の最終行は `ALL PASS (N件WARN …)` になり exit 0。WARN はプラグインのフック経由で `events.jsonl` に記録され `stats` の「頻出WARN」に現れるため、直し忘れが見える(init.sh 配布のみでフックが無い環境では記録されない)。

直し終わったら `warn_on` から外す。**検査そのものを消したいときだけ `skip` を使う** — `skip` は検査を行わないため、壊れたままで気づけなくなる。`warn_on` は「今は直せないが見えていてほしい」ためのもの。

### 誤検出の多い検査を止めたい

**症状**: 特定の検査(ここでは `vulture`)がこのプロジェクトでは常に意味のない指摘を出す。

**書く YAML**:

```yaml
checks:
  vulture:
    severity: skip
```

**出力がどう変わるか**: `check.sh` の該当行が `SKIP  python: vulture (config: checks.vulture)` になる。理由に `config: …` と付くため、自分で止めたのか既定の挙動なのかが区別できる。

ステージ単位で停止することもできる（`check.skip: [security]` など。指定できる値は `lint` / `typecheck` / `test` / `build` / `format` / `security` / `docs` / `contract`）。ただし `lint` には18個の検査が含まれるため、構文エラー検出（`bash-syntax` / `json-syntax`）を残したい場合は、検査IDで個別に指定する。

### モノレポで言語ごとに事情が違う

**症状**: 同じリポジトリに Python と Node があり、Python の test は重すぎる、Node の lint は歴史的経緯で汚い。

**書く YAML**:

```yaml
check:
  python:
    skip: [test]
  node:
    warn_on: [lint]
```

**出力がどう変わるか**: Python の test ステージだけ SKIP、Node の lint 群だけ WARN になる。**他スタックに漏れない**(`check.python.skip` を書いても Go の test は消えない)。スタックは `python` / `node` / `go` / `rust` / `java` / `shell` の6つ。

### 生成物・ベンダコードを見せたくない

**症状**: `vendor/` 配下のシェルスクリプトや生成済み Markdown が `bash-syntax` や `md-links` で引っかかる。

**書く YAML**:

```yaml
check:
  exclude:
    - vendor/**
    - dist/**
```

**出力がどう変わるか**: ハーネスが列挙する検査対象からその glob が外れ、該当ファイルに起因する PASS / FAIL / WARN の行が消える。

**効く範囲(重要)**: `exclude` が効くのは**ハーネス自身がファイルを列挙する検査だけ** — shell の `bash -n` / `shellcheck`、config の `json-syntax` / `yaml-syntax`、docs の `md-links` 等。**ruff / pytest / go test のように自分でツリーを歩くツールには効かない。** それらはそれぞれの無視設定(ruff の `exclude` / `per-file-ignores`、pytest の `testpaths` / `--ignore` 等)に従う。詳細は「[効かないとき](#効かないとき)」。

### CI だけ挙動を変えたい

**症状**: 普段使いの config はそのままに、CI だけで重いステージを外したい / shellcheck を厳しくしたい。

**書くもの**: 環境変数。config より優先される:

```bash
FEEDBACK_CHECK_SKIP="test build" bash scripts/check.sh   # CI だけで重いステージを外す
FEEDBACK_SHELLCHECK_SEVERITY=style bash scripts/check.sh # CI だけ厳しく
```

**出力がどう変わるか**: `--list-checks` の出所が `env.FEEDBACK_CHECK_SKIP` のように `env.` 始まりになる。**環境変数で切り替えられるのはこの3項目**(`FEEDBACK_CHECK_SKIP` / `FEEDBACK_SHELLCHECK_SEVERITY` / `FEEDBACK_CONTRACT_BASE`)で、判定(`severity` / `fail_on` / `warn_on`)を環境変数で上書きする口は無い。

### 特定の検査だけ絶対にブロックしたい

**症状**: 宣言していない検査は WARN になるが、これだけは必ず FAIL にしたい(例: 依存の実在性)。

**書く YAML**:

```yaml
checks:
  deptry:
    severity: fail
```

**出力がどう変わるか**: `--list-checks` で `warn` → `fail`、出所は `checks.deptry`。指摘があると `check.sh` が exit 1 になり完了がブロックされる。

## 優先順位

**環境変数 > `checks.<検査>` > `check.<スタック>` > `check`(全体) > 既定値**

最も具体的な指定が勝つ。使い分けの指針: **commit したい設定は config、その場限りの一時上書きは環境変数**。CI の workflow に書く環境変数はむしろ commit されるが、それは「CI という環境の既定値」を表している。

### 設定ファイルは2層ある

| ファイル | 追跡 | 用途 |
|---|---|---|
| `.feedback/config.yaml` | commit して共有 | チームの設定。全員に同じ判定を効かせる |
| `.feedback/local/config.yaml` | `.gitignore` 済み | この端末だけの設定。**共有設定より優先される** |

書ける項目は両方とも同じ。個人設定は、共有設定を書き換えずに手元の事情を反映したいときに使う — 使っていないツールの検査を切る、重い検査を一時的に外す、といった用途である。チームの判定を変えたいなら共有設定を直す。

個人設定で決まった項目は、`--list-checks` の出所が `local.` で始まる(例 `local.checks.ruff`)。SKIP の理由表示も `(config: …)` ではなく `(個人設定: …)` になる。個人設定は他の人からは見えないため、共有設定を読んでも理由が見つからない状況を避けるための区別である。

どちらのファイルが壊れていても、そのファイル名付きでエラーになり検査は既定値のまま続行する。

同じ層で同じステージを複数のキーに指定した場合は、`fail_on` > `warn_on` > `skip` の順で優先される。検査を誤って無効化しないよう、より厳しい判定を優先するためである。

## 項目リファレンス

辞書として引く章。通読する必要はない。検査IDは `--list-checks` の左端の列からコピーする。

**① 全体(`check`)**

| キー | 型 | 既定値 | 対応する環境変数 | 効果 |
|---|---|---|---|---|
| `skip` | ステージリスト | `[]` | `FEEDBACK_CHECK_SKIP` | 指定ステージを飛ばす。語彙は `lint` / `typecheck` / `test` / `build` / `format` / `security` / `docs` / `contract` |
| `fail_on` | ステージリスト | `[]` | — | 宣言が無くても WARN ではなく FAIL にする |
| `warn_on` | ステージリスト | `[]` | — | FAIL するステージを WARN に落とす |
| `exclude` | glob リスト | `[]` | — | ハーネスが列挙するファイルから除外する(効く範囲は上記) |
| `log_tail_lines` | 整数 | `40` | — | FAIL / WARN 時に出すログ行数。エージェントの文脈量に直結する |

**② スタック単位(`check.<stack>`)**

`skip` / `fail_on` / `warn_on` の3キーのみ。①と同じ意味で、そのスタックの検査にだけ効く。スタックは `python` / `node` / `go` / `rust` / `java` / `shell`。

**③ 検査単位(`checks.<id>`)**

| キー | 型 | 既定値 | 効果 |
|---|---|---|---|
| `severity` | `fail` \| `warn` \| `skip` | 検査ごと(宣言の有無で決まる既定) | この検査の判定。`skip` は実行しない |
| ツール固有キー | — | — | 下表 |

| 検査ID | 固有キー | 型 | 既定値 | 対応する環境変数 |
|---|---|---|---|---|
| `shellcheck` | `min_severity` | `style`\|`info`\|`warning`\|`error` | `warning` | `FEEDBACK_SHELLCHECK_SEVERITY` |
| `vulture` | `min_confidence` | 0〜100 の整数（大きいほど検出が減る） | `80` | — |
| `oasdiff` | `base` | 文字列 | `main` | `FEEDBACK_CONTRACT_BASE` |

**その他のセクション**

| キー | 型 | 既定値 | 効果 |
|---|---|---|---|
| `audit.interval_days` | 整数 | `7` | `stats` / `report` が「監査を推奨」を出すまでの経過日数 |
| `audit.npm_audit_level` | 文字列 | `high` | `npm audit --audit-level=<値>`(`low` / `moderate` / `high` / `critical`) |
| `feedback.open_threshold` | 整数 | `3` | `add` / `stats` / `report` が promote を促す open エントリ件数 |
| `feedback.lock_timeout_seconds` | 整数 | `10` | 複数agent/sessionが同時に更新したとき、repository lockの取得を待つ秒数(1〜300) |
| `feedback.stale_days` | 整数 | `7` | `stats` / `report` が頻出WARN・失敗上位に「これだけ再発していない」と注記するまでの日数 |
| `feedback.retro_interval_days` | 整数 | `90` | `stats` / `report` が「ルールの棚卸しを推奨」を出すまでの経過日数(基点は `.feedback/.last-retro`) |

### 検査ID一覧(41件)

暗記しないこと。使うときは `--list-checks` の左端の列からコピーする。以下は全体像の把握用。

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

## 効かないとき

### まず `--list-checks` で出所を見る

ほとんどの「効かない」は、**想定と違う層で判定が決まっている**ことの症状である。

```bash
bash scripts/check.sh --list-checks
```

- 出所が `既定` のまま → config が読めていない。下記「壊れた config」を確認
- 出所が config 由来のパス(例: `check.python.warn_on`)だが期待するキーと違う(例: `check.python.warn_on` を書いたつもりが `check.warn_on` で効いている)→ 優先順位の誤り
- 出所が `env.<変数名>` → 環境変数が export されたまま。config より優先されるため、`unset` するまで config は効かない

### 壊れた config は表の後に stderr へ出る(仕様)

config に打ち間違い(未知のキー・未知の検査ID・型不一致)があると、`--list-checks` は表を**既定値で**出した後に stderr へエラーを出して exit 1 する:

```
$ bash scripts/check.sh --list-checks
検査ID       ラベル               ステージ  判定  出所
(…表は既定値で出る…)

ERROR: .feedback/config.yaml を読めませんでした。以下はすべて既定値です。
.feedback/config.yaml: check.skip の 'lnit' は未知のステージです。使えるのは lint / typecheck / test / build / format / security / docs / contract
```

これは黙って既定値に落ちるより安全な挙動である — 「設定が効かない」の原因が config 自体の誤りであることを教えてくれる。`check.sh` の通常実行でも `FAIL  config: .feedback/config.yaml` が立つ。

### `exclude` の効く範囲

`exclude` が効くのは**ハーネス自身がファイルを列挙する検査**(`bash-syntax` / `shellcheck` / `json-syntax` / `yaml-syntax` / `md-links` 等)に限る。ruff / pytest / go test / vulture のように**自分でツリーを歩くツールには効かない** — それらはツール自身の無視設定(ruff の `exclude` / `per-file-ignores`、pytest の `testpaths` 等)に従う。ハーネスが各ツールの除外構文へ翻訳することはしない(ツールごとに意味が違い、翻訳は必ずずれるため)。

### `--list-checks` に載らない検査がある

`--list-checks` は、対象プロジェクトの構成から適用対象になった検査だけを表示する。適用対象になった検査でツールが未導入の場合は、行を省略せず `skip` と理由を表示する。一方、設定や対象ファイルが無く、検査の適用条件自体を満たさない場合は表示しない。たとえば import-linter の設定が無いプロジェクトでは `import-linter` は表示されないが、設定がありツールだけが無い場合は `skip` と表示される。

機械処理で全行を取得したい場合は、次の JSON 出力を利用できる。

```bash
bash scripts/check.sh --list-checks --json
```

### それでも分からなければ

`bash -c '. scripts/lib.sh; harness_python scripts/harness_config.py --json'` で解決済みの全実効値を出せる。「[YAML の書ける記法・書けない記法](#yaml-の書ける記法書けない記法)」に該当しないかも確認すること。

## YAML の書ける記法・書けない記法

config の YAML は PyYAML を要求せず自前のパーサで読む(任意依存を増やさないため)。そのため**書ける記法が YAML のサブセット**になっている。

**書ける記法**:

- コメント(`#` 始まり、および値の後ろ)
- 入れ子マップ(スペースインデント。深さ制限なし)
- スカラー: 裸文字列 / `'...'` / `"..."` / 整数 / `true`・`false` / 空(= null)
- リスト: ブロック形式(`- item`)とフロー形式(`[a, b]`)、空リスト `[]`

**書けない記法(行番号と理由付きでエラーになる)**:

- アンカー・エイリアス(`&` / `*`)
- 複数文書(`---` 区切り)
- 複数行文字列(`|` / `>`)
- リスト要素の入れ子(マップやリストを要素に持つリスト)
- タブインデント

また、クォート（`'` / `"`）やフロー形式のリスト（`[`）を閉じていない場合も、行番号付きのエラーになる。壊れた値を通常の文字列として受理し、後続の検査が意図せず無効になることを防ぐためである。

書けない記法を黙って無視すると「書いたのに効かない」という最悪の状態になるため、いずれも FAIL にする。未知のキー(`shelcheck_severity` のような打ち間違い)も同じ理由でエラーになる。
