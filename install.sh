#!/usr/bin/env bash
# install.sh — フィードバックハーネスを任意のプロジェクトへ導入する。
#
# 使い方: bash install.sh <対象プロジェクトパス>
#
# 動作:
# - scripts/ と .claude/(agents, skills, settings.json)をコピー
# - .feedback/ のシード(rules.md)を作成(既存なら触らない)
# - CLAUDE.md / AGENTS.md は既存があれば追記、なければ新規作成
# - 既存の .claude/settings.json がある場合は上書きせず .suggested として置く
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-}"

[[ -z "$DEST" ]] && { echo "使い方: bash install.sh <対象プロジェクトパス>"; exit 2; }
[[ -d "$DEST" ]] || { echo "ERROR: 対象が存在しません: $DEST"; exit 2; }
DEST="$(cd "$DEST" && pwd)"
[[ "$DEST" == "$SRC" ]] && { echo "ERROR: 自分自身には導入できません"; exit 2; }

echo "導入先: $DEST"

# scripts/
mkdir -p "$DEST/scripts/hooks"
cp "$SRC/scripts/check.sh" "$SRC/scripts/check_file.sh" "$SRC/scripts/feedback_log.py" "$DEST/scripts/"
cp "$SRC/scripts/hooks/post_edit.sh" "$SRC/scripts/hooks/on_stop.sh" "$DEST/scripts/hooks/"
chmod +x "$DEST/scripts/"*.sh "$DEST/scripts/hooks/"*.sh "$DEST/scripts/feedback_log.py"
echo "  scripts/ ... OK"

# .claude/agents + skills
mkdir -p "$DEST/.claude/agents"
cp "$SRC/.claude/agents/"*.md "$DEST/.claude/agents/"
for sk in capture-feedback apply-feedback feedback-loop; do
  mkdir -p "$DEST/.claude/skills/$sk"
  cp "$SRC/.claude/skills/$sk/SKILL.md" "$DEST/.claude/skills/$sk/"
done
echo "  .claude/agents, .claude/skills ... OK"

# settings.json (Hooks)
if [[ -f "$DEST/.claude/settings.json" ]]; then
  cp "$SRC/.claude/settings.json" "$DEST/.claude/settings.json.suggested"
  echo "  .claude/settings.json は既存のため settings.json.suggested を作成 — Hooks設定を手動でマージしてください"
else
  cp "$SRC/.claude/settings.json" "$DEST/.claude/settings.json"
  echo "  .claude/settings.json ... OK"
fi

# .feedback/
mkdir -p "$DEST/.feedback/log"
[[ -f "$DEST/.feedback/rules.md" ]] || cp "$SRC/.feedback/rules.md" "$DEST/.feedback/rules.md"
echo "  .feedback/ ... OK"

# CLAUDE.md / AGENTS.md — ポインタの追記
append_pointer() { # append_pointer <file> <marker> <src-file>
  local file="$1" marker="$2" srcfile="$3"
  if [[ -f "$DEST/$file" ]]; then
    if grep -q "$marker" "$DEST/$file"; then
      echo "  $file ... ポインタ既存のためスキップ"
    else
      { echo; echo "---"; echo; cat "$SRC/$srcfile"; } >> "$DEST/$file"
      echo "  $file ... 既存ファイルに追記"
    fi
  else
    cp "$SRC/$srcfile" "$DEST/$file"
    echo "  $file ... 新規作成"
  fi
}
append_pointer "CLAUDE.md" "ハーネス: フィードバックループ" "CLAUDE.md"
append_pointer "AGENTS.md" "フィードバックハーネス" "AGENTS.md"

echo
echo "導入完了。動作確認: cd \"$DEST\" && bash scripts/check.sh"
