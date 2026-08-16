# feedback-harness

## ハーネス: フィードバックループ

**目標:** エージェントへの自動フィードバック(Hooks経由のlint/test/build)と、人間のレビュー指摘の蓄積・ルール化を全プロジェクトで再利用可能にする。

**トリガー:**
- 実装作業の開始前は `apply-feedback` スキルで `.feedback/rules.md` を反映せよ
- 人間から指摘・修正を受けたら、また次回も再現したい成功パターンに気づいたら `capture-feedback` スキルで記録せよ
- 作業を完了する前に1問自省せよ — このセッションで共有アーティファクト(`.feedback/rules.md`・CLAUDE.md・スキル)を変えるべき出来事はあったか。あれば `capture-feedback` で記録してから完了する(答えは大抵ノーでよい)
- フィードバックの整理・ルール昇華・ハーネス点検・他プロジェクトへの導入は `feedback-loop` スキルを使用せよ
- 単純な質問には直接回答してよい

**自動チェック:** Hooks(`.claude/settings.json`)が編集直後のファイルlint(PostToolUse)と完了前のフルチェック(Stop)を自動実行する。失敗内容は自動でフィードバックされるため、修正してから完了とすること。

**スクリプト設計メモ:**
- フック実行時に export された環境変数(CLAUDE_PROJECT_DIR 等)は make・テスト経由の子孫プロセスすべてに伝播する。スクリプトが環境変数でルート解決する場合、ネスト呼び出しでの再帰を前提にガードを入れること(FEEDBACK_CHECK_RECURSION_GUARD が参考実装 — 2026-08-16 の無限再帰修正由来)。

**変更履歴:**
| 日付 | 変更内容 | 対象 | 理由 |
|------|----------|------|------|
| 2026-08-09 | 初期構成 | 全体 | - |
| 2026-08-10 | QAレポート(FAIL 10件)対応 | check.sh / install.sh / hooks / feedback_log.py | SKIP契約の実装、壊れたツールの誤FAIL防止、ハーネス自己検査、導入品質 |
| 2026-08-10 | 再QA(新規10件)対応 | lib.sh(新規) / check_file.sh / check.sh / AGENTS.md | has()の共通化でドリフト防止、PyYAML未導入時の誤ブロック解消、未追跡ファイルの検査、shellcheck重大度しきい値 |
| 2026-08-10 | 実環境テストで発見した蓄積ループの不具合を修正 | feedback_log.py / feedback-curator.md / capture-feedback | 同一秒のID衝突で昇華不能になる問題、および作業原則4・5(統合・close)がCLIで実行不能だった問題 |
| 2026-08-12 | プラグイン化 | .claude-plugin / hooks / skills / agents / scripts / tests | 他リポジトリへ配布可能にし、コピー方式のドリフトを解消 |
| 2026-08-12 | Feedback Flywheel(Fowler記事)照合 Step 1 | skills / docs / AGENTS.md / on_stop.sh / CLAUDE.md | openエントリの死蔵防止、セッション後自省の錨定、成功パターン捕獲、失敗根因の記録、hook失敗の再発シグナル化 |
| 2026-08-12 | Feedback Flywheel 照合 Step 2 | agents/feedback-curator.md / skills/feedback-loop | 根因→昇華先マッピング(rules.md一極集中の解消)、再発を「ルールが効いていない」シグナルとして文言強化 |
| 2026-08-12 | Feedback Flywheel 照合 Step 3 | feedback_log.py / skills/feedback-loop / tests / README | retire でルールの退役出口を追加、棚卸しPhase(定期審査)で陳腐化を負債化させない |
| 2026-08-12 | Stopフックの過剰実行を解消 | lib.sh / on_stop.sh / tests / README | 変更が無いターンでもフルチェックが走り、導入先の重いビルドが毎回動く問題。2周目の無意味な再実行も除去 |
| 2026-08-12 | 全体検証と不具合修正 | lib.sh / feedback-loop / init.sh / test_skill_paths / plugin.json | 削除を検出できず検査が飛ぶ穴、プラグイン導入時に解決できない `scripts/init.sh` 参照、導入先での検査スタンプ追跡、バージョン据え置き |
| 2026-08-16 | Stopフックの無限再帰を修正 | check.sh / tests/test_recursion_guard.sh / README | フック由来の `CLAUDE_PROJECT_DIR` が子孫に伝播し、make check → テスト → check.sh が循環して timeout 300 を食い潰す問題を、make再帰ガードで断った |
| 2026-08-16 | Flywheel Step 4(信号種・測定・報告) | feedback_log.py / hooks / lib.sh / rules.template / skills / tests | 信号4分類のデータ化、フック合否からの初回通過率測定、朝会・振り返り議題の report、再発候補の機械化 |
| 2026-08-16 | 適用範囲拡張 P1(基盤と既存欠陥) | lib.sh / check_file.sh / check.sh / on_stop.sh / feedback_log.py / tests | JSONC・複数文書YAMLの誤ブロック解消、設定ファイル構文の横断検査、非ブロッキングWARNとその測定連携 |
