#!/usr/bin/env bash
# test_audit.sh — オンデマンド脆弱性監査 audit.sh を検証する。
#
# audit.sh は唯一ネットワークを使う検査(Stopフックからは呼ばれない)。
# 検証するのは配線の契約: スタック検出・ツール不在SKIP・exit code・
# スタンプが「成功時のみ」書かれること(失敗中は推奨が消えないため)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
AUDIT="$REPO/scripts/audit.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

new_project() { # new_project <名前>
  local d="$WORK/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
make_fake() { # make_fake <名前> <exit> [記録ファイル]
  { echo '#!/usr/bin/env bash'
    echo 'case "$*" in *--version*) exit 0 ;; esac'
    [[ -n "${3:-}" ]] && echo "echo \"\$@\" >> \"$3\""
    echo "exit $2"
  } > "$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}

# --- Python: ツールがあり検出したら FAIL + スタンプ無し ---
P1="$(new_project py_vuln)"
printf '[project]\nname = "t"\n' > "$P1/pyproject.toml"
ARGS="$WORK/pipaudit_args.txt"; : > "$ARGS"
make_fake pip-audit 1 "$ARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P1" 2>&1)"; RC=$?
assert_eq "1" "$RC" "脆弱性ありで exit 1"
assert_contains "$OUT" "FAIL  python: pip-audit" "FAILとして記録される"
assert_not_contains "$(cat "$ARGS")" "--no-install" "pip-audit は直接起動(npxを介さない)"
assert_file_absent "$P1/.feedback/.last-audit" "失敗時はスタンプを書かない"

# --- 成功時は exit 0 + スタンプに今日の日付 ---
P2="$(new_project py_ok)"
printf '[project]\nname = "t"\n' > "$P2/pyproject.toml"
make_fake pip-audit 0
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P2" 2>&1)"; RC=$?
assert_eq "0" "$RC" "脆弱性なしで exit 0"
assert_contains "$OUT" "PASS  python: pip-audit" "PASSとして記録される"
assert_file_exists "$P2/.feedback/.last-audit" "成功時にスタンプが作られる"
TODAY="$(python3 -c 'import datetime; print(datetime.date.today().isoformat())')"
assert_contains "$(cat "$P2/.feedback/.last-audit")" "$TODAY" "スタンプはISO日付1行"
# fake を使い捨てる(次セクションは「ツール不在」を検証するため、
# P2 で作った fake が残っていると不在が再現できない — test_check_p2.sh と同じ作法)
rm -f "$FAKEBIN/pip-audit"

# --- ツール不在は SKIP(FAILにしない) ---
P3="$(new_project py_notool)"
printf '[project]\nname = "t"\n' > "$P3/pyproject.toml"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P3" 2>&1)"; RC=$?
assert_eq "0" "$RC" "ツール不在で完了をブロックしない"
assert_contains "$OUT" "SKIP  python: pip-audit (pip-audit 未インストール)" "理由付きSKIP"

# --- Node: lockfile があるときだけ npm audit ---
P4="$(new_project node_vuln)"
printf '{"name":"t","private":true}\n' > "$P4/package.json"
printf '{}\n' > "$P4/package-lock.json"
NARGS="$WORK/npm_args.txt"; : > "$NARGS"
make_fake npm 1 "$NARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P4" 2>&1)"; RC=$?
assert_eq "1" "$RC" "npm audit の失敗は exit 1"
assert_contains "$OUT" "FAIL  node: npm audit" "FAILとして記録される"
assert_contains "$(cat "$NARGS")" "--audit-level=high" "高深刻度のみ失敗扱い"

# lockfile が無い package.json のみは対象外(監査不能なものを監査しない)
P5="$(new_project node_nolock)"
printf '{"name":"t","private":true}\n' > "$P5/package.json"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P5" 2>&1)"
assert_not_contains "$OUT" "npm audit" "lockfileが無ければステージを出さない"

# --- pnpm/yarn の lockfile しか無ければ npm audit を走らせない ---
# npm audit が読めるのは package-lock.json だけで、pnpm-lock.yaml しか無いと
# ENOLOCK で exit 1 になる(実測)。走らせると脆弱性ゼロのプロジェクトが
# 「脆弱性あり」と誤報告される(check.sh の npm ls を npm 限定にしたのと同じ欠陥クラス)
P8="$(new_project node_pnpm)"
printf '{"name":"t","private":true}\n' > "$P8/package.json"
printf 'lockfileVersion: 9\n' > "$P8/pnpm-lock.yaml"
: > "$NARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P8" 2>&1)"; RC=$?
assert_eq "0" "$RC" "pnpm プロジェクトを誤FAILさせない"
assert_contains "$OUT" "SKIP  node: npm audit" "理由付きSKIPになる"
assert_eq "" "$(cat "$NARGS")" "npm audit を起動しない"

# --- Rust: cargo はあるが cargo-audit が無ければ SKIP(FAILにしない) ---
# cargo audit は cargo 内蔵ではなく cargo-audit クレート由来。cargo だけある環境では
# `cargo audit` が exit 101 になるため、probe が cargo のままだと「未導入」が誤FAILする
P7="$(new_project rust_notool)"
printf '[package]\nname = "t"\nversion = "0.1.0"\n' > "$P7/Cargo.toml"
printf 'version = 3\n' > "$P7/Cargo.lock"
make_fake cargo 101  # --version は 0、audit は 101(実際の失敗モード)
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P7" 2>&1)"; RC=$?
assert_eq "0" "$RC" "cargo-audit 不在で完了をブロックしない"
assert_contains "$OUT" "SKIP  rust: cargo audit (cargo-audit 未インストール)" "cargo-audit 不在は理由付きSKIP"
rm -f "$FAKEBIN/cargo"

# --- 依存ファイルが一切無いプロジェクト ---
P6="$(new_project nothing)"
printf 'hello\n' > "$P6/README.txt"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P6" 2>&1)"; RC=$?
assert_eq "0" "$RC" "監査対象が無くても exit 0"
assert_contains "$OUT" "監査対象が見つかりません" "対象なしの旨を表示"
assert_file_absent "$P6/.feedback/.last-audit" "何も実行していない場合はスタンプを書かない"

assert_summary
