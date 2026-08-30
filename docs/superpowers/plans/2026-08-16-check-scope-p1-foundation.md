# 適用範囲拡張 P1(基盤と既存欠陥)Implementation Plan

> **履歴資料:** この計画は実施済みです。チェックボックスは実施当時の作業単位をそのまま保存したもので、未チェックのままでも未着手を意味しません。**この文書に従って作業しないこと。** 現在の検査内容は[プロジェクト概要](../../../README.md)と[スクリプト仕様](../../../scripts/README.md)を参照してください。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 設定ファイル構文検証の既存欠陥(D1〜D3)を解消し、以降の全検査が乗る土台として **WARN 結果クラス**とその測定連携を作る。

**Architecture:** JSON/YAML 検証ロジックを `lib.sh` の共有関数へ集約して `check_file.sh` と `check.sh` のドリフトを防ぐ(既存の `has()` の教訓)。`check.sh` に非ブロッキングの WARN を追加し、`run_stage_soft` で「宣言していない検査」を報告のみに落とす。WARN は `events.jsonl` へ記録され `stats`/`report` に「頻出WARN」として現れることで、握り潰しではなくフィードバックループの信号になる。

**Tech Stack:** Bash(`set -u`、lib.sh 共有関数)、Python 3 標準ライブラリ + PyYAML(任意)。新規依存の追加なし。

**Spec:** [docs/superpowers/specs/2026-08-16-check-scope-expansion-design.md](../specs/2026-08-16-check-scope-expansion-design.md)

## Global Constraints

- **P-A(非交渉)**: ハーネスは決してツールを自動インストールしない。未導入は SKIP と理由表示に留める
- **P-B**: OS依存の導入手段を前提にしない。P1 で追加する検査は**追加インストール不要**(python3 / PyYAML / 既存の ruff のみ)
- 新規依存パッケージ禁止(bash / python3 標準ライブラリ + 任意の PyYAML)
- ツール未導入・環境の問題を**ユーザーのコードの失敗として報告しない**(既存原則)。python3 不在・PyYAML 不在は検証せず成功扱い
- WARN は **exit code を 0 のまま**にする。exit 1 は FAIL のみ
- テストは `tests/test_*.sh` + `tests/assert.sh` 規約。期待値はリテラルで書き、判定は自前カウンタ + `assert_summary` の明示 exit(**検証対象の機構をそのテスト自身の合否判定に使わない**)
- 外部ツールはテストで PATH に偽実行ファイルを置いて駆動する(`tests/test_on_stop_skip.sh` が確立した手法)
- コメントは「なぜ」を書く。コミットメッセージは日本語 conventional commits(`feat:` / `fix:` / `docs:`)
- 未関係の未コミット削除(`docs/superpowers/plans/2026-08-12-plugin-packaging.md` 等)を**コミットに含めない** — 各タスクのコミット手順に列挙したファイルだけを `git add` する

## ファイル構成

| ファイル | 責務 | 変更 |
|---|---|---|
| `scripts/lib.sh` | 両チェッカが共有する判定ロジック | 構文検証3関数を追加 |
| `scripts/check_file.sh` | 単一ファイルの高速チェック | JSON/YAML 分岐を共有関数へ置換 |
| `scripts/check.sh` | フルチェックと結果集計 | 横断チェック節・WARN 結果クラス・format ステージ |
| `scripts/hooks/on_stop.sh` | Stop フックの薄いラッパ | WARN 行を events.jsonl へ記録 |
| `scripts/feedback_log.py` | 記録・集計CLI | stats/report に頻出WARN、stop 通過率の汚染修正 |

---

### Task 1: 構文検証の共有関数(D2・D3 の修正)

**Files:**
- Modify: `scripts/lib.sh`(末尾に追加)
- Test: `tests/test_config_syntax.sh`(新規)

**Interfaces:**
- Consumes: 既存の `has()`(lib.sh 内)
- Produces: `harness_is_jsonc <path>`(JSONC慣例ファイルなら0)、`harness_has_pyyaml`(PyYAML が使えるなら0)、`harness_validate_json <file...>`、`harness_validate_yaml <file...>`(いずれも問題があれば `path: 理由` を stdout に出し非0)。Task 2 と Task 3 がこれらを呼ぶ

- [ ] **Step 1: 失敗テストを書く**

`tests/test_config_syntax.sh` を作成:

