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

ROOT="${1:-.}"
cd "$ROOT" 2>/dev/null || { echo "ERROR: ディレクトリが見つかりません: $ROOT"; exit 2; }

SKIP="${FEEDBACK_CHECK_SKIP:-}"
RESULTS=()
FAILED=0
STACK_FOUND=0   # マニフェストを検出したか。RESULTS の空判定とは分離する
                # (全ステージがSKIPでも「スタック未検出」とは報告しないため)
LOGDIR="$(mktemp -d)"
trap 'rm -rf "$LOGDIR"' EXIT

# has: コマンドが存在し、かつ実際に起動できるか。
# command -v はファイルの存在と実行ビットしか見ないため、shebang切れのvenv等を
# 「インストール済み」と誤判定し、環境障害がFAILになる。--version を試行し、
# 126(実行不可) / 127(未検出) のときだけ未インストール扱いにする。
# --version を持たないコマンドは別のexit code(1/2等)を返すので影響を受けない。
has() {
  command -v "$1" >/dev/null 2>&1 || return 1
  local rc
  "$1" --version >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 126 || $rc -eq 127 ]] && return 1
  return 0
}
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
    FAILED=1
    RESULTS+=("FAIL  $label")
    {
      echo "----- FAIL: $label ($*) — 末尾40行 -----"
      tail -n 40 "$log"
    } >> "$LOGDIR/failures.txt"
  fi
}

npm_script_exists() { # package.json に scripts.<name> があるか
  node -e "process.exit(require('./package.json').scripts?.['$1'] ? 0 : 1)" 2>/dev/null
}

list_files() { # list_files <glob> — 検査対象のファイルを1行1件で出力
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # --others を含めないと、まだコミットしていない新規ファイルが検査対象外になり、
    # 壊れた新規ファイルがあっても ALL PASS になる。--exclude-standard で
    # .gitignore 済み(ビルド成果物・依存ディレクトリ)は従来どおり除外する
    git ls-files --cached --others --exclude-standard "$1"
  else
    find . -name "$1" -not -path './.git/*' -not -path './node_modules/*' -not -path './.venv/*'
  fi
}

# ---------- Python ----------
if [[ -f pyproject.toml || -f setup.py || -f requirements.txt ]]; then
  STACK_FOUND=1
  run_stage lint "ruff" "python: ruff" ruff check .
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
    [[ -n "$f" ]] && PY_FILES+=("$f")
  done < <(list_files '*.py')
  if [[ ${#PY_FILES[@]} -gt 0 ]]; then
    STACK_FOUND=1
    run_stage lint "ruff" "python: ruff" ruff check "${PY_FILES[@]}"
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
  [[ -n "$f" ]] && SH_FILES+=("$f")
done < <(list_files '*.sh')
if [[ ${#SH_FILES[@]} -gt 0 ]]; then
  STACK_FOUND=1
  # shellcheck disable=SC2016  # $@ は内側の bash -c で展開させるため単一引用符が正しい
  run_stage lint "-" "shell: bash -n" \
    bash -c 'for f in "$@"; do bash -n "$f" || exit 1; done' _ "${SH_FILES[@]}"
  run_stage lint "shellcheck" "shell: shellcheck" \
    shellcheck -x -S "$SHELLCHECK_SEVERITY" "${SH_FILES[@]}"
fi

# ---------- 汎用フォールバック ----------
if [[ -f Makefile ]] && grep -qE "^check:" Makefile; then
  STACK_FOUND=1
  run_stage test "make" "make check" make check
fi

# ---------- 結果出力 ----------
echo "=== feedback-harness check ==="
if [[ $STACK_FOUND -eq 0 ]]; then
  echo "検出できたスタックがありません (pyproject.toml / package.json / go.mod / Cargo.toml / pom.xml / *.sh / Makefile:check を確認)"
  exit 0
fi
if [[ ${#RESULTS[@]} -eq 0 ]]; then
  echo "スタックは検出しましたが、実行できるステージがありません"
  exit 0
fi
printf '%s\n' "${RESULTS[@]}"

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
for r in "${RESULTS[@]}"; do
  case "$r" in
    PASS*) PASSED=$((PASSED + 1)) ;;
    SKIP*) SKIPPED=$((SKIPPED + 1)) ;;
  esac
done
if [[ $PASSED -eq 0 ]]; then
  echo "実行できたステージがありません(すべてSKIP)"
  exit 0
fi
if [[ $SKIPPED -gt 0 ]]; then
  echo "ALL PASS (${SKIPPED}件SKIP — 未検証の項目があります)"
else
  echo "ALL PASS"
fi
exit 0
