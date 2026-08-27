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
# 行読み(post_edit の path 抽出)に使い、harness_load_config は eval する。
# Windows の Python は sys.stdout へ CRLF を書き出す(2026-08-24 の Windows CI
# で実測)ため、境界の harness_python が一度だけ CR を落とす契約にしている。
# capture 側それぞれで落とす形にすると、足し忘れた経路だけが静かに壊れる。

# 実出力に CR が無いこと。Windows CI ではこれが正規化の実地検証になる。
CR_PROBE="$(bash -c '
  . "$1"
  harness_python -c "print(\"true\"); print(\"/a/b\")" | od -An -c | tr -d " \n"
' _ "$LIB")"
assert_not_contains "$CR_PROBE" '\r' "harness_python の出力に CR が混ざらない: $CR_PROBE"

# Windows を持たない開発機でも正規化そのものを検証する。MSYSTEM を立てたうえで
# Python に CRLF を明示的に書かせ、境界が落とすことを確かめる。
CRLF_PROBE="$(MSYSTEM=MINGW64 bash -c '
  . "$1"
  harness_python -c "
import sys
sys.stdout.buffer.write(b\"true\r\n/a/b\r\n\")
" | od -An -c | tr -d " \n"
' _ "$LIB")"
assert_not_contains "$CRLF_PROBE" '\r' \
  "Python が CRLF を書いても境界が LF へ正規化する: $CRLF_PROBE"
assert_contains "$CRLF_PROBE" "true" "正規化しても本文は失われない: $CRLF_PROBE"

# 正規化は pipeline で行うため、終了ステータスの取りこぼしが起きやすい。
MSYSTEM=MINGW64 bash -c '. "$1"; harness_python -c "raise SystemExit(3)"' _ "$LIB" >/dev/null 2>&1
assert_eq "3" "$?" "正規化経路でも Python の終了ステータスを保つ"
MSYSTEM=MINGW64 bash -c '. "$1"; harness_python -c "pass"' _ "$LIB" >/dev/null 2>&1
assert_eq "0" "$?" "正規化経路でも成功時は 0 を返す"

# テスト側の捕捉も同じ契約に乗せる。ハーネス本体は harness_python が境界で
# 正規化するが、テストが素の python3 を $( ) で捕まえるとその境界を通らず、
# Windows では期待値だけに CR が混ざって「表示は同じなのに一致しない」失敗になる。
# 走査で禁止する — 21箇所を移行したあと、次に足される1箇所を止められるのは
# 一覧ではなく走査だけである(比較に使わない直接実行は対象外)。
# パターンは分割して組み立てる。走査対象にこのファイル自身が含まれるため、
# 探している並びをそのまま書くと自分の1行に当たって常に落ちる
PY_CAPTURE_PATTERN='\$\(python'"3 "
CAPTURES="$(grep -rnE "$PY_CAPTURE_PATTERN" "$REPO"/tests/*.sh || true)"
assert_eq "" "$CAPTURES" "テストは Python 出力の捕捉に tpy を使う(素の python3 は CR が残る)"

# 契約が「境界で一度だけ」であること。フック側が自前で CR を落とし始めると
# 「どこで落ちているのか」が経路ごとに分かれ、抜けが生まれる。
for hook in "$REPO"/scripts/hooks/*.sh; do
  HOOK_BODY="$(cat "$hook")"
  assert_not_contains "$HOOK_BODY" "tr -d '\\r'" \
    "$(basename "$hook") は自前で CR を落とさない(境界の正規化に任せる)"
  assert_not_contains "$HOOK_BODY" "%\$'\\r'" \
    "$(basename "$hook") は自前で CR を削らない(境界の正規化に任せる)"
done

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

# --- 4. shell function に乗っ取られない -------------------------------
# command -v は export された shell function も解決する。tests/assert.sh は
# python3 が無い環境で `export -f python3` の shim を定義するため、対策が無いと
# 実 Git Bash 上で harness_python が本番コードではなく shim を呼び、上の
# セクション3(自由テキストを変換しない)が shim の挙動を検査してしまう
# — 「アサーションが本番の入力に触れていない」型の欠陥(PR #13 レビュー由来)。
SHIMBIN="$WORK/shimbin"
mkdir -p "$SHIMBIN"
cat > "$SHIMBIN/python" <<SH
#!/usr/bin/env bash
exec "$TEST_PYTHON" "\$@"
SH
chmod +x "$SHIMBIN/python"

HIJACK="$(PATH="$SHIMBIN:/usr/bin:/bin" HARNESS_PYTHON='' bash -c '
  python3() { echo "SHIM-WAS-USED"; }
  export -f python3
  . "$1"
  _harness_python_resolve && echo "resolved=$_HARNESS_PYTHON_CACHED"
  harness_python -c "print(\"real-interpreter\")"
' _ "$LIB" 2>&1)"
assert_not_contains "$HIJACK" "SHIM-WAS-USED" \
  "export された python3 関数が interpreter として選ばれない: $HIJACK"
assert_contains "$HIJACK" "resolved=python" "実ファイルの python へ解決する: $HIJACK"
assert_contains "$HIJACK" "real-interpreter" "解決先の実 interpreter が実行される: $HIJACK"

assert_summary
