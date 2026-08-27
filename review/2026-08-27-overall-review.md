# feedback-harness 全体レビュー(main)

- 対象: `main` = `ad5de82dd258a57c8c65821021bb82e9e595406c`(2026-08-27)
- 規模: shell 6,857 行 / Python 2,166 行 / Markdown 13,668 行、コミット 169 件(2026-08-09〜)
- テスト: `tests/run_tests.sh` 37 ファイル **全PASS**(内 1 件は開発用フック定義なしで SKIP)
- 自己検査: `bash scripts/check.sh` → **ALL PASS**(4件SKIP: shellcheck / actionlint / secretlint設定 / node_modules)
- CI: main 最新 run(Linux + Windows Git Bash)ともに success
- 蓄積状況: ログ 35 件 / ルール 22 件 / open 0 件

総評: **設計・実装・文書の水準は高い。** 特に「壊れ方から逆算した防御」と「その根拠を残す文化」は同種のツールの中でも突出している。一方で、**エージェントが日常的に書く入力(`---` を含む detail)で記録が静かに壊れる P1 欠陥が 1 件**あり、これは本ハーネスの中心機能(記録→昇華)を無効化する。以下、観点別に記す。

---

## 0. 改修状況(このブランチ)

本レポートの指摘は `claude/feedback-harness-fixes-dgnghz` で対応済み(`abbdeb9` ほか)。
各修正は欠陥を再注入して護欄テストが落ちることを確認している。

| 指摘 | 対応 | 護欄 |
|------|------|------|
| ①[P1] frontmatter 乗っ取り | 先頭ブロック限定の読み取りへ変更 | `tests/test_entry_frontmatter.sh` |
| ②[P2] Stop フックのループ防止 | 判定不能はブロックしない側へ倒し shell フォールバックを追加 | `tests/test_on_stop_skip.sh` |
| ③[P2] 日付の無検証 | `--since` / `.last-retro` をパースして復旧手順つきで案内 | `tests/test_date_args.sh` |
| ④[P3] 環境変数の無検証 | config と同じ規則で検証し同じ経路で報告(FAIL ラベルを出所中立へ) | `tests/test_config_wiring.sh` |
| ⑤[P3] ステージのタイムアウト無し | `check.stage_timeout_seconds` と `--stage-timeout` を追加、Stop は 240 秒、打ち切りは `TIMEOUT` | `tests/test_stage_timeout.sh` |
| ⑥[P3] テスト規約の乖離 | 捕捉21箇所を `tpy` へ移行し走査で禁止 | `tests/test_python_boundary.sh` |
| ⑦[P4] `exclude` の非対称 | 3言語の設定ガイドへ明記 | — |

改修中に新たに1件を検出し、その場で塞いだ: ステージを `timeout` で包む実装は
shell 関数(`harness_validate_json` 等)を渡すと 127 になり、`run_stage` の
「実行不可」判定で**横断検査が黙って SKIP へ落ちる**。外部コマンドのときだけ
包むよう限定し、`tests/test_stage_timeout.sh` が固定している。

拡張案(§6)は未着手で、レポートの記載のまま残している。

---

## 1. 実装品質

**強い点**

- 共有判断の一元化が徹底している。`has()` / `harness_python` / `harness_node_pm` / `harness_config.py` と、「経路ごとに書き足さない」原則が実際にコードへ落ちている(`scripts/lib.sh:1-40`)。
- 設定パーサを自前実装しつつ、**未対応記法を黙って無視せず行番号付きで落とす**(`scripts/harness_config.py:47-137`)。「書いたのに効かない」を最悪の失敗モードと位置づけた設計判断が一貫している。
- 状態更新が journal + roll-forward の transaction になっており(`scripts/feedback_store.py:330-360`)、`os.link` 非対応 FS のフォールバック、Windows の `msvcrt.locking` 1バイト確保まで手当てされている。
- コメントが「何をしているか」でなく「なぜこの形か / どう壊れたか」を書いている。実測値(英語 0.16 / 中国語 0.10 の bigram 類似度、Python 起動 7→4 回)まで残っており、レビュー可能性が高い。

