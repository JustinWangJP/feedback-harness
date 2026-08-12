#!/usr/bin/env bash
# check_file.sh — 編集された単一ファイルの高速チェック(Hooks / 変更直後用)。
# フルビルドはせず、数秒で終わる静的チェックのみ行う。
#
# 使い方: scripts/check_file.sh <ファイルパス>
# 出力: 問題があれば内容を表示して exit 1、なければ exit 0(無出力)。
set -u

LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$LIBDIR/lib.sh"

FILE="${1:-}"
[[ -z "$FILE" || ! -f "$FILE" ]] && exit 0

# has() / SHELLCHECK_SEVERITY は lib.sh で定義(check.sh と共有)

OUT=""
case "$FILE" in
  *.py)
    if has ruff; then
      # exit code で判定する(ruffは成功時も "All checks passed!" を出力するため)
      OUT="$(ruff check --output-format=concise "$FILE" 2>&1)" && OUT=""
    elif has python3; then
      OUT="$(python3 -m py_compile "$FILE" 2>&1)" && OUT=""
    fi
    ;;
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs)
    if has npx && [[ -f .eslintrc.json || -f .eslintrc.js || -f eslint.config.js || -f eslint.config.mjs ]]; then
      OUT="$(npx --no-install eslint --format unix "$FILE" 2>&1)" && OUT=""
    elif has node && [[ "$FILE" == *.js || "$FILE" == *.mjs || "$FILE" == *.cjs ]]; then
      OUT="$(node --check "$FILE" 2>&1)" && OUT=""
    fi
    ;;
  *.go)
    if has gofmt; then
      UNFMT="$(gofmt -l "$FILE" 2>&1)"
      [[ -n "$UNFMT" ]] && OUT="gofmt: 未フォーマット: $UNFMT (gofmt -w を実行せよ)"
    fi
    ;;
  *.rs)
    has rustfmt && { rustfmt --check "$FILE" >/dev/null 2>&1 || OUT="rustfmt: 未フォーマット: $FILE"; }
    ;;
  *.sh)
    OUT="$(bash -n "$FILE" 2>&1)" || true
    if has shellcheck; then
      # -S: style/info まで拾うと導入初日のプロジェクトが既存コードで詰まる
      # -x: source 先を追う(追えないだけの SC1091 を問題として報告しない)
      SC="$(shellcheck -x -S "$SHELLCHECK_SEVERITY" -f gcc "$FILE" 2>&1)" || true
      # bash -n が無出力のときに先頭空行を出さないよう、区切り改行は連結時だけ入れる
      [[ -n "$SC" ]] && OUT="${OUT:+$OUT$'\n'}$SC"
    fi
    ;;
  *.json)
    has python3 && { OUT="$(python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$FILE" 2>&1)" && OUT=""; }
    ;;
  *.yaml|*.yml)
    # PyYAML は標準ライブラリではない。未導入だと ModuleNotFoundError が
    # 「ファイルの問題」として報告され、正当なYAMLでフックがブロックする
    if has python3 && python3 -c "import yaml" >/dev/null 2>&1; then
      OUT="$(python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$FILE" 2>&1)" && OUT=""
    fi
    ;;
esac

if [[ -n "${OUT// /}" ]]; then
  echo "check_file: $FILE に問題があります:"
  echo "$OUT"
  exit 1
fi
exit 0
