#!/usr/bin/env bash
# post_edit.sh — Claude Code PostToolUse (Edit|Write) フック。
# 編集されたファイルを check_file.sh で即時チェックし、問題があれば
# exit 2 + stderr でエージェントに自動フィードバックする(自己修正ループ)。
# 合否は成功・失敗の両方を events.jsonl に記録する(stats の初回通過率の原料)。
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$DIR/../lib.sh"

FILE="$(python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("file_path", ""))
except Exception:
    pass
')"

if [[ -z "$FILE" ]]; then
  exit 0
fi

ROOT="$(harness_project_root)"

if OUT="$("$DIR/../check_file.sh" "$FILE" 2>&1)"; then
  harness_log_event "$ROOT" post_edit pass "$FILE"
  exit 0
fi

harness_log_event "$ROOT" post_edit fail "$FILE"
# exit 2: stderr が Claude にフィードバックされ、自動で修正が促される
echo "$OUT" >&2
echo "上記の問題を修正してから作業を続けること。" >&2
exit 2
