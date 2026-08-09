#!/usr/bin/env bash
# post_edit.sh — Claude Code PostToolUse (Edit|Write) フック。
# 編集されたファイルを check_file.sh で即時チェックし、問題があれば
# exit 2 + stderr でエージェントに自動フィードバックする(自己修正ループ)。
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FILE="$(python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("file_path", ""))
except Exception:
    pass
')"

[[ -z "$FILE" ]] && exit 0

OUT="$("$DIR/../check_file.sh" "$FILE" 2>&1)" && exit 0

# exit 2: stderr が Claude にフィードバックされ、自動で修正が促される
echo "$OUT" >&2
echo "上記の問題を修正してから作業を続けること。" >&2
exit 2
