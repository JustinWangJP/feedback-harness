#!/usr/bin/env bash
# init.sh — フィードバックハーネスを任意のプロジェクトへ導入する。
#
# 使い方: bash scripts/init.sh <対象プロジェクトパス>
#
# Claude Code の skills / agents / hooks はプラグインが提供するので、ここでは
# 扱わない。このスクリプトが用意するのは、プラグインを持たない環境(Codex 等)が
# 必要とする実ファイルと、両環境で共有する状態だけである。
#
# 動作:
# - scripts/(check.sh / check_file.sh / lib.sh / audit.sh / harness_config.py /
#   feedback_log.py)をコピー
# - .feedback/ のシードを作成(rules.md は既存なら触らない。config.example.yaml
#   は毎回上書き — 雛形は本体側の更新を常に受け取るため。手元の config.yaml
#   は別ファイルなので上書きされない)
# - CLAUDE.md / AGENTS.md へ docs/pointer_*.md の断片を追記(なければ新規作成)
# - .gitignore へ _workspace/ を追記
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-}"

[[ -z "$DEST" ]] && { echo "使い方: bash scripts/init.sh <対象プロジェクトパス>"; exit 2; }
[[ -d "$DEST" ]] || { echo "ERROR: 対象が存在しません: $DEST"; exit 2; }
DEST="$(cd "$DEST" && pwd)"
[[ "$DEST" == "$SRC" ]] && { echo "ERROR: 自分自身には導入できません"; exit 2; }

echo "導入先: $DEST"

# scripts/ — Codex 等がリポジトリ相対で叩くための実体
mkdir -p "$DEST/scripts"
# audit.sh も配る。scripts/README.md が使い方を載せ、feedback_log.py の stats/report が
# 「bash scripts/audit.sh の実行を推奨」と案内するため、欠けると案内先が存在しなくなる
# harness_config.py も配る。check.sh / check_file.sh / audit.sh / feedback_log.py が
# 設定(.feedback/config.yaml)の読み込みに使う唯一のパーサのため、欠けると config が
# 読めないまま動く
cp "$SRC/scripts/check.sh" "$SRC/scripts/check_file.sh" "$SRC/scripts/lib.sh" \
   "$SRC/scripts/audit.sh" "$SRC/scripts/harness_config.py" \
   "$SRC/scripts/feedback_log.py" "$SRC/scripts/README.md" \
   "$DEST/scripts/"

# harness_config.py / feedback_log.py は導入元で管理・検査済みのベンダー
# ファイルで、導入先の pyproject.toml [tool.ruff] の対象ではない。導入先の
# 設定ファイルを書き換える(=ユーザーの設定に手を出す)代わりに、ruff 自身が
# 読む file-level ディレクティブをファイルへ埋め込む(`ruff: noqa` は lint、
# `fmt: off`/`fmt: on` は format を丸ごと無効化する)。導入元(このリポジトリ)
# の同名ファイルには入れない — 自己ドッグフーディングの検査対象から外れるため、
# コピー後の $DEST 側だけに後挿入する
for f in harness_config.py feedback_log.py; do
  tmp="$(mktemp)"
  {
    head -n1 "$DEST/scripts/$f"
    echo "# ruff: noqa -- ハーネス配布ファイル(導入元で管理・検査済み。導入先の ruff 設定の対象外)"
    echo "# fmt: off"
    tail -n +2 "$DEST/scripts/$f"
    echo "# fmt: on"
  } > "$tmp"
  mv "$tmp" "$DEST/scripts/$f"
done

# 755(+x ではなく明示指定)。シェルスクリプトの実行には読み取り権限が必要で、
# 導入元が 711 の場合に +x だと所有者以外が実行できない権限のまま複製される
chmod 755 "$DEST/scripts/"*.sh "$DEST/scripts/feedback_log.py"
echo "  scripts/ ... OK"

# Claude Code 向けの skills / agents / hooks はプラグインが提供する
echo "  .claude/ ... スキップ(Claude Code ではプラグインを使ってください)"

# .feedback/
# rules.md は導入元の promote 済みルール(と導入先に存在しない出典ID)を持ち込まないよう、
# ヘッダのみのテンプレートをシードにする。template 自体も feedback_log.py が
# rules.md 再生成時に参照するためコピーする。
# config.yaml は自動生成しない — 空の雛形が commit されると「設定した」のか
# 「置いただけ」なのか区別できなくなるため、config.example.yaml のコピーで始める
mkdir -p "$DEST/.feedback/log"
cp "$SRC/.feedback/rules.template.md" "$DEST/.feedback/rules.template.md"
[[ -f "$DEST/.feedback/rules.md" ]] || cp "$SRC/.feedback/rules.template.md" "$DEST/.feedback/rules.md"
cp "$SRC/.feedback/config.example.yaml" "$DEST/.feedback/config.example.yaml"
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

# .gitignore — 中間生成物とローカル状態は追跡しない。
# .feedback/.last-check は Stop フックの検査スタンプ(mtime比較用)。共有すると
# 他マシンの時刻で「検査済み」と誤判定され、検査が飛ばされる。
if [[ -f "$DEST/.gitignore" ]] && grep -q '^_workspace/' "$DEST/.gitignore"; then
  echo "  .gitignore ... 記載済みのためスキップ"
else
  {
    echo
    echo "# Harness working area (QAレポート等の中間生成物)"
    echo "_workspace/"
    echo "# Stop フックの検査スタンプ(ローカル状態)"
    echo ".feedback/.last-check"
  } >> "$DEST/.gitignore"
  echo "  .gitignore ... _workspace/ と .feedback/.last-check を追記"
fi

echo
echo "導入完了。動作確認: cd \"$DEST\" && bash scripts/check.sh"
echo "Claude Code を使う場合は、あわせてプラグインを導入してください:"
echo "  /plugin marketplace add JustinWangJP/feedback-harness"
echo "  /plugin install feedback-harness@feedback-harness"
