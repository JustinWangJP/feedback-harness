# feedback-harness 全体レビュー(main)

> **履歴資料:** これは 2026-09-02 時点の `main` に対する定期レビュー記録です。**指摘は §0 のとおり対応済み**で、件数・行数・SHA はレビュー実施時点のスナップショットです(現在の値とは一致しません)。現在の仕様は[プロジェクト概要](../README.md)・[設定ガイド](../docs/configuration.ja.md)・[スクリプト仕様](../scripts/README.ja.md)と実装を参照してください。

- レビュー日: 2026-09-02(Asia/Tokyo、月・水・金・日 9:00 の定期実行)
- 対象リポジトリ: `JustinWangJP/feedback-harness`
- 対象 HEAD: `951f783ebe29b4b0559bf87d15e39011227ee7b4`(2026-08-30 22:42 JST、`Merge pull request #16 from JustinWangJP/feature/docs-update-20260830`)
- 規模: shell 7,590 行 / Python 2,265 行 / Markdown 14,060 行、コミット 182 件(2026-08-09〜)、git tag 10件(最新 `v0.1.11` = HEAD)
- 前回レビューからの差分: `ad5de82`(2026-08-27 レビュー対象)から 56ファイル / +1,352 −123

## 0. 改修状況(このブランチ)

本レポートの指摘5件は `claude/fix-overall-review-2026-09-02` で対応済み(`c538607` ほか)。
各修正は欠陥を再注入して護欄テストが落ちることを確認している。

| 指摘 | 対応 | 護欄 |
|------|------|------|
| ①[P1] `status_changed` の全文判定 | 境界判定を `split_frontmatter` へ集約し、読み書き双方が同じ関数を通る形へ | `tests/test_entry_frontmatter.sh` |
| ②[P2] `promote`/`merge` の状態ガード欠落 | `require_open` で open 以外を復旧手順つきに拒否 | `tests/test_feedback_log_retire.sh` |
| ③[P2] ESLint 設定検出の固定列挙 | `harness_has_eslint_config` で2系統を glob 網羅 | `tests/test_check_file_severity.sh` |
| ④[P3] `json-syntax`/`md-links` の偽 PASS | `yaml-syntax` と同じ事前ゲートで `SKIP` を明示 | `tests/test_check_config.sh` |
| ⑤[P3] mypy 宣言ゲートの緩い `grep` | 他の宣言ゲートと同じ `^\[tool\.` 形式へ + 走査で固定 | `tests/test_declaration_gates.sh` |

改修中に**同じ契約(環境の問題をユーザーのコードの失敗として報告しない)を破る欠陥を2件**
検出し、その場で塞いだ。どちらも③の修正で ESLint が実際に起動するようになって初めて表面化した:

- `--format unix` は ESLint 10 で core から外れており、指定すると「The unix formatter is no
  longer part of core ESLint」というツール自身のエラーが**ユーザーのファイルの問題**として
  差し戻される(実測 10.1.0)。formatter を指定しない形へ変更した。
- ESLint の終了コードは 0=指摘なし / 1=lint 違反 / 2=致命的エラーだが、実装は「非0なら違反」と
  扱っていた。そのため eslintrc しか持たないプロジェクト(ESLint 9 以降は eslintrc を読まない)で
  「`eslint.config.js` が見つからない」という設定エラーが、編集のたびに差し戻されていた。
  終了コード 1 のみを違反として扱う形へ変更した。

後者は改修版に対するコードレビューで見つかった。③の列挙拡大が `.eslintrc.*` を検出対象へ
含めたことで、この経路を実際に通るプロジェクトが増える — 修正が既存の欠陥の露出面を広げる形で、
「直した結果として別の欠陥が届くようになる」典型である。

なお §6 の拡張案は未着手で、レポートの記載のまま残している。

---

## 前回レビューについての注記

`review/` 配下で `main` にマージ済みの `*-overall-review.md` は 2026-08-27 版のみだが、この定期タスクと同形式のレビューが `origin/claude/scheduled-review-2026-08-28`(未マージ、PR化していないブランチ)にも存在し、日付はこちらの方が新しい。今回はこれを実質的な「前回レビュー」として解消状況を確認した(2026-08-27 版の指摘は 2026-08-28 版がすでに解消済みとして再確認済みのため、二重には辿らない)。同ブランチが `main` へマージされていない点は運用上の注意点として §5 に記す。

