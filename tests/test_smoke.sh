#!/usr/bin/env bash
# test_smoke.sh — テスト土台そのものの自己テスト。
#
# アサーションが失敗を検出できなければ、以降の全テストが「常に成功」に
# なっても誰も気づかない。土台が壊れていないことをここで固定する。
#
# このファイルだけは assert.sh を「使わない」— 検証対象と判定機構が同じだと、
# assert_summary が常に exit 0 を返す壊れ方をしたときに自分でも検出できず
# (全テストが無条件成功になる最悪の壊れ方が素通りする)、自己テストの意味が
# 消える。合否は下の smoke_fail / 明示的な exit で独立に決める。
#
# 「わざと失敗させる」子プロセスの出力は必ず捨てる。漏らすと、全件成功の
# 実行でも「N件の検証が失敗」が出力に混ざり、本物の失敗と見分けられなくなる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSERT="$HERE/assert.sh"

SMOKE_FAILURES=0
smoke_fail() {
  echo "    FAIL: $1" >&2
  SMOKE_FAILURES=$((SMOKE_FAILURES + 1))
}

# run_child <アサーション呼び出し> — assert.sh を読み込んだ子プロセスで実行し、
# 終了コードを返す。土台が健全なら「失敗を含む→非0」「成功のみ→0」になる
run_child() {
  bash -c ". '$ASSERT'; $1; assert_summary" >/dev/null 2>&1
}

detects() { # detects <ラベル> <わざと失敗するアサーション>
  run_child "$2" && smoke_fail "$1"
}

accepts() { # accepts <ラベル> <成功するはずのアサーション>
  run_child "$2" || smoke_fail "$1"
}

detects "assert_eq が不一致を検出できていない"             "assert_eq a b 'わざと失敗'"
accepts "assert_eq が一致を失敗扱いにしている"             "assert_eq a a '一致'"

detects "assert_file_exists が不在を検出できていない"      "assert_file_exists /no/such/path x"
accepts "assert_file_exists が存在を失敗扱いにしている"    "assert_file_exists '$ASSERT' x"

detects "assert_file_absent が存在を検出できていない"      "assert_file_absent '$ASSERT' x"
accepts "assert_file_absent が不在を失敗扱いにしている"    "assert_file_absent /no/such/path x"

detects "assert_contains が非包含を検出できていない"       "assert_contains abc x '含まない'"
accepts "assert_contains が包含を失敗扱いにしている"       "assert_contains abc b '含む'"

detects "assert_not_contains が包含を検出できていない"     "assert_not_contains abc b '含む'"
accepts "assert_not_contains が非包含を失敗扱いにしている" "assert_not_contains abc x '含まない'"

# 複数失敗しても最後まで数え上げてから非0で終わること(1件目で止まると
# 1回の実行で全部の失敗を見せられず、修正の往復が増える)
OUT="$(bash -c ". '$ASSERT'; assert_eq a b 一; assert_eq c d 二; assert_summary" 2>&1)"
case "$OUT" in
  *"2/2"*) ;;
  *) smoke_fail "複数の失敗が数え上げられていない: [$OUT]" ;;
esac

if [[ $SMOKE_FAILURES -gt 0 ]]; then
  echo "    ${SMOKE_FAILURES} 件の土台検証が失敗" >&2
  exit 1
fi
exit 0