```bash
#!/usr/bin/env bash
# test_config_syntax.sh — JSON/YAML 構文検証の共有関数を検証する。
#
# 誤検出は「正当なファイルで完了がブロックされる」形の最悪の壊れ方になるため、
# 検出できること以上に「誤検出しないこと」を固定する:
# - コメント付きJSON(tsconfig.json 等は JSONC が慣例)
# - 複数文書YAML(--- 区切り)
# - カスタムタグYAML(CloudFormation の !Ref 等)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
. "$REPO/scripts/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/.vscode"

ok() { # ok <関数> <ファイル> <ラベル> — 検証が成功(exit 0)することを期待
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  local out
  if ! out="$("$1" "$2" 2>&1)"; then
    fail "$3: 誤検出した (出力: $out)"
  fi
}
ng() { # ng <関数> <ファイル> <ラベル> — 検証が失敗(非0)することを期待
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  if "$1" "$2" >/dev/null 2>&1; then
    fail "$3: 壊れているのに検出されなかった"
  fi
}

# --- JSON ---
printf '{"a": 1}\n' > "$WORK/good.json"
printf '{"a": 1,\n' > "$WORK/broken.json"
ok harness_validate_json "$WORK/good.json" "正当なJSONを通す"
ng harness_validate_json "$WORK/broken.json" "壊れたJSONを検出する"

# JSONC 慣例のファイルは検証対象外(標準パーサでは原理的に検証できない)
printf '{\n  // コメント\n  "a": 1\n}\n' > "$WORK/tsconfig.json"
printf '{\n  // コメント\n  "a": 1\n}\n' > "$WORK/.vscode/settings.json"
printf '{\n  // コメント\n  "a": 1\n}\n' > "$WORK/devcontainer.json"
ok harness_validate_json "$WORK/tsconfig.json" "tsconfig.json のコメントで誤検出しない"
ok harness_validate_json "$WORK/.vscode/settings.json" ".vscode配下のコメントで誤検出しない"
ok harness_validate_json "$WORK/devcontainer.json" "devcontainer.json のコメントで誤検出しない"

ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
harness_is_jsonc "$WORK/tsconfig.json" || fail "harness_is_jsonc が tsconfig.json を判定できない"
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
if harness_is_jsonc "$WORK/good.json"; then fail "harness_is_jsonc が通常のJSONを誤判定した"; fi

# 複数ファイル一括: 1件でも壊れていれば非0
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
if harness_validate_json "$WORK/good.json" "$WORK/broken.json" >/dev/null 2>&1; then
  fail "複数ファイル指定で壊れたJSONを見逃した"
fi

# --- YAML(PyYAML がある環境でのみ実質検証される) ---
if harness_has_pyyaml; then
  printf 'a: 1\n' > "$WORK/good.yaml"
  printf 'a: [1, 2\n' > "$WORK/broken.yaml"
  printf -- '---\na: 1\n---\nb: 2\n' > "$WORK/multi.yaml"
  printf 'Resources:\n  X:\n    Value: !Ref Other\n' > "$WORK/customtag.yaml"
  ok harness_validate_yaml "$WORK/good.yaml" "正当なYAMLを通す"
  ng harness_validate_yaml "$WORK/broken.yaml" "壊れたYAMLを検出する"
  ok harness_validate_yaml "$WORK/multi.yaml" "複数文書YAMLで誤検出しない"
  ok harness_validate_yaml "$WORK/customtag.yaml" "カスタムタグYAMLで誤検出しない"
else
  # PyYAML が無い環境では検証せず成功する(環境の問題をコードの失敗として報告しない)
  printf 'a: [1, 2\n' > "$WORK/broken.yaml"
  ok harness_validate_yaml "$WORK/broken.yaml" "PyYAML不在なら検証せず成功する"
fi

assert_summary
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_config_syntax.sh`
Expected: FAIL — `harness_validate_json: command not found` により全チェックが失敗する

- [ ] **Step 3: `scripts/lib.sh` の末尾に実装を追加**

```bash
# harness_is_jsonc <path> — コメント付きJSON(JSONC)が慣例のファイルか。
#
# tsconfig.json 等はコメント付きで配布されるのが通例で、標準の JSON パーサでは
# 原理的に検証できない。検証対象に含めると正当なファイルで完了をブロックする。
harness_is_jsonc() {
  local base
  base="$(basename "$1")"
  case "$base" in
    tsconfig*.json|jsconfig*.json|devcontainer.json) return 0 ;;
  esac
  case "$1" in
    */.vscode/*) return 0 ;;
  esac
  return 1
}

# harness_has_pyyaml — YAML 検証が可能か。
# PyYAML は標準ライブラリではない。未導入を「ファイルの問題」として報告しない。
harness_has_pyyaml() {
  has python3 && python3 -c "import yaml" >/dev/null 2>&1
}

# harness_validate_json <file...> — JSON 構文を検証する。
# 壊れていれば "path: 理由" を出力して非0。python3 不在時は検証せず成功。
harness_validate_json() {
  has python3 || return 0
  local targets=()
  local f
  for f in "$@"; do
    harness_is_jsonc "$f" || targets+=("$f")
  done
  [[ ${#targets[@]} -eq 0 ]] && return 0
  python3 -c '
import json, sys
bad = 0
for p in sys.argv[1:]:
    try:
        with open(p, encoding="utf-8") as fh:
            json.load(fh)
    except Exception as e:
        print(f"{p}: {e}")
        bad = 1
sys.exit(bad)
' "${targets[@]}"
}

# harness_validate_yaml <file...> — YAML 構文を検証する。
# 壊れていれば "path: 理由" を出力して非0。PyYAML 不在時は検証せず成功。
harness_validate_yaml() {
  harness_has_pyyaml || return 0
  [[ $# -eq 0 ]] && return 0
  python3 -c '
import sys, yaml
bad = 0
for p in sys.argv[1:]:
    try:
        with open(p, encoding="utf-8") as fh:
            # safe_load は単一文書しか読まない。--- 区切りの複数文書(k8sマニフェスト等)を
            # 構文エラーとして誤検出しないため safe_load_all を使う
            list(yaml.safe_load_all(fh))
    except yaml.constructor.ConstructorError:
        # 未知のカスタムタグ(CloudFormation の !Ref 等)は構文エラーではない。
        # ここで検証したいのは構文であってスキーマではない
        pass
    except Exception as e:
        print(f"{p}: {e}")
        bad = 1
sys.exit(bad)
' "$@"
}
```

- [ ] **Step 4: テストを実行して通ることを確認**

