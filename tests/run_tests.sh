#!/usr/bin/env bash
# run_tests.sh — tests/test_*.sh を1件ずつ子プロセスで実行する。
#
# 子プロセスで実行するのは、テストが cd や export で環境を汚しても
# 他のテストに影響させないため。
set -u
TESTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
