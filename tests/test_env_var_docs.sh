#!/usr/bin/env bash
# test_env_var_docs.sh — 入力用の環境変数と README の一覧が一致していることを検証する。
#
# PR #13 が HARNESS_PYTHON を足したとき、3言語の README どれにも載らなかった。
# 「環境変数を1つ足す」は既存の表へ1行足すだけの作業なので、レビューでしか
# 気づけない形で抜ける。期待値をここへ書き並べると同じ抜け方をするため、
# 期待集合はコードから導出する:
#
#   config を上書きする変数 : harness_config.py の ENV_STAGE_SKIP と
#                             ENV_PARAM_OVERRIDES の key
#   shell 側の入力変数      : scripts/ が読む変数から、設定ローダーが出力する
#                             変数(= 入力ではなく内部の受け渡し)を引いたもの
#
# これで harness_config.py へ上書き口を足しても、lib.sh 等で新しい変数を
# 読み始めても、README を直すまでこのテストが落ちる。
#
# Python の起動はすべて harness_python(境界)経由にする。素の python3 を使うと
# Windows では stdout が CRLF になり、期待値だけに CR が混ざって「表示は同じ
# なのに一致しない」失敗になる(2026-08-24 の Windows CI で実際に発生)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ローダーが出力する変数名(入力ではないので期待集合から除く)
EMITTED="$(bash -c '. "$1/lib.sh"; harness_python "$1/harness_config.py" --shell "$2"' \
  _ "$REPO/scripts" "$REPO" 2>/dev/null | sed -E 's/^export //; s/=.*//')"
[[ -n "$EMITTED" ]] || fail "設定ローダーの出力を取得できません(期待集合を導出できない)"

cat > "$WORK/derive.py" <<'PY'
import os
import re
from pathlib import Path

repo = Path(os.environ["TEST_REPO"])
emitted = {line.strip() for line in os.environ["TEST_EMITTED"].splitlines() if line.strip()}

# check.sh が make の子孫へ意図的に伝える再帰切断フラグ。利用者が設定するもの
# ではないため一覧に載せない(scripts/README の該当節で説明している)
internal = {"FEEDBACK_CHECK_RECURSION_GUARD"}

names = set()
shell_files = sorted(repo.glob("scripts/**/*.sh"))
if not shell_files:
    raise SystemExit(f"scripts/ 配下の *.sh を列挙できません: {repo}")
for path in shell_files:
    text = path.read_text(encoding="utf-8")
    names |= set(re.findall(r"\$\{?((?:FEEDBACK|HARNESS|CLAUDE)_[A-Z0-9_]+)", text))

config_src = (repo / "scripts" / "harness_config.py").read_text(encoding="utf-8")
stage = re.search(r'ENV_STAGE_SKIP\s*=\s*"([A-Z_]+)"', config_src)
if not stage:
    raise SystemExit("ENV_STAGE_SKIP を読み取れません")
overrides = re.search(r"ENV_PARAM_OVERRIDES\s*=\s*\{(.*?)\}", config_src, re.S)
if not overrides:
    raise SystemExit("ENV_PARAM_OVERRIDES を読み取れません")

expected = names - emitted - internal
expected.add(stage.group(1))
expected |= set(re.findall(r'"([A-Z_]+)":', overrides.group(1)))
print("\n".join(sorted(expected)))
PY

# TEST_REPO は env 経由なので _harness_python_exec の path 変換が掛からない。
# Git Bash の /d/... のままでは Windows Python が別のドライブ相対 path として
# 解釈するため、ここで明示的に native path へ直す。
EXPECTED="$(TEST_EMITTED="$EMITTED" TEST_REPO="$(native_path "$REPO")" \
  bash -c '. "$1"; harness_python "$2"' _ "$LIB" "$WORK/derive.py")"
[[ -n "$EXPECTED" ]] || fail "期待集合を導出できません"

assert_contains "$EXPECTED" "HARNESS_PYTHON" \
  "導出が機能している(HARNESS_PYTHON を入力変数として拾う): $EXPECTED"

for readme in README.md README.ja.md README.zh-CN.md; do
  # 環境変数の表に現れる `VAR` だけを取る。行末の CR(Windows チェックアウト)は
  # 落としてから比較する — 比べたいのは変数名の集合であって改行の形ではない
  # shellcheck disable=SC2016  # \1 は sed の後方参照。shell に展開させない
  DOCUMENTED="$(sed -E 's/\r$//' "$REPO/$readme" \
    | sed -nE 's/^\| *`((FEEDBACK|HARNESS|CLAUDE)_[A-Z0-9_]+)`.*/\1/p' | sort -u)"
  assert_eq "$EXPECTED" "$DOCUMENTED" \
    "$readme の環境変数一覧がコード側の入力変数と一致する"
done

assert_summary
