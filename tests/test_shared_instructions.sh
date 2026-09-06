#!/usr/bin/env bash
# 共通規約の読取経路、旧項目の移行先、文書追記案の契約を検証する。
# 意味の保存や実際の読取は本文レビューの責務。変異はメモリ内のコピーだけに加える。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

tpy - "$REPO" <<'PY'
import copy
import pathlib
import posixpath
import re
import subprocess
import sys

repo = pathlib.Path(sys.argv[1])
paths = subprocess.run(
    ["git", "-C", str(repo), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    capture_output=True, text=True, check=True,
).stdout.split("\0")
# 未追跡の新しい文書も検査する。fixture の削除は実ファイルへ触れず再現する。
documents = {p: (repo / p).read_text(encoding="utf-8")
             for p in paths if p.endswith(".md")}
PLAN = "docs/proposals/2026-09-06-shared-agent-instructions.md"
GUIDE = "docs/development-guide.md"
CURATOR = "agents/feedback-curator.md"
LOOP = "skills/feedback-loop/SKILL.md"
POINTERS = re.findall(r'"(docs/pointer_[^\"]+\.md)"',
                      (repo / "scripts/init.sh").read_text(encoding="utf-8"))
if len(POINTERS) < 2:
    raise SystemExit("init.sh の配布用ポインタを検出できません")


def links(text):
    # このテストが扱う文書の通常リンクのみ。一般的なリンク検査は md-links の責務。
    prose = re.sub(r"^```.*?^```[^\n]*", "", text, flags=re.M | re.S)
    prose = re.sub(r"`[^`]*`", "", prose)
    return re.findall(r"\[([^\]]*)\]\(([^)\s]+)\)", prose)


def target(source, href):
    path, _, anchor = href.partition("#")
    return posixpath.normpath(posixpath.join(posixpath.dirname(source), path)), anchor


def contracts(text):
    # YAML例のキーの構造だけを抽出し、説明文の言及での代用を許さない。
    result = {}
    for block in re.findall(r"^```yaml\n(.*?)^```", text, re.M | re.S):
        current = None
        for line in block.splitlines():
            header = re.fullmatch(r"([a-z_]+_candidates):", line)
            if header:
                current = header.group(1)
                if current in result:
                    raise ValueError("duplicate contract: " + current)
                result[current] = {}
            elif current:
                field = re.fullmatch(r"(?:  - |    )([a-z_]+):\s*(.*)", line)
                if field:
                    name, value = field.groups()
                    if name in result[current]:
                        raise ValueError("duplicate field: " + name)
                    result[current][name] = value
    return result


def validate(files):
    errors = []
    for required in ("AGENTS.md", "CLAUDE.md", PLAN, GUIDE, CURATOR, LOOP, *POINTERS):
        if required not in files:
            errors.append("missing-file: " + required)
    if errors:
        return errors

    # 期待集合を旧項目の対応表から導出する。件数だけや部分文字列では照合しない。
    ids = re.findall(r"^\| (C\d+)(?: ★)? \|", files[PLAN], re.M)
    if not ids or len(ids) != len(set(ids)):
        errors.append("source-inventory: missing or duplicate IDs")
    anchors = re.findall(r'<a id="(c\d+)"></a>', files["AGENTS.md"])
    if len(anchors) != len(set(anchors)):
        errors.append("rule-anchor: duplicate")
    for item in ids:
        if item.lower() not in anchors:
            errors.append("rule-anchor: " + item)
        body = re.search(
            rf'<a id="{item.lower()}"></a>\s*\*\*{item}\*\*([^\n]*)', files["AGENTS.md"])
        if not body or not body.group(1).strip():
            errors.append("rule-body: " + item)
    rows = [(label, href) for label, href in links(files[GUIDE])
            if re.fullmatch(r"C\d+", label)]
    if sorted(label for label, _ in rows) != sorted(ids):
        errors.append("migration-map: missing or duplicate rows")
    for label, href in rows:
        if target(GUIDE, href) != ("AGENTS.md", label.lower()):
            errors.append("migration-target: " + label)

    claude_refs = [target("CLAUDE.md", href) for _, href in links(files["CLAUDE.md"])]
    if ("AGENTS.md", "") not in claude_refs:
        errors.append("entry-reference: CLAUDE.md -> AGENTS.md")
    sections = re.findall(r"^##+ (.+)$", files["CLAUDE.md"], re.M)
    allowed = {"共通規約", "Claude Code 固有の設定"}
    if set(sections) != allowed or len(sections) != len(allowed):
        errors.append("claude-scope: unexpected or missing section; review content")

    agent_refs = {target("AGENTS.md", href) for _, href in links(files["AGENTS.md"])}
    for required in (".feedback/rules.md", GUIDE, "docs/history/development-history.md"):
        if (required, "") not in agent_refs or required not in files:
            errors.append("shared-reference: " + required)
    # 移行先の実体とアンカーはリンク経路の両側で確認する。
    for source in ("AGENTS.md", LOOP):
        if (CURATOR, "document-targets") not in {target(source, h) for _, h in links(files[source])}:
            errors.append("curator-reference: " + source)
    if '<a id="document-targets"></a>' not in files[CURATOR]:
        errors.append("curator-anchor: missing")

    canonical = contracts(files[CURATOR])
    if set(canonical) != {"automation_candidates", "document_candidates"}:
        errors.append("output-contract: missing proposal type")
    # 全 agent / skill と実際に配布するポインタの YAML例を走査。
    # 期待フィールドは curator から導出する。
    consumers = 0
    for path, text in files.items():
        if not path.startswith(("agents/", "skills/")) and path not in POINTERS:
            continue
        found = contracts(text)
        if not found:
            if path == LOOP or path in POINTERS:
                errors.append("output-contract: " + path)
            continue
        consumers += 1
        if {k: set(v) for k, v in found.items()} != {k: set(v) for k, v in canonical.items()}:
            errors.append("output-contract: " + path)
        if any(fields.get("human_decision") != "pending" for fields in found.values()):
            errors.append("approval-state: " + path)
    if consumers < 2 + len(POINTERS):
        errors.append("output-contract: scan did not reach curator, orchestrator and pointers")
    readmes = [p for p in files if re.fullmatch(r"README(?:\.[\w-]+)?\.md", p)]
    if not readmes:
        errors.append("contract-docs: no README scanned")
    for path in readmes:
        for name, fields in canonical.items():
            paragraphs = [line for line in files[path].splitlines() if f"`{name}`" in line]
            if not any(all(f"`{field}`" in line for field in fields) for line in paragraphs):
                errors.append("contract-docs: " + path + ": " + name)
    return errors


failures = []


def check(condition, label):
    if not condition:
        failures.append(label)
        print("FAIL: " + label)


errors = validate(documents)
check(not errors, "repository: " + "; ".join(errors))

# 本物の文書を入力にしてから欠陥を再注入する。空の走査や別名の fixture で合格させない。
first = re.findall(r"^\| (C\d+)(?: ★)? \|", documents[PLAN], re.M)[0]
mutations = [
    ("entry-reference", "CLAUDE.md", lambda s: s.replace(
        "[AGENTS.md](AGENTS.md)", "[AGENTS.md](docs/AGENTS.md)")),
    ("rule-anchor", "AGENTS.md", lambda s: s.replace(f'<a id="{first.lower()}"></a>', "")),
    ("rule-body", "AGENTS.md", lambda s: re.sub(
        rf'(<a id="{first.lower()}"></a>\s*\*\*{first}\*\*)[^\n]*', r"\1", s)),
    ("migration-map", GUIDE, lambda s: "\n".join(
        line for line in s.splitlines() if not line.startswith(f"| [{first}]"))),
    ("migration-target", GUIDE, lambda s: s.replace(
        f"../AGENTS.md#{first.lower()}", f"../scripts/AGENTS.md#{first.lower()}")),
    ("migration-target", GUIDE, lambda s: s.replace(
        f"../AGENTS.md#{first.lower()}", "../AGENTS.md#missing")),
    ("claude-scope", "CLAUDE.md", lambda s: s + "\n## 共通の開発制約\n追加された規約\n"),
    ("curator-anchor", CURATOR, lambda s: s.replace('<a id="document-targets"></a>', "")),
    ("output-contract", LOOP, lambda s: "\n".join(
        line for line in s.splitlines() if not line.startswith("    read_path:"))),
    ("approval-state", CURATOR, lambda s: s.replace("human_decision: pending", "human_decision: approved")),
    ("contract-docs", "README.md", lambda s: s.replace("`read_path`", "read path")),
]
for expected, path, mutate in mutations:
    fixture = copy.copy(documents)
    fixture[path] = mutate(fixture[path])
    check(fixture[path] != documents[path], "mutation changed input: " + expected)
    detected = validate(fixture)
    check(any(e.startswith(expected + ":") for e in detected), "mutation detected: " + expected)
for path in POINTERS:
    fixture = copy.copy(documents)
    fixture[path] = "\n".join(line for line in fixture[path].splitlines()
                             if not line.startswith("    read_path:"))
    check(fixture[path] != documents[path], "pointer mutation changed input: " + path)
    check(any(e.startswith("output-contract:") for e in validate(fixture)),
          "pointer contract drift detected: " + path)
fixture = copy.copy(documents)
del fixture[GUIDE]
check(any(e.startswith("missing-file:") for e in validate(fixture)), "missing guide detected")

if failures:
    raise SystemExit(1)
print(f"共通規約: {len(documents)}文書を走査、旧項目の参照と出力契約、{len(mutations) + len(POINTERS) + 1}種の欠陥再注入が成功")
PY
STATUS=$?
assert_eq "0" "$STATUS" "共通規約の構造と検査自身の欠陥検出"

assert_summary