Run: `bash tests/test_config_syntax.sh`
Expected: PASS(exit 0・無出力)

- [ ] **Step 5: 既存テストの回帰確認**

Run: `bash tests/run_tests.sh`
Expected: 全 PASS(lib.sh への追加のみで既存の呼び出しに影響しない)

- [ ] **Step 6: コミット**

```bash
git add scripts/lib.sh tests/test_config_syntax.sh
git commit -m "feat: JSON/YAML構文検証を共有関数化しJSONC・複数文書YAMLの誤検出を解消"
```

---

### Task 2: `check_file.sh` を共有関数へ置換

**Files:**
- Modify: `scripts/check_file.sh:54-63`
- Test: `tests/test_config_syntax.sh`(Task 1 で作成したファイルに追記)

**Interfaces:**
- Consumes: Task 1 の `harness_validate_json` / `harness_validate_yaml`
- Produces: なし(外形的な振る舞いは不変 — 問題があれば出力して exit 1、なければ無出力で exit 0)

- [ ] **Step 1: 失敗テストを追記**

`tests/test_config_syntax.sh` の `assert_summary` の直前に追加:

```bash
# --- check_file.sh 経由でも同じ判定になる(共有関数を使っているか) ---
CF="$REPO/scripts/check_file.sh"
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
if bash "$CF" "$WORK/broken.json" >/dev/null 2>&1; then
  fail "check_file.sh が壊れたJSONを検出しない"
fi
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
if ! bash "$CF" "$WORK/tsconfig.json" >/dev/null 2>&1; then
  fail "check_file.sh が tsconfig.json のコメントで誤ブロックする(D2の回帰)"
fi
if harness_has_pyyaml; then
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  if ! bash "$CF" "$WORK/multi.yaml" >/dev/null 2>&1; then
    fail "check_file.sh が複数文書YAMLで誤ブロックする(D3の回帰)"
  fi
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  if ! bash "$CF" "$WORK/customtag.yaml" >/dev/null 2>&1; then
    fail "check_file.sh がカスタムタグYAMLで誤ブロックする(D3の回帰)"
  fi
fi
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_config_syntax.sh`
Expected: FAIL — `check_file.sh が tsconfig.json のコメントで誤ブロックする(D2の回帰)`(現行実装は `json.load` を直接呼ぶため)

- [ ] **Step 3: `scripts/check_file.sh` の JSON/YAML 分岐を置換**

54〜63行目の2つの `case` 分岐を以下に差し替える:

```bash
  *.json)
    # 検証ロジックは lib.sh に集約(check.sh と同じ判定を保つため)
    OUT="$(harness_validate_json "$FILE" 2>&1)" && OUT=""
    ;;
  *.yaml|*.yml)
    OUT="$(harness_validate_yaml "$FILE" 2>&1)" && OUT=""
    ;;
```

- [ ] **Step 4: テストを実行して通ることを確認**

Run: `bash tests/test_config_syntax.sh`
Expected: PASS

- [ ] **Step 5: 既存テストの回帰確認**

Run: `bash tests/run_tests.sh`
Expected: 全 PASS

- [ ] **Step 6: コミット**

```bash
git add scripts/check_file.sh tests/test_config_syntax.sh
git commit -m "fix: check_file.sh のJSON/YAML検証を共有関数へ委譲し誤ブロックを解消"
```

---

### Task 3: `check.sh` に横断チェック節を追加(D1 の解消)

**Files:**
- Modify: `scripts/check.sh`(汎用フォールバック節の直前に追加、および結果出力節 201-204 行)
- Test: `tests/test_check_config.sh`(新規)

**Interfaces:**
- Consumes: Task 1 の `harness_validate_json` / `harness_validate_yaml` / `harness_has_pyyaml`、既存の `list_files` / `run_stage`
- Produces: 結果行 `PASS/FAIL  config: json 構文` と `config: yaml 構文`。Task 4 がこの節の隣に format ステージを足す

- [ ] **Step 1: 失敗テストを書く**

`tests/test_check_config.sh` を作成:

```bash
#!/usr/bin/env bash
# test_check_config.sh — check.sh が設定ファイルの構文を検査することを検証する。
#
# check_file.sh が JSON/YAML を検証できるのに check.sh 側に無いと、Bash 経由や
# 外部エディタで壊された設定ファイルが完了前チェックをすり抜ける(Shell ステージを
# 追加したときと同じ非対称性)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
. "$REPO/scripts/lib.sh"
CHECK="$REPO/scripts/check.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

new_project() { # new_project <名前> — 空のgitプロジェクトを作って標準出力にパスを返す
  local d="$WORK/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}

# --- 壊れたJSONだけのプロジェクト(他のスタックは無い) ---
P1="$(new_project json_only)"
printf '{"a": 1,\n' > "$P1/config.json"
OUT="$(bash "$CHECK" "$P1" 2>&1)"; RC=$?
assert_eq "1" "$RC" "壊れたJSONで exit 1 になる"
assert_contains "$OUT" "config: json 構文" "json 構文ステージが結果に出る"
assert_contains "$OUT" "config.json" "失敗ログに対象ファイル名が出る"

# --- 正当なJSONなら通る ---
P2="$(new_project json_ok)"
printf '{"a": 1}\n' > "$P2/config.json"
OUT="$(bash "$CHECK" "$P2" 2>&1)"; RC=$?
assert_eq "0" "$RC" "正当なJSONは exit 0"
assert_contains "$OUT" "PASS  config: json 構文" "PASSとして記録される"

# --- JSONC は誤検出しない(D2の回帰・check.sh 経由) ---
P3="$(new_project jsonc)"
printf '{\n  // コメント\n  "a": 1\n}\n' > "$P3/tsconfig.json"
OUT="$(bash "$CHECK" "$P3" 2>&1)"; RC=$?
assert_eq "0" "$RC" "tsconfig.json のコメントで exit 1 にならない"

# --- YAML(PyYAML がある時のみ実質検証。無ければ理由付きSKIP) ---
P4="$(new_project yaml_broken)"
printf 'a: [1, 2\n' > "$P4/conf.yaml"
OUT="$(bash "$CHECK" "$P4" 2>&1)"; RC=$?
if harness_has_pyyaml; then
  assert_eq "1" "$RC" "壊れたYAMLで exit 1 になる"
  assert_contains "$OUT" "config: yaml 構文" "yaml 構文ステージが結果に出る"
else
  assert_eq "0" "$RC" "PyYAML不在では失敗にしない"
  assert_contains "$OUT" "SKIP  config: yaml 構文 (PyYAML 未インストール)" "理由付きSKIPになる"
fi

# --- 複数文書YAMLを誤検出しない(D3の回帰・check.sh 経由) ---
if harness_has_pyyaml; then
  P5="$(new_project yaml_multi)"
  printf -- '---\na: 1\n---\nb: 2\n' > "$P5/multi.yaml"
  OUT="$(bash "$CHECK" "$P5" 2>&1)"; RC=$?
  assert_eq "0" "$RC" "複数文書YAMLで exit 1 にならない"
fi

# --- 設定ファイルが無いプロジェクトでは何も記録しない ---
P6="$(new_project empty)"
printf 'hello\n' > "$P6/README.txt"
OUT="$(bash "$CHECK" "$P6" 2>&1)"
assert_not_contains "$OUT" "config: json 構文" "対象ファイルが無ければステージを出さない"
assert_contains "$OUT" "検出できたスタックがありません" "スタック未検出のメッセージは従来どおり"

assert_summary
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_check_config.sh`
Expected: FAIL — `壊れたJSONで exit 1 になる: expected [1] but got [0]`(現行の check.sh は JSON を見ないため。加えてスタック未検出で早期 exit する)

- [ ] **Step 3: 横断チェック節を追加**

`scripts/check.sh` の `# ---------- 汎用フォールバック ----------` の直前に挿入:

```bash
# ---------- 横断チェック(スタック非依存) ----------
# check_file.sh が JSON/YAML を検証できるのに check.sh 側に対応が無いと、
# Bash 経由・外部エディタで壊された設定ファイルが完了前チェックをすり抜ける
# (Shell ステージを追加したときと同じ非対称性)。
# STACK_FOUND は立てない — 設定ファイルの存在は「スタックの検出」ではない。
JSON_FILES=()
while IFS= read -r f; do
  [[ -n "$f" ]] && JSON_FILES+=("$f")
done < <(list_files '*.json')
if [[ ${#JSON_FILES[@]} -gt 0 ]]; then
  run_stage lint "-" "config: json 構文" harness_validate_json "${JSON_FILES[@]}"
fi

YAML_FILES=()
while IFS= read -r f; do
  [[ -n "$f" ]] && YAML_FILES+=("$f")
done < <(list_files '*.yaml')
while IFS= read -r f; do
  [[ -n "$f" ]] && YAML_FILES+=("$f")
done < <(list_files '*.yml')
if [[ ${#YAML_FILES[@]} -gt 0 ]]; then
  if harness_has_pyyaml; then
    run_stage lint "-" "config: yaml 構文" harness_validate_yaml "${YAML_FILES[@]}"
  else
    RESULTS+=("SKIP  config: yaml 構文 (PyYAML 未インストール)")
  fi
fi
```

- [ ] **Step 4: スタック未検出時の早期 exit を修正**

現行の結果出力節(201〜204行)は、`STACK_FOUND` が 0 のとき `RESULTS` を印字せずに exit 0 する。横断チェックは `STACK_FOUND` を立てないため、**設定ファイルだけのプロジェクトで JSON の FAIL が握り潰される**。結果が1件でもあれば通常の出力経路へ進むよう条件を変える:

```bash
if [[ $STACK_FOUND -eq 0 && ${#RESULTS[@]} -eq 0 ]]; then
  echo "検出できたスタックがありません (pyproject.toml / package.json / go.mod / Cargo.toml / pom.xml / *.sh / Makefile:check を確認)"
  exit 0
fi
```

- [ ] **Step 5: テストを実行して通ることを確認**

Run: `bash tests/test_check_config.sh`
Expected: PASS

- [ ] **Step 6: 既存テストの回帰確認と自己適用**

Run: `bash tests/run_tests.sh && bash scripts/check.sh`
Expected: テスト全 PASS。`check.sh` の結果に `PASS  config: json 構文` が現れる(このリポジトリは `.claude-plugin/*.json` 等を持つ)

- [ ] **Step 7: コミット**

```bash
git add scripts/check.sh tests/test_check_config.sh
git commit -m "feat: check.sh に設定ファイル構文の横断チェックを追加"
```

---

### Task 4: WARN 結果クラスと最初の産出源(ruff format)

**Files:**
- Modify: `scripts/check.sh`(`run_stage` 内の失敗分岐、Python 節、結果出力節)
- Test: `tests/test_check_warn.sh`(新規)