**弱い点**

- Python 側の**入力境界の検証が場所によって不揃い**。config は厳格に検証する一方、CLI 引数(`--since`)と外部状態(`.last-retro`)は無検証で、同一ファイル内で `audit_status_lines()` は `ValueError` を握るのに `resolve_report_since()` は握らない(§7-③)。
- `feedback_log.py` は 1,020 行の単一モジュールで、CLI 定義・集計・rules.md 編集・エントリ解析が同居している。`parse_entry` のような**フォーマット契約の中心**がテスト観点から見えにくくなっている(実際 §7-① はそこに残っていた)。
- shell 側の関数群は `set -u` のみで `set -e` を使わない方針だが、`check.sh` の `RESULTS+=` 集約と暗黙の大域変数(`STACK_FOUND` / `LOGDIR` / `LIST_MODE`)を stack runner が共有しており、runner 追加時の暗黙依存が多い。

## 2. 実用性

**効いている設計**

- **未導入ツールは SKIP**、設定宣言があるものだけ FAIL、という導入初日の摩擦を潰す契約。`ALL PASS (4件SKIP)` のように未検証件数を必ず添えるため、「検査したつもり」になりにくい。
- Stop フックの**変更検知スキップ**(`harness_tree_changed`)。質問応答だけのターンで重いビルドが回らない。判定不能時は必ず「実行する」側に倒す設計も妥当。
- 個人設定レイヤ `.feedback/local/config.yaml` と出所表示(`SKIP node: … (個人設定: check.skip)`)。チーム設定を汚さずに手元の事情を反映でき、かつ「チーム設定を読んでも理由が見つからない」を防いでいる。
- Windows Git Bash 対応が CI で実証されている(job env に UTF-8 を置かない=利用者環境を検証する、という判断まで含めて)。

**摩擦が残る点**

- **ステージ単位のタイムアウトが無い**(§7-⑤)。`mvn verify` や重い `npm run build` を持つ導入先では、Stop フックの 300 秒制限に当たった時点でプロセスが落とされ、失敗内容がエージェントに戻らないまま毎ターン再実行される。
- 計測が**マシンローカル**。`.feedback/events.jsonl` は `.gitignore` 済みで、初回通過率はチーム合算できない。「フィードバックフライホイールの計測」を掲げる以上、ここは実用上の天井になる。
- 実行時出力・スキル・エージェント定義が**日本語のみ**。README は 3 言語あるため、英語・中国語の利用者は導入直後に日本語の検査結果を読むことになる。

## 3. 機能性

| 領域 | 実装状況 |
|------|----------|
| 自動検査 | 8ステージ(lint / typecheck / test / build / format / security / docs / contract)、41 検査ID |
| スタック | Python / Node / Go / Rust / Java(Maven はモジュール別派生ID) / Shell + 横断(JSON・YAML・md リンク・secretlint・gitleaks・actionlint・Dockerfile) |
| 契約差分 | OpenAPI(oasdiff)・Rust(cargo-semver-checks)。いずれも git 由来のベースラインでネットワーク不使用 |
| 監査 | `audit.sh` を Stop フックの外に分離(pip-audit / npm audit / govulncheck / cargo audit)、最終監査日を stats/report に表示 |
| 蓄積 | add / list / search / promote / merge / close / retire / rules |
| 計測 | PostToolUse 初回通過率、Stop 初回通過率、頻出WARN・失敗上位(鮮度注記つき)、再発候補の列挙 |
| 設定 | 3層 + 環境変数、`--list-checks` で実効値と出所を可視化 |
| 配布 | Claude Code プラグイン / Codex プラグイン / `init.sh`(汎用エージェント向け実ファイル配布) |

機能の**穴として目立つのは 3 点**:退役(`retire`)まで含む蓄積ライフサイクルは閉じているのに、(a) 計測が共有されない、(b) `check.sh` の結果を機械可読で出す口が `--list-checks --json` しかない(CI から使えない)、(c) Gradle はマルチモジュール派生IDを持たない(Maven のみ対応)。

