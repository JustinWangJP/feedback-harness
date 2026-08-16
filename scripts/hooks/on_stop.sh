#!/usr/bin/env bash
# on_stop.sh — Claude Code Stop フック。
# 応答完了前にフルチェック(check.sh)を実行し、失敗があれば exit 2 で
# 完了をブロックし、失敗内容をエージェントに返して修正を続行させる。
#
# 検査は「前回の成功検査以降に作業ツリーが変わっていれば」実行する。
# 無条件に走らせると、質問応答だけのターンでも導入先のフルビルドが毎回動く。
#
# 無限ループ防止: stop_hook_active が true(すでにStopフック起因で継続中)の
# ときは再ブロックしない。
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$DIR/../lib.sh"

# check.sh の出力から WARN 行を拾って記録する。成功時の出力はエージェントに
# 渡らないため、記録しないと WARN は誰にも届かない
log_warns() { # log_warns <check.shの出力>
  local line label
  while IFS= read -r line; do
    case "$line" in
      "WARN  "*) label="${line#WARN  }"; harness_log_warn "$ROOT" "$label" ;;
    esac
  done <<< "$1"
}

INPUT="$(cat)"
ACTIVE="$(printf '%s' "$INPUT" | python3 -c '
import json,sys
try:
    print(str(json.load(sys.stdin).get("stop_hook_active", False)).lower())
except Exception:
    print("false")
')"

# 検査ルートを明示的に渡す。省略するとカレントディレクトリが検査対象になり、
# サブディレクトリ起動やCI流用時に沈黙して誤ったツリーを検査する。
# $DIR 起点にはしない — プラグイン配布時はキャッシュを指してしまう。
ROOT="$(harness_project_root)"
STAMP="$ROOT/.feedback/.last-check"

# 2周目以降はブロックしない(ループ防止)。ここで check.sh を再実行しない —
# exit 0 で返す出力はエージェントに渡らないため結果が誰にも作用せず、
# 重い導入先では「一番待たされている場面」で時間だけを失う。
if [[ "$ACTIVE" == "true" ]]; then
  exit 0
fi

# 前回の成功検査以降に変更が無ければ、検査済みの状態が続いているだけなので走らせない
if ! harness_tree_changed "$ROOT" "$STAMP"; then
  exit 0
fi

if OUT="$("$DIR/../check.sh" "$ROOT" 2>&1)"; then
  # 成功した時だけスタンプを更新する。失敗を記録すると、直さないまま次の
  # ターンで「変更なし」と判定され、壊れたまま完了できてしまう
  mkdir -p "$(dirname "$STAMP")" 2>/dev/null && : > "$STAMP" 2>/dev/null
  log_warns "$OUT"
  harness_log_event "$ROOT" stop pass
  exit 0
fi

log_warns "$OUT"
harness_log_event "$ROOT" stop fail
echo "$OUT" >&2
# 反復する失敗はルール/自動チェック改善の材料(失敗シグナル)。単発の失敗は記録不要
echo "HINT: 同種の失敗がこのセッションで繰り返されている場合は、修正後に python3 \"$DIR/../feedback_log.py\" add --source hook で記録を検討すること" >&2
exit 2
