#!/usr/bin/env bash
# test_check_file_severity.sh — check_file.sh(PostToolUse 用の単発ファイル検査)が
# check.sh と同じ実効判定(severity: skip/warn/fail)に従うことを検証する。
#
# 以前は severity: skip が一部の検査にしか効かず、severity: warn も最終的に
# exit 1 になっていた。フルチェックでは SKIP/WARN でも、編集のたびに
# PostToolUse がブロックする食い違いがあった(review/feature-enhance-fowler-feedback.md)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CF="$REPO/scripts/check_file.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"

make_fake() { # make_fake <名前> <exit> — --version は常に成功させ、失敗時は出力も出す
  { echo '#!/usr/bin/env bash'
    echo 'case "$*" in *--version*) exit 0 ;; esac'
    echo "[[ $2 -ne 0 ]] && echo 'FAKE: 問題を検出しました'"
    echo "exit $2"
  } > "$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}

new_project() { # new_project <名前>
  local d="$WORK/$1"
  mkdir -p "$d/.feedback"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}

# check_file.sh はファイルパスしか受け取らずルートを引数で渡せないため、
# harness_project_root() の解決(git 由来)に rely する。フック由来の
# CLAUDE_PROJECT_DIR 伝播は run_tests.sh が一括して掃落とすが、単体実行でも
# 冪等に保つ保険としてここでも空にする(隔離プロジェクトの git init で解決)
run_cf() { CLAUDE_PROJECT_DIR="" PATH="$FAKEBIN:$PATH" bash "$CF" "$1" 2>&1; } # run_cf <ファイル>

# --- severity: skip は実行そのものをしない ---
P1="$(new_project skip)"
make_fake ruff 1   # 呼ばれたら必ず F401 相当の失敗を返す偽ツール
printf 'checks:\n  ruff:\n    severity: skip\n' > "$P1/.feedback/config.yaml"
printf 'import os\n' > "$P1/bad.py"
OUT="$(cd "$P1" && run_cf "$P1/bad.py")"; RC=$?
assert_eq "0" "$RC" "checks.ruff.severity=skip で exit 0"
assert_eq "" "$OUT" "skip では出力も出ない"

# --- severity: warn は指摘を表示するが非ブロッキング ---
P2="$(new_project warn)"
make_fake ruff 1
printf 'checks:\n  ruff:\n    severity: warn\n' > "$P2/.feedback/config.yaml"
printf 'import os\n' > "$P2/bad.py"
OUT="$(cd "$P2" && run_cf "$P2/bad.py")"; RC=$?
assert_eq "0" "$RC" "checks.ruff.severity=warn で exit 0(非ブロッキング)"
assert_contains "$OUT" "非ブロッキング" "warn の指摘だとわかる文言が出る"

# --- 指定が無ければ従来どおりブロックする(既定 fail) ---
P3="$(new_project default_fail)"
make_fake ruff 1
printf 'import os\n' > "$P3/bad.py"
OUT="$(cd "$P3" && run_cf "$P3/bad.py")"; RC=$?
assert_eq "1" "$RC" "config 無しでは従来どおり exit 1"
assert_contains "$OUT" "問題があります" "ブロッキングの文言が出る"

# --- node-lint も同じ配線に従う(eslint 相当) ---
P4="$(new_project node_skip)"
mkdir -p "$P4/node_modules/.bin"
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo 'exit 1'
} > "$FAKEBIN/npx"; chmod +x "$FAKEBIN/npx"
printf '{}' > "$P4/eslint.config.js" # -f eslintrc 判定用ではなく eslint.config.js 判定を使う
printf 'checks:\n  node-lint:\n    severity: skip\n' > "$P4/.feedback/config.yaml"
printf 'var x = 1\n' > "$P4/bad.js"
OUT="$(cd "$P4" && run_cf "$P4/bad.js")"; RC=$?
assert_eq "0" "$RC" "checks.node-lint.severity=skip で exit 0"
rm -f "$FAKEBIN/npx"

# --- eslint 未導入は差し戻さない(npx を実際に呼ぶ経路) ---
# 上の skip ケースは分岐へ入る前に return するため、npx を起動するコードパスは
# 一度も実行されていなかった。npx --no-install は「未インストール」も「lint 違反」も
# 非0で返すため、設定ファイルの有無だけをゲートにすると eslint 未導入のプロジェクトで
# npm の内部エラー(missing packages)がそのまま差し戻される(実測で再現)
P6="$(new_project node_eslint_missing)"
{ echo '#!/usr/bin/env bash'
  # --version(プローブ)も本体も失敗する = eslint がインストールされていない状態
  echo 'echo "npm error npx canceled due to missing packages and no YES option: [\"eslint@9.39.5\"]" >&2'
  echo 'exit 1'
} > "$FAKEBIN/npx"; chmod +x "$FAKEBIN/npx"
printf '{}' > "$P6/eslint.config.js"
printf 'var x = 1\n' > "$P6/bad.js"
OUT="$(cd "$P6" && run_cf "$P6/bad.js")"; RC=$?
assert_eq "0" "$RC" "eslint 未導入では差し戻さない"
assert_not_contains "$OUT" "missing packages" "npm の内部エラーを差し戻さない"

