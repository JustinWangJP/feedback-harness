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
assert_file_exists "$WORK/target/scripts/feedback_store.py" "feedback_store.py"
for runner in python node go rust java shell cross_cutting; do
  assert_file_exists "$WORK/target/scripts/checks/$runner.sh" "$runner runner"
done
# audit.sh は導入先に必要。scripts/README.md が使い方を載せ、feedback_log.py の
# stats/report が「bash scripts/audit.sh の実行を推奨」と案内するため、
# 配り漏れると案内先が存在しないコマンドになる
assert_file_exists "$WORK/target/scripts/audit.sh" "audit.sh"
# harness_config.py は全スクリプトが config(.feedback/config.yaml)を読むための
# 唯一のパーサ。欠けると config が効かないまま導入先が動く
assert_file_exists "$WORK/target/scripts/harness_config.py" "harness_config.py"
assert_file_exists "$WORK/target/scripts/README.md" "English scripts README"
assert_file_exists "$WORK/target/scripts/README.ja.md" "Japanese scripts README"
assert_file_exists "$WORK/target/scripts/README.zh-CN.md" "Simplified Chinese scripts README"
assert_file_exists "$WORK/target/AGENTS.md" "AGENTS.md"
assert_file_exists "$WORK/target/CLAUDE.md" "CLAUDE.md"
assert_file_exists "$WORK/target/.feedback/rules.md" "rules.md"
# config の雛形。config.yaml 自体は自動生成しない(置いただけで「設定した」ように
# 見えないため)ため、利用者はこの雛形から始める
assert_file_exists "$WORK/target/.feedback/config.example.yaml" "config.example.yaml"
assert_eq "1" "$(grep -c '<!-- feedback-harness:pointer:start -->' "$WORK/target/CLAUDE.md")" \
  "CLAUDE.md に管理開始マーカーが1つある"
assert_eq "1" "$(grep -c '<!-- feedback-harness:pointer:end -->' "$WORK/target/CLAUDE.md")" \
  "CLAUDE.md に管理終了マーカーが1つある"
assert_eq "1" "$(grep -c '<!-- feedback-harness:pointer:start -->' "$WORK/target/AGENTS.md")" \
  "AGENTS.md に管理開始マーカーが1つある"
assert_eq "1" "$(grep -c '<!-- feedback-harness:pointer:end -->' "$WORK/target/AGENTS.md")" \
  "AGENTS.md に管理終了マーカーが1つある"
assert_contains "$(cat "$WORK/target/CLAUDE.md")" '`init.sh` だけで導入した場合' \
  "CLAUDE.md が init.sh 単独導入を区別する"
assert_contains "$(cat "$WORK/target/CLAUDE.md")" 'bash scripts/check_file.sh <編集したファイル>' \
  "CLAUDE.md に Hooks 無効時の手動チェックがある"
assert_contains "$(cat "$WORK/target/CLAUDE.md")" '根因: <分類>' \
  "CLAUDE.md にスキルなしでも使える根因分類がある"

# プラグインが担う領域はコピーしない
assert_file_absent "$WORK/target/.claude/skills" ".claude/skills をコピーしない"
assert_file_absent "$WORK/target/.claude/agents" ".claude/agents をコピーしない"
assert_file_absent "$WORK/target/.claude/settings.json" ".claude/settings.json をコピーしない"
assert_file_absent "$WORK/target/scripts/hooks" "hooks ラッパーをコピーしない"

# 実行権限
if [[ -x "$WORK/target/scripts/check.sh" ]]; then :; else fail "check.sh に実行権限がない"; fi
if [[ -x "$WORK/target/scripts/feedback_store.py" ]]; then :; else fail "feedback_store.py に実行権限がない"; fi

# ベンダリングした check.sh が対象プロジェクトで exit 0 になる。
# ルートに README.md を置く(一般的な導入先と同じ状態)。「0か1なら可」の緩い
# 判定にしていた頃、配布物の相対リンク切れが md-links FAIL として見逃されて
# いた — docs/ は配布対象外のため、scripts/README.md から docs/ への
# リンクを足すと必ず壊れる(2026-08-18 のレビューで発見)
printf '# Target README\n' > "$WORK/target/README.md"
CHECK_OUT="$(cd "$WORK/target" && bash scripts/check.sh 2>&1)"
RC=$?
if [[ "$RC" != "0" ]]; then
  fail "ベンダリングした check.sh が exit 0 にならない (exit=$RC) — 出力: [$CHECK_OUT]"
fi

# 冪等性と更新: 2回目で管理ブロックを置換し、利用者の記述を保持する
BEFORE_C="$(grep -c 'ハーネス: フィードバックループ' "$WORK/target/CLAUDE.md")"
BEFORE_A="$(grep -c 'フィードバックハーネス' "$WORK/target/AGENTS.md")"
printf '\n## USER CLAUDE CONTENT\nkeep me\n' >> "$WORK/target/CLAUDE.md"
printf '\n## USER AGENTS CONTENT\nkeep me\n' >> "$WORK/target/AGENTS.md"
python3 - "$WORK/target/CLAUDE.md" "$WORK/target/AGENTS.md" <<'PY'
import sys
from pathlib import Path

