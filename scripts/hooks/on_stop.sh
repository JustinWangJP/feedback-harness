#!/usr/bin/env bash
# on_stop.sh — Claude Code Stop フック。
# 応答完了前にフルチェック(check.sh)を実行し、失敗があれば exit 2 で
# 完了をブロックし、失敗内容をエージェントに返して修正を続行させる。
#
# 無限ループ防止: stop_hook_active が true(すでにStopフック起因で継続中)の
# ときは再ブロックしない。
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$DIR/../.." && pwd)}"

# 2周目以降はチェック結果を表示するだけでブロックしない(ループ防止)
if [[ "$ACTIVE" == "true" ]]; then
  "$DIR/../check.sh" "$ROOT" >&2 || true
  exit 0
fi

OUT="$("$DIR/../check.sh" "$ROOT" 2>&1)" && exit 0

echo "$OUT" >&2
exit 2
