#!/usr/bin/env bash
# run_tests.sh — tests/test_*.sh を1件ずつ子プロセスで実行する。
#
# 子プロセスで実行するのは、テストが cd や export で環境を汚しても
# 他のテストに影響させないため。
set -u
TESTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# フック実行時に export された環境変数は make・テスト経由で子孫へ伝播する。
# CLAUDE_PROJECT_DIR が本リポジトリを指したままテストが走ると、隔離プロジェクト
# ではなく本リポジトリの .feedback/ を読み書きし、アサートが環境次第で崩れる
# (2026-08-19 に test_check_file_severity / test_events_log の2件で実際に発生)。
# ここで一括して掃落とし、「テストは必要な変数を自分で設定する」契約にする。
#
# FEEDBACK_CHECK_RECURSION_GUARD は外すと逆に壊れる — この変数は check.sh が
# make 起動時に意図的に子孫へ伝える再帰切断機構であり、run_tests.sh →
# test_recursion_guard.sh → check.sh → make check → run_tests.sh … の循環を
# 断っている。hook 由来の偶然の伝播(掃落とすべきもの)と、設計された伝播
# (残すべきもの)の区別がここにある。
unset CLAUDE_PROJECT_DIR FEEDBACK_CHECK_SKIP FEEDBACK_SHELLCHECK_SEVERITY FEEDBACK_CONTRACT_BASE

# テスト自身が直接起動する python3(fixture生成・検証補助)の入出力を UTF-8 に
# 固定する。テストコードは配布物ではないので、ハーネス本体と違いここで環境変数を
# 使ってよい。ハーネス本体の Python 実行は _harness_python_exec が command 上で
# UTF-8 を指定するため、この export に依存しない — 依存していないことは
# test_python_boundary.sh が ambient を ascii に潰して検証する。
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

PASSED=0
FAILED=0
FAILED_NAMES=""

for t in "$TESTDIR"/test_*.sh; do
  [[ -f "$t" ]] || continue
  name="$(basename "$t")"
  echo "  $name"
  if bash "$t"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_NAMES="${FAILED_NAMES}    $name"$'\n'
  fi
done

echo "=== tests: ${PASSED} passed, ${FAILED} failed ==="
if [[ $FAILED -gt 0 ]]; then
  printf '%s' "$FAILED_NAMES"
  exit 1
fi
exit 0
