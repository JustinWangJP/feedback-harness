#!/usr/bin/env bash
# test_check_p2.sh — P2 で追加した検査(docs / security / 依存整合性 / 各種lint)が
# check.sh に正しく配線されているかを検証する。
#
# 外部ツールは PATH に偽実行ファイルを置いて駆動する。検証するのはツールの
# 検出精度ではなく「検出条件・引数・終了コードの写像」という配線の契約である。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$REPO/scripts/check.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

new_project() { # new_project <名前> — 空のgitプロジェクトを作りパスを返す
  local d="$WORK/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}

# --- docs: 内部リンク ---
P1="$(new_project docs_broken)"
printf 'see [x](missing.md)\n' > "$P1/README.md"
OUT="$(bash "$CHECK" "$P1" 2>&1)"; RC=$?
assert_eq "1" "$RC" "リンク切れで exit 1 になる"
assert_contains "$OUT" "docs: 内部リンク" "docs ステージが結果に出る"
assert_contains "$OUT" "missing.md" "失敗ログにリンク先が出る"

P2="$(new_project docs_ok)"
printf 'target\n' > "$P2/target.md"
printf 'see [t](target.md)\n' > "$P2/README.md"
OUT="$(bash "$CHECK" "$P2" 2>&1)"; RC=$?
assert_eq "0" "$RC" "リンクが有効なら exit 0"
assert_contains "$OUT" "PASS  docs: 内部リンク" "PASSとして記録される"

# --- Markdown が無ければステージ自体を出さない ---
P3="$(new_project no_md)"
printf 'hello\n' > "$P3/note.txt"
OUT="$(bash "$CHECK" "$P3" 2>&1)"
assert_not_contains "$OUT" "docs: 内部リンク" "対象が無ければステージを出さない"
# 何も検出できていないディレクトリでは横断チェックの案内も出さない
# (案内行が残ると「スタック未検出」の報告を潰してしまう)
assert_not_contains "$OUT" "security: secretlint" "検出対象が無ければ案内も出さない"

# --- 非ASCIIファイル名でも落ちない(git ls-files のエスケープ対策の回帰) ---
P4="$(new_project nonascii)"
printf 'target\n' > "$P4/対象.md"
printf 'see [t](対象.md)\n' > "$P4/日本語ファイル名.md"
OUT="$(bash "$CHECK" "$P4" 2>&1)"; RC=$?
assert_eq "0" "$RC" "日本語ファイル名でも誤検出しない"
assert_contains "$OUT" "PASS  docs: 内部リンク" "日本語ファイル名を検証対象にできる"

# --- 追跡済みだが作業ツリーから消えたファイルは対象外(list_files が列挙するため) ---
P5="$(new_project deleted_md)"
printf 'gone\n' > "$P5/gone.md"
printf 'true\n' > "$P5/gone.sh"
( cd "$P5" && git add gone.md gone.sh \
    && git -c user.email=t@example.com -c user.name=t commit -q -m init \
    && rm gone.md gone.sh )
printf 'target\n' > "$P5/target.md"
printf 'see [t](target.md)\n' > "$P5/README.md"
OUT="$(bash "$CHECK" "$P5" 2>&1)"; RC=$?
assert_eq "0" "$RC" "削除済み追跡ファイルがあっても exit 0"
assert_not_contains "$OUT" "Errno 2" "削除済みファイルを読もうとしない"
assert_contains "$OUT" "PASS  docs: 内部リンク" "残ったファイルは検証される"
# .sh も同様。bash -n は存在しないファイルで非ゼロを返すため、渡すと誤FAILになる
assert_not_contains "$OUT" "FAIL  shell: bash -n" "削除済みの.shで誤FAILしない"

# --- security: secretlint(設定ゲート) ---
# 偽ツールを PATH に置く。検証するのは検出精度ではなく配線の契約
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
make_fake() { # make_fake <名前> <exit> [記録ファイル]
  # --version だけは 0 を返す。実物は検出の有無に関わらずバージョンを返すため、
  # check.sh はこの応答で「未インストール」と「検出あり」(どちらも exit 1)を分ける
  { echo '#!/usr/bin/env bash'
    [[ -n "${3:-}" ]] && echo "echo \"\$@\" >> \"$3\""
    echo 'case "$*" in *--version*) exit 0 ;; esac'
    echo "exit $2"
  } > "$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}
make_fake_missing() { # make_fake_missing <名前> — --version も失敗する = 未インストール相当
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}

# 設定が無ければ実行しない(secretlint は設定なしでは exit 2 で落ちるため)
P6="$(new_project sl_nocfg)"
# 検査対象を1つ持たせる。何も検出できないディレクトリでは横断チェック自体を
# 行わない仕様のため、案内の SKIP を見るには検出対象が要る
printf 'note\n' > "$P6/README.md"
make_fake npx 1
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P6" 2>&1)"; RC=$?
assert_eq "0" "$RC" "secretlint 設定が無ければ完了をブロックしない"
assert_contains "$OUT" "SKIP  security: secretlint" "設定が無ければ理由付きSKIP"
assert_contains "$OUT" ".secretlintrc" "SKIP理由に設定ファイル名が出る"

# 設定があれば実行し、失敗は FAIL になる
P7="$(new_project sl_cfg)"
printf 'x\n' > "$P7/a.txt"
printf '{"rules":[]}' > "$P7/.secretlintrc.json"
ARGS="$WORK/npx_args.txt"; : > "$ARGS"
make_fake npx 1 "$ARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P7" 2>&1)"; RC=$?
assert_eq "1" "$RC" "設定があり検出されたら exit 1"
assert_contains "$OUT" "FAIL  security: secretlint" "FAILとして記録される"
# 秘密の値を出さない契約: マスク無効化オプションを渡していないこと
assert_not_contains "$(cat "$ARGS")" "--no-maskSecrets" "マスクを無効化する引数を渡さない"
assert_contains "$(cat "$ARGS")" "secretlint" "secretlint を呼んでいる"

# 設定があっても secretlint 未インストールなら FAIL にしない。npx は検出時も
# 未インストール時も exit 1 を返すため、事前プローブが無いと誤FAILになる
P8="$(new_project sl_notool)"
printf 'x\n' > "$P8/a.txt"
printf '{"rules":[]}' > "$P8/.secretlintrc.json"
make_fake_missing npx
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P8" 2>&1)"; RC=$?
assert_eq "0" "$RC" "secretlint 未インストールなら完了をブロックしない"
assert_contains "$OUT" "SKIP  security: secretlint" "未インストールは理由付きSKIP"

# 設定があり問題が無ければ PASS
P9="$(new_project sl_pass)"
printf 'x\n' > "$P9/a.txt"
printf '{"rules":[]}' > "$P9/.secretlintrc.json"
make_fake npx 0
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P9" 2>&1)"; RC=$?
assert_eq "0" "$RC" "問題が無ければ exit 0"
assert_contains "$OUT" "PASS  security: secretlint" "PASSとして記録される"

# --- security: gitleaks(フラグ対応のプローブ) ---
# 対応版: ヘルプに両フラグが出る → 実行される
P10="$(new_project gl_ok)"
printf 'note\n' > "$P10/README.md"
GLARGS="$WORK/gl_args.txt"; : > "$GLARGS"
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in'
  echo '  *--help*) echo "  --no-git  scan without git"; echo "  --redact  redact secrets"; exit 0 ;;'
  echo '  *--version*) exit 0 ;;'
  echo 'esac'
  echo "echo \"\$@\" >> \"$GLARGS\""
  echo 'exit 1'
} > "$FAKEBIN/gitleaks"
chmod +x "$FAKEBIN/gitleaks"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P10" 2>&1)"; RC=$?
assert_eq "1" "$RC" "gitleaks が検出したら exit 1"
assert_contains "$OUT" "FAIL  security: gitleaks" "FAILとして記録される"
assert_contains "$(cat "$GLARGS")" "--redact" "秘密を伏せる --redact を必ず渡す"

