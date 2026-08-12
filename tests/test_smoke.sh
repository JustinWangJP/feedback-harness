#!/usr/bin/env bash
# test_smoke.sh — テスト土台そのものの自己テスト。
#
# アサーションが失敗を検出できなければ、以降の全テストが「常に成功」に
# なっても誰も気づかない。土台が壊れていないことをここで固定する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"

# 失敗するアサーションを含む子プロセスは exit 1 になること
if bash -c ". '$HERE/assert.sh'; assert_eq a b 'わざと失敗' 2>/dev/null; assert_summary"; then
  fail "assert_eq が不一致を検出できていない"
fi

# 成功するアサーションだけの子プロセスは exit 0 になること
if bash -c ". '$HERE/assert.sh'; assert_eq a a '一致'; assert_summary"; then
  :
else
  fail "assert_eq が一致を失敗扱いにしている"
fi

# assert_file_exists / assert_file_absent も同様に両方向を確認する
if bash -c ". '$HERE/assert.sh'; assert_file_exists /no/such/path x 2>/dev/null; assert_summary"; then
  fail "assert_file_exists が不在を検出できていない"
fi
if bash -c ". '$HERE/assert.sh'; assert_file_absent '$HERE/assert.sh' x 2>/dev/null; assert_summary"; then
  fail "assert_file_absent が存在を検出できていない"
fi

# assert_contains も同様に両方向を確認する
if bash -c ". '$HERE/assert.sh'; assert_contains abc x '含まない' 2>/dev/null; assert_summary"; then
  fail "assert_contains が非包含を検出できていない"
fi
if bash -c ". '$HERE/assert.sh'; assert_contains abc b '含む'; assert_summary"; then
  :
else
  fail "assert_contains が包含を失敗扱いにしている"
fi

assert_summary