## 4. よくできたこと

1. **「テストがある」を根拠にしない文化がテストの形に落ちている。** `test_skill_paths.sh` / `test_env_var_docs.sh` は列挙ではなく**走査**で書き漏れを捕まえ、期待集合をコード(`harness_config.py` の上書き口)から導出している。同種の防御が「レビューでしか気づけない抜け」を実際に塞いでいる。
2. **失敗の握り潰しと記録の消失を切り分けた。** `_harness_append_event` は Python 経路が落ちたら shell から追記する。「件数が減る」ではなく「合格率が上がって見える」形の壊れ方を名指しして対処している(`scripts/lib.sh:355-375`)。
3. **意味判断を機械的しきい値で先取りしない、という撤回判断。** bigram 類似度によるフィルタを実測(英語 0.16 / 中国語 0.10)を根拠に撤去し、CLI は列挙に徹してエージェントが本文を読む契約へ戻した。実装を足す方向でなく削る方向の判断ができている。
4. **Windows 対応の担保を CI の job env でなく配布コードへ置いた。** `_harness_python_exec` が UTF-8 を指定し、CI からは意図的に外して非設定をテストで固定している。「CI だけが緑」を構造的に防いでいる。
5. **3言語文書の同期が機械的に固定されている。** 見出し数 33/33/33、configuration の表行数 37/37/37、検査ID 41 件は 3 言語すべてに登場する(本レビューで実測)。

## 5. 改善できること

- **入力境界の検証を config と同じ厳しさへ揃える。**(§7-①③④)特に「打ち間違いを黙って無視しない」原則が、config には適用され環境変数と CLI 引数には適用されていない。
- **`feedback_log.py` の分割。** エントリのシリアライズ/デシリアライズ(frontmatter 契約)を独立モジュールへ出し、往復テスト(`add` した内容が `parse_entry` で同一に戻る)を置く。§7-① はこの往復テストがあれば書けなかった。
- **Stop フックの所要時間を記録する。** 現在 events.jsonl は合否のみ。ステージ別の所要時間を持てば、タイムアウト設計とスキップ最適化の効果を数字で議論できる。
- **OSS 運用の基礎整備。** git tag 0 件でプラグインは 0.1.9、`CONTRIBUTING.md` / `SECURITY.md` / Issue・PR テンプレート / dependabot が未整備。マーケットプレイス配布物としてはバージョンと配布実体の対応が追跡できない。
- **`review/` と `docs/superpowers/` の位置づけ整理。** プラグイン導入時にはリポジトリ全体が配られるため、内部作業成果物も利用者へ届く。`_workspace/`(gitignore 済み)との使い分けを明文化したい。

## 6. 機能性・実用性の拡張余地

優先度順(効果 ÷ コスト):

1. **SessionStart フックで rules.md を文脈へ注入する。** 現状 `on_session_start.sh` は `.feedback/` を作るだけで stdout に何も出さない(`scripts/hooks/on_session_start.sh:28`)。Claude Code の SessionStart は追加文脈を返せるため、`rules.md` と open エントリの要約をそのまま返せば、`apply-feedback` スキルの起動漏れに依存せず**必ず**ルールが効く。ハーネスの中心価値に最短で効く拡張。
2. **チーム合算の計測。** `events.jsonl` はローカルのまま、`stats --export` で匿名化済みの日次サマリ(初回通過率・上位WARN)だけを共有ファイルへ書き出す。個人のファイル名を共有せずに指標だけ合算できる。
3. **`check.sh --json`(結果版)。** `--list-checks --json` と同じ形式で PASS/FAIL/SKIP/所要時間を出し、CI から同じ検査を回して PR コメントへ載せられるようにする。ローカルと CI で検査定義が二重管理になる問題も同時に解ける。
4. **ステージ単位のタイムアウトと部分結果。** `timeout` で各ステージを打ち切り、`TIMEOUT` を新しい判定として扱う(FAIL とは別枠)。300 秒制限に当たっても「どのステージが遅いか」がエージェントに返る。
5. **スタック拡張。** .NET(`dotnet format` / `dotnet test`)、Ruby(rubocop / rspec)、Terraform(`terraform validate` / tflint)、Gradle マルチモジュールの派生ID。既存の runner 構造(`scripts/checks/*.sh`)にそのまま乗る。
6. **rules.md のスコープ化。** ルールが 22 件に達し、今後も単調増加する。`scope: python` `path: scripts/**` のような適用範囲メタデータを持たせ、`apply-feedback` が作業対象に応じて絞り込めるようにする(文脈コストの上限管理)。
7. **実行時メッセージの多言語化。** 出力文字列をカタログ化し `HARNESS_LANG` で切り替える。3 言語 README がある以上、次の自然な一歩。

