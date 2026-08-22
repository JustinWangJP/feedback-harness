#!/usr/bin/env python3
# ruff: noqa -- ハーネス配布ファイル(導入元で管理・検査済み。導入先の ruff 設定の対象外)
# fmt: off
"""feedback_log.py — 人間のレビュー・修正指摘を記録・検索・ルール化するCLI。

エントリは .feedback/log/ に frontmatter 付き Markdown で保存され、
一般化されたルールは .feedback/rules.md に昇華(promote)される。
rules.md は CLAUDE.md / AGENTS.md から参照され、次回以降のセッションに反映される。

使い方:
  feedback_log.py add --category <cat> --summary "<要約>" [--detail "<詳細>"] [--source human|hook|agent] \
      [--signal context|instruction|workflow|failure]
  feedback_log.py list [--status open|promoted|closed|retired|all] [--category <cat>] \
      [--signal context|instruction|workflow|failure|unknown]
  feedback_log.py search <キーワード>
  feedback_log.py promote <entry-id> --rule "<一般化したルール1行>"
  feedback_log.py merge <entry-id> --into <既存ルールの出典id> [--rule "<更新後の本文>"]
  feedback_log.py close <entry-id> [--reason "<昇華しない理由>"]
  feedback_log.py retire <出典entry-id> --reason "<退役理由>"
  feedback_log.py rules            # 現在のルール一覧を表示
  feedback_log.py stats [--since YYYY-MM-DD] [--days N]   # 初回通過率・再発候補など
  feedback_log.py report --since <日付|yesterday> [--mark]  # 期間ダイジェスト(朝会・振り返りの議題)
  feedback_log.py report --last [--mark]                    # 前回の振り返り以降

category の例: style, architecture, testing, naming, workflow, domain
"""
import argparse
import datetime
import json
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
EVENTS_FILE = ROOT / ".feedback" / "events.jsonl"
LAST_RETRO = ROOT / ".feedback" / ".last-retro"
# audit.sh が監査成功時にだけ書くスタンプ。stats/report が「最終監査日」として表示する
LAST_AUDIT = ROOT / ".feedback" / ".last-audit"
# 設定は harness_config が解決する(bash 側と同じ解決規則を使うため、
# ここで環境変数や既定値を独自に読み直さない)
# dont_write_bytecode: init.sh 配布先の scripts/ に __pycache__/ が生えて
# Python プロジェクトでない導入先の untracked ノイズになるのを防ぐ
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from feedback_store import (  # noqa: E402 -- 配布先scripts/を先にpathへ載せる
    StoreError,
    atomic_create_text,
    recover_transaction,
    state_lock,
    transaction,
)

try:
    import harness_config as _hc

    _CFG = _hc.effective(str(ROOT), os.environ)
    if _CFG.get("error"):
        print(f"WARNING: {_CFG['error']}", file=sys.stderr)
except Exception:  # ローダーが壊れていても記録・集計は止めない
    _CFG = {"values": {}}


def _cfg(key, default):
    entry = _CFG.get("values", {}).get(key)
    return entry[0] if entry else default


AUDIT_INTERVAL_DAYS = _cfg("audit.interval_days", 7)
OPEN_THRESHOLD = _cfg("feedback.open_threshold", 3)
# この日数だけ再発していない頻出項目は「解消済みかもしれない」と注記する。
# 累積件数だけで並べると直った問題が上位に居座り、対処すべき項目を隠すため
STALE_DAYS = _cfg("feedback.stale_days", 7)
# 棚卸し(ルールの定期審査)の間隔。更新されないルールは安定するのではなく
# 負債になるため、監査と同じく「ブロックせず、溜まったら見える」形で促す
RETRO_INTERVAL_DAYS = _cfg("feedback.retro_interval_days", 90)
LOCK_TIMEOUT_SECONDS = _cfg("feedback.lock_timeout_seconds", 10)
# バンドル資産は状態と違い、スクリプトに同梱されて配られる読み取り専用のファイル。
# 導入先が rules.template.md を持たない(プラグインのみで導入した)場合の供給元。
BUNDLED_TEMPLATE = Path(__file__).resolve().parent.parent / ".feedback" / "rules.template.md"

