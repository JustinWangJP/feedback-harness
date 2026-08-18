#!/usr/bin/env bash
# test_config.sh — harness_config.py のパーサ・スキーマ検証・解決規則を検証する。
#
# YAML は PyYAML を使わず自前のサブセット実装で読む(PyYAML は任意依存で、
# 開発機にも入っていない)。サポート範囲の境界と、範囲外を「黙って無視せず
# 行番号付きで落とす」ことがこのテストの中心。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CFG="$REPO/scripts/harness_config.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

# parse <YAML本文> — パーサだけを叩き、結果を JSON で返す(非0なら stderr が出る)
parse() { printf '%s' "$1" > "$WORK/t.yaml"; python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import harness_config as hc
print(json.dumps(hc.parse_yaml(open(sys.argv[2]).read(), sys.argv[2]), sort_keys=True))
' "$REPO/scripts" "$WORK/t.yaml" 2>&1; }

# --- スカラー ---
assert_eq '{"a": 1}' "$(parse 'a: 1')" "整数"
assert_eq '{"a": "x"}' "$(parse 'a: x')" "裸文字列"
assert_eq '{"a": "x y"}' "$(parse 'a: "x y"')" "ダブルクォート"
assert_eq '{"a": true}' "$(parse 'a: true')" "真偽値"
assert_eq '{"a": null}' "$(parse 'a:')" "空は null"

# --- コメント ---
assert_eq '{"a": 1}' "$(parse '# 先頭コメント
a: 1  # 行末コメント')" "コメントは無視される"
assert_eq '{"a": "x#y"}' "$(parse 'a: "x#y"')" "クォート内の # はコメントではない"

# --- リスト ---
assert_eq '{"a": []}' "$(parse 'a: []')" "空のフローリスト"
assert_eq '{"a": ["x", "y"]}' "$(parse 'a: [x, y]')" "フローリスト"
assert_eq '{"a": ["x", "y"]}' "$(parse 'a:
  - x
  - y')" "ブロックリスト"

# --- 入れ子マップ ---
assert_eq '{"a": {"b": {"c": 1}}}' "$(parse 'a:
  b:
    c: 1')" "入れ子マップ"

# --- 未対応記法は行番号付きで落ちる ---
OUT="$(parse 'a: 1
b: &anchor x')"; RC=$?
assert_eq "1" "$RC" "アンカーは非0で落ちる"
assert_contains "$OUT" ":2:" "行番号が出る"
assert_contains "$OUT" "アンカー" "理由が出る"

OUT="$(parse 'a: |
  multi')"
assert_contains "$OUT" "複数行文字列" "複数行文字列を拒否する"

OUT="$(printf 'a:\n\tb: 1' > "$WORK/t.yaml"; python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import harness_config as hc
hc.parse_yaml(open(sys.argv[2]).read(), sys.argv[2])' "$REPO/scripts" "$WORK/t.yaml" 2>&1)"
assert_contains "$OUT" "タブ" "タブインデントを拒否する"

# --- スキーマ検証 ---
# 検証は parse の後段。打ち間違いを黙って無視しない契約を固定する
val() { printf '%s' "$1" > "$WORK/v.yaml"; python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import harness_config as hc
p = sys.argv[2]
print(json.dumps(hc.validate(hc.parse_yaml(open(p).read(), p), p), sort_keys=True))
' "$REPO/scripts" "$WORK/v.yaml" 2>&1; }

OUT="$(val 'check:
  shelcheck_severity: warning')"
assert_contains "$OUT" "未知のキー" "打ち間違いのキーを拒否する"
assert_contains "$OUT" "shelcheck_severity" "問題のキー名を出す"

OUT="$(val 'check:
  skip: [lnit]')"
assert_contains "$OUT" "lnit" "未知のステージ名を拒否する"

OUT="$(val 'checks:
  vultrue:
    severity: skip')"
assert_contains "$OUT" "vultrue" "未知の検査IDを拒否する"

OUT="$(val 'checks:
  vulture:
    severity: hard')"
assert_contains "$OUT" "hard" "未知の severity を拒否する"

OUT="$(val 'audit:
  interval_days: seven')"
assert_contains "$OUT" "整数" "型不一致を拒否する"

OUT="$(val 'version: 2')"
assert_contains "$OUT" "version" "対応外のスキーマ版を拒否する"

OUT="$(val 'version: true')"
assert_contains "$OUT" "version" "version にブール値を渡すと拒否する(boolはintのサブクラス)"

OUT="$(val 'check:
  golang:
    skip: [test]')"
assert_contains "$OUT" "golang" "未知のスタック名を拒否する"

# 正しい設定は通る
assert_eq "0" "$(val 'check:
  skip: [test]
checks:
  vulture:
    severity: skip' >/dev/null 2>&1; echo $?)" "妥当な設定は検証を通る"

# 検査IDの一覧が取れる(check.sh との突き合わせに使う)
assert_contains "$(python3 "$CFG" --keys)" "vulture" "--keys が検査IDを出す"
assert_contains "$(python3 "$CFG" --keys)" "ruff-format" "--keys がハイフン付きIDを出す"

# --- 解決規則(3層 + 環境変数)---
# 実効値は --json で確認する。出所(どの層で決まったか)も一緒に返る
mkdir -p "$WORK/proj/.feedback"
resolve_json() { # resolve_json [環境変数の代入...]
  env "$@" python3 "$CFG" --json "$WORK/proj"
}
get() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d, sort_keys=True, ensure_ascii=False))'; }

