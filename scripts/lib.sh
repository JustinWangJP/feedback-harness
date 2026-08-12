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
