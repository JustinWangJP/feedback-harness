#!/usr/bin/env python3
"""feedback_log.py — 人間のレビュー・修正指摘を記録・検索・ルール化するCLI。

エントリは .feedback/log/ に frontmatter 付き Markdown で保存され、
一般化されたルールは .feedback/rules.md に昇華(promote)される。
rules.md は CLAUDE.md / AGENTS.md から参照され、次回以降のセッションに反映される。

使い方:
  feedback_log.py add --category <cat> --summary "<要約>" [--detail "<詳細>"] [--source human|hook|agent] \
      [--signal context|instruction|workflow|failure]
  feedback_log.py list [--status open|promoted|closed|all] [--category <cat>]
  feedback_log.py search <キーワード>
  feedback_log.py promote <entry-id> --rule "<一般化したルール1行>"
  feedback_log.py merge <entry-id> --into <既存ルールの出典id> [--rule "<更新後の本文>"]
  feedback_log.py close <entry-id> [--reason "<昇華しない理由>"]
  feedback_log.py retire <出典entry-id> --reason "<退役理由>"
  feedback_log.py rules            # 現在のルール一覧を表示

category の例: style, architecture, testing, naming, workflow, domain
"""
import argparse
import datetime
import os
import re
import subprocess
import sys
from pathlib import Path


def project_root() -> Path:
    """状態(.feedback/)を置くプロジェクトルートを解決する。

    解決順: CLAUDE_PROJECT_DIR → git rev-parse --show-toplevel → cwd

    __file__ 起点にはしない。プラグインとして配布されるとこのファイルは
    プラグインキャッシュに置かれ、そこへ書いた状態はプラグイン更新で失われる。
    """
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env and Path(env).is_dir():
        return Path(env).resolve()
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        if out:
            return Path(out).resolve()
    except (OSError, subprocess.SubprocessError):
        pass
    return Path.cwd().resolve()


ROOT = project_root()
LOG_DIR = ROOT / ".feedback" / "log"
RULES = ROOT / ".feedback" / "rules.md"
RULES_TEMPLATE = ROOT / ".feedback" / "rules.template.md"
# バンドル資産は状態と違い、スクリプトに同梱されて配られる読み取り専用のファイル。
# 導入先が rules.template.md を持たない(プラグインのみで導入した)場合の供給元。
BUNDLED_TEMPLATE = Path(__file__).resolve().parent.parent / ".feedback" / "rules.template.md"

# rules.md が無いときの初期ヘッダ。install.sh の配布シードと同一内容を保つため、
# rules.template.md があればそれを正とする(テンプレート消失時のフォールバックが以下)。
DEFAULT_RULES_HEADER = """# フィードバック由来ルール

エージェントはセッション開始時に必ずこのファイルを読むこと。
各ルールは実際の人間の指摘から一般化されたもの(`scripts/feedback_log.py promote` で追加される)。

<!-- ここから下に promote されたルールが追記される -->
"""


def rules_seed() -> str:
    # 導入先のテンプレート → バンドルのテンプレート → 埋め込みの既定ヘッダ
    for candidate in (RULES_TEMPLATE, BUNDLED_TEMPLATE):
        if candidate.exists():
            return candidate.read_text(encoding="utf-8")
    return DEFAULT_RULES_HEADER


def slugify(text: str, limit: int = 40) -> str:
    s = re.sub(r"[^\w\-]+", "-", text.lower()).strip("-")
    return s[:limit] or "entry"


SIGNALS = ["context", "instruction", "workflow", "failure"]


def infer_signal(category: str, detail: str) -> str:
    """--signal 省略時に detail/category から信号種を推論する。

    根因は failure のサブルーティング材料であり、signal はそれを置き換えない。
    「根因: 文脈欠落」の失敗は直す先がプライミング文書(context)なのに対し、
    「指示欠陥/モデル限界」は失敗信号(failure)として扱う。
    """
    if "根因" in detail and "文脈欠落" in detail:
        return "context"
    if "根因" in detail and ("指示欠陥" in detail or "モデル限界" in detail):
        return "failure"
    if category == "workflow":
        return "workflow"
    return "instruction"


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


def next_entry_id(now: datetime.datetime) -> str:
    """記録時刻からIDを採番する。

    秒精度のため同一秒に複数記録するとIDが衝突し、promote が先頭の1件しか
    掴めず残りが昇華不能になる(rules.md の出典も曖昧になる)。
    衝突したら連番を付けて一意にする。
    """
    base = now.strftime("%Y%m%d-%H%M%S")
    existing = {e.get("id") for e in entries()}
    if base not in existing:
        return base
    for n in range(2, 1000):
        candidate = f"{base}-{n}"
        if candidate not in existing:
            return candidate
    sys.exit(f"ERROR: id={base} の連番が尽きました")