**Interfaces:**
- Consumes: 既存の `run_stage`
- Produces: 関数 `run_stage_soft <stage> <tool> <label> <cmd...>`(失敗しても FAIL にせず `WARN  <label>` を記録し exit code に影響させない)、結果行の接頭辞 `WARN  `、最終行の `N件WARN` 表記。Task 5 が `WARN  ` 行を解析する

- [ ] **Step 1: 失敗テストを書く**

`tests/test_check_warn.sh` を作成:

```bash
#!/usr/bin/env bash
# test_check_warn.sh — WARN(非ブロッキングの結果クラス)を検証する。
#
# 設計原則: プロジェクトが設定ファイルで宣言した検査は FAIL(ブロック)、
# ハーネスが推測で走らせる検査は WARN(報告のみ)。宣言していない検査で
# 完了をブロックすると、導入初日の既存プロジェクトが作業不能になる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$REPO/scripts/check.sh"

command -v ruff >/dev/null 2>&1 || { echo "  (ruff 未インストールのためスキップ)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

new_project() { # new_project <名前>
  local d="$WORK/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}
# ruff format が「要整形」と判断するコード(括弧内の余分な空白と長すぎない行)
unformatted() { printf 'x = {  "a":1 }\n'; }

# --- 宣言なし: 未整形でも WARN で、完了をブロックしない ---
P1="$(new_project no_decl)"
unformatted > "$P1/mod.py"
OUT="$(bash "$CHECK" "$P1" 2>&1)"; RC=$?
assert_eq "0" "$RC" "宣言が無ければ未整形で exit 1 にしない"
assert_contains "$OUT" "WARN  python: ruff format" "WARN として記録される"
assert_contains "$OUT" "件WARN" "最終行に WARN 件数が出る"
assert_not_contains "$OUT" "FAIL  python: ruff format" "FAIL にはしない"

# --- 宣言あり([tool.ruff] を書いた): 同じ未整形が FAIL になる ---
P2="$(new_project with_decl)"
unformatted > "$P2/mod.py"
printf '[tool.ruff]\nline-length = 100\n' > "$P2/pyproject.toml"
OUT="$(bash "$CHECK" "$P2" 2>&1)"; RC=$?
assert_eq "1" "$RC" "宣言があれば未整形で exit 1 になる"
assert_contains "$OUT" "FAIL  python: ruff format" "FAIL として記録される"

# --- 整形済みなら PASS ---
P3="$(new_project formatted)"
printf 'x = {"a": 1}\n' > "$P3/mod.py"
OUT="$(bash "$CHECK" "$P3" 2>&1)"; RC=$?
assert_eq "0" "$RC" "整形済みは exit 0"
assert_contains "$OUT" "PASS  python: ruff format" "PASS として記録される"
assert_not_contains "$OUT" "件WARN" "WARNが無ければ件数表記は出ない"

# --- WARN と FAIL が混在したら exit 1(FAIL が優先される) ---
P4="$(new_project warn_and_fail)"
unformatted > "$P4/mod.py"          # → WARN(宣言なし)
printf '{"a": 1,\n' > "$P4/broken.json"  # → FAIL(構文エラー)
OUT="$(bash "$CHECK" "$P4" 2>&1)"; RC=$?
assert_eq "1" "$RC" "FAILが1件でもあれば exit 1"
assert_contains "$OUT" "WARN  python: ruff format" "混在時もWARNは記録される"

assert_summary
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_check_warn.sh`
Expected: FAIL — `WARN として記録される: [WARN  python: ruff format] が出力に含まれない`(format ステージ自体が存在しないため)

- [ ] **Step 3: `run_stage` に WARN 分岐を追加**

`scripts/check.sh` の `RESULTS=()` / `FAILED=0` の並びに WARN 用の状態を追加:

```bash
RESULTS=()
FAILED=0
WARNED=0
SOFT_STAGE=0
```

`run_stage` の失敗分岐(現行の `else` 節)を差し替える:

```bash
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
```

`run_stage` の定義直後に薄いラッパを追加:

```bash
# run_stage_soft — 失敗しても完了をブロックせず WARN として記録する。
# プロジェクトが設定で宣言していない検査(ハーネスの推測)に使う。
run_stage_soft() {
  SOFT_STAGE=1
  run_stage "$@"
  SOFT_STAGE=0
}
```

- [ ] **Step 4: Python 節に format ステージを追加**

Python 節のマニフェスト分岐で、`run_stage lint "ruff" ...` の直後に追加:

```bash
  # 宣言(pyproject.toml の [tool.ruff] 系)があれば FAIL、無ければ WARN。
  # 既存プロジェクトがフォーマッタ未使用の場合に完了不能にしないため
  if grep -q "^\[tool\.ruff" pyproject.toml 2>/dev/null; then
    run_stage format "ruff" "python: ruff format" ruff format --check .
  else
    run_stage_soft format "ruff" "python: ruff format" ruff format --check .
  fi
```

マニフェストが無い分岐(`PY_FILES` を使う側)では、`run_stage lint "ruff" "python: ruff" ruff check "${PY_FILES[@]}"` の直後に追加:

```bash
    # マニフェストが無い=宣言も無いので WARN 固定
    run_stage_soft format "ruff" "python: ruff format" ruff format --check "${PY_FILES[@]}"
```

- [ ] **Step 5: 結果出力節に WARN の集計と表示を追加**

