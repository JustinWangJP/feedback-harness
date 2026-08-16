# Flywheel Step 4 設計 — 測る(stats)・共有する(report)・シグナル型(--signal)

- 日付: 2026-08-16
- 提案: [docs/proposals/2026-08-16-flywheel-expansion-proposal.md](../../proposals/2026-08-16-flywheel-expansion-proposal.md)
- 採用範囲(ユーザー確定): **P1(イベントログ+stats)/ P2(report)/ P3(--signal)**。P4(doctor)・P5(還流)は見送り
- ステータス: 設計済み・未実装

---

## 1. スコープと目標

| 採用案 | 記事上の根拠(翻訳文書の行番号) | ゴール |
|---|---|---|
| P3 シグナル型 | L37–47(四种信号・信号→制品の具体マッピング) | 4分類を frontmatter のデータにし、昇華先ルーティングと rules.md の構造を型で駆動する |
| P1 イベントログ+stats | L69–73(初回通過率・イテレーション数。仪表盘は建てない) | フック合否から「効いているか」の数字をテキストで出す。再発候補の列挙を機械化 |
| P2 report | L55–61(朝会の1問・振り返りの具体産出・既存会議+5分) | 期間区切りの Markdown ダイジェストを既存の儀式に供給する |

設計原則(記事 L73, L79 を維持に翻訳): 出力は要求時のテキストのみ。常駐プロセス・グラフ・外部送信なし。stats / report は**読み取り専用**。

## 2. 全体像(データフロー)

```
[書き込みはフックとCLIのみ]
post_edit.sh ──check_file.sh の合否──▶ .feedback/events.jsonl(1行JSON・ローカル・gitignore)
on_stop.sh   ──check.sh の合否(実行時のみ)──▶ .feedback/events.jsonl
feedback_log.py add/promote/close/retire
    ├─ .feedback/log/*.md   frontmatter に signal / status_changed を追加
    └─ .feedback/rules.md   失敗由来/成功由来の2セクション構造

[読み取り専用の集計]
feedback_log.py stats  ──▶ 数字(初回通過率・再発候補)をテキスト出力
feedback_log.py report ──▶ 期間ダイジェスト(朝会/振り返りの議題)をテキスト出力
                              ↑ どちらも .feedback/.last-retro 等の状態は report --mark のみ更新
```

## 3. P3 — シグナル型の第一級化

### 3.1 スキーマ

- `feedback_log.py add --signal context|instruction|workflow|failure`(任意項目)
- frontmatter に `signal: <type>` を記録。**既存エントリには signal が無い** — 触らず `unknown` 扱いとする(後方互換)
- `list --signal <type|unknown>` フィルタを追加

### 3.2 推論規則(`--signal` 省略時)

| 条件(detail/category から判定) | 推論される signal |
|---|---|
| `detail` に `根因: 文脈欠落` を含む | `context`(知識の欠落 — 直す先はプライミング文書) |
| `detail` に `根因: 指示欠陥` または `根因: モデル限界` を含む | `failure` |
| 根因行なし・`--category workflow` | `workflow` |
| 根因行なし・その他カテゴリ | `instruction` |

明示指定が常に最優先。根因は failure のサブルーティング材料として現行どおり `--detail` に残る(signal は根因を置き換えない — 記事 L45 の「根因が制品を決める」を保存する)。

### 3.3 rules.md の2セクション構造

- ヘッダ直下に2つのマーカーコメントを置く:

```markdown
<!-- rules:failure -->
### 守るべき制約(失敗由来)
<!-- rules:success -->
### 再現すべき措辞・進め方(成功由来)
```

- `promote` は signal でセクションを選ぶ: `instruction`/`workflow` → success、`failure`/`context`/`unknown` → failure
- マーカーが存在しない既存 rules.md では、promote/retire 実行時に**既存ルール群を failure セクションとして**マーカーを挿入する(現存の4ルールはすべて失敗由来のため整合)
- `find_rule_by_source` / `retire` / `merge` は行スキャン方式のためマーカー透過(撤去・追記の挙動は変わらない)
- `.feedback/rules.template.md` にマーカーと見出しを追加(新規導入は最初から2セクション)

### 3.4 昇華先ルーティング(curator の判断軸を拡張)

