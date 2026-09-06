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

# --- 4. 本文中の `status_changed:` が frontmatter の更新を横取りしない ---
# updated_status_text は close / promote / merge / retire が共有する。
# 「フィールドが既にあるか」を全文で判定すると、detail や理由に
# `status_changed: 2020-01-01` という文言があるだけで既存とみなし、
# frontmatter へ追加せず**本文側の日付**を置換してしまう。実害は2つあり、
# どちらも静かに起きるので両方を固定する:
#   (a) 記録した文言が黙って書き換わる
#   (b) frontmatter に status_changed が付かず、report の close・retire 節から
#       そのエントリが永久に消える(status_changed >= since で絞るため)
TODAY="$(date +%F)"
ID3="$(fb add --category workflow --summary "frontmatter の注記" \
  --detail "旧テンプレートに status_changed: 2020-01-01 の行が混じっていた" | extract_id)"
fb close "$ID3" --reason "一回限りの事情" >/dev/null
ENTRY3="$(cat "$WORK/project/.feedback/log/$ID3"-*.md)"
# 先頭 frontmatter ブロックだけを取り出す(1行目の --- の次から、閉じの --- まで)
FRONT3="$(printf '%s\n' "$ENTRY3" | awk 'NR>1 && /^---[[:space:]]*$/{exit} NR>1{print}')"
assert_contains "$FRONT3" "status_changed: $TODAY" \
  "本文に status_changed の文言があっても frontmatter へ追加される: $FRONT3"
assert_contains "$ENTRY3" "status_changed: 2020-01-01" \
  "本文に記録した日付が書き換わらない: $ENTRY3"
# 節を切り出してから照合する。report 全文への部分一致では、同じ id が
# 「新規エントリ」節にも出るため欠陥があっても成立してしまう(実際、欠陥を
# 再注入した最初の版はこのアサーションだけ緑のままだった)
REPORT3="$(fb report --since "$TODAY" | sed -n '/^## close・retire$/,/^## /p')"
assert_contains "$REPORT3" "$ID3" \
  "close したエントリが report の close・retire 節に出る: $REPORT3"

# frontmatter に絞っても、部分文字列の置換は「他のキーの値」に引っかかる。
# --category は自由テキストで、しかも cmd_add の並びでは status より前に出る。
# 値に `status: open` と書けばそちらが先に一致し、category が壊れて status は
# 元のまま残る(close は成功したと report する)。キー名で行を特定する契約の回帰。
ID5="$(fb add --category "testing (status: open のまま)" --summary "値にstatusを含む指摘" \
  --detail "本文" | extract_id)"
fb close "$ID5" --reason "一回限りの事情" >/dev/null
ENTRY5="$(cat "$WORK/project/.feedback/log/$ID5"-*.md)"
FRONT5="$(printf '%s\n' "$ENTRY5" | awk 'NR>1 && /^---[[:space:]]*$/{exit} NR>1{print}')"
assert_contains "$FRONT5" "status: closed" "他キーの値ではなく status 行が書き換わる: $FRONT5"
assert_contains "$FRONT5" "category: testing (status: open のまま)" \
  "category の値が壊れない: $FRONT5"
assert_contains "$(fb list --status closed)" " $ID5 " "状態が closed として読める"

# promote 経路も同じ関数を通る(close だけ直して他が残る形を防ぐ)
ID4="$(fb add --category testing --summary "昇華する注記" \
  --detail "手順書に status_changed: 2019-12-31 と書かれていた" | extract_id)"
fb promote "$ID4" --rule "本文の日付を書き換えない" >/dev/null
ENTRY4="$(cat "$WORK/project/.feedback/log/$ID4"-*.md)"
FRONT4="$(printf '%s\n' "$ENTRY4" | awk 'NR>1 && /^---[[:space:]]*$/{exit} NR>1{print}')"
assert_contains "$FRONT4" "status_changed: $TODAY" \
  "promote でも frontmatter へ status_changed が追加される: $FRONT4"
assert_contains "$ENTRY4" "status_changed: 2019-12-31" \
  "promote でも本文の日付が書き換わらない: $ENTRY4"

# --- 終端していない手書き frontmatter でも行が連結しない ---
# parse_entry は「閉じの --- が無いファイルは末尾まで frontmatter」として読む
# 契約(手書きされた壊れたファイルの扱い)。その末尾行が status で、改行で
# 終わっていないと、status_changed の挿入が `status: closedstatus_changed: …` と
# 連結し、status も status_changed も読めなくなる
#
# --reason は付けない。理由ブロックの追記は末尾へ改行を足すため、付けると
# status 行が改行で終わる形になり、この経路を通らない(--reason 無しの close は
# CLI の既定の使い方なので、実際に起こりうる組み合わせである)
HAND="$WORK/project/.feedback/log/20200101-000000-手書き.md"
printf -- '---\nid: 20200101-000000\ncategory: style\nstatus: open' > "$HAND"  # 末尾に改行なし
fb close "20200101-000000" >/dev/null
HAND_TEXT="$(cat "$HAND")"
assert_not_contains "$HAND_TEXT" "closedstatus_changed" "行が連結しない: $HAND_TEXT"
assert_contains "$(fb list --status closed)" " 20200101-000000 " \
  "手書きエントリの状態が closed として読める"

assert_summary