`printf '%s\n' "${RESULTS[@]}"` の直後に、警告ブロックの出力を挿入:

```bash
if [[ $WARNED -eq 1 ]]; then
  echo
  echo "以下は完了をブロックしませんが、確認してください:"
  cat "$LOGDIR/warnings.txt"
fi
```

集計ループに WARN を加える:

```bash
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
```

最終行の判定を差し替える(WARN は「走った」に数える — 実行されなかった SKIP とは違う):

```bash
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
```

- [ ] **Step 6: テストを実行して通ることを確認**

Run: `bash tests/test_check_warn.sh`
Expected: PASS

- [ ] **Step 7: 既存テストの回帰確認と自己適用**

Run: `bash tests/run_tests.sh && bash scripts/check.sh; echo "exit=$?"`
Expected: テスト全 PASS。このリポジトリ自身は `scripts/feedback_log.py` が ruff format 未適用のため `WARN  python: ruff format` が出て、**exit は 0 のまま**(WARN は完了をブロックしない)

- [ ] **Step 8: コミット**

```bash
git add scripts/check.sh tests/test_check_warn.sh
git commit -m "feat: 非ブロッキングのWARN結果クラスを追加しruff formatを宣言ゲートで実行する"
```

---

### Task 5: WARN を events.jsonl へ記録

**Files:**
- Modify: `scripts/lib.sh`(`harness_log_event` の直後に追加)
- Modify: `scripts/hooks/on_stop.sh`
- Test: `tests/test_events_log.sh`(既存ファイルに追記)

**Interfaces:**
- Consumes: Task 4 の `WARN  <label>` 出力行、既存の `harness_log_event`
- Produces: `harness_log_warn <root> <label>` — `{"ts":"...","hook":"stop","result":"warn","check":"<label>"}` を1行追記する。Task 6 の `stats`/`report` がこの `check` フィールドで集計する

- [ ] **Step 1: 失敗テストを追記**

`tests/test_events_log.sh` の `assert_summary` の直前に追加:

```bash
# --- WARN は events.jsonl に記録される(成功時の出力はエージェントに届かないため、
#     WARN を握り潰さずフィードバックループに載せる唯一の経路になる) ---
: > "$EVENTS"
mkdir -p "$WORK/fake"
{ echo '#!/usr/bin/env bash'
  echo 'echo "=== feedback-harness check ==="'
  echo 'echo "PASS  python: ruff"'
  echo 'echo "WARN  python: ruff format"'
  echo 'echo "ALL PASS (1件WARN — 未対応の指摘があります)"'
  echo 'exit 0'
} > "$WORK/fake/check.sh"
chmod +x "$WORK/fake/check.sh"
rm -f "$STAMP"
printf '{"stop_hook_active": false}' \
  | CLAUDE_PROJECT_DIR="$WORK/proj" bash "$WORK/fake/hooks/on_stop.sh" >/dev/null 2>&1
EV="$(cat "$EVENTS")"
assert_contains "$EV" '"result":"warn"' "WARN イベントが記録される"
assert_contains "$EV" '"check":"python: ruff format"' "WARN のラベルが check として記録される"
assert_contains "$EV" '"result":"pass"' "同じ実行の stop 成功イベントも残る"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_events_log.sh`
Expected: FAIL — `WARN イベントが記録される: ["result":"warn"] が出力に含まれない`

- [ ] **Step 3: `scripts/lib.sh` に `harness_log_warn` を追加**

`harness_log_event` の定義の直後に追加:

```bash
# harness_log_warn <ルート> <ラベル> — WARN を events.jsonl に1行追記する。
#
# Stop フックは成功時(exit 0)の出力をエージェントへ渡さないため、WARN は
# そのままでは誰にも届かない。記録して stats/report に載せることで、
# 反復する WARN が「設定を入れて FAIL に昇格させるか」の判断材料になる。
harness_log_warn() {
  local root="$1" label="$2"
  local dir="$root/.feedback"
  local ev="$dir/events.jsonl"
  mkdir -p "$dir" 2>/dev/null || return 0
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 0
  printf '{"ts":"%s","hook":"stop","result":"warn","check":"%s"}\n' \
    "$ts" "$label" >>"$ev" 2>/dev/null || return 0
  return 0
}
```

- [ ] **Step 4: `scripts/hooks/on_stop.sh` に WARN 抽出を追加**

`if OUT="$("$DIR/../check.sh" "$ROOT" 2>&1)"; then` ブロックの `harness_log_event "$ROOT" stop pass` の直前に、WARN 行の記録を挿入する。失敗側(`harness_log_event "$ROOT" stop fail` の直前)にも同じ処理を置く。重複を避けるため関数にまとめる — スクリプト冒頭の `. "$DIR/../lib.sh"` の後に定義:

```bash
# check.sh の出力から WARN 行を拾って記録する。成功時の出力はエージェントに
# 渡らないため、記録しないと WARN は誰にも届かない
log_warns() { # log_warns <check.shの出力>
  local line label
  while IFS= read -r line; do
    case "$line" in
      "WARN  "*) label="${line#WARN  }"; harness_log_warn "$ROOT" "$label" ;;
    esac
  done <<< "$1"
}
```

成功分岐:

```bash
if OUT="$("$DIR/../check.sh" "$ROOT" 2>&1)"; then
  mkdir -p "$(dirname "$STAMP")" 2>/dev/null && : > "$STAMP" 2>/dev/null
  log_warns "$OUT"
  harness_log_event "$ROOT" stop pass
  exit 0
fi

log_warns "$OUT"
harness_log_event "$ROOT" stop fail
```

