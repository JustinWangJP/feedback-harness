#!/usr/bin/env bash
# test_pm_lockfile.sh — npm 系コマンドの PM・lockfile 判定を検証する。
#
# npm ls --all / npm audit が読めるのは npm の世界(package-lock.json)だけ。
# pnpm-lock.yaml / yarn.lock しか無いプロジェクトでこれらを走らせると ENOLOCK
# で exit 1 になり、ユーザーのコードの問題ではない誤FAILになる(出典
# 20260817-142537)。npm 系コマンドをスクリプトへ足すときは PM 判定を併せて
# 足すこと — このテストは判定の書き漏れを機械的に捕まえる護欄である。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$REPO/scripts/check.sh"
AUDIT="$REPO/scripts/audit.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"

# 偽 npm — 呼び出しの引数を記録する。PM 判定が正しければ ls / audit は
# 一度も起動されないはず
NPM_ARGS="$WORK/npm_args.txt"; : > "$NPM_ARGS"
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo "echo \"\$@\" >> \"$NPM_ARGS\""
  echo 'exit 0'
} > "$FAKEBIN/npm"; chmod +x "$FAKEBIN/npm"

P="$WORK/proj"
mkdir -p "$P"
( cd "$P" && git init -q . )
printf '{"name":"t","version":"0.0.0"}\n' > "$P/package.json"
printf 'lockfileVersion: 6.0\n' > "$P/pnpm-lock.yaml"   # npm 以外の lockfile のみ
mkdir -p "$P/node_modules"   # npm ls の node_modules ゲートを通し、PM 判定だけを試す

# --- check.sh: npm ls は PM 判定で理由付き SKIP ---
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P" 2>&1)"; RC=$?
assert_eq "0" "$RC" "pnpm プロジェクトで check.sh は exit 0(誤FAILしない)"
assert_contains "$OUT" "SKIP  node: npm ls (pnpm は ls --all 非対応)" "npm ls は理由付き SKIP になる"
assert_not_contains "$(cat "$NPM_ARGS")" "ls --all" "npm ls --all は起動されない"

# --- audit.sh: npm audit は lockfile 判定で理由付き SKIP ---
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P" 2>&1)"; RC=$?
assert_eq "0" "$RC" "pnpm プロジェクトで audit.sh は exit 0(誤FAILしない)"
assert_contains "$OUT" "npm 以外の lockfile" "npm audit は理由付き SKIP になる"
assert_not_contains "$(cat "$NPM_ARGS")" "audit" "npm audit は起動されない"

assert_summary
