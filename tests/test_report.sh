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

fb() { tpy "$CLI" "$@"; }
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
{"ts":"2026-08-14T03:00:00Z","hook":"stop","result":"warn","check":"python: ruff format"}
EOF

OUT="$(fb report --since 2026-07-10)"
assert_contains "$OUT" "scope: local" "report はローカル集計であることを明示する"
assert_contains "$OUT" ".feedback/log/" "report はデータ元を明示する"

# --- セクション構造と期間フィルタ ---
assert_contains "$OUT" "フィードバックレポート(2026-07-10 以降" "ヘッダに期間が出る"
assert_contains "$OUT" "## 新規エントリ" "新規エントリセクションがある"
assert_contains "$OUT" "20260715-000001" "期間内の新規エントリが出る"
assert_contains "$OUT" "20260720-000001" "期間内のもう1件も出る"
assert_not_contains "$OUT" "20260701-000001)" "期間前のエントリは新規に出ない(id括弧付きで照合)"
assert_contains "$OUT" "## close・retire" "close・retire セクションがある"
assert_contains "$OUT" "[closed] 20260720-000001 (2026-07-21)" "status_changed 日付で close が出る"
assert_contains "$OUT" "## 再発候補" "再発候補セクションがある"
assert_contains "$OUT" "20260715-000001(参考 " "再発候補の本文(読む順のヒントつき)"
# 昇華セクション: 期間前の昇華(2026-07-01)は出ない(「出典 」プレフィックスは
# 昇華セクションだけで、再発候補行はプレフィックス無し — こちらで区別して照合する)
assert_not_contains "$OUT" "出典 20260701-000001" "期間前の昇華は載らない"
# 数字セクション: events があるので初回通過率が出る
assert_contains "$OUT" "PostToolUse 初回通過率:" "イベント数字が出る"
assert_contains "$OUT" "## WARN" "WARN セクションがある"
assert_contains "$OUT" "python: ruff format: 1件" "WARN の件数が出る"
# 件数だけでは、直った指摘と今も出ている指摘が同じ見た目になる
assert_contains "$OUT" "最終 " "WARN に最終発生日が併記される"
assert_contains "$OUT" "日以上再発なし" "古いWARNには鮮度の注記が付く"

# --- status_changed が CLI 経由で書かれる ---
CID="$(fb add --category style --summary "close確認用" --detail "" | extract_id)"
fb close "$CID" --reason "テスト" >/dev/null
CLOSED_FILE="$(grep -rl "^id: ${CID}\$" "$WORK/project/.feedback/log")"
assert_contains "$(cat "$CLOSED_FILE")" "status_changed:" "close が status_changed を書く"

# --- --mark で基点スタンプが更新され、--last で読める ---
TODAY="$(tpy -c 'import datetime; print(datetime.date.today().isoformat())')"
fb report --since 2026-07-10 --mark >/dev/null
assert_file_exists "$WORK/project/.feedback/.last-retro" "--mark で .last-retro が作られる"
assert_contains "$(cat "$WORK/project/.feedback/.last-retro")" "$TODAY" "スタンプには今日の日付が入る"
assert_contains "$(fb report --last)" "フィードバックレポート" "--last でスタンプ基点のレポートが出る"

# --- yesterday ショートカット ---
YESTERDAY="$(tpy -c 'import datetime; print((datetime.date.today()-datetime.timedelta(days=1)).isoformat())')"
assert_contains "$(fb report --since yesterday)" "$YESTERDAY 以降" "--since yesterday が解決される"

# --- スタンプが無い状態での --last は明示的エラー ---
ERR="$(cd "$WORK/project2" && CLAUDE_PROJECT_DIR="$WORK/project2" tpy "$CLI" report --last 2>&1 || true)"
assert_contains "$ERR" ".last-retro がありません" "スタンプ不在の --last はエラーメッセージを出す"

# --- 数字: 前期間との比較(設計 §5-7)---
# 前期間は「since から今日までと同じ長さだけ遡った区間」。窓が実行日を基準に
# 動くため、固定日付のフィクスチャでは検証できない — 日付は今日からの相対で組む。
# 既存フィクスチャに混ぜると上の期間フィルタの期待値が動くので別プロジェクトで測る
days_ago() { tpy -c 'import datetime,sys; print((datetime.date.today()-datetime.timedelta(days=int(sys.argv[1]))).isoformat())' "$1"; }
mkdir -p "$WORK/project3/.feedback"
SINCE_REL="$(days_ago 4)"   # span=4 → 前期間は [今日-8, 今日-5]
{
  # 当期間([今日-4, ∞)): 初回 pass の1ファイル → 1/1
  printf '{"ts":"%sT01:00:00Z","hook":"post_edit","file":"src/cur.py","result":"pass"}\n' "$(days_ago 2)"
  # 前期間([今日-8, 今日-5]): 初回 fail の1ファイル → 0/1
  printf '{"ts":"%sT01:00:00Z","hook":"post_edit","file":"src/prev.py","result":"fail"}\n' "$(days_ago 6)"
} > "$WORK/project3/.feedback/events.jsonl"
OUT3="$(CLAUDE_PROJECT_DIR="$WORK/project3" tpy "$CLI" report --since "$SINCE_REL")"
assert_contains "$OUT3" "PostToolUse 初回通過率: 当期間 1/1" "当期間の初回通過率が出る"
assert_contains "$OUT3" "(前期間 0/1)" "同じ長さだけ遡った前期間と比較される"

# 前期間にイベントが無ければ比較は付かない(0/0 と書いて誤解させない)
printf '{"ts":"%sT01:00:00Z","hook":"post_edit","file":"src/cur.py","result":"pass"}\n' "$(days_ago 2)" \
  > "$WORK/project3/.feedback/events.jsonl"
OUT4="$(CLAUDE_PROJECT_DIR="$WORK/project3" tpy "$CLI" report --since "$SINCE_REL")"
assert_contains "$OUT4" "当期間 1/1" "当期間だけでも数字は出る"
assert_not_contains "$OUT4" "前期間" "前期間にデータが無ければ比較を出さない"

assert_summary
