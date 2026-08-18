#!/usr/bin/env bash
# test_config_wiring.sh — config が check.sh の実挙動に効くことを検証する。
#
# パーサ単体のテスト(test_config.sh)では配線を検証できない。ここでは
# 偽の検査ツールを PATH に置き、config の指定で exit code と出力が
# 変わることを確かめる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$REPO/scripts/check.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"

make_fake() { # make_fake <名前> <exit>
  { echo '#!/usr/bin/env bash'
    echo 'case "$*" in *--version*) exit 0 ;; esac'
    echo "exit $2"
  } > "$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}
new_project() { local d="$WORK/$1"; mkdir -p "$d/.feedback"; ( cd "$d" && git init -q . ); printf '%s\n' "$d"; }
run_check() { PATH="$FAKEBIN:$PATH" bash "$CHECK" "$1" 2>&1; }

# --- 検査単位の skip ---
P1="$(new_project skip_one)"
printf '[project]\nname = "t"\n' > "$P1/pyproject.toml"
make_fake ruff 1          # ruff は失敗する
OUT="$(run_check "$P1")"; RC=$?
assert_eq "1" "$RC" "config 無しでは ruff の失敗で exit 1"

printf 'checks:\n  ruff:\n    severity: skip\n' > "$P1/.feedback/config.yaml"
OUT="$(run_check "$P1")"; RC=$?
assert_eq "0" "$RC" "checks.ruff.severity=skip で完了をブロックしない"
assert_contains "$OUT" "SKIP  python: ruff (config: checks.ruff)" "SKIP に出所が出る"

# --- 検査単位で WARN に落とす ---
printf 'checks:\n  ruff:\n    severity: warn\n' > "$P1/.feedback/config.yaml"
OUT="$(run_check "$P1")"; RC=$?
assert_eq "0" "$RC" "severity=warn なら exit 0"
assert_contains "$OUT" "WARN  python: ruff" "WARN として記録される"

# --- 宣言が無くても FAIL に上げる ---
P2="$(new_project fail_on)"
printf '[project]\nname = "t"\n' > "$P2/pyproject.toml"   # [tool.ruff] は書かない
make_fake ruff 0
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; *format*) exit 1 ;; esac'
  echo 'exit 0'
} > "$FAKEBIN/ruff"; chmod +x "$FAKEBIN/ruff"
OUT="$(run_check "$P2")"; RC=$?
assert_eq "0" "$RC" "宣言が無ければ ruff format は WARN(exit 0)"
printf 'checks:\n  ruff-format:\n    severity: fail\n' > "$P2/.feedback/config.yaml"
OUT="$(run_check "$P2")"; RC=$?
assert_eq "1" "$RC" "severity=fail で完了をブロックする"
rm -f "$FAKEBIN/ruff"

# --- スタック単位 ---
P3="$(new_project per_stack)"
printf '[project]\nname = "t"\n' > "$P3/pyproject.toml"
printf 'module t\n\ngo 1.21\n' > "$P3/go.mod"
mkdir -p "$P3/tests"; printf 'def test_x():\n    assert True\n' > "$P3/tests/test_x.py"
make_fake pytest 1
make_fake ruff 0
{ echo '#!/usr/bin/env bash'
  echo 'case "$1" in version|--version) exit 0 ;; esac'
  echo 'exit 0'
} > "$FAKEBIN/go"; chmod +x "$FAKEBIN/go"
printf 'check:\n  python:\n    skip: [test]\n' > "$P3/.feedback/config.yaml"
OUT="$(run_check "$P3")"; RC=$?
assert_eq "0" "$RC" "Python の test だけ外して exit 0"
assert_contains "$OUT" "SKIP  python: pytest (config: check.python.skip)" "スタック層の出所が出る"
assert_contains "$OUT" "PASS  go: test" "他スタックの test は残る"
rm -f "$FAKEBIN/pytest" "$FAKEBIN/ruff" "$FAKEBIN/go"

# --- 環境変数が config に勝つ ---
P4="$(new_project env_wins)"
printf '[project]\nname = "t"\n' > "$P4/pyproject.toml"
make_fake ruff 1
printf 'checks:\n  ruff:\n    severity: fail\n' > "$P4/.feedback/config.yaml"
OUT="$(PATH="$FAKEBIN:$PATH" FEEDBACK_CHECK_SKIP=lint bash "$CHECK" "$P4" 2>&1)"; RC=$?
assert_eq "0" "$RC" "環境変数の skip が config の fail に勝つ"
assert_contains "$OUT" "env.FEEDBACK_CHECK_SKIP" "出所が環境変数になる"
rm -f "$FAKEBIN/ruff"

# --- 壊れた config は FAIL を立てつつ他の検査を続ける ---
P5="$(new_project broken)"
printf '[project]\nname = "t"\n' > "$P5/pyproject.toml"
make_fake ruff 0
printf 'check:\n  skip: [lnit]\n' > "$P5/.feedback/config.yaml"
OUT="$(run_check "$P5")"; RC=$?
assert_eq "1" "$RC" "壊れた config は完了をブロックする"
assert_contains "$OUT" "FAIL  config: .feedback/config.yaml" "config 自体の FAIL が出る"
assert_contains "$OUT" "PASS  python: ruff" "他の検査は既定値で続行する"
rm -f "$FAKEBIN/ruff"

assert_summary
