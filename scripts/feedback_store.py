#!/usr/bin/env python3
"""feedback-harness の共有状態を安全に更新するための保存プリミティブ。"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import stat
import tempfile
import time
from collections.abc import Callable, Iterable
from pathlib import Path

LOCK_NAME = ".state.lock"
JOURNAL_NAME = ".transaction.json"
JOURNAL_VERSION = 1
EVENT_MAX_BYTES = 524288
EVENT_KEEP_LINES = 2000


class StoreError(RuntimeError):
    """状態保存または回復に失敗した。"""


def _fsync_dir(path: Path) -> None:
    """rename/unlink の永続化を可能な範囲で保証する。"""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _write_temp(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
    fd, raw_tmp = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    tmp = Path(raw_tmp)
    try:
        os.chmod(tmp, mode)
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        tmp.unlink(missing_ok=True)
        raise
    return tmp


def atomic_write_text(path: Path, content: str) -> None:
    """同一directory内のtempfileを `os.replace` して部分書きを見せない。"""
    tmp = _write_temp(path, content)
    try:
        os.replace(tmp, path)
        _fsync_dir(path.parent)
    finally:
        tmp.unlink(missing_ok=True)


def atomic_create_text(path: Path, content: str) -> None:
    """既存pathを上書きせず、完全に書けた内容だけを公開する。"""
    tmp = _write_temp(path, content)
    try:
        try:
            os.link(tmp, path)
        except FileExistsError as exc:
            raise StoreError(f"既存ファイルを上書きしません: {path}") from exc
        _fsync_dir(path.parent)
    finally:
        tmp.unlink(missing_ok=True)


def _append_jsonl_event(
    root: Path,
    event: dict,
    *,
    max_bytes: int = EVENT_MAX_BYTES,
    keep_lines: int = EVENT_KEEP_LINES,
) -> None:
    """lock取得済みの状態でJSONLへ追記し、必要なら原子的にrotationする。"""
    if not isinstance(event, dict):
        raise StoreError("eventはJSON objectである必要があります")
    path = root / ".feedback" / "events.jsonl"
    try:
        lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    except OSError as exc:
        raise StoreError(f"event logを読み取れません: {path}") from exc
    lines.append(json.dumps(event, ensure_ascii=False, separators=(",", ":")))
    content = "\n".join(lines) + "\n"
    if len(content.encode("utf-8")) > max_bytes:
        content = "\n".join(lines[-keep_lines:]) + "\n"
    atomic_write_text(path, content)


def record_event(
    root: Path,
    event: dict,
    timeout_seconds: int,
    *,
    max_bytes: int = EVENT_MAX_BYTES,
    keep_lines: int = EVENT_KEEP_LINES,
) -> None:
    """event追記とrotationをrepository lock内で直列化する。"""
    with state_lock(root, timeout_seconds):
        recover_transaction(root)
        _append_jsonl_event(root, event, max_bytes=max_bytes, keep_lines=keep_lines)


@contextlib.contextmanager
def state_lock(root: Path, timeout_seconds: int):
    """`.feedback/` の共有状態をrepository単位で直列化する。

    lock pathは削除しない。待機中processが同じinodeを監視できることが
    正しさの前提であり、unlock後に削除すると別inodeのlockが同時成立しうる。
    """
    feedback_dir = root / ".feedback"
    feedback_dir.mkdir(parents=True, exist_ok=True)
    path = feedback_dir / LOCK_NAME
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    deadline = time.monotonic() + timeout_seconds
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise StoreError(
                        f"状態lockを{timeout_seconds}秒以内に取得できません: {path}"
                    )
                time.sleep(0.05)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def _feedback_relative(root: Path, path: Path) -> str:
    root = root.resolve()
    target = path.resolve(strict=False)
    feedback_dir = (root / ".feedback").resolve(strict=False)
    try:
        target.relative_to(feedback_dir)
    except ValueError as exc:
        raise StoreError(
            f"transaction対象は .feedback/ 配下に限ります: {path}"
        ) from exc
    return str(target.relative_to(root))


def _journal_payload(
    root: Path, operation: str, writes: Iterable[tuple[Path, str]]
) -> dict:
    items = []
    seen = set()
    for path, content in writes:
        relative = _feedback_relative(root, path)
        if relative in seen:
            raise StoreError(
                f"transaction内で同じpathを複数回更新できません: {relative}"
            )
        seen.add(relative)
        try:
            before = path.read_bytes() if path.exists() else None
        except OSError as exc:
            raise StoreError(f"transaction対象を読み取れません: {path}") from exc
        items.append(
            {
                "path": relative,
                "content": content,
                "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
                "before_sha256": hashlib.sha256(before).hexdigest()
                if before is not None
                else None,
            }
        )
    if not items:
        raise StoreError("transactionに更新対象がありません")
    return {"version": JOURNAL_VERSION, "operation": operation, "writes": items}


def _apply_payload(
    root: Path, payload: dict, after_write: Callable[[int], None] | None = None
) -> None:
    if payload.get("version") != JOURNAL_VERSION or not isinstance(
        payload.get("writes"), list
    ):
        raise StoreError("transaction journalのschemaを解釈できません")
    for index, item in enumerate(payload["writes"], start=1):
        if not isinstance(item, dict) or not all(
            k in item for k in ("path", "content", "sha256", "before_sha256")
        ):
            raise StoreError("transaction journalのwrite項目が不正です")
        path = root / item["path"]
        expected = hashlib.sha256(item["content"].encode("utf-8")).hexdigest()
        if expected != item["sha256"]:
            raise StoreError(
                f"transaction journalの内容hashが一致しません: {item['path']}"
            )
        _feedback_relative(root, path)
        try:
            current = (
                hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
            )
        except OSError as exc:
            raise StoreError(f"transaction対象を読み取れません: {path}") from exc
        if current not in (item["before_sha256"], expected):
            raise StoreError(
                f"transaction開始後に対象が別内容へ変更されています: {item['path']}"
            )
        atomic_write_text(path, item["content"])
        if after_write:
            after_write(index)


def recover_transaction(root: Path) -> bool:
    """中断されたtransactionを同じ最終内容へroll-forwardする。"""
    journal = root / ".feedback" / JOURNAL_NAME
    if not journal.exists():
        return False
    try:
        payload = json.loads(journal.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise StoreError(f"transaction journalを読み取れません: {journal}") from exc
    _apply_payload(root, payload)
    journal.unlink()
    _fsync_dir(journal.parent)
    return True


def transaction(
    root: Path,
    operation: str,
    writes: Iterable[tuple[Path, str]],
    *,
    after_write: Callable[[int], None] | None = None,
) -> None:
    """複数ファイルの最終状態をjournalへ先に記録してから反映する。

    途中でprocessが終了してもjournalを残す。次回lock取得後の
    `recover_transaction` が全writeを再適用するため、操作はidempotentである。
    """
    payload = _journal_payload(root, operation, writes)
    journal = root / ".feedback" / JOURNAL_NAME
    atomic_write_text(journal, json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    _apply_payload(root, payload, after_write=after_write)
    journal.unlink()
    _fsync_dir(journal.parent)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    append = sub.add_parser(
        "append-event", help="JSON objectをevents.jsonlへ安全に追記"
    )
    append.add_argument("root")
    append.add_argument("event_json")
    append.add_argument("--lock-timeout", type=int, default=10)
    args = parser.parse_args()
    try:
        event = json.loads(args.event_json)
        record_event(Path(args.root).resolve(), event, args.lock_timeout)
    except (json.JSONDecodeError, StoreError) as exc:
        parser.exit(1, f"ERROR: {exc}\n")


if __name__ == "__main__":
    main()
