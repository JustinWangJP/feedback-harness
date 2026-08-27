#!/usr/bin/env bash
# test_recursion_guard.sh — check.sh → make check → テスト → check.sh の循環が
# 再帰ガードで断たれていることを検証する。
#
# フック実行時のみ発火する回帰: Claude Code は hook に CLAUDE_PROJECT_DIR を
# export し、それは make・テスト・ベンダリング版 check.sh まで伝播する。
# harness_project_root は CLAUDE_PROJECT_DIR を最優先で解決するため、
# test_init_sh.sh 内の check.sh が検査ルートを本リポジトリに解決し直して
# make check がテストをもう一度走らせる。以降が無限再帰となり、Stop フックが
# timeout 300 を食い潰していた(2026-08-16 発生)。
#
# 実時間を合否判定にすると、遅いrunnerを再帰と誤判定する。代わりに一時
# Makefileからcheck.shを呼び返し、Makeの実行回数を独立したmarkerで数える。
# ガードが壊れていてもfixture側で3回までに制限し、再帰プロセスを残さない。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROJECT="$WORK/project"
MARKER="$WORK/make-invocations"
mkdir -p "$PROJECT"
: > "$MARKER"

cat > "$PROJECT/Makefile" <<'MAKE'
check:
	@count="$$(wc -l < "$${MARKER}")"; \
		printf 'make\n' >> "$${MARKER}"; \
		if [ "$$count" -lt 2 ]; then \
			export CLAUDE_PROJECT_DIR="$${PROJECT}"; \
			bash "$${CHECK}"; \
		fi
MAKE

# フックと同じくCLAUDE_PROJECT_DIRが伝播した状態で起動する。外側のcheck.shが
# makeへだけFEEDBACK_CHECK_RECURSION_GUARDを渡すため、Makefileから呼び返された
# 内側のcheck.shはmake fallbackをSKIPし、markerは1行だけになる。
OUT="$(
  export CHECK="$REPO/scripts/check.sh"
  export PROJECT MARKER
  export CLAUDE_PROJECT_DIR="$PROJECT"
  unset FEEDBACK_CHECK_RECURSION_GUARD
  bash "$REPO/scripts/check.sh" "$PROJECT" 2>&1
)"
RC=$?
assert_eq "0" "$RC" "fixtureに対するcheck.shが成功する: $OUT"
COUNT="$(wc -l < "$MARKER" | tr -d ' ')"
assert_eq "1" "$COUNT" "make fallbackを1回で打ち切る"
assert_contains "$OUT" "PASS  make check" "外側のmake checkが成功する"

assert_summary