# config 不在 → 全て既定値
OUT="$(resolve_json | get)"
assert_contains "$OUT" '"check.log_tail_lines": [40, "既定"]' "config 不在で既定値になる"

cat > "$WORK/proj/.feedback/config.yaml" <<'EOF'
check:
  skip: [contract]
  log_tail_lines: 10
  python:
    warn_on: [test]
checks:
  vulture:
    severity: skip
    min_confidence: 60
EOF

OUT="$(resolve_json)"
assert_contains "$OUT" '"pytest": ["warn", "check.python.warn_on"]' "スタック層がステージを展開する"
assert_contains "$OUT" '"vulture": ["skip", "checks.vulture"]' "検査層が効く"
assert_contains "$OUT" '"oasdiff": ["skip", "check.skip"]' "全体層が contract ステージを展開する"
assert_contains "$OUT" '"check.log_tail_lines": [10, "check.log_tail_lines"]' "全体層の値が効く"
assert_contains "$OUT" '"checks.vulture.min_confidence": [60, "checks.vulture.min_confidence"]' "検査固有パラメータが効く"

# スタック層は他スタックに漏れない
assert_not_contains "$OUT" '"go-test":' "Python の warn_on が Go に漏れない"

# 検査層 > スタック層 > 全体層
cat > "$WORK/proj/.feedback/config.yaml" <<'EOF'
check:
  skip: [test]
  python:
    warn_on: [test]
checks:
  pytest:
    severity: fail
EOF
OUT="$(resolve_json)"
assert_contains "$OUT" '"pytest": ["fail", "checks.pytest"]' "検査層がスタック層に勝つ"
assert_contains "$OUT" '"go-test": ["skip", "check.skip"]' "指定の無いスタックは全体層に従う"

# 環境変数が config に勝つ
OUT="$(resolve_json FEEDBACK_CHECK_SKIP=lint)"
assert_contains "$OUT" '"ruff": ["skip", "env.FEEDBACK_CHECK_SKIP"]' "環境変数が最優先"
assert_contains "$OUT" '"pytest": ["fail", "checks.pytest"]' "環境変数が触らない検査は config のまま"

OUT="$(resolve_json FEEDBACK_SHELLCHECK_SEVERITY=style)"
assert_contains "$OUT" '"checks.shellcheck.min_severity": ["style", "env.FEEDBACK_SHELLCHECK_SEVERITY"]' "環境変数がパラメータにも効く"