## 7. 不具合検知

各項目は**実際に再現**して確認した(再現手順は付録)。

### ① [P1] エントリ本文の `---` で frontmatter が乗っ取られ、記録が addressable でなくなる

対象: `scripts/feedback_log.py:363-375`(`parse_entry`)

`parse_entry` は `---` 行を見るたびに frontmatter モードを反転する。そのため本文中の水平線以降に `key: value` 形式の行があると、**そのエントリのメタデータとして解釈される**。エージェントが detail に区切り線と箇条書きを書くのは日常的な形式であり、事故は容易に起きる。

再現(実測):

```
$ feedback.sh add --category style --summary "id乗っ取り" --detail $'メモ\n---\nid: 99999999'
recorded: .feedback/log/20260827-152509-id乗っ取り.md (id=20260827-152509)

$ feedback.sh list --status all
[open    ] 99999999  style        id乗っ取り        ← CLI が印字した id と別物になる

$ feedback.sh promote 20260827-152509 --rule "…"
ERROR: id=20260827-152509 のエントリが見つかりません
```

`status` / `category` / `signal` も同様に上書きでき、`open` で記録したエントリが `closed` として一覧に出る状態を確認した。影響は「記録が消える」ではなく「**記録したはずのものが昇華できない/別状態に見える**」であり、本ハーネスが最も警戒してきた静かな壊れ方に該当する。

修正案: frontmatter は**先頭ブロックに限定**する(1行目が `---` のときだけ開始し、次の `---` で確定終了。以降は無条件に body)。`cmd_add` 側で detail 中の `---` をエスケープする案は既存エントリを救えないため、読み取り側の修正が本筋。あわせて `add` → `parse_entry` の往復テスト(id / status / category / body が保存される)を追加する。

### ② [P2] Python 不在時に Stop フックの無限ループ防止が無効化する

対象: `scripts/hooks/on_stop.sh:28-47`

`stop_hook_active` の判定を `harness_python` に依存しているため、Python 3.10+ が解決できない環境では `ACTIVE` が空文字になり、**2周目以降もブロックする**。

再現(実測):

```
$ echo '{"stop_hook_active": true}' | HARNESS_PYTHON=/nonexistent/python on_stop.sh ; echo $?
2          ← 期待は 0(ループ防止で素通し)
$ echo '{"stop_hook_active": true}' | on_stop.sh ; echo $?
0
```

check.sh は bash 主体で Python 不在でも動く(bash -n / shellcheck / ruff 等)ため、失敗が残っている限り Stop → 修正試行 → Stop … が続きうる。ハーネス自身の「判定できないときは安全側に倒す」原則(`harness_tree_changed` のコメント)に照らすと、ここでの安全側は「**ブロックしない**」側である。

修正案: Python が使えないときは `grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'` の shell フォールバックで判定するか、判定不能を `true`(=ブロックしない)扱いにする。どちらでも 1 行の変更で済む。

### ③ [P2] `--since` / `.last-retro` が無検証で、静かに空のレポートまたは traceback になる

対象: `scripts/feedback_log.py:189-194`(`resolve_since`)、`802-810`(`resolve_report_since`)、`908`