## 実測結果(レビュー時点)

### リポジトリの最新化

`git fetch origin main && git checkout main && git pull` を実行し、`Already up to date.` を確認した(clone 直後のため fetch 前後で差分なし)。

### テスト・自己検査(実測)

| 項目 | 結果 |
|---|---|
| `bash tests/run_tests.sh` | **41 passed / 0 failed**(exit 0)。SKIP 1件: `test_plugin_manifest.sh`(開発用フック定義なし) |
| `bash scripts/check.sh` | **ALL PASS(4件SKIP)**(exit 0) |
| 自己検査 PASS | python: ruff / ruff format、shell: bash -n、config: json 構文 / yaml 構文、docs: 内部リンク、make check |
| 自己検査 SKIP | node: npm ls(node_modules 未インストール)、shell: shellcheck(未インストール)、security: secretlint(設定なし)、ci: actionlint(未インストール) |

これらの PASS/SKIP は「テストが存在する」ことと同義ではない。§7 の指摘は、いずれもこの PASS 表示の裏でアサーションが実際には本番の入力(エージェントが書く detail・reason の文言、Python が使えない環境)に触れていなかった箇所である。

### 蓄積状況

| 項目 | 件数 |
|---|---:|
| `.feedback/log/*.md` | 40 |
| `.feedback/rules.md` のルール行(`^- \*\*[`) | 22 |
| open エントリ | 5(`bash scripts/feedback.sh list --status open`) |
| 最終監査(`audit.sh`) | 未実行 |
| 最終棚卸し(retro) | 未実行 |

open 5件は promote/close 未処理のまま `NOTE: openが3件以上` を出し続けている状態(閾値3、最古のエントリは4日経過)。内容は 2026-08-29/30 に記録された運用メモで、破壊的ではないが素振りの機会として残っている。監査・棚卸しの「未実行」は、`interval_days`(既定7日)・`retro_interval_days`(既定90日)に対して監査が一度も走っていないことを示す — リポジトリの活動期間(24日)からは監査だけは少なくとも2〜3回相当のタイミングを過ぎている。コードの欠陥ではないが、ハーネス自身が自分の運用契約(定期監査)を実施できていない状態であり、§5 に記す。

### CI

GitHub CLI(`gh`)・GitHub 連携ツールともにこの実行環境で利用不可だったため、**CI の結論は未確認**。参考として公開 Web ページを1回だけ確認したところ「Windows Git Bash checks」の1 run が `succeeded`(9m24s)と表示されたが、認証済み API 経由の確認ではなく、他 job の結論を含めて断定はしない。この点を理由にレビューは止めていない。

## 前回(2026-08-28)指摘の解消状況

2026-08-28 版レビューの指摘は2件(P3 1・P4 1)。いずれも解消を確認した。

| 前回 | 状況 | 確認内容 |
|---|---|---|
| ①[P3] Python 境界の護欄が前置代入・関数経由の捕捉を見逃す | **解消済み** | `tests/test_python_boundary.sh` の走査(`raw_test_python()`)が前置代入つき command substitution・関数経由・解決済み `$TEST_PYTHON` 直接起動まで拡張され(`:91-134`)、護欄自身の変異テスト(3fixture)が検出を固定している。 |
| ②[P4] `--days` / report の前期間計算が `date.min` 境界で `OverflowError` になる | **解消済み** | `resolve_since()` が `max_days` を超える `--days` をエラーメッセージで拒否し(`scripts/feedback_log.py:213-218`)、`cmd_report` の前期間計算も `date.min` 境界を回避する(`:962-969`)。隔離プロジェクトで `stats --days 1000000000` と `report --since 0001-01-01` を再実行し、どちらも traceback なく終了することを確認した(付録)。 |

その後の 2026-08-30 のドキュメント整合性点検(`34857eb`)の指摘(review/ が索引に無い、`docs/superpowers/plans/` の履歴注記欠落、tpy 捕捉の終了コード未検査、doc inventory のパス比較が部分文字列一致、README×3 の記述ずれ)も同一コミットで対応済みであることを、該当テスト(`tests/test_python_boundary.sh` の `unchecked_tpy_capture()`、`tests/test_doc_inventory.sh`)を読んで確認した。今回は「解消済み」の再検証に留め、本文は再掲しない。

