#!/usr/bin/env bash
# check.sh — スタック自動検出 → lint / typecheck / test / build を実行し、
# エージェントが読みやすい要約を出力する。失敗があれば exit 1。
#
# 使い方:
#   scripts/check.sh [プロジェクトルート]   # 省略時はカレントディレクトリ
#   FEEDBACK_CHECK_SKIP="test build" scripts/check.sh   # 特定ステージをスキップ
#
# 設計方針:
# - 出力は「エージェントへのフィードバック」なので、成功時は1行、失敗時は
#   末尾に失敗コマンドのログ(tail)を出す。長大なログ全文は出さない。
# - ツールが未インストールのステージは SKIP とし、失敗扱いにしない。
set -u

LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$LIBDIR/lib.sh"

ROOT="$(harness_project_root "${1:-}")" \
  || { echo "ERROR: ディレクトリが見つかりません: ${1:-}"; exit 2; }
cd "$ROOT" || { echo "ERROR: ディレクトリへ移動できません: $ROOT"; exit 2; }

SKIP="${FEEDBACK_CHECK_SKIP:-}"
RESULTS=()
FAILED=0
WARNED=0
SOFT_STAGE=0
STACK_FOUND=0   # マニフェストを検出したか。RESULTS の空判定とは分離する
                # (全ステージがSKIPでも「スタック未検出」とは報告しないため)
LOGDIR="$(mktemp -d)"
trap 'rm -rf "$LOGDIR"' EXIT

skipped() { [[ " $SKIP " == *" $1 "* ]]; }

# run_stage <stage> <tool> <label> <cmd...>
# <tool> にコマンド名を渡すと未インストール時に SKIP を記録する(失敗扱いにしない)。
# ツール判定が不要なステージは "-" を渡す。
run_stage() {
  local stage="$1" tool="$2" label="$3"; shift 3
  skipped "$stage" && { RESULTS+=("SKIP  $label (FEEDBACK_CHECK_SKIP)"); return; }
  if [[ "$tool" != "-" ]]; then
    if ! command -v "$tool" >/dev/null 2>&1; then
      RESULTS+=("SKIP  $label ($tool 未インストール)")
      return
    elif ! has "$tool"; then
      # PATH上にはあるが起動できない(shebang切れのvenv等)。環境側の問題である
      RESULTS+=("SKIP  $label ($tool 起動不可 — 環境を確認してください)")
      return
    fi
  fi
  local log="$LOGDIR/${label//[^a-zA-Z0-9]/_}.log"
  local rc
  "$@" >"$log" 2>&1
  rc=$?
  if [[ $rc -eq 0 ]]; then
    RESULTS+=("PASS  $label")
  elif [[ $rc -eq 126 || $rc -eq 127 ]]; then
    # 起動そのものに失敗(実行不可・未検出)。ユーザーのコードの問題ではない
    RESULTS+=("SKIP  $label (実行不可)")
  else
    if [[ "$SOFT_STAGE" == "1" ]]; then
      # 宣言していない検査の失敗は報告に留める。完了はブロックしない
      WARNED=1
      RESULTS+=("WARN  $label")
      {
        echo "----- WARN: $label ($*) — 末尾40行 -----"
        tail -n 40 "$log"
      } >> "$LOGDIR/warnings.txt"
    else
      FAILED=1
      RESULTS+=("FAIL  $label")
      {
        echo "----- FAIL: $label ($*) — 末尾40行 -----"
        tail -n 40 "$log"
      } >> "$LOGDIR/failures.txt"
    fi
  fi
}

# run_stage_soft — 失敗しても完了をブロックせず WARN として記録する。
# プロジェクトが設定で宣言していない検査(ハーネスの推測)に使う。
run_stage_soft() {
  SOFT_STAGE=1
  run_stage "$@"
  SOFT_STAGE=0
}

npm_script_exists() { # package.json に scripts.<name> があるか
  node -e "process.exit(require('./package.json').scripts?.['$1'] ? 0 : 1)" 2>/dev/null
}

