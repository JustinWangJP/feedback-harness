#!/usr/bin/env bash
# test_oss_baseline.sh — OSS公開条件とnetwork保証境界の文書契約を固定する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

assert_file_exists "$REPO/LICENSE" "MIT Licenseが存在する"
assert_contains "$(cat "$REPO/LICENSE")" "MIT License" "ライセンス本文がMITである"
assert_contains "$(cat "$REPO/LICENSE")" "Copyright (c) 2026 JustinWangJP" "著作権表示がある"
assert_eq "MIT" \
  "$(python3 -c "import json; print(json.load(open('$REPO/package.json'))['license'])")" \
  "package metadataのlicenseがMITである"
assert_eq "MIT" \
  "$(python3 -c "import json; print(json.load(open('$REPO/package-lock.json'))['packages']['']['license'])")" \
  "lockfileのroot package metadataもMITである"

CI="$REPO/.github/workflows/ci.yml"
assert_file_exists "$CI" "Linux CI workflowが存在する"
CI_BODY="$(cat "$CI")"
assert_contains "$CI_BODY" "runs-on: ubuntu-latest" "Linux runnerを必須にする"
assert_not_contains "$CI_BODY" "macos-" "macOS runnerを必須にしない"
assert_not_contains "$CI_BODY" "windows-" "Windows runnerを必須にしない"
assert_contains "$CI_BODY" "bash tests/run_tests.sh" "回帰テストをCIで実行する"
assert_contains "$CI_BODY" "bash scripts/check.sh" "ハーネス自身をCIで検査する"
assert_contains "$CI_BODY" "scripts/checks/*.sh" "抽出したstack runnerもCIで構文検査する"
assert_contains "$CI_BODY" "actions/setup-go@v5" "actionlint導入用のGoをCIでセットアップする"
assert_contains "$CI_BODY" "make install-dev-tools" \
  "PyYAMLとactionlintを共通ターゲットからCIへ導入する"
assert_contains "$CI_BODY" '.venv/bin" >> "$GITHUB_PATH"' \
  "CIがリポジトリ内の開発ツールを後続ステップで検出する"
assert_contains "$CI_BODY" "ruff --version" \
  "CIがruffを検査前に実行可能と確認する"
assert_contains "$CI_BODY" "actionlint --version" \
  "CIがactionlintを検査前に実行可能と確認する"

assert_file_exists "$REPO/requirements-dev.txt" "Python開発依存の宣言が存在する"
assert_contains "$(cat "$REPO/requirements-dev.txt")" "PyYAML==6.0.3" \
  "PyYAMLの開発バージョンを固定する"
assert_contains "$(cat "$REPO/requirements-dev.txt")" "ruff==0.16.1" \
  "ruffの開発バージョンを固定する"
assert_file_exists "$REPO/scripts/dev_tool_versions.sh" "外部開発ツールのバージョン宣言が存在する"
# shellcheck source=../scripts/dev_tool_versions.sh
. "$REPO/scripts/dev_tool_versions.sh"
assert_eq "v1.7.12" "$ACTIONLINT_VERSION" "actionlintの開発バージョンを固定する"

MAKEFILE_BODY="$(cat "$REPO/Makefile")"
assert_contains "$MAKEFILE_BODY" "install-dev-tools:" "開発依存の明示的な導入ターゲットがある"
assert_contains "$MAKEFILE_BODY" "pip install --requirement requirements-dev.txt" \
  "導入ターゲットが固定されたPyYAML依存を使う"
assert_contains "$MAKEFILE_BODY" '. scripts/dev_tool_versions.sh' \
  "導入ターゲットがactionlintの共通バージョン宣言を読む"
assert_contains "$MAKEFILE_BODY" 'actionlint/cmd/actionlint@$${ACTIONLINT_VERSION}' \
  "導入ターゲットが固定されたactionlintを使う"

assert_contains "$(cat "$REPO/README.md")" "Project-defined commands and tools may still use the network" \
  "英語READMEがproject-defined commandの通信可能性を明記する"
assert_contains "$(cat "$REPO/README.ja.md")" "プロジェクト定義のコマンドや外部ツールは設定に応じて通信する場合がある" \
  "日本語READMEがproject-defined commandの通信可能性を明記する"
assert_contains "$(cat "$REPO/README.zh-CN.md")" "项目定义的命令和外部工具仍可能根据自身配置访问网络" \
  "中国語READMEがproject-defined commandの通信可能性を明記する"

for f in "$REPO/README.md" "$REPO/README.ja.md" "$REPO/README.zh-CN.md"; do
  assert_contains "$(cat "$f")" "MIT License" "$(basename "$f")がMIT Licenseへ案内する"
  assert_contains "$(cat "$f")" "requirements-dev.txt" \
    "$(basename "$f")がリポジトリ開発依存の導入方法を説明する"
  assert_contains "$(cat "$f")" "Ruff" \
    "$(basename "$f")がruffをリポジトリ開発依存として説明する"
  assert_contains "$(cat "$f")" "scripts/dev_tool_versions.sh" \
    "$(basename "$f")がactionlintの共通バージョン宣言を参照する"
done

assert_summary
