#!/usr/bin/env bash
# test_feedback_concurrency.sh — feedback状態の並列更新と中断回復を検証する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CLI="$REPO/scripts/feedback_log.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PROJECT="$WORK/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q

# 同一秒・同一summaryでも全entryが残らなければ、ID採番とcreateが競合している。
PIDS=()
for n in $(seq 1 50); do
  CLAUDE_PROJECT_DIR="$PROJECT" python3 "$CLI" add \
    --category testing --summary "parallel-entry" --detail "probe-$n" --source agent \
    >/dev/null 2>&1 &
  PIDS+=("$!")
done
ADD_FAILED=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || ADD_FAILED=$((ADD_FAILED + 1))
done
assert_eq "0" "$ADD_FAILED" "50並列addが全て成功する"

ENTRY_COUNT="$(find "$PROJECT/.feedback/log" -type f -name '*.md' | wc -l | tr -d ' ')"
ID_COUNT="$(sed -n 's/^id: //p' "$PROJECT"/.feedback/log/*.md | sort -u | wc -l | tr -d ' ')"
DETAIL_COUNT="$(grep -h '^probe-' "$PROJECT"/.feedback/log/*.md | sort -u | wc -l | tr -d ' ')"
assert_eq "50" "$ENTRY_COUNT" "50並列addで50ファイルが残る"
assert_eq "50" "$ID_COUNT" "50並列addでIDが全て一意になる"
assert_eq "50" "$DETAIL_COUNT" "50並列addで本文が消失しない"

# 別projectで複数promoteを並列実行し、rulesとstatusを同じ件数へ収束させる。
PROMOTE_PROJECT="$WORK/promote"
mkdir -p "$PROMOTE_PROJECT"
git -C "$PROMOTE_PROJECT" init -q
IDS=()
for n in $(seq 1 8); do
  OUT="$(CLAUDE_PROJECT_DIR="$PROMOTE_PROJECT" python3 "$CLI" add \
    --category architecture --summary "rule-$n" --detail "detail-$n" --source human)"
  IDS+=("$(printf '%s' "$OUT" | sed -n 's/.*(id=\([^)]*\)).*/\1/p')")
done

PIDS=()
for n in $(seq 1 8); do
  id="${IDS[$((n - 1))]}"
  CLAUDE_PROJECT_DIR="$PROMOTE_PROJECT" python3 "$CLI" promote "$id" --rule "parallel rule $n" \
    >/dev/null 2>&1 &
  PIDS+=("$!")
done
PROMOTE_FAILED=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || PROMOTE_FAILED=$((PROMOTE_FAILED + 1))
done
assert_eq "0" "$PROMOTE_FAILED" "8並列promoteが全て成功する"
RULE_COUNT="$(grep -c '^- \*\*\[' "$PROMOTE_PROJECT/.feedback/rules.md")"
PROMOTED_COUNT="$(grep -l '^status: promoted$' "$PROMOTE_PROJECT"/.feedback/log/*.md | wc -l | tr -d ' ')"
assert_eq "8" "$RULE_COUNT" "8並列promoteでruleが消失しない"
assert_eq "8" "$PROMOTED_COUNT" "rulesとentry statusが同じ件数になる"
RULE_BREAK_COUNT="$(grep -c '^- \*\*\[.*<br>$' "$PROMOTE_PROJECT/.feedback/rules.md")"
assert_eq "8" "$RULE_BREAK_COUNT" "promoteが行末空白ではなく明示的なMarkdown改行を生成する"

# 2ファイルtransactionの1件目直後に例外を起こし、journalからroll-forwardする。
python3 - "$REPO/scripts" "$WORK/recovery" <<'PY'
import json
import sys
import subprocess
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from feedback_store import JOURNAL_NAME, StoreError, recover_transaction, state_lock, transaction

root = Path(sys.argv[2])
feedback = root / ".feedback"
feedback.mkdir(parents=True)
a = feedback / "a.txt"
b = feedback / "b.txt"
a.write_text("old-a", encoding="utf-8")
b.write_text("old-b", encoding="utf-8")

