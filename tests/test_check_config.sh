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

# --- 検証器が使えないときは PASS ではなく SKIP ---
# harness_validate_json / harness_check_md_links は Python 不在で「検証せず成功」を
# 返すため、run_stage からは合格と区別がつかない。事前ゲートが無いと、1件も
# 検証していないのに `PASS config: json 構文` と報告する — 未検証を検証済みに
# 見せる、このハーネスが最も避けてきた形の報告になる(yaml-syntax だけが
# PyYAML で事前ゲートしていて正しかった)。
P7="$(new_project no_python)"
printf '{ invalid\n' > "$P7/broken.json"
printf '# doc\n\n[dead](./nope.md)\n' > "$P7/doc.md"
OUT="$(HARNESS_PYTHON=/nonexistent/python bash "$CHECK" "$P7" 2>&1)"
assert_contains "$OUT" "SKIP  config: json 構文" "Python 不在なら json 構文は SKIP: $OUT"
assert_contains "$OUT" "SKIP  docs: 内部リンク" "Python 不在なら 内部リンク は SKIP: $OUT"
assert_not_contains "$OUT" "PASS  config: json 構文" "検証していないのに PASS と報告しない"
assert_not_contains "$OUT" "PASS  docs: 内部リンク" "検証していないのに PASS と報告しない"

# JSONC しか無いプロジェクトでも「検証済み」に見せない。
# harness_validate_json は内部で JSONC を除外するため、対象が1件も残らないと
# 何も検証しないまま成功が返り、ステージが PASS になる(同じ偽 PASS の別経路)
P8="$(new_project jsonc_only)"
printf '{\n  // コメント\n  "a": 1\n}\n' > "$P8/tsconfig.json"
OUT="$(bash "$CHECK" "$P8" 2>&1)"
assert_not_contains "$OUT" "PASS  config: json 構文" \
  "JSONC だけのプロジェクトで json 構文を PASS と報告しない: $OUT"

# 対になるケース: 検証対象が1件でもあれば従来どおり検証する
printf '{"a": 1,\n' > "$P8/broken.json"
OUT="$(bash "$CHECK" "$P8" 2>&1)"; RC=$?
assert_eq "1" "$RC" "JSONC と壊れた JSON が混在すれば exit 1"
assert_contains "$OUT" "FAIL  config: json 構文" "JSONC を除いた残りは検証される: $OUT"

# 対になるケース。SKIP へ倒しすぎる退行(常に SKIP)も同時に禁じる
OUT="$(bash "$CHECK" "$P7" 2>&1)"; RC=$?
assert_eq "1" "$RC" "Python があれば壊れたJSON・リンク切れで exit 1"
assert_contains "$OUT" "FAIL  config: json 構文" "Python があれば json 構文は実際に検証する: $OUT"
assert_contains "$OUT" "FAIL  docs: 内部リンク" "Python があれば 内部リンク は実際に検証する: $OUT"

assert_summary