- [ ] **Step 5: テストを実行して通ることを確認**

Run: `bash tests/test_events_log.sh`
Expected: PASS

- [ ] **Step 6: 既存テストの回帰確認**

Run: `bash tests/run_tests.sh`
Expected: 全 PASS

- [ ] **Step 7: コミット**

```bash
git add scripts/lib.sh scripts/hooks/on_stop.sh tests/test_events_log.sh
git commit -m "feat: WARN を events.jsonl に記録しフィードバックループに載せる"
```

---

### Task 6: `stats` / `report` に頻出WARNを表示し、通過率の汚染を修正

**Files:**
- Modify: `scripts/feedback_log.py`(`cmd_stats` のフック節、`cmd_report` の数字節)
- Test: `tests/test_stats.sh`(既存ファイルに追記・修正)

**Interfaces:**
- Consumes: Task 5 が書く `{"result":"warn","check":"<label>"}` 形式のイベント、既存の `load_events()`
- Produces: `stats` の `頻出WARN: <label>(<件数>), ...` 行、`report` の `## WARN` 節

- [ ] **Step 1: 失敗テストを追記**

`tests/test_stats.sh` の events フィクスチャ(`cat > "$WORK/project/.feedback/events.jsonl"` のヒアドキュメント)の `this is not json` の直前に3行追加する:

```
{"ts":"2026-08-13T07:00:00Z","hook":"stop","result":"warn","check":"python: ruff format"}
{"ts":"2026-08-13T08:00:00Z","hook":"stop","result":"warn","check":"python: ruff format"}
{"ts":"2026-08-13T09:00:00Z","hook":"stop","result":"warn","check":"config: yaml 構文"}
```

同ファイルの `assert_contains "$OUT" "Stop フルチェック初回通過率: 2/3 (67%)" "stop の pass 率"` の直後に追加:

```bash
# WARN イベントは stop の通過率の分母に混ぜない(warn は「テストの失敗」ではない)
assert_contains "$OUT" "頻出WARN: python: ruff format(2), config: yaml 構文(1)" "頻出WARNが件数降順で出る"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_stats.sh`
Expected: FAIL 2件 — `Stop フルチェック初回通過率: 2/3 (67%)` が `2/6 (33%)` に変わる(warn が分母に混入)、および `頻出WARN` 行が存在しない

- [ ] **Step 3: `cmd_stats` を修正**

`scripts/feedback_log.py` の `cmd_stats` 内、stop 集計の行を差し替える(warn を分母から除く):

```python
        stops = [
            e for e in evs
            if e.get("hook") == "stop"
            and e.get("result") in ("pass", "fail")
            and str(e.get("ts", ""))[:10] >= since
        ]
```

同じブロックの `top = sorted(fails.items(), ...)` の直後に、頻出WARNの出力を追加:

```python
        warns = {}
        for e in evs:
            if e.get("result") != "warn" or str(e.get("ts", ""))[:10] < since:
                continue
            k = e.get("check", "-")
            warns[k] = warns.get(k, 0) + 1
        if warns:
            top_warn = sorted(warns.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
            print("頻出WARN: " + ", ".join(f"{k}({v})" for k, v in top_warn))
```

- [ ] **Step 4: `cmd_report` に WARN 節を追加**

`cmd_report` の `print("## 数字")` ブロックの直前に挿入する。イベントの読み込みは1回で済ませるため、ここで `evs` を束縛する:

```python
    print()
    print("## WARN(ブロックしないが溜まっている指摘)")
    evs = load_events()
    warns = {}
    for e in evs:
        if e.get("result") != "warn" or str(e.get("ts", ""))[:10] < since:
            continue
        k = e.get("check", "-")
        warns[k] = warns.get(k, 0) + 1
    if not warns:
        print("(なし)")
    for k, v in sorted(warns.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"- {k}: {v}件")
```

続く「## 数字」ブロックの先頭にある `evs = load_events()` の行は**削除する**(同じファイルを2度読まない)。`print("## 数字")` の直後は `if not evs:` から始まる形になる。

- [ ] **Step 5: report 側のテストを追記**

`tests/test_report.sh` の events フィクスチャのヒアドキュメント末尾(`EOF` の直前)に1行追加:

```
{"ts":"2026-08-14T03:00:00Z","hook":"stop","result":"warn","check":"python: ruff format"}
```

同ファイルの `assert_contains "$OUT" "PostToolUse 初回通過率:" "イベント数字が出る"` の直後に追加:

```bash
assert_contains "$OUT" "## WARN" "WARN セクションがある"
assert_contains "$OUT" "python: ruff format: 1件" "WARN の件数が出る"
```

- [ ] **Step 6: テストを実行して通ることを確認**

Run: `bash tests/test_stats.sh && bash tests/test_report.sh`
Expected: 両方 PASS

- [ ] **Step 7: 既存テストの回帰確認**

Run: `bash tests/run_tests.sh`
Expected: 全 PASS

- [ ] **Step 8: コミット**

```bash
git add scripts/feedback_log.py tests/test_stats.sh tests/test_report.sh
git commit -m "feat: stats/report に頻出WARNを表示し stop 通過率からWARNを除外する"
```

---

### Task 7: ドキュメント・バージョン・全体チェック

