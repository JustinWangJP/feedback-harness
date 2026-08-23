#!/usr/bin/env bash
# test_events_log.sh — フックが合否を events.jsonl に記録する(成功も失敗も)ことと、
# .feedback/ 内の更新が木変更判定(harness_tree_changed)を起こさないことを検証する。
#
# 成功の記録が無いと初回通過率の分母が取れない。また events.jsonl が木変更判定に
# 波及すると、記録のたびにフルチェックが再燃する(2026-08-12 の過剰実行の再発)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
. "$REPO/scripts/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/proj/sub" "$WORK/proj/.feedback/log" "$WORK/proj/.git"
( cd "$WORK/proj" && git init -q . )
touch "$WORK/proj/sub/code.py"
touch -t 202601010000 "$WORK/proj/sub/code.py" "$WORK/proj/sub" "$WORK/proj"
STAMP="$WORK/proj/.feedback/.last-check"
: > "$STAMP"
touch -t 202601020000 "$STAMP"

# 偽の check_file.sh / check.sh でフックを駆動する(実際のlinterに依存しない)
mkdir -p "$WORK/fake/hooks"
cp "$REPO/scripts/hooks/post_edit.sh" "$WORK/fake/hooks/"
cp "$REPO/scripts/hooks/on_stop.sh" "$WORK/fake/hooks/"
cp "$REPO/scripts/lib.sh" "$WORK/fake/"
cp "$REPO/scripts/feedback_store.py" "$WORK/fake/"
fake_exit() { # fake_exit <exit-code>
  for name in check_file check; do
    { echo '#!/usr/bin/env bash'; echo "exit $1"; } > "$WORK/fake/$name.sh"
    chmod +x "$WORK/fake/$name.sh"
  done
}

EVENTS="$WORK/proj/.feedback/events.jsonl"
run_post_edit() { # run_post_edit <exit-code>
  fake_exit "$1"
  printf '{"tool_input": {"file_path": "%s"}}' "$WORK/proj/sub/code.py" \
    | CLAUDE_PROJECT_DIR="$WORK/proj" bash "$WORK/fake/hooks/post_edit.sh" >/dev/null 2>&1
}
run_stop() { # run_stop <exit-code>
  fake_exit "$1"
  rm -f "$STAMP"  # 「変更あり」を保証して check.sh が実行されるようにする
  printf '{"stop_hook_active": false}' \
    | CLAUDE_PROJECT_DIR="$WORK/proj" bash "$WORK/fake/hooks/on_stop.sh" >/dev/null 2>&1
}

# --- post_edit: 成功も失敗も記録される ---
run_post_edit 0
assert_contains "$(cat "$EVENTS")" '"hook":"post_edit"' "post_edit のイベントが記録される"
assert_contains "$(cat "$EVENTS")" '"result":"pass"' "成功も記録される(初回通過率の分母)"
assert_contains "$(cat "$EVENTS")" '"file":"sub/code.py"' "file はルート相対パスで記録される"
run_post_edit 1
assert_contains "$(tail -n 1 "$EVENTS")" '"result":"fail"' "失敗も記録される"

# Codex の apply_patch は file_path ではなくパッチ本文を tool_input.command に渡す。
# 実フックと同じく CLAUDE_PROJECT_DIR を設定して駆動する(他の呼び出しと同様。
# フック由来の変数の汚染は run_tests.sh が一括して掃落とす契約)
fake_exit 0
printf '%s' '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: sub/code.py\n@@\n-old\n+new\n*** End Patch"}}' \
  | (cd "$WORK/proj" && CLAUDE_PROJECT_DIR="$WORK/proj" bash "$WORK/fake/hooks/post_edit.sh") >/dev/null 2>&1
assert_contains "$(tail -n 1 "$EVENTS")" '"file":"sub/code.py"' \
  "Codex apply_patch の対象ファイルが記録される"
assert_contains "$(tail -n 1 "$EVENTS")" '"result":"pass"' \
  "Codex apply_patch でも即時チェックが実行される"

# file が解決できない入力は記録しない
BEFORE="$(wc -l <"$EVENTS" | tr -d ' ')"
printf '{"tool_input": {}}' \
  | CLAUDE_PROJECT_DIR="$WORK/proj" bash "$WORK/fake/hooks/post_edit.sh" >/dev/null 2>&1
AFTER="$(wc -l <"$EVENTS" | tr -d ' ')"
assert_eq "$BEFORE" "$AFTER" "file_path とパッチ本文が無いときは記録しない"

# --- on_stop: check.sh を実行したときだけ記録される ---
run_stop 0
assert_contains "$(tail -n 1 "$EVENTS")" '"hook":"stop"' "stop のイベントが記録される"
run_stop 1
assert_contains "$(tail -n 1 "$EVENTS")" '"result":"fail"' "stop の失敗も記録される"

# --- ローテーション: 512KB 超で末尾2000行に切詰められる ---
# 追記してから切り詰める順序なので、結果は追記分を含めてちょうど2000行になる
yes '{"ts":"2026-01-01T00:00:00Z","hook":"stop","result":"pass"}' | head -n 15000 > "$EVENTS"
harness_log_event "$WORK/proj" stop pass
LINES="$(wc -l <"$EVENTS" | tr -d ' ')"
assert_eq "2000" "$LINES" "512KB超で末尾2000行に切詰められる"

# --- 除外: events.jsonl の更新でフルチェックが再燃しない(prune 前提の固定) ---
# 直前の run_stop(失敗)はスタンプを進めないため、ここで基準スタンプを作り直す
# (スタンプ不在は「初回・安全側」で常に変更ありと判定されるため検証にならない)
touch -t 202601010000 "$WORK/proj/sub/code.py" "$WORK/proj/sub" "$WORK/proj"
: > "$STAMP"
touch -t 202601020000 "$STAMP"
touch -t 202601030000 "$EVENTS"
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
if harness_tree_changed "$WORK/proj" "$STAMP"; then
  fail "events.jsonl の更新でフルチェックが再燃した(.feedback prune前提が崩れた)"
fi

# --- WARN は events.jsonl に記録される(成功時の出力はエージェントに届かないため、
#     WARN を握り潰さずフィードバックループに載せる唯一の経路になる) ---
: > "$EVENTS"
mkdir -p "$WORK/fake"
{ echo '#!/usr/bin/env bash'
  echo 'echo "=== feedback-harness check ==="'
  echo 'echo "PASS  python: ruff"'
  echo 'echo "WARN  python: ruff format"'
  echo 'echo "ALL PASS (1件WARN — 未対応の指摘があります)"'
  echo 'exit 0'
} > "$WORK/fake/check.sh"
chmod +x "$WORK/fake/check.sh"
rm -f "$STAMP"
printf '{"stop_hook_active": false}' \
  | CLAUDE_PROJECT_DIR="$WORK/proj" bash "$WORK/fake/hooks/on_stop.sh" >/dev/null 2>&1
EV="$(cat "$EVENTS")"
assert_contains "$EV" '"result":"warn"' "WARN イベントが記録される"
assert_contains "$EV" '"check":"python: ruff format"' "WARN のラベルが check として記録される"
assert_contains "$EV" '"result":"pass"' "同じ実行の stop 成功イベントも残る"

assert_summary
