# 開発ガイド

このプロジェクトは、編集時・完了時の自動チェックと、人間のレビュー指摘の蓄積・ルール化を他のプロジェクトでも再利用するためのハーネスである。

社内公開して他プロジェクトへ導入することを前提とする。利用者向けの契約を変更するときは、プラグインと `init.sh` 単独導入の両経路で必要な指示が届くか確認する。このリポジトリ固有の開発規約をそのまま配布せず、導入先の既存規約と文書の役割を尊重する。

必須の開発規約は [AGENTS.md](../AGENTS.md) にある。このガイドは、スクリプト・検査・スキルを変更するときに、その制約の背景と具体例を調べるために読む。過去の変更内容は [開発履歴](history/development-history.md)、利用方法は [プロジェクト概要](../README.ja.md)、設定と終了コードは [設定ガイド](configuration.ja.md)・[スクリプト仕様](../scripts/README.ja.md) を参照する。

## 共通規約の移行対応表

旧項目は `34627b3a38cff7dec761d92f647c260471e5f99e` の CLAUDE.md「スクリプト設計メモ」順。[移行計画](proposals/2026-09-06-shared-agent-instructions.md) の C01〜C29 と対応し、各リンクが必須制約の実際の移行先を示す。旧 AGENTS.md §1〜5 は正本の同じ節に保持した。CLAUDE.md の目標は本書冒頭、トリガーは正本冒頭、自動チェックの共通条件は正本§2〜3、環境固有の設定は CLAUDE.md、変更履歴の全行は開発履歴へ移した。

