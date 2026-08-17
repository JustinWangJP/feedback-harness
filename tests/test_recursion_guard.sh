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
# このテストの判定対象は check.sh の合否ではなく「時間内に終了するか」。
# 合否は対象プロジェクトの状態次第で変わるため判定に使わない。ガードが
# 壊れていると終わらないため、set -m で独自プロセスグループを切り、時限で
# 再帰ツリーごと強制終了する(放置するとCPUを焼き続ける)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LOG="$WORK/check.log"
# 判定したいのは「有限時間で終わるか」であって速度ではない。ガードが壊れていれば
# 再帰は Stop フックの timeout 300 まで伸びるため、そこに十分届かない値であれば
# 回帰は捕まえられる。予算を実測値ぎりぎりに置くと負荷で落ちる不安定なテストになる
# (P1〜P3 でテストが7本増え、make check 込みの実測が約30秒まで伸びて 30 が同値になった)。
LIMIT=150

# フックと同じ環境(CLAUDE_PROJECT_DIR export 済み)で check.sh を走らせる。
# 再帰は1段階あたり数秒かかるため、ガードが効いていれば数秒で終わる。
set -m
CLAUDE_PROJECT_DIR="$REPO" bash "$REPO/scripts/check.sh" >"$LOG" 2>&1 &
PID=$!
set +m

ELAPSED=0
while kill -0 "$PID" 2>/dev/null && [[ $ELAPSED -lt $LIMIT ]]; do
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

if kill -0 "$PID" 2>/dev/null; then
  # 終わらない = 再帰している。ツリー全体をプロセスグループごと止める
  PGID="$(ps -o pgid= -p "$PID" | tr -d ' ')"
  [[ -n "$PGID" ]] && kill -TERM -- -"$PGID" 2>/dev/null
  wait "$PID" 2>/dev/null
  fail "check.sh が${LIMIT}秒以内に終了しない(再帰ガードが効いていない)"
else
  wait "$PID"
  RC=$?
  # 0=ALL PASS / 1=ステージ失敗 / 2=ルート解決失敗。いずれも「終了した」ことの証拠
  if [[ $RC -ne 0 && $RC -ne 1 && $RC -ne 2 ]]; then
    fail "check.sh が異常終了した (exit=$RC)"
  fi
fi

assert_summary
