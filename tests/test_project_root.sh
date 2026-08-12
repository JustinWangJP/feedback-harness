#!/usr/bin/env bash
# test_project_root.sh — harness_project_root() の解決順を検証する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
. "$HERE/../scripts/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# macOS の mktemp は /var/folders/... を返すが実体は /private/var/... なので
# pwd の結果と比較するために実パスへ正規化しておく
WORK="$(cd "$WORK" && pwd -P)"

# 1: 明示引数が最優先
mkdir -p "$WORK/explicit"
assert_eq "$WORK/explicit" "$(harness_project_root "$WORK/explicit")" "明示引数が最優先"

# 2: 存在しない明示引数はエラー
if harness_project_root "$WORK/no-such-dir" >/dev/null 2>&1; then
  fail "存在しない明示引数で成功してしまった"
fi

# 3: 明示引数が無ければ CLAUDE_PROJECT_DIR
mkdir -p "$WORK/from-env"
assert_eq "$WORK/from-env" \
  "$(CLAUDE_PROJECT_DIR="$WORK/from-env" harness_project_root)" \
  "CLAUDE_PROJECT_DIR を使う"

# 4: CLAUDE_PROJECT_DIR が実在しないディレクトリなら無視して次段へ
mkdir -p "$WORK/repo/sub"
( cd "$WORK/repo" && git init -q . )
assert_eq "$WORK/repo" \
  "$(cd "$WORK/repo/sub" && CLAUDE_PROJECT_DIR="$WORK/no-such-dir" harness_project_root)" \
  "壊れた CLAUDE_PROJECT_DIR は git にフォールバック"

# 5: 環境変数が無ければ git のトップレベル(サブディレクトリからでもリポジトリルート)
assert_eq "$WORK/repo" \
  "$(cd "$WORK/repo/sub" && unset CLAUDE_PROJECT_DIR; harness_project_root)" \
  "git rev-parse --show-toplevel を使う"

# 6: git 管理外なら cwd
mkdir -p "$WORK/plain"
assert_eq "$WORK/plain" \
  "$(cd "$WORK/plain" && unset CLAUDE_PROJECT_DIR; GIT_CEILING_DIRECTORIES="$WORK" harness_project_root)" \
  "git 管理外は cwd"

assert_summary
