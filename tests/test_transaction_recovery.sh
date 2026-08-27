#!/usr/bin/env bash
# test_transaction_recovery.sh — 回復不能な transaction journal が残ったときの
# CLI の振る舞いを検証する。
#
# 回復は main() の入口で全コマンド共通に走る。journal が1つ壊れているだけで
# 読み取り専用コマンドまで巻き添えで死ぬと、「調べるための道具が、調べたい
# 状況でだけ使えない」ことになる。読み取りは通し、書き込みは止め、どちらでも
# 復旧手順を必ず見せる — その3点を固定する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CLI="$REPO/scripts/feedback.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PROJECT="$WORK/project"
mkdir -p "$PROJECT/.feedback/log"

# 回復できない journal を作る。transaction の開始後に対象が第三者へ書き換えられた
# 状態 — roll-forward すると人の変更を無断で潰すため、store は必ずここで止まる。
poison_journal() {
  TEST_PROJECT="$(native_path "$PROJECT")" bash -c '. "$1"; harness_python "$2"' \
    _ "$REPO/scripts/lib.sh" "$WORK/poison.py"
}

cat > "$WORK/poison.py" <<'PY'
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["TEST_PROJECT"])
rules = root / ".feedback" / "rules.md"
rules.write_text("第三者が書き換えた内容\n", encoding="utf-8")
content = "transaction が書こうとしていた内容\n"
payload = {
    "version": 1,
    "operation": "promote",
    "writes": [
        {
            "path": ".feedback/rules.md",
            "content": content,
            "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
            "before_sha256": hashlib.sha256(
                "transaction 開始時の内容\n".encode("utf-8")
            ).hexdigest(),
        }
    ],
}
(root / ".feedback" / ".transaction.json").write_text(
    json.dumps(payload, ensure_ascii=False), encoding="utf-8"
)
PY

poison_journal
assert_file_exists "$PROJECT/.feedback/.transaction.json" "回復不能な journal を用意できた"

# --- 読み取り専用コマンドは通る ------------------------------------------
# 引数が要るものだけ個別に、他は素で回す
run_ro() { # run_ro <ラベル> <args...>
  local label="$1"; shift
  local out rc
  out="$(CLAUDE_PROJECT_DIR="$PROJECT" bash "$CLI" "$@" 2>&1)"
  rc=$?
  assert_eq "0" "$rc" "$label は壊れた journal があっても成功する: $out"
  assert_contains "$out" ".transaction.json" \
    "$label が復旧手順(journalのpath)を示す: $out"
  assert_contains "$out" "この記録を削除して再実行" \
    "$label が復旧手順(削除して再実行)を示す: $out"
}

run_ro "list" list
run_ro "list --status all" list --status all
run_ro "search" search キーワード
run_ro "rules" rules
run_ro "stats" stats
run_ro "report" report --since 2026-01-01

# --- 変更系コマンドは止まる ----------------------------------------------
run_rw() { # run_rw <ラベル> <args...>
  local label="$1"; shift
  local out rc
  out="$(CLAUDE_PROJECT_DIR="$PROJECT" bash "$CLI" "$@" 2>&1)"
  rc=$?
  assert_eq "1" "$rc" "$label は壊れた journal があると失敗する: $out"
  assert_contains "$out" "ERROR" "$label の失敗が ERROR として出る: $out"
  assert_contains "$out" ".transaction.json" \
    "$label が復旧手順(journalのpath)を示す: $out"
  assert_contains "$out" "この記録を削除して再実行" \
    "$label が復旧手順(削除して再実行)を示す: $out"
}

run_rw "add" add --category style --summary "テスト用の記録"
run_rw "close" close 20260101-000000 --reason "テスト"
# report --mark は .last-retro を transaction で書く。読み取り扱いのまま通すと
# transaction() が壊れた journal を上書きしてから unlink し、「内容を確認のうえ
# 削除して再実行」と案内した当の記録が黙って消える
run_rw "report --mark" report --since 2026-01-01 --mark
assert_file_exists "$PROJECT/.feedback/.transaction.json" \
  "止まった report --mark が journal を消していない"
assert_file_absent "$PROJECT/.feedback/.last-retro" \
  "止まった report --mark が基点を書いていない"

# 書き込みが止まっている以上、記録は1件も増えていないこと
ENTRY_COUNT="$(find "$PROJECT/.feedback/log" -name '*.md' | wc -l | tr -d ' ')"
assert_eq "0" "$ENTRY_COUNT" "失敗した add がエントリを作っていない"

# --- 復旧手順どおりに直せば元に戻る --------------------------------------
rm -f "$PROJECT/.feedback/.transaction.json"
OUT="$(CLAUDE_PROJECT_DIR="$PROJECT" bash "$CLI" add \
  --category style --summary "復旧後の記録" 2>&1)"
assert_eq "0" "$?" "journal を削除すれば add が通る: $OUT"
assert_contains "$OUT" "recorded:" "復旧後に記録できる: $OUT"

assert_summary
