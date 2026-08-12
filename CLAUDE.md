# feedback-harness

## ハーネス: フィードバックループ

**目標:** エージェントへの自動フィードバック(Hooks経由のlint/test/build)と、人間のレビュー指摘の蓄積・ルール化を全プロジェクトで再利用可能にする。

**トリガー:**
- 実装作業の開始前は `apply-feedback` スキルで `.feedback/rules.md` を反映せよ
- 人間から指摘・修正を受けたら `capture-feedback` スキルで記録せよ
- フィードバックの整理・ルール昇華・ハーネス点検・他プロジェクトへの導入は `feedback-loop` スキルを使用せよ
- 単純な質問には直接回答してよい

**自動チェック:** Hooks(`.claude/settings.json`)が編集直後のファイルlint(PostToolUse)と完了前のフルチェック(Stop)を自動実行する。失敗内容は自動でフィードバックされるため、修正してから完了とすること。

**変更履歴:**
| 日付 | 変更内容 | 対象 | 理由 |
|------|----------|------|------|
| 2026-08-09 | 初期構成 | 全体 | - |
| 2026-08-10 | QAレポート(FAIL 10件)対応 | check.sh / install.sh / hooks / feedback_log.py | SKIP契約の実装、壊れたツールの誤FAIL防止、ハーネス自己検査、導入品質 |
| 2026-08-10 | 再QA(新規10件)対応 | lib.sh(新規) / check_file.sh / check.sh / AGENTS.md | has()の共通化でドリフト防止、PyYAML未導入時の誤ブロック解消、未追跡ファイルの検査、shellcheck重大度しきい値 |
| 2026-08-10 | 実環境テストで発見した蓄積ループの不具合を修正 | feedback_log.py / feedback-curator.md / capture-feedback | 同一秒のID衝突で昇華不能になる問題、および作業原則4・5(統合・close)がCLIで実行不能だった問題 |