## 1. 実装品質

**強い点(前回から継続)**

- 設定パーサ・優先順位判断が `harness_config.py` に一元化されたままで、shell/Python 双方が同じ解決結果を消費する構造にドリフトが無い。
- `feedback_store.py` の transaction/journal/roll-forward、Windows の 1バイトロック確保、`os.link` 非対応 FS のフォールバックは、今回読み直した範囲でも整合していた。`_apply_payload` の `current not in (before_hash, expected)` 判定は「lock 保持中の想定外の外部変更」を確実に検出する。

**弱い点(新規に確認)**

今回の指摘(§7)はすべて同じ形の欠陥に分類できる: **「frontmatter やステータスの判定を、ファイル全体・文字列全体への部分一致で行っている」箇所が、`parse_entry`(§7の前身、2026-08-27に修正済み)以外にもまだ残っていた。**

- `scripts/feedback_log.py:569-581`(`updated_status_text`)は `"status_changed:" in text` を**frontmatter に限定せず全文(body・close/retire理由を含む)に対して**判定しており、body 側にたまたま `status_changed: YYYY-MM-DD` という文言があると、frontmatter へ新規追加すべきフィールドをそちらに誤爆させる(§7-①)。
- `cmd_promote` / `cmd_merge` に `cmd_close` と同じ「対象が `open`(または妥当な現在状態)であることの確認」が無く、同じエントリを2回 promote/merge できてしまう(§7-②)。
- `scripts/checks/cross_cutting.sh` の `json-syntax` / `md-links` は `yaml-syntax`(`harness_has_pyyaml` で事前ゲート)と違い、Python 不在時に「検証できなかった」ことを可視化する仕組みが `run_stage` の外側に無い(§7-④)。
- `scripts/checks/python.sh:19` の mypy 宣言検出だけ、他の宣言判定(ruff-format/deptry/vulture/import-linter)と違って行頭アンカー・エスケープを欠く(§7-⑤)。

## 2. 実用性

- **`close` / `merge` / `retire` を安心して使えない場面がある。** §7-① により、事情(reason)や本文(detail)に日付を含む文言を書くと、その文言が silently 書き換わり、かつ振り返りレポートから消える。ハーネスの中心的価値は「記録すれば必ず辿れる」ことであり、これはその約束を部分的に破る。
- **`promote` の誤操作から自力で回復できない。** §7-② により、同じエントリを2回 promote すると `retire` が永久にエラーになり、`rules.md` の手編集(ドキュメントが明示的に避けるよう求めている操作)以外の回復経路が無い。
- 監査・棚卸しの「未実行」が長期化しても、通常の使用感には現れない(「実測結果」節)。
- git tag による配布追跡は前回指摘から改善した(`v0.1.11` が HEAD と一致)。`V0.1.2` / `V0.1.3` のみ表記が不揃い(実害なし)。CONTRIBUTING.md / SECURITY.md / Issue テンプレート / dependabot は引き続き未整備。
- PostToolUse(`check_file.sh`)と Stop(`check.sh`)の判定が、ESLint の設定ファイル形式によって食い違う場合がある(§7-③)。

## 3. 機能性

前回(2026-08-28)からの機能追加はなく、ドキュメント整合性の修正のみ。既存の自動検査・蓄積・計測・監査・設定レイヤ・配布の機能構成は変化していない。チーム合算計測・`check.sh` 実行結果 JSON・Gradle マルチモジュール派生ID は今回も未着手(§6)。

## 4. よくできたこと