| signal | 昇華先 |
|---|---|
| `context` | 導入先 CLAUDE.md への追記案(提案止まり・現行維持) |
| `instruction` | rules.md **success** セクションへ `promote` |
| `workflow` | rules.md **success** セクションへ `promote`(category=workflow) |
| `failure` | 根因でサブルーティング(現行維持): 指示欠陥→rules.md **failure** / モデル限界→境界ルール(failure)/ 機械検出可→lint・テスト追加案(提案止まり) |

### 3.5 文言の追随

- `skills/capture-feedback/SKILL.md`: 手順に signal の選択(または推論に任せる)を1項目追加
- `skills/apply-feedback/SKILL.md`: rules.md の2セクションの読み方を1行追加(success は再現すべき措辞)
- `agents/feedback-curator.md`: ルーティング表を 3.4 に差し替え
- `AGENTS.md` / `docs/pointer_agents.md`: 規約4のコマンド例に `--signal` を追記
- `README.md`: 運用フロー図に signal を反映

## 4. P1 — イベントログ + `stats`

### 4.1 イベント収集(hooks)

- `post_edit.sh`: `check_file.sh` 実行の直後に結果を1行追記:

```json
{"ts": "<ISO8601>", "hook": "post_edit", "file": "<ルート相対パス>", "result": "pass"|"fail"}
```

  - **成功時も記録する**(現状は失敗しか観測されない — 初回通過率には成功の分母が要る)
  - `file` が解決できないとき(ツール入力に file_path 無し)は記録しない
  - 追記はフック本体に影響を与えない: `mkdir -p` + `|| true` で沈黙化(フックが記録失敗で壊れない)

- `on_stop.sh`: `check.sh` を**実際に実行した場合のみ**(skip 判定・2周目は無記録):

```json
{"ts": "<ISO8601>", "hook": "stop", "result": "pass"|"fail"}
```

- ローテーション: 追記後にファイルが 512KB 超なら末尾 2000 行へ切り詰め
- **木変更判定との関係(設計前提)**: `harness_tree_changed` は `.feedback/` を丸ごと prune する(`scripts/lib.sh:75-78`)ため events.jsonl は判定に影響しない。この前提を固定する回帰テストを追加する(§7)
- `.gitignore` に `.feedback/events.jsonl` を追加。README に「`.last-check` と同様のローカル状態であり共有しない」旨を明記

### 4.2 `stats` サブコマンド

`feedback_log.py stats [--since YYYY-MM-DD] [--days N](既定30)`

出力は全てプレーンテキスト(グラフ・色なし)。セクション:

1. **フック(イベント系)** — events.jsonl から:
   - PostToolUse 初回通過率: 期間内で各ファイルの**最初の** post_edit イベントが pass だった割合(初回=期間スナップショット。期間を跨ぐ再登場はリセット)
   - 平均再チェック回数: ファイルごとの fail イベント数の平均(イテレーション数の代理)
   - Stop フルチェック初回通過率: stop イベントの pass 率
   - 失敗上位ファイル TOP5(fail 件数)
2. **ログ系** — `.feedback/log/` から:
   - signal / category / 根因 / source 別の件数
   - open 滞留: 最古 open の経過日数と件数(3件超はその旨)
   - promote 率: status 別件数
3. **再発候補** — rules.md の各ルール(出典 id + 昇華日)について、昇華日以降に作成された**同 category かつ signal が failure/context/unknown** のエントリを列挙(curator 原則5・Phase 4 手順1の機械化)

events.jsonl が不在・空ならセクション1は「(イベント記録が無い)」と出して残りを出す。

### 4.3 エラー処理

- events.jsonl の不正 JSON 行は読み飛ばして集計継続(壊れた記録が stats を殺さない)
- 日付解析不能な frontmatter も同様に読み飛ばす
- stats は一切書き込まない

## 5. P2 — `report` サブコマンド

`feedback_log.py report [--since <YYYY-MM-DD>|yesterday|--last] [--mark]`

- `--last`: `.feedback/.last-retro` の mtime(または内容日付)以降。`--mark` 指定時のみ実行後にスタンプを更新する(レポート生成と「振り返りをやった」は別のタイミングのため、更新は明示に限る)
- `--since yesterday`: 前日 00:00 以降(朝会の1問 L55 のためのショートカット)

