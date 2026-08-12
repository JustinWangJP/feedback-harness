#!/usr/bin/env bash
# test_plugin_manifest.sh — プラグインのマニフェストと構成を検証する。
#
# claude CLI が無い環境でも動くよう、JSON の妥当性と参照先の実在は
# python3 で自前に確認する(claude plugin validate は Step 6 で別途実行する)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

# 1: JSON として妥当
for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$REPO/$f" 2>/dev/null; then
    :
  else
    fail "$f が妥当な JSON でない"
  fi
done

# 2: プラグイン名とマーケットプレイス名
assert_eq "feedback-harness" \
  "$(python3 -c "import json;print(json.load(open('$REPO/.claude-plugin/plugin.json'))['name'])")" \
  "プラグイン名"
assert_eq "feedback-harness" \
  "$(python3 -c "import json;print(json.load(open('$REPO/.claude-plugin/marketplace.json'))['name'])")" \
  "マーケットプレイス名"

# 3: コンポーネントが規定の場所にある
assert_file_exists "$REPO/skills/apply-feedback/SKILL.md" "apply-feedback"
assert_file_exists "$REPO/skills/capture-feedback/SKILL.md" "capture-feedback"
assert_file_exists "$REPO/skills/feedback-loop/SKILL.md" "feedback-loop"
assert_file_exists "$REPO/agents/feedback-curator.md" "feedback-curator"
assert_file_exists "$REPO/agents/harness-qa.md" "harness-qa"
assert_file_absent "$REPO/.claude/skills" "旧 .claude/skills が残っていない"
assert_file_absent "$REPO/.claude/agents" "旧 .claude/agents が残っていない"

# 4: hooks.json が参照するスクリプトが実在する
MISSING="$(python3 - "$REPO" <<'PY'
import json, re, sys, pathlib
repo = pathlib.Path(sys.argv[1])
cfg = json.load(open(repo / "hooks" / "hooks.json"))
missing = []
for entries in cfg["hooks"].values():
    for entry in entries:
        for hook in entry["hooks"]:
            for path in re.findall(r'\$\{CLAUDE_PLUGIN_ROOT\}"?(/\S+\.sh)', hook["command"]):
                if not (repo / path.lstrip("/")).is_file():
                    missing.append(path)
print(" ".join(missing))
PY
)"
assert_eq "" "$MISSING" "hooks.json の参照先が実在する"

# 5: 開発用 .claude/settings.json と配布用 hooks.json が同じスクリプトを指す
#    (二重管理なので、片方だけ直してもう片方が古いまま残るのを防ぐ)
NAMES_A="$(python3 -c "
import json,re
cfg=json.load(open('$REPO/.claude/settings.json'))
print(' '.join(sorted(set(re.findall(r'([a-z_]+\.sh)', json.dumps(cfg))))))
")"
NAMES_B="$(python3 -c "
import json,re
cfg=json.load(open('$REPO/hooks/hooks.json'))
print(' '.join(sorted(set(re.findall(r'([a-z_]+\.sh)', json.dumps(cfg))))))
")"
assert_eq "$NAMES_A" "$NAMES_B" "開発用と配布用のフック定義が同じスクリプトを指す"

assert_summary