# --- eslint 導入済みなら lint 違反を差し戻す(同じ経路の対になるケース) ---
# 上の未導入ケースだけだと「常に素通し」に退行しても緑のままになる
P7="$(new_project node_eslint_present)"
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo 'echo "bad.js:1:1: warning: unexpected var [no-var]"'
  echo 'exit 1'
} > "$FAKEBIN/npx"; chmod +x "$FAKEBIN/npx"
printf '{}' > "$P7/eslint.config.js"
printf 'var x = 1\n' > "$P7/bad.js"
OUT="$(cd "$P7" && run_cf "$P7/bad.js")"; RC=$?
assert_eq "1" "$RC" "eslint 導入済みなら lint 違反で exit 1"
assert_contains "$OUT" "no-var" "eslint の指摘内容が出る"
rm -f "$FAKEBIN/npx"

# --- ESLint の設定ファイル名を固定列挙にしない ---
# ESLint は eslintrc 系(.eslintrc / .eslintrc.{js,cjs,mjs,json,yml,yaml})と
# フラット系(eslint.config.{js,mjs,cjs,ts,mts,cts})の2系統を探索する。
# 4種だけを見ていたため .eslintrc.cjs(package.json が "type": "module" の
# ときの定番)等では検査が丸ごと飛び、同じ違反を Stop 側の `$PM run lint` だけが
# 報告する食い違いになっていた。名前ごとに if を足す形にすると必ず取りこぼすので、
# 代表的な名前を**並べて回す**形で固定する(1つでも漏れれば落ちる)
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo 'echo "bad.js:1:1: warning: unexpected var [no-var]"'
  echo 'exit 1'
} > "$FAKEBIN/npx"; chmod +x "$FAKEBIN/npx"
for cfg in .eslintrc .eslintrc.cjs .eslintrc.yml .eslintrc.yaml .eslintrc.json \
           eslint.config.js eslint.config.cjs eslint.config.mjs eslint.config.ts; do
  PC="$(new_project "node_cfg_$(printf '%s' "$cfg" | tr -c 'a-zA-Z0-9' '_')")"
  printf '{}' > "$PC/$cfg"
  printf 'var x = 1\n' > "$PC/bad.js"
  OUT="$(cd "$PC" && run_cf "$PC/bad.js")"; RC=$?
  assert_eq "1" "$RC" "$cfg を設定として認識し ESLint を実行する"
  assert_contains "$OUT" "no-var" "$cfg のとき指摘内容が出る: $OUT"
done

# 設定がまったく無ければ従来どおり ESLint を起動しない(過剰検出への退行防止)
PN="$(new_project node_cfg_none)"
printf 'var x = 1\n' > "$PN/bad.js"
OUT="$(cd "$PN" && run_cf "$PN/bad.js")"; RC=$?
assert_eq "0" "$RC" "ESLint 設定が無ければ差し戻さない: $OUT"
rm -f "$FAKEBIN/npx"

# --- formatter を指定しない(core から外れた formatter を渡さない) ---
# `--format unix` / `compact` は ESLint 10 で core から外れ、指定すると
# "The unix formatter is no longer part of core ESLint" というツール自身の
# エラーが**ユーザーのファイルの問題**として差し戻される(実測 eslint 10.1.0)。
# 「環境の問題をユーザーのコードの失敗として報告しない」という check の契約に
# 反するため、実際の起動引数を記録して --format を渡していないことを固定する
# (ソース文字列ではなく本番の呼び出しを見る)
ARGLOG="$WORK/npx-args.log"
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo "printf '%s\\n' \"\$*\" >> '$ARGLOG'"
  echo 'echo "bad.js:1:1: warning: unexpected var [no-var]"'
  echo 'exit 1'
} > "$FAKEBIN/npx"; chmod +x "$FAKEBIN/npx"
PF="$(new_project node_formatter)"
printf '{}' > "$PF/eslint.config.js"
printf 'var x = 1\n' > "$PF/bad.js"
( cd "$PF" && run_cf "$PF/bad.js" ) >/dev/null
ARGS="$(cat "$ARGLOG" 2>/dev/null || true)"
assert_contains "$ARGS" "eslint" "前提: eslint を実際に起動している: $ARGS"
assert_not_contains "$ARGS" "--format" "core から外れた formatter を指定しない: $ARGS"
rm -f "$FAKEBIN/npx"

