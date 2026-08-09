#!/usr/bin/env python3
"""feedback_log.py — 人間のレビュー・修正指摘を記録・検索・ルール化するCLI。

エントリは .feedback/log/ に frontmatter 付き Markdown で保存され、
一般化されたルールは .feedback/rules.md に昇華(promote)される。
rules.md は CLAUDE.md / AGENTS.md から参照され、次回以降のセッションに反映される。

使い方:
  feedback_log.py add --category <cat> --summary "<要約>" [--detail "<詳細>"] [--source human|hook|agent]
  feedback_log.py list [--status open|promoted|all] [--category <cat>]
  feedback_log.py search <キーワード>
  feedback_log.py promote <entry-id> --rule "<一般化したルール1行>"
  feedback_log.py rules            # 現在のルール一覧を表示

category の例: style, architecture, testing, naming, workflow, domain
"""
import argparse
import datetime
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOG_DIR = ROOT / ".feedback" / "log"
RULES = ROOT / ".feedback" / "rules.md"


def slugify(text: str, limit: int = 40) -> str:
    s = re.sub(r"[^\w\-]+", "-", text.lower()).strip("-")
    return s[:limit] or "entry"


def parse_entry(path: Path) -> dict:
    meta, body, in_fm = {}, [], False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip() == "---":
            in_fm = not in_fm
            continue
        if in_fm and ":" in line:
            k, v = line.split(":", 1)
            meta[k.strip()] = v.strip()
        elif not in_fm:
            body.append(line)
    meta["body"] = "\n".join(body).strip()
    meta["path"] = path
    return meta


def entries():
    if not LOG_DIR.exists():
        return []
    return sorted((parse_entry(p) for p in LOG_DIR.glob("*.md")), key=lambda e: e.get("id", ""))


def cmd_add(args):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    now = datetime.datetime.now()
    entry_id = now.strftime("%Y%m%d-%H%M%S")
    path = LOG_DIR / f"{entry_id}-{slugify(args.summary)}.md"
    path.write_text(
        f"""---
id: {entry_id}
date: {now.strftime('%Y-%m-%d')}
source: {args.source}
category: {args.category}
status: open
---

# {args.summary}

{args.detail or ''}
""",
        encoding="utf-8",
    )
    print(f"recorded: {path.relative_to(ROOT)} (id={entry_id})")
    open_count = sum(1 for e in entries() if e.get("status") == "open")
    if open_count >= 3:
        print(f"NOTE: open状態のエントリが{open_count}件あります。一般化できるものは promote を検討してください。")


def cmd_list(args):
    found = False
    for e in entries():
        if args.status != "all" and e.get("status") != args.status:
            continue
        if args.category and e.get("category") != args.category:
            continue
        found = True
        title = next((l[2:] for l in e["body"].splitlines() if l.startswith("# ")), "")
        print(f"[{e.get('status','?'):8}] {e.get('id')}  {e.get('category','-'):12} {title}")
    if not found:
        print("該当エントリなし")


def cmd_search(args):
    kw = args.keyword.lower()
    hits = [e for e in entries() if kw in e["path"].read_text(encoding="utf-8").lower()]
    for e in hits:
        print(f"{e.get('id')}  {e['path'].relative_to(ROOT)}")
    if not hits:
        print("ヒットなし")


def cmd_promote(args):
    target = next((e for e in entries() if e.get("id") == args.entry_id), None)
    if not target:
        sys.exit(f"ERROR: id={args.entry_id} のエントリが見つかりません")
    RULES.parent.mkdir(parents=True, exist_ok=True)
    if not RULES.exists():
        RULES.write_text("# フィードバック由来ルール\n\nエージェントはセッション開始時に必ずこのファイルを読むこと。\n", encoding="utf-8")
    date = datetime.date.today().isoformat()
    with RULES.open("a", encoding="utf-8") as f:
        f.write(f"\n- **[{target.get('category','-')}]** {args.rule}  \n  <sub>出典: {target.get('id')} ({date} 昇華)</sub>\n")
    text = target["path"].read_text(encoding="utf-8").replace("status: open", "status: promoted", 1)
    target["path"].write_text(text, encoding="utf-8")
    print(f"promoted: rules.md に追加し {target.get('id')} を promoted に更新")


def cmd_rules(_args):
    print(RULES.read_text(encoding="utf-8") if RULES.exists() else "(rules.md はまだありません)")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("add", help="フィードバックエントリを記録")
    a.add_argument("--category", required=True)
    a.add_argument("--summary", required=True)
    a.add_argument("--detail", default="")
    a.add_argument("--source", default="human", choices=["human", "hook", "agent"])
    a.set_defaults(func=cmd_add)

    l = sub.add_parser("list", help="エントリ一覧")
    l.add_argument("--status", default="open", choices=["open", "promoted", "all"])
    l.add_argument("--category")
    l.set_defaults(func=cmd_list)

    s = sub.add_parser("search", help="キーワード検索")
    s.add_argument("keyword")
    s.set_defaults(func=cmd_search)

    pr = sub.add_parser("promote", help="エントリを一般化ルールへ昇華")
    pr.add_argument("entry_id")
    pr.add_argument("--rule", required=True)
    pr.set_defaults(func=cmd_promote)

    r = sub.add_parser("rules", help="ルール一覧を表示")
    r.set_defaults(func=cmd_rules)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