def crash_after_first(index):
    if index == 1:
        raise RuntimeError("simulated crash")

with state_lock(root, 2):
    try:
        transaction(root, "test-crash", [(a, "new-a"), (b, "new-b")], after_write=crash_after_first)
    except RuntimeError:
        pass

assert a.read_text(encoding="utf-8") == "new-a"
assert b.read_text(encoding="utf-8") == "old-b"
assert (feedback / JOURNAL_NAME).exists()
journal = json.loads((feedback / JOURNAL_NAME).read_text(encoding="utf-8"))
assert journal["operation"] == "test-crash"
assert all("before_sha256" in write and "sha256" in write for write in journal["writes"])

# journal開始後の第三者変更を無断で上書きせず、診断可能な状態でjournalを残す。
b.write_text("external-b", encoding="utf-8")
with state_lock(root, 2):
    try:
        recover_transaction(root)
    except StoreError as exc:
        assert "別内容へ変更" in str(exc)
    else:
        raise AssertionError("external change must block recovery")
assert b.read_text(encoding="utf-8") == "external-b"
assert (feedback / JOURNAL_NAME).exists()
b.write_text("old-b", encoding="utf-8")

with state_lock(root, 2):
    assert recover_transaction(root) is True

assert a.read_text(encoding="utf-8") == "new-a"
assert b.read_text(encoding="utf-8") == "new-b"
assert not (feedback / JOURNAL_NAME).exists()
assert (feedback / ".state.lock").exists()
assert not list(feedback.glob(".*.tmp"))

# JSONとしては有効でもschemaが壊れたjournalはtracebackにせず、安全停止して残す。
journal_path = feedback / JOURNAL_NAME
journal_path.write_text("[]\n", encoding="utf-8")
with state_lock(root, 2):
    try:
        recover_transaction(root)
    except StoreError as exc:
        assert "schemaを解釈できません" in str(exc)
    else:
        raise AssertionError("invalid journal schema must block recovery")
assert journal_path.exists()
journal_path.unlink()

with state_lock(root, 2):
    blocked = subprocess.run(
        [
            sys.executable,
            str(Path(sys.argv[1]) / "feedback_store.py"),
            "append-event",
            str(root),
            '{"probe":"timeout"}',
            "--lock-timeout",
            "1",
        ],
        capture_output=True,
        text=True,
        timeout=3,
    )
assert blocked.returncode == 1
assert "1秒以内に取得できません" in blocked.stderr
PY
assert_eq "0" "$?" "中断transaction回復とlock timeout診断が機能する"

# rotationと並列appendを同じlockで直列化する。大きな旧ログを最初のwriterが
# 切り詰めた後も、同時に来た20イベントをlost updateせず全て保持する。
python3 - "$REPO/scripts" "$WORK/events" <<'PY'
import json
import multiprocessing
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from feedback_store import record_event

root = Path(sys.argv[2])
feedback = root / ".feedback"
feedback.mkdir(parents=True)
old = [json.dumps({"old": n, "padding": "x" * 500}) for n in range(30)]
(feedback / "events.jsonl").write_text("\n".join(old) + "\n", encoding="utf-8")

def append(index):
    record_event(
        root,
        {"new": index},
        5,
        max_bytes=5000,
        keep_lines=5,
    )

context = multiprocessing.get_context("fork")
processes = [context.Process(target=append, args=(n,)) for n in range(20)]
for process in processes:
    process.start()
for process in processes:
    process.join()
assert all(process.exitcode == 0 for process in processes)
events = [json.loads(line) for line in (feedback / "events.jsonl").read_text().splitlines()]
assert {event["new"] for event in events if "new" in event} == set(range(20))
assert not list(feedback.glob(".*.tmp"))
PY
assert_eq "0" "$?" "並列event appendとrotationで新規行を失わない"

assert_summary
