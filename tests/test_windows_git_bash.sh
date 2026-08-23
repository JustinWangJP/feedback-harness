#!/usr/bin/env bash
# test_windows_git_bash.sh — python.exe だけの Git Bash 実行経路を検証する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"

# 壊れた python3 が先に見えても、利用可能な python へfallbackすること。
cat > "$FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
exit 127
SH
cat > "$FAKEBIN/python" <<'SH'
#!/usr/bin/env bash
exec "${TEST_PYTHON:?}" "$@"
SH
chmod +x "$FAKEBIN/python3" "$FAKEBIN/python"

OUT="$(PATH="$FAKEBIN:$PATH" HARNESS_PYTHON='' bash -c '
  unset -f python3 2>/dev/null || true
  . "$1"
  harness_python -c "print(\"python-fallback-ok\")"
' _ "$REPO/scripts/lib.sh" 2>&1)"
assert_eq "0" "$?" "python3 から python へのfallbackが成功する: $OUT"
assert_contains "$OUT" "python-fallback-ok" "fallback先のPythonが実行される"

OUT="$(PATH="$FAKEBIN:$PATH" HARNESS_PYTHON='' bash -c '
  unset -f python3 2>/dev/null || true
  bash "$1" --help
' _ "$REPO/scripts/feedback.sh" 2>&1)"
assert_eq "0" "$?" "feedback.sh が python.exe 相当だけで動く: $OUT"
assert_contains "$OUT" "feedback_log.py" "feedback.sh がCLI helpを表示する"

if [[ -n "${MSYSTEM:-}" ]]; then
  PROJECT="$WORK/windows-path-project"
  mkdir -p "$PROJECT"
  WINDOWS_PROJECT="$(cygpath -w "$PROJECT")"
  OUT="$(CLAUDE_PROJECT_DIR="$WINDOWS_PROJECT" bash -c '. "$1"; harness_project_root' _ "$REPO/scripts/lib.sh")"
  assert_eq "$PROJECT" "$OUT" "Windows native project pathをGit Bash pathへ正規化する"
fi

assert_summary
