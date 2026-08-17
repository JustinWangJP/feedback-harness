#!/usr/bin/env bash
# test_check_warn.sh — WARN(非ブロッキングの結果クラス)を検証する。
#
# 設計原則: プロジェクトが設定ファイルで宣言した検査は FAIL(ブロック)、
# ハーネスが推測で走らせる検査は WARN(報告のみ)。宣言していない検査で
# 完了をブロックすると、導入初日の既存プロジェクトが作業不能になる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$REPO/scripts/check.sh"

command -v ruff >/dev/null 2>&1 || { echo "  (ruff 未インストールのためスキップ)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

new_project() { # new_project <名前>
  local d="$WORK/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}
# ruff format が「要整形」と判断するコード(括弧内の余分な空白と長すぎない行)
unformatted() { printf 'x = {  "a":1 }\n'; }

# --- 宣言なし: 未整形でも WARN で、完了をブロックしない ---
P1="$(new_project no_decl)"
unformatted > "$P1/mod.py"
OUT="$(bash "$CHECK" "$P1" 2>&1)"; RC=$?
assert_eq "0" "$RC" "宣言が無ければ未整形で exit 1 にしない"
assert_contains "$OUT" "WARN  python: ruff format" "WARN として記録される"
assert_contains "$OUT" "件WARN" "最終行に WARN 件数が出る"
assert_not_contains "$OUT" "FAIL  python: ruff format" "FAIL にはしない"

# --- 宣言あり([tool.ruff] を書いた): 同じ未整形が FAIL になる ---
P2="$(new_project with_decl)"
unformatted > "$P2/mod.py"
printf '[tool.ruff]\nline-length = 100\n' > "$P2/pyproject.toml"
OUT="$(bash "$CHECK" "$P2" 2>&1)"; RC=$?
assert_eq "1" "$RC" "宣言があれば未整形で exit 1 になる"
assert_contains "$OUT" "FAIL  python: ruff format" "FAIL として記録される"

# --- 整形済みなら PASS ---
P3="$(new_project formatted)"
printf 'x = {"a": 1}\n' > "$P3/mod.py"
OUT="$(bash "$CHECK" "$P3" 2>&1)"; RC=$?
assert_eq "0" "$RC" "整形済みは exit 0"
assert_contains "$OUT" "PASS  python: ruff format" "PASS として記録される"
assert_not_contains "$OUT" "件WARN" "WARNが無ければ件数表記は出ない"

# --- WARN と FAIL が混在したら exit 1(FAIL が優先される) ---
P4="$(new_project warn_and_fail)"
unformatted > "$P4/mod.py"          # → WARN(宣言なし)
printf '{"a": 1,\n' > "$P4/broken.json"  # → FAIL(構文エラー)
OUT="$(bash "$CHECK" "$P4" 2>&1)"; RC=$?
assert_eq "1" "$RC" "FAILが1件でもあれば exit 1"
assert_contains "$OUT" "WARN  python: ruff format" "混在時もWARNは記録される"

assert_summary
