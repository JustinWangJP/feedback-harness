#!/usr/bin/env bash
# test_rules_sections.sh — rules.md の2セクション構造(失敗由来/成功由来)を検証する。
#
# - セクションマーカーが無い既存 rules.md への遅延マイグレーション
#   (既存ルールは失敗セクション側に入る)
# - promote のセクション選択(signal の instruction/workflow → 成功、他 → 失敗)
# - 成功セクションのルールも retire で撤去できる
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CLI="$REPO/scripts/feedback_log.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/project"
( cd "$WORK/project" && git init -q . )
export CLAUDE_PROJECT_DIR="$WORK/project"

fb() { tpy "$CLI" "$@"; }
extract_id() { sed -n 's/.*(id=\(.*\))$/\1/p'; }
line_of() { grep -n -F "$1" "$WORK/project/.feedback/rules.md" | head -1 | cut -d: -f1; }
lt() { [[ "$1" -lt "$2" ]] && echo 1 || echo 0; }

# --- 遅延マイグレーション: 古い形式(マーカー無し・ルールあり)から始める ---
mkdir -p "$WORK/project/.feedback"
cat > "$WORK/project/.feedback/rules.md" <<'EOF'
# フィードバック由来ルール

ヘッダ行。

- **[style]** 既存ルール
  <sub>出典: 20260101-000000 (2026-01-01 昇華)</sub>
EOF

F1="$(fb add --category style --summary "失敗系の指摘" --detail "根因: 指示欠陥" | extract_id)"
I1="$(fb add --category workflow --summary "成功系の進め方" --detail "先に設計を固める" | extract_id)"
fb promote "$F1" --rule "失敗由来ルール" >/dev/null
fb promote "$I1" --rule "成功由来ルール" >/dev/null

RULES_FILE="$WORK/project/.feedback/rules.md"
RULES="$(cat "$RULES_FILE")"
assert_contains "$RULES" "<!-- rules:failure -->" "失敗セクションのマーカーが挿入される"
assert_contains "$RULES" "<!-- rules:success -->" "成功セクションのマーカーが挿入される"
assert_contains "$RULES" "既存ルール" "移行前の既存ルールが残る"

F_MARKER="$(line_of "<!-- rules:failure -->")"
S_MARKER="$(line_of "<!-- rules:success -->")"
assert_eq "1" "$(lt "$(line_of "既存ルール")" "$S_MARKER")" "既存ルールは失敗セクション内(successマーカーより前)"
assert_eq "1" "$(lt "$(line_of "失敗由来ルール")" "$S_MARKER")" "failure系のpromoteは失敗セクションに入る"
assert_eq "1" "$(lt "$S_MARKER" "$(line_of "成功由来ルール")")" "instruction/workflow系のpromoteは成功セクションに入る"
assert_eq "1" "$(lt "$F_MARKER" "$(line_of "既存ルール")")" "失敗マーカーは既存ルールより前(ヘッダ側)"

# --- 成功セクションのルールも retire で撤去できる ---
OUT="$(fb retire "$I1" --reason "プレイブック移行" 2>&1)"
assert_contains "$OUT" "retired:" "成功セクションのルールも retire できる"
assert_not_contains "$(cat "$RULES_FILE")" "成功由来ルール" "撤去後に本文が残らない"
assert_contains "$(cat "$RULES_FILE")" "<!-- rules:success -->" "撤去後もセクション構造は保たれる"
assert_contains "$(cat "$RULES_FILE")" "失敗由来ルール" "失敗セクションのルールは巻き添えにならない"

assert_summary
