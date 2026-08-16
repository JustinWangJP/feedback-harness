#!/usr/bin/env bash
# test_report.sh — report の期間集計(新規/昇華/close・retire/open/再発候補/数字)、
# status_changed の記録、--last/--mark の基点スタンプを検証する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CLI="$REPO/scripts/feedback_log.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/project/.feedback/log" "$WORK/project2"
( cd "$WORK/project" && git init -q . ) >/dev/null 2>&1
export CLAUDE_PROJECT_DIR="$WORK/project"

fb() { python3 "$CLI" "$@"; }
extract_id() { sed -n 's/.*(id=\(.*\))$/\1/p'; }

# --- フィクスチャ(期日固定のため log/rules は手書き) ---
cat > "$WORK/project/.feedback/log/20260701-000001-rule-src.md" <<'EOF'
---
id: 20260701-000001
date: 2026-07-01
source: human
category: style
status: promoted
status_changed: 2026-07-01
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
cat > "$WORK/project/.feedback/log/20260720-000001-closed.md" <<'EOF'
---
id: 20260720-000001
date: 2026-07-20
source: human
category: naming
status: closed
status_changed: 2026-07-21
---

# 一回限りの指摘
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
cat > "$WORK/project/.feedback/events.jsonl" <<'EOF'
{"ts":"2026-08-10T01:00:00Z","hook":"post_edit","file":"src/a.py","result":"fail"}
{"ts":"2026-08-10T01:01:00Z","hook":"post_edit","file":"src/a.py","result":"pass"}
{"ts":"2026-08-14T02:00:00Z","hook":"post_edit","file":"src/b.py","result":"pass"}
EOF

OUT="$(fb report --since 2026-07-10)"

# --- セクション構造と期間フィルタ ---
assert_contains "$OUT" "フィードバックレポート(2026-07-10 以降" "ヘッダに期間が出る"
assert_contains "$OUT" "## 新規エントリ" "新規エントリセクションがある"
assert_contains "$OUT" "20260715-000001" "期間内の新規エントリが出る"
assert_contains "$OUT" "20260720-000001" "期間内のもう1件も出る"
assert_not_contains "$OUT" "20260701-000001)" "期間前のエントリは新規に出ない(id括弧付きで照合)"
assert_contains "$OUT" "## close・retire" "close・retire セクションがある"
assert_contains "$OUT" "[closed] 20260720-000001 (2026-07-21)" "status_changed 日付で close が出る"
assert_contains "$OUT" "## 再発候補" "再発候補セクションがある"
assert_contains "$OUT" "以降の同カテゴリ: 20260715-000001" "再発候補の本文"
# 昇華セクション: 期間前の昇華(2026-07-01)は出ない(「出典 」プレフィックスは
# 昇華セクションだけで、再発候補行はプレフィックス無し — こちらで区別して照合する)
assert_not_contains "$OUT" "出典 20260701-000001" "期間前の昇華は載らない"
# 数字セクション: events があるので初回通過率が出る
assert_contains "$OUT" "PostToolUse 初回通過率:" "イベント数字が出る"

# --- status_changed が CLI 経由で書かれる ---
CID="$(fb add --category style --summary "close確認用" --detail "" | extract_id)"
fb close "$CID" --reason "テスト" >/dev/null
CLOSED_FILE="$(grep -rl "^id: ${CID}\$" "$WORK/project/.feedback/log")"
assert_contains "$(cat "$CLOSED_FILE")" "status_changed:" "close が status_changed を書く"

# --- --mark で基点スタンプが更新され、--last で読める ---
TODAY="$(python3 -c 'import datetime; print(datetime.date.today().isoformat())')"
fb report --since 2026-07-10 --mark >/dev/null
assert_file_exists "$WORK/project/.feedback/.last-retro" "--mark で .last-retro が作られる"
assert_contains "$(cat "$WORK/project/.feedback/.last-retro")" "$TODAY" "スタンプには今日の日付が入る"
assert_contains "$(fb report --last)" "フィードバックレポート" "--last でスタンプ基点のレポートが出る"

# --- yesterday ショートカット ---
YESTERDAY="$(python3 -c 'import datetime; print((datetime.date.today()-datetime.timedelta(days=1)).isoformat())')"
assert_contains "$(fb report --since yesterday)" "$YESTERDAY 以降" "--since yesterday が解決される"

# --- スタンプが無い状態での --last は明示的エラー ---
ERR="$(cd "$WORK/project2" && CLAUDE_PROJECT_DIR="$WORK/project2" python3 "$CLI" report --last 2>&1 || true)"
assert_contains "$ERR" ".last-retro がありません" "スタンプ不在の --last はエラーメッセージを出す"

assert_summary
