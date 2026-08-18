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

OUT="$(bash "$REPO/scripts/init.sh" "$WORK/target" 2>&1)"
assert_eq "0" "$?" "init.sh が成功する: $OUT"

# Codex 向けにベンダリングされるもの
assert_file_exists "$WORK/target/scripts/check.sh" "check.sh"
assert_file_exists "$WORK/target/scripts/check_file.sh" "check_file.sh"
assert_file_exists "$WORK/target/scripts/lib.sh" "lib.sh"
assert_file_exists "$WORK/target/scripts/feedback_log.py" "feedback_log.py"
# audit.sh は導入先に必要。scripts/README.md が使い方を載せ、feedback_log.py の
# stats/report が「bash scripts/audit.sh の実行を推奨」と案内するため、
# 配り漏れると案内先が存在しないコマンドになる
assert_file_exists "$WORK/target/scripts/audit.sh" "audit.sh"
# harness_config.py は全スクリプトが config(.feedback/config.yaml)を読むための
# 唯一のパーサ。欠けると config が効かないまま導入先が動く
assert_file_exists "$WORK/target/scripts/harness_config.py" "harness_config.py"
assert_file_exists "$WORK/target/AGENTS.md" "AGENTS.md"
assert_file_exists "$WORK/target/CLAUDE.md" "CLAUDE.md"
assert_file_exists "$WORK/target/.feedback/rules.md" "rules.md"
# config の雛形。config.yaml 自体は自動生成しない(置いただけで「設定した」ように
# 見えないため)ため、利用者はこの雛形から始める
assert_file_exists "$WORK/target/.feedback/config.example.yaml" "config.example.yaml"

# プラグインが担う領域はコピーしない
assert_file_absent "$WORK/target/.claude/skills" ".claude/skills をコピーしない"
assert_file_absent "$WORK/target/.claude/agents" ".claude/agents をコピーしない"
assert_file_absent "$WORK/target/.claude/settings.json" ".claude/settings.json をコピーしない"
assert_file_absent "$WORK/target/scripts/hooks" "hooks ラッパーをコピーしない"

# 実行権限
if [[ -x "$WORK/target/scripts/check.sh" ]]; then :; else fail "check.sh に実行権限がない"; fi

# ベンダリングした check.sh が対象プロジェクトで exit 0 になる。
# ルートに README.md を置く(一般的な導入先と同じ状態)。「0か1なら可」の緩い
# 判定にしていた頃、配布物の相対リンク切れが md-links FAIL として見逃されて
# いた — docs/ は配布対象外のため、scripts/README.md から docs/ への
# リンクを足すと必ず壊れる(2026-08-18 のレビューで発見)
printf '# Target README\n' > "$WORK/target/README.md"
( cd "$WORK/target" && bash scripts/check.sh >/dev/null 2>&1 )
RC=$?
if [[ "$RC" != "0" ]]; then
  fail "ベンダリングした check.sh が exit 0 にならない (exit=$RC) — 配布物のリンク切れ等の可能性"
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
