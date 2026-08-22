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

# 1: skills/ と agents/ に、ハーネス側スクリプトの裸参照が残っていない。
# 対象は feedback_log.py と init.sh — どちらもプラグイン側にしか無く、
# 導入先の相対パスでは解決できない(init.sh に至っては導入先の scripts/ を
# 作る側なので、実行時点では存在しない)。
# check.sh / check_file.sh は init.sh が導入先へ展開した後に
# 「導入先で」叩くものなので、相対パスのままが正しく、ここでは禁じない。
BARE="$(grep -rnE 'scripts/(feedback_log\.py|init\.sh)' "$REPO/skills" "$REPO/agents" 2>/dev/null \
  | grep -v 'CLAUDE_PLUGIN_ROOT' || true)"
assert_eq "" "$BARE" "skills/agents に裸の scripts/ 参照が残っていない"

# 2: 置換後の表記が実際に使われている
HAS_PLUGIN_ROOT="$(grep -rl 'CLAUDE_PLUGIN_ROOT' "$REPO/skills" "$REPO/agents" | wc -l | tr -d ' ')"
if [[ "$HAS_PLUGIN_ROOT" -lt 3 ]]; then
  fail "CLAUDE_PLUGIN_ROOT を使うファイルが少なすぎる($HAS_PLUGIN_ROOT 件)"
fi

# 2b: skills/ と agents/ は両環境で展開される。Codex はスキル本文で
# CLAUDE_PLUGIN_ROOT を設定しない(互換変数は Hooks のみ)ため、
# 裸の ${CLAUDE_PLUGIN_ROOT} は Codex で空へ潰れ "/scripts/..." になる。
# PLUGIN_ROOT を先に見るフォールバック形式を必須とする。
BARE_CLAUDE="$(grep -rn 'CLAUDE_PLUGIN_ROOT' "$REPO/skills" "$REPO/agents" 2>/dev/null \
  | grep -v 'PLUGIN_ROOT:-' || true)"
assert_eq "" "$BARE_CLAUDE" \
  "skills/agents のプラグインルート参照が \${PLUGIN_ROOT:-\${CLAUDE_PLUGIN_ROOT:-}} 形式に統一されている"

# 3: Codex 向けポインタは据え置き(placeholder を書いてはいけない)
POINTER="$(cat "$REPO/docs/pointer_agents.md")"
assert_contains "$POINTER" "scripts/feedback_log.py" "ポインタはリポジトリ相対のまま"
case "$POINTER" in
  *CLAUDE_PLUGIN_ROOT*) fail "pointer_agents.md に CLAUDE_PLUGIN_ROOT を書いてはいけない" ;;
esac

assert_summary
