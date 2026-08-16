#!/usr/bin/env bash
# test_config_syntax.sh — JSON/YAML 構文検証の共有関数を検証する。
#
# 誤検出は「正当なファイルで完了がブロックされる」形の最悪の壊れ方になるため、
# 検出できること以上に「誤検出しないこと」を固定する:
# - コメント付きJSON(tsconfig.json 等は JSONC が慣例)
# - 複数文書YAML(--- 区切り)
# - カスタムタグYAML(CloudFormation の !Ref 等)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
. "$REPO/scripts/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/.vscode"

ok() { # ok <関数> <ファイル> <ラベル> — 検証が成功(exit 0)することを期待
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  local out
  if ! out="$("$1" "$2" 2>&1)"; then
    fail "$3: 誤検出した (出力: $out)"
  fi
}
ng() { # ng <関数> <ファイル> <ラベル> — 検証が失敗(非0)することを期待
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  if "$1" "$2" >/dev/null 2>&1; then
    fail "$3: 壊れているのに検出されなかった"
  fi
}

# --- JSON ---
printf '{"a": 1}\n' > "$WORK/good.json"
printf '{"a": 1,\n' > "$WORK/broken.json"
ok harness_validate_json "$WORK/good.json" "正当なJSONを通す"
ng harness_validate_json "$WORK/broken.json" "壊れたJSONを検出する"

# JSONC 慣例のファイルは検証対象外(標準パーサでは原理的に検証できない)
printf '{\n  // コメント\n  "a": 1\n}\n' > "$WORK/tsconfig.json"
printf '{\n  // コメント\n  "a": 1\n}\n' > "$WORK/.vscode/settings.json"
printf '{\n  // コメント\n  "a": 1\n}\n' > "$WORK/devcontainer.json"
ok harness_validate_json "$WORK/tsconfig.json" "tsconfig.json のコメントで誤検出しない"
ok harness_validate_json "$WORK/.vscode/settings.json" ".vscode配下のコメントで誤検出しない"
ok harness_validate_json "$WORK/devcontainer.json" "devcontainer.json のコメントで誤検出しない"

ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
harness_is_jsonc "$WORK/tsconfig.json" || fail "harness_is_jsonc が tsconfig.json を判定できない"
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
if harness_is_jsonc "$WORK/good.json"; then fail "harness_is_jsonc が通常のJSONを誤判定した"; fi

# check.sh の list_files は git ls-files 由来のリポジトリ相対パス(先頭に ./ も / も付かない)を
# 返す。この形を取りこぼすと、最も一般的なJSONCであるトップレベルの .vscode/settings.json が
# 厳密なJSONとして検証され、完了をブロックする
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
harness_is_jsonc ".vscode/settings.json" || fail "harness_is_jsonc がリポジトリ相対の .vscode パスを判定できない(check.sh の list_files が返す形)"
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
harness_is_jsonc "./.vscode/settings.json" || fail "harness_is_jsonc が ./ 始まりの .vscode パスを判定できない"

# 複数ファイル一括: 1件でも壊れていれば非0
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
if harness_validate_json "$WORK/good.json" "$WORK/broken.json" >/dev/null 2>&1; then
  fail "複数ファイル指定で壊れたJSONを見逃した"
fi

# 出力契約: 壊れたファイルのパスと理由を stdout に出す(Task 2/3 がこれをそのまま提示する)
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
json_diag="$(harness_validate_json "$WORK/broken.json" 2>/dev/null)" || true
assert_contains "$json_diag" "broken.json" "壊れたJSONの診断に対象パスが含まれる"

# --- YAML(PyYAML がある環境でのみ実質検証される) ---
if harness_has_pyyaml; then
  printf 'a: 1\n' > "$WORK/good.yaml"
  printf 'a: [1, 2\n' > "$WORK/broken.yaml"
  printf -- '---\na: 1\n---\nb: 2\n' > "$WORK/multi.yaml"
  printf 'Resources:\n  X:\n    Value: !Ref Other\n' > "$WORK/customtag.yaml"
  ok harness_validate_yaml "$WORK/good.yaml" "正当なYAMLを通す"
  ng harness_validate_yaml "$WORK/broken.yaml" "壊れたYAMLを検出する"
  ok harness_validate_yaml "$WORK/multi.yaml" "複数文書YAMLで誤検出しない"
  ok harness_validate_yaml "$WORK/customtag.yaml" "カスタムタグYAMLで誤検出しない"
else
  # PyYAML が無い環境では検証せず成功する(環境の問題をコードの失敗として報告しない)
  printf 'a: [1, 2\n' > "$WORK/broken.yaml"
  ok harness_validate_yaml "$WORK/broken.yaml" "PyYAML不在なら検証せず成功する"
fi

assert_summary