def cmd_add(args):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    now = datetime.datetime.now()
    entry_id = next_entry_id(now)
    signal = args.signal or infer_signal(args.category, args.detail)
    path = LOG_DIR / f"{entry_id}-{slugify(args.summary)}.md"
    path.write_text(
        f"""---
id: {entry_id}
date: {now.strftime('%Y-%m-%d')}
source: {args.source}
category: {args.category}
signal: {signal}
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
        if args.signal and (e.get("signal") or "unknown") != args.signal:
            continue
        found = True
        title = next((line[2:] for line in e["body"].splitlines() if line.startswith("# ")), "")
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
    target = find_entry(args.entry_id)
    RULES.parent.mkdir(parents=True, exist_ok=True)
    if not RULES.exists():
        RULES.write_text(rules_seed(), encoding="utf-8")
    date = datetime.date.today().isoformat()
    with RULES.open("a", encoding="utf-8") as f:
        f.write(f"\n- **[{target.get('category','-')}]** {args.rule}  \n  <sub>出典: {target.get('id')} ({date} 昇華)</sub>\n")
    text = target["path"].read_text(encoding="utf-8").replace("status: open", "status: promoted", 1)
    target["path"].write_text(text, encoding="utf-8")
    print(f"promoted: rules.md に追加し {target.get('id')} を promoted に更新")


def find_entry(entry_id: str) -> dict:
    matches = [e for e in entries() if e.get("id") == entry_id]
    if not matches:
        sys.exit(f"ERROR: id={entry_id} のエントリが見つかりません")
    if len(matches) > 1:
        # 旧バージョンが採番した重複IDが残っている場合。黙って先頭を選ぶと
        # 残りが昇華不能なまま気づかれないため、明示的に失敗させる
        paths = "\n".join(f"  - {m['path'].relative_to(ROOT)}" for m in matches)
        sys.exit(
            f"ERROR: id={entry_id} のエントリが{len(matches)}件あります。"
            f"frontmatter の id を一意に直してください:\n{paths}"
        )
    return matches[0]


def set_status(target: dict, new_status: str) -> None:
    text = target["path"].read_text(encoding="utf-8")
    target["path"].write_text(
        text.replace(f"status: {target.get('status')}", f"status: {new_status}", 1),
        encoding="utf-8",
    )


RULE_SOURCE_RE = re.compile(r"^(\s*<sub>出典: )(.+?)( \(.*)$")


def find_rule_by_source(lines: list, entry_id: str) -> tuple:
    """rules.md の行リストから、出典に entry_id を含むルールの出典行を探す。

    行全体への部分文字列一致で探すと、同一秒採番の枝番ID(例: X と X-2)が
    互いに誤ヒットする。出典リストを分解して厳密一致で比較する。
    """
    hits = []
    for i, ln in enumerate(lines):
        m = RULE_SOURCE_RE.match(ln)
        if not m:
            continue
        if entry_id in (s.strip() for s in m.group(2).split(",")):
            hits.append((i, m))
    if not hits:
        sys.exit(f"ERROR: 出典に {entry_id} を含むルールが rules.md にありません")
    if len(hits) > 1:
        sys.exit(f"ERROR: 出典に {entry_id} を含むルールが{len(hits)}件あります。rules.md の出典の重複を解消してください")
    return hits[0]


def cmd_close(args):
    """昇華せずに処理済みにする。

    一回限りの事情で一般化できない指摘は open のまま残すとノイズになり、
    promote すると狭すぎるルールが増える。その逃げ道がないと
    「open が3件以上」の通知が永久に鳴り続ける。
    """
    target = find_entry(args.entry_id)
    if target.get("status") != "open":
        sys.exit(f"ERROR: id={args.entry_id} は open ではありません (status={target.get('status')})")
    if args.reason:
        text = target["path"].read_text(encoding="utf-8").rstrip("\n")
        target["path"].write_text(f"{text}\n\n---\nclose理由: {args.reason}\n", encoding="utf-8")
        target = find_entry(args.entry_id)
    set_status(target, "closed")
    print(f"closed: {args.entry_id} を closed に更新(ルールには昇華していません)")


def cmd_merge(args):
    """既存ルールへ統合する。

    同じ原則の指摘が再発したとき、新規ルールを増やすと rules.md が
    重複だらけになる。既存ルールの出典に追記し、必要なら本文を更新する。
    """
    target = find_entry(args.entry_id)
    if not RULES.exists():
        sys.exit("ERROR: rules.md がありません。先に promote でルールを作成してください")

    lines = RULES.read_text(encoding="utf-8").splitlines()
    i, m = find_rule_by_source(lines, args.into)
    sources = [s.strip() for s in m.group(2).split(",")]
    if args.entry_id in sources:
        sys.exit(f"ERROR: {args.entry_id} はすでにこのルールの出典です")
    sources.append(args.entry_id)
    lines[i] = f"{m.group(1)}{', '.join(sources)}{m.group(3)}"

    if args.rule:
        if i == 0 or not lines[i - 1].lstrip().startswith("- **["):
            sys.exit("ERROR: 統合先のルール本文行が見つかりません")
        category = re.match(r"^(\s*- \*\*\[[^\]]+\]\*\* )", lines[i - 1])
        if not category:
            sys.exit(f"ERROR: ルール本文行の形式を解釈できません: {lines[i - 1]}")
        lines[i - 1] = f"{category.group(1)}{args.rule}  "

    RULES.write_text("\n".join(lines) + "\n", encoding="utf-8")
    set_status(target, "promoted")
    print(f"merged: {args.entry_id} を既存ルール(出典 {args.into})へ統合し promoted に更新")


def cmd_retire(args):
    """昇華済みルールを退役させ、rules.md から撤去する。

    更新されないルールは時間とともに陳腐化し誤適用の負債になるが、
    promote/merge/close だけでは rules.md からルールを取り除く出口がない
    (手編集は禁止)。退役は棚卸し(feedback-loopスキル)で人間が裁定した
    後に実行する。出典エントリには理由を追記して監査痕跡を残す。
    """
    if not RULES.exists():
        sys.exit("ERROR: rules.md がありません")

    lines = RULES.read_text(encoding="utf-8").splitlines()
    i, m = find_rule_by_source(lines, args.entry_id)
    if i == 0 or not lines[i - 1].lstrip().startswith("- **["):
        sys.exit("ERROR: 退役対象のルール本文行が見つかりません")
    sources = [s.strip() for s in m.group(2).split(",")]

    start = i - 1
    if start > 0 and not lines[start - 1].strip():
        start -= 1  # promote が挿入する直前の空行も一緒に取り除く
    del lines[start : i + 1]
    RULES.write_text("\n".join(lines) + "\n", encoding="utf-8")

    updated = []
    for sid in sources:
        matches = [e for e in entries() if e.get("id") == sid]
        if len(matches) != 1:
            print(f"WARN: 出典 {sid} のエントリを一意に特定できません({len(matches)}件)。status を手動で確認してください")
            continue
        target = matches[0]
        text = target["path"].read_text(encoding="utf-8").rstrip("\n")
        target["path"].write_text(f"{text}\n\n---\nretire理由: {args.reason}\n", encoding="utf-8")
        set_status(parse_entry(target["path"]), "retired")
        updated.append(sid)
    print(f"retired: rules.md からルールを撤去し、出典エントリ({', '.join(updated) if updated else 'なし'})を retired に更新")


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
    a.add_argument("--signal", choices=SIGNALS,
                   help="信号種(省略時は detail/category から推論)")
    a.set_defaults(func=cmd_add)

    li = sub.add_parser("list", help="エントリ一覧")
    li.add_argument("--status", default="open", choices=["open", "promoted", "closed", "retired", "all"])
    li.add_argument("--category")
    li.add_argument("--signal", choices=SIGNALS + ["unknown"])
    li.set_defaults(func=cmd_list)

    s = sub.add_parser("search", help="キーワード検索")
    s.add_argument("keyword")
    s.set_defaults(func=cmd_search)

    pr = sub.add_parser("promote", help="エントリを一般化ルールへ昇華")
    pr.add_argument("entry_id")
    pr.add_argument("--rule", required=True)
    pr.set_defaults(func=cmd_promote)

    mg = sub.add_parser("merge", help="既存ルールへ統合(新規ルールを増やさない)")
    mg.add_argument("entry_id")
    mg.add_argument("--into", required=True, help="統合先ルールの出典に含まれるentry-id")
    mg.add_argument("--rule", help="統合後のルール本文(省略時は既存本文のまま)")
    mg.set_defaults(func=cmd_merge)

    cl = sub.add_parser("close", help="昇華せず処理済みにする")
    cl.add_argument("entry_id")
    cl.add_argument("--reason", help="昇華しない理由")
    cl.set_defaults(func=cmd_close)

    rt = sub.add_parser("retire", help="昇華済みルールを退役(rules.md から撤去)")
    rt.add_argument("entry_id", help="退役するルールの出典に含まれるentry-id")
    rt.add_argument("--reason", required=True, help="退役の理由(出典エントリに追記され監査痕跡になる)")
    rt.set_defaults(func=cmd_retire)

    r = sub.add_parser("rules", help="ルール一覧を表示")
    r.set_defaults(func=cmd_rules)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
