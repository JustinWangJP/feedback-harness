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
parse() { printf '%s' "$1" > "$WORK/t.yaml"; tpy -c '
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

OUT="$(printf 'a:\n\tb: 1' > "$WORK/t.yaml"; tpy -c '
import sys; sys.path.insert(0, sys.argv[1]); import harness_config as hc
hc.parse_yaml(open(sys.argv[2]).read(), sys.argv[2])' "$REPO/scripts" "$WORK/t.yaml" 2>&1)"
assert_contains "$OUT" "タブ" "タブインデントを拒否する"

# リスト要素のマップ形式は黙って文字列化せず拒否する(exclude に
# 「何にも一致しない glob」が静かに増えるのを防ぐ — 設計書 §5.2)
OUT="$(parse 'exclude:
  - path: vendor/**')"
assert_contains "$OUT" "マップ" "リスト要素のマップ形式を拒否する"
assert_contains "$OUT" ":2:" "マップ形式の拒否にも行番号が出る"

OUT="$(parse 'a: [path: x, y]')"
assert_contains "$OUT" "マップ" "フローリストでもマップ形式を拒否する"

# クォートされたコロン入り文字列はマップではないため素通しする
assert_eq '{"a": ["x: y"]}' "$(parse 'a: ["x: y"]')" "クォート済みのコロン入り文字列は通る"

# 閉じていないクォート・フローリストは裸文字列として通さず行番号付きで落ちる
# ("main のようなクォート開始のみの値が git merge-base 等を静かに壊す実例あり)
OUT="$(parse 'a: "main')"
assert_contains "$OUT" "クォート" "閉じていないクォートを拒否する"
OUT="$(parse 'a: [x, y')"
assert_contains "$OUT" "フローリスト" "閉じていないフローリストを拒否する"
assert_eq '{"a": "main"}' "$(parse 'a: "main"')" "正しく閉じたクォートは通る"

# --- スキーマ検証 ---
# 検証は parse の後段。打ち間違いを黙って無視しない契約を固定する
val() { printf '%s' "$1" > "$WORK/v.yaml"; tpy -c '
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

# 検査固有パラメータの範囲制約(雛形が 0-100 と明記する vulture.min_confidence)
OUT="$(val 'checks:
  vulture:
    min_confidence: 101')"
assert_contains "$OUT" "0〜100" "範囲外の整数を拒否する"
assert_eq "0" "$(val 'checks:
  vulture:
    min_confidence: 100' >/dev/null 2>&1; echo $?)" "範囲の上限は許可する"

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
assert_contains "$(tpy "$CFG" --keys)" "vulture" "--keys が検査IDを出す"
assert_contains "$(tpy "$CFG" --keys)" "ruff-format" "--keys がハイフン付きIDを出す"

# --- 解決規則(3層 + 環境変数)---
# 実効値は --json で確認する。出所(どの層で決まったか)も一緒に返る
mkdir -p "$WORK/proj/.feedback"
resolve_json() { # resolve_json [環境変数の代入...]
  local assignment
  (
    for assignment in "$@"; do
      export "${assignment?}"
    done
    tpy "$CFG" --json "$WORK/proj"
  )
}
get() { tpy -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d, sort_keys=True, ensure_ascii=False))'; }

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
SHELL_OUT="$(tpy "$CFG" --shell "$WORK/proj")"
assert_not_contains "$SHELL_OUT" "HARNESS_CHECK_SEVERITY=" \
  "検査設定を区切り文字入りの単一変数へ詰めない"
eval "$SHELL_OUT"
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

# source は構造化された別フィールドなので、旧形式の区切り文字・空白・タブ・
# Unicode を含んでも欠落しない。Python生成→shell eval→lookupを端から端まで試す
SPECIAL_SHELL_OUT="$(tpy - "$REPO/scripts" "$WORK/proj" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
import harness_config as hc

real_effective = hc.effective
def special_effective(root, env):
    result = real_effective(root, env)
    result["severity"]["vulture"] = ("skip", "local: path\t日本語")
    return result

hc.effective = special_effective
hc._cmd_shell(sys.argv[2], {})
PY
)"
eval "$SPECIAL_SHELL_OUT"
assert_eq $'local: path\t日本語' "$(harness_check_source vulture)" \
  "出所の内容を区切り文字で再解釈しない"

# 永続ロックの待機時間は設定可能だが、0 や過大値で安全機構を無効化できない
OUT="$(val 'feedback:
  lock_timeout_seconds: 0')"
assert_contains "$OUT" "1〜300" "lock_timeout_seconds の下限を検証する"
OUT="$(val 'feedback:
  lock_timeout_seconds: 301')"
assert_contains "$OUT" "1〜300" "lock_timeout_seconds の上限を検証する"
rm -f "$WORK/proj/.feedback/config.yaml"

# --- feedback_log.py が config に従う ---
FB="$REPO/scripts/feedback_log.py"
mkdir -p "$WORK/proj/.feedback/log"
printf '2026-01-01\n' > "$WORK/proj/.feedback/.last-audit"

OUT="$(CLAUDE_PROJECT_DIR="$WORK/proj" tpy "$FB" stats)"
assert_contains "$OUT" "監査を推奨" "既定(7日)では推奨が出る"

printf 'audit:\n  interval_days: 99999\n' > "$WORK/proj/.feedback/config.yaml"
OUT="$(CLAUDE_PROJECT_DIR="$WORK/proj" tpy "$FB" stats)"
assert_not_contains "$OUT" "監査を推奨" "config で間隔を延ばすと推奨が消える"
rm -f "$WORK/proj/.feedback/config.yaml" "$WORK/proj/.feedback/.last-audit"

# open_threshold も config に従う(配線のタイポが黙って既定値に落ちるのを防ぐ)
for i in 1 2; do
  printf -- '---\nid: 20260101-00000%d\ndate: 2026-01-0%d\nsource: human\ncategory: style\nstatus: open\n---\n\n# t%d\ntest\n' "$i" "$i" "$i" \
    > "$WORK/proj/.feedback/log/e$i.md"
done
printf 'feedback:\n  open_threshold: 2\n' > "$WORK/proj/.feedback/config.yaml"
OUT="$(CLAUDE_PROJECT_DIR="$WORK/proj" tpy "$FB" stats)"
assert_contains "$OUT" "openが2件以上" "open_threshold=2 で open 2件の NOTE が出る"
rm -f "$WORK/proj/.feedback/log/e1.md" "$WORK/proj/.feedback/log/e2.md" "$WORK/proj/.feedback/config.yaml"

# --- 雛形とガイドがスキーマと一致する ---
# 設定項目は harness_config.py / config.example.yaml / 設定ガイドに現れる。
# 文書が古いまま残るのを機械的に防ぐ。
# 設定ガイドは3言語ある。1言語だけを見ると、翻訳版に検査IDを足し忘れても
# 緑のまま通り、日本語以外の利用者にだけ不完全なリファレンスが残る
EXAMPLE="$REPO/.feedback/config.example.yaml"
GUIDES=(
  "$REPO/docs/configuration.md"
  "$REPO/docs/configuration.ja.md"
  "$REPO/docs/configuration.zh-CN.md"
)
assert_file_exists "$EXAMPLE" "雛形が存在する"
for GUIDE in "${GUIDES[@]}"; do
  assert_file_exists "$GUIDE" "設定ガイドが存在する: $(basename "$GUIDE")"
done

MISSING=""
while IFS=$'\t' read -r kind name _ _; do
  case "$kind" in
    key|param) grep -q "${name##*.}" "$EXAMPLE" || MISSING="$MISSING $name(雛形)" ;;
  esac
done < <(tpy "$CFG" --keys)
assert_eq "" "$MISSING" "全設定キーが雛形に載っている"

for GUIDE in "${GUIDES[@]}"; do
  MISSING=""
  while IFS=$'\t' read -r kind name _ _; do
    [[ "$kind" == "check" ]] || continue
    grep -q "\`$name\`" "$GUIDE" || MISSING="$MISSING $name"
  done < <(tpy "$CFG" --keys)
  assert_eq "" "$MISSING" "全検査IDが設定ガイドに載っている: $(basename "$GUIDE")"
done

# 言語切替行がお互いを指していること。3言語に分けた以上、どの版から入っても
# 他の版へ辿れなければ「英語だと思って開いた日本語文書」が別の形で再発する
for GUIDE in "${GUIDES[@]}"; do
  HEAD_LINE="$(head -n 1 "$GUIDE")"
  for peer in configuration.md configuration.ja.md configuration.zh-CN.md; do
    [[ "$(basename "$GUIDE")" == "$peer" ]] && continue
    assert_contains "$HEAD_LINE" "($peer)" \
      "$(basename "$GUIDE") の言語切替行が $peer を指す: $HEAD_LINE"
  done
done

# check.sh の呼び出しID と CHECKS のドリフトも防ぐ(設計書 §8)。
# 行頭アンカーの grep は "cmd && run_stage ..." 形式の行を拾えないため
# 非アンカーで抽出する。ID の過不足と、ステージ引数の取り違えの両方を見る
DRIFT="$(tpy - "$REPO/scripts/check.sh" "$CFG" <<'PY'
import pathlib, re, subprocess, sys
check_sh = pathlib.Path(sys.argv[1])
src = check_sh.read_text()
src += "\n".join(p.read_text() for p in sorted((check_sh.parent / "checks").glob("*.sh")))
calls = re.findall(r'\brun_stage(?:_soft)?\s+([a-z]+)\s+"([a-z0-9-]+)"', src)
keys = {}
for line in subprocess.run(
    [sys.executable, sys.argv[2], "--keys"], capture_output=True, text=True
).stdout.splitlines():
    if line.startswith("check\t"):
        _, cid, _stack, stage = line.split("\t")
        keys[cid] = stage
issues = []
for stage, cid in calls:
    if cid not in keys:
        issues.append(f"未登録ID: {cid}")
    elif keys[cid] != stage:
        issues.append(f"ステージ不一致: {cid} は {keys[cid]} だが {stage} で呼ばれている")
# 派生検査ID(mvn-<module> 等)の base は run_stage へ変数で渡るため呼び出し行から
# 拾えない。未使用扱いにはしないが、checks/ に literal で現れることは要求する
# — 本当に死んだ登録を見逃さないため。ステージの対応は個別テストが固定する。
config_src = pathlib.Path(sys.argv[2]).read_text()
derivable = re.findall(
    r'"([a-z0-9-]+)"', re.search(r"DERIVABLE_CHECKS\s*=\s*\(([^)]*)\)", config_src).group(1)
)
for base in derivable:
    if f'"{base}"' not in src:
        issues.append(f"派生元IDが checks/ に literal で現れない: {base}")
missing = sorted(set(keys) - {cid for _s, cid in calls} - set(derivable))
issues += [f"CHECKSにあるが未使用: {cid}" for cid in missing]
print("; ".join(issues))
PY
)"
assert_eq "" "$DRIFT" "check.sh の呼び出し検査ID・ステージが CHECKS と一致する"

# --- 個人設定レイヤ(.feedback/local/config.yaml) ---
# config.yaml は commit して共有する「チームの設定」、local/config.yaml は
# .gitignore 済みの「この端末だけの設定」。共有設定を書き換えずに手元の事情
# (ツール未導入・重い検査の一時停止)を反映するためのもの
LP="$WORK/localproj"
mkdir -p "$LP/.feedback/local"

eff() { # eff <root> — 実効設定を JSON で返す
  tpy "$CFG" --json "$1"
}
src_of() { # src_of <JSON> <検査ID> — その検査の判定と出所を "sev|src" で返す
  tpy -c '
import json, sys
d = json.loads(sys.stdin.read())
sev, src = d["severity"].get(sys.argv[1], ("(なし)", "(なし)"))
print(f"{sev}|{src}")
' "$2"
}

printf 'checks:\n  ruff:\n    severity: warn\n' > "$LP/.feedback/config.yaml"
assert_eq "warn|checks.ruff" "$(eff "$LP" | src_of - ruff)" \
  "共有設定だけなら出所はキー名のまま(既存表示を変えない)"

# 個人設定は共有設定に勝つ
printf 'checks:\n  ruff:\n    severity: skip\n' > "$LP/.feedback/local/config.yaml"
assert_eq "skip|local.checks.ruff" "$(eff "$LP" | src_of - ruff)" \
  "個人設定が共有設定を上書きし、出所に local. が付く"

# 一覧や JSON の利用者が安定して扱えるよう、出所の公開表記はドット形式に固定する
assert_not_contains "$(eff "$LP" | src_of - ruff)" "local:" \
  "出所はドット形式の安定した識別子にする"

# 個人設定が触れていない検査は共有設定のまま
printf 'checks:\n  ruff:\n    severity: warn\n  shellcheck:\n    severity: skip\n' \
  > "$LP/.feedback/config.yaml"
assert_eq "skip|checks.shellcheck" "$(eff "$LP" | src_of - shellcheck)" \
  "個人設定が触れていない検査は共有設定の判定と出所を保つ"

# 壊れた個人設定も FAIL として見えること(黙って無視しない)
printf 'checks:\n  ruff:\n    severity: nonsense\n' > "$LP/.feedback/local/config.yaml"
ERR="$(eff "$LP" | tpy -c 'import json,sys; print(json.loads(sys.stdin.read())["error"] or "")')"
assert_contains "$ERR" "local" "壊れた個人設定はどのファイルか分かる形でエラーになる"

assert_summary