1. **前回指摘(P3・P4)を回帰テストとセットで閉じた。** `test_python_boundary.sh` の走査拡張・変異テスト、`test_date_args.sh` の境界値テストとも、実入口を駆動している。
2. **ドキュメント整合性の護欄が実効化された。** `test_doc_inventory.sh` が正規化パス集合で照合するようになった。
3. **リリース追跡が改善した。** git tag が `plugin.json` のバージョンと揃った。
4. **未検証を隠さない姿勢が継続している。** 今回のレビューでも SKIP 理由・CI 未確認をそのまま記載できた。
5. **`cmd_close` は今回の観点(§7-②)を既に部分的に満たしていた。** `close` だけは `if target.get("status") != "open"` の防御を持ち、同じ関数群の中でも防御にばらつきがあることが、今回 `promote`/`merge` の欠落を見つける手がかりになった — 「一部の入口だけ検証強度が高い」という、CLAUDE.md 自身が名指しする失敗パターンがここにも残っていた。

## 5. 改善できること

- **`updated_status_text` の `"status_changed:" in text` 判定を frontmatter ブロックに限定する。**(§7-①)`parse_entry` が2026-08-27 に「先頭ブロック限定」へ直した教訓が、書き込み側のこの関数にはまだ反映されていない。
- **`cmd_promote` / `cmd_merge` に `cmd_close` と同じ状態ガードを入れる。**(§7-②)
- **監査・棚卸しの「未実行」を能動的に検知する経路を作る。** SessionStart や Stop の要約に `audit_status_lines()` を1行差し込むだけで済む。
- **定期レビュー(このタスク)の成果物を `main` へ確実に反映する経路を用意する。** 2026-08-28 のレビューはブランチのまま `main` の `review/` に入らず、「レビューが行われた事実」自体が `main` から見えない期間が生じた。
- **`json-syntax` / `md-links` を `yaml-syntax` と同じ事前ゲート方式に揃える。**(§7-④)
- **`scripts/checks/python.sh` の mypy 検出パターンを他の宣言判定と揃える。**(§7-⑤、1行)
- **`check_file.sh` の ESLint 設定ファイル検出を prettier/knip と同じ網羅方式へ揃える。**(§7-③)

## 6. 機能性・実用性の拡張余地

優先度順(効果 ÷ コスト、前回案を据え置きで再評価):

1. **`check.sh --json`(実行結果版)。** TIMEOUT が判定に加わって以降、PASS/FAIL/WARN/SKIP/TIMEOUT を構造化する価値が高いままである。
2. **SessionStart で rules.md / open / 監査期限切れを注入する。** 22件のルール・5件の open・「監査未実行」を手動手順に依存せず文脈へ乗せる。
3. **チーム合算メトリクス。** `events.jsonl` はローカルのままで、匿名化した日次サマリだけを export する。
4. **配布・OSS 運用の残り(CONTRIBUTING/SECURITY/Issue テンプレート/dependabot)。** タグ運用は前進したので次の一手はこちら。
5. **スタック拡張(.NET/Ruby/Terraform/Gradle マルチモジュール派生ID)。**

## 7. 不具合検知

各項目は**隔離した一時プロジェクト**(作業ディレクトリ配下に `git init` した空ディレクトリ、`CLAUDE_PROJECT_DIR` を明示)で実際に再現し、本リポジトリの `.feedback/` には触れていない。再現ログは付録に収めた。

### ① [P1] `close`/`promote`/`merge`/`retire` が、本文中の `status_changed:` 文言に釣られて frontmatter を更新せず、書いた本文まで書き換える

対象: `scripts/feedback_log.py:569-581`(`updated_status_text`)

```python
text = text.replace(f"status: {target.get('status')}", f"status: {new_status}", 1)
if "status_changed:" in text:
    text = re.sub(r"status_changed: \d{4}-\d{2}-\d{2}", f"status_changed: {today}", text, count=1)
else:
    text = text.replace(
        f"status: {new_status}", f"status: {new_status}\nstatus_changed: {today}", 1
    )
```

`"status_changed:" in text` はファイル**全体**(frontmatter + body + close/retire の `--reason` で追記される文言)への部分文字列判定であり、frontmatter にそのフィールドがあるかどうかを見ていない。エントリの `detail` や `close`/`retire` の `--reason` に、たまたま `status_changed: YYYY-MM-DD` という文字列が含まれていると(このプロジェクト自身がまさに日付・frontmatter のバグを記録し続けているため、実際に書かれうる文言である)、初回の状態変化で `re.sub(..., count=1)` が**その本文中の一致**を書き換え、frontmatter には `status_changed:` が一切追加されない。