claude = Path(sys.argv[1])
agents = Path(sys.argv[2])
claude.write_text(
    claude.read_text(encoding="utf-8").replace(
        "第三者マーケットプレイスは自動更新が既定で無効",
        "OLD CLAUDE POINTER",
    ),
    encoding="utf-8",
)
agents.write_text(
    agents.read_text(encoding="utf-8").replace(
        "Codex Plugin の Hooks が有効かつ信頼済みなら",
        "OLD AGENTS POINTER",
    ),
    encoding="utf-8",
)
PY
bash "$REPO/scripts/init.sh" "$WORK/target" >/dev/null 2>&1
assert_eq "$BEFORE_C" "$(grep -c 'ハーネス: フィードバックループ' "$WORK/target/CLAUDE.md")" "CLAUDE.md のポインタが重複しない"
assert_eq "$BEFORE_A" "$(grep -c 'フィードバックハーネス' "$WORK/target/AGENTS.md")" "AGENTS.md のポインタが重複しない"
assert_eq "0" "$(grep -c 'OLD CLAUDE POINTER' "$WORK/target/CLAUDE.md")" "CLAUDE.md の旧管理内容を更新する"
assert_eq "0" "$(grep -c 'OLD AGENTS POINTER' "$WORK/target/AGENTS.md")" "AGENTS.md の旧管理内容を更新する"
assert_contains "$(cat "$WORK/target/CLAUDE.md")" "第三者マーケットプレイスは自動更新が既定で無効" \
  "CLAUDE.md に最新ポインタを反映する"
assert_contains "$(cat "$WORK/target/AGENTS.md")" "Codex Plugin の Hooks が有効かつ信頼済みなら" \
  "AGENTS.md に最新ポインタを反映する"
assert_contains "$(cat "$WORK/target/CLAUDE.md")" "USER CLAUDE CONTENT" "CLAUDE.md の利用者記述を保持する"
assert_contains "$(cat "$WORK/target/AGENTS.md")" "USER AGENTS CONTENT" "AGENTS.md の利用者記述を保持する"

# マーカー導入前の旧ポインタも、既知の末尾までに限定して安全に移行する
mkdir -p "$WORK/legacy"
( cd "$WORK/legacy" && git init -q . )
cat > "$WORK/legacy/CLAUDE.md" <<'EOF'
# Existing Claude Instructions

## ハーネス: フィードバックループ

OLD LEGACY CLAUDE POINTER

**ハーネス本体の更新:** 古い説明

## USER SECTION AFTER CLAUDE POINTER

keep claude tail
EOF
cat > "$WORK/legacy/AGENTS.md" <<'EOF'
# Existing Agent Instructions

## フィードバックハーネス — エージェント作業規約（Codex / 汎用エージェント向け）

OLD LEGACY AGENTS POINTER

今回の明示的な指示を優先し、矛盾があったことをユーザーに一言伝える。

## USER SECTION AFTER AGENTS POINTER

keep agents tail
EOF
bash "$REPO/scripts/init.sh" "$WORK/legacy" >/dev/null 2>&1
assert_eq "0" "$(grep -c 'OLD LEGACY CLAUDE POINTER' "$WORK/legacy/CLAUDE.md")" \
  "CLAUDE.md の旧ポインタを移行する"
assert_eq "0" "$(grep -c 'OLD LEGACY AGENTS POINTER' "$WORK/legacy/AGENTS.md")" \
  "AGENTS.md の旧ポインタを移行する"
assert_contains "$(cat "$WORK/legacy/CLAUDE.md")" "USER SECTION AFTER CLAUDE POINTER" \
  "CLAUDE.md 旧ポインタ後の利用者記述を保持する"
assert_contains "$(cat "$WORK/legacy/AGENTS.md")" "USER SECTION AFTER AGENTS POINTER" \
  "AGENTS.md 旧ポインタ後の利用者記述を保持する"
assert_eq "1" "$(grep -c '<!-- feedback-harness:pointer:start -->' "$WORK/legacy/CLAUDE.md")" \
  "CLAUDE.md の旧ポインタを管理ブロック化する"
assert_eq "1" "$(grep -c '<!-- feedback-harness:pointer:start -->' "$WORK/legacy/AGENTS.md")" \
  "AGENTS.md の旧ポインタを管理ブロック化する"

# 既存 rules.md を上書きしない
printf 'MY OWN RULES\n' > "$WORK/target/.feedback/rules.md"
bash "$REPO/scripts/init.sh" "$WORK/target" >/dev/null 2>&1
assert_eq "MY OWN RULES" "$(cat "$WORK/target/.feedback/rules.md")" "既存 rules.md を保護する"

# 自分自身への導入は拒否する
if bash "$REPO/scripts/init.sh" "$REPO" >/dev/null 2>&1; then
  fail "自分自身への導入が拒否されなかった"
fi

# --- .gitignore はエントリ単位で追記する ---
# 「1行でもあれば全体をスキップ」だと、後から足したエントリが既存導入へ
# 永久に届かない。特に .feedback/local/(個人設定)は共有されると事故になる
GI="$WORK/gitignore_proj"
mkdir -p "$GI"
( cd "$GI" && git init -q . )
# 旧バージョンの init.sh が書いた2行だけがある既存導入を模す
printf 'node_modules/\n\n# Harness working area\n_workspace/\n.feedback/.last-check\n' \
  > "$GI/.gitignore"
bash "$REPO/scripts/init.sh" "$GI" >/dev/null 2>&1
GI_BODY="$(cat "$GI/.gitignore")"
assert_contains "$GI_BODY" ".feedback/local/" "既存導入にも個人設定の除外が届く"
assert_contains "$GI_BODY" ".feedback/events.jsonl" "既存導入にも後から足したエントリが届く"

# 2回目の実行で行が重複しない(init.sh は繰り返し実行される)
bash "$REPO/scripts/init.sh" "$GI" >/dev/null 2>&1
assert_eq "1" "$(grep -cxF '.feedback/local/' "$GI/.gitignore")" \
  "再実行しても .gitignore の行が重複しない"
assert_eq "1" "$(grep -cxF '_workspace/' "$GI/.gitignore")" \
  "既存エントリを二重に書かない"

assert_summary
