#!/usr/bin/env bash
# feedback.sh — platform差を吸収して feedback_log.py を実行する入口。
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

if ! harness_has_python; then
  echo "ERROR: Python 3.10+ が見つかりません。Git Bash の PATH または HARNESS_PYTHON を確認してください。" >&2
  exit 127
fi

harness_python "$DIR/feedback_log.py" "$@"
