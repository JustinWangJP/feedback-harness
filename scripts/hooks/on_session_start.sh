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

if [[ ! -f "$ROOT/.feedback/rules.md" ]]; then
  if [[ -f "$TEMPLATE" ]]; then
    cp "$TEMPLATE" "$ROOT/.feedback/rules.md" 2>/dev/null || exit 0
  else
    # テンプレートが同梱されていない場合の最小シード。
    # feedback_log.py の DEFAULT_RULES_HEADER と同じ役割。
    cat > "$ROOT/.feedback/rules.md" 2>/dev/null <<'SEED' || exit 0
# フィードバック由来ルール

エージェントはセッション開始時に必ずこのファイルを読むこと。

<!-- ここから下に promote されたルールが追記される -->
SEED
  fi
fi

exit 0
