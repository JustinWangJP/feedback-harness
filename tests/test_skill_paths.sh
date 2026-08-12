#!/usr/bin/env bash
# test_skill_paths.sh — skill/agent 本文のコマンド表記がプラグイン対応であることを検証する。
#
# skills/ と agents/ の本文では ${CLAUDE_PLUGIN_ROOT} が実パスへ展開される。
# 一方 docs/pointer_agents.md は Codex 向けで展開されないため、
# リポジトリ相対のままであることを逆向きに固定する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

# 1: skills/ と agents/ に裸の "scripts/feedback_log.py" が残っていない
BARE="$(grep -rn 'scripts/feedback_log\.py' "$REPO/skills" "$REPO/agents" 2>/dev/null \
  | grep -v 'CLAUDE_PLUGIN_ROOT' || true)"
assert_eq "" "$BARE" "skills/agents に裸の scripts/ 参照が残っていない"

# 2: 置換後の表記が実際に使われている
HAS_PLUGIN_ROOT="$(grep -rl 'CLAUDE_PLUGIN_ROOT' "$REPO/skills" "$REPO/agents" | wc -l | tr -d ' ')"
if [[ "$HAS_PLUGIN_ROOT" -lt 3 ]]; then
  fail "CLAUDE_PLUGIN_ROOT を使うファイルが少なすぎる($HAS_PLUGIN_ROOT 件)"
fi

# 3: Codex 向けポインタは据え置き(placeholder を書いてはいけない)
POINTER="$(cat "$REPO/docs/pointer_agents.md")"
assert_contains "$POINTER" "scripts/feedback_log.py" "ポインタはリポジトリ相対のまま"
case "$POINTER" in
  *CLAUDE_PLUGIN_ROOT*) fail "pointer_agents.md に CLAUDE_PLUGIN_ROOT を書いてはいけない" ;;
esac

assert_summary