# 非対応版: ヘルプにフラグが無い → 誤検出を避けて SKIP
P11="$(new_project gl_old)"
printf 'note\n' > "$P11/README.md"
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--help*) echo "  usage: gitleaks"; exit 0 ;; *--version*) exit 0 ;; esac'
  echo 'exit 1'
} > "$FAKEBIN/gitleaks"
chmod +x "$FAKEBIN/gitleaks"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P11" 2>&1)"; RC=$?
assert_eq "0" "$RC" "非対応版では完了をブロックしない"
assert_contains "$OUT" "SKIP  security: gitleaks" "非対応版は理由付きSKIP"
rm -f "$FAKEBIN/gitleaks"

# --- ci: actionlint(ワークフローがある時だけ) ---
P12="$(new_project ci_ws)"
mkdir -p "$P12/.github/workflows"
printf 'name: t\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' \
  > "$P12/.github/workflows/ci.yml"
make_fake actionlint 1
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P12" 2>&1)"; RC=$?
assert_eq "1" "$RC" "actionlint の失敗は exit 1"
assert_contains "$OUT" "FAIL  ci: actionlint" "FAILとして記録される"

# ワークフローが無ければ何も出さない
P13="$(new_project ci_none)"
printf 'x\n' > "$P13/a.txt"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P13" 2>&1)"
assert_not_contains "$OUT" "ci: actionlint" "ワークフローが無ければステージを出さない"
rm -f "$FAKEBIN/actionlint"

# --- docker: dockerfilelint(exit 2 を FAIL として扱う) ---
P14="$(new_project df)"
printf 'FROM node:latest\n' > "$P14/Dockerfile"
DFARGS="$WORK/df_args.txt"; : > "$DFARGS"
make_fake npx 2 "$DFARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P14" 2>&1)"; RC=$?
assert_eq "1" "$RC" "dockerfilelint の exit 2 を FAIL として扱う"
assert_contains "$OUT" "FAIL  docker: dockerfilelint" "FAILとして記録される"
assert_contains "$(cat "$DFARGS")" "Dockerfile" "対象ファイルを渡している"

# サブディレクトリの Dockerfile も拾う
P15="$(new_project df_sub)"
mkdir -p "$P15/docker"
printf 'FROM node:20-alpine\n' > "$P15/docker/Dockerfile"
make_fake npx 0
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P15" 2>&1)"; RC=$?
assert_eq "0" "$RC" "問題が無ければ exit 0"
assert_contains "$OUT" "PASS  docker: dockerfilelint" "サブディレクトリの Dockerfile も検査する"

assert_summary
