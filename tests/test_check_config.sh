#!/usr/bin/env bash
# test_check_config.sh — check.sh が設定ファイルの構文を検査することを検証する。
#
# check_file.sh が JSON/YAML を検証できるのに check.sh 側に無いと、Bash 経由や
# 外部エディタで壊された設定ファイルが完了前チェックをすり抜ける(Shell ステージを
# 追加したときと同じ非対称性)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
. "$REPO/scripts/lib.sh"
CHECK="$REPO/scripts/check.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

new_project() { # new_project <名前> — 空のgitプロジェクトを作って標準出力にパスを返す
  local d="$WORK/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}

# --- 壊れたJSONだけのプロジェクト(他のスタックは無い) ---
P1="$(new_project json_only)"
printf '{"a": 1,\n' > "$P1/config.json"
OUT="$(bash "$CHECK" "$P1" 2>&1)"; RC=$?
assert_eq "1" "$RC" "壊れたJSONで exit 1 になる"
assert_contains "$OUT" "config: json 構文" "json 構文ステージが結果に出る"
assert_contains "$OUT" "config.json" "失敗ログに対象ファイル名が出る"

# --- 正当なJSONなら通る ---
P2="$(new_project json_ok)"
printf '{"a": 1}\n' > "$P2/config.json"
OUT="$(bash "$CHECK" "$P2" 2>&1)"; RC=$?
assert_eq "0" "$RC" "正当なJSONは exit 0"
assert_contains "$OUT" "PASS  config: json 構文" "PASSとして記録される"

# --- JSONC は誤検出しない(D2の回帰・check.sh 経由) ---
P3="$(new_project jsonc)"
printf '{\n  // コメント\n  "a": 1\n}\n' > "$P3/tsconfig.json"
OUT="$(bash "$CHECK" "$P3" 2>&1)"; RC=$?
assert_eq "0" "$RC" "tsconfig.json のコメントで exit 1 にならない"

# --- YAML(PyYAML がある時のみ実質検証。無ければ理由付きSKIP) ---
P4="$(new_project yaml_broken)"
printf 'a: [1, 2\n' > "$P4/conf.yaml"
OUT="$(bash "$CHECK" "$P4" 2>&1)"; RC=$?
if harness_has_pyyaml; then
  assert_eq "1" "$RC" "壊れたYAMLで exit 1 になる"
  assert_contains "$OUT" "config: yaml 構文" "yaml 構文ステージが結果に出る"
else
  assert_eq "0" "$RC" "PyYAML不在では失敗にしない"
  assert_contains "$OUT" "SKIP  config: yaml 構文 (PyYAML 未インストール)" "理由付きSKIPになる"
fi

# --- 複数文書YAMLを誤検出しない(D3の回帰・check.sh 経由) ---
if harness_has_pyyaml; then
  P5="$(new_project yaml_multi)"
  printf -- '---\na: 1\n---\nb: 2\n' > "$P5/multi.yaml"
  OUT="$(bash "$CHECK" "$P5" 2>&1)"; RC=$?
  assert_eq "0" "$RC" "複数文書YAMLで exit 1 にならない"
fi

# --- 設定ファイルが無いプロジェクトでは何も記録しない ---
P6="$(new_project empty)"
printf 'hello\n' > "$P6/README.txt"
OUT="$(bash "$CHECK" "$P6" 2>&1)"
assert_not_contains "$OUT" "config: json 構文" "対象ファイルが無ければステージを出さない"
assert_contains "$OUT" "検出できたスタックがありません" "スタック未検出のメッセージは従来どおり"

assert_summary
