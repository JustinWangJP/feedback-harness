#!/usr/bin/env bash
# test_plugin_manifest.sh — プラグインのマニフェストと構成を検証する。
#
# Claude / Codex の検証 CLI が無い環境でも動くよう、JSON の妥当性と
# 参照先の実在は python3 で自前に確認する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

# 1: JSON として妥当
for f in .claude-plugin/plugin.json .codex-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$REPO/$f" 2>/dev/null; then
    :
  else
    fail "$f が妥当な JSON でない"
  fi
done

# 2: Claude / Codex のプラグイン名・バージョンとマーケットプレイス名
assert_eq "feedback-harness" \
  "$(tpy -c "import json,sys;print(json.load(open(sys.argv[1]))['name'])" "$REPO/.claude-plugin/plugin.json")" \
  "Claude プラグイン名"
assert_eq "feedback-harness" \
  "$(tpy -c "import json,sys;print(json.load(open(sys.argv[1]))['name'])" "$REPO/.codex-plugin/plugin.json")" \
  "Codex プラグイン名"
assert_eq "feedback-harness" \
  "$(tpy -c "import json,sys;print(json.load(open(sys.argv[1]))['name'])" "$REPO/.claude-plugin/marketplace.json")" \
  "マーケットプレイス名"
assert_eq \
  "$(tpy -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$REPO/.claude-plugin/plugin.json")" \
  "$(tpy -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$REPO/.codex-plugin/plugin.json")" \
  "Claude / Codex のプラグインバージョンが一致する"
assert_eq "0.1.9" \
  "$(tpy -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$REPO/.claude-plugin/plugin.json")" \
  "公開プラグインバージョンが0.1.9である"

CODEX_MANIFEST_ERROR="$(tpy - "$REPO/.codex-plugin/plugin.json" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1]))
errors = []
if manifest.get("skills") != "./skills/":
    errors.append("skills must point to ./skills/")
interface = manifest.get("interface", {})
for key in ("displayName", "shortDescription", "longDescription", "developerName", "category"):
    if not interface.get(key):
        errors.append(f"interface.{key} is required")
print("; ".join(errors))
PY
)"
assert_eq "" "$CODEX_MANIFEST_ERROR" "Codex マニフェストの必須フィールド"

# 3: コンポーネントが規定の場所にある
assert_file_exists "$REPO/skills/apply-feedback/SKILL.md" "apply-feedback"
assert_file_exists "$REPO/skills/capture-feedback/SKILL.md" "capture-feedback"
assert_file_exists "$REPO/skills/feedback-loop/SKILL.md" "feedback-loop"
assert_file_exists "$REPO/.codex-plugin/plugin.json" "Codex plugin manifest"
assert_file_exists "$REPO/agents/feedback-curator.md" "feedback-curator"
assert_file_exists "$REPO/agents/harness-qa.md" "harness-qa"
assert_file_absent "$REPO/.claude/skills" "旧 .claude/skills が残っていない"
assert_file_absent "$REPO/.claude/agents" "旧 .claude/agents が残っていない"

# 4: hooks.json が参照するスクリプトが実在する
MISSING="$(tpy - "$REPO" <<'PY'
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

# 5: 開発用 .claude/settings.json と配布用 hooks.json が同じイベント構造
#    (どのイベントに、どのスクリプトが、どの matcher・timeout で紐づくか)を指す
#    (二重管理なので、片方だけ直してもう片方が古いまま残るのを防ぐ。
#     スクリプト名の集合比較だけでは「イベントの取り違え」や「timeout だけ食い違う」
#     ドリフトを見逃すため、イベントごとに正規化した構造で突き合わせる。
#     ${CLAUDE_PLUGIN_ROOT} と $CLAUDE_PROJECT_DIR のプレフィックス差は
#     正当な差異なので、コマンド全体ではなくスクリプトのベース名だけを比較する)
NORM_A="$(tpy - "$REPO/.claude/settings.json" <<'PY'
import json, re, sys

def normalize(path):
    cfg = json.load(open(path))
    out = {}
    for event, entries in cfg.get("hooks", {}).items():
        norm_entries = []
        for entry in entries:
            matcher = entry.get("matcher", "")
            hooks = []
            for hook in entry.get("hooks", []):
                m = re.search(r"([a-z_]+\.sh)", hook.get("command", ""))
                script = m.group(1) if m else None
                hooks.append({"script": script, "timeout": hook.get("timeout")})
            hooks.sort(key=lambda h: (h["script"] or "", h["timeout"] if h["timeout"] is not None else -1))
            norm_entries.append({"matcher": matcher, "hooks": hooks})
        norm_entries.sort(key=lambda e: (e["matcher"], json.dumps(e["hooks"], sort_keys=True)))
        out[event] = norm_entries
    return out

print(json.dumps(normalize(sys.argv[1]), sort_keys=True))
PY
)"
NORM_B="$(tpy - "$REPO/hooks/hooks.json" <<'PY'
import json, re, sys

def normalize(path):
    cfg = json.load(open(path))
    out = {}
    for event, entries in cfg.get("hooks", {}).items():
        norm_entries = []
        for entry in entries:
            matcher = entry.get("matcher", "")
            hooks = []
            for hook in entry.get("hooks", []):
                m = re.search(r"([a-z_]+\.sh)", hook.get("command", ""))
                script = m.group(1) if m else None
                hooks.append({"script": script, "timeout": hook.get("timeout")})
            hooks.sort(key=lambda h: (h["script"] or "", h["timeout"] if h["timeout"] is not None else -1))
            norm_entries.append({"matcher": matcher, "hooks": hooks})
        norm_entries.sort(key=lambda e: (e["matcher"], json.dumps(e["hooks"], sort_keys=True)))
        out[event] = norm_entries
    return out

print(json.dumps(normalize(sys.argv[1]), sort_keys=True))
PY
)"
# 開発用 settings.json に hooks が無いのは、このリポジトリ自身がプラグイン導入へ
# 移行した状態(enabledPlugins で自己ドッグフーディングする)。両方に定義を置くと
# Stop のたびに check.sh が二重に走るため、移行後は dev 側を空にするのが正しい。
# 比較対象が存在しない状態を「ドリフト」と呼ぶことはできないので、その場合は検証を飛ばす。
if [[ "$NORM_A" == "{}" ]]; then
  echo "    SKIP: 開発用フック定義なし(プラグイン導入で自己ドッグフーディング中)" >&2
else
  assert_eq "$NORM_A" "$NORM_B" "開発用と配布用のフック定義が同じイベント構造(スクリプト・matcher・timeout)を指す"
fi

assert_summary
