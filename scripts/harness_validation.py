#!/usr/bin/env python3
"""Portable syntax and Markdown-link validators used by PowerShell entry points."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


FENCE = re.compile(r"^\s*(```|~~~)")
LINK = re.compile(r'!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')
SPAN = re.compile(r"`[^`]*`")


def is_jsonc(path: Path) -> bool:
    name = path.name
    normalized = path.as_posix()
    return (
        re.fullmatch(r"(?:ts|js)config.*\.json", name) is not None
        or name == "devcontainer.json"
        or "/.vscode/" in f"/{normalized}"
    )


def validate_json(paths: list[Path]) -> int:
    bad = False
    for path in paths:
        if is_jsonc(path):
            continue
        try:
            json.loads(path.read_text(encoding="utf-8-sig"))
        except Exception as exc:
            print(f"{path}: {exc}")
            bad = True
    return int(bad)


def validate_yaml(paths: list[Path]) -> int:
    try:
        import yaml
    except ImportError:
        return 2

    bad = False
    for path in paths:
        try:
            list(yaml.safe_load_all(path.read_text(encoding="utf-8-sig")))
        except yaml.constructor.ConstructorError:
            # Unknown application-specific tags are not syntax errors.
            pass
        except Exception as exc:
            print(f"{path}: {exc}")
            bad = True
    return int(bad)


def validate_markdown_links(paths: list[Path]) -> int:
    bad = False
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8-sig")
        except OSError as exc:
            print(f"{path}: {exc}")
            bad = True
            continue
        in_fence = False
        for line in text.splitlines():
            if FENCE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            for match in LINK.finditer(SPAN.sub("", line)):
                target = match.group(1)
                if target.startswith(("http://", "https://", "mailto:", "#", "/")):
                    continue
                target = target.split("#", 1)[0]
                if target and not (path.parent / target).exists():
                    print(f"{path}: リンク先が見つかりません: {target}")
                    bad = True
    return int(bad)


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[0] not in {"json", "yaml", "markdown"}:
        print("usage: harness_validation.py <json|yaml|markdown> <file>...", file=sys.stderr)
        return 2
    paths = [Path(value) for value in argv[1:]]
    if argv[0] == "json":
        return validate_json(paths)
    if argv[0] == "yaml":
        return validate_yaml(paths)
    return validate_markdown_links(paths)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
