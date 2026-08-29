#!/usr/bin/env bash
# test_cli_help.sh — 配布する全 CLI が --help に同じ契約で応じることを検証する。
#
# --help を1スクリプトずつ足していくと契約が割れる。実際 6b51480 は check.sh と
# audit.sh の2ファイルにしか適用されず、init.sh は「ERROR: 対象が存在しません:
# --help」で exit 2、harness_config.py は exit 1、check_file.sh は exit 0 で完全に
# 無言(パスのタイプミスと「検査して問題なし」が区別できない)という不揃いが残った。
# ここで全スクリプトを列挙して固定し、新しい CLI を足したときの書き漏れを捕まえる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

# 配布される CLI(init.sh が導入先へコピーするもの + init.sh 自身)。
# scripts/ に実行可能な CLI を足したらこの配列にも足すこと
CLIS=(
  "bash $REPO/scripts/check.sh"
  "bash $REPO/scripts/check_file.sh"
  "bash $REPO/scripts/feedback.sh"
  "bash $REPO/scripts/audit.sh"
  "bash $REPO/scripts/init.sh"
  "tpy $REPO/scripts/harness_config.py"
  "tpy $REPO/scripts/feedback_log.py"
)

for cli in "${CLIS[@]}"; do
  name="$(basename "${cli##* }")"

  # --help は exit 0 で使い方を出す。非0だと、フックやスキルから叩いた
  # エージェントが「壊れている」と誤認して別の手段を探し始める
  OUT="$($cli --help 2>&1)"; RC=$?
  assert_eq "0" "$RC" "$name --help は exit 0"
  assert_contains "$OUT" "使い方" "$name --help が使い方を出す"

  # -h も同じ挙動(片方だけ効く不揃いを防ぐ)
  $cli -h >/dev/null 2>&1
  assert_eq "0" "$?" "$name -h は exit 0"
done

# --- 不明オプションは引数の誤りとして落ちる ---
# 未知のオプションをプロジェクトルートやファイルパス扱いすると
# 「ディレクトリが見つかりません: --dry-run」となり、原因が引数だと気づけない。
# check_file.sh は除外する — このスクリプトの非0は PostToolUse の差し戻しに
# 直結するため、"-" 始まりのファイル名を誤ブロックしない契約を優先している
for cli in "bash $REPO/scripts/check.sh" "bash $REPO/scripts/audit.sh" "bash $REPO/scripts/init.sh"; do
  name="$(basename "${cli##* }")"
  OUT="$($cli --no-such-option 2>&1)"; RC=$?
  assert_eq "2" "$RC" "$name は不明オプションで exit 2"
  assert_contains "$OUT" "不明なオプション" "$name が原因は引数だと伝える"
done

# --- check_file.sh は "-" 始まりを差し戻さない ---
# post_edit.sh は check_file.sh の非0を fail として記録し exit 2 でブロックする。
# 存在しないファイル(削除直後)を exit 0 で通す既存契約と同じ理由で、
# --help 以外の "-" 始まりもファイル名として扱い、ブロックしない
OUT="$(bash "$REPO/scripts/check_file.sh" --no-such-option 2>&1)"; RC=$?
assert_eq "0" "$RC" "check_file.sh は不明オプションでも差し戻さない"

assert_summary
