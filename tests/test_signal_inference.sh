#!/usr/bin/env bash
# test_signal_inference.sh — add --signal の推論規則・明示指定優先・
# 既存エントリ(signal無し)の unknown 扱いを検証する。
#
# signal は昇華先ルーティングの軸。推論を誤ると context 信号が rules.md に
# 昇華される(本来の行き先は CLAUDE.md)などの迷子になる。
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

fb() { python3 "$CLI" "$@"; }
extract_id() { sed -n 's/.*(id=\(.*\))$/\1/p'; }
entry_signal() { # entry_signal <id> — frontmatter の signal(無ければ unknown)
  local f
  f="$(grep -rl "^id: $1\$" "$WORK/project/.feedback/log")"
  if grep -q "^signal: " "$f"; then
    sed -n 's/^signal: //p' "$f" | head -1
  else
    echo "unknown"
  fi
}

# --- 推論規則(明示指定なし) ---
S1="$(fb add --category style --summary "文脈欠落の指摘" --detail "根因: 文脈欠落" | extract_id)"
assert_eq "context" "$(entry_signal "$S1")" "根因:文脈欠落 → context"

S2="$(fb add --category architecture --summary "指示欠陥の指摘" --detail "根因: 指示欠陥" | extract_id)"
assert_eq "failure" "$(entry_signal "$S2")" "根因:指示欠陥 → failure"

S3="$(fb add --category testing --summary "モデル限界の指摘" --detail "根因: モデル限界" | extract_id)"
assert_eq "failure" "$(entry_signal "$S3")" "根因:モデル限界 → failure"

S4="$(fb add --category workflow --summary "効いた進め方" --detail "設計を先に固めると良かった" | extract_id)"
assert_eq "workflow" "$(entry_signal "$S4")" "根因なし+category=workflow → workflow"

S5="$(fb add --category style --summary "効いた措辞" --detail "〜という言い方が効いた" | extract_id)"
assert_eq "instruction" "$(entry_signal "$S5")" "根因なし+その他カテゴリ → instruction"

# --- 明示指定が推論に勝る ---
S6="$(fb add --category style --summary "明示指定" --detail "根因: 指示欠陥" --signal workflow | extract_id)"
assert_eq "workflow" "$(entry_signal "$S6")" "明示指定が推論より優先"

# --- 既存エントリ(signal 無し)は unknown で絞り込める ---
cat > "$WORK/project/.feedback/log/20260101-000000-legacy.md" <<'EOF'
---
id: 20260101-000000
date: 2026-01-01
source: human
category: style
status: open
---

# 移行前のエントリ
EOF
assert_contains "$(fb list --status open --signal unknown)" "20260101-000000" "signal無しエントリは unknown で絞り込める"
assert_not_contains "$(fb list --status open --signal context)" "20260101-000000" "unknown は他の信号種に出ない"

# --- signal による正の絞り込み(unknown 以外)---
# 照合は ID ではなく要約で行う: 同一秒に作られた ID には -2/-3 が付くため、
# 片方の ID がもう片方の部分文字列になり assert_not_contains が誤検知する
FAIL_LIST="$(fb list --status open --signal failure)"
assert_contains "$FAIL_LIST" "指示欠陥の指摘" "failure 指定で failure エントリが出る"
assert_contains "$FAIL_LIST" "モデル限界の指摘" "同じ signal の別エントリもまとめて出る"
assert_not_contains "$FAIL_LIST" "文脈欠落の指摘" "context エントリは failure の絞り込みに出ない"
assert_not_contains "$FAIL_LIST" "効いた措辞" "instruction エントリは failure の絞り込みに出ない"
assert_not_contains "$FAIL_LIST" "移行前のエントリ" "signal 無しエントリは failure の絞り込みに出ない"

# --- signal と category は AND で効く ---
# S4(signal=workflow/category=workflow)と S6(signal=workflow/category=style)は
# signal が同じで category だけ違うため、1組で AND 条件を検証できる
BOTH="$(fb list --status open --signal workflow --category style)"
assert_contains "$BOTH" "明示指定" "signal と category の両方に合致すれば出る"
assert_not_contains "$BOTH" "効いた進め方" "signal が合っても category が違えば出ない"

assert_summary
