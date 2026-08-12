#!/usr/bin/env bash
# lib.sh — check.sh / check_file.sh が共有するユーティリティ。
#
# 両スクリプトで同じ判定を独立に持つと、片方だけ直して他方が古いまま残る
# (実際に has() でそれが起きた)。共有が必要なものはここに置く。
#
# 使い方: . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# has: コマンドが存在し、かつ実際に起動できるか。
# command -v はファイルの存在と実行ビットしか見ないため、shebang切れのvenv等を
# 「インストール済み」と誤判定し、環境障害がユーザーのコードの失敗として報告される。
# --version を試行し、126(実行不可) / 127(未検出) のときだけ未インストール扱いにする。
# --version を持たないコマンドは別のexit code(1/2等)を返すので影響を受けない。
has() {
  command -v "$1" >/dev/null 2>&1 || return 1
  local rc
  "$1" --version >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 126 || $rc -eq 127 ]] && return 1
  return 0
}

# 重大度しきい値(shellcheck の -S に渡す)。既定は warning。
# style/info まで拾うと、導入初日のプロジェクトが既存コードのSC2086等で
# 完了をブロックされ続けるため、既定では拾わない。
# shellcheck disable=SC2034  # 読み込み側(check.sh / check_file.sh)で使う
SHELLCHECK_SEVERITY="${FEEDBACK_SHELLCHECK_SEVERITY:-warning}"

# harness_project_root [明示パス] — 検査対象・状態保存先のプロジェクトルートを解決する。
#
# 解決順: 明示引数 → CLAUDE_PROJECT_DIR → git rev-parse --show-toplevel → cwd
#
# スクリプト自身の位置($BASH_SOURCE 起点)は使わない。プラグインとして配布されると
# スクリプトはプラグインキャッシュに置かれ、そこは導入先ではないうえ更新のたびに
# 消える領域だからである(状態を書くと失われる)。
harness_project_root() {
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then
    (cd "$explicit" 2>/dev/null && pwd) || return 1
    return 0
  fi
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "${CLAUDE_PROJECT_DIR}" ]]; then
    (cd "$CLAUDE_PROJECT_DIR" && pwd)
    return 0
  fi
  local top
  if top="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$top" ]]; then
    printf '%s\n' "$top"
    return 0
  fi
  pwd
}