# --- ESLint の致命的エラー(exit 2)は差し戻さない ---
# ESLint の終了コードは 0=指摘なし / 1=lint 違反 / 2=致命的エラー。
# 「非0なら違反」と扱うと、eslintrc しか持たないプロジェクト(ESLint 9 以降は
# eslintrc を読まない)で「eslint.config.js が見つからない」というツール側の
# 都合が、編集のたびにユーザーのファイルの問題として差し戻される(実測 10.1.0)。
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo 'echo "Oops! Something went wrong! :("'
  echo 'echo "ESLint couldn'"'"'t find an eslint.config.(js|mjs|cjs) file."'
  echo 'exit 2'
} > "$FAKEBIN/npx"; chmod +x "$FAKEBIN/npx"
PE="$(new_project node_eslint_fatal)"
printf '{"rules":{}}' > "$PE/.eslintrc.json"   # ESLint 9+ が読まない旧形式
printf 'var x = 1\n' > "$PE/bad.js"
OUT="$(cd "$PE" && run_cf "$PE/bad.js")"; RC=$?
assert_eq "0" "$RC" "ESLint の致命的エラー(exit 2)では差し戻さない: $OUT"
assert_not_contains "$OUT" "問題があります" "ツール側の都合をファイルの問題として差し戻さない: $OUT"
# 黙って捨てない。壊れた設定は非ブロッキングの WARN として見せる —
# 見せないと「lint されているつもりで一度も lint されない」状態が続く
assert_contains "$OUT" "ESLint を実行できませんでした" "設定の破綻は WARN として見せる: $OUT"

# WARN は exit 0 で返るため、post_edit.sh は出力を捨てて pass を記録する。
# 記録まで捨てると「一度も lint していない」ことが件数からも消え、件数が減る
# のではなく初回通過率が上がったように見える形で壊れる — 指標を読む側からは
# 気づけない。.ts は構文検査のフォールバックも無く被覆が完全にゼロになるので、
# この経路こそ記録が要る(2026-09-03 のレビュー由来)
printf 'const x: number = 1\n' > "$PE/typed.ts"
: > "$PE/.feedback/events.jsonl"
OUT="$(cd "$PE" && run_cf "$PE/typed.ts")"; RC=$?
assert_eq "0" "$RC" "前提: .ts でも致命的エラーでは差し戻さない: $OUT"
EV="$(cat "$PE/.feedback/events.jsonl" 2>/dev/null || true)"
assert_contains "$EV" '"result":"warn"' \
  "WARN を events.jsonl に記録する(記録まで握り潰さない): $EV"
assert_contains "$EV" '"hook":"post_edit"' \
  "記録は post_edit として残す(stop の件数に混ぜない): $EV"
assert_contains "$EV" '"check":"node-lint"' \
  "どの検査が素通ししたかを検査IDで残す: $EV"

# 対になるケース: 問題なしの実行は WARN を記録しない(常に記録する退行を禁じる)
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo 'exit 0'
} > "$FAKEBIN/npx"; chmod +x "$FAKEBIN/npx"
: > "$PE/.feedback/events.jsonl"
( cd "$PE" && run_cf "$PE/typed.ts" ) >/dev/null
assert_eq "" "$(cat "$PE/.feedback/events.jsonl")" \
  "指摘が無ければ WARN は記録しない: $(cat "$PE/.feedback/events.jsonl")"
# exit 2 を返す偽 npx へ戻す(以降のケースが前提にしている)
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo 'echo "Oops! Something went wrong! :("'
  echo 'exit 2'
} > "$FAKEBIN/npx"; chmod +x "$FAKEBIN/npx"

# ESLint が判定を返せないときは構文検査へ倒す。
# 「lint を試みた」ことを理由に検査ゼロで素通しすると、壊れた設定の
# プロジェクトだけ PostToolUse が無検査になる(exit 2 対応で作りかけた穴)
printf 'function f( {\n' > "$PE/broken-syntax.js"
OUT="$(cd "$PE" && run_cf "$PE/broken-syntax.js")"; RC=$?
assert_eq "1" "$RC" "ESLint が使えなくても構文エラーは捕まえる: $OUT"
assert_contains "$OUT" "問題があります" "構文エラーは差し戻す: $OUT"

# 対になるケース: exit 1(本物の lint 違反)は従来どおり差し戻す
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo 'echo "bad.js:1:1: warning: unexpected var [no-var]"'
  echo 'exit 1'
} > "$FAKEBIN/npx"; chmod +x "$FAKEBIN/npx"
OUT="$(cd "$PE" && run_cf "$PE/bad.js")"; RC=$?
assert_eq "1" "$RC" "exit 1(lint 違反)は従来どおり差し戻す: $OUT"
rm -f "$FAKEBIN/npx"

# --- 壊れた config.yaml は check_file.sh 自身をブロックする ---
# AGENTS.md §2 で check_file.sh は編集直後の必須ゲート。黙って exit 0 で
# 通すと、設定の打ち間違いに誰も気づけない
P5="$(new_project broken_config)"
printf 'check:\n  lnit: []\n' > "$P5/.feedback/config.yaml"
printf 'hello\n' > "$P5/ok.txt"
OUT="$(cd "$P5" && run_cf "$P5/ok.txt")"; RC=$?
assert_eq "1" "$RC" "壊れた config.yaml で check_file.sh も exit 1"
assert_contains "$OUT" "設定エラー" "設定エラーの文言が出る"
assert_contains "$OUT" "lnit" "原因のキー名が出る"

rm -f "$FAKEBIN/ruff"
assert_summary
