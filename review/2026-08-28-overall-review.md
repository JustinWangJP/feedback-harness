# feedback-harness 全体レビュー（main）

- レビュー日: 2026-08-28（Asia/Tokyo）
- 対象リポジトリ: `JustinWangJP/feedback-harness`
- 対象ブランチ: `main`
- 対象 HEAD: `0e827e13646f570691f4546811462c6151d34510`
- HEAD 日付: 2026-08-28 23:01:28 +09:00
- HEAD 件名: `Merge pull request #14 from JustinWangJP/claude/feedback-harness-fixes-dgnghz`
- 前回レビュー: `review/2026-08-27-overall-review.md`（対象 `ad5de82dd258a57c8c65821021bb82e9e595406c`）
- GitHub CI: [run 33178125831](https://github.com/JustinWangJP/feedback-harness/actions/runs/33178125831)
- HTML Artifact: この実行環境には HTML Artifact の publish 機能が無いため、Markdown のみで完結する

## 結論

前回の P1 1件・P2 2件はすべて解消済みで、中心機能を止める欠陥は今回見つからなかった。前回からの差分は、7指摘への修正、回帰テスト、3言語文書の同期、プラグイン 0.1.10 化が中心であり、修正の意図と実装は概ね一致している。

ただし、前回 P3「テスト規約の実装漏れ」は**一部解消に留まる**。新設された走査が `$(python3 …)` の直書きだけを検出し、環境変数を前置した呼び出しや関数経由の捕捉を見逃すためである。また、日付入力の通常の誤記は修正されたが、表現可能範囲の端では traceback が残る。今回の指摘は P3 1件、P4 1件で、P1/P2 は 0件である。

## 0. 対象固定と実測結果

### リポジトリの最新化

指定どおり `git fetch origin main && git checkout main && git pull` を実行し、`Already up to date.` を確認した。レビュー開始時の `main` と `origin/main` は同一 SHA だった。

### テスト・自己検査

| 実測項目 | 結果 |
|---|---|
| `bash tests/run_tests.sh` | **40 passed / 0 failed**、exit 0 |
| テスト内 SKIP | `test_plugin_manifest.sh`: 開発用フック定義なし、`test_stage_timeout.sh`: この macOS 環境に `timeout(1)` なし |
| `bash scripts/check.sh` | **ALL PASS（3件SKIP）**、exit 0 |
| 自己検査 PASS | ruff、ruff format、npm ls、bash -n、shellcheck、JSON 構文、内部リンク、make check（8件） |
| 自己検査 SKIP | PyYAML 未導入、secretlint 設定なし、actionlint 未導入（3件） |

`test_stage_timeout.sh` はこのローカル環境では SKIP したため、ローカルの全テスト成功だけをタイムアウト機能の根拠にはしていない。同テストが実際の `scripts/check.sh` を偽 ruff（`sleep 30`）で駆動し、TIMEOUT、config 優先、WARN 降格、shell 関数検査の非消失をアサートしていることを読んだ。加えて、同じ HEAD の GitHub CI で Linux / Windows Git Bash の両 job が success であることを確認した。

レビュー用 worktree での push 前フルチェックも exit 0（ALL PASS、4件SKIP）だった。上表との差は、専用 worktree に `node_modules` が無く `npm ls` が追加で SKIP した1件である。

### 蓄積状況

| 項目 | 件数 | 前回比 |
|---|---:|---:|
| `.feedback/log/*.md` | 35 | ±0 |
| `.feedback/rules.md` のルール | 22 | ±0 |
| open エントリ | 0 | ±0 |

ルール件数は `^- **[category]**` 形式のルール行を数えた。open は `bash scripts/feedback.sh list --status open` で「該当エントリなし」を確認した。

### CI

GitHub CLI で対象 SHA の run を確認した。

| job | 結論 |
|---|---|
| Linux checks | success |
| Windows Git Bash checks | success |

run 全体は `completed / success`、head SHA はレビュー対象と同じ `0e827e13646f570691f4546811462c6151d34510` である。

### 前回からの差分

前回対象 `ad5de82…` から 30ファイル、849 insertions / 67 deletions。主な差分は以下である。

- 前回 7指摘の修正（`abbdeb9`）
- frontmatter・日付・Stop ループ・環境変数・ステージタイムアウトの回帰テスト追加
- Python 境界用 `tpy` と走査テスト追加
- `exclude` の非対称性とステージタイムアウトを3言語文書へ反映
- Claude / Codex プラグインを 0.1.10 へ更新

## 前回指摘の解消状況

| 前回 | 状況 | 確認内容 |
|---|---|---|
| ① P1 frontmatter 乗っ取り | **解消済み** | `parse_entry()` は先頭 frontmatter ブロックだけを読む（`scripts/feedback_log.py:381`）。`test_entry_frontmatter.sh` は実入口 `feedback.sh` で add→list/search/promote/close を往復し、本文中の `id:` 等がメタデータを上書きしないことを確認している。 |
| ② P2 Python 不在時の Stop ループ防止 | **解消済み** | `on_stop.sh:27-47` に shell fallback が入り、`test_on_stop_skip.sh:100-110` が `HARNESS_PYTHON=/nonexistent/python` の true/false 両方を実入口で確認している。 |
| ③ P2 `--since` / `.last-retro` 無検証 | **解消済み** | `parse_date_arg()` と `resolve_report_since()` が通常の誤形式を拒否し、壊れた `.last-retro` には復旧手順を返す。`test_date_args.sh` が stats/report と基点ファイルを実入口で検証している。端の値に残る traceback は今回の P4 として分離した。 |
| ④ P3 環境変数だけ無検証 | **解消済み** | `harness_config.py:566-602` で未知ステージ・型・列挙・範囲を config と同じ規則で検証し、`test_config.sh` / `test_config_wiring.sh` が shell 入口まで確認している。 |
| ⑤ P3 ステージタイムアウトなし | **解消済み** | `check.sh:79-87,117-224` に GNU timeout 能力判定と TIMEOUT 集約が入り、`on_stop.sh:67-74` が 240秒の fallback を渡す。`timeout(1)` 非対応時に無効となることも文書化済み。 |
| ⑥ P3 テストの Python 境界規約 | **一部解消・再掲** | 21箇所の一部は `tpy` へ移行し、規約も具体化された。一方、`test_python_boundary.sh:91-93` の走査は直書きだけを検出し、現存する環境変数前置・関数経由の捕捉を見逃す。詳細は新指摘①。 |
| ⑦ P4 `exclude` の非対称 | **解消済み** | 挙動自体は仕様どおりであり、`docs/configuration.ja.md:279` ほか3言語に PostToolUse / Stop の差と揃え方が追記された。 |

## 1. 実装品質

前回から最も改善したのは、入力境界と失敗の見せ方である。

- frontmatter は「書き込み時にエスケープ」ではなく読み取り契約を先頭ブロックに限定したため、既存の壊れた記録も救える。
- 環境変数の検証は config と同じ `_check_type()` / 列挙を再利用し、入口ごとのドリフトを増やしていない。
- ステージタイムアウトは `timeout(1)` の存在だけでなく `--kill-after` 対応まで確認し、Windows の同名コマンドや BusyBox を利用者コードの失敗として誤報しない。
- shell 関数を timeout の外へ残す判断には、別プロセスから関数を exec できず検査が SKIP に落ちる理由がコメントとテストの両方で残っている。

一方、テスト規約の護欄は構文を文字列パターンで近似しており、保証したい意味（「Python 出力が比較へ入る」）と検出条件（「`$(python3 ` という字面」）が一致していない。過去ルールが避けるよう求めている「テスト名・コメントの主張と実際のアサーション範囲のずれ」が、回帰テスト自身に残った形である。

## 2. 実用性

ステージタイムアウトの追加は、前回の実用上の最大の穴を直接埋めている。Stop フックの外側 300秒で無音終了する前に、ステージ名・上限・ログ末尾・設定変更方法を返せる。`severity: warn` を維持するため、既存の段階導入契約も壊していない。

ローカルで `timeout(1)` が無い場合は従来どおり無制限となるが、これは SKIP 理由と3言語文書で明示されている。導入初日の挙動として妥当である。ただし、利用者が「Stop は必ず 240秒で切れる」と思わないよう、設定例にも `timeout(1)` 条件を一言併記するとさらに誤解が減る。

残る実用上の天井は前回と同じで、計測がマシンローカルであること、実行時出力が日本語中心であること、配布バージョンと git tag / release の対応を追いにくいことである。前回から変化がないため詳細は再掲しない。

## 3. 機能性

前回からの実質的な機能追加は「ステージ単位の TIMEOUT」と、入力検証・frontmatter 読み取りの堅牢化である。自動検査、蓄積、計測、監査、設定レイヤ、Claude / Codex / init.sh 配布という既存の機能面は維持されている。

特に TIMEOUT を FAIL と分けたことは、単なる表示変更ではない。「コードが落ちた」と「時間内に観測できなかった」を別の次アクションへつなげられるため、エージェント向けハーネスとして機能的に意味がある。

機能の穴として前回挙げた、チーム合算、実行結果の JSON、Gradle マルチモジュール派生 ID は未着手である。今回の変更範囲外であり、優先度の変更材料もない。

## 4. よくできたこと

1. **前回指摘を修正単位で閉じた。** コードだけでなく回帰テスト、3言語文書、設計メモ、プラグインバージョンまで同じ変更系列に入っている。
2. **回帰テストの多くが本番入口へ触れている。** frontmatter は `feedback.sh` の往復、日付は stats/report、Stop は hook script、環境変数は `check.sh` まで駆動している。
3. **未検証を隠さない。** ローカルの timeout テストと自己検査の3項目は SKIP 理由が明示され、GitHub CI を別の証拠として確認できる。
4. **失敗モードから設計している。** timeout 非互換、shell 関数の exec 不可、壊れた基点ファイル、既存 frontmatter の救済まで、正常系以外の挙動がコメントに残る。
5. **P1/P2 を短期間で解消した。** 中心の記録ライフサイクルと Stop 無限ループという重大箇所が、今回の main では再発しなかった。

## 5. 改善できること

優先順は以下である。

1. **Python 境界の護欄を意味に近づける。** 直書き grep で「捕捉全体」を保証したことにせず、環境変数前置・複数行・関数経由を扱う。新指摘①。
2. **日付の算術境界を中央で検証する。** 形式検証だけでなく、実際に行う減算・前期間計算まで安全にできる範囲を契約にする。新指摘②。
3. **自己検査の機械可読結果を追加する。** `--list-checks --json` だけでなく実行結果も JSON にすれば、PASS/SKIP/TIMEOUT と所要時間を CI・定期レビューから再解析しやすい。
4. **リリース追跡を整える。** plugin.json だけの 0.1.10 更新では、導入済みキャッシュとソース commit の対応を後から追いにくい。tag / GitHub Release / changelog の最小セットが欲しい。

## 6. 機能性と実用性の拡張余地

前回案を差分ベースで再評価した。

1. **`check.sh --json`（実行結果）**: TIMEOUT が加わった今、PASS/FAIL/WARN/SKIP/TIMEOUT、所要時間、出所を構造化する価値が上がった。
2. **SessionStart で rules/open を注入**: 22ルールを毎回手動手順に依存させない。文脈量を抑えるため、作業パス・カテゴリで絞る設計と組み合わせる。
3. **チーム合算メトリクス**: 個人パスを除いた日次サマリだけを export し、初回通過率と頻出 WARN を共有する。
4. **所要時間の記録**: TIMEOUT の有無だけでなく、ステージ別 duration を events / JSON 結果へ載せ、240秒や個別上限を実測で調整できるようにする。
5. **配布・OSS 運用**: tag、Release、CONTRIBUTING、SECURITY、依存更新の方針を揃える。

スタック追加（.NET / Ruby / Terraform 等）は引き続き可能だが、現時点では上記の観測性・配布追跡の方が既存利用者への効果が大きい。

## 7. 不具合検知

### ① [P3] Python 出力境界の走査が関数経由・前置代入を見逃す（前回⑥の残存）

対象:

- `tests/test_python_boundary.sh:91-93`
- 現存例: `tests/test_config.sh:18-26,156-159,281-295,422`
- 現存例: `tests/test_report.sh:17,79,115,119,122,138,145`

`test_python_boundary.sh` は `\$\(python3 ` だけを grep し、空であることを「テストは Python 出力の捕捉に tpy を使う」証拠としている。しかし次の形式はすべて捕捉結果を比較へ渡すのに、走査を通過する。

- `OUT="$(CLAUDE_PROJECT_DIR=… python3 …)"`（`$(` の直後が `python3` ではない）
- `fb() { python3 …; }; OUT="$(fb …)"`（関数経由）
- `parse() { python3 …; }; assert_eq expected "$(parse …)"`（関数経由）

現リポジトリにも上記の形式が残る。Windows CI が success であることは、現アサーションが CR に耐えている・対象経路で CR が出ていないことの証拠にはなるが、走査が将来の比較回帰を捕捉する証拠にはならない。

再現手順（本リポジトリの `.feedback/` を触らない隔離 git project で実測）:

```bash
mkdir -p _workspace/overall-review-2026-08-28-repro/tests
git init _workspace/overall-review-2026-08-28-repro
export CLAUDE_PROJECT_DIR="$PWD/_workspace/overall-review-2026-08-28-repro"

# tests/indirect_capture.sh に次の3形式を書く
# fb() { python3 tool.py "$@"; }
# parse() { python3 -c 'print("fixture")'; }
# OUT="$(CLAUDE_PROJECT_DIR=/tmp/isolated python3 tool.py stats)"

pattern='\$\(python'"3 "
grep -rnE "$pattern" "$CLAUDE_PROJECT_DIR/tests"/*.sh
# 実測: 0件

rg -n -U '\$\([^)]{0,300}python3|^[A-Za-z_][A-Za-z0-9_]*\(\).*python3' \
  "$CLAUDE_PROJECT_DIR/tests"/*.sh
# 実測: 3件
```

修正案:

- 現在残る比較用呼び出しを `tpy` へ移す。
- 単一の直書きパターンではなく、複数行・前置代入を含む command substitution と、Python を起動する helper の利用箇所を検査する。
- 文字列 heuristic を続けるなら、意図的な raw Python 呼び出しへ行内注釈（例: `python-boundary: raw-ok`）を要求し、注釈の無い `python3` を禁止する方が、別ファイルの allowlist より追加漏れを捕まえやすい。
- 回帰テストには、上記3形式を fixture として与えたとき護欄自身が失敗する変異テストを追加する。

### ② [P4] 日付形式は検証されたが、算術可能範囲の端で traceback になる

対象:

- `scripts/feedback_log.py:205-212`（`resolve_since`）
- `scripts/feedback_log.py:954-956`（前期間計算）

前回 P2 の通常ケース（`2026/08/01`、`notadate`、壊れた `.last-retro`）は解消した。一方、`--days` は非負だけを確認してから `timedelta` を作り、report は ISO として妥当な最小日付からさらに1日引く。このため、形式上は受理された入力でも Python の表現可能範囲を越えて traceback になる。

再現手順（隔離 git project、`CLAUDE_PROJECT_DIR` 明示）:

```bash
mkdir -p _workspace/overall-review-2026-08-28-repro
git init _workspace/overall-review-2026-08-28-repro
export CLAUDE_PROJECT_DIR="$PWD/_workspace/overall-review-2026-08-28-repro"

bash scripts/feedback.sh stats --days 1000000000
# exit 1 / OverflowError: days=1000000000 ...

# report の「前期間」計算へ入るよう、本番 writer でイベントを1件作る
bash -c '. scripts/lib.sh; harness_log_event "$CLAUDE_PROJECT_DIR" post_edit pass x.py'
bash scripts/feedback.sh report --since 0001-01-01
# exit 1 / OverflowError: date value out of range（feedback_log.py:955）
```

修正案:

- `--days` は `today - timedelta(days=N)` が可能な上限まで検証し、範囲外なら期待範囲と修正方法を表示して終了する。
- `report` の前期間は、`since == date.min` なら比較対象なしとして省略する。一般には減算を共通 helper に集約して `OverflowError` を利用者向けエラーへ変換する。
- `test_date_args.sh` に最大・最小境界と「Traceback を出さない」アサーションを追加する。

### 未確認の疑い

なし。上記2件は隔離プロジェクトで再現済みである。`timeout(1)` 非対応環境での打ち切り無効は仕様として文書化されており、不具合扱いしていない。

## 8. ドキュメントと実装の整合性

前回からの整合性改善は明確である。

- `check.stage_timeout_seconds` は config example、設定ガイド3言語、scripts README 3言語へ同期された。
- `exclude` の PostToolUse / Stop 非対称は設定ガイド3言語へ明記された。
- Python 境界規約は `tpy` という具体的入口と走査テストへ結びついた。
- Claude / Codex plugin manifest は 0.1.10 で揃い、manifest テストも通っている。
- GitHub CI は Linux / Windows Git Bash とも対象 SHA で success である。

残る不整合は新指摘①である。CLAUDE.md とテストコメントは「比較用 Python 出力は tpy」「走査で再発を禁止」と読めるが、実際の走査は前置代入・関数経由を対象にせず、現存例もある。文書の原則を弱めるより、護欄を原則へ合わせる方がプロジェクトの設計思想に整合する。

## 優先度集計

| 優先度 | 件数 | 前回 | 変化 |
|---|---:|---:|---:|
| P1 | 0 | 1 | -1 |
| P2 | 0 | 2 | -2 |
| P3 | 1 | 3 | -2（前回⑥の残存） |
| P4 | 1 | 1 | ±0（前回⑦は解消、新規1） |

推奨順は、P3 の護欄を修正して「修正済み」の保証範囲を実態へ合わせ、その後 P4 の日付算術境界を小さな入力検証として閉じる、である。
