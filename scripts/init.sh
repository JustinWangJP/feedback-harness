#!/usr/bin/env bash
# init.sh — フィードバックハーネスを任意のプロジェクトへ導入する。
#
# 使い方: bash scripts/init.sh <対象プロジェクトパス>
#
# Claude Code の skills / agents / hooks はプラグインが提供するので、ここでは
# 扱わない。このスクリプトが用意するのは、Codex IDE 拡張や汎用エージェントなど
# プラグインを利用できない環境が必要とする実ファイルと、各環境で共有する状態だけである。
#
# 動作:
# - scripts/(check.sh / checks/*.sh / check_file.sh / lib.sh / audit.sh / harness_config.py /
#   feedback_store.py / feedback_log.py / README.md / README.ja.md / README.zh-CN.md)をコピー
# - .feedback/ のシードを作成(rules.md は既存なら触らない。config.example.yaml
#   は毎回上書き — 雛形は本体側の更新を常に受け取るため。手元の config.yaml
#   は別ファイルなので上書きされない)
# - CLAUDE.md / AGENTS.md へ docs/pointer_*.md の管理ブロックを追加・更新
# - .gitignore へ _workspace/ を追記
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
使い方: bash scripts/init.sh <対象プロジェクトパス>

  <対象プロジェクトパス>  ハーネスを導入するプロジェクトのディレクトリ
  -h, --help              この使い方を表示する

Claude Code / Codex app・CLI でプラグインとして使う場合、このスクリプトは不要。
Codex IDE 拡張や他の汎用エージェントを併用する場合にだけ実行する。
exit 0 = 導入成功 / 2 = 引数・環境の誤り
USAGE
}
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  # 未知のオプションを対象パス扱いすると「対象が存在しません: --dry-run」に
  # なり、原因が引数だと気づけない
  -*) echo "ERROR: 不明なオプション: $1" >&2; usage >&2; exit 2 ;;
esac

DEST="${1:-}"

[[ -z "$DEST" ]] && { usage; exit 2; }
[[ -d "$DEST" ]] || { echo "ERROR: 対象が存在しません: $DEST"; exit 2; }
DEST="$(cd "$DEST" && pwd)"
[[ "$DEST" == "$SRC" ]] && { echo "ERROR: 自分自身には導入できません"; exit 2; }

echo "導入先: $DEST"

# scripts/ — Codex 等がリポジトリ相対で叩くための実体
mkdir -p "$DEST/scripts/checks"
# audit.sh も配る。scripts/README.md / README.ja.md / README.zh-CN.md が使い方を載せ、feedback_log.py の stats/report が
# 「bash scripts/audit.sh の実行を推奨」と案内するため、欠けると案内先が存在しなくなる
# harness_config.py も配る。check.sh / check_file.sh / audit.sh / feedback_log.py が
# 設定(.feedback/config.yaml)の読み込みに使う唯一のパーサのため、欠けると config が
# 読めないまま動く
cp "$SRC/scripts/check.sh" "$SRC/scripts/check_file.sh" "$SRC/scripts/lib.sh" \
   "$SRC/scripts/audit.sh" "$SRC/scripts/harness_config.py" \
   "$SRC/scripts/feedback_store.py" "$SRC/scripts/feedback_log.py" "$SRC/scripts/README.md" \
   "$SRC/scripts/README.ja.md" "$SRC/scripts/README.zh-CN.md" \
   "$DEST/scripts/"
cp "$SRC/scripts/checks/"*.sh "$DEST/scripts/checks/"

# harness_config.py / feedback_log.py は導入元で管理・検査済みのベンダー
# ファイルで、導入先の pyproject.toml [tool.ruff] の対象ではない。導入先の
# 設定ファイルを書き換える(=ユーザーの設定に手を出す)代わりに、ruff 自身が
# 読む file-level ディレクティブをファイルへ埋め込む(`ruff: noqa` は lint、
# `fmt: off`/`fmt: on` は format を丸ごと無効化する)。導入元(このリポジトリ)
# の同名ファイルには入れない — 自己ドッグフーディングの検査対象から外れるため、
# コピー後の $DEST 側だけに後挿入する
for f in harness_config.py feedback_store.py feedback_log.py; do
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
chmod 755 "$DEST/scripts/"*.sh "$DEST/scripts/checks/"*.sh "$DEST/scripts/feedback_log.py"
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

# CLAUDE.md / AGENTS.md — 管理マーカー付きポインタの追加・更新
# 導入元の CLAUDE.md / AGENTS.md 全文ではなく docs/pointer_*.md の断片を使う。
# 全文だと導入元のH1(プロジェクト名)と変更履歴が導入先に紛れ込む。
# 管理マーカー内だけを置換するため、利用者が前後に書いた内容は保持する。
# 旧版(マーカーなし)は、既知の見出しから既知の末尾行までを一度だけ移行する。
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

