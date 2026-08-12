#!/usr/bin/env bash
# assert.sh — テスト用アサーション。各 test_*.sh から source して使う。
#
# 失敗は即座に終了せず数え上げ、assert_summary で最後にまとめて報告する。
# 1ファイル内の複数の失敗を1回の実行で全部見せるため(修正の往復を減らす)。
ASSERT_FAILURES=0
ASSERT_CHECKS=0

fail() {
  echo "    FAIL: $1" >&2
  ASSERT_FAILURES=$((ASSERT_FAILURES + 1))
}

assert_eq() { # assert_eq <expected> <actual> <label>
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  [[ "$1" == "$2" ]] || fail "$3: expected [$1] but got [$2]"
}

assert_contains() { # assert_contains <haystack> <needle> <label>
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  case "$1" in
    *"$2"*) ;;
    *) fail "$3: [$2] が出力に含まれない。出力: [$1]" ;;
  esac
}

assert_file_exists() { # assert_file_exists <path> <label>
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  [[ -e "$1" ]] || fail "$2: 存在しない: $1"
}

assert_file_absent() { # assert_file_absent <path> <label>
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  [[ ! -e "$1" ]] || fail "$2: 存在してはいけない: $1"
}

assert_summary() {
  if [[ $ASSERT_FAILURES -gt 0 ]]; then
    echo "    ${ASSERT_FAILURES}/${ASSERT_CHECKS} 件の検証が失敗" >&2
    exit 1
  fi
  exit 0
}
