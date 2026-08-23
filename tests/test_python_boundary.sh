#!/usr/bin/env bash
# test_python_boundary.sh — shell と Python の境界(_harness_python_exec)の契約を検証する。
#
# 検証する契約は3つ:
#   1. 出力encodingは常に UTF-8。周囲の環境変数がどうであれハーネスの日本語出力は壊れない
#   2. 出力改行は常に LF。capture 側は CR 除去を行わない
#   3. Windows path 変換は「実在する絶対path」だけに掛かる。自由テキストは書き換えない
#
# いずれも「Windows でしか壊れない」欠陥だが、ambient を潰す・cygpath を差し替えると
# Linux / macOS でも同じ失敗を再現できるため、開発機の実行で回帰を捕まえられる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. UTF-8 -----------------------------------------------------------
# Windows の Git Bash では stdout が ANSI コードページ(cp932 / cp1252)で
# 符号化され、日本語を出す全経路(feedback.sh list / rules、--list-checks の表)が
# UnicodeEncodeError で落ちる。PYTHONIOENCODING=ascii はこれを移植性のある形で
# 再現する。まず「素の Python なら実際に落ちる」ことを確かめ、テストが
# 空振りしていないことを保証する。
CONTROL="$(PYTHONUTF8=0 PYTHONIOENCODING=ascii "$TEST_PYTHON" -c 'print("規約")' 2>&1)"
CONTROL_RC=$?
assert_eq "1" "$CONTROL_RC" "対照: ambient ascii では素の Python が失敗する"
assert_contains "$CONTROL" "UnicodeEncodeError" "対照: 失敗理由がencodingであることを確認する"

OUT="$(PYTHONUTF8=0 PYTHONIOENCODING=ascii bash -c '
  . "$1"
  harness_python -c "print(\"規約 — フィードバック\")"
' _ "$LIB" 2>&1)"
assert_eq "0" "$?" "ambient ascii でも harness_python が成功する: $OUT"
assert_contains "$OUT" "規約 — フィードバック" "harness_python の日本語出力が壊れない"

# ハーネスは ambient を尊重せず上書きする。尊重すると、上の対照が示すとおり
# 利用者環境の設定ひとつでハーネスが使えなくなる。
OUT="$(PYTHONUTF8=0 PYTHONIOENCODING=ascii bash -c '
  . "$1"
  harness_python -c "import sys; print(sys.stdout.encoding)"
' _ "$LIB" 2>&1)"
assert_contains "$(printf '%s' "$OUT" | tr '[:upper:]' '[:lower:]')" "utf-8" \
  "harness_python が stdout encoding を UTF-8 へ固定する: $OUT"

# 実入口(feedback.sh)でも同じであること — lib.sh 単体でなく配布される経路を通す。
OUT="$(PYTHONUTF8=0 PYTHONIOENCODING=ascii bash "$REPO/scripts/feedback.sh" --help 2>&1)"
assert_eq "0" "$?" "ambient ascii でも feedback.sh --help が成功する: $OUT"

# --- 2. LF only ---------------------------------------------------------
# フックは harness_python の出力を文字列比較(on_stop の stop_hook_active)と
# 行読み(post_edit の path 抽出)に使う。CR が混ざると比較が黙って外れるため、
# 経路ごとに CR を落とす防御ではなく「境界が LF しか出さない」契約で担保する。
CR_PROBE="$(bash -c '
  . "$1"
  harness_python -c "print(\"true\"); print(\"/a/b\")" | od -An -c | tr -d " \n"
' _ "$LIB")"
assert_not_contains "$CR_PROBE" '\r' "harness_python の出力に CR が混ざらない: $CR_PROBE"

# 契約を守る代わりに個別の CR 除去を足すと、抜けた経路(harness_load_config の
# eval など)だけが静かに壊れる。走査で書き戻しを捕まえる。
CR_STRIPPERS="$(grep -rn "tr -d '\\\\r'" \
  "$REPO/scripts" 2>/dev/null || true)"
assert_eq "" "$CR_STRIPPERS" \
  "scripts/ に場当たりの CR 除去を足さない(境界の LF 契約で担保する)"

# --- 3. path 変換の範囲 -------------------------------------------------
# MSYSTEM と cygpath を差し替えて Git Bash を模す。fake cygpath は受け取った
# path を log へ記録したうえで原文のまま返す(返り値を変えると実際の Python
# 起動が壊れて何も検証できない)。どの引数へ変換が掛かったかは log で判定する。
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
export CYGPATH_LOG="$WORK/cygpath.log"
cat > "$FAKEBIN/cygpath" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${!#}" >> "${CYGPATH_LOG:?}"
printf '%s\n' "${!#}"
SH
chmod +x "$FAKEBIN/cygpath"

EXISTING="$WORK/real-file.txt"
: > "$EXISTING"

: > "$CYGPATH_LOG"
OUT="$(PATH="$FAKEBIN:$PATH" MSYSTEM=MINGW64 bash -c '
  . "$1"
  harness_python -c "
import sys
for a in sys.argv[1:]:
    print(a)
" "$2" "/docs 配下は英語で書く" "/api" "--rule" "/scripts は触らない"
' _ "$LIB" "$EXISTING" 2>&1)"
CONVERTED="$(cat "$CYGPATH_LOG")"

assert_contains "$CONVERTED" "$EXISTING" "実在する絶対pathは Windows path へ変換する"
assert_not_contains "$CONVERTED" "/docs 配下は英語で書く" "スラッシュで始まる自由テキストへ cygpath を掛けない"
assert_not_contains "$CONVERTED" "/api" "実在しない検索語へ cygpath を掛けない"
assert_not_contains "$CONVERTED" "/scripts は触らない" "スラッシュで始まるルール文言へ cygpath を掛けない"
assert_contains "$OUT" "/docs 配下は英語で書く" "自由テキストが Python へ原文のまま渡る: $OUT"

# 記録経路の実害を実入口で確認する。add した summary が原文のまま保存されること。
PROJECT="$WORK/project"
mkdir -p "$PROJECT"
: > "$CYGPATH_LOG"
ADD_OUT="$(PATH="$FAKEBIN:$PATH" MSYSTEM=MINGW64 CLAUDE_PROJECT_DIR="$PROJECT" \
  bash "$REPO/scripts/feedback.sh" add \
    --category style --summary "/docs 配下は英語で書く" 2>&1)"
assert_eq "0" "$?" "Git Bash 相当の環境で add が成功する: $ADD_OUT"
assert_not_contains "$(cat "$CYGPATH_LOG")" "/docs 配下は英語で書く" \
  "add の summary へ cygpath を掛けない"
LIST_OUT="$(PATH="$FAKEBIN:$PATH" MSYSTEM=MINGW64 CLAUDE_PROJECT_DIR="$PROJECT" \
  bash "$REPO/scripts/feedback.sh" list 2>&1)"
assert_contains "$LIST_OUT" "/docs 配下は英語で書く" \
  "記録した summary が原文のまま保存される: $LIST_OUT"

assert_summary