実害は2つある。

1. **本文が黙って書き換わる。** ユーザー(エージェント)が書いた `2020-01-01` という具体的な日付が、無関係な「今日の日付」に上書きされる。
2. **`report` の「close・retire」節から永久に消える。** `cmd_report` はこの節を `status_changed` の有無・値で絞り込むため、frontmatter に無いエントリはフィルタに掛からず、振り返りに一切出てこなくなる(close/retire した記録が追跡不能になる、という `parse_entry` の旧 P1 と同じ壊れ方)。

再現(実測、隔離プロジェクト):

```
$ feedback.sh add --category workflow --summary "frontmatter note" \
    --detail "old broken template had a stray status_changed: 2020-01-01 line in it"
recorded: …/20260902-002710-frontmatter-note.md (id=20260902-002710)

$ feedback.sh close 20260902-002710 --reason "not generalizable"

$ cat .feedback/log/20260902-002710-*.md
---
id: 20260902-002710
...
status: closed          ← status_changed: が無い(frontmatter は更新されていない)
---
# frontmatter note

old broken template had a stray status_changed: 2026-09-02 line in it   ← 2020-01-01 が書き換わった

---
close理由: not generalizable

$ feedback.sh report --since 2026-08-01
## close・統合(rules.md)     ← このエントリが出てこない
(なし)
```

修正案: `parse_entry` と同じく「先頭 frontmatter ブロック内かどうか」で判定を限定する。具体的には、`text` をブロックに分けず操作するのではなく、frontmatter 相当の先頭行群(最初の `---` 〜次の `---`)だけを対象に `status_changed:` の有無・置換を行う小さなヘルパーへ切り出す。回帰テストは、`--detail`/`--reason` に `status_changed: 2000-01-01` を含むエントリで `close`/`promote`/`merge`/`retire` の往復(frontmatter に正しく追加される・本文の文言が変化しない・`report` に出てくる)を確認する形にする。

### ② [P2] `promote` / `merge` に状態ガードが無く、二重実行が `rules.md` の出典重複と `retire` の恒久ロックを生む

対象: `scripts/feedback_log.py:525-551`(`cmd_promote`)、`:627-661`(`cmd_merge`)。`cmd_close`(`:605-624`)は `if target.get("status") != "open": sys.exit(...)` を持つが、`cmd_promote`/`cmd_merge` には対応する確認が無い。

同じエントリに対して `promote` を2回実行する(エージェントの再試行・操作ミスなど)と、両方とも成功し、`rules.md` に**同じ出典を持つ2つの独立したルール**が生まれる。この状態になると、以後その entry_id を対象にした `merge --into` や `retire` はすべて `find_rule_by_source` の曖昧性チェック(`scripts/feedback_log.py:598-602`)に引っかかり、`ERROR: 出典に … を含むルールが2件あります。rules.md の出典の重複を解消してください` で失敗し続ける。CLI 側にはこの重複を解消する手段が無く、`rules.md` は手編集を前提としていない(`cmd_retire` のドキュメント文言も参照)。

再現(実測、隔離プロジェクト):

```
$ feedback.sh add --category style --summary "dup rule test" --detail "x"
recorded: … (id=20260902-002724)

$ feedback.sh promote 20260902-002724 --rule "rule A"
promoted: rules.md に追加し 20260902-002724 を promoted に更新
$ feedback.sh promote 20260902-002724 --rule "rule B"
promoted: rules.md に追加し 20260902-002724 を promoted に更新   ← 2回目も成功してしまう

$ grep -c "出典: 20260902-002724" .feedback/rules.md
2

$ feedback.sh retire 20260902-002724 --reason cleanup
ERROR: 出典に 20260902-002724 を含むルールが2件あります。rules.md の出典の重複を解消してください
```

修正案: `cmd_promote`/`cmd_merge` の先頭で `cmd_close` と同じ形の状態確認(`target.get("status") == "open"` のときだけ許可、あるいは merge 先の重複追加も含めて「このエントリは既にルールの出典です」を明示するメッセージで拒否)を追加する。回帰テストは、同一エントリへの2回目の `promote`/`merge` がエラーになること、および `rules.md` に出典の重複が生まれないことを確認する。