# rules.md が無いときの初期ヘッダ。install.sh の配布シードと同一内容を保つため、
# rules.template.md があればそれを正とする(テンプレート消失時のフォールバックが以下)。
DEFAULT_RULES_HEADER = """# フィードバック由来ルール

エージェントはセッション開始時に必ずこのファイルを読むこと。
各ルールは実際の人間の指摘から一般化されたもの(`scripts/feedback_log.py promote` で追加される)。

<!-- rules:failure -->
### 守るべき制約(失敗由来)

<!-- rules:success -->
### 再現すべき措辞・進め方(成功由来)
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
ROOT_CAUSES = ["文脈欠落", "指示欠陥", "実行誤り", "モデル限界", "未判定"]
ROOT_CAUSE_RE = re.compile(r"根因:\s*(" + "|".join(map(re.escape, ROOT_CAUSES)) + r")")
ROOT_CAUSE_TOKEN_RE = re.compile(r"根因:\s*([^\s（(、。]+)")


def validate_root_cause(detail: str) -> None:
    """根因行がある場合、定義済みの分類が1件だけ指定されていることを確認する。"""
    if "根因:" not in detail:
        return
    found = ROOT_CAUSE_TOKEN_RE.findall(detail)
    if len(found) != 1 or found[0] not in ROOT_CAUSES:
        allowed = " / ".join(ROOT_CAUSES)
        sys.exit(f"ERROR: 根因は次のいずれかを1件指定してください: {allowed}")


def infer_signal(category: str, detail: str) -> str:
    """--signal 省略時に detail/category から信号種を推論する。

    signal は観測した出来事の種類、根因は失敗理由であり別軸である。
    根因を記録するのは誤った出力・行動があったときなので、根因の種類に
    かかわらず failure とする。失敗を伴わない context 信号は --signal context
    で明示する。
    """
    if ROOT_CAUSE_RE.search(detail):
        return "failure"
    if category == "workflow":
        return "workflow"
    return "instruction"


RULE_DATE_RE = re.compile(r"\((\d{4}-\d{2}-\d{2}) 昇華\)")


def load_events() -> list:
    """events.jsonl を読む。不正な JSON 行は読み飛ばす(壊れた記録が集計を殺さない)。"""
    if not EVENTS_FILE.exists():
        return []
    out = []
    for line in EVENTS_FILE.read_text(encoding="utf-8").splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if isinstance(ev, dict) and "ts" in ev and "result" in ev:
            out.append(ev)
    return out


def resolve_since(args) -> str:
    """--since(優先)または --days(既定30)から集計開始日を返す。"""
    if getattr(args, "since", None):
        return args.since
    days = getattr(args, "days", 30)
    return (datetime.date.today() - datetime.timedelta(days=days)).isoformat()


def staleness_cutoff() -> str:
    """これより古い最終発生日は「しばらく再発していない」と扱う境界日。"""
    return (datetime.date.today() - datetime.timedelta(days=STALE_DAYS)).isoformat()


def is_transient_path(path: str) -> bool:
    """セッション作業用の一時ファイルなら True。

    スクラッチパッドや /tmp 配下はプロジェクトの資産ではないため、
    「どのファイルでつまずいているか」の集計に混ぜると順位を歪める。
    """
    p = str(path)
    if p.startswith("/tmp/") or p.startswith("/private/tmp/"):
        return True
    # 判定はセグメント単位で行う。events.jsonl の writer(lib.sh の
    # harness_log_event)はプロジェクト内のファイルを相対パスで記録するため、
    # "/scratchpad/" のように前後のスラッシュを要求すると、ルート直下の
    # scratchpad/x.py だけが除外から漏れ、_workspace/scratchpad/x.py は
    # 除外されるという階層依存の挙動になる(実測で再現)
    segments = p.split("/")
    return "scratchpad" in segments or ".git" in segments


def post_edit_first_pass(evs, date_from: str, date_to: str):
    """期間内の post_edit イベントから
    (初回pass数, ファイル数, ファイル別fail数, ファイル別の最終fail日)を返す。

    「初回」= 期間内でそのファイルに最初に現れたイベント。期間を跨ぐ再登場は
    リセットされる(日次/指定期間のスナップショットとして測る)。
    一時ファイルは集計対象外(is_transient_path)。
    """
    first, fails, last_fail = {}, {}, {}
    for e in evs:
        if e.get("hook") != "post_edit":
            continue
        d = str(e.get("ts", ""))[:10]
        if not (date_from <= d <= date_to):
            continue
        f = str(e.get("file", ""))
        if is_transient_path(f):
            continue
        if e.get("result") == "fail":
            fails[f] = fails.get(f, 0) + 1
            if d > last_fail.get(f, ""):
                last_fail[f] = d
        if f not in first:
            first[f] = e.get("result") == "pass"
    return (sum(first.values()), len(first), fails, last_fail)


def root_cause(entry: dict) -> str:
    """エントリ本文の「根因:」行から根因を返す(無ければ "-")。"""
    m = ROOT_CAUSE_RE.search(entry.get("body", ""))
    return m.group(1) if m else "-"


def rule_sources() -> list:
    """rules.md の各ルールから {sources, category, date} を返す(date は昇華日)。"""
    if not RULES.exists():
        return []
    out = []
    lines = RULES.read_text(encoding="utf-8").splitlines()
    for i, ln in enumerate(lines):
        m = RULE_SOURCE_RE.match(ln)
        if not m or i == 0:
            continue
        cat_m = re.match(r"\s*- \*\*\[([^\]]+)\]\*\*", lines[i - 1])
        dm = RULE_DATE_RE.search(ln)
        out.append({
            "sources": [s.strip() for s in m.group(2).split(",")],
            "category": cat_m.group(1) if cat_m else "-",
            "date": dm.group(1) if dm else "",
        })
    return out


def _bigrams(text: str) -> set:
    """文字bigramの集合(読む順のヒント用)。"""
    t = re.sub(r"\s+", "", text or "")
    return {t[i:i + 2] for i in range(len(t) - 1)}


def text_similarity(a: str, b: str) -> float:
    """2つの本文の表面的な近さ(文字bigramのJaccard係数、0.0〜1.0)。

    **判定には使わない。** 候補を読む順を決めるためだけの補助値である。
    文字の重なりしか見ないため、言語によって値域が大きくずれ(実測: 無関係な
    2文でも英語は 0.16、中国語は同主題でも 0.10)、全エントリ共通の定型句
    (「根因: …」等)にも引きずられる。同じ原則の再発かどうかの判断は、
    本文を読めるエージェントが行う(feedback-loop スキル Phase 4)。
    """
    A, B = _bigrams(a), _bigrams(b)
    if not A or not B:
        return 0.0
    return len(A & B) / len(A | B)


def recurrence_lines(cands: list) -> list:
    """再発候補の表示行(stats / report 共通)。

    絞り込まずに列挙する。同じ原則の再発かどうかは本文の意味を読まないと決まらず、
    機械的な文字列一致で足切りすると、言語や書式の差で真の再発を捨てる
    (2026-08-22: 文字bigramのしきい値方式を撤去)。CLI は見るべき対象を漏れなく
    出し、判断はエージェントに委ねる。
    """
    lines = []
    for c in cands:
        if not c["recurrences"]:
            continue
        sims = c.get("similarities", {})
        hits = ", ".join(f"{i}(参考 {sims.get(i, 0):.2f})" for i in c["recurrences"])
        lines.append(
            f"- [{c['category']}] {', '.join(c['sources'])} ({c['date']} 昇華) ← 以降の同カテゴリ: {hits}"
        )
    if not lines:
        return ["(なし)"]
    lines.append(
        "※ 同じ原則の再発かは出典と候補の本文を読んで判断すること"
        "(括弧内は表面的な文字の重なりで、読む順のヒント。判定基準ではない)"
    )
    return lines


def recurrence_candidates() -> list:
    """昇華日以降に同カテゴリの失敗系エントリが出たルールを列挙する。

    curator 原則5(再発=ルールが効いていない兆候)と棚卸しPhase4手順1の
    手動検索を機械化したもの。成功系(instruction/workflow)の再記録は
    再発ではないため対象外。

    ここで返すのは**判定結果ではなく調査対象**である。同じ原則の再発かどうかは
    本文の意味を読まないと決まらず、機械的な文字列一致で足切りすると言語や書式の
    差で真の再発を捨てる(見落としは「ルールが効いていない」ことに気づけない害が
    あり、余分な候補を1件読む手間より重い)。判断はエージェントが行う。

    各候補には表面的な類似度を添えるが、これは読む順のヒントに過ぎない
    (text_similarity の注記を参照)。
    """
    out = []
    es = entries()
    by_id = {e.get("id"): e for e in es}
    for rule in rule_sources():
        if not rule["date"]:
            continue
        # 出典が複数(merge済み)なら最も新しいものを主題の代表とする
        srcs = [by_id[s] for s in rule["sources"] if s in by_id]
        src_body = max(srcs, key=lambda e: e.get("date") or "", default={}).get("body", "")
        hits = [
            (e.get("id", "?"), text_similarity(src_body, e.get("body", "")))
            for e in es
            if e.get("category") == rule["category"]
            and (e.get("date") or "") > rule["date"]
            and e.get("id") not in rule["sources"]
            and (e.get("signal") or "unknown") in ("failure", "context", "unknown")
        ]
        if hits:
            # 読む順のヒントとして、表面的に近いものを先に出す
            hits.sort(key=lambda kv: (-kv[1], kv[0]))
            out.append({
                **rule,
                "recurrences": [i for i, _ in hits],
                "similarities": dict(hits),
            })
    return out


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
    validate_root_cause(args.detail)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    now = datetime.datetime.now()
    entry_id = next_entry_id(now)
    signal = args.signal or infer_signal(args.category, args.detail)
    path = LOG_DIR / f"{entry_id}-{slugify(args.summary)}.md"
    content = f"""---
