#!/usr/bin/env bash
# on_session_start.sh — Claude Code SessionStart フック。
#
# プラグインのみで導入したプロジェクトには .feedback/ を作る担い手がいない
# (init.sh を実行するのは Codex 併用時だけ)。ここで一度だけシードする。
#
# 既存の .feedback/ には一切触れない。失敗してもセッションはブロックしない。
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$DIR/../lib.sh"

cat >/dev/null 2>&1 || true   # フック入力のJSONは使わないが読み捨てる

ROOT="$(harness_project_root)" || exit 0
TEMPLATE="$DIR/../../.feedback/rules.template.md"

mkdir -p "$ROOT/.feedback/log" 2>/dev/null || exit 0

# テンプレートが無い場合はここで代替の rules.md を書かない。テンプレートは
# バンドル資産なので、不在は「導入が壊れている」ことを意味し、ここで別内容の
# 最小シードを書くと scripts/feedback_log.py の DEFAULT_RULES_HEADER と内容が
# 分岐する(3箇所目のコピーを増やさない)。安全網は feedback_log.py 側に既にある。
if [[ ! -f "$ROOT/.feedback/rules.md" && -f "$TEMPLATE" ]]; then
  cp "$TEMPLATE" "$ROOT/.feedback/rules.md" 2>/dev/null || exit 0
fi

exit 0
