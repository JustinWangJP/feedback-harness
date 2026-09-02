#!/usr/bin/env bash
# test_feedback_log_retire.sh — retire がルールを rules.md から撤去し、
# 出典エントリ(merge済みの複数出典を含む)を retired に更新することを検証する。
#
# retire は棚卸し(定期審査)の出口。これが無いとルールは増える一方で、
# 陳腐化したルールの誤適用リスクが時間とともに増える。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CLI="$REPO/scripts/feedback_log.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/project"
( cd "$WORK/project" && git init -q . )
export CLAUDE_PROJECT_DIR="$WORK/project"

fb() { tpy "$CLI" "$@"; }
extract_id() { sed -n 's/.*(id=\(.*\))$/\1/p'; }

# ルールA(出典2件: merge で統合)とルールB(隣接ルール、巻き添え検出用)を用意する
ID_A="$(fb add --category style --summary "指摘A" --source human | extract_id)"
ID_B="$(fb add --category testing --summary "指摘B" --source human | extract_id)"
ID_C="$(fb add --category style --summary "指摘Aの再発" --source human | extract_id)"
if [[ -z "$ID_A" || -z "$ID_B" || -z "$ID_C" ]]; then
  fail "add の出力から id を取り出せない"
  assert_summary
fi
fb promote "$ID_A" --rule "ルールA本文" >/dev/null
fb promote "$ID_B" --rule "ルールB本文" >/dev/null
# 同一秒採番の枝番ID(A と A-2 等)が並ぶ状態での merge。出典検索が部分文字列
# 一致だと A が A-2 にも誤ヒットして失敗する(過去に実在したバグ)の回帰確認
MERGE_OUT="$(fb merge "$ID_C" --into "$ID_A" 2>&1)"
assert_contains "$MERGE_OUT" "merged:" "枝番IDが並んでいても merge が正しいルールに当たる"

RULES_FILE="$WORK/project/.feedback/rules.md"
assert_contains "$(cat "$RULES_FILE")" "ルールA本文" "前提: ルールAが存在する"

# --- 退役 ---
OUT="$(fb retire "$ID_A" --reason "検査で自動化したため" 2>&1)"
assert_contains "$OUT" "retired:" "retire が成功する"

CONTENT="$(cat "$RULES_FILE")"
assert_not_contains "$CONTENT" "ルールA本文" "退役したルールAが撤去される"
assert_not_contains "$CONTENT" "出典: $ID_A," "ルールAの出典行も撤去される"
assert_contains "$CONTENT" "ルールB本文" "隣のルールBは巻き添えにならない"
assert_contains "$CONTENT" "フィードバック由来ルール" "ヘッダは残る"

# 出典エントリは merge 済みの分も含めて全件 retired になり、理由が追記される。
# ID_A は ID_B/ID_C(枝番)の部分文字列なので、前後の空白で区切って照合する
LIST_RETIRED="$(fb list --status retired)"
assert_contains "$LIST_RETIRED" " $ID_A " "出典Aが retired になる"
assert_contains "$LIST_RETIRED" " $ID_C " "merge済みの出典Cも retired になる"
LIST_PROMOTED="$(fb list --status promoted)"
assert_not_contains "$LIST_PROMOTED" " $ID_A " "Aは promoted に残らない"
assert_contains "$LIST_PROMOTED" " $ID_B " "Bは promoted のまま"

ENTRY_A_FILE="$(grep -rl "^id: ${ID_A}\$" "$WORK/project/.feedback/log")"
assert_contains "$(cat "$ENTRY_A_FILE")" "retire理由: 検査で自動化したため" "退役理由がエントリに追記される"

# 退役後も rules.md の形式が保たれ、promote が壊れないこと
ID_D="$(fb add --category naming --summary "指摘D" --source human | extract_id)"
fb promote "$ID_D" --rule "ルールD本文" >/dev/null
assert_contains "$(cat "$RULES_FILE")" "ルールD本文" "退役後も promote できる"

# --- エラー系 ---
ERR="$(fb retire "99999999-999999" --reason "存在しない" 2>&1 || true)"
assert_contains "$ERR" "ありません" "存在しないIDはエラーになる"

