#!/usr/bin/env bash
# test_md_links.sh — Markdown の内部リンク切れ検出を検証する。
#
# 「READMEに書いたパスが実在しない」「ファイルを移動してリンクが腐る」は
# 実際に頻出する欠陥だが、外部ツール無しで捕まえられる。
# 誤検出は正当な文書で完了をブロックするため、除外側の固定を厚くする:
# コードブロック内・コードスパン内の "[text](path)" 風の記述は対象外。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
. "$REPO/scripts/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/docs/sub"

ok() { # ok <ファイル> <ラベル> — 検証が成功(exit 0)することを期待
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  local out
  if ! out="$(harness_check_md_links "$1" 2>&1)"; then
    fail "$2: 誤検出した (出力: $out)"
  fi
}
ng() { # ng <ファイル> <ラベル> — 検証が失敗(非0)することを期待
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  if harness_check_md_links "$1" >/dev/null 2>&1; then
    fail "$2: 壊れたリンクを検出しなかった"
  fi
}

# --- 実在するリンクは通す ---
printf 'target\n' > "$WORK/docs/target.md"
printf 'see [t](target.md)\n' > "$WORK/docs/good.md"
ok "$WORK/docs/good.md" "実在する相対リンクを通す"

# --- 壊れたリンクを検出する ---
printf 'see [x](missing.md)\n' > "$WORK/docs/broken.md"
ng "$WORK/docs/broken.md" "存在しない相対リンクを検出する"

# 出力に対象ファイルとリンク先が含まれる(何を直せばよいか分かる)
DIAG="$(harness_check_md_links "$WORK/docs/broken.md" 2>/dev/null || true)"
assert_contains "$DIAG" "broken.md" "診断に対象ファイル名が出る"
assert_contains "$DIAG" "missing.md" "診断にリンク先が出る"

# --- 相対解決は「そのファイルの位置」を基準にする ---
printf 'up [t](../target.md)\n' > "$WORK/docs/sub/rel.md"
ok "$WORK/docs/sub/rel.md" "親ディレクトリへの相対リンクを解決する"

# --- 検証対象外(ネットワーク・アンカー・絶対パス) ---
printf '[a](https://example.com) [b](http://example.com) [c](mailto:x@example.com)\n' > "$WORK/docs/ext.md"
ok "$WORK/docs/ext.md" "外部URL・mailtoは検証しない"
printf '[a](#section)\n' > "$WORK/docs/anchor.md"
ok "$WORK/docs/anchor.md" "アンカーのみのリンクは検証しない"
printf '[a](/abs/path.md)\n' > "$WORK/docs/abs.md"
ok "$WORK/docs/abs.md" "絶対パスは検証しない(サイト設計依存)"

# --- アンカー付きは「ファイル部分だけ」を見る ---
printf 'see [t](target.md#heading)\n' > "$WORK/docs/frag.md"
ok "$WORK/docs/frag.md" "アンカー付きリンクはファイル部分で判定する"
printf 'see [x](missing.md#heading)\n' > "$WORK/docs/fragbad.md"
ng "$WORK/docs/fragbad.md" "アンカー付きでも実体が無ければ検出する"

# --- 画像も対象 ---
printf '![img](missing.png)\n' > "$WORK/docs/img.md"
ng "$WORK/docs/img.md" "画像リンクも検証する"

# --- 誤検出しないこと(ここが本丸) ---
# コードブロック内の記述は説明用であって実リンクではない
{ printf 'text\n\n'; printf '```markdown\n'; printf '[example](does-not-exist.md)\n'; printf '```\n'; } \
  > "$WORK/docs/fence.md"
ok "$WORK/docs/fence.md" "コードブロック内のリンク風記述は検証しない"

# コードスパン内も同様
printf 'write `[text](path)` like this\n' > "$WORK/docs/span.md"
ok "$WORK/docs/span.md" "コードスパン内のリンク風記述は検証しない"

# タイトル付きリンク [text](path "title")
printf 'see [t](target.md "タイトル")\n' > "$WORK/docs/title.md"
ok "$WORK/docs/title.md" "タイトル付きリンクを正しく解釈する"

# --- 複数ファイル指定: 1件でも壊れていれば非0 ---
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
if harness_check_md_links "$WORK/docs/good.md" "$WORK/docs/broken.md" >/dev/null 2>&1; then
  fail "複数ファイル指定で壊れたリンクを見逃した"
fi

# --- 引数ゼロは成功 ---
ok_zero() {
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  harness_check_md_links >/dev/null 2>&1 || fail "引数ゼロで失敗した"
}
ok_zero

assert_summary
