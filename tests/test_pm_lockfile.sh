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
assert_contains "$OUT" "pnpm の lockfile" "npm audit は理由付き SKIP になる"
assert_not_contains "$(cat "$NPM_ARGS")" "audit" "npm audit は起動されない"

# --- lockfile 併存: check.sh と audit.sh が同じ PM を見る ---
# npm から pnpm への移行中などで package-lock.json が残っていると、
# 判定が2箇所にあった頃は check.sh が pnpm で走る一方 audit.sh が npm audit を
# 実行し、実際の依存解決(pnpm-lock.yaml)と違うツリーを監査していた。
# 監査対象がテスト実行と食い違う状態を機械的に禁じる(出典 20260817-142537)
printf '{"lockfileVersion":3}\n' > "$P/package-lock.json"   # pnpm-lock.yaml と併存させる
: > "$NPM_ARGS"

OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P" 2>&1)"; RC=$?
assert_eq "0" "$RC" "lockfile 併存でも check.sh は exit 0"
assert_contains "$OUT" "SKIP  node: npm ls (pnpm は ls --all 非対応)" \
  "併存時も check.sh は pnpm と判定する"

OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P" 2>&1)"; RC=$?
assert_eq "0" "$RC" "lockfile 併存でも audit.sh は exit 0"
assert_contains "$OUT" "pnpm の lockfile" \
  "併存時に audit.sh は check.sh と同じ pnpm 判定へ揃う(npm audit を走らせない)"
assert_not_contains "$(cat "$NPM_ARGS")" "audit" \
  "package-lock.json が残っていても npm audit は起動されない"

# --- npm プロジェクトでは従来どおり npm audit が動く(過剰なSKIPにしない) ---
NP="$WORK/npmproj"; mkdir -p "$NP"
( cd "$NP" && git init -q . )
printf '{"name":"t","version":"0.0.0"}\n' > "$NP/package.json"
printf '{"lockfileVersion":3}\n' > "$NP/package-lock.json"
: > "$NPM_ARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$NP" 2>&1)"
assert_contains "$(cat "$NPM_ARGS")" "audit" "npm プロジェクトでは npm audit が起動する"

# --- 判定の書き漏れを構造で捕まえる ---
# 上のケースは check.sh / audit.sh という既知2箇所の回帰テストであり、
# 3つ目のスクリプトが npm 系コマンドを PM 判定なしで足しても緑のままだった。
# 冒頭が「判定の書き漏れを機械的に捕まえる護欄」と宣言している以上、
# 宣言どおり全スクリプトを走査する検査をここに置く
#
# npm ls --all / npm audit を実行しているスクリプトは harness_node_pm を
# 参照していること。参照せずに呼べば、pnpm/yarn プロジェクトで ENOLOCK の
# 誤FAIL(出典 20260817-142537 の欠陥そのもの)を再発させる
for script in "$REPO"/scripts/*.sh; do
  name="$(basename "$script")"
  [[ "$name" == "lib.sh" ]] && continue # 判定関数の定義元(参照側ではない)

  # コメント行を除いて、npm ls / npm audit を実際に起動している行を探す
  invocations="$(grep -vE '^\s*#' "$script" | grep -E 'npm (ls|audit)' || true)"
  [[ -z "$invocations" ]] && continue

  assert_contains "$(cat "$script")" "harness_node_pm" \
    "$name は npm 系コマンドを呼ぶため harness_node_pm で PM を判定している"
done

assert_summary