# --- 二重昇華の遮断(close と同じ強さで状態を確認する) ---
# 状態を見ていたのは close だけだったため、同じエントリを2回 promote すると
# 同じ出典を持つルールが2件でき、以後その id では find_rule_by_source が
# 曖昧性で失敗して merge / retire が一切通らなくなる(出口が rules.md の
# 手編集しか無い袋小路)。入口ごとに検証の強さを変えない、という原則の回帰。
DUP_ERR="$(fb promote "$ID_D" --rule "ルールD本文(2回目)" 2>&1 || true)"
assert_contains "$DUP_ERR" "open ではありません" "昇華済みのエントリは promote できない: $DUP_ERR"
assert_contains "$DUP_ERR" "retire" "エラー文が復旧手順(retire)を案内する: $DUP_ERR"
assert_not_contains "$(cat "$RULES_FILE")" "ルールD本文(2回目)" "2回目のルール本文は書き込まれない"
DUP_SOURCES="$(grep -c "出典: $ID_D" "$RULES_FILE" || true)"
assert_eq "1" "$DUP_SOURCES" "出典行が重複しない"

# merge も同じ状態ガードを通る(片方だけ直して他が残る形を防ぐ)
MERGE_ERR="$(fb merge "$ID_D" --into "$ID_B" 2>&1 || true)"
assert_contains "$MERGE_ERR" "open ではありません" "昇華済みのエントリは merge できない: $MERGE_ERR"

# ただし「同じ merge のやり直し」は状態ガードより先に、具体的なエラーで止める。
# 汎用の状態エラーは retire を案内するため、それに従うと統合先ルールごと
# 撤去される — 案内どおりに操作して壊れるのが最悪の形なので順序で防ぐ。
# ルールA は既に退役済みなので、この検証専用のルールを新しく作る
ID_F="$(fb add --category naming --summary "指摘F" --source human | extract_id)"
ID_G="$(fb add --category naming --summary "指摘Fの再発" --source human | extract_id)"
fb promote "$ID_F" --rule "ルールF本文" >/dev/null
fb merge "$ID_G" --into "$ID_F" >/dev/null
REMERGE_ERR="$(fb merge "$ID_G" --into "$ID_F" 2>&1 || true)"
assert_contains "$REMERGE_ERR" "すでにこのルールの出典です" \
  "同じルールへの再 merge は具体的なエラーで止まる: $REMERGE_ERR"
assert_not_contains "$REMERGE_ERR" "retire" \
  "再 merge のエラーが破壊的な操作を案内しない: $REMERGE_ERR"
assert_contains "$(cat "$RULES_FILE")" "ルールF本文" "再 merge を弾いてもルールFは残る"

# 遮断したうえで、正規の出口(retire)は塞がっていないこと — 袋小路を作らない
assert_contains "$(fb retire "$ID_D" --reason "重複を作らずに退役できる" 2>&1)" "retired:" \
  "二重昇華を弾いた後も retire は通る"

# close 済みのエントリも昇華できない(open 以外は一律で弾く)
ID_E="$(fb add --category style --summary "指摘E" --source human | extract_id)"
fb close "$ID_E" --reason "一回限り" >/dev/null
CLOSED_ERR="$(fb promote "$ID_E" --rule "ルールE本文" 2>&1 || true)"
assert_contains "$CLOSED_ERR" "open ではありません" "close 済みのエントリは promote できない: $CLOSED_ERR"

# close 自身も同じ関数(require_open)を通る。インラインの確認を残すと、
# 文言も復旧手順も片方にしか反映されない形でドリフトする
DOUBLE_CLOSE_ERR="$(fb close "$ID_E" --reason "二重close" 2>&1 || true)"
assert_contains "$DOUBLE_CLOSE_ERR" "open ではありません" "close 済みは再 close できない: $DOUBLE_CLOSE_ERR"
assert_contains "$DOUBLE_CLOSE_ERR" "add で記録し直して" \
  "close のエラーも復旧手順を案内する(promote / merge と同じ関数を通る): $DOUBLE_CLOSE_ERR"

assert_summary
