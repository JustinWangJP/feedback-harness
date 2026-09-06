#!/usr/bin/env bash
# test_doc_inventory.sh — README の構成ツリーと履歴資料の扱いが実体からずれないことを検証する。
#
# 2026-08-30 の全体ドキュメント点検で、次の3つが同じ形で抜けていた:
#   - README の構成ツリーの `.feedback/` に `local/config.yaml`(個人設定レイヤ)が無い
#   - 同ツリーの `docs/` が pointer と superpowers だけで、後から足した
#     configuration ガイド・ドキュメント案内・proposals・references が載っていない
#   - `review/` がどの索引にも無く、履歴資料であることを示す注記も無い
#
# いずれも「資産を足したが README を直し忘れた」型で、期待値をテストへ書き並べると
# 同じ抜け方をする(AGENTS.md C11 の環境変数ドキュメント整合と同じ理由)。そのため
# 期待集合はコードと実ファイルから導出し、走査で書き漏れを捕まえる形にする。
#
# 初版はこの護欄自身が2つの穴を持っていた(2026-08-30 のレビュー指摘):
#   - tpy の終了コードを見ておらず、Python が例外で死ぬと空出力=合格になっていた
#   - 期待値をファイル名だけに潰して本文全体へ部分文字列照合していたため、
#     docs/README.md のツリー行を消しても scripts/ 側の README.md が一致し、
#     review/ のツリー行を消しても本文の言及が一致して緑のままだった
# 現在は、ツリーをインデントから正規化パスの集合へ復元し、パス同士で比較する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

READMES=(README.md README.ja.md README.zh-CN.md)
DOC_INDEXES=(docs/README.md docs/README.ja.md docs/README.zh-CN.md)

# --- 構成ツリーが実体を網羅している ---
# 期待集合の導出元:
#   .feedback/ … git 追跡ファイル + .gitignore の .feedback/ エントリ
#                + harness_config.py が読む config path(共有・個人)
#   docs/      … docs/ 直下の実エントリ
#   履歴資料   … 冒頭に履歴注記を持つ .md の置き場(その最上位ディレクトリ)
# いずれも正規化した相対パスで持ち、ツリー側も同じ形へ復元して突き合わせる。
for readme in "${READMES[@]}"; do
  MISSING="$(tpy - "$REPO" "$readme" <<'PY'
import pathlib, re, subprocess, sys

repo = pathlib.Path(sys.argv[1])
readme = repo / sys.argv[2]

# 履歴資料の注記ブロック。冒頭5行以内にこの形があるものだけを履歴資料と見なす
BANNER = re.compile(r"^> \*\*履歴資料:", re.M)


def tracked(prefix):
    out = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "-z", "--", prefix],
        capture_output=True, text=True, check=True,
    ).stdout
    return [p for p in out.split("\0") if p.strip()]


def top_entries(prefix):
    """prefix 直下のエントリを、ディレクトリは末尾スラッシュ付きの相対パスで返す。
    git 追跡分だけを見る — .DS_Store のような無視対象の OS 生成物まで
    README に載せろと要求しないため。"""
    found = set()
    for rel in tracked(prefix):
        rest = rel[len(prefix) + 1:]
        head = rest.split("/")[0]
        found.add(f"{prefix}/{head}" + ("/" if "/" in rest else ""))
    return found


expected = set()

# .feedback/ 配下 — 追跡ファイル(log/ 等はディレクトリで代表させる)
expected |= top_entries(".feedback")

# .feedback/ 配下 — 実行時状態(.gitignore が唯一の宣言場所)
for line in (repo / ".gitignore").read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if line.startswith(".feedback/") and not line.startswith("#"):
        expected.add(line)

# .feedback/ 配下 — ローダーが読む config path(共有・個人)
cfg = (repo / "scripts" / "harness_config.py").read_text(encoding="utf-8")
for m in re.finditer(r'^(?:LOCAL_)?CONFIG_RELPATH = "([^"]+)"', cfg, re.M):
    expected.add(m.group(1))

# docs/ 直下の実エントリ
expected |= top_entries("docs")

# 履歴資料の置き場。docs/ の外(review/ など)にもあるため、注記を持つ .md の
# 位置から導出する。トップレベル要素だけを要求する — 中身の列挙までは求めない。
# 判定は冒頭の注記ブロック(`> **履歴資料:`)に限る。本文で履歴資料に言及するだけの
# 文書(docs/README 等)まで履歴資料の置き場と見なさないため
for rel in tracked("."):
    if not rel.endswith(".md"):
        continue
    head = "\n".join((repo / rel).read_text(encoding="utf-8").split("\n")[:5])
    if BANNER.search(head) and "/" in rel:
        expected.add(rel.split("/")[0] + "/")

