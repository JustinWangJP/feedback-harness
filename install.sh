#!/usr/bin/env bash
# install.sh — フィードバックハーネスを任意のプロジェクトへ導入する。
#
# 使い方: bash install.sh <対象プロジェクトパス>
#
# 動作:
# - scripts/ と .claude/(agents, skills, settings.json)をコピー
# - .feedback/ のシード(rules.template.md → rules.md)を作成(既存なら触らない)
# - CLAUDE.md / AGENTS.md へ docs/pointer_*.md の断片を追記(なければ新規作成)
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
cp "$SRC/scripts/check.sh" "$SRC/scripts/check_file.sh" "$SRC/scripts/lib.sh" \
   "$SRC/scripts/feedback_log.py" "$SRC/scripts/README.md" "$DEST/scripts/"
cp "$SRC/scripts/hooks/post_edit.sh" "$SRC/scripts/hooks/on_stop.sh" "$DEST/scripts/hooks/"
# 755(+x ではなく明示指定)。シェルスクリプトの実行には読み取り権限が必要で、
# 導入元が 711 の場合に +x だと所有者以外が実行できない権限のまま複製される
chmod 755 "$DEST/scripts/"*.sh "$DEST/scripts/hooks/"*.sh "$DEST/scripts/feedback_log.py"
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
# rules.md は導入元の promote 済みルール(と導入先に存在しない出典ID)を持ち込まないよう、
# ヘッダのみのテンプレートをシードにする。template 自体も feedback_log.py が
# rules.md 再生成時に参照するためコピーする。
mkdir -p "$DEST/.feedback/log"
cp "$SRC/.feedback/rules.template.md" "$DEST/.feedback/rules.template.md"
[[ -f "$DEST/.feedback/rules.md" ]] || cp "$SRC/.feedback/rules.template.md" "$DEST/.feedback/rules.md"
echo "  .feedback/ ... OK"

# CLAUDE.md / AGENTS.md — ポインタの追記
# 導入元の CLAUDE.md / AGENTS.md 全文ではなく docs/pointer_*.md の断片を使う。
# 全文だと導入元のH1(プロジェクト名)と変更履歴が導入先に紛れ込む。
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

append_pointer() { # append_pointer <file> <marker> <fragment>
  local file="$1" marker="$2" frag="$3"
  local rendered
  rendered="$WORK/$(basename "$frag")"
  sed "s/{{INSTALL_DATE}}/$(date +%Y-%m-%d)/" "$SRC/$frag" > "$rendered"
  if [[ -f "$DEST/$file" ]]; then
    if grep -q "$marker" "$DEST/$file"; then
      echo "  $file ... ポインタ既存のためスキップ"
    else
      { echo; echo "---"; echo; cat "$rendered"; } >> "$DEST/$file"
      echo "  $file ... 既存ファイルに追記"
    fi
  else
    { echo "# $(basename "$DEST")"; echo; cat "$rendered"; } > "$DEST/$file"
    echo "  $file ... 新規作成"
  fi
}
append_pointer "CLAUDE.md" "ハーネス: フィードバックループ" "docs/pointer_claude.md"
append_pointer "AGENTS.md" "フィードバックハーネス" "docs/pointer_agents.md"

# .gitignore — _workspace/ は中間生成物なので追跡しない
if [[ -f "$DEST/.gitignore" ]] && grep -q '^_workspace/' "$DEST/.gitignore"; then
  echo "  .gitignore ... 記載済みのためスキップ"
else
  { echo; echo "# Harness working area (QAレポート等の中間生成物)"; echo "_workspace/"; } >> "$DEST/.gitignore"
  echo "  .gitignore ... _workspace/ を追記"
fi

echo
echo "導入完了。動作確認: cd \"$DEST\" && bash scripts/check.sh"