### ③ [P2] `check_file.sh` の ESLint 設定ファイル検出が不完全で、Stop では捕まる違反を PostToolUse が見逃す

対象: `scripts/check_file.sh:102-103`

```bash
if has npx && [[ -f .eslintrc.json || -f .eslintrc.js || -f eslint.config.js || -f eslint.config.mjs ]] \
   && npx --no-install eslint --version >/dev/null 2>&1; then
  cur="$(npx --no-install eslint --format unix "$FILE" 2>&1)" && cur=""
```

対象4種以外の ESLint 設定ファイル(`.eslintrc.cjs` / `.eslintrc.yml` / `.eslintrc.yaml` / 拡張子なし `.eslintrc` / `eslint.config.cjs` / `eslint.config.ts` 等)を使うプロジェクトでは条件が常に偽になり、単一ファイル検査(PostToolUse)は ESLint を一切実行しない。`.eslintrc.cjs` は `package.json` に `"type": "module"` を書いた CJS 設定でよく使われる形式であり、珍しくない。

一方 Stop 側(`scripts/checks/node.sh` の `run_node_checks`)は `package.json` の `scripts.lint` をそのまま実行するため、設定ファイル形式に依存しない。結果として **PostToolUse は「問題なし」と報告し、Stop になって初めて同じ違反が FAIL として出る**。同じファイル内の prettier/knip 判定が `compgen -G` で「列挙漏れを避ける」設計になっているのと対照的である。

再現(実測、隔離プロジェクト。ESLint はローカル環境に導入済み):

```
$ cat package.json
{"name":"demo","type":"commonjs","scripts":{"lint":"eslint ."}}
$ cat eslint.config.cjs
module.exports = [{ rules: { "no-unused-vars": "error" } }];
$ cat bad.js
const unused = 42;
module.exports = {};

$ check_file.sh bad.js; echo "exit=$?"
exit=0      ← 何も報告しない

$ check.sh .
FAIL  node: npm run lint
  1:7  error  'unused' is assigned a value but never used  no-unused-vars
```

修正案: 固定列挙をやめ、`.eslintrc*`(拡張子なし含む)・`eslint.config.*` を `compgen -G` 等で網羅する。あるいは ESLint 自身に設定の有無を判定させる(`--print-config` 等)方が drift しない。

### ④ [P3] `json-syntax` / `md-links` は Python が使えない場合に SKIP ではなく偽の PASS を報告する

対象: `scripts/checks/cross_cutting.sh:16,41`、`scripts/lib.sh` の `harness_validate_json` / `harness_check_md_links`(いずれも内部で `harness_has_python || return 0`)

`yaml-syntax` は `harness_has_pyyaml` で事前ゲートしてから `run_stage` を呼ぶため、PyYAML が無ければ正しく `SKIP` になる(`scripts/checks/cross_cutting.sh:27-32`)。一方 `json-syntax` / `md-links` にはこの事前ゲートが無く、`run_stage lint "json-syntax" "-" … harness_validate_json …` の形で無条件に呼ばれる。ヘルパー関数が Python 不在で `return 0`(何も検証せず正常終了)すると、`run_stage` はそれを「検査が成功した」と解釈し、**`PASS config: json 構文` を出す**。

実際には、Python が完全に不在/壊れている状況は `harness_load_config` が `HARNESS_CONFIG_ERROR` を立てるため `check.sh` 全体としては同じ実行内で `FAIL config: 設定エラー` も表示され、結果全体が exit 1 になる(`check_file.sh` はこのエラーを検出した時点で個別検査へ進む前に exit 1 で止まるため、この誤 PASS は現れない)。したがって「気づかれずに完了扱いになる」わけではないが、**`PASS config: json 構文` という個別の行自体は事実と異なる**(実際には何も検証していない)。設定エラーを直す過程でこの行を見た利用者が「JSON は検証済み」と誤解しうる。

再現(実測、隔離プロジェクト、`broken.json`(壊れた JSON)を含む):

```
$ HARNESS_PYTHON=/nonexistent/python check.sh .
=== feedback-harness check ===
FAIL  config: 設定エラー
PASS  config: json 構文        ← 実際には broken.json を検証していない
...
```

