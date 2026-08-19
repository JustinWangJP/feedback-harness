#!/usr/bin/env bash
# test_signal_inference.sh — add --signal の推論規則・明示指定優先・
# 既存エントリ(signal無し)の unknown 扱いを検証する。
#
# signal は起きた出来事の種類、根因は失敗の原因として別々に扱う。
# 根因が何であっても、誤った出力や行動への指摘は failure 信号になる。
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
assert_eq "failure" "$(entry_signal "$S1")" "根因:文脈欠落 → failure"

S2="$(fb add --category architecture --summary "指示欠陥の指摘" --detail "根因: 指示欠陥" | extract_id)"
assert_eq "failure" "$(entry_signal "$S2")" "根因:指示欠陥 → failure"

S3="$(fb add --category testing --summary "モデル限界の指摘" --detail "根因: モデル限界" | extract_id)"
assert_eq "failure" "$(entry_signal "$S3")" "根因:モデル限界 → failure"

S4="$(fb add --category testing --summary "実行誤りの指摘" --detail "根因: 実行誤り" | extract_id)"
assert_eq "failure" "$(entry_signal "$S4")" "根因:実行誤り → failure"

S5="$(fb add --category domain --summary "未判定の指摘" --detail "根因: 未判定" | extract_id)"
assert_eq "failure" "$(entry_signal "$S5")" "根因:未判定 → failure"

S6="$(fb add --category workflow --summary "効いた進め方" --detail "設計を先に固めると良かった" | extract_id)"
assert_eq "workflow" "$(entry_signal "$S6")" "根因なし+category=workflow → workflow"

S7="$(fb add --category style --summary "効いた措辞" --detail "〜という言い方が効いた" | extract_id)"
assert_eq "instruction" "$(entry_signal "$S7")" "根因なし+その他カテゴリ → instruction"

# --- 明示指定が推論に勝る ---
S8="$(fb add --category style --summary "明示指定" --detail "根因: 指示欠陥" --signal workflow | extract_id)"
assert_eq "workflow" "$(entry_signal "$S8")" "明示指定が推論より優先"

# --- context は失敗原因ではなく、前提情報の追加として明示する ---
S9="$(fb add --category domain --summary "前提情報の追加" --detail "対象環境のバージョンを共有する" --signal context | extract_id)"
assert_eq "context" "$(entry_signal "$S9")" "明示した前提情報 → context"

# --- 未定義の根因は signal を誤推論する前に拒否する ---
BEFORE_INVALID="$(find "$WORK/project/.feedback/log" -type f | wc -l | tr -d ' ')"
INVALID_OUT="$(fb add --category workflow --summary "未定義の根因" --detail "根因: 独自分類" 2>&1)"
INVALID_RC=$?
if [[ "$INVALID_RC" == "0" ]]; then
  fail "未定義の根因が拒否されなかった"
fi
assert_contains "$INVALID_OUT" "根因は次のいずれかを1件指定してください" \
  "未定義の根因に許可値を案内する"
AFTER_INVALID="$(find "$WORK/project/.feedback/log" -type f | wc -l | tr -d ' ')"
assert_eq "$BEFORE_INVALID" "$AFTER_INVALID" "未定義の根因ではエントリを作らない"

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
assert_contains "$FAIL_LIST" "文脈欠落の指摘" "文脈欠落が根因でも failure に出る"
assert_contains "$FAIL_LIST" "実行誤りの指摘" "実行誤りも failure に出る"
assert_contains "$FAIL_LIST" "未判定の指摘" "未判定でも失敗への指摘は failure に出る"
assert_not_contains "$FAIL_LIST" "効いた措辞" "instruction エントリは failure の絞り込みに出ない"
assert_not_contains "$FAIL_LIST" "移行前のエントリ" "signal 無しエントリは failure の絞り込みに出ない"

CONTEXT_LIST="$(fb list --status open --signal context)"
assert_contains "$CONTEXT_LIST" "前提情報の追加" "context 指定で前提情報が出る"
assert_not_contains "$CONTEXT_LIST" "文脈欠落の指摘" "文脈欠落という根因だけでは context に出ない"

# --- signal と category は AND で効く ---
# S6(signal=workflow/category=workflow)と S8(signal=workflow/category=style)は
# signal が同じで category だけ違うため、1組で AND 条件を検証できる
BOTH="$(fb list --status open --signal workflow --category style)"
assert_contains "$BOTH" "明示指定" "signal と category の両方に合致すれば出る"
assert_not_contains "$BOTH" "効いた進め方" "signal が合っても category が違えば出ない"

assert_summary
