#!/usr/bin/env bash
# test_init_sh.sh — scripts/init.sh の展開内容と冪等性を検証する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

mkdir -p "$WORK/target"
( cd "$WORK/target" && git init -q . )

# shellcheck disable=SC2034  # 失敗時の調査用に出力を保持しておく(現状は未参照)
OUT="$(bash "$REPO/scripts/init.sh" "$WORK/target" 2>&1)"
assert_eq "0" "$?" "init.sh が成功する"

# Codex 向けにベンダリングされるもの
assert_file_exists "$WORK/target/scripts/check.sh" "check.sh"
assert_file_exists "$WORK/target/scripts/check_file.sh" "check_file.sh"
assert_file_exists "$WORK/target/scripts/lib.sh" "lib.sh"
assert_file_exists "$WORK/target/scripts/feedback_log.py" "feedback_log.py"
assert_file_exists "$WORK/target/AGENTS.md" "AGENTS.md"
assert_file_exists "$WORK/target/CLAUDE.md" "CLAUDE.md"
assert_file_exists "$WORK/target/.feedback/rules.md" "rules.md"

# プラグインが担う領域はコピーしない
assert_file_absent "$WORK/target/.claude/skills" ".claude/skills をコピーしない"
assert_file_absent "$WORK/target/.claude/agents" ".claude/agents をコピーしない"
assert_file_absent "$WORK/target/.claude/settings.json" ".claude/settings.json をコピーしない"
assert_file_absent "$WORK/target/scripts/hooks" "hooks ラッパーをコピーしない"

# 実行権限
if [[ -x "$WORK/target/scripts/check.sh" ]]; then :; else fail "check.sh に実行権限がない"; fi

# ベンダリングした check.sh が対象プロジェクトで動く
( cd "$WORK/target" && bash scripts/check.sh >/dev/null 2>&1 )
RC=$?
if [[ $RC -ne 0 && $RC -ne 1 ]]; then
  fail "ベンダリングした check.sh が異常終了した (exit=$RC)"
fi

# 冪等性: 2回目でポインタが重複しない
BEFORE_C="$(grep -c 'ハーネス: フィードバックループ' "$WORK/target/CLAUDE.md")"
BEFORE_A="$(grep -c 'フィードバックハーネス' "$WORK/target/AGENTS.md")"
bash "$REPO/scripts/init.sh" "$WORK/target" >/dev/null 2>&1
assert_eq "$BEFORE_C" "$(grep -c 'ハーネス: フィードバックループ' "$WORK/target/CLAUDE.md")" "CLAUDE.md のポインタが重複しない"
assert_eq "$BEFORE_A" "$(grep -c 'フィードバックハーネス' "$WORK/target/AGENTS.md")" "AGENTS.md のポインタが重複しない"

# 既存 rules.md を上書きしない
printf 'MY OWN RULES\n' > "$WORK/target/.feedback/rules.md"
bash "$REPO/scripts/init.sh" "$WORK/target" >/dev/null 2>&1
assert_eq "MY OWN RULES" "$(cat "$WORK/target/.feedback/rules.md")" "既存 rules.md を保護する"

# 自分自身への導入は拒否する
if bash "$REPO/scripts/init.sh" "$REPO" >/dev/null 2>&1; then
  fail "自分自身への導入が拒否されなかった"
fi

assert_summary
