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

# --- contract: oasdiff(git ベースラインとの破壊的変更差分) ---
P6="$(new_project oas)"
( cd "$P6" && git checkout -q -b main )
printf 'openapi: 3.0.0\ninfo:\n  title: t\n  version: 1.0.0\n' > "$P6/openapi.yaml"
( cd "$P6" && git add openapi.yaml \
  && git -c user.email=t@t -c user.name=t commit -qm v1 )
# 破壊的変更(フィールド削除)を作業ツリーに載せる
printf 'openapi: 3.0.0\ninfo:\n  title: t\n' > "$P6/openapi.yaml"
OARGS="$WORK/oasdiff_args.txt"; : > "$OARGS"
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo "echo \"\$@\" >> \"$OARGS\""
  echo 'exit 1'
} > "$FAKEBIN/oasdiff"
chmod +x "$FAKEBIN/oasdiff"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P6" 2>&1)"; RC=$?
assert_eq "1" "$RC" "破壊的変更の検出で exit 1"
assert_contains "$OUT" "FAIL  contract: oasdiff" "FAILとして記録される"
# ベースラインと現行の2ファイルを渡していること
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
[[ "$(wc -w <"$OARGS" | tr -d ' ')" == "3" ]] || fail "oasdiff に breaking <base> <current> の3語が渡る(実際: $(cat "$OARGS"))"
assert_contains "$(cat "$OARGS")" "breaking" "breaking サブコマンドを使う"

# spec ファイルが無ければステージを出さない
P7="$(new_project oas_none)"
printf 'x\n' > "$P7/a.txt"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P7" 2>&1)"
assert_not_contains "$OUT" "contract: oasdiff" "specが無ければステージを出さない"

# 未コミットの新規 spec はベースラインが取れない → SKIP(FAILにしない)
P8="$(new_project oas_new)"
printf 'openapi: 3.0.0\n' > "$P8/openapi.yaml"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P8" 2>&1)"; RC=$?
assert_eq "0" "$RC" "ベースライン取得不能はブロックしない"
assert_contains "$OUT" "SKIP  contract: oasdiff" "理由付きSKIPになる"
rm -f "$FAKEBIN/oasdiff"

# --- contract: cargo semver-checks ---
P9="$(new_project semver)"
printf '[package]\nname = "t"\nversion = "0.1.0"\n\n[lib]\npath = "src/lib.rs"\n' > "$P9/Cargo.toml"
SARGS="$WORK/semver_args.txt"; : > "$SARGS"
# 偽 cargo: 通常サブコマンド(clippy/test等)は成功させ、semver-checks だけ失敗させる
# (全部落とすと rust: clippy 等もFAILになり、contract の配線検証が曖昧になるため)
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in'
  echo '  *--version*) exit 0 ;;'
  echo '  *"semver-checks check-release"*) echo "$@" >> "'"$SARGS"'"; exit 1 ;;'
  echo 'esac'
  echo "echo \"\$@\" >> \"$SARGS\""
  echo 'exit 0'
} > "$FAKEBIN/cargo"
chmod +x "$FAKEBIN/cargo"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P9" 2>&1)"; RC=$?
assert_eq "1" "$RC" "破壊的変更の検出で exit 1"
assert_contains "$OUT" "FAIL  contract: cargo semver-checks" "FAILとして記録される"
assert_contains "$(cat "$SARGS")" "check-release" "check-release を呼んでいる"

# [lib] が無い crate(バイナリのみ)は対象外
P10="$(new_project semver_bin)"
printf '[package]\nname = "t"\nversion = "0.1.0"\n' > "$P10/Cargo.toml"
: > "$SARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P10" 2>&1)"
assert_not_contains "$OUT" "cargo semver-checks" "[lib]が無ければステージを出さない"
rm -f "$FAKEBIN/cargo"

assert_summary
