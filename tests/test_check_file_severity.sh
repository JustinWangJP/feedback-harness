#!/usr/bin/env bash
# test_check_file_severity.sh — check_file.sh(PostToolUse 用の単発ファイル検査)が
# check.sh と同じ実効判定(severity: skip/warn/fail)に従うことを検証する。
#
# 以前は severity: skip が一部の検査にしか効かず、severity: warn も最終的に
# exit 1 になっていた。フルチェックでは SKIP/WARN でも、編集のたびに
# PostToolUse がブロックする食い違いがあった(review/feature-enhance-fowler-feedback.md)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CF="$REPO/scripts/check_file.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"

make_fake() { # make_fake <名前> <exit> — --version は常に成功させ、失敗時は出力も出す
  { echo '#!/usr/bin/env bash'
    echo 'case "$*" in *--version*) exit 0 ;; esac'
    echo "[[ $2 -ne 0 ]] && echo 'FAKE: 問題を検出しました'"
    echo "exit $2"
  } > "$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}

new_project() { # new_project <名前>
  local d="$WORK/$1"
  mkdir -p "$d/.feedback"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}

# check_file.sh はファイルパスしか受け取らずルートを引数で渡せないため、
# harness_project_root() の解決(git 由来)に rely する。フック由来の
# CLAUDE_PROJECT_DIR 伝播は run_tests.sh が一括して掃落とすが、単体実行でも
# 冪等に保つ保険としてここでも空にする(隔離プロジェクトの git init で解決)
run_cf() { CLAUDE_PROJECT_DIR="" PATH="$FAKEBIN:$PATH" bash "$CF" "$1" 2>&1; } # run_cf <ファイル>

# --- severity: skip は実行そのものをしない ---
P1="$(new_project skip)"
make_fake ruff 1   # 呼ばれたら必ず F401 相当の失敗を返す偽ツール
printf 'checks:\n  ruff:\n    severity: skip\n' > "$P1/.feedback/config.yaml"
printf 'import os\n' > "$P1/bad.py"
OUT="$(cd "$P1" && run_cf "$P1/bad.py")"; RC=$?
assert_eq "0" "$RC" "checks.ruff.severity=skip で exit 0"
assert_eq "" "$OUT" "skip では出力も出ない"

# --- severity: warn は指摘を表示するが非ブロッキング ---
P2="$(new_project warn)"
make_fake ruff 1
printf 'checks:\n  ruff:\n    severity: warn\n' > "$P2/.feedback/config.yaml"
printf 'import os\n' > "$P2/bad.py"
OUT="$(cd "$P2" && run_cf "$P2/bad.py")"; RC=$?
assert_eq "0" "$RC" "checks.ruff.severity=warn で exit 0(非ブロッキング)"
assert_contains "$OUT" "非ブロッキング" "warn の指摘だとわかる文言が出る"

# --- 指定が無ければ従来どおりブロックする(既定 fail) ---
P3="$(new_project default_fail)"
make_fake ruff 1
printf 'import os\n' > "$P3/bad.py"
OUT="$(cd "$P3" && run_cf "$P3/bad.py")"; RC=$?
assert_eq "1" "$RC" "config 無しでは従来どおり exit 1"
assert_contains "$OUT" "問題があります" "ブロッキングの文言が出る"

# --- node-lint も同じ配線に従う(eslint 相当) ---
P4="$(new_project node_skip)"
mkdir -p "$P4/node_modules/.bin"
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo 'exit 1'
} > "$FAKEBIN/npx"; chmod +x "$FAKEBIN/npx"
printf '{}' > "$P4/eslint.config.js" # -f eslintrc 判定用ではなく eslint.config.js 判定を使う
printf 'checks:\n  node-lint:\n    severity: skip\n' > "$P4/.feedback/config.yaml"
printf 'var x = 1\n' > "$P4/bad.js"
OUT="$(cd "$P4" && run_cf "$P4/bad.js")"; RC=$?
assert_eq "0" "$RC" "checks.node-lint.severity=skip で exit 0"
rm -f "$FAKEBIN/npx"

# --- 壊れた config.yaml は check_file.sh 自身をブロックする ---
# AGENTS.md §2 で check_file.sh は編集直後の必須ゲート。黙って exit 0 で
# 通すと、設定の打ち間違いに誰も気づけない
P5="$(new_project broken_config)"
printf 'check:\n  lnit: []\n' > "$P5/.feedback/config.yaml"
printf 'hello\n' > "$P5/ok.txt"
OUT="$(cd "$P5" && run_cf "$P5/ok.txt")"; RC=$?
assert_eq "1" "$RC" "壊れた config.yaml で check_file.sh も exit 1"
assert_contains "$OUT" "設定エラー" "設定エラーの文言が出る"
assert_contains "$OUT" "lnit" "原因のキー名が出る"

rm -f "$FAKEBIN/ruff"
assert_summary
