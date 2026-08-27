#!/usr/bin/env bash
# test_atomic_create.sh — atomic_create_text が hardlink 非対応の filesystem でも
# 動き、かつ「既存を上書きしない」保証を落とさないことを検証する。
#
# os.link は exFAT/FAT32(USBメモリ)・多くのSMB共有・一部のWindows構成で
# FileExistsError でも StoreError でもない OSError(EPERM/ENOTSUP)を上げる。
# そこで落ちると feedback.sh add が traceback で死に、その checkout では記録
# そのものができなくなる。os.link を差し替えて、その filesystem を再現する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/probe.py" <<'PY'
import errno
import os
import sys
from pathlib import Path

sys.path.insert(0, os.environ["TEST_SCRIPTS"])
import feedback_store  # noqa: E402
from feedback_store import StoreError, atomic_create_text  # noqa: E402

work = Path(os.environ["TEST_WORK"])
results = []


def check(label, ok):
    results.append(f"{'PASS' if ok else 'FAIL'} {label}")


def create_rejects_existing(target, label):
    try:
        atomic_create_text(target, "二度目の内容\n")
    except StoreError as exc:
        check(f"{label}: 既存を上書きしない", "上書きしません" in str(exc))
    else:
        check(f"{label}: 既存を上書きしない", False)


def leftovers(directory):
    return sorted(p.name for p in directory.iterdir() if p.name.endswith(".tmp"))


# --- 1. 通常経路(hardlink が使える) -------------------------------------
normal = work / "normal"
normal.mkdir()
target = normal / "entry.md"
atomic_create_text(target, "最初の内容\n")
check("hardlink経路: 作成できる", target.read_text(encoding="utf-8") == "最初の内容\n")
create_rejects_existing(target, "hardlink経路")
check("hardlink経路: 内容が保たれる", target.read_text(encoding="utf-8") == "最初の内容\n")
check("hardlink経路: 一時ファイルが残らない", leftovers(normal) == [])

# --- 2. hardlink 非対応の filesystem を再現 -------------------------------
real_link = os.link


def no_hardlink(src, dst, **kwargs):
    raise OSError(errno.EPERM, "operation not permitted")


feedback_store.os.link = no_hardlink
try:
    fallback = work / "fallback"
    fallback.mkdir()
    target = fallback / "entry.md"
    atomic_create_text(target, "最初の内容\n")
    check("代替経路: 作成できる", target.read_text(encoding="utf-8") == "最初の内容\n")
    create_rejects_existing(target, "代替経路")
    check("代替経路: 内容が保たれる", target.read_text(encoding="utf-8") == "最初の内容\n")
    check("代替経路: 一時ファイルが残らない", leftovers(fallback) == [])
finally:
    feedback_store.os.link = real_link

print("\n".join(results))
sys.exit(1 if any(r.startswith("FAIL") for r in results) else 0)
PY

OUT="$(TEST_SCRIPTS="$(native_path "$REPO/scripts")" TEST_WORK="$(native_path "$WORK")" \
  bash -c '. "$1"; harness_python "$2"' _ "$REPO/scripts/lib.sh" "$WORK/probe.py" 2>&1)"
RC=$?
assert_eq "0" "$RC" "atomic_create_text の検証がすべて通る: $OUT"
# 検証項目が実際に走ったこと(import 失敗などで 0 件のまま通るのを防ぐ)
CHECKS="$(printf '%s\n' "$OUT" | grep -c '^PASS ')"
assert_eq "8" "$CHECKS" "検証項目が8件すべて実行された: $OUT"

# 実入口でも記録できること — 代替経路は state_lock 前提なので、
# lock を握る main() 経由でも壊れないことを確認する
PROJECT="$WORK/project"
mkdir -p "$PROJECT/.feedback/log"
ADD_OUT="$(CLAUDE_PROJECT_DIR="$PROJECT" bash "$REPO/scripts/feedback.sh" add \
  --category style --summary "記録できる" 2>&1)"
assert_eq "0" "$?" "feedback.sh add が通る: $ADD_OUT"
assert_contains "$ADD_OUT" "recorded:" "エントリが記録される: $ADD_OUT"

assert_summary