修正案: `json-syntax` / `md-links` も `yaml-syntax` と同じ「`harness_has_python` を事前ゲートにして `SKIP` を明示する」形に揃える。

### ⑤ [P3] mypy の宣言検出が行頭アンカー・エスケープ無しの `grep` で、無関係な文言にマッチして誤って FAIL 化する

対象: `scripts/checks/python.sh:19`

```bash
if [[ -f pyproject.toml ]] && grep -q "\[tool.mypy\]" pyproject.toml 2>/dev/null; then
  run_stage typecheck "mypy" "mypy" "python: mypy" mypy .
fi
```

同じファイルの他判定(`:14` ruff-format、`:36` deptry、`:46` vulture、`:58-59` import-linter)は `^\[tool\.xxx` の形で行頭アンカーとドットのエスケープを施しているが、mypy だけ両方欠ける。`[tool.mypy]` という文字列が `[project]` の `description` 等、実際のセクション宣言ではない場所に現れただけで検出が成立し、`mypy` には ruff-format/deptry/vulture のような WARN フォールバック(`run_stage_soft`)が無いため、誤検出がそのまま完了ブロックの `FAIL` に直結する。`scripts/README.ja.md:71` は `mypy`(宣言時) と明記しており、文書の契約(実際の宣言がある場合だけ)が実装で部分的に破られている。

再現(実測、隔離プロジェクト):

```
$ cat pyproject.toml
[project]
description = "Type-checked with [tool.mypy] settings inherited from base config"
[tool.ruff]
line-length = 100

$ check.sh .
FAIL  python: mypy
bad.py:3: error: Incompatible return value type (got "int", expected "str")  [return-value]
```

対照(`[tool.mypy]` という文字列を含めない同型の `pyproject.toml`)では mypy が起動しないことを確認済み。

修正案: `grep -q "^\[tool\.mypy\]" pyproject.toml` へ1行直す(他の判定と同形式に揃えるだけ)。

### 未確認の疑い

なし。上記5件はいずれも隔離プロジェクトで実行して再現を確認した。

## 8. ドキュメントと実装の整合性

- `scripts/README.ja.md:71` の `mypy`(宣言時) は §7-⑤ の誤検出によって部分的に破られている。文書の記述自体は正しく、実装がそこへ追いついていない。
- `report` の「close・統合」節はドキュメント上「close/retire したエントリを振り返りに出す」ことが前提だが、§7-① の欠陥がある間はこの前提が成立しないケースがある(ドキュメントの誤りではなく実装側のギャップ)。
- ESLint の設定ファイル検出範囲は README・`docs/configuration*.md` のいずれにも具体的な列挙が無いため、§7-③ は文書との不整合ではなく実装内の非対称(PostToolUse と Stop の判定基準が違う)として扱った。
- 前回(2026-08-30)に修正されたドキュメント整合性項目は、当該コミット(`34857eb`)の diff とテスト(`tests/test_doc_inventory.sh`)を読み、実装と一致していることを確認した。
- git tag(`v0.1.11`)・`plugin.json`(Claude/Codex とも `0.1.11`)は一致している。

---

## 付録: 再現手順(隔離プロジェクト、本リポジトリの `.feedback/` は不使用)