- `report --since 2026/08/01`(区切り違い)は**エラーにならず**、日付が文字列比較されるため全項目が空のレポートになる。振り返りの議題を作る用途で「何も起きていない期間」に見える。
- `stats --since notadate` も同様で、ヘッダに `notadate 以降` と印字したまま集計 0 件になる。
- `.last-retro` が空/不正な内容だと `report --last` が `ValueError: Invalid isoformat string: ''` で traceback(`:908`)。同ファイルの `audit_status_lines()` / `retro_status_lines()` は同じ状況を try/except で処理しており、堅牢性が不揃い。

再現(実測): 上記 3 ケースすべてを確認。

修正案: `datetime.date.fromisoformat()` で一度パースして受け付ける(`yesterday` は先に解決)。`.last-retro` は不正なら「基点が壊れています。`--since` を指定するか `--mark` で作り直してください」と復旧手順つきで終了する。

### ④ [P3] 環境変数の上書きだけスキーマ検証を通らない

対象: `scripts/harness_config.py:553-562`

config の `check.skip: [tests]`(綴り誤り)は行番号付きでエラーになるのに、`FEEDBACK_CHECK_SKIP=tests` は**沈黙して無視**される。逆に `FEEDBACK_SHELLCHECK_SEVERITY=bogus` は検証されずそのまま `shellcheck -S bogus` へ渡り、利用者のコードの失敗として報告される。

再現(実測): `FEEDBACK_CHECK_SKIP=tests bash check.sh --list-checks` は無反応、`harness_config.py --json` は `['bogus', 'env.FEEDBACK_SHELLCHECK_SEVERITY']` を返す。

修正案: `resolve()` の環境変数適用時に、ステージ名は `STAGES`、パラメータは `CHECK_PARAMS` の型・列挙で検証し、外れていれば `error`(既存の `HARNESS_CONFIG_ERROR` 経路)へ載せる。config と同じ扱いに揃うだけで実装は既存関数の再利用で済む。

### ⑤ [P3] ステージ単位のタイムアウトが無く、フック制限超過が「無音の打ち切り」になる

対象: `scripts/check.sh:143-171`、`hooks/hooks.json`(Stop の timeout 300)

`run_stage` は外部コマンドを無制限に待つ。Stop フックが 300 秒で打ち切られると、失敗内容もタイムアウトの事実もエージェントに渡らず、スタンプも更新されないため次ターンで同じ検査が再実行される。重い導入先ほど当たりやすい。

修正案: `timeout` があれば各ステージを包み(既定は Stop の制限より短く)、打ち切りを `TIMEOUT` として別枠で報告する。`timeout` 不在環境では従来動作へフォールバック。

### ⑥ [P3] テスト規約の実装漏れ(CLAUDE.md のルールとテストの実態が乖離)

対象: `tests/test_audit.sh` / `test_config.sh` / `test_oss_baseline.sh` / `test_plugin_manifest.sh` / `test_report.sh` / `test_stats.sh`(計 21 箇所)

CLAUDE.md は「テスト内で起動する Python の出力を比較に使うなら `harness_python` を通す。素の `python3` は正規化を通らず Windows では CR が混ざる」と定めているが、実際に移行済みなのは `test_env_var_docs.sh` のみで、**21 箇所は素の `$(python3 …)` 比較のまま**。Windows CI は緑であるため、少なくとも「Windows の Python は常に CRLF を書く」という前提はこの経路では成立していない。

対応の選択肢は 2 つで、どちらかに寄せるべき(現状はルールと実装のどちらが正か読み手が判断できない):
- ルールが正 → 21 箇所を `harness_python` 経由へ移行し、`tests/` を走査する護欄を追加する。
- 実態が正 → CLAUDE.md の記述を「CR が混ざったのは○○の経路」と具体化して範囲を狭める。

### ⑦ [P4] `exclude` の効き方が PostToolUse と Stop で非対称

対象: `scripts/check_file.sh:58-62`、`scripts/checks/python.sh:11`

