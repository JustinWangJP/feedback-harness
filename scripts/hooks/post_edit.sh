#!/usr/bin/env bash
# post_edit.sh — Claude Code / Codex PostToolUse (Edit|Write) フック。
# 編集されたファイルを check_file.sh で即時チェックし、問題があれば
# exit 2 + stderr でエージェントに自動フィードバックする(自己修正ループ)。
# 合否は成功・失敗の両方を events.jsonl に記録する(stats の初回通過率の原料)。
#
# Claude Code は tool_input.file_path、Codex の apply_patch は
# tool_input.command 内のパッチヘッダで対象ファイルを渡す。両形式を受け付け、
# 1回の apply_patch が複数ファイルを変更した場合は全ファイルを検査する。
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$DIR/../lib.sh"

INPUT="$(cat)"
FILES=()
while IFS= read -r file; do
  [[ -n "$file" ]] && FILES[${#FILES[@]}]="$file"
done < <(printf '%s' "$INPUT" | harness_python -c '
import json,re,sys
try:
    d = json.load(sys.stdin)
    tool_input = d.get("tool_input", {})
    paths = []

    file_path = tool_input.get("file_path", "")
    if isinstance(file_path, str) and file_path:
        paths.append(file_path)

    command = tool_input.get("command", tool_input.get("patch", ""))
    if isinstance(command, str):
        for line in command.splitlines():
            match = re.match(r"^\*\*\* (?:Add|Update) File: (.+)$", line)
            if match:
                paths.append(match.group(1))
                continue
            match = re.match(r"^\*\*\* Move to: (.+)$", line)
            if match:
                if paths:
                    paths[-1] = match.group(1)
                else:
                    paths.append(match.group(1))

    seen = set()
    for path in paths:
        if path and path not in seen:
            seen.add(path)
            print(path)
except Exception:
    pass
')

if [[ ${#FILES[@]} -eq 0 ]]; then
  exit 0
fi

ROOT="$(harness_project_root)"
FAILED=0
FAIL_OUTPUT=""

for FILE in "${FILES[@]}"; do
  FILE="$(harness_bash_path "$FILE")"
  case "$FILE" in
    /*) CHECK_PATH="$FILE" ;;
    *) CHECK_PATH="$ROOT/$FILE" ;;
  esac

  if OUT="$("$DIR/../check_file.sh" "$CHECK_PATH" 2>&1)"; then
    harness_log_event "$ROOT" post_edit pass "$CHECK_PATH"
    continue
  fi

  harness_log_event "$ROOT" post_edit fail "$CHECK_PATH"
  FAILED=1
  if [[ -n "$FAIL_OUTPUT" ]]; then
    FAIL_OUTPUT="$FAIL_OUTPUT
"
  fi
  FAIL_OUTPUT="${FAIL_OUTPUT}[$FILE]
$OUT"
done

if [[ $FAILED -ne 0 ]]; then
  # exit 2: stderr が Claude Code / Codex にフィードバックされ、自動で修正が促される
  echo "$FAIL_OUTPUT" >&2
  echo "上記の問題を修正してから作業を続けること。" >&2
  exit 2
fi

exit 0