```bash
# 前回指摘②の解消確認(date.min 境界)
WORK=$(mktemp -d); git init -q "$WORK"; export CLAUDE_PROJECT_DIR="$WORK"
bash scripts/feedback.sh stats --days 1000000000
# → ERROR: --days に指定できる最大は 739860 です … (exit 1、traceback なし)
bash -c '. scripts/lib.sh; harness_log_event "$CLAUDE_PROJECT_DIR" post_edit pass x.py'
bash scripts/feedback.sh report --since 0001-01-01     # 正常終了(exit 0)

# ①status_changed 誤爆・本文破壊
WORK=$(mktemp -d); git init -q "$WORK"; export CLAUDE_PROJECT_DIR="$WORK"
bash <repo>/scripts/feedback.sh add --category workflow --summary "frontmatter note" \
  --detail "old broken template had a stray status_changed: 2020-01-01 line in it"
ID=<印字されたid>
bash <repo>/scripts/feedback.sh close "$ID" --reason "not generalizable"
cat "$WORK"/.feedback/log/*.md          # status_changed: が frontmatter に無く、本文の日付が書き換わっている
bash <repo>/scripts/feedback.sh report --since 2026-08-01   # close・統合節に出てこない

# ②promote二重実行
WORK=$(mktemp -d); git init -q "$WORK"; export CLAUDE_PROJECT_DIR="$WORK"
ID=$(bash <repo>/scripts/feedback.sh add --category style --summary "dup rule test" --detail x | grep -oE 'id=[^)]+' | cut -d= -f2)
bash <repo>/scripts/feedback.sh promote "$ID" --rule "rule A"
bash <repo>/scripts/feedback.sh promote "$ID" --rule "rule B"   # 2回目も成功
bash <repo>/scripts/feedback.sh retire "$ID" --reason cleanup   # ERROR: 出典が2件あります

# ③ESLint 設定ファイル検出漏れ
WORK=$(mktemp -d); git init -q "$WORK"; cd "$WORK"
cat > package.json <<'EOF'
{"name":"demo","type":"commonjs","scripts":{"lint":"eslint ."}}
EOF
cat > eslint.config.cjs <<'EOF'
module.exports = [{ rules: { "no-unused-vars": "error" } }];
EOF
printf 'const unused = 42;\nmodule.exports = {};\n' > bad.js
bash <repo>/scripts/check_file.sh "$WORK/bad.js"; echo "exit=$?"   # exit=0(見逃す)
bash <repo>/scripts/check.sh "$WORK"                               # FAIL node: npm run lint(捕まる)

# ④json-syntax の偽PASS
WORK=$(mktemp -d); git init -q "$WORK"; printf '{ invalid' > "$WORK/broken.json"
( cd "$WORK" && git add broken.json )
HARNESS_PYTHON=/nonexistent/python bash <repo>/scripts/check.sh "$WORK"
# → FAIL config: 設定エラー と同時に PASS config: json 構文 が出る(broken.json は未検証)

# ⑤mypy 誤検出
WORK=$(mktemp -d); cd "$WORK"; git init -q .
cat > pyproject.toml <<'EOF'
[project]
description = "Type-checked with [tool.mypy] settings inherited from base config"
[tool.ruff]
line-length = 100
EOF
printf 'def f(x: int) -> str:\n    return x\n' > bad.py
bash <repo>/scripts/check.sh "$WORK"     # FAIL python: mypy が出る
```

## 優先順位の提案

| 優先 | 項目 | 見積 |
|------|------|------|
| 1 | §7-① `updated_status_text` を frontmatter ブロック限定にする + 往復テスト | 小〜中 |
| 2 | §7-② `promote`/`merge` に状態ガードを追加 | 小 |
| 3 | §7-③ `check_file.sh` の ESLint 設定検出を prettier/knip と同じ網羅方式へ | 小〜中 |
| 4 | §7-④ `json-syntax`/`md-links` を `yaml-syntax` と同じ事前ゲート方式へ | 小 |
| 5 | §7-⑤ `checks/python.sh` の mypy 検出パターンを揃える(1行) | 小 |
| 6 | §5 監査・棚卸し「未実行」を SessionStart/Stop の要約へ出す | 小〜中 |

## 優先度集計

| 優先度 | 件数 | 前回(2026-08-28) | 変化 |
|---|---:|---:|---:|
| P1 | 1 | 0 | **+1**(新規: `updated_status_text` の frontmatter 誤爆・本文破壊) |
| P2 | 2 | 0 | +2(新規: promote/merge 状態ガード欠落、ESLint 設定検出漏れ) |
| P3 | 2 | 1 | +1(前回分は解消、新規2件と入れ替わり: json-syntax 偽PASS、mypy誤検出) |
| P4 | 0 | 1 | -1(前回分は解消) |

上表はレビュー時点(`951f783`)の件数。**改修ブランチではこの5件に加えて、改修中に検出した
ESLint 経路の2件(formatter の core 外れ・終了コードの一律扱い)も塞いでいる**(§0)。
いずれも「環境の問題をユーザーのコードの失敗として報告しない」という同じ契約に属し、
③の修正で ESLint が実際に起動するようになったことで初めて観測可能になった。
