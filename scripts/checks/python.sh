#!/usr/bin/env bash
# Python stack runner. check.sh の共通 core(run_stage / list_files 等)を利用する。

# shellcheck disable=SC2034 # source元のcheck.shがSTACK_FOUNDを集計する
run_python_checks() {
  local f
  local -a PYTEST_ARGS PY_FILES

  if [[ -f pyproject.toml || -f setup.py || -f requirements.txt ]]; then
    STACK_FOUND=1
    run_stage lint "ruff" "ruff" "python: ruff" ruff check .
    # 宣言(pyproject.toml の [tool.ruff] 系)があれば FAIL、無ければ WARN。
    # 既存プロジェクトがフォーマッタ未使用の場合に完了不能にしないため
    if grep -q "^[[:space:]]*\[tool\.ruff" pyproject.toml 2>/dev/null; then
      run_stage format "ruff-format" "ruff" "python: ruff format" ruff format --check .
    else
      run_stage_soft format "ruff-format" "ruff" "python: ruff format" ruff format --check .
    fi
    # 宣言の検出は行頭アンカー + ドットのエスケープで行う(他の宣言ゲートと同形式)。
    # `\[tool.mypy\]` のように緩めると、[project] の description など**宣言では
    # ない位置**にその文字列があるだけで検出が成立する。mypy には他と違って
    # WARN フォールバック(run_stage_soft)が無く、誤検出がそのまま完了ブロックの
    # FAIL になる(2026-09-02 の全体レビュー由来)
    # mypy の直後も区切りに限定する。前方一致では [tool.mypy_extra] 等の
    # 別テーブルで型検査を有効にしてしまう。空白を挟んだ区切りも TOML では有効。
    if [[ -f pyproject.toml ]] && grep -qE "^[[:space:]]*\[tool\.mypy[[:space:]]*(\]|\.)" pyproject.toml 2>/dev/null; then
      run_stage typecheck "mypy" "mypy" "python: mypy" mypy .
    fi
    # カバレッジ相乗り(M3): テストを2回走らせず、計装フラグを足すだけ。
    # pytest-cov は設定の --cov-fail-under を exit code で強制するため、
    # 閾値宣言があるプロジェクトは自動的に FAIL ゲートになる
    PYTEST_ARGS=(-q -x)
    if harness_python -c "import pytest_cov" >/dev/null 2>&1; then
      PYTEST_ARGS+=(--cov --cov-report=term-missing)
    fi
    if [[ -d tests ]] || compgen -G "test_*.py" >/dev/null 2>&1 \
       || compgen -G "*_test.py" >/dev/null 2>&1; then
      run_stage test "pytest" "pytest" "python: pytest" pytest "${PYTEST_ARGS[@]}"
    fi
    # 宣言に無い import・未使用依存の検出(ネットワーク不使用)。
    # 誤検出の可能性があるため、設定の宣言があるときだけ FAIL にする
    if has deptry; then
      if grep -q "^[[:space:]]*\[tool\.deptry" pyproject.toml 2>/dev/null; then
        run_stage lint "deptry" "deptry" "python: deptry" deptry .
      else
        run_stage_soft lint "deptry" "deptry" "python: deptry" deptry .
      fi
    fi

    # デッドコード。動的呼び出し・フレームワークのフックを誤検出しやすいため
    # 確信度80%以上に絞り、宣言があるときだけ FAIL にする
    if has vulture; then
      if [[ -f .vulture ]] || grep -q "^[[:space:]]*\[tool\.vulture" pyproject.toml 2>/dev/null; then
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
       || grep -q "^[[:space:]]*\[importlinter\]" setup.cfg 2>/dev/null \
       || grep -q "^[[:space:]]*\[tool\.importlinter" pyproject.toml 2>/dev/null; then
      if has lint-imports; then
        run_stage lint "import-linter" "-" "python: import-linter" lint-imports
      else
        record_skip "import-linter" lint "python: import-linter" "import-linter 未インストール"
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
}
