#!/usr/bin/env bash
# test_entry_frontmatter.sh — エントリの frontmatter が「先頭ブロックだけ」で
# あることを、書き込み(add)→読み取り(list/promote/search)の往復で固定する。
#
# `---` を見るたびに frontmatter モードを反転する実装では、detail に水平線と
# `キー: 値` を書いたエントリの id / status / category が本文で上書きされ、
# cmd_add が印字した id では promote できなくなる(記録が addressable でなくなる)。
# エージェントが detail に区切り線を書くのは日常的な形式なので、往復で固定する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/project"
( cd "$WORK/project" && git init -q . )
export CLAUDE_PROJECT_DIR="$WORK/project"

# 配布される入口(feedback.sh)を通す。.py の直接実行は Git Bash で解決できない
fb() { bash "$REPO/scripts/feedback.sh" "$@"; }
extract_id() { sed -n 's/.*(id=\(.*\))$/\1/p'; }

# --- 1. 本文中の区切り線が frontmatter を再開しない ---
DETAIL="$(printf '%s\n' "調査メモ" "---" "id: 99999999" "status: closed" \
  "category: hacked" "signal: workflow" "対象: scripts/check.sh の run_stage")"
ADD_OUT="$(fb add --category style --summary "区切り線を含む指摘" --detail "$DETAIL")"
ID="$(printf '%s' "$ADD_OUT" | extract_id)"
if [[ -z "$ID" ]]; then
  fail "add の出力から id を取り出せない: $ADD_OUT"
  assert_summary
fi

LIST="$(fb list --status all)"
assert_contains "$LIST" " $ID " "印字された id でエントリが一覧に出る"
assert_not_contains "$LIST" "99999999" "本文の id: 行がメタデータを上書きしない"
assert_not_contains "$LIST" "hacked" "本文の category: 行がメタデータを上書きしない"
assert_contains "$(fb list --status open)" " $ID " "本文の status: 行で状態が変わらない"

# 本文は失われない(区切り線より後ろも body に残る)
assert_contains "$(fb search "run_stage")" "$ID" "区切り線より後ろの本文も検索できる"

# 記録した id でそのまま昇華できること — 欠陥の実害はここに出る
PROMOTE_OUT="$(fb promote "$ID" --rule "区切り線を含む指摘のルール" 2>&1)"
assert_contains "$PROMOTE_OUT" "promoted:" "印字された id で promote できる: $PROMOTE_OUT"
assert_contains "$(cat "$WORK/project/.feedback/rules.md")" "区切り線を含む指摘のルール" \
  "昇華したルールが rules.md に載る"

# --- 2. 通常のエントリが従来どおり読める(往復) ---
ID2="$(fb add --category testing --summary "通常の指摘" --detail "本文だけ" --signal failure | extract_id)"
LIST2="$(fb list --status open)"
assert_contains "$LIST2" "testing" "category が frontmatter から読める"
assert_contains "$LIST2" "通常の指摘" "本文の見出しがタイトルとして読める"
assert_contains "$(fb list --signal failure)" " $ID2 " "signal が frontmatter から読める"

# --- 3. close が追記する理由ブロックが状態を壊さない ---
# close は本文末尾へ "---\nclose理由: …" を追記する。これは frontmatter では
# ないため、status は close が書き換えた値のままでなければならない
fb close "$ID2" --reason "一回限りの事情" >/dev/null
assert_contains "$(fb list --status closed)" " $ID2 " "close 後も状態を正しく読める"
assert_contains "$(fb search "一回限りの事情")" "$ID2" "close理由が本文として残る"

assert_summary
