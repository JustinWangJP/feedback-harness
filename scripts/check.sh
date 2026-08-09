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

ROOT="${1:-.}"
cd "$ROOT" || { echo "ERROR: ディレクトリが見つかりません: $ROOT"; exit 2; }

SKIP="${FEEDBACK_CHECK_SKIP:-}"
RESULTS=()
FAILED=0
LOGDIR="$(mktemp -d)"
trap 'rm -rf "$LOGDIR"' EXIT

has() { command -v "$1" >/dev/null 2>&1; }
skipped() { [[ " $SKIP " == *" $1 "* ]]; }

run_stage() { # run_stage <stage> <label> <cmd...>
  local stage="$1" label="$2"; shift 2
  skipped "$stage" && { RESULTS+=("SKIP  $label (FEEDBACK_CHECK_SKIP)"); return; }
  local log="$LOGDIR/${label//[^a-zA-Z0-9]/_}.log"
  if "$@" >"$log" 2>&1; then
    RESULTS+=("PASS  $label")
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

# ---------- Python ----------
if [[ -f pyproject.toml || -f setup.py || -f requirements.txt ]]; then
  has ruff   && run_stage lint "python: ruff"    ruff check .
  has mypy && [[ -f pyproject.toml ]] && grep -q "\[tool.mypy\]" pyproject.toml 2>/dev/null \
             && run_stage typecheck "python: mypy" mypy .
  if has pytest && { [[ -d tests ]] || ls test_*.py *_test.py >/dev/null 2>&1; }; then
    run_stage test "python: pytest" pytest -q -x
  fi
fi

# ---------- Node / TypeScript ----------
if [[ -f package.json ]]; then
  PM="npm"; [[ -f pnpm-lock.yaml ]] && PM="pnpm"; [[ -f yarn.lock ]] && PM="yarn"
  npm_script_exists lint      && run_stage lint      "node: $PM run lint"      "$PM" run lint
  npm_script_exists typecheck && run_stage typecheck "node: $PM run typecheck" "$PM" run typecheck
  if ! npm_script_exists typecheck && [[ -f tsconfig.json ]] && has npx; then
    run_stage typecheck "node: tsc --noEmit" npx tsc --noEmit
  fi
  npm_script_exists test  && run_stage test  "node: $PM test"      "$PM" test
  npm_script_exists build && run_stage build "node: $PM run build" "$PM" run build
fi

# ---------- Go ----------
if [[ -f go.mod ]] && has go; then
  run_stage lint  "go: vet"   go vet ./...
  run_stage build "go: build" go build ./...
  run_stage test  "go: test"  go test ./...
fi

# ---------- Rust ----------
if [[ -f Cargo.toml ]] && has cargo; then
  if cargo clippy --version >/dev/null 2>&1; then
    run_stage lint "rust: clippy" cargo clippy --quiet -- -D warnings
  else
    run_stage build "rust: check" cargo check --quiet
  fi
  run_stage test "rust: test" cargo test --quiet
fi

# ---------- Java ----------
if [[ -f pom.xml ]] && has mvn; then
  run_stage test "java: mvn verify" mvn -q verify
elif [[ -f build.gradle || -f build.gradle.kts ]]; then
  GRADLE="./gradlew"; [[ -x $GRADLE ]] || GRADLE="gradle"
  has "${GRADLE##*/}" || [[ -x ./gradlew ]] && run_stage test "java: gradle check" "$GRADLE" -q check
fi

# ---------- 汎用フォールバック ----------
[[ -f Makefile ]] && grep -qE "^check:" Makefile && run_stage test "make check" make check

# ---------- 結果出力 ----------
echo "=== feedback-harness check ==="
if [[ ${#RESULTS[@]} -eq 0 ]]; then
  echo "検出できたスタックがありません (pyproject.toml / package.json / go.mod / Cargo.toml / pom.xml / Makefile:check を確認)"
  exit 0
fi
printf '%s\n' "${RESULTS[@]}"

if [[ $FAILED -eq 1 ]]; then
  echo
  echo "以下の失敗を修正してから完了とすること:"
  cat "$LOGDIR/failures.txt"
  exit 1
fi
echo "ALL PASS"
exit 0
