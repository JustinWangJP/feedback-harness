---
id: 20260816-194509
date: 2026-08-16
source: human
category: architecture
status: closed
---

# フック実行時に export された環境変数(CLAUDE_PROJECT_DIR等)は make・テスト経由の子孫プロセスすべてに伝播する — ネストしたスクリプトのルート解決を歪めるため、伝播を前提に再帰ガードを入れる

Stopフック on_stop.sh が timeout 300 を食い潰す「遅さ」の調査で発見。CLAUDE_PROJECT_DIR が check.sh → make check → run_tests.sh → test_init_sh.sh 内のベンダリング版 check.sh まで伝播し、harness_project_root が一時プロジェクトでなく本リポジトリを返したため make check → テスト → check.sh の無限再帰になった。check.sh の make フォールバックに FEEDBACK_CHECK_RECURSION_GUARD を伝える再帰ガードで解決。根因: 文脈欠落(環境変数の伝播範囲を考慮していなかった)

---
close理由: 根因は文脈欠落(環境変数の伝播範囲)のため rules.md 昇華の対象外。対策(check.sh の FEEDBACK_CHECK_RECURSION_GUARD)・回帰テスト(tests/test_recursion_guard.sh)・CLAUDE.md 変更履歴への記録がすべて実施済みで、ガードはハーネス側に織り込まれ導入先でも自動的に機能するため追加対応不要。CLAUDE.md 恒久セクションへの追記案は報告側に提示。
