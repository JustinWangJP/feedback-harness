#!/usr/bin/env bash
# Node / TypeScript stack runner. 共通coreはcheck.shから受け取る。

# shellcheck disable=SC2034 # source元のcheck.shがSTACK_FOUND等を集計する
run_node_checks() {
  if [[ -f package.json ]]; then
    STACK_FOUND=1
    PM="$(harness_node_pm)"
    if ! has node; then
      # npm_script_exists が node に依存するため、node 不在では全ステージを判定できない。
      # --list-checks では対象IDごとに記録する(通常実行は1行にまとめたまま)
      if [[ "$LIST_MODE" == "1" ]]; then
        for _id_stage in node-lint:lint node-typecheck:typecheck tsc:typecheck \
                         node-test-coverage:test node-test:test node-build:build \
                         npm-ls:lint prettier:format knip:lint; do
          record_skip "${_id_stage%%:*}" "${_id_stage##*:}" "node: 全ステージ" "node 未インストール"
        done
      else
        RESULTS+=("SKIP  node: 全ステージ (node 未インストール)")
      fi
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
          record_skip "tsc" typecheck "node: tsc --noEmit" "typescript 未インストール"
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
        record_skip "npm-ls" lint "node: npm ls" "node_modules 未インストール"
      elif [[ "$PM" != "npm" ]]; then
        record_skip "npm-ls" lint "node: npm ls" "$PM は ls --all 非対応"
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
          record_skip "prettier" format "node: prettier" "prettier 未インストール"
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
          record_skip "knip" lint "node: knip" "knip 未インストール"
        fi
      fi
    fi
  fi
  
}
