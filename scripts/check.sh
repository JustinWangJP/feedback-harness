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
harness_load_config "$ROOT"

RESULTS=()
FAILED=0
WARNED=0
SOFT_STAGE=0
STACK_FOUND=0   # マニフェストを検出したか。RESULTS の空判定とは分離する
                # (全ステージがSKIPでも「スタック未検出」とは報告しないため)
LOGDIR="$(mktemp -d)"
trap 'rm -rf "$LOGDIR"' EXIT

# 壊れた config は FAIL を立てるが、ここで止めない。設定が壊れているからと
# 他の検査まで止めると、直すべき箇所が見えなくなる(既定値のまま続行する)
if [[ -n "${HARNESS_CONFIG_ERROR:-}" ]]; then
  FAILED=1
  RESULTS+=("FAIL  config: .feedback/config.yaml")
  {
    echo "----- FAIL: config: .feedback/config.yaml -----"
    echo "$HARNESS_CONFIG_ERROR"
  } >> "$LOGDIR/failures.txt"
fi

# run_stage <stage> <id> <tool> <label> <cmd...>
# <id> は config が参照する安定した検査ID(harness_config.py の CHECKS と一致させる)。
# 表示ラベルは Node で $PM により変動するため ID には使えない。
# <tool> にコマンド名を渡すと未インストール時に SKIP を記録する(失敗扱いにしない)。
# ツール判定が不要なステージは "-" を渡す。
run_stage() {
  shift  # $1 = stage — 判定は id で行うため本体では使わない(呼び出し側の可読性のために残す)
  local id="$1" tool="$2" label="$3"; shift 3
  local sev src
  sev="$(harness_check_severity "$id" "$([[ "$SOFT_STAGE" == "1" ]] && echo warn || echo fail)")"
  if [[ "$sev" == "skip" ]]; then
    src="$(harness_check_source "$id")"
    if [[ "$src" == "既定" ]]; then
      RESULTS+=("SKIP  $label")
    elif [[ "$src" == env.* ]]; then
      RESULTS+=("SKIP  $label (${src})")
    else
      RESULTS+=("SKIP  $label (config: $src)")
    fi
    return
  fi
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
  elif [[ "$sev" == "warn" ]]; then
    WARNED=1
    RESULTS+=("WARN  $label")
    {
      echo "----- WARN: $label ($*) — 末尾${HARNESS_LOG_TAIL_LINES}行 -----"
      tail -n "$HARNESS_LOG_TAIL_LINES" "$log"
    } >> "$LOGDIR/warnings.txt"
  else
    FAILED=1
    RESULTS+=("FAIL  $label")
    {
      echo "----- FAIL: $label ($*) — 末尾${HARNESS_LOG_TAIL_LINES}行 -----"
      tail -n "$HARNESS_LOG_TAIL_LINES" "$log"
    } >> "$LOGDIR/failures.txt"
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

# harness_excluded <パス> — config の exclude に一致するか。
# glob の照合は bash の == を使う(**/ を含むパターンも extglob 無しで
# 前方一致的に効かせるため、* が / を跨ぐ bash の既定挙動をそのまま利用する)
harness_excluded() {
  local path="$1" pattern
  [[ -n "${HARNESS_EXCLUDE:-}" ]] || return 1
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    # shellcheck disable=SC2053  # 右辺は glob として評価させたいので引用しない
    [[ "$path" == $pattern ]] && return 0
  done <<< "$HARNESS_EXCLUDE"
  return 1
}

# 注意: git ls-files は「追跡済みだが作業ツリーから削除された」ファイルも列挙する。
# それらを検査ツールに渡すと読み取りエラーで完了をブロックしてしまう(実測: リンク
# 検査の [Errno 2]、bash -n の非ゼロ終了)。呼び出し側は必ず -f で実在を確認すること
list_files() { # list_files <glob> — 検査対象のファイルを1行1件で出力
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    harness_excluded "$f" || printf '%s\n' "$f"
  done < <(
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
  )
}

# ---------- Python ----------
if [[ -f pyproject.toml || -f setup.py || -f requirements.txt ]]; then
  STACK_FOUND=1
  run_stage lint "ruff" "ruff" "python: ruff" ruff check .
  # 宣言(pyproject.toml の [tool.ruff] 系)があれば FAIL、無ければ WARN。
  # 既存プロジェクトがフォーマッタ未使用の場合に完了不能にしないため
  if grep -q "^\[tool\.ruff" pyproject.toml 2>/dev/null; then
    run_stage format "ruff-format" "ruff" "python: ruff format" ruff format --check .
  else
    run_stage_soft format "ruff-format" "ruff" "python: ruff format" ruff format --check .
  fi
  if [[ -f pyproject.toml ]] && grep -q "\[tool.mypy\]" pyproject.toml 2>/dev/null; then
    run_stage typecheck "mypy" "mypy" "python: mypy" mypy .
  fi
  # カバレッジ相乗り(M3): テストを2回走らせず、計装フラグを足すだけ。
  # pytest-cov は設定の --cov-fail-under を exit code で強制するため、
  # 閾値宣言があるプロジェクトは自動的に FAIL ゲートになる
  PYTEST_ARGS=(-q -x)
  if python3 -c "import pytest_cov" >/dev/null 2>&1; then
    PYTEST_ARGS+=(--cov --cov-report=term-missing)
  fi
  if [[ -d tests ]] || compgen -G "test_*.py" >/dev/null 2>&1 \
     || compgen -G "*_test.py" >/dev/null 2>&1; then
    run_stage test "pytest" "pytest" "python: pytest" pytest "${PYTEST_ARGS[@]}"
  fi
  # 宣言に無い import・未使用依存の検出(ネットワーク不使用)。
  # 誤検出の可能性があるため、設定の宣言があるときだけ FAIL にする
  if has deptry; then
    if grep -q "^\[tool\.deptry" pyproject.toml 2>/dev/null; then
      run_stage lint "deptry" "deptry" "python: deptry" deptry .
    else
      run_stage_soft lint "deptry" "deptry" "python: deptry" deptry .
    fi
  fi

  # デッドコード。動的呼び出し・フレームワークのフックを誤検出しやすいため
  # 確信度80%以上に絞り、宣言があるときだけ FAIL にする
  if has vulture; then
    if [[ -f .vulture ]] || grep -q "^\[tool\.vulture" pyproject.toml 2>/dev/null; then
      run_stage lint "vulture" "vulture" "python: vulture" \
        vulture . --min-confidence "$HARNESS_VULTURE_MIN_CONFIDENCE"
    else
      run_stage_soft lint "vulture" "vulture" "python: vulture" \
        vulture . --min-confidence "$HARNESS_VULTURE_MIN_CONFIDENCE"
    fi
  fi

  # 層の制約(アーキテクチャ)。設定を書いた=意図的に制約を宣言したという
  # ことなので、誤検出は原理的に起きない。mypy と同じ「設定がある時だけ」パターン
  if [[ -f .importlinter ]] \
     || grep -q "^\[importlinter\]" setup.cfg 2>/dev/null \
     || grep -q "^\[tool\.importlinter" pyproject.toml 2>/dev/null; then
    if has lint-imports; then
      run_stage lint "import-linter" "-" "python: import-linter" lint-imports
    else
      RESULTS+=("SKIP  python: import-linter (import-linter 未インストール)")
    fi
  fi
else
  # マニフェストが無くても .py があれば lint はできる(check_file.sh と対称)
  PY_FILES=()
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] && PY_FILES+=("$f")
  done < <(list_files '*.py')
  if [[ ${#PY_FILES[@]} -gt 0 ]]; then
    STACK_FOUND=1
    run_stage lint "ruff" "ruff" "python: ruff" ruff check "${PY_FILES[@]}"
    # マニフェストが無い=宣言も無いので WARN 固定
    run_stage_soft format "ruff-format" "ruff" "python: ruff format" ruff format --check "${PY_FILES[@]}"
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
    npm_script_exists lint && run_stage lint "node-lint" "$PM" "node: $PM run lint" "$PM" run lint
    npm_script_exists typecheck && run_stage typecheck "node-typecheck" "$PM" "node: $PM run typecheck" "$PM" run typecheck
    if ! npm_script_exists typecheck && [[ -f tsconfig.json ]]; then
      # typescript 未導入で npx tsc を走らせると、ユーザーのコードと無関係な失敗が
      # FAIL になる(--no-install でも exit 1 のため run_stage の 126/127 判定では拾えない)。
      # --no-install を明示し、チェックが勝手にネットワークから取得しないようにする
      # typecheck が既に skip なら、未導入プローブに時間をかけない
      if [[ "$(harness_check_severity tsc fail)" == "skip" ]] \
         || npx --no-install tsc --version >/dev/null 2>&1; then
        run_stage typecheck "tsc" "-" "node: tsc --noEmit" npx --no-install tsc --noEmit
      else
        RESULTS+=("SKIP  node: tsc --noEmit (typescript 未インストール)")
      fi
    fi
    # カバレッジ相乗り(M3): test:coverage スクリプトを書いた=計装を宣言した。
    # 通常の test の「差し替え」であって追加ではない — 両方走らせると、カバレッジを
    # 測るためだけにテストスイートが2回実行される(M3 が禁じているもの)。
    # Python の --cov / Go の -cover が既存コマンドに計装を足すのと同じ扱いに揃える
    if npm_script_exists test:coverage; then
      run_stage test "node-test-coverage" "$PM" "node: $PM run test:coverage" "$PM" run test:coverage
    elif npm_script_exists test; then
      run_stage test "node-test" "$PM" "node: $PM test" "$PM" test
    fi
    npm_script_exists build && run_stage build "node-build" "$PM" "node: $PM run build" "$PM" run build
    # 依存の実在性・整合性(ネットワーク不使用)。宣言と実体のずれ・欠損を
    # 検出する — AIが存在しないパッケージ名を書く欠陥はここで捕まる。
    # node_modules が無いのは「未インストール」であって欠陥ではないので SKIP。
    # さらに `ls --all` は npm 固有の構文で、pnpm には --all が無く Yarn Berry には
    # ls 自体が無い。他PMで走らせると健全なプロジェクトが usage error で FAIL する
    # ため、npm のときだけ実行する
    if [[ ! -d node_modules ]]; then
      RESULTS+=("SKIP  node: npm ls (node_modules 未インストール)")
    elif [[ "$PM" != "npm" ]]; then
      RESULTS+=("SKIP  node: npm ls ($PM は ls --all 非対応)")
    else
      run_stage lint "npm-ls" "npm" "node: npm ls" npm ls --all
    fi

    # フォーマット。設定が無い prettier は既定スタイルの押し付けになるため
    # 走らせない(WARN でもノイズになる)。
    # 設定ファイル名は prettier が探索する主要な形を網羅する(.prettierrc / .prettierrc.*
    # / prettier.config.*)。ls のグロブで一括判定し、列挙漏れを避ける
    if [[ -f .prettierrc ]] || compgen -G ".prettierrc.*" >/dev/null 2>&1 \
       || compgen -G "prettier.config.*" >/dev/null 2>&1 \
       || node -e "process.exit(require('./package.json').prettier ? 0 : 1)" 2>/dev/null; then
      if npx --no-install prettier --version >/dev/null 2>&1; then
        run_stage format "prettier" "-" "node: prettier" npx --no-install prettier --check .
      else
        RESULTS+=("SKIP  node: prettier (prettier 未インストール)")
      fi
    fi

    # デッドコード。設定なしの knip はエントリポイント推定を誤り、実測では
    # 検査ツールとして入れた devDependencies まで「未使用」と報告する。
    # 設定を書いた=対象を宣言した、というときだけ走らせる
    # ls は複数引数の1つでも欠けると全体が非0になるため、パターンごとに compgen で判定する
    if [[ -f knip.json || -f knip.jsonc ]] || compgen -G "knip.config.*" >/dev/null 2>&1 \
       || node -e "process.exit(require('./package.json').knip ? 0 : 1)" 2>/dev/null; then
      if npx --no-install knip --version >/dev/null 2>&1; then
        run_stage lint "knip" "-" "node: knip" npx --no-install knip
      else
        RESULTS+=("SKIP  node: knip (knip 未インストール)")
      fi
    fi
  fi
fi

# ---------- Go ----------
if [[ -f go.mod ]]; then
  STACK_FOUND=1
  run_stage lint "go-vet" "go" "go: vet" go vet ./...
  run_stage build "go-build" "go" "go: build" go build ./...
  # -cover は標準機能で計装のみ(追加プロセス無し)。coverage の数値は
  # ステージログに現れる。閾値ゲートは持たない(go test のexitはテスト合否のみ)
  run_stage test "go-test" "go" "go: test" go test -cover ./...
  # go.sum のチェックサム検証(ネットワーク不使用)。依存の改竄・欠損を検出する
  if [[ -f go.sum ]]; then
    run_stage lint "go-mod-verify" "go" "go: mod verify" go mod verify
  fi

  # gofmt は言語標準であり「宣言しないと従わない」性質のものではないため、
  # 宣言ゲートを設けず常に FAIL とする(Goコミュニティの普遍的合意)
  GO_FILES=()
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] && GO_FILES+=("$f")
  done < <(list_files '*.go')
  if [[ ${#GO_FILES[@]} -gt 0 ]] && has gofmt; then
    # gofmt -l は未整形ファイル名を「出力する」形式で、終了コードは 0 のまま。
    # 出力があれば未整形なので、非0に変換して run_stage に伝える
    run_stage format "gofmt" "-" "go: gofmt" \
      bash -c 'out="$(gofmt -l "$@")"; [[ -z "$out" ]] || { echo "未フォーマット:"; echo "$out"; exit 1; }' _ "${GO_FILES[@]}"
  fi
fi

# ---------- Rust ----------
if [[ -f Cargo.toml ]]; then
  STACK_FOUND=1
  if ! has cargo; then
    RESULTS+=("SKIP  rust: 全ステージ (cargo 未インストール)")
  else
    if cargo clippy --version >/dev/null 2>&1; then
      run_stage lint "clippy" "-" "rust: clippy" cargo clippy --quiet -- -D warnings
    else
      run_stage build "cargo-check" "-" "rust: check" cargo check --quiet
    fi
    run_stage test "cargo-test" "-" "rust: test" cargo test --quiet
    # Cargo.lock と実体の整合(--offline でネットワークを使わない)
    if [[ -f Cargo.lock ]]; then
      run_stage lint "cargo-metadata" "-" "rust: metadata" \
        cargo metadata --offline --format-version 1
    fi

    # rustfmt.toml があれば FAIL、無ければ WARN(既定スタイルの押し付けを避ける)
    if [[ -f rustfmt.toml || -f .rustfmt.toml ]]; then
      run_stage format "cargo-fmt" "-" "rust: cargo fmt" cargo fmt --check
    else
      run_stage_soft format "cargo-fmt" "-" "rust: cargo fmt" cargo fmt --check
    fi
  fi
fi

# ---------- Java ----------
if [[ -f pom.xml ]]; then
  STACK_FOUND=1
  run_stage test "mvn" "mvn" "java: mvn verify" mvn -q verify
elif [[ -f build.gradle || -f build.gradle.kts ]]; then
  STACK_FOUND=1
  if [[ -x ./gradlew ]]; then
    run_stage test "gradle" "-" "java: gradlew check" ./gradlew -q check
  else
    run_stage test "gradle" "gradle" "java: gradle check" gradle -q check
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
  run_stage lint "bash-syntax" "-" "shell: bash -n" \
    bash -c 'for f in "$@"; do bash -n "$f" || exit 1; done' _ "${SH_FILES[@]}"
  run_stage lint "shellcheck" "shellcheck" "shell: shellcheck" \
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
  run_stage lint "json-syntax" "-" "config: json 構文" harness_validate_json "${JSON_FILES[@]}"
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
    run_stage lint "yaml-syntax" "-" "config: yaml 構文" harness_validate_yaml "${YAML_FILES[@]}"
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
  run_stage docs "md-links" "-" "docs: 内部リンク" harness_check_md_links "${MD_FILES[@]}"
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
    run_stage security "secretlint" "-" "security: secretlint" npx --no-install secretlint "**/*"
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
    run_stage security "gitleaks" "-" "security: gitleaks" \
      gitleaks detect --no-git --redact --no-banner -s .
  else
    RESULTS+=("SKIP  security: gitleaks (この版は detect --no-git/--redact に非対応)")
  fi
fi

# GitHub Actions のワークフロー。YAML構文は上で検証済みなので、ここで見るのは
# アクションの使い方(存在しない入力・シェルの誤り等)。actionlint は Go 製
# バイナリのため任意扱い(あれば使う)
if compgen -G ".github/workflows/*.y*ml" >/dev/null 2>&1; then
  if has actionlint; then
    run_stage lint "actionlint" "-" "ci: actionlint" actionlint
  else
    RESULTS+=("SKIP  ci: actionlint (actionlint 未インストール)")
  fi
fi

# Dockerfile。git pathspec の * は / を跨ぐため 'Dockerfile*' 単独では
# ルート直下しか当たらない(*.py が全階層に当たるのとは非対称)
DOCKER_FILES=()
while IFS= read -r f; do
  [[ -n "$f" && -f "$f" ]] && DOCKER_FILES+=("$f")
done < <(list_files 'Dockerfile*'; list_files '*/Dockerfile*')
# 上の2つのグロブは Dockerfile がリポジトリ直下にある場合に重複しない
# (git pathspec の 'Dockerfile*' はルート直下のみ、'*/Dockerfile*' は1階層以上)。
# 念のため防御的な重複排除を入れる(現状の経路では重複は生じない)
if [[ ${#DOCKER_FILES[@]} -gt 1 ]]; then
  IFS=$'\n' read -r -d '' -a DOCKER_FILES < <(printf '%s\n' "${DOCKER_FILES[@]}" | sort -u && printf '\0')
fi
if [[ ${#DOCKER_FILES[@]} -gt 0 ]]; then
  if has npx && npx --no-install dockerfilelint --version >/dev/null 2>&1; then
    # dockerfilelint は問題があると exit 2 を返す(実測)。run_stage は非0を
    # FAIL とするため、そのまま扱える
    run_stage lint "dockerfilelint" "-" "docker: dockerfilelint" \
      npx --no-install dockerfilelint "${DOCKER_FILES[@]}"
  elif has hadolint; then
    run_stage lint "hadolint" "-" "docker: hadolint" hadolint "${DOCKER_FILES[@]}"
  else
    RESULTS+=("SKIP  docker: lint (dockerfilelint / hadolint 未インストール)")
  fi
fi

# ---------- API契約・破壊的変更 ----------
# ベースラインは git から取る(ネットワーク不要・自己完結)。merge-base が
# 解決できなければ HEAD(=未コミット変更のみ)と比較する。spec ファイルの
# 検出は for+[[ -f ]] で行う(ls の複数引数は1つでも欠けると全体が非0になる)
OPENAPI_SPEC=""
for f in openapi.yaml openapi.json api/openapi.yaml api/openapi.json; do
  if [[ -f "$f" ]]; then
    OPENAPI_SPEC="$f"
    break
  fi
done
if [[ -n "$OPENAPI_SPEC" ]] && has oasdiff; then
  BASE_SHA="$(git merge-base HEAD "$HARNESS_OASDIFF_BASE" 2>/dev/null \
    || git rev-parse HEAD 2>/dev/null)"
  TMP_BASE="$(mktemp)"
  if [[ -n "$BASE_SHA" ]] && git show "$BASE_SHA:$OPENAPI_SPEC" > "$TMP_BASE" 2>/dev/null; then
    run_stage contract "oasdiff" "-" "contract: oasdiff" oasdiff breaking "$TMP_BASE" "$OPENAPI_SPEC"
  else
    RESULTS+=("SKIP  contract: oasdiff (ベースライン取得不能 — $OPENAPI_SPEC がベースラインに無い)")
  fi
  rm -f "$TMP_BASE"
elif [[ -n "$OPENAPI_SPEC" ]]; then
  RESULTS+=("SKIP  contract: oasdiff (oasdiff 未インストール)")
fi

# Rust ライブラリの破壊的変更。cargo-semver-checks の導入自体が宣言
# (ビルドを伴い重いため、入れたプロジェクトだけがコストを払う)
if [[ -f Cargo.toml ]] && has cargo \
   && cargo semver-checks --version >/dev/null 2>&1 \
   && grep -q "^\[lib\]" Cargo.toml; then
  run_stage contract "cargo-semver-checks" "-" "contract: cargo semver-checks" cargo semver-checks check-release
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
    run_stage test "make-check" "make" "make check" env FEEDBACK_CHECK_RECURSION_GUARD=1 make check
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