| 旧項目 → 必須制約 | 背景・実装例・関連する検証 |
|---|---|
| [C01](../AGENTS.md#c01) | フックの `CLAUDE_PROJECT_DIR` は make・テストへ伝播する。2026-08-16 には `make check → tests → check.sh` が循環した。`FEEDBACK_CHECK_RECURSION_GUARD` が再帰を断つ実装例。 |
| [C02](../AGENTS.md#c02) | 2026-08-19 に、隔離プロジェクトではなく本リポジトリの `.feedback/` を読み書きする事故が2件あった。ランナーによるフック変数の除去と、意図的に残す再帰ガードは [run_tests.sh](../tests/run_tests.sh) にまとまっている。 |
| [C03](../AGENTS.md#c03) | 根因5分類の定義が配布物間でずれた経緯がある。[根因整合テスト](../tests/test_root_cause_consistency.sh) が CLI と文書の語彙を照合する。 |
| [C04](../AGENTS.md#c04) | Codex のスキル本文では `CLAUDE_PLUGIN_ROOT` が設定されず、Hooks の互換変数とは条件が異なる。`PLUGIN_ROOT` を先に使う呼出し形式は [スキル経路テスト](../tests/test_skill_paths.sh) で検査する。 |
| [C05](../AGENTS.md#c05) | マーケットプレイス経由の更新は既存導入へ届く条件の確認が必要。`init.sh` の `update_pointer` は管理マーカー内を置換し、マーカーのない旧ポインタも見出しから移行する。末尾を特定できない場合は手動整理を促して停止する。配布用ポインタにも反映先選択・提案形式を含め、既存の再実行経路で届ける。 |
| [C06](../AGENTS.md#c06) | 再発候補の類似度は、無関係な英文同士で0.16、同主題の中国語で0.10という分布だった。候補の順序付けには使えても、共通のしきい値で関連性を判定すると言語による取りこぼしが生じた。 |
| [C07](../AGENTS.md#c07) | 2026-08-22 の QA 6件中4件は「緑だがアサーションが本番入力に触れていない」型だった。走査対象と本番の writer・フックの入力を照合し、欠陥再注入が実際に不合格になることまで確認する理由である。 |
| [C08](../AGENTS.md#c08) | `_harness_python_exec` の `PYTHONUTF8` / `PYTHONIOENCODING` は配布側の担保。CI の job env だけに設定すると、本体の防御が消えても利用者と違う環境で緑のままになる。 |
| [C09](../AGENTS.md#c09) | 先頭 `/` だけでパスとみなす変換は、CLI が受け取る自由テキストを静かに書き換えた。入力の見た目と実体を区別する必要がある。 |
| [C10](../AGENTS.md#c10) | Windows Python の stdout は実際に `true\r\n` を返した。`create_stdio()` に関する記憶から CR 除去を外す判断は CI に否定された。[Python 境界テスト](../tests/test_python_boundary.sh) は、低レベル境界テスト2本を除く通常テストの起動経路を走査し、前置代入・関数経由・解決済み interpreter の直接起動も再注入で検証する。 |
| [C11](../AGENTS.md#c11) | PR #13 の `HARNESS_PYTHON` は3言語全てで記載が抜けた。[環境変数文書テスト](../tests/test_env_var_docs.sh) は、config ローダーの上書き口と scripts が読む変数からローダーの出力変数を除いて期待集合を導出する。 |
| [C12](../AGENTS.md#c12) | Unix では shebang と実行ビットにより `.py` 直接実行が動いても、`python.exe` だけの Git Bash では `env: python3: No such file or directory` になる。skills だけ移行して curator が残った際、Windows の promote / add / list が全滅した。 |
| [C13](../AGENTS.md#c13) | `command -v` は `export -f` された shell function も解決する。`assert.sh` の `python3` shim が本番の `_harness_python_works` に選ばれ、Windows 経路の代わりにテストの足場だけを検証していた。解決側の `type -t` による実ファイル確認が混入を断つ。 |
| [C14](../AGENTS.md#c14) | `_harness_append_event` が代替記録の実装例。PR #17 では編集時の WARN が記録されず、lint 被覆ゼロでも初回通過率だけが上がった。`emit` から `harness_log_warn ... post_edit` へ記録し、`check_sev` で severity と検査IDをまとめた経緯は履歴にも保存している。 |
| [C15](../AGENTS.md#c15) | `_harness_python_resolve` の cache と `maven_check_id` の連番で同じ subshell の欠陥が起きた。呼出し側で値を受け取れても、子でのグローバル変数の更新は親へ戻らない。 |
| [C16](../AGENTS.md#c16) | 回復処理を全コマンドの入口に置くと、壊れた状態を調査するコマンドまで使えなくなる。復旧案内が必要な場面と、読取を継続できる場面を分ける背景である。 |
| [C17](../AGENTS.md#c17) | `FEEDBACK_CHECK_SKIP=tests` が黙って無視され、`--since 2026/08/01` が文字列比較で全件不一致となり、本文の `---` が frontmatter を再開して ID を上書きした。入口ごとの検証の違いが「記録したのに辿れない」結果を生んだ。 |
| [C18](../AGENTS.md#c18) | 外側の timeout で停止すると理由がエージェントに届かず、検査スタンプも進まず毎ターン再実行になる。`TIMEOUT` は「修正」以外の対処が必要であることを伝える結果種別。 |
| [C19](../AGENTS.md#c19) | `report --mark` は transaction で `.last-retro` を書く。コマンド名だけで読取扱いすると、壊れた journal を上書き・unlink して、確認するよう案内した当の記録を消していた。 |
| [C20](../AGENTS.md#c20) | PR #17 の `split_frontmatter` 集約以前は、読取だけを先頭ブロック限定へ直しても書込が全文を対象としていた。本文の `status_changed:` で日付が改変され、frontmatter に時刻が付かず report の close / retire 節から消える問題だった。 |
| [C21](../AGENTS.md#c21) | `close` だけが open を確認し、promote / merge が無確認だったため、二重 promote が同じ出典のルールを2件作り merge / retire を曖昧性エラーで不能にした。PR #17 の `require_open` が共通の状態ガード。 |
| [C22](../AGENTS.md#c22) | ガード共通化後も、merge / close に promote 用の retire 案内が返った。案内どおり実行するとルール本体が消え、出典全てが retired となり、目的の merge はなお失敗した。`_promoted_recovery` の verb 別分岐と呼出し側の走査が対策。 |
| [C23](../AGENTS.md#c23) | `RESULTS` を積まない `--list-checks` で `anything_detected` が常に false となり、secretlint の案内が一覧から消えた。`run_stage` / `record_skip` の入口で数える `RECORDED_CHECKS` は両モードの共通材料。 |
| [C24](../AGENTS.md#c24) | PR #17 では ESLint の違反（exit 1）と致命的エラー（exit 2）を区別した。設定形式や core から外れた formatter を指定した際のツールエラーが、編集したファイルの違反として返っていた。バージョン固有の挙動は変更時に対応版の実体を確認する。 |
| [C25](../AGENTS.md#c25) | ESLint 設定を4種だけ列挙した編集時チェックは `.eslintrc.cjs` などを飛ばし、同じ違反が Stop 側だけで出た。`harness_has_eslint_config` が glob による共通検出の実装例。 |
| [C26](../AGENTS.md#c26) | `harness_validate_json` / `harness_check_md_links` は Python 不在でも成功を返しうる。実行段階の前に Python を検出して `SKIP` とするゲートは、PyYAML のゲートと同じ考え方。C14 の計測上の誤合格とも関係する。 |
| [C27](../AGENTS.md#c27) | mypy の宣言ゲートはアンカーとドットのエスケープがなく、description 内の `[tool.mypy]` で起動した。護欄自身も `-q` / `-qE` / `-qF` だけを列挙し、`-qs` / `-q --` / 出力リダイレクトを見逃した。[宣言ゲートテスト](../tests/test_declaration_gates.sh) は実対象に触れる肯定形の確認も持つ。 |
| [C28](../AGENTS.md#c28) | 改修中の変異テストの後始末で `git checkout` を使い、未コミットの修正も消した。出典 `20260830-110231` に記録されている。 |
| [C29](../AGENTS.md#c29) | `tpy` が例外終了しても空出力となり、否定形のアサーションだけでは成功した。フック定義比較でも両側が死ぬと空文字同士で一致した。`unchecked_tpy_capture` の走査に加え、[文書一覧テスト](../tests/test_doc_inventory.sh) は `docs/README.md` と `scripts/README.md` を完全パスで区別する。 |

## 規約を更新するときのレビュー

共通の行動制約は AGENTS.md、前提知識・実装例はこのガイド、日付付きの経緯は開発履歴に置く。フィードバックの昇華・統合は `.feedback/rules.md` と既存 CLI の責務のまま維持する。導入先への追記案は [curator の選択契約](../agents/feedback-curator.md#document-targets) に従い、導入先の入口と参照文書の役割から選ぶ。

自動検査では、CLAUDE.md の正本参照、移行表から規約への到達、節の構造、反映案の出力項目を確認する。文章の意味や読取は別にレビューする。CLAUDE.md の既存の節の中に書かれた共通規約や、意味を変えた文言まで構造検査で防げるとは扱わない。

| 確認場面 | 本文を読んで確認する結果 |
|---|---|
| Codex / 汎用エージェントからテストを起動する | AGENTS.md の C02・C10 により、ランナーを通し、通常テスト内の Python は `tpy` を使う |
| Claude Code から同じ作業をする | CLAUDE.md の読取指示から AGENTS.md へ進み、同じ制約に従う |
| 前提知識の追記先を選ぶ | 導入先の両文書と参照先を読む。片方しかなくてもそれを入口にでき、二重追記や固定名の新設を前提にしない |
| 作業を完了する | どの入口でも正本§3の exit 0、WARN / SKIP の確認、振り返りへ到達する |

この表はレビューの観点であり、エージェントが実環境で読んだことの自動証明ではない。