id: {entry_id}
date: {now.strftime('%Y-%m-%d')}
source: {args.source}
category: {args.category}
signal: {signal}
status: open
---

# {args.summary}

{args.detail or ''}
"""
    atomic_create_text(path, content)
    print(f"recorded: {path.relative_to(ROOT)} (id={entry_id})")
    open_count = sum(1 for e in entries() if e.get("status") == "open")
    if open_count >= OPEN_THRESHOLD:
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


FAILURE_MARKER = "<!-- rules:failure -->"
SUCCESS_MARKER = "<!-- rules:success -->"

FAILURE_SECTION = FAILURE_MARKER + "\n### 守るべき制約(失敗由来)\n"
SUCCESS_SECTION = SUCCESS_MARKER + "\n### 再現すべき措辞・進め方(成功由来)\n"


def ensure_sections(text: str) -> str:
    """rules.md に2セクション構造が無ければ挿入する(遅延マイグレーション)。

    既存の promote 済みルールはすべて失敗セクションに入れる。成功パターンの
    捕獲(--signal)が始まる以前のルールはすべて失敗由来のためである。
    """
    if FAILURE_MARKER in text and SUCCESS_MARKER in text:
        return text
    lines = text.rstrip("\n").splitlines()
    first_rule = next(
        (i for i, ln in enumerate(lines) if ln.startswith("- **[")), len(lines)
    )
    out = "\n".join(lines[:first_rule]).rstrip() + "\n\n"
    out += FAILURE_SECTION + "\n"
    if first_rule < len(lines):
        out += "\n".join(lines[first_rule:]).rstrip() + "\n\n"
    out += SUCCESS_SECTION
    return out


def cmd_promote(args):
    target = find_entry(args.entry_id)
    RULES.parent.mkdir(parents=True, exist_ok=True)
    text = ensure_sections(
        RULES.read_text(encoding="utf-8") if RULES.exists() else rules_seed()
    )
    date = datetime.date.today().isoformat()
    rule_line = f"- **[{target.get('category','-')}]** {args.rule}  "
    source_line = f"  <sub>出典: {target.get('id')} ({date} 昇華)</sub>"
    # instruction/workflow(成功系)は成功セクションの末尾へ、それ以外
    # (failure/context/unknown)は失敗セクションの末尾(=成功マーカーの直前)へ
    if (target.get("signal") or "unknown") in ("instruction", "workflow"):
        rules_text = text.rstrip("\n") + "\n\n" + rule_line + "\n" + source_line + "\n"
    else:
        lines = text.splitlines()
        j = lines.index(SUCCESS_MARKER)
        ins = [rule_line, source_line]
        if lines[j - 1].strip():
            ins.insert(0, "")
        lines[j:j] = ins
        rules_text = "\n".join(lines) + "\n"
    transaction(
        ROOT,
        f"promote:{target.get('id')}",
        [(RULES, rules_text), (target["path"], updated_status_text(target, "promoted"))],
    )
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


def updated_status_text(target: dict, new_status: str, text: str | None = None) -> str:
    today = datetime.date.today().isoformat()
    if text is None:
        text = target["path"].read_text(encoding="utf-8")
    text = text.replace(f"status: {target.get('status')}", f"status: {new_status}", 1)
    if "status_changed:" in text:
        # 1キー・上書き(report の期間集計は「最後の状態変化」を基準にする)
        text = re.sub(r"status_changed: \d{4}-\d{2}-\d{2}", f"status_changed: {today}", text, count=1)
    else:
        text = text.replace(
            f"status: {new_status}", f"status: {new_status}\nstatus_changed: {today}", 1
        )
    return text
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
    text = target["path"].read_text(encoding="utf-8")
    if args.reason:
        text = text.rstrip("\n")
        text = f"{text}\n\n---\nclose理由: {args.reason}\n"
    transaction(
        ROOT,
        f"close:{target.get('id')}",
        [(target["path"], updated_status_text(target, "closed", text))],
    )
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

    transaction(
        ROOT,
        f"merge:{target.get('id')}->{args.into}",
        [
            (RULES, "\n".join(lines) + "\n"),
            (target["path"], updated_status_text(target, "promoted")),
        ],
    )
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

    updated = []
    writes = [(RULES, "\n".join(lines) + "\n")]
    for sid in sources:
        matches = [e for e in entries() if e.get("id") == sid]
        if len(matches) != 1:
            print(f"WARN: 出典 {sid} のエントリを一意に特定できません({len(matches)}件)。status を手動で確認してください")
            continue
        target = matches[0]
        text = target["path"].read_text(encoding="utf-8").rstrip("\n")
        text = f"{text}\n\n---\nretire理由: {args.reason}\n"
        writes.append((target["path"], updated_status_text(target, "retired", text)))
        updated.append(sid)
    transaction(ROOT, f"retire:{args.entry_id}", writes)
    print(f"retired: rules.md からルールを撤去し、出典エントリ({', '.join(updated) if updated else 'なし'})を retired に更新")


def audit_status_lines() -> list:
    """最終監査日と期限切れ推奨の行を返す(report と stats で共有)。

    audit.sh は成功時のみスタンプを書くため、脆弱性が残っている間は
    「未実行/期限切れ」表示が消えず修正を促し続ける。
    """
    if not LAST_AUDIT.exists():
        return ["最終監査: 未実行 — bash scripts/audit.sh の実行を推奨"]
    raw = LAST_AUDIT.read_text(encoding="utf-8").strip()
    try:
        d = datetime.date.fromisoformat(raw)
    except ValueError:
        return [f"最終監査: {raw} (日付不明)"]
    days = (datetime.date.today() - d).days
    line = f"最終監査: {raw} ({days}日前)"
    if days > AUDIT_INTERVAL_DAYS:
        line += f" — {AUDIT_INTERVAL_DAYS}日超過、監査を推奨(bash scripts/audit.sh)"
    return [line]


def retro_status_lines() -> list:
    """最終棚卸し日と期限切れ推奨の行を返す(audit_status_lines と対称)。

    .last-retro は report --mark が書く「前回の振り返り」の基点。棚卸しの
    期限そのものは今まで誰も見ておらず、実施忘れに気づく手段が無かった。
    """
    if not LAST_RETRO.exists():
        return ["最終棚卸し: 未実行 — feedback-loop スキルの棚卸し(Phase 4)を推奨"]
    raw = LAST_RETRO.read_text(encoding="utf-8").strip()
    try:
        d = datetime.date.fromisoformat(raw)
    except ValueError:
        return [f"最終棚卸し: {raw} (日付不明)"]
    days = (datetime.date.today() - d).days
    line = f"最終棚卸し: {raw} ({days}日前)"
    if days > RETRO_INTERVAL_DAYS:
        line += (
            f" — {RETRO_INTERVAL_DAYS}日超過、ルールの棚卸しを推奨"
            "(feedback-loop スキルの Phase 4)"
        )
    return [line]


def cmd_stats(args):
    since = resolve_since(args)
    print(f"# feedback stats(イベント集計: {since} 以降 / ログ集計: 全期間)")
    print(
        "scope: local (source: .feedback/events.jsonl, .feedback/log/, "
        ".feedback/rules.md, .feedback/.last-*)"
    )
    evs = load_events()

    print()
    print("[フック]")
    if not evs:
        print("(イベント記録が無い — hooks が .feedback/events.jsonl に蓄積する)")
    else:
        npass, total, fails, last_fail = post_edit_first_pass(evs, since, "9999-12-31")
        if total:
            print(f"PostToolUse 初回通過率: {npass}/{total} ({round(npass * 100 / total)}%)")
            print(f"1ファイルあたりの平均再チェック回数: {sum(fails.values()) / total:.2f}")
        else:
            print("(期間内の post_edit イベントが無い)")
        # warn は「テストの失敗」ではなく指摘の一種なので通過率の分母から除く
        stops = [
            e for e in evs
            if e.get("hook") == "stop"
            and e.get("result") in ("pass", "fail")
            and str(e.get("ts", ""))[:10] >= since
        ]
        if stops:
            spass = sum(1 for e in stops if e.get("result") == "pass")
            print(f"Stop フルチェック初回通過率: {spass}/{len(stops)} ({round(spass * 100 / len(stops))}%)")
        # 件数だけを出すと、直った問題が累積回数のまま上位に居座り
        # 「今なお困っていること」と区別できない。最終発生日を併記して鮮度を示す
        top = sorted(fails.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
        warns, warn_last = {}, {}
        for e in evs:
            d = str(e.get("ts", ""))[:10]
            if e.get("result") != "warn" or d < since:
                continue
            k = e.get("check", "-")
            warns[k] = warns.get(k, 0) + 1
            if d > warn_last.get(k, ""):
                warn_last[k] = d
        if warns:
            top_warn = sorted(warns.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
            print("頻出WARN: " + ", ".join(
                f"{k}({v}, 最終 {warn_last.get(k, '?')})" for k, v in top_warn))
        if top:
            print("失敗上位: " + ", ".join(
                f"{f}({n}, 最終 {last_fail.get(f, '?')})" for f, n in top))
        stale = [k for k, _ in top_warn] if warns else []
        stale = [k for k in stale if warn_last.get(k, "") < staleness_cutoff()]
        if stale:
            print(f"NOTE: {', '.join(stale)} は {STALE_DAYS}日以上再発していません"
                  " — 解消済みなら順位から外れるまで表示が残ります")

    print()
    print("[ログ]")
    es = entries()
    sig = {s: 0 for s in SIGNALS}
    sig["unknown"] = 0
    for e in es:
        k = e.get("signal") or "unknown"
        sig[k] = sig.get(k, 0) + 1
    print("signal: " + " / ".join(f"{k} {v}" for k, v in sig.items()))
    cats, causes, srcs, st = {}, {}, {}, {}
    for e in es:
        cats[e.get("category", "-")] = cats.get(e.get("category", "-"), 0) + 1
        rc = root_cause(e)
        causes[rc] = causes.get(rc, 0) + 1
        srcs[e.get("source", "-")] = srcs.get(e.get("source", "-"), 0) + 1
        st[e.get("status", "-")] = st.get(e.get("status", "-"), 0) + 1
    print("category: " + " / ".join(f"{k} {v}" for k, v in sorted(cats.items())))
    print("根因: " + " / ".join(f"{k} {v}" for k, v in sorted(causes.items())))
    print("source: " + " / ".join(f"{k} {v}" for k, v in sorted(srcs.items())))
    print("status: " + " / ".join(f"{k} {v}" for k, v in sorted(st.items())))
    opens = [e for e in es if e.get("status") == "open"]
    if opens:
        oldest = min(opens, key=lambda e: e.get("date") or "9999-99-99")
        if oldest.get("date"):
            days = (datetime.date.today() - datetime.date.fromisoformat(oldest["date"])).days
            print(f"open: {len(opens)}件(最古 {oldest.get('id')} から {days}日経過)")
        else:
            print(f"open: {len(opens)}件")
        if len(opens) >= OPEN_THRESHOLD:
            print(f"NOTE: openが{OPEN_THRESHOLD}件以上 — promote/close を検討してください")

    print()
    print("[監査・棚卸し]")
    for line in audit_status_lines():
        print(line)
    for line in retro_status_lines():
        print(line)

    print()
    print("[再発候補] 昇華後に同カテゴリの失敗系エントリが記録されたルール(調査対象)")
    cands = recurrence_candidates()
    for line in recurrence_lines(cands):
        print(line)


def resolve_report_since(args) -> str:
    if args.last:
        if not LAST_RETRO.exists():
            sys.exit("ERROR: .feedback/.last-retro がありません。--since <日付> を指定するか、初回は --mark で基点を作ってください")
        return LAST_RETRO.read_text(encoding="utf-8").strip()
    if not args.since:
        sys.exit("ERROR: --since <日付|yesterday> か --last を指定してください")
    if args.since == "yesterday":
        return (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
    return args.since


def cmd_report(args):
    since = resolve_report_since(args)
    today = datetime.date.today().isoformat()
    print(f"# フィードバックレポート({since} 以降 {today} まで)")
    print(
        "scope: local (source: .feedback/events.jsonl, .feedback/log/, "
        ".feedback/rules.md, .feedback/.last-*)"
    )
    es = entries()

    print()
    print("## 新規エントリ")
    new = [e for e in es if (e.get("date") or "") >= since]
    if not new:
        print("(なし)")
    for e in sorted(new, key=lambda e: (e.get("signal") or "unknown", e.get("category", ""))):
        title = next((ln[2:] for ln in e["body"].splitlines() if ln.startswith("# ")), "")
        print(f"- [{e.get('signal') or 'unknown'}/{e.get('category','-')}] {title} ({e.get('id')})")

    print()
    print("## 昇華・統合(rules.md)")
    promoted_rules = [r for r in rule_sources() if r["date"] and r["date"] >= since]
    if not promoted_rules:
        print("(なし)")
    for r in promoted_rules:
        print(f"- [{r['category']}] 出典 {', '.join(r['sources'])} ({r['date']} 昇華)")

    print()
    print("## close・retire")
    handled = [
        e for e in es
        if (e.get("status_changed") or "") >= since
        and e.get("status") in ("closed", "retired")
    ]
    if not handled:
        print("(なし)")
    for e in sorted(handled, key=lambda e: e.get("status_changed") or ""):
        print(f"- [{e.get('status')}] {e.get('id')} ({e.get('status_changed')})")

    print()
    print("## open 棚卸し")
    opens = [e for e in es if e.get("status") == "open"]
    if not opens:
        print("(open なし)")
    else:
        for e in sorted(opens, key=lambda e: e.get("date") or ""):
            print(f"- {e.get('id')} ({e.get('date', '?')}) [{e.get('signal') or 'unknown'}/{e.get('category','-')}]")
        if len(opens) >= OPEN_THRESHOLD:
            print(f"NOTE: open が{len(opens)}件 — promote/close を検討してください")

    print()
    print("## 再発候補")
    for line in recurrence_lines(recurrence_candidates()):
        print(line)

    print()
    print("## 監査・棚卸し")
    for line in audit_status_lines():
        print(line)
    for line in retro_status_lines():
        print(line)

    print()
    print("## WARN(ブロックしないが溜まっている指摘)")
    evs = load_events()
    warns, warn_last = {}, {}
    for e in evs:
        d = str(e.get("ts", ""))[:10]
        if e.get("result") != "warn" or d < since:
            continue
        k = e.get("check", "-")
        warns[k] = warns.get(k, 0) + 1
        if d > warn_last.get(k, ""):
            warn_last[k] = d
    if not warns:
        print("(なし)")
    cutoff = staleness_cutoff()
    for k, v in sorted(warns.items(), key=lambda kv: (-kv[1], kv[0])):
        # 累積件数だけでは、直った指摘と今も出ている指摘が同じ見た目になる
        note = f"(最終 {warn_last.get(k, '?')}"
        note += f" — {STALE_DAYS}日以上再発なし)" if warn_last.get(k, "") < cutoff else ")"
        print(f"- {k}: {v}件 {note}")

    print()
    print("## 数字")
    if not evs:
        print("(イベント記録が無い)")
    else:
        cur = post_edit_first_pass(evs, since, "9999-12-31")
        if not cur[1]:
            print("(期間内の post_edit イベントが無い)")
        else:
            line = f"PostToolUse 初回通過率: 当期間 {cur[0]}/{cur[1]}"
            # 前期間は「今回と同じ長さだけ遡った区間」。傾向の向きだけを見るための粗い比較
            span = abs((datetime.date.fromisoformat(since) - datetime.date.today()).days) or 1
            prev_to = (datetime.date.fromisoformat(since) - datetime.timedelta(days=1)).isoformat()
            prev_from = (datetime.date.fromisoformat(since) - datetime.timedelta(days=span)).isoformat()
            prev = post_edit_first_pass(evs, prev_from, prev_to)
            if prev[1]:
                line += f"(前期間 {prev[0]}/{prev[1]})"
            print(line)

    if args.mark:
        LAST_RETRO.parent.mkdir(parents=True, exist_ok=True)
        transaction(ROOT, "report-mark", [(LAST_RETRO, today)])
        print()
        print(f"(基点を更新しました: .feedback/.last-retro = {today})")


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

    stt = sub.add_parser("stats", help="フック合否とログの集計(初回通過率・再発候補)")
    stt.add_argument("--since", help="イベント集計の開始日 YYYY-MM-DD(既定: --days 日前から)")
    stt.add_argument("--days", type=int, default=30, help="イベント集計の期間日数(既定30)")
    stt.set_defaults(func=cmd_stats)

    rp = sub.add_parser("report", help="期間ダイジェスト(朝会・振り返りの議題)")
    rp.add_argument("--since", default="", help="開始日 YYYY-MM-DD または yesterday")
    rp.add_argument("--last", action="store_true", help=".last-retro 基点で期間を切る")
    rp.add_argument("--mark", action="store_true", help="実行後に .last-retro を今日で更新する")
    rp.set_defaults(func=cmd_report)

    r = sub.add_parser("rules", help="ルール一覧を表示")
    r.set_defaults(func=cmd_rules)

    args = p.parse_args()
    try:
        with state_lock(ROOT, LOCK_TIMEOUT_SECONDS):
            recovered = recover_transaction(ROOT)
            if recovered:
                print("NOTE: 中断されたfeedback transactionを回復しました", file=sys.stderr)
            args.func(args)
    except StoreError as exc:
        sys.exit(f"ERROR: {exc}")


if __name__ == "__main__":
    main()
# fmt: on
