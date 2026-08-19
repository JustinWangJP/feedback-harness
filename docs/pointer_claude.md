## ハーネス: フィードバックループ

**目標:** エージェントへの自動フィードバック(Hooks経由のlint/test/build)と、人間のレビュー指摘の蓄積・ルール化をこのプロジェクトで回す。

**トリガー:**
- 実装作業の開始前は `apply-feedback` スキルで `.feedback/rules.md` を反映せよ
- 人間から指摘・修正を受けたら、また次回も再現したい成功パターンに気づいたら `capture-feedback` スキルで記録せよ
- 作業を完了する前に1問自省せよ — このセッションで共有アーティファクト(`.feedback/rules.md`・CLAUDE.md・スキル)を変えるべき出来事はあったか。あれば `capture-feedback` で記録してから完了する(答えは大抵ノーでよい)
- フィードバックの整理・ルール昇華・ハーネス点検・他プロジェクトへの導入は `feedback-loop` スキルを使用せよ
- 単純な質問には直接回答してよい

**自動チェック:** プラグインの `hooks/hooks.json` が、編集直後の単一ファイル検査（PostToolUse）と完了前のフルチェック（Stop）を自動実行する。失敗内容は自動でフィードバックされるため、修正してから完了とすること。

**変更履歴:**
| 日付 | 変更内容 | 対象 | 理由 |
|------|----------|------|------|
| {{INSTALL_DATE}} | フィードバックハーネス導入 | 全体 | - |

**ハーネス本体の更新:** Claude Code のスキル・エージェント・Hooks はプラグインが提供する。第三者マーケットプレイスは自動更新が既定で無効なので、`/plugin` → `Marketplaces` → `feedback-harness` で `Enable auto-update` を選んだ場合にのみ起動時に自動更新される。無効のまま更新する場合は `/plugin marketplace update feedback-harness` の後に `/plugin update feedback-harness@feedback-harness` を実行し、必要に応じて `/reload-plugins` する。`scripts/` を `init.sh` でベンダリングしている場合は、`init.sh` を再実行すると管理マーカー内のポインタも最新版へ置換される。
