#!/usr/bin/env bash
# test_root_cause_consistency.sh — 運用中の文書・スキル・CLIで根因分類がずれないことを検証する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

CAUSES=("文脈欠落" "指示欠陥" "実行誤り" "モデル限界" "未判定")
FILES=(
  "README.md"
  "AGENTS.md"
  "docs/pointer_agents.md"
  "docs/pointer_claude.md"
  "skills/capture-feedback/SKILL.md"
  "agents/feedback-curator.md"
  "scripts/feedback_log.py"
)

for file in "${FILES[@]}"; do
  content="$(cat "$REPO/$file")"
  for cause in "${CAUSES[@]}"; do
    assert_contains "$content" "$cause" "$file に根因「${cause}」が定義されている"
  done
done

CLAUDE_POINTER="$(cat "$REPO/docs/pointer_claude.md")"
assert_contains "$CLAUDE_POINTER" '`init.sh` だけで導入した場合' \
  "Claude ポインタが init.sh 単独導入を区別する"
assert_contains "$CLAUDE_POINTER" 'bash scripts/check_file.sh <編集したファイル>' \
  "Claude ポインタに Hooks 無効時の単一ファイル検査がある"
assert_contains "$CLAUDE_POINTER" 'bash scripts/check.sh; echo "exit=$?"' \
  "Claude ポインタに Hooks 無効時のフルチェックがある"

assert_summary
