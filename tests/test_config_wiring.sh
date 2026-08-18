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

# --- exclude が検査対象を減らす ---
# 効くのはハーネス自身がファイルを列挙する検査だけ(ruff や pytest のように
# 自分でツリーを歩くツールは各自の無視設定に従う)。ここでは shell 検査で確認する
P6="$(new_project excl)"
mkdir -p "$P6/vendor dir"
printf 'if [ ; then\n' > "$P6/vendor dir/broken.sh"    # 構文エラー
# shebang を付ける: 実環境の shellcheck(SC2148)が「シェル種別不明」を
# error 重大度で報告するため、無いと exclude と無関係な理由で FAIL してしまう
printf '#!/usr/bin/env bash\necho ok\n' > "$P6/good.sh"
OUT="$(run_check "$P6")"; RC=$?
assert_eq "1" "$RC" "exclude 無しでは壊れた .sh で exit 1"

# 空白を含むパスが割れないことも同時に確認する
printf 'check:\n  exclude:\n    - "vendor dir/**"\n' > "$P6/.feedback/config.yaml"
OUT="$(run_check "$P6")"; RC=$?
assert_eq "0" "$RC" "exclude で対象から外れ exit 0"
assert_contains "$OUT" "PASS  shell: bash -n" "残ったファイルは検査される"

# --- git 管理外でも同じパターンが効く ---
# 非git環境ではファイル列挙が find になり "./vendor/broken.sh" 形式で返る。
# 先頭の ./ を落とさないと、同じ config を書いても git 管理下かどうかで
# exclude が効いたり効かなかったりし、利用者にはその違いが見えない
P7="$WORK/nogit"
mkdir -p "$P7/.feedback" "$P7/vendor dir"
printf 'if [ ; then\n' > "$P7/vendor dir/broken.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$P7/good.sh"
OUT="$(run_check "$P7")"; RC=$?
assert_eq "1" "$RC" "非git環境でも exclude 無しなら壊れた .sh で exit 1"
printf 'check:\n  exclude:\n    - "vendor dir/**"\n' > "$P7/.feedback/config.yaml"
OUT="$(run_check "$P7")"; RC=$?
assert_eq "0" "$RC" "非git環境でも git 環境と同じパターンで除外できる"

# --- --list-checks ---
P8="$(new_project listing)"
printf '[project]\nname = "t"\n' > "$P8/pyproject.toml"
make_fake ruff 0
# vulture は "has vulture" で存在ゲートされているため(未導入環境では run_stage
# 自体が呼ばれず一覧にも出ない)、他のツールと同じく偽バイナリを置いて確実に走らせる
make_fake vulture 0
printf 'checks:\n  vulture:\n    severity: skip\n' > "$P8/.feedback/config.yaml"

OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" --list-checks "$P8" 2>&1)"; RC=$?
assert_eq "0" "$RC" "--list-checks は exit 0"
assert_contains "$OUT" "検査ID" "見出しが出る"
assert_contains "$OUT" "ruff" "対象の検査が並ぶ"
assert_contains "$OUT" "既定" "config が触っていない検査の出所は既定"
assert_not_contains "$OUT" "cargo-fmt" "対象外スタックの検査は並ばない"

# 検査コマンドを実行しない(一覧表示で pytest や mvn が走ると使い物にならない)
mkdir -p "$P8/tests"; printf 'def test_x():\n    assert True\n' > "$P8/tests/test_x.py"
: > "$WORK/pytest_ran.txt"
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo "echo ran >> \"$WORK/pytest_ran.txt\""
  echo 'exit 0'
} > "$FAKEBIN/pytest"; chmod +x "$FAKEBIN/pytest"
PATH="$FAKEBIN:$PATH" bash "$CHECK" --list-checks "$P8" >/dev/null 2>&1
assert_eq "" "$(cat "$WORK/pytest_ran.txt")" "一覧表示で検査コマンドを実行しない"

# JSON 形式で出所を確認する
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" --list-checks --json "$P8" 2>&1)"
assert_contains "$OUT" '"id": "vulture"' "JSON に検査IDが出る"
assert_contains "$OUT" '"source": "checks.vulture"' "JSON に出所が出る"
rm -f "$FAKEBIN/ruff" "$FAKEBIN/pytest" "$FAKEBIN/vulture"

assert_summary