# 注意: git ls-files は「追跡済みだが作業ツリーから削除された」ファイルも列挙する。
# それらを検査ツールに渡すと読み取りエラーで完了をブロックしてしまう(実測: リンク
# 検査の [Errno 2]、bash -n の非ゼロ終了)。呼び出し側は必ず -f で実在を確認すること
list_files() { # list_files <glob> — 検査対象のファイルを1行1件で出力
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # --others を含めないと、まだコミットしていない新規ファイルが検査対象外になり、
    # 壊れた新規ファイルがあっても ALL PASS になる。--exclude-standard で
    # .gitignore 済み(ビルド成果物・依存ディレクトリ)は従来どおり除外する
    # -c core.quotePath=false: 非ASCIIファイル名を8進エスケープ("\350\250...")で
    # 出さず生のパスで出す。日本語ファイル名を持つプロジェクトで、受け取り側が
    # ファイルを開けなくなる(実測: .feedback/log/*.md で FileNotFoundError)
    git -c core.quotePath=false ls-files --cached --others --exclude-standard "$1"
  else
    find . -name "$1" -not -path './.git/*' -not -path './node_modules/*' -not -path './.venv/*'
  fi
}

# ---------- Python ----------
if [[ -f pyproject.toml || -f setup.py || -f requirements.txt ]]; then
  STACK_FOUND=1
  run_stage lint "ruff" "python: ruff" ruff check .
  # 宣言(pyproject.toml の [tool.ruff] 系)があれば FAIL、無ければ WARN。
  # 既存プロジェクトがフォーマッタ未使用の場合に完了不能にしないため
  if grep -q "^\[tool\.ruff" pyproject.toml 2>/dev/null; then
    run_stage format "ruff" "python: ruff format" ruff format --check .
  else
    run_stage_soft format "ruff" "python: ruff format" ruff format --check .
  fi
  if [[ -f pyproject.toml ]] && grep -q "\[tool.mypy\]" pyproject.toml 2>/dev/null; then
    run_stage typecheck "mypy" "python: mypy" mypy .
  fi
  if [[ -d tests ]] || ls ./test_*.py ./*_test.py >/dev/null 2>&1; then
    run_stage test "pytest" "python: pytest" pytest -q -x
  fi
else
  # マニフェストが無くても .py があれば lint はできる(check_file.sh と対称)
  PY_FILES=()
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] && PY_FILES+=("$f")
  done < <(list_files '*.py')
  if [[ ${#PY_FILES[@]} -gt 0 ]]; then
    STACK_FOUND=1
    run_stage lint "ruff" "python: ruff" ruff check "${PY_FILES[@]}"
    # マニフェストが無い=宣言も無いので WARN 固定
    run_stage_soft format "ruff" "python: ruff format" ruff format --check "${PY_FILES[@]}"
  fi
fi

# ---------- Node / TypeScript ----------
if [[ -f package.json ]]; then
  STACK_FOUND=1
  PM="npm"; [[ -f pnpm-lock.yaml ]] && PM="pnpm"; [[ -f yarn.lock ]] && PM="yarn"
  if ! has node; then
    # npm_script_exists が node に依存するため、node 不在では全ステージを判定できない
    RESULTS+=("SKIP  node: 全ステージ (node 未インストール)")
  else
    npm_script_exists lint      && run_stage lint      "$PM" "node: $PM run lint"      "$PM" run lint
    npm_script_exists typecheck && run_stage typecheck "$PM" "node: $PM run typecheck" "$PM" run typecheck
    if ! npm_script_exists typecheck && [[ -f tsconfig.json ]]; then
      # typescript 未導入で npx tsc を走らせると、ユーザーのコードと無関係な失敗が
      # FAIL になる(--no-install でも exit 1 のため run_stage の 126/127 判定では拾えない)。
      # --no-install を明示し、チェックが勝手にネットワークから取得しないようにする
      if skipped typecheck || npx --no-install tsc --version >/dev/null 2>&1; then
        run_stage typecheck "-" "node: tsc --noEmit" npx --no-install tsc --noEmit
      else
        RESULTS+=("SKIP  node: tsc --noEmit (typescript 未インストール)")
      fi
    fi
    npm_script_exists test  && run_stage test  "$PM" "node: $PM test"      "$PM" test
    npm_script_exists build && run_stage build "$PM" "node: $PM run build" "$PM" run build
  fi
fi

# ---------- Go ----------
if [[ -f go.mod ]]; then
  STACK_FOUND=1
  run_stage lint  "go" "go: vet"   go vet ./...
  run_stage build "go" "go: build" go build ./...
  run_stage test  "go" "go: test"  go test ./...
fi

# ---------- Rust ----------
if [[ -f Cargo.toml ]]; then
  STACK_FOUND=1
  if ! has cargo; then
    RESULTS+=("SKIP  rust: 全ステージ (cargo 未インストール)")
  else
    if cargo clippy --version >/dev/null 2>&1; then
      run_stage lint "-" "rust: clippy" cargo clippy --quiet -- -D warnings
    else
      run_stage build "-" "rust: check" cargo check --quiet
    fi
    run_stage test "-" "rust: test" cargo test --quiet
  fi
fi

# ---------- Java ----------
if [[ -f pom.xml ]]; then
  STACK_FOUND=1
  run_stage test "mvn" "java: mvn verify" mvn -q verify
elif [[ -f build.gradle || -f build.gradle.kts ]]; then
  STACK_FOUND=1
  if [[ -x ./gradlew ]]; then
    run_stage test "-" "java: gradlew check" ./gradlew -q check
  else
    run_stage test "gradle" "java: gradle check" gradle -q check
  fi
fi

# ---------- Shell ----------
# check_file.sh が .sh を扱えるのに check.sh 側に対応ステージがないと、
# シェルスクリプト主体のプロジェクト(ハーネス自身を含む)が一切検査されない。
SH_FILES=()
while IFS= read -r f; do
  [[ -n "$f" && -f "$f" ]] && SH_FILES+=("$f")
done < <(list_files '*.sh')
if [[ ${#SH_FILES[@]} -gt 0 ]]; then
  STACK_FOUND=1
  # shellcheck disable=SC2016  # $@ は内側の bash -c で展開させるため単一引用符が正しい
  run_stage lint "-" "shell: bash -n" \
    bash -c 'for f in "$@"; do bash -n "$f" || exit 1; done' _ "${SH_FILES[@]}"
  run_stage lint "shellcheck" "shell: shellcheck" \
    shellcheck -x -S "$SHELLCHECK_SEVERITY" "${SH_FILES[@]}"
fi

# ---------- 横断チェック(スタック非依存) ----------
# check_file.sh が JSON/YAML を検証できるのに check.sh 側に対応が無いと、
# Bash 経由・外部エディタで壊された設定ファイルが完了前チェックをすり抜ける
# (Shell ステージを追加したときと同じ非対称性)。
# STACK_FOUND は立てない — 設定ファイルの存在は「スタックの検出」ではない。
JSON_FILES=()
while IFS= read -r f; do
  [[ -n "$f" && -f "$f" ]] && JSON_FILES+=("$f")
done < <(list_files '*.json')
if [[ ${#JSON_FILES[@]} -gt 0 ]]; then
  run_stage lint "-" "config: json 構文" harness_validate_json "${JSON_FILES[@]}"
fi

YAML_FILES=()
while IFS= read -r f; do
  [[ -n "$f" && -f "$f" ]] && YAML_FILES+=("$f")
done < <(list_files '*.yaml')
while IFS= read -r f; do
  [[ -n "$f" && -f "$f" ]] && YAML_FILES+=("$f")
done < <(list_files '*.yml')
if [[ ${#YAML_FILES[@]} -gt 0 ]]; then
  if harness_has_pyyaml; then
    run_stage lint "-" "config: yaml 構文" harness_validate_yaml "${YAML_FILES[@]}"
  else
    RESULTS+=("SKIP  config: yaml 構文 (PyYAML 未インストール)")
  fi
fi

# ドキュメントの内部リンク。外部URLは検証しない(ネットワークを使わない原則)。
# リンク先が実在しないのは好みの問題ではなく事実誤りなので、常に FAIL とする
MD_FILES=()
while IFS= read -r f; do
  [[ -n "$f" && -f "$f" ]] && MD_FILES+=("$f")
done < <(list_files '*.md')
if [[ ${#MD_FILES[@]} -gt 0 ]]; then
  run_stage docs "-" "docs: 内部リンク" harness_check_md_links "${MD_FILES[@]}"
fi

# 検査対象を何か検出できたか。ここまでの全ステージの結果を見て判断する。
# 何も検出できていないディレクトリに「設定すれば有効になる」と案内しても
# 相手がいない上に、案内行が残ることで「スタック未検出」の報告を潰してしまう
anything_detected() { [[ $STACK_FOUND -eq 1 || ${#RESULTS[@]} -gt 0 ]]; }

# 秘密情報スキャン。secretlint は .secretlintrc.* が無いと exit 2 で実行できない
# (実測)ため、設定の有無をゲートにする。設定を書いた=チームが検査を選んだ、
# という宣言なので FAIL でよい。マスクは既定で有効 — 無効化する引数は渡さない
# (失敗ログはエージェントのコンテキストに入るため、秘密の値を拡散させない)
if ls .secretlintrc.* >/dev/null 2>&1; then
  # npx は「未インストール」も「秘密を検出」も exit 1 を返すので区別できない。
  # tsc と同じく --version で事前プローブし、未導入を誤FAILにしない
  if has npx && npx --no-install secretlint --version >/dev/null 2>&1; then
    run_stage security "-" "security: secretlint" npx --no-install secretlint "**/*"
  else
    RESULTS+=("SKIP  security: secretlint (secretlint 未インストール)")
  fi