# 壊れた config はエラーを返し、値は既定値のまま
printf 'check:\n  skip: [lnit]\n' > "$WORK/proj/.feedback/config.yaml"
OUT="$(resolve_json)"
assert_contains "$OUT" '"error"' "壊れた config はエラーを返す"
assert_contains "$OUT" "lnit" "エラーに原因が入る"
assert_contains "$OUT" '"check.log_tail_lines": [40, "既定"]' "壊れていても既定値で続行できる"
rm -f "$WORK/proj/.feedback/config.yaml"

# --- シェルへの受け渡し ---
# eval に渡る以上、引用の回帰は致命的。値にシェルメタ文字を入れて確認する
cat > "$WORK/proj/.feedback/config.yaml" <<'EOF'
check:
  exclude:
    - "vendor dir/**"
    - "$(touch /tmp/harness_pwned); echo x"
EOF
eval "$(python3 "$CFG" --shell "$WORK/proj")"
assert_file_absent "/tmp/harness_pwned" "config の値がシェルコードとして実行されない"
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
[[ "$(printf '%s' "$HARNESS_EXCLUDE" | wc -l | tr -d ' ')" == "1" ]] \
  || fail "exclude は改行区切りで2件になる(実際: [$HARNESS_EXCLUDE])"
assert_contains "$HARNESS_EXCLUDE" "vendor dir/**" "空白を含む glob が割れない"

# --- 判定の参照 ---
cat > "$WORK/proj/.feedback/config.yaml" <<'EOF'
checks:
  vulture:
    severity: skip
EOF
. "$REPO/scripts/lib.sh"
harness_load_config "$WORK/proj"
assert_eq "skip" "$(harness_check_severity vulture warn)" "config の判定が返る"
assert_eq "checks.vulture" "$(harness_check_source vulture)" "出所が返る"
assert_eq "fail" "$(harness_check_severity ruff fail)" "指定の無い検査は呼び出し側の既定"
assert_eq "既定" "$(harness_check_source ruff)" "指定が無ければ出所は既定"
rm -f "$WORK/proj/.feedback/config.yaml"

# --- feedback_log.py が config に従う ---
FB="$REPO/scripts/feedback_log.py"
mkdir -p "$WORK/proj/.feedback/log"
printf '2026-01-01\n' > "$WORK/proj/.feedback/.last-audit"

OUT="$(CLAUDE_PROJECT_DIR="$WORK/proj" python3 "$FB" stats)"
assert_contains "$OUT" "監査を推奨" "既定(7日)では推奨が出る"

printf 'audit:\n  interval_days: 99999\n' > "$WORK/proj/.feedback/config.yaml"
OUT="$(CLAUDE_PROJECT_DIR="$WORK/proj" python3 "$FB" stats)"
assert_not_contains "$OUT" "監査を推奨" "config で間隔を延ばすと推奨が消える"
rm -f "$WORK/proj/.feedback/config.yaml" "$WORK/proj/.feedback/.last-audit"

# open_threshold も config に従う(配線のタイポが黙って既定値に落ちるのを防ぐ)
for i in 1 2; do
  printf -- '---\nid: 20260101-00000%d\ndate: 2026-01-0%d\nsource: human\ncategory: style\nstatus: open\n---\n\n# t%d\ntest\n' "$i" "$i" "$i" \
    > "$WORK/proj/.feedback/log/e$i.md"
done
printf 'feedback:\n  open_threshold: 2\n' > "$WORK/proj/.feedback/config.yaml"
OUT="$(CLAUDE_PROJECT_DIR="$WORK/proj" python3 "$FB" stats)"
assert_contains "$OUT" "openが2件以上" "open_threshold=2 で open 2件の NOTE が出る"
rm -f "$WORK/proj/.feedback/log/e1.md" "$WORK/proj/.feedback/log/e2.md" "$WORK/proj/.feedback/config.yaml"

assert_summary