# 構成ツリーを正規化パスの集合へ復元する。
# 書式: 字下げ無しの行がトップレベル、字下げされた行はその直下。
# "                    #   retire / ..." のような継続コメント行は読み飛ばす。
tree_block = ""
for block in re.findall(r"^```[a-zA-Z]*\n(.*?)^```", readme.read_text(encoding="utf-8"), re.M | re.S):
    if re.search(r"^\.feedback/", block, re.M):
        tree_block = block
        break
if not tree_block:
    print("構成ツリー(.feedback/ を含む fenced block)が見つからない")
    raise SystemExit(0)

paths, current_top = set(), None
for raw in tree_block.split("\n"):
    if not raw.strip() or raw.strip().startswith("#"):
        continue
    name = raw.split("#")[0].strip()
    if not name:
        continue
    if raw[0] not in " \t":
        current_top = name
        paths.add(name)
    elif current_top and current_top.endswith("/"):
        paths.add(current_top + name)

# 期待パス P の網羅判定。`.feedback/local/` と `.feedback/local/config.yaml` は
# どちらの表記でもよいが、**親のトップレベル行では代用させない** — `docs/` の行が
# あるだけで `docs/configuration.md` を満たしてしまうと、子の行を消しても緑になり、
# まさにこの護欄が防ぎたかったドリフト(configuration ガイドの記載漏れ)を見逃す。
def covered(want):
    if want in paths:
        return True
    if want.endswith("/"):
        # ディレクトリの要求は、その中身が1行でも載っていれば満たされる
        return any(t != want and t.startswith(want) for t in paths)
    # ファイルの要求を代用できるのは、トップレベルより深いディレクトリ行だけ
    return any(t.endswith("/") and t.rstrip("/").count("/") >= 1 and want.startswith(t)
               for t in paths)


for want in sorted(expected):
    if not covered(want):
        print(want)
PY
)"
  STATUS=$?
  assert_eq "0" "$STATUS" "$readme のツリー検査が正常終了する(異常終了を空出力=合格にしない)"
  assert_eq "" "$MISSING" "$readme の構成ツリーが .feedback/ ・ docs/ ・履歴資料の置き場を網羅している"
done

# --- 履歴資料には注記が要る ---
# 注記の無い履歴資料は、実装済みの設計を現在の仕様として読ませる。特に plans/ は
# 冒頭が "implement this plan task-by-task" で、未チェックのチェックボックスを
# 持つため、注記が無いと未着手の作業指示として読める(実際に6ファイルで発生)。
# 対象ディレクトリは「注記を持つ .md が1つでもある置き場」から導出する — 種類を
# テストへ書き並べると、種類が増えたときに同じ形で漏れるため。
STALE="$(tpy - "$REPO" <<'PY'
import pathlib, re, subprocess, sys

repo = pathlib.Path(sys.argv[1])
BANNER = re.compile(r"^> \*\*履歴資料:", re.M)
files = [p for p in subprocess.run(
    ["git", "-C", str(repo), "ls-files", "-z", "--", "."],
    capture_output=True, text=True, check=True,
).stdout.split("\0") if p.strip().endswith(".md")]

heads = {rel: "\n".join((repo / rel).read_text(encoding="utf-8").split("\n")[:5])
         for rel in files}
historical_dirs = {str(pathlib.PurePosixPath(rel).parent)
                   for rel, head in heads.items() if BANNER.search(head)}

for rel, head in sorted(heads.items()):
    if str(pathlib.PurePosixPath(rel).parent) in historical_dirs and not BANNER.search(head):
        print(rel)
PY
)"
STATUS=$?
assert_eq "0" "$STATUS" "履歴注記の走査が正常終了する"
assert_eq "" "$STALE" "履歴資料の置き場にある .md すべてが冒頭に履歴注記を持つ"

# --- ドキュメント案内が履歴資料ディレクトリを網羅している ---
for index in "${DOC_INDEXES[@]}"; do
  BODY="$(cat "$REPO/$index")"
  for dir in "proposals/" "superpowers/specs/" "superpowers/plans/" "references/" "review/"; do
    assert_contains "$BODY" "$dir" "$index が履歴資料 $dir を案内している"
  done
done

assert_summary