elif anything_detected; then
  RESULTS+=("SKIP  security: secretlint (.secretlintrc.* が無い — 設定すると検査が有効になります)")
fi

# gitleaks があれば併用する(OS固有バイナリのため任意扱い)。バージョン差が
# 大きく v8.19 で detect が再編されたため、必要なフラグがヘルプに出ることを
# 確認してから使う。--redact は省略不可(秘密の値を出力に出さない)。
# PATH にあることはプロジェクトの宣言ではないので、検出対象があるときだけ走らせる
if anything_detected && has gitleaks; then
  GL_HELP="$(gitleaks detect --help 2>&1)"
  if [[ "$GL_HELP" == *"--no-git"* && "$GL_HELP" == *"--redact"* ]]; then
    run_stage security "-" "security: gitleaks" \
      gitleaks detect --no-git --redact --no-banner -s .
  else
    RESULTS+=("SKIP  security: gitleaks (この版は detect --no-git/--redact に非対応)")
  fi
fi

# ---------- 汎用フォールバック ----------
# 再帰ガード: make check のテストが check.sh を呼び返す循環を断つ。フック実行時は
# CLAUDE_PROJECT_DIR が子孫まで伝播し、テスト内の check.sh がルートを本リポジトリに
# 解決し直して make check がテストを再実行する — この無限再帰で Stop フックの
# timeout を食い潰していた。ガードが拾うのは make フォールバックだけ。直接ステージ
# (lint/test/build)はこの経路を通らないため必ず実行され、検証を抜けたまま完了しない。
if [[ -f Makefile ]] && grep -qE "^check:" Makefile; then
  STACK_FOUND=1
  if [[ -n "${FEEDBACK_CHECK_RECURSION_GUARD:-}" ]]; then
    RESULTS+=("SKIP  make check (再帰ガード — check.sh 起因のmake実行内のため)")
  else
    # env 経由で make とその子孫にだけ伝える。check.sh 全体へ export すると
    # 直接ステージの子孫(テスト内で別プロジェクトを検証する等)まで誤スキップする
    run_stage test "make" "make check" env FEEDBACK_CHECK_RECURSION_GUARD=1 make check
  fi