**Files:**
- Modify: `scripts/README.md`(結果クラス・ステージ表・検査一覧)
- Modify: `README.md`(仕組み)
- Modify: `AGENTS.md` と `docs/pointer_agents.md`(規約3の最終行の表)
- Modify: `CLAUDE.md`(変更履歴)
- Modify: `.claude-plugin/plugin.json`(0.3.0 → 0.4.0)

**Interfaces:**
- Consumes: Task 1〜6 のすべての動作
- Produces: なし(リリース整備)

- [ ] **Step 1: `scripts/README.md` の設計思想に WARN を追記**

「設計思想(共通)」の項目2の直後に項目を挿入し、以降の番号を繰り下げる:

```markdown
3. **宣言の有無で強度を決める**: プロジェクトが設定ファイルで宣言した検査は `FAIL`(完了をブロック)、ハーネスが推測で走らせる検査は `WARN`(報告のみ・exit 0)。宣言していない検査で完了不能にすると、導入初日の既存プロジェクトが作業できなくなる。WARN は `events.jsonl` に記録され `stats` / `report` の「頻出WARN」に現れる。
4. **ツールを自動インストールしない**: 未導入は `SKIP` と理由表示に留める。インストールは環境を変える行為であり、導入の判断はユーザーが行う。
```

- [ ] **Step 2: `scripts/README.md` の check.sh 節を更新**

「**動作:**」の行を差し替える:

```markdown
**動作:** 検出したスタックごとに `lint` / `typecheck` / `test` / `build` / `format` を走らせ、スタック非依存の横断チェック(設定ファイルの構文)も実行して、`PASS`/`FAIL`/`WARN`/`SKIP` の要約を出す。
```

「**検出対象**」の箇条書きの直後に2項目を追加:

```markdown
- **横断チェック(スタック非依存)**: `*.json` / `*.yaml` / `*.yml` の構文検証。`tsconfig*.json` / `jsconfig*.json` / `devcontainer.json` / `.vscode/` 配下はコメント付き(JSONC)が慣例のため対象外。YAML は複数文書(`---` 区切り)に対応し、未知のカスタムタグ(`!Ref` 等)は構文エラーとして扱わない。PyYAML 未導入なら YAML は理由付き `SKIP`
- **ステージスキップ**: `FEEDBACK_CHECK_SKIP` に指定できるステージ名は `lint` / `typecheck` / `test` / `build` / `format`
```

「**exit code**」の行の直前に追加:

```markdown
- **WARN**: 完了をブロックしない指摘。exit code は `0` のまま。最終行に件数が付く(`ALL PASS (1件WARN — 未対応の指摘があります)`)。現在の産出源は `python: ruff format`(`pyproject.toml` に `[tool.ruff` の宣言があれば `FAIL` に切り替わる)
```

- [ ] **Step 3: `README.md` の「仕組み」表を更新**

Claude Code 行の「自動チェック」セルの末尾に追記:

```markdown
。設定ファイル(JSON/YAML)の構文も横断的に検査し、宣言していない検査の指摘は WARN(非ブロッキング)として `events.jsonl` に記録される
```

- [ ] **Step 4: `AGENTS.md` と `docs/pointer_agents.md` の規約3の表に WARN 行を追加**

両ファイルの「最終行は状況により変わる」表に行を追加(`ALL PASS` 行の直後):

```markdown
| `ALL PASS (N件WARN — 未対応の指摘があります)` | 成功したが、ブロックしない指摘がある。内容を確認し、直せるものは直す |
```

- [ ] **Step 5: `CLAUDE.md` の変更履歴に1行追加**

変更履歴テーブルの最終行の後に追加:

```markdown
| 2026-08-16 | 適用範囲拡張 P1(基盤と既存欠陥) | lib.sh / check_file.sh / check.sh / on_stop.sh / feedback_log.py / tests | JSONC・複数文書YAMLの誤ブロック解消、設定ファイル構文の横断検査、非ブロッキングWARNとその測定連携 |
```

- [ ] **Step 6: バージョンを 0.4.0 に上げる**

`.claude-plugin/plugin.json` の `"version": "0.3.0",` を `"version": "0.4.0",` に変更。

- [ ] **Step 7: 全体チェック**

Run: `bash scripts/check.sh; echo "exit=$?"`
Expected: `exit=0`。このリポジトリは `scripts/feedback_log.py` が ruff format 未適用のため `WARN  python: ruff format` と最終行 `ALL PASS (1件WARN — 未対応の指摘があります)` が出る(WARN は完了をブロックしない)

- [ ] **Step 8: コミット**

```bash
git add scripts/README.md README.md AGENTS.md docs/pointer_agents.md CLAUDE.md .claude-plugin/plugin.json
git commit -m "docs: P1(構文検査・WARN機構)の文書を整え v0.4.0 に上げる"
```

---

## 完了後の自省(実行エージェント向け)

計画全体を終えたら、このセッションで共有アーティファクト(CLAUDE.md・`docs/`・スキル)を変えるべき出来事があったかを1問自省する(CLAUDE.md のトリガーに従う)。実装中に設計と実際が食い違った場合は、設計書(spec)側も更新してから完了すること。

P1 完了後の次段階は **P2(速い検査群)** — 秘密情報(secretlint)・Dockerfile(dockerfilelint)・アーキ制約(import-linter)・依存整合性・デッドコード・内部リンク。P2 の着手前に、必要な npm パッケージの導入可否をユーザーに確認すること(原則 P-A: 自動インストールしない)。
