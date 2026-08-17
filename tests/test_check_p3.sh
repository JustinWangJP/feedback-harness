#!/usr/bin/env bash
# test_check_p3.sh — P3 で追加する検査(カバレッジ相乗り・contract)の配線を検証する。
# 外部ツールは偽実行ファイル、Python モジュール検出は PYTHONPATH スタブで駆動する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$REPO/scripts/check.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

new_project() { # new_project <名前>
  local d="$WORK/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
make_fake() { # make_fake <名前> <exit> [記録ファイル]
  { echo '#!/usr/bin/env bash'
    echo 'case "$*" in *--version*) exit 0 ;; esac'
    [[ -n "${3:-}" ]] && echo "echo \"\$@\" >> \"$3\""
    echo "exit $2"
  } > "$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}

# --- Python: pytest-cov があるときだけ --cov が渡る ---
P1="$(new_project cov_on)"
printf '[project]\nname = "t"\n' > "$P1/pyproject.toml"
mkdir -p "$P1/tests" "$P1/covstub"
printf 'def test_x():\n    assert True\n' > "$P1/tests/test_x.py"
printf '' > "$P1/covstub/pytest_cov.py"   # import pytest_cov を通すスタブ
PARGS="$WORK/pytest_args.txt"; : > "$PARGS"
make_fake pytest 0 "$PARGS"
make_fake ruff 0
OUT="$(PATH="$FAKEBIN:$PATH" PYTHONPATH="$P1/covstub" bash "$CHECK" "$P1" 2>&1)"; RC=$?
assert_eq "0" "$RC" "pytest が成功すれば exit 0"
assert_contains "$(cat "$PARGS")" "--cov" "pytest-cov 検出時に --cov が渡る"
assert_contains "$(cat "$PARGS")" "--cov-report=term-missing" "行欠損レポートが渡る"

# pytest-cov が無い環境では従来どおりフラグ無し
P2="$(new_project cov_off)"
printf '[project]\nname = "t"\n' > "$P2/pyproject.toml"
mkdir -p "$P2/tests"
printf 'def test_x():\n    assert True\n' > "$P2/tests/test_x.py"
: > "$PARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P2" 2>&1)"; RC=$?
assert_eq "0" "$RC" "pytest-cov 無しでも exit 0"
assert_not_contains "$(cat "$PARGS")" "--cov" "未導入なら --cov を渡さない"

# --- Go: test ステージが -cover に置き換わる ---
P3="$(new_project cov_go)"
printf 'module t\n\ngo 1.21\n' > "$P3/go.mod"
GARGS="$WORK/go_args.txt"; : > "$GARGS"
{ echo '#!/usr/bin/env bash'
  echo 'case "$1" in version|--version) exit 0 ;; esac'
  echo "echo \"\$@\" >> \"$GARGS\""
  echo 'exit 0'
} > "$FAKEBIN/go"
chmod +x "$FAKEBIN/go"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P3" 2>&1)"; RC=$?
assert_eq "0" "$RC" "go test 成功で exit 0"
assert_contains "$(cat "$GARGS")" "test -cover" "go test に -cover が渡る(二重実行しない)"
rm -f "$FAKEBIN/go" "$FAKEBIN/pytest" "$FAKEBIN/ruff"

# --- Node: test:coverage スクリプトがあるときだけ別ステージ ---
P4="$(new_project cov_node)"
printf '{"name":"t","private":true,"scripts":{"test":"exit 0","test:coverage":"exit 0"}}\n' \
  > "$P4/package.json"
NARGS="$WORK/npm_args.txt"; : > "$NARGS"
make_fake npm 0 "$NARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P4" 2>&1)"; RC=$?
assert_eq "0" "$RC" "test:coverage が成功すれば exit 0"
assert_contains "$OUT" "node: npm run test:coverage" "test:coverage ステージが出る"
assert_contains "$(cat "$NARGS")" "run test:coverage" "スクリプトを呼んでいる"

P5="$(new_project cov_node_none)"
printf '{"name":"t","private":true,"scripts":{"test":"exit 0"}}\n' > "$P5/package.json"
: > "$NARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P5" 2>&1)"
assert_not_contains "$OUT" "test:coverage" "スクリプトが無ければステージを出さない"

assert_summary
