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
assert_contains "$OUT" "頻出WARN: python: ruff format(2, 最終 2026-08-13), config: yaml 構文(1, 最終 2026-08-13)" \
  "頻出WARNが件数降順で最終発生日つきに出る"
assert_contains "$OUT" "失敗上位: src/c.py(2, 最終 2026-08-12), src/a.py(1, 最終 2026-08-10)" \
  "失敗上位が件数降順・ファイル名昇順で最終発生日つきに出る"
# フィクスチャの最終発生は過去日のため、解消済みかもしれない注記が出る
assert_contains "$OUT" "日以上再発していません" "古いWARNには鮮度の注記が出る"

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
assert_contains "$OUT" "20260715-000001(参考 " "昇華日以降の同カテゴリ指摘が列挙される"
assert_not_contains "$OUT" "20260716-000001(参考" "別カテゴリは再発候補に出ない"
assert_contains "$OUT" "本文を読んで判断すること" "判断はエージェントが行う旨が明示される"

# --- 再発候補は文字列一致で足切りしない(判定はエージェントが本文を読んで行う) ---
# 主題が離れて見えるエントリも候補として出す。表面的な文字の重なりで捨てると、
# 言語や書式の差で真の再発を落とし、「ルールが効いていない」ことに気づけなくなる。
# 余分な候補を1件読む手間より、見落としのほうが重い(2026-08-22 にしきい値方式を撤去)
cat > "$WORK/project/.feedback/log/20260717-000001-offtopic.md" <<'EOF'
---
id: 20260717-000001
date: 2026-07-17
source: human
category: style
signal: failure
status: open
---

# 全く別の主題についての指摘

コミットメッセージの一行目は50文字以内に収める。長い説明は本文へ回す。
EOF
OUT_R="$(fb stats --since 2026-08-10)"
assert_contains "$OUT_R" "20260717-000001(参考 " "主題が離れて見えるエントリも候補として出す(足切りしない)"
assert_contains "$OUT_R" "20260715-000001(参考 " "同カテゴリの他の候補も引き続き出る"
# 参考値は読む順のヒント。表面的に近いものが先に並ぶ
POS_NEAR="$(printf '%s' "$OUT_R" | grep -o '20260715-000001\|20260717-000001' | head -1)"
assert_eq "20260715-000001" "$POS_NEAR" "参考値の高い候補が先に並ぶ(読む順のヒント)"
rm "$WORK/project/.feedback/log/20260717-000001-offtopic.md"

# --- 一時ファイルは集計に混ぜない ---
# スクラッチパッド等はプロジェクトの資産ではないため、件数を稼いで
# 「どのファイルでつまずいているか」の順位を歪めてはいけない
# フィクスチャは writer(lib.sh の harness_log_event)が実際に書く形に合わせる。
# プロジェクト内のファイルは root を剥がした相対パスで記録されるため、
# ルート直下の scratchpad/ は先頭にスラッシュが付かない。絶対パスだけで
# テストすると、除外機能の主要ケースに一度も触れないまま緑になる
cat >> "$WORK/project/.feedback/events.jsonl" <<'EOF'
{"ts":"2026-08-14T01:00:00Z","hook":"post_edit","file":"scratchpad/probe.py","result":"fail"}
{"ts":"2026-08-14T01:01:00Z","hook":"post_edit","file":"scratchpad/probe.py","result":"fail"}
{"ts":"2026-08-14T01:02:00Z","hook":"post_edit","file":"_workspace/scratchpad/deep.py","result":"fail"}
{"ts":"2026-08-14T01:03:00Z","hook":"post_edit","file":"/tmp/other.py","result":"fail"}
{"ts":"2026-08-14T01:04:00Z","hook":"post_edit","file":".git/COMMIT_EDITMSG","result":"fail"}
EOF
OUT_T="$(fb stats --since 2026-08-10)"
assert_not_contains "$OUT_T" "scratchpad" "スクラッチパッドのファイルは失敗上位に出ない(相対・深い階層とも)"
assert_not_contains "$OUT_T" "/tmp/other.py" "/tmp 配下のファイルは失敗上位に出ない"
assert_not_contains "$OUT_T" "COMMIT_EDITMSG" "ルート直下の .git/ も失敗上位に出ない"
assert_contains "$OUT_T" "PostToolUse 初回通過率: 1/3 (33%)" "一時ファイルは初回通過率の分母にも入らない"

# --- events が無いプロジェクトでも死なない ---
rm "$WORK/project/.feedback/events.jsonl"
OUT3="$(fb stats)"
assert_contains "$OUT3" "イベント記録が無い" "events.jsonl 不在でもログ集計を続ける"
assert_contains "$OUT3" "再発候補" "再発候補セクションは出る"

# --- 最終監査日(.last-audit)の表示と期限切れ推奨 ---
mkdir -p "$WORK/project/.feedback"
printf '2026-01-01\n' > "$WORK/project/.feedback/.last-audit"
OUT="$(fb stats)"
assert_contains "$OUT" "最終監査: 2026-01-01 (" "最終監査日が表示される"
assert_contains "$OUT" "日前)" "経過日数が表示される"
assert_contains "$OUT" "監査を推奨" "7日超過なら推奨行が出る"

printf '%s\n' "$(python3 -c 'import datetime; print(datetime.date.today().isoformat())')" \
  > "$WORK/project/.feedback/.last-audit"
OUT="$(fb stats)"
assert_contains "$OUT" "最終監査:" "当日でも表示される"
assert_not_contains "$OUT" "監査を推奨" "期限内なら推奨は出ない"

rm -f "$WORK/project/.feedback/.last-audit"
OUT="$(fb stats)"
assert_contains "$OUT" "最終監査: 未実行" "スタンプ無しは未実行表示"
assert_contains "$OUT" "scripts/audit.sh" "未実行なら実行方法を案内する"

assert_summary