fi

# ---------- 結果出力 ----------
echo "=== feedback-harness check ==="
if [[ $STACK_FOUND -eq 0 && ${#RESULTS[@]} -eq 0 ]]; then
  echo "検出できたスタックがありません (pyproject.toml / package.json / go.mod / Cargo.toml / pom.xml / *.sh / Makefile:check を確認)"
  exit 0
fi
if [[ ${#RESULTS[@]} -eq 0 ]]; then
  echo "スタックは検出しましたが、実行できるステージがありません"
  exit 0
fi
printf '%s\n' "${RESULTS[@]}"

if [[ $WARNED -eq 1 ]]; then
  echo
  echo "以下は完了をブロックしませんが、確認してください:"
  cat "$LOGDIR/warnings.txt"
fi

if [[ $FAILED -eq 1 ]]; then
  echo
  echo "以下の失敗を修正してから完了とすること:"
  cat "$LOGDIR/failures.txt"
  exit 1
fi

# 全ステージSKIPで "ALL PASS" と出すと、実際には何も検証していないのに
# 検証済みだとエージェントに誤解させる。部分SKIPも件数を添えて明示する
PASSED=0
SKIPPED=0
WARNS=0
for r in "${RESULTS[@]}"; do
  case "$r" in
    PASS*) PASSED=$((PASSED + 1)) ;;
    SKIP*) SKIPPED=$((SKIPPED + 1)) ;;
    WARN*) WARNS=$((WARNS + 1)) ;;
  esac
done
if [[ $((PASSED + WARNS)) -eq 0 ]]; then
  echo "実行できたステージがありません(すべてSKIP)"
  exit 0
fi
if [[ $WARNS -gt 0 && $SKIPPED -gt 0 ]]; then
  echo "ALL PASS (${WARNS}件WARN・${SKIPPED}件SKIP — 未検証/未対応の項目があります)"
elif [[ $WARNS -gt 0 ]]; then
  echo "ALL PASS (${WARNS}件WARN — 未対応の指摘があります)"
elif [[ $SKIPPED -gt 0 ]]; then
  echo "ALL PASS (${SKIPPED}件SKIP — 未検証の項目があります)"
else
  echo "ALL PASS"
fi
exit 0