update_pointer() { # update_pointer <file> <heading> <fragment> <legacy-end-regex>
  local file="$1" heading="$2" frag="$3" legacy_end="$4"
  local rendered_fragment rendered_block install_date existing_date action
  rendered_fragment="$WORK/$(basename "$frag").rendered"
  rendered_block="$WORK/$(basename "$frag").managed"
  install_date="$(date +%Y-%m-%d)"
  if [[ -f "$DEST/$file" ]]; then
    existing_date="$(sed -nE 's/^\| ([0-9]{4}-[0-9]{2}-[0-9]{2}) \| フィードバックハーネス導入.*/\1/p' "$DEST/$file" | head -n1)"
    [[ -n "$existing_date" ]] && install_date="$existing_date"
  fi
  sed "s/{{INSTALL_DATE}}/$install_date/" "$SRC/$frag" > "$rendered_fragment"
  {
    echo '<!-- feedback-harness:pointer:start -->'
    cat "$rendered_fragment"
    echo '<!-- feedback-harness:pointer:end -->'
  } > "$rendered_block"

  if [[ -f "$DEST/$file" ]]; then
    action="$(python3 - "$DEST/$file" "$rendered_block" "$heading" "$legacy_end" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
block = Path(sys.argv[2]).read_text(encoding="utf-8")
heading = sys.argv[3]
legacy_end = sys.argv[4]
start_marker = "<!-- feedback-harness:pointer:start -->"
end_marker = "<!-- feedback-harness:pointer:end -->"
content = path.read_text(encoding="utf-8")

start_count = content.count(start_marker)
end_count = content.count(end_marker)
if start_count or end_count:
    if start_count != 1 or end_count != 1:
        print("ERROR: 管理マーカーが不整合です。該当ブロックを確認して再実行してください", file=sys.stderr)
        raise SystemExit(3)
    start = content.index(start_marker)
    end = content.index(end_marker, start) + len(end_marker)
    if end < len(content) and content[end] == "\n":
        end += 1
    content = content[:start] + block + content[end:]
    action = "管理ブロックを更新"
elif heading in content:
    start = content.index(heading)
    start = content.rfind("\n", 0, start) + 1
    match = re.search(legacy_end, content[start:], re.MULTILINE)
    if match is None:
        print(
            "ERROR: 旧ポインタの末尾を特定できません。既存ポインタを手動で削除して再実行してください。\n"
            "  この整理が要るのは init.sh が必要な環境(Codex IDE 拡張や他の汎用エージェントを併用する場合)だけです。\n"
            "  Claude Code または Codex app / CLI のプラグインだけで使うなら init.sh 自体が不要なため、この作業は不要です。",
            file=sys.stderr,
        )
        raise SystemExit(3)
    end = start + match.end()
    if end < len(content) and content[end] == "\n":
        end += 1
    content = content[:start] + block + content[end:]
    action = "旧ポインタを管理ブロックへ移行"
else:
    separator = "" if content.endswith("\n\n") else "\n" if content.endswith("\n") else "\n\n"
    content += separator + "---\n\n" + block
    action = "既存ファイルに管理ブロックを追記"

path.write_text(content, encoding="utf-8")
print(action)
PY
)"
    echo "  $file ... $action"
  else
    { echo "# $(basename "$DEST")"; echo; cat "$rendered_block"; } > "$DEST/$file"
    echo "  $file ... 管理ブロック付きで新規作成"
  fi
}
update_pointer "CLAUDE.md" "## ハーネス: フィードバックループ" \
  "docs/pointer_claude.md" '^\*\*ハーネス本体の更新:\*\*.*$'
update_pointer "AGENTS.md" \
  "## フィードバックハーネス — エージェント作業規約（Codex / 汎用エージェント向け）" \
  "docs/pointer_agents.md" '^今回の明示的な指示を優先し、矛盾があったことをユーザーに一言伝える。$'

# .gitignore — 中間生成物とローカル状態は追跡しない。
# .feedback/.last-check は Stop フックの検査スタンプ(mtime比較用)。共有すると
# 他マシンの時刻で「検査済み」と誤判定され、検査が飛ばされる。
# 判定は「ファイル全体に1行でもあればスキップ」ではなくエントリ単位で行う。
# 一括スキップだと、後から足したエントリ(.feedback/local/ など)が既存導入へ
# 永久に届かない。特に .feedback/local/ は個人設定で、共有されると事故になる。
IGNORE_ENTRIES=(
  "_workspace/|Harness working area (QAレポート等の中間生成物)"
  ".feedback/.last-check|Stop フックの検査スタンプ(ローカル状態)"
  ".feedback/events.jsonl|フック合否のイベントログ(マシン固有のノイズを共有しない)"
  ".feedback/.last-retro|棚卸しの基点(個人の運用リズム)"
  ".feedback/.last-audit|脆弱性監査の最終実行日(マシンローカル)"
  ".feedback/.state.lock|feedback CLI のrepository-wide lock(ローカル状態)"
  ".feedback/.transaction.json|中断されたfeedback更新の回復journal(ローカル状態)"
  ".feedback/local/|個人設定レイヤ(この端末だけの設定。共有設定に勝つ)"
)
ADDED=()
for entry in "${IGNORE_ENTRIES[@]}"; do
  pattern="${entry%%|*}"
  comment="${entry#*|}"
  if [[ -f "$DEST/.gitignore" ]] && grep -qxF "$pattern" "$DEST/.gitignore"; then
    continue
  fi
  { echo; echo "# $comment"; echo "$pattern"; } >> "$DEST/.gitignore"
  ADDED+=("$pattern")
done
if [[ ${#ADDED[@]} -eq 0 ]]; then
  echo "  .gitignore ... 記載済みのためスキップ"
else
  echo "  .gitignore ... ${ADDED[*]} を追記"
fi

echo
echo "導入完了。動作確認: cd \"$DEST\" && bash scripts/check.sh"
echo "Claude Code を使う場合は、あわせてプラグインを導入してください:"
echo "  /plugin marketplace add JustinWangJP/feedback-harness"
echo "  /plugin install feedback-harness@feedback-harness"
