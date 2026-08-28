#!/usr/bin/env bash
# test_date_args.sh — stats / report の日付入力が検証されることを固定する。
#
# 集計は日付の文字列比較で期間を切るため、`--since 2026/08/01` のような
# 区切り違いはエラーにならず、全件不一致で「何も起きていない期間」に見える。
# レポートは振り返りの議題そのもので、静かに空になる方が失敗より悪い。
# 基点ファイル(.last-retro)が壊れている場合も、traceback ではなく復旧手順を出す。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/project"
( cd "$WORK/project" && git init -q . )
export CLAUDE_PROJECT_DIR="$WORK/project"
RETRO="$WORK/project/.feedback/.last-retro"

fb() { bash "$REPO/scripts/feedback.sh" "$@"; }
# 出力と終了コードの両方を見る。コマンド置換だけでは rc が取れない
OUT=""
run() { # run <args...>
  local rc
  OUT="$(fb "$@" 2>&1)"
  rc=$?
  return $rc
}

fb add --category style --summary "集計対象の指摘" --detail "本文" >/dev/null

# --- 不正な日付は落とす(静かに空のレポートにしない) ---
for BAD in "2026/08/01" "notadate" "2026-13-01"; do
  run stats --since "$BAD"; RC=$?
  assert_eq "1" "$RC" "stats --since '$BAD' はエラーになる: $OUT"
  assert_contains "$OUT" "YYYY-MM-DD" "stats --since '$BAD' が期待形式を案内する"
  assert_not_contains "$OUT" "Traceback" "stats --since '$BAD' で traceback を出さない"

  run report --since "$BAD"; RC=$?
  assert_eq "1" "$RC" "report --since '$BAD' はエラーになる: $OUT"
  assert_not_contains "$OUT" "Traceback" "report --since '$BAD' で traceback を出さない"
done

run stats --days -1; RC=$?
assert_eq "1" "$RC" "--days に負値を渡すとエラーになる: $OUT"

# 空文字は「指定なし」として扱う(stats は --days の既定へ、report は --last との
# 指定漏れとして案内する)。どちらも黙って誤った期間を切らないことが要件
run stats --since ""; RC=$?
assert_eq "0" "$RC" "stats --since '' は既定の --days へ落ちる: $OUT"
run report --since ""; RC=$?
assert_eq "1" "$RC" "report --since '' は指定漏れとして案内する: $OUT"
assert_contains "$OUT" "--last" "report --since '' が --last の存在を案内する"

# --- 正しい入力は従来どおり通る ---
run stats --since 2026-08-01; RC=$?
assert_eq "0" "$RC" "正しい --since は通る: $OUT"
assert_contains "$OUT" "2026-08-01 以降" "指定した開始日が見出しに出る"

run report --since 2026-08-01; RC=$?
assert_eq "0" "$RC" "report の正しい --since は通る: $OUT"
assert_contains "$OUT" "集計対象の指摘" "期間内の新規エントリが載る"

run report --since yesterday; RC=$?
assert_eq "0" "$RC" "yesterday は従来どおり使える: $OUT"

run stats --days 30; RC=$?
assert_eq "0" "$RC" "--days の既定経路は通る: $OUT"

# --- 壊れた基点(.last-retro)は復旧手順を出す ---
mkdir -p "$(dirname "$RETRO")"
for BROKEN in "" "2026/08/01" "きのう"; do
  printf '%s' "$BROKEN" > "$RETRO"
  run report --last; RC=$?
  assert_eq "1" "$RC" ".last-retro が '$BROKEN' ならエラーになる: $OUT"
  assert_not_contains "$OUT" "Traceback" ".last-retro が '$BROKEN' でも traceback を出さない"
  assert_contains "$OUT" "--mark" "復旧手順(--mark で作り直す)を案内する"
done

printf '2026-08-01' > "$RETRO"
run report --last; RC=$?
assert_eq "0" "$RC" "正しい基点なら report --last が通る: $OUT"
assert_contains "$OUT" "2026-08-01 以降" "基点の日付が見出しに出る"

# --mark は基点を今日で作り直せる(壊れた基点からの復旧経路)
printf 'こわれた' > "$RETRO"
run report --since 2026-08-01 --mark; RC=$?
assert_eq "0" "$RC" "壊れた基点でも --since 指定なら --mark で作り直せる: $OUT"
assert_eq "$(date +%F)" "$(cat "$RETRO")" "--mark が基点を今日へ更新する"

assert_summary