`check.exclude` は文書どおり「ハーネスが列挙する検査」にのみ効く(`docs/configuration.md:131` に明記)。一方 `check_file.sh` は**単発ファイルなら常に** exclude を適用するため、`vendor/**` を除外した状態で `vendor/bad.py` を編集すると PostToolUse は素通し、Stop の `ruff check .` はブロック、という挙動になる(実測)。仕様どおりだが、CLAUDE.md が繰り返し警戒してきた「フックとフルチェックの食い違い」そのものの形。文書の「効く範囲」の節に、この非対称を1行足しておくのが安価な対応。

## 8. ドキュメントと実装の整合性

**総じて非常に高い。** 実測した整合点:

| 検証項目 | 結果 |
|----------|------|
| 3言語 README の見出し数 | 33 / 33 / 33 一致 |
| `docs/configuration*.md` の見出し・表行数 | 21 / 37 で 3 言語一致 |
| 検査ID(コード 41 件)の 3 言語文書への登場 | 欠落 0 |
| プラグインバージョン(Claude / Codex) | 0.1.9 で一致 |
| `hooks/hooks.json` の参照先スクリプト実在 | テストで固定済み |
| 環境変数一覧(6 README) | コードから期待集合を導出するテストで固定済み |
| 根因 5 分類の複製箇所 | 整合テストあり(README 翻訳版含む) |

**乖離が残る箇所**は 2 件のみ:

1. §7-⑥ のテスト規約(CLAUDE.md の規約 ⇄ tests の実態)。
2. §7-⑦ の `exclude` 非対称(文書は「効く範囲」を説明しているが、`check_file.sh` 側の常時適用には触れていない)。

なお `CLAUDE.md` の変更履歴・設計メモは、**その記述を裏づけるテストが実在するか**を今回サンプリングした範囲では全件確認できた(再帰ガード、PM 判定、shim 混入、transaction 回復、`report --mark` の読み取り専用分類の是正)。文書が実装より先行して「できていることにする」型の乖離は見つからなかった。

---

## 付録: 再現手順

```bash
# ① frontmatter 乗っ取り
export CLAUDE_PROJECT_DIR=/tmp/proj && mkdir -p "$CLAUDE_PROJECT_DIR" && cd "$CLAUDE_PROJECT_DIR" && git init -q .
bash scripts/feedback.sh add --category style --summary "id乗っ取り" --detail $'メモ\n---\nid: 99999999'
bash scripts/feedback.sh list --status all      # id が 99999999 になる
bash scripts/feedback.sh promote <印字されたid> --rule x   # 見つかりません

# ② Stop フックのループ防止
echo '{"stop_hook_active": true}' | HARNESS_PYTHON=/nonexistent/python bash scripts/hooks/on_stop.sh; echo $?   # 2

# ③ 日付の無検証
bash scripts/feedback.sh report --since 2026/08/01     # 全項目が空
: > .feedback/.last-retro && bash scripts/feedback.sh report --last   # traceback

# ④ 環境変数の無検証
FEEDBACK_CHECK_SKIP=tests bash scripts/check.sh --list-checks          # 沈黙
FEEDBACK_SHELLCHECK_SEVERITY=bogus python3 scripts/harness_config.py --json .   # bogus が通る
```

## 優先順位の提案

| 優先 | 項目 | 見積 |
|------|------|------|
| 1 | §7-① frontmatter を先頭ブロック限定にする + 往復テスト | 小 |
| 2 | §7-② Stop フックのループ防止に shell フォールバック | 小 |
| 3 | §7-③ 日付の検証と `.last-retro` の復旧案内 | 小 |
| 4 | §6-1 SessionStart で rules.md を文脈へ注入 | 中(効果大) |
| 5 | §7-④ 環境変数のスキーマ検証 | 小 |
| 6 | §7-⑥ テスト規約の是正(どちらかに寄せる) | 小〜中 |
| 7 | §7-⑤ ステージタイムアウト / §6-3 `check.sh --json` | 中 |
