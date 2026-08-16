#!/usr/bin/env bash
# test_stats.sh — stats の数値(初回通過率・再チェック回数・再発候補)を
# 既知の数値を持つフィクスチャに対して検証する。
#
# 期待値はリテラルで書く(検証対象の集計機構自身で期待値を算出しない)。
# 不正 JSON 行があっても集計が続くことも確認する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CLI="$REPO/scripts/feedback_log.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/project/.feedback/log"
export CLAUDE_PROJECT_DIR="$WORK/project"

fb() { python3 "$CLI" "$@"; }

# --- events フィクスチャ(数値既知。末尾に不正JSON行を混ぜる) ---
# post_edit: a.py は初回fail→pass、b.py は初回pass、c.py は fail,fail,pass
# → 全期間の初回通過率 1/3(33%)。fail総数3(a=1, c=2)/ファイル数3 = 平均1.00
# stop: pass, fail, pass → 2/3(67%)
cat > "$WORK/project/.feedback/events.jsonl" <<'EOF'
{"ts":"2026-08-10T01:00:00Z","hook":"post_edit","file":"src/a.py","result":"fail"}
{"ts":"2026-08-10T01:01:00Z","hook":"post_edit","file":"src/a.py","result":"pass"}
{"ts":"2026-08-11T02:00:00Z","hook":"post_edit","file":"src/b.py","result":"pass"}
{"ts":"2026-08-12T03:00:00Z","hook":"post_edit","file":"src/c.py","result":"fail"}
{"ts":"2026-08-12T03:01:00Z","hook":"post_edit","file":"src/c.py","result":"fail"}
{"ts":"2026-08-12T03:02:00Z","hook":"post_edit","file":"src/c.py","result":"pass"}
{"ts":"2026-08-13T04:00:00Z","hook":"stop","result":"pass"}
{"ts":"2026-08-13T05:00:00Z","hook":"stop","result":"fail"}
{"ts":"2026-08-13T06:00:00Z","hook":"stop","result":"pass"}
{"ts":"2026-08-13T07:00:00Z","hook":"stop","result":"warn","check":"python: ruff format"}
{"ts":"2026-08-13T08:00:00Z","hook":"stop","result":"warn","check":"python: ruff format"}
{"ts":"2026-08-13T09:00:00Z","hook":"stop","result":"warn","check":"config: yaml 構文"}
this is not json
EOF

# --- log フィクスチャ(手書き — 期日を固定するためCLI経由にしない) ---
cat > "$WORK/project/.feedback/log/20260701-000001-rule-src.md" <<'EOF'
---
id: 20260701-000001
date: 2026-07-01
source: human
category: style
status: promoted
---

# 元の指摘

根因: 指示欠陥
EOF
cat > "$WORK/project/.feedback/log/20260715-000001-recurrence.md" <<'EOF'
---
id: 20260715-000001
date: 2026-07-15
source: human
category: style
status: open
---

# 再発した同種の指摘

根因: 指示欠陥
EOF
cat > "$WORK/project/.feedback/log/20260716-000001-unrelated.md" <<'EOF'
---
id: 20260716-000001
date: 2026-07-16
source: agent
category: testing
status: open
---

# 別カテゴリのエントリ
EOF
cat > "$WORK/project/.feedback/rules.md" <<'EOF'
# フィードバック由来ルール

<!-- rules:failure -->
### 守るべき制約(失敗由来)

- **[style]** テスト用ルール本文
  <sub>出典: 20260701-000001 (2026-07-01 昇華)</sub>

<!-- rules:success -->
### 再現すべき措辞・進め方(成功由来)
EOF

OUT="$(fb stats --since 2026-08-10)"

# --- フック系(不正JSON行は読み飛ばされて数値が崩れない) ---
assert_contains "$OUT" "PostToolUse 初回通過率: 1/3 (33%)" "初回通過率(a=fail,b=pass,c=fail → 1/3)"
assert_contains "$OUT" "1ファイルあたりの平均再チェック回数: 1.00" "平均再チェック回数(fail3/3ファイル)"
assert_contains "$OUT" "Stop フルチェック初回通過率: 2/3 (67%)" "stop の pass 率"
# WARN イベントは stop の通過率の分母に混ぜない(warn は「テストの失敗」ではない)
assert_contains "$OUT" "頻出WARN: python: ruff format(2), config: yaml 構文(1)" "頻出WARNが件数降順で出る"
assert_contains "$OUT" "失敗上位: src/c.py(2), src/a.py(1)" "失敗上位(件数降順・ファイル名昇順)"

# --- 期間指定(a.py の2026-08-10を除外 → b,c の2ファイル) ---
OUT2="$(fb stats --since 2026-08-11)"
assert_contains "$OUT2" "PostToolUse 初回通過率: 1/2 (50%)" "期間フィルタが効く"

# --- ログ系(signal 無しは unknown、根因は本文から抽出) ---
assert_contains "$OUT" "signal:" "signal 集計行がある"
assert_contains "$OUT" "unknown 3" "signal無しエントリ3件は unknown に数えられる"
assert_contains "$OUT" "根因:" "根因集計行がある"
assert_contains "$OUT" "指示欠陥 2" "根因は本文の「根因:」行から数えられる"
assert_contains "$OUT" "category: style 2 / testing 1" "category 別件数"

# --- 再発候補(同カテゴリの失敗系のみ。別カテゴリは候補に出ない) ---
assert_contains "$OUT" "20260701-000001 (2026-07-01 昇華)" "再発候補に出典ルールが出る"
assert_contains "$OUT" "以降の同カテゴリ: 20260715-000001" "昇華日以降の同カテゴリ指摘が列挙される"
assert_not_contains "$OUT" "以降の同カテゴリ: 20260716-000001" "別カテゴリは再発候補に出ない"

# --- events が無いプロジェクトでも死なない ---
rm "$WORK/project/.feedback/events.jsonl"
OUT3="$(fb stats)"
assert_contains "$OUT3" "イベント記録が無い" "events.jsonl 不在でもログ集計を続ける"
assert_contains "$OUT3" "再発候補" "再発候補セクションは出る"

assert_summary