出力セクション(Markdown、振り返りドキュメントに貼れる5分議題):

1. 期間と対象件数
2. 新規エントリ(signal → category のグループ、要約行)
3. 昇華・統合: rules.md の出典行(日付付き)が期間内のもの
4. close / retire: frontmatter の `status_changed` が期間内のもの
5. open 棚卸し(最古滞留・3件超警告)
6. 再発候補(stats と共通ロジックを利用)
7. 数字: イベントデータがあれば初回通過率の前期間 vs 当期間比較、無ければセクションごと省略

### スキーマ追加: `status_changed`

- `set_status`(promote/merge/close/retire 共通)が frontmatter に `status_changed: YYYY-MM-DD` を書く(1キー・上書き)
- 既存エントリは持たない → report では「日付不明」扱い。promote の日付は rules.md 出典行が真実源のため、セクション3は出典行ベース・セクション4は status_changed ベースと**情報源を1つに定める**(二重管理しない)

## 6. 影響範囲

| ファイル | 変更 |
|---|---|
| `scripts/feedback_log.py` | `--signal`/推論、`list --signal`、rules.md 2セクション化(promote/retire/merge)、`status_changed`、`stats`、`report` |
| `scripts/hooks/post_edit.sh` / `on_stop.sh` | イベント追記+ローテーション |
| `scripts/lib.sh` | 変更なし(prune 前提は既存。コメントで `.feedback/` prune が events.jsonl を含む旨を追記のみ) |
| `.gitignore` | `.feedback/events.jsonl` 追加 |
| `.feedback/rules.template.md` | 2セクションのマーカーと見出し |
| `skills/capture-feedback/SKILL.md` / `skills/apply-feedback/SKILL.md` / `agents/feedback-curator.md` | §3.5 の文言 |
| `skills/feedback-loop/SKILL.md` | Phase 0 の実行モード判定に「レポート/数字」系の依頼を追加し、Phase 4 棚卸しの前処理として `stats`/`report` の実行を案内 |
| `AGENTS.md` / `docs/pointer_agents.md` / `docs/pointer_claude.md` | 規約4のコマンド例に `--signal`、report の案内 |
| `README.md` | 運用フロー・構成・`stats`/`report` の説明、events.jsonl の位置づけ |
| `tests/` | §7 の新規テスト |
| `CLAUDE.md` / `.claude-plugin/plugin.json` | 変更履歴 1 行 / バージョン 0.3.0 |

## 7. テスト方針

既存ルール(`.feedback/rules.md`: 検証対象の機構をそのテスト自身の合否判定に使わない)に従い、期待値はリテラルで書き、判定は自前カウンタ+明示 exit とする。

| テスト | 検証内容 |
|---|---|
| `tests/test_signal_inference.sh` | 根因/category の組合せ推論・明示指定優先・既存エントリ unknown |
| `tests/test_rules_sections.sh` | マーカーの遅延挿入・promote のセクション選択・retire のセクション跨ぎ撤去 |
| `tests/test_events_exclusion.sh` | `.feedback/` 内(events.jsonl)の更新で `harness_tree_changed` が「変更なし」を維持する(prune 前提の固定) |
| `tests/test_stats.sh` | 数値既知のフィクスチャ events.jsonl/log/rules から初回通過率・再発候補の期待値一致・不正 JSON 行の読み飛ばし |
| `tests/test_report.sh` | フィクスチャからの期間集計セクション・`--mark` によるスタンプ更新 |

加えて既存テスト全 green(`make check`)を実装完了条件とする。

## 8. 実装順序(writing-plans への引き継ぎ骨格)

1. **P3**: signal スキーマ+推論+`list --signal` → rules.md 2セクション化 → 文言(curator/skills/AGENTS/pointers/README)
2. **P1a**: hooks のイベント追記+ローテーション+`test_events_exclusion.sh`+.gitignore
3. **P1b**: `stats`(ログ系 → フック系 → 再発候補の順で実装)
4. **P2**: `status_changed` → `report`(セクション3–4 → `--last`/`--mark`)
5. README・CLAUDE.md 変更履歴・バージョン 0.3.0・全体チェック

各ステップはテスト先行(TDD)で進める。
