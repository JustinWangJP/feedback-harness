#!/usr/bin/env bash
# test_check_p2.sh — P2 で追加した検査(docs / security / 依存整合性 / 各種lint)が
# check.sh に正しく配線されているかを検証する。
#
# 外部ツールは PATH に偽実行ファイルを置いて駆動する。検証するのはツールの
# 検出精度ではなく「検出条件・引数・終了コードの写像」という配線の契約である。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$REPO/scripts/check.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

new_project() { # new_project <名前> — 空のgitプロジェクトを作りパスを返す
  local d="$WORK/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}

# --- docs: 内部リンク ---
P1="$(new_project docs_broken)"
printf 'see [x](missing.md)\n' > "$P1/README.md"
OUT="$(bash "$CHECK" "$P1" 2>&1)"; RC=$?
assert_eq "1" "$RC" "リンク切れで exit 1 になる"
assert_contains "$OUT" "docs: 内部リンク" "docs ステージが結果に出る"
assert_contains "$OUT" "missing.md" "失敗ログにリンク先が出る"

P2="$(new_project docs_ok)"
printf 'target\n' > "$P2/target.md"
printf 'see [t](target.md)\n' > "$P2/README.md"
OUT="$(bash "$CHECK" "$P2" 2>&1)"; RC=$?
assert_eq "0" "$RC" "リンクが有効なら exit 0"
assert_contains "$OUT" "PASS  docs: 内部リンク" "PASSとして記録される"

# --- Markdown が無ければステージ自体を出さない ---
P3="$(new_project no_md)"
printf 'hello\n' > "$P3/note.txt"
OUT="$(bash "$CHECK" "$P3" 2>&1)"
assert_not_contains "$OUT" "docs: 内部リンク" "対象が無ければステージを出さない"

# --- 非ASCIIファイル名でも落ちない(git ls-files のエスケープ対策の回帰) ---
P4="$(new_project nonascii)"
printf 'target\n' > "$P4/対象.md"
printf 'see [t](対象.md)\n' > "$P4/日本語ファイル名.md"
OUT="$(bash "$CHECK" "$P4" 2>&1)"; RC=$?
assert_eq "0" "$RC" "日本語ファイル名でも誤検出しない"
assert_contains "$OUT" "PASS  docs: 内部リンク" "日本語ファイル名を検証対象にできる"

# --- 追跡済みだが作業ツリーから消えたファイルは対象外(list_files が列挙するため) ---
P5="$(new_project deleted_md)"
printf 'gone\n' > "$P5/gone.md"
( cd "$P5" && git add gone.md && git -c user.email=t@example.com -c user.name=t commit -q -m init && rm gone.md )
printf 'target\n' > "$P5/target.md"
printf 'see [t](target.md)\n' > "$P5/README.md"
OUT="$(bash "$CHECK" "$P5" 2>&1)"; RC=$?
assert_eq "0" "$RC" "削除済み追跡ファイルがあっても exit 0"
assert_not_contains "$OUT" "Errno 2" "削除済みファイルを読もうとしない"
assert_contains "$OUT" "PASS  docs: 内部リンク" "残ったファイルは検証される"

assert_summary
