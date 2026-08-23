#!/usr/bin/env bash
# assert.sh — テスト用アサーション。各 test_*.sh から source して使う。
#
# 失敗は即座に終了せず数え上げ、assert_summary で最後にまとめて報告する。
# 1ファイル内の複数の失敗を1回の実行で全部見せるため(修正の往復を減らす)。
ASSERT_FAILURES=0
ASSERT_CHECKS=0

# setup-python は Windows では python.exe だけを PATH に置く。既存テストの
# python3 呼び出しを Git Bash でも同じまま使えるよう、実在する Python 3.10+
# を一度解決し、python3 が無い場合だけ Bash function で橋渡しする。
if command -v python3 >/dev/null 2>&1 \
   && python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' \
     >/dev/null 2>&1; then
  TEST_PYTHON="$(command -v python3)"
elif command -v python >/dev/null 2>&1 \
   && python -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' \
     >/dev/null 2>&1; then
  TEST_PYTHON="$(command -v python)"
  # 変換条件が _harness_python_exec(実在pathのみ)より広いのは意図的。
  # ここへ渡るのはテストが組み立てた引数だけで、まだ存在しない出力pathも含む。
  # 自由テキストが来ることは無いため、実在判定で絞ると逆に変換漏れになる。
  python3() {
    local args=()
    local arg
    for arg in "$@"; do
      if [[ -n "${MSYSTEM:-}" && "$arg" == /* ]] && command -v cygpath >/dev/null 2>&1; then
        args+=("$(cygpath -w -- "$arg")")
      else
        args+=("$arg")
      fi
    done
    "$TEST_PYTHON" "${args[@]}"
  }
  export -f python3
else
  echo "    FAIL: tests require Python 3.10+ (python3 or python)" >&2
  exit 1
fi
export TEST_PYTHON

native_path() { # native_path <Git Bash / Unix path>
  if [[ -n "${MSYSTEM:-}" ]] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w -- "$1"
  else
    printf '%s\n' "$1"
  fi
}

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

assert_not_contains() { # assert_not_contains <haystack> <needle> <label>
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  case "$1" in
    *"$2"*) fail "$3: [$2] が出力に含まれてはいけない。出力: [$1]" ;;
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
