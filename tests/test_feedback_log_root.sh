#!/usr/bin/env bash
# test_feedback_log_root.sh — feedback_log.py が状態を「導入先」に書くことを検証する。
#
# プラグイン配布で最も退行しやすい箇所。スクリプトをキャッシュ相当の場所へ
# コピーして実行し、そこではなく導入先に .feedback/ ができることを確かめる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

# プラグインキャッシュを模した場所へスクリプトとバンドル資産を配置する
mkdir -p "$WORK/cache/scripts" "$WORK/cache/.feedback"
cp "$REPO/scripts/feedback_log.py" "$WORK/cache/scripts/"
cp "$REPO/.feedback/rules.template.md" "$WORK/cache/.feedback/"

# 本物の rules.template.md は DEFAULT_RULES_HEADER (埋め込みフォールバック) と
# バイト単位で同一のため、"フィードバック由来ルール" が rules.md に出るだけでは
# BUNDLED_TEMPLATE が実際に読まれた証拠にならない(段を飛ばして埋め込みへ
# 落ちても同じ文字列が出てしまう)。BUNDLED_TEMPLATE 経由でしか出ない
# マーカーをキャッシュ側のコピーにだけ追記して区別できるようにする。
BUNDLED_MARKER="<!-- BUNDLED-TEMPLATE-MARKER -->"
printf '\n%s\n' "$BUNDLED_MARKER" >> "$WORK/cache/.feedback/rules.template.md"

# 導入先(.feedback/ をまだ持たない git リポジトリ)
mkdir -p "$WORK/project"
( cd "$WORK/project" && git init -q . )

OUT="$(cd "$WORK/project" && CLAUDE_PROJECT_DIR="$WORK/project" \
  python3 "$WORK/cache/scripts/feedback_log.py" add \
    --category workflow --summary "テスト用の指摘" --source human 2>&1)"

assert_contains "$OUT" "recorded:" "add が成功する"
assert_file_absent "$WORK/cache/.feedback/log" "キャッシュ側にログを作らない"
ENTRIES="$(find "$WORK/project/.feedback/log" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "1" "$ENTRIES" "導入先にエントリが1件できる"

# rules.md をキャッシュ側(バンドル)のテンプレートから初期化できること。
# 導入先には rules.template.md が無い状態なので、BUNDLED_TEMPLATE への
# フォールバックが働かないとヘッダの無い rules.md ができる。
# rules_seed() を実際に通るのは promote なので、それで検証する。
ENTRY_ID="$(printf '%s' "$OUT" | sed -n 's/.*(id=\(.*\))$/\1/p')"
if [[ -z "$ENTRY_ID" ]]; then
  fail "add の出力から id を取り出せない: [$OUT]"
else
  ( cd "$WORK/project" && CLAUDE_PROJECT_DIR="$WORK/project" \
    python3 "$WORK/cache/scripts/feedback_log.py" promote "$ENTRY_ID" \
      --rule "テスト用のルール" >/dev/null 2>&1 )
  assert_contains "$(cat "$WORK/project/.feedback/rules.md" 2>/dev/null)" \
    "$BUNDLED_MARKER" "バンドルのテンプレートでシードされる"
  assert_file_absent "$WORK/cache/.feedback/rules.md" "キャッシュ側に rules.md を作らない"
fi

# CLAUDE_PROJECT_DIR が無くても git のトップレベルへ書く
mkdir -p "$WORK/project/sub"
OUT3="$(cd "$WORK/project/sub" && unset CLAUDE_PROJECT_DIR; \
  python3 "$WORK/cache/scripts/feedback_log.py" add \
    --category workflow --summary "サブディレクトリからの指摘" --source human 2>&1)"
assert_contains "$OUT3" "recorded:" "サブディレクトリからでも add できる"
assert_file_absent "$WORK/project/sub/.feedback" "サブディレクトリ直下には作らない"
ENTRIES2="$(find "$WORK/project/.feedback/log" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "2" "$ENTRIES2" "リポジトリルートに集約される"

assert_summary
