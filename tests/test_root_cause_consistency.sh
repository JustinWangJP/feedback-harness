#!/usr/bin/env bash
# test_root_cause_consistency.sh — 運用中の文書・スキル・CLIで根因分類がずれないことを検証する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

CAUSES=("文脈欠落" "指示欠陥" "実行誤り" "モデル限界" "未判定")
# AGENTS.md C03「分類語彙は参照している全ファイルを同じ変更で更新する」の
# 対象には README の各言語版も含まれる。README.md だけを見ていると、翻訳版だけが
# 旧分類のまま取り残されてもテストは緑のままになる(語彙は訳さず原語のまま載せる方針)
FILES=(
  "README.md"
  "README.ja.md"
  "README.zh-CN.md"
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

# init は環境によって不要になる。この要否が文言変更で静かに失われると、
# プラグインのみの利用者へ不要な手作業を必須として案内する失敗が再発する
# (出典: .feedback/log/20260820-000443)
INIT_CMD="$(cat "$REPO/commands/init.md")"
assert_contains "$INIT_CMD" 'Codex IDE 拡張' \
  "init コマンドが init.sh を要する環境を明示する"
assert_contains "$INIT_CMD" '実行不要' \
  "init コマンドがプラグインのみの利用では不要と明示する"

# 停止メッセージも同じ規約に従う(案内文・エラー文にも環境別の要否を書く)
INIT_SH="$(cat "$REPO/scripts/init.sh")"
assert_contains "$INIT_SH" 'init.sh が必要な環境' \
  "init.sh の停止メッセージが環境別の要否に触れる"

assert_summary
