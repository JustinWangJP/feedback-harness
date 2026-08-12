#!/usr/bin/env bash
# test_session_start_seed.sh — SessionStart フックによる .feedback/ シードを検証する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

HOOK="$REPO/scripts/hooks/on_session_start.sh"

# 1: .feedback/ が無いプロジェクトにシードされる
mkdir -p "$WORK/fresh"
echo '{}' | CLAUDE_PROJECT_DIR="$WORK/fresh" bash "$HOOK"
assert_eq "0" "$?" "シード実行が成功する"
assert_file_exists "$WORK/fresh/.feedback/rules.md" "rules.md が作られる"
assert_file_exists "$WORK/fresh/.feedback/log" "log/ が作られる"
SEEDED="$(cat "$WORK/fresh/.feedback/rules.md")"
assert_contains "$SEEDED" "フィードバック由来ルール" "テンプレート内容でシードされる"

# 2: 既存の .feedback/rules.md は上書きしない
mkdir -p "$WORK/existing/.feedback/log"
printf 'MY OWN RULES\n' > "$WORK/existing/.feedback/rules.md"
echo '{}' | CLAUDE_PROJECT_DIR="$WORK/existing" bash "$HOOK"
assert_eq "MY OWN RULES" "$(cat "$WORK/existing/.feedback/rules.md")" "既存 rules.md を保護する"

# 3: 書き込めない場所でもセッションをブロックしない
mkdir -p "$WORK/readonly"
chmod 500 "$WORK/readonly"
echo '{}' | CLAUDE_PROJECT_DIR="$WORK/readonly" bash "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "書き込み不可でも exit 0"
chmod 700 "$WORK/readonly"

assert_summary
