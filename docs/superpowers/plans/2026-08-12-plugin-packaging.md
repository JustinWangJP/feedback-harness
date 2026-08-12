# feedback-harness プラグイン化 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** feedback-harness を Claude Code Plugin として配布可能にし、導入先が本体の更新に自動追従できるようにする(Codex 対応は維持)。

**Architecture:** リポジトリ自体をマーケットプレイス兼プラグインにする。コード(scripts / skills / agents / hooks)の実体はプラグイン側にのみ置き、状態(`.feedback/`)は導入先リポジトリに置く。両者を分離するため、全スクリプトのプロジェクトルート解決を `CLAUDE_PROJECT_DIR → git rev-parse → cwd` に統一し、`__file__` 起点の解決は「バンドル資産の読み取り」に限定する。

**Tech Stack:** Bash 3.2+ (macOS 標準), Python 3 (標準ライブラリのみ), Claude Code Plugin (`.claude-plugin/`), GNU Make, shellcheck, ruff

## Global Constraints

- **設計仕様:** `docs/superpowers/specs/2026-08-12-plugin-packaging-design.md` が正。矛盾したら仕様を優先し、逸脱する場合は仕様も更新すること。
- **Python は標準ライブラリのみ。** 導入先に依存を増やさないため、`feedback_log.py` に外部パッケージを追加しない。
- **Bash は 3.2 互換。** macOS 標準の bash が 3.2 系のため、連想配列(`declare -A`)と `${var,,}` を使わない。
- **プラグインキャッシュに状態を書かない。** `${CLAUDE_PLUGIN_ROOT}` 配下への書き込みは禁止(更新時に消える)。
- **プラグイン名:** `feedback-harness`、マーケットプレイス名も `feedback-harness`、初版バージョンは `0.1.0`。
- **既存の出力文言を変えない。** `ALL PASS` / `ALL PASS (N件SKIP — 未検証の項目があります)` / `実行できたステージがありません(すべてSKIP)` / `検出できたスタックがありません` は AGENTS.md が表として文書化しているため文字列を維持する。
- **全スクリプトは shellcheck (`-S warning`) と `bash -n` を通ること。** Stop フックが自分自身を検査するため、通らないとコミットできない。
- **コミットは各タスク末尾で1回。** メッセージは日本語、`Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` で終える。

---

## File Structure

**新規作成**

| パス | 責務 |
|------|------|
| `tests/assert.sh` | アサーション関数のみ。テスト本体は持たない |
| `tests/run_tests.sh` | `tests/test_*.sh` を子プロセスとして実行し集計する |
| `tests/test_project_root.sh` | `harness_project_root()` の解決順 |
| `tests/test_feedback_log_root.sh` | `feedback_log.py` の状態書き込み先 |
| `tests/test_session_start_seed.sh` | `.feedback/` 自動シード |
| `tests/test_init_sh.sh` | `scripts/init.sh` の展開内容と冪等性 |
| `tests/test_plugin_manifest.sh` | マニフェストの JSON 妥当性と参照先の実在 |
| `Makefile` | `check:` ターゲット。`check.sh` から `make check` として呼ばれる |
| `.claude-plugin/plugin.json` | プラグインのメタデータ |
| `.claude-plugin/marketplace.json` | カタログ |
| `hooks/hooks.json` | 配布用 Hooks 定義(`${CLAUDE_PLUGIN_ROOT}` 基準) |
| `commands/init.md` | `/feedback-harness:init` — `scripts/init.sh` のラッパー |
| `scripts/hooks/on_session_start.sh` | `.feedback/` が無ければシードする |

**変更**

| パス | 変更内容 |
|------|---------|
| `scripts/lib.sh` | `harness_project_root()` を追加 |
| `scripts/check.sh:19-20` | ルート解決を共通関数へ。`30-42` の重複 `has()` を削除 |
| `scripts/hooks/on_stop.sh:22` | フォールバックを共通関数へ |
| `scripts/feedback_log.py:25-28` | 状態ルートとバンドル資産の分離 |
| `docs/pointer_claude.md` | `extraKnownMarketplaces` の案内を追記 |
| `README.md` / `CLAUDE.md` | 導入手順の刷新 |
| `.claude/agents/harness-qa.md` | 検証項目にプラグイン構成を追加 |

**移動 / 改名**

| 変更前 | 変更後 |
|--------|--------|
| `.claude/skills/{apply,capture}-feedback/`, `.claude/skills/feedback-loop/` | `skills/` 配下 |
| `.claude/agents/*.md` | `agents/` 配下 |
| `install.sh` | `scripts/init.sh` |

**維持**

`.claude/settings.json` はこのリポジトリ自身の開発用に残す(自己ドッグフーディング)。配布用は `hooks/hooks.json`。両者の参照先がずれないことを `tests/test_plugin_manifest.sh` で検証する。

**開発中の動作確認方法:** `skills/` と `agents/` をリポジトリルートへ移すと、このリポジトリでは Claude Code の自動検出対象から外れる。開発中は `/plugin marketplace add .` → `/plugin install feedback-harness@feedback-harness` でローカルインストールして使う。実際の配布経路をそのまま検証できる。

---

## Task 1: テスト土台の構築

**Files:**
- Create: `tests/assert.sh`
- Create: `tests/run_tests.sh`
- Create: `tests/test_smoke.sh`
- Create: `Makefile`

**Interfaces:**
- Consumes: なし
- Produces:
  - `tests/assert.sh` が定義する関数 — `assert_eq <expected> <actual> <label>`、`assert_contains <haystack> <needle> <label>`、`assert_file_exists <path> <label>`、`assert_file_absent <path> <label>`、`fail <msg>`、`assert_summary`(失敗が1件でもあれば exit 1)
  - 以降の全タスクのテストは `tests/test_*.sh` という名前で置けば `run_tests.sh` が自動発見する

- [ ] **Step 1: `tests/assert.sh` を作る**

```bash
#!/usr/bin/env bash
# assert.sh — テスト用アサーション。各 test_*.sh から source して使う。
#
# 失敗は即座に終了せず数え上げ、assert_summary で最後にまとめて報告する。
# 1ファイル内の複数の失敗を1回の実行で全部見せるため(修正の往復を減らす)。
ASSERT_FAILURES=0
ASSERT_CHECKS=0

fail() {
  echo "    FAIL: $1" >&2
  ASSERT_FAILURES=$((ASSERT_FAILURES + 1))
}

assert_eq() { # assert_eq <expected> <actual> <label>
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  [[ "$1" == "$2" ]] || fail "$3: expected [$1] but got [$2]"
}

assert_contains() { # assert_contains <haystack> <needle> <label>
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  case "$1" in
    *"$2"*) ;;
    *) fail "$3: [$2] が出力に含まれない。出力: [$1]" ;;
  esac
}

assert_file_exists() { # assert_file_exists <path> <label>
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  [[ -e "$1" ]] || fail "$2: 存在しない: $1"
}

assert_file_absent() { # assert_file_absent <path> <label>
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  [[ ! -e "$1" ]] || fail "$2: 存在してはいけない: $1"
}

assert_summary() {
  if [[ $ASSERT_FAILURES -gt 0 ]]; then
    echo "    ${ASSERT_FAILURES}/${ASSERT_CHECKS} 件の検証が失敗" >&2
    exit 1
  fi
  exit 0
}
```

- [ ] **Step 2: `tests/run_tests.sh` を作る**

```bash
#!/usr/bin/env bash
# run_tests.sh — tests/test_*.sh を1件ずつ子プロセスで実行する。
#
# 子プロセスで実行するのは、テストが cd や export で環境を汚しても
# 他のテストに影響させないため。
set -u
TESTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASSED=0
FAILED=0
FAILED_NAMES=""

for t in "$TESTDIR"/test_*.sh; do
  [[ -f "$t" ]] || continue
  name="$(basename "$t")"
  echo "  $name"
  if bash "$t"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_NAMES="${FAILED_NAMES}    $name"$'\n'
  fi
done

echo "=== tests: ${PASSED} passed, ${FAILED} failed ==="
if [[ $FAILED -gt 0 ]]; then
  printf '%s' "$FAILED_NAMES"
  exit 1
fi
exit 0
```

- [ ] **Step 3: 失敗するスモークテストを書く**

`tests/test_smoke.sh`:

```bash
#!/usr/bin/env bash
# test_smoke.sh — テスト土台そのものが動くことの確認。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/assert.sh"

assert_eq "ok" "ng" "土台の失敗検出"
assert_summary
```

- [ ] **Step 4: 失敗することを確認する**

Run: `bash tests/run_tests.sh`
Expected: FAIL。`test_smoke.sh` の行に `FAIL: 土台の失敗検出: expected [ok] but got [ng]` が出て、最終行が `=== tests: 0 passed, 1 failed ===`、exit code 1。

- [ ] **Step 5: スモークテストを成功に変える**

`tests/test_smoke.sh` の該当行を差し替える:

```bash
assert_eq "ok" "ok" "土台の成功検出"
```

- [ ] **Step 6: 成功することを確認する**

Run: `bash tests/run_tests.sh; echo "exit=$?"`
Expected: `=== tests: 1 passed, 0 failed ===` と `exit=0`

- [ ] **Step 7: `Makefile` を作る**

`check.sh` は `Makefile` に `^check:` があると `make check` を実行する。これでテストが Stop フックの自動チェックに組み込まれる。

```makefile
# check: — feedback-harness の check.sh から `make check` として呼ばれる。
# check.sh 自身を呼び返さないこと(無限再帰になる)。
.PHONY: check test
check: test

test:
	@bash tests/run_tests.sh
```

**注意:** Makefile のレシピ行は**タブ文字**でインデントすること。スペースだと `missing separator` で失敗する。

- [ ] **Step 8: check.sh 経由でテストが走ることを確認する**

Run: `bash scripts/check.sh . 2>&1 | grep -E "make check|ALL PASS"`
Expected: `PASS  make check` を含む行が出る。

- [ ] **Step 9: 自己チェックを通す**

Run: `bash scripts/check.sh .; echo "exit=$?"`
Expected: `exit=0`。shellcheck の指摘が出たら修正してから次へ進む。

- [ ] **Step 10: コミット**

```bash
git add tests/ Makefile
git commit -m "$(cat <<'EOF'
test: bash テストの土台を追加

以降のパス解決・シード・導入手順の変更を検証するための最小の土台。
check.sh の Makefile フォールバック経由で Stop フックからも自動実行される。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: プロジェクトルート解決の共通化 (Bash)

現状 `check.sh:19` は `ROOT="${1:-.}"` でカレントディレクトリを、`on_stop.sh:22` は `$DIR/../..` をフォールバックにしている。後者はプラグインキャッシュから実行されるとキャッシュを検査ツリーと誤認する。

あわせて `check.sh:30-42` の `has()` 重複を削除する。`lib.sh` の冒頭コメントが「実際に has() でそれが起きた」と記録しているとおり、この重複は既知のドリフト源であり、同じ場所に新しい共有関数を足す前に解消しておく。

**Files:**
- Modify: `scripts/lib.sh`(末尾に関数を追加)
- Modify: `scripts/check.sh:19-20`, `scripts/check.sh:30-42`
- Modify: `scripts/hooks/on_stop.sh:22`
- Test: `tests/test_project_root.sh`

**Interfaces:**
- Consumes: `tests/assert.sh`(Task 1)
- Produces: `harness_project_root [明示パス]` — 絶対パスを1行で stdout に出す。明示パスが渡され、かつそれが存在しないディレクトリの場合は何も出さず exit 1。それ以外は必ず成功する。

- [ ] **Step 1: 失敗するテストを書く**

`tests/test_project_root.sh`:

```bash
#!/usr/bin/env bash
# test_project_root.sh — harness_project_root() の解決順を検証する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
. "$HERE/../scripts/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# macOS の mktemp は /var/folders/... を返すが実体は /private/var/... なので
# pwd の結果と比較するために実パスへ正規化しておく
WORK="$(cd "$WORK" && pwd)"

# 1: 明示引数が最優先
mkdir -p "$WORK/explicit"
assert_eq "$WORK/explicit" "$(harness_project_root "$WORK/explicit")" "明示引数が最優先"

# 2: 存在しない明示引数はエラー
if harness_project_root "$WORK/no-such-dir" >/dev/null 2>&1; then
  fail "存在しない明示引数で成功してしまった"
fi

# 3: 明示引数が無ければ CLAUDE_PROJECT_DIR
mkdir -p "$WORK/from-env"
assert_eq "$WORK/from-env" \
  "$(CLAUDE_PROJECT_DIR="$WORK/from-env" harness_project_root)" \
  "CLAUDE_PROJECT_DIR を使う"

# 4: CLAUDE_PROJECT_DIR が実在しないディレクトリなら無視して次段へ
mkdir -p "$WORK/repo/sub"
( cd "$WORK/repo" && git init -q . )
assert_eq "$WORK/repo" \
  "$(cd "$WORK/repo/sub" && CLAUDE_PROJECT_DIR="$WORK/no-such-dir" harness_project_root)" \
  "壊れた CLAUDE_PROJECT_DIR は git にフォールバック"

# 5: 環境変数が無ければ git のトップレベル(サブディレクトリからでもリポジトリルート)
assert_eq "$WORK/repo" \
  "$(cd "$WORK/repo/sub" && unset CLAUDE_PROJECT_DIR; harness_project_root)" \
  "git rev-parse --show-toplevel を使う"

# 6: git 管理外なら cwd
mkdir -p "$WORK/plain"
assert_eq "$WORK/plain" \
  "$(cd "$WORK/plain" && unset CLAUDE_PROJECT_DIR; GIT_CEILING_DIRECTORIES="$WORK" harness_project_root)" \
  "git 管理外は cwd"

assert_summary
```

**補足:** ケース6の `GIT_CEILING_DIRECTORIES` は、`$WORK` が偶然どこかの git リポジトリの内側にあった場合に `git rev-parse` が外側のリポジトリを拾うのを防ぐために必要。

- [ ] **Step 2: 失敗することを確認する**

Run: `bash tests/test_project_root.sh`
Expected: FAIL。`harness_project_root: command not found` 相当のエラーで exit 1。

- [ ] **Step 3: `harness_project_root()` を `scripts/lib.sh` の末尾に追加する**

```bash
# harness_project_root [明示パス] — 検査対象・状態保存先のプロジェクトルートを解決する。
#
# 解決順: 明示引数 → CLAUDE_PROJECT_DIR → git rev-parse --show-toplevel → cwd
#
# スクリプト自身の位置($BASH_SOURCE 起点)は使わない。プラグインとして配布されると
# スクリプトはプラグインキャッシュに置かれ、そこは導入先ではないうえ更新のたびに
# 消える領域だからである(状態を書くと失われる)。
harness_project_root() {
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then
    (cd "$explicit" 2>/dev/null && pwd) || return 1
    return 0
  fi
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "${CLAUDE_PROJECT_DIR}" ]]; then
    (cd "$CLAUDE_PROJECT_DIR" && pwd)
    return 0
  fi
  local top
  if top="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$top" ]]; then
    printf '%s\n' "$top"
    return 0
  fi
  pwd
}
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `bash tests/test_project_root.sh; echo "exit=$?"`
Expected: `exit=0`(無出力)

- [ ] **Step 5: `check.sh` の重複 `has()` を削除する**

`scripts/check.sh` の30〜42行目(`# has: コマンドが存在し…` のコメントブロックから `}` まで)を丸ごと削除する。`lib.sh` を17行目で source 済みなので定義は失われない。

削除後、43行目の `skipped() { ... }` が `run_stage` の直前に来ることを確認する。

- [ ] **Step 6: 重複削除後も check.sh が動くことを確認する**

Run: `bash scripts/check.sh .; echo "exit=$?"`
Expected: `exit=0` で `ALL PASS` 系の行が出る。`has: command not found` が出たら source 順を確認する。

- [ ] **Step 7: `check.sh` のルート解決を差し替える**

19〜20行目:

```bash
ROOT="${1:-.}"
cd "$ROOT" 2>/dev/null || { echo "ERROR: ディレクトリが見つかりません: $ROOT"; exit 2; }
```

を次に置き換える:

```bash
ROOT="$(harness_project_root "${1:-}")" \
  || { echo "ERROR: ディレクトリが見つかりません: ${1:-}"; exit 2; }
cd "$ROOT" || { echo "ERROR: ディレクトリへ移動できません: $ROOT"; exit 2; }
```

- [ ] **Step 8: `on_stop.sh` のフォールバックを差し替える**

`scripts/hooks/on_stop.sh` の9行目 `DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` の直後に lib.sh の読み込みを追加する:

```bash
# shellcheck source=../lib.sh
. "$DIR/../lib.sh"
```

22行目のコメント付き代入:

```bash
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$DIR/../.." && pwd)}"
```

を次に置き換える(コメントも更新する):

```bash
# 検査ルートを明示的に渡す。省略するとカレントディレクトリが検査対象になり、
# サブディレクトリ起動やCI流用時に沈黙して誤ったツリーを検査する。
# $DIR 起点にはしない — プラグイン配布時はキャッシュを指してしまう。
ROOT="$(harness_project_root)"
```

- [ ] **Step 9: on_stop.sh がプラグインキャッシュを誤認しないことを手で確認する**

Run:

```bash
WORK=$(mktemp -d) && mkdir -p "$WORK/cache/scripts/hooks" "$WORK/project" && cp scripts/*.sh scripts/*.py "$WORK/cache/scripts/" && cp scripts/hooks/*.sh "$WORK/cache/scripts/hooks/" && (cd "$WORK/project" && git init -q . && echo '{}' | CLAUDE_PROJECT_DIR="$WORK/project" bash "$WORK/cache/scripts/hooks/on_stop.sh"; echo "exit=$?") ; rm -rf "$WORK"
```

Expected: `exit=0`。`$WORK/project` は空の git リポジトリなのでスタック未検出となり、キャッシュ側(`.sh` が多数ある)を検査していないことがわかる。`shell: shellcheck` 等の行が出たらキャッシュを検査してしまっている。

- [ ] **Step 10: 全テストと自己チェックを通す**

Run: `bash tests/run_tests.sh && bash scripts/check.sh .; echo "exit=$?"`
Expected: `exit=0`

- [ ] **Step 11: コミット**

```bash
git add scripts/lib.sh scripts/check.sh scripts/hooks/on_stop.sh tests/test_project_root.sh
git commit -m "$(cat <<'EOF'
fix: プロジェクトルート解決を共通化しスクリプト位置への依存を断つ

on_stop.sh のフォールバックが $DIR/../.. だったため、プラグインとして
配布するとプラグインキャッシュを検査ツリーと誤認する。解決順を
明示引数 → CLAUDE_PROJECT_DIR → git rev-parse → cwd に統一した。

あわせて check.sh に残っていた has() の重複定義を削除した(lib.sh と
二重管理になっており、同じ場所に共有関数を追加する前に解消した)。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: feedback_log.py の状態保存先を分離する

現状 `ROOT = Path(__file__).resolve().parent.parent` のため、プラグインキャッシュから実行するとフィードバックがキャッシュ内に書かれ、プラグイン更新で失われる。

**状態**(`.feedback/log/`, `.feedback/rules.md`)は解決済みのプロジェクトルート基準、**バンドル資産**(`rules.template.md` のフォールバック)は `__file__` 基準、と用途で使い分ける。

**Files:**
- Modify: `scripts/feedback_log.py:19-44`
- Test: `tests/test_feedback_log_root.sh`

**Interfaces:**
- Consumes: `tests/assert.sh`(Task 1)
- Produces: `feedback_log.py` の `project_root() -> Path`。モジュールレベルの `ROOT` / `LOG_DIR` / `RULES` / `RULES_TEMPLATE` は名前と型を維持し、`BUNDLED_TEMPLATE: Path` を新設する。

- [ ] **Step 1: 失敗するテストを書く**

`tests/test_feedback_log_root.sh`:

```bash
#!/usr/bin/env bash
# test_feedback_log_root.sh — feedback_log.py が状態を「導入先」に書くことを検証する。
#
# プラグイン配布で最も退行しやすい箇所。スクリプトをキャッシュ相当の場所へ
# コピーして実行し、そこではなく導入先に .feedback/ ができることを確かめる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

# プラグインキャッシュを模した場所へスクリプトとバンドル資産を配置する
mkdir -p "$WORK/cache/scripts" "$WORK/cache/.feedback"
cp "$REPO/scripts/feedback_log.py" "$WORK/cache/scripts/"
cp "$REPO/.feedback/rules.template.md" "$WORK/cache/.feedback/"

# 導入先(.feedback/ をまだ持たない git リポジトリ)
mkdir -p "$WORK/project"
( cd "$WORK/project" && git init -q . )

OUT="$(cd "$WORK/project" && CLAUDE_PROJECT_DIR="$WORK/project" \
  python3 "$WORK/cache/scripts/feedback_log.py" add \
    --category workflow --summary "テスト用の指摘" --source human 2>&1)"

assert_contains "$OUT" "recorded:" "add が成功する"
assert_file_absent "$WORK/cache/.feedback/log" "キャッシュ側にログを作らない"
ENTRIES="$(find "$WORK/project/.feedback/log" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "1" "$ENTRIES" "導入先にエントリが1件できる"

# rules.md をキャッシュ側(バンドル)のテンプレートから初期化できること。
# 導入先には rules.template.md が無い状態なので、BUNDLED_TEMPLATE への
# フォールバックが働かないとヘッダの無い rules.md ができる。
# rules_seed() を実際に通るのは promote なので、それで検証する。
ENTRY_ID="$(printf '%s' "$OUT" | sed -n 's/.*(id=\(.*\))$/\1/p')"
if [[ -z "$ENTRY_ID" ]]; then
  fail "add の出力から id を取り出せない: [$OUT]"
else
  ( cd "$WORK/project" && CLAUDE_PROJECT_DIR="$WORK/project" \
    python3 "$WORK/cache/scripts/feedback_log.py" promote "$ENTRY_ID" \
      --rule "テスト用のルール" >/dev/null 2>&1 )
  assert_contains "$(cat "$WORK/project/.feedback/rules.md" 2>/dev/null)" \
    "フィードバック由来ルール" "バンドルのテンプレートでシードされる"
  assert_file_absent "$WORK/cache/.feedback/rules.md" "キャッシュ側に rules.md を作らない"
fi

# CLAUDE_PROJECT_DIR が無くても git のトップレベルへ書く
mkdir -p "$WORK/project/sub"
OUT3="$(cd "$WORK/project/sub" && unset CLAUDE_PROJECT_DIR; \
  python3 "$WORK/cache/scripts/feedback_log.py" add \
    --category workflow --summary "サブディレクトリからの指摘" --source human 2>&1)"
assert_contains "$OUT3" "recorded:" "サブディレクトリからでも add できる"
assert_file_absent "$WORK/project/sub/.feedback" "サブディレクトリ直下には作らない"
ENTRIES2="$(find "$WORK/project/.feedback/log" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "2" "$ENTRIES2" "リポジトリルートに集約される"

assert_summary
```

- [ ] **Step 2: 失敗することを確認する**

Run: `bash tests/test_feedback_log_root.sh`
Expected: FAIL。`キャッシュ側にログを作らない: 存在してはいけない: .../cache/.feedback/log` と `導入先にエントリが1件できる: expected [1] but got [0]` が出る。

- [ ] **Step 3: `feedback_log.py` のパス解決を差し替える**

19〜23行目の import 群に `os` と `subprocess` を足す:

```python
import argparse
import datetime
import os
import re
import subprocess
import sys
from pathlib import Path
```

25〜28行目:

```python
ROOT = Path(__file__).resolve().parent.parent
LOG_DIR = ROOT / ".feedback" / "log"
RULES = ROOT / ".feedback" / "rules.md"
RULES_TEMPLATE = ROOT / ".feedback" / "rules.template.md"
```

を次に置き換える:

```python
def project_root() -> Path:
    """状態(.feedback/)を置くプロジェクトルートを解決する。

    解決順: CLAUDE_PROJECT_DIR → git rev-parse --show-toplevel → cwd

    __file__ 起点にはしない。プラグインとして配布されるとこのファイルは
    プラグインキャッシュに置かれ、そこへ書いた状態はプラグイン更新で失われる。
    """
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env and Path(env).is_dir():
        return Path(env).resolve()
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        if out:
            return Path(out).resolve()
    except (OSError, subprocess.SubprocessError):
        pass
    return Path.cwd().resolve()


ROOT = project_root()
LOG_DIR = ROOT / ".feedback" / "log"
RULES = ROOT / ".feedback" / "rules.md"
RULES_TEMPLATE = ROOT / ".feedback" / "rules.template.md"
# バンドル資産は状態と違い、スクリプトに同梱されて配られる読み取り専用のファイル。
# 導入先が rules.template.md を持たない(プラグインのみで導入した)場合の供給元。
BUNDLED_TEMPLATE = Path(__file__).resolve().parent.parent / ".feedback" / "rules.template.md"
```

- [ ] **Step 4: `rules_seed()` にバンドルのフォールバックを追加する**

41〜44行目:

```python
def rules_seed() -> str:
    if RULES_TEMPLATE.exists():
        return RULES_TEMPLATE.read_text(encoding="utf-8")
    return DEFAULT_RULES_HEADER
```

を次に置き換える:

```python
def rules_seed() -> str:
    # 導入先のテンプレート → バンドルのテンプレート → 埋め込みの既定ヘッダ
    for candidate in (RULES_TEMPLATE, BUNDLED_TEMPLATE):
        if candidate.exists():
            return candidate.read_text(encoding="utf-8")
    return DEFAULT_RULES_HEADER
```

- [ ] **Step 5: テストが通ることを確認する**

Run: `bash tests/test_feedback_log_root.sh; echo "exit=$?"`
Expected: `exit=0`(無出力)

- [ ] **Step 6: 既存の CLI 機能が壊れていないことを確認する**

Run: `python3 scripts/feedback_log.py list --status all && python3 scripts/feedback_log.py rules | head -5`
Expected: このリポジトリ自身の既存エントリ(`20260809-163042-設定値をハードコードしない`)が一覧に出て、rules の先頭に `# フィードバック由来ルール` が出る。

- [ ] **Step 7: 全テストと自己チェックを通す**

Run: `bash tests/run_tests.sh && bash scripts/check.sh .; echo "exit=$?"`
Expected: `exit=0`。ruff の指摘が出たら修正する。

- [ ] **Step 8: コミット**

```bash
git add scripts/feedback_log.py tests/test_feedback_log_root.sh
git commit -m "$(cat <<'EOF'
fix: フィードバックの保存先を実行スクリプトの位置から切り離す

ROOT が __file__ 起点だったため、プラグインとして配布するとフィードバックが
プラグインキャッシュへ書かれ、プラグイン更新のたびに蓄積が消える構造だった。
状態は解決済みのプロジェクトルート基準、バンドル資産(rules.template.md)は
__file__ 基準、と用途で分離した。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `.feedback/` の自動シード (SessionStart フック)

プラグインのみで導入したプロジェクトでは `init.sh` が走らないため、`.feedback/` を作る担い手がいない。SessionStart フックで用意する。

**Files:**
- Create: `scripts/hooks/on_session_start.sh`
- Test: `tests/test_session_start_seed.sh`

**Interfaces:**
- Consumes: `harness_project_root`(Task 2)、`.feedback/rules.template.md`(既存)
- Produces: `scripts/hooks/on_session_start.sh` — 常に exit 0。標準入力の JSON は読み捨てる。

- [ ] **Step 1: 失敗するテストを書く**

`tests/test_session_start_seed.sh`:

```bash
#!/usr/bin/env bash
# test_session_start_seed.sh — SessionStart フックによる .feedback/ シードを検証する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

HOOK="$REPO/scripts/hooks/on_session_start.sh"

# 1: .feedback/ が無いプロジェクトにシードされる
mkdir -p "$WORK/fresh"
echo '{}' | CLAUDE_PROJECT_DIR="$WORK/fresh" bash "$HOOK"
assert_eq "0" "$?" "シード実行が成功する"
assert_file_exists "$WORK/fresh/.feedback/rules.md" "rules.md が作られる"
assert_file_exists "$WORK/fresh/.feedback/log" "log/ が作られる"
SEEDED="$(cat "$WORK/fresh/.feedback/rules.md")"
assert_contains "$SEEDED" "フィードバック由来ルール" "テンプレート内容でシードされる"

# 2: 既存の .feedback/rules.md は上書きしない
mkdir -p "$WORK/existing/.feedback/log"
printf 'MY OWN RULES\n' > "$WORK/existing/.feedback/rules.md"
echo '{}' | CLAUDE_PROJECT_DIR="$WORK/existing" bash "$HOOK"
assert_eq "MY OWN RULES" "$(cat "$WORK/existing/.feedback/rules.md")" "既存 rules.md を保護する"

# 3: 書き込めない場所でもセッションをブロックしない
mkdir -p "$WORK/readonly"
chmod 500 "$WORK/readonly"
echo '{}' | CLAUDE_PROJECT_DIR="$WORK/readonly" bash "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "書き込み不可でも exit 0"
chmod 700 "$WORK/readonly"

assert_summary
```

- [ ] **Step 2: 失敗することを確認する**

Run: `bash tests/test_session_start_seed.sh`
Expected: FAIL。`bash: .../on_session_start.sh: No such file or directory` によりアサーションが失敗する。

- [ ] **Step 3: `scripts/hooks/on_session_start.sh` を作る**

```bash
#!/usr/bin/env bash
# on_session_start.sh — Claude Code SessionStart フック。
#
# プラグインのみで導入したプロジェクトには .feedback/ を作る担い手がいない
# (init.sh を実行するのは Codex 併用時だけ)。ここで一度だけシードする。
#
# 既存の .feedback/ には一切触れない。失敗してもセッションはブロックしない。
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$DIR/../lib.sh"

cat >/dev/null 2>&1 || true   # フック入力のJSONは使わないが読み捨てる

ROOT="$(harness_project_root)" || exit 0
TEMPLATE="$DIR/../../.feedback/rules.template.md"

mkdir -p "$ROOT/.feedback/log" 2>/dev/null || exit 0

if [[ ! -f "$ROOT/.feedback/rules.md" ]]; then
  if [[ -f "$TEMPLATE" ]]; then
    cp "$TEMPLATE" "$ROOT/.feedback/rules.md" 2>/dev/null || exit 0
  else
    # テンプレートが同梱されていない場合の最小シード。
    # feedback_log.py の DEFAULT_RULES_HEADER と同じ役割。
    cat > "$ROOT/.feedback/rules.md" 2>/dev/null <<'SEED' || exit 0
# フィードバック由来ルール

エージェントはセッション開始時に必ずこのファイルを読むこと。

<!-- ここから下に promote されたルールが追記される -->
SEED
  fi
fi

exit 0
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `bash tests/test_session_start_seed.sh; echo "exit=$?"`
Expected: `exit=0`(無出力)

- [ ] **Step 5: 全テストと自己チェックを通す**

Run: `bash tests/run_tests.sh && bash scripts/check.sh .; echo "exit=$?"`
Expected: `exit=0`

- [ ] **Step 6: コミット**

```bash
git add scripts/hooks/on_session_start.sh tests/test_session_start_seed.sh
git commit -m "$(cat <<'EOF'
feat: SessionStart フックで .feedback/ を自動シードする

プラグインのみで導入したプロジェクトは init.sh を実行しないため、
フィードバックの置き場を作る担い手がいなかった。既存の .feedback/ には
触れず、失敗してもセッションをブロックしない設計とした。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: プラグイン骨格の作成

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`
- Create: `hooks/hooks.json`
- Move: `.claude/skills/*` → `skills/*`、`.claude/agents/*` → `agents/*`
- Test: `tests/test_plugin_manifest.sh`

**Interfaces:**
- Consumes: `scripts/hooks/{post_edit,on_stop,on_session_start}.sh`(Task 2, 4)
- Produces: プラグイン名 `feedback-harness`、マーケットプレイス名 `feedback-harness`。スキルは `feedback-harness:apply-feedback` のように名前空間化される。

- [ ] **Step 1: 失敗するテストを書く**

`tests/test_plugin_manifest.sh`:

```bash
#!/usr/bin/env bash
# test_plugin_manifest.sh — プラグインのマニフェストと構成を検証する。
#
# claude CLI が無い環境でも動くよう、JSON の妥当性と参照先の実在は
# python3 で自前に確認する(claude plugin validate は Step 6 で別途実行する)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

# 1: JSON として妥当
for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$REPO/$f" 2>/dev/null; then
    :
  else
    fail "$f が妥当な JSON でない"
  fi
done

# 2: プラグイン名とマーケットプレイス名
assert_eq "feedback-harness" \
  "$(python3 -c "import json;print(json.load(open('$REPO/.claude-plugin/plugin.json'))['name'])")" \
  "プラグイン名"
assert_eq "feedback-harness" \
  "$(python3 -c "import json;print(json.load(open('$REPO/.claude-plugin/marketplace.json'))['name'])")" \
  "マーケットプレイス名"

# 3: コンポーネントが規定の場所にある
assert_file_exists "$REPO/skills/apply-feedback/SKILL.md" "apply-feedback"
assert_file_exists "$REPO/skills/capture-feedback/SKILL.md" "capture-feedback"
assert_file_exists "$REPO/skills/feedback-loop/SKILL.md" "feedback-loop"
assert_file_exists "$REPO/agents/feedback-curator.md" "feedback-curator"
assert_file_exists "$REPO/agents/harness-qa.md" "harness-qa"
assert_file_absent "$REPO/.claude/skills" "旧 .claude/skills が残っていない"
assert_file_absent "$REPO/.claude/agents" "旧 .claude/agents が残っていない"

# 4: hooks.json が参照するスクリプトが実在する
MISSING="$(python3 - "$REPO" <<'PY'
import json, re, sys, pathlib
repo = pathlib.Path(sys.argv[1])
cfg = json.load(open(repo / "hooks" / "hooks.json"))
missing = []
for entries in cfg["hooks"].values():
    for entry in entries:
        for hook in entry["hooks"]:
            for path in re.findall(r'\$\{CLAUDE_PLUGIN_ROOT\}"?(/\S+\.sh)', hook["command"]):
                if not (repo / path.lstrip("/")).is_file():
                    missing.append(path)
print(" ".join(missing))
PY
)"
assert_eq "" "$MISSING" "hooks.json の参照先が実在する"

# 5: 開発用 .claude/settings.json と配布用 hooks.json が同じスクリプトを指す
#    (二重管理なので、片方だけ直してもう片方が古いまま残るのを防ぐ)
NAMES_A="$(python3 -c "
import json,re
cfg=json.load(open('$REPO/.claude/settings.json'))
print(' '.join(sorted(set(re.findall(r'([a-z_]+\.sh)', json.dumps(cfg))))))
")"
NAMES_B="$(python3 -c "
import json,re
cfg=json.load(open('$REPO/hooks/hooks.json'))
print(' '.join(sorted(set(re.findall(r'([a-z_]+\.sh)', json.dumps(cfg))))))
")"
assert_eq "$NAMES_A" "$NAMES_B" "開発用と配布用のフック定義が同じスクリプトを指す"

assert_summary
```

- [ ] **Step 2: 失敗することを確認する**

Run: `bash tests/test_plugin_manifest.sh`
Expected: FAIL。マニフェスト未作成・スキル未移動により複数の検証が失敗する。

- [ ] **Step 3: `.claude-plugin/plugin.json` を作る**

```json
{
  "name": "feedback-harness",
  "displayName": "Feedback Harness",
  "version": "0.1.0",
  "description": "lint/test/build の結果をエージェントへ自動フィードバックし、人間のレビュー指摘を蓄積してルール化するハーネス",
  "author": {
    "name": "JustinWangJP",
    "url": "https://github.com/JustinWangJP"
  },
  "homepage": "https://github.com/JustinWangJP/feedback-harness",
  "keywords": ["feedback", "lint", "hooks", "code-review"]
}
```

- [ ] **Step 4: `.claude-plugin/marketplace.json` を作る**

プラグインがマーケットプレイスと同じリポジトリのルートにあるので、`source` はリポジトリルートを指す相対パスにする。

```json
{
  "name": "feedback-harness",
  "owner": {
    "name": "JustinWangJP",
    "url": "https://github.com/JustinWangJP"
  },
  "plugins": [
    {
      "name": "feedback-harness",
      "source": "./",
      "description": "lint/test/build の自動フィードバックと、人間のレビュー指摘の蓄積・ルール化"
    }
  ]
}
```

- [ ] **Step 5: `hooks/hooks.json` を作る**

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}\"/scripts/hooks/on_session_start.sh",
            "timeout": 30
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}\"/scripts/hooks/post_edit.sh",
            "timeout": 60
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}\"/scripts/hooks/on_stop.sh",
            "timeout": 300
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 6: 開発用 `.claude/settings.json` に SessionStart を追加する**

配布用と参照スクリプトを揃える(Step 1 のケース5)。既存の `PostToolUse` 配列の**前**に追加する:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/hooks/on_session_start.sh\"",
            "timeout": 30
          }
        ]
      }
    ],
    "PostToolUse": [
```

以降の `PostToolUse` / `Stop` は現状のまま維持する。

- [ ] **Step 7: skills と agents を移動する**

```bash
mkdir -p skills agents
git mv .claude/skills/apply-feedback skills/apply-feedback
git mv .claude/skills/capture-feedback skills/capture-feedback
git mv .claude/skills/feedback-loop skills/feedback-loop
git mv .claude/agents/feedback-curator.md agents/feedback-curator.md
git mv .claude/agents/harness-qa.md agents/harness-qa.md
rmdir .claude/skills .claude/agents 2>/dev/null || true
```

- [ ] **Step 8: テストが通ることを確認する**

Run: `bash tests/test_plugin_manifest.sh; echo "exit=$?"`
Expected: `exit=0`(無出力)

- [ ] **Step 9: Claude Code 公式のバリデータを通す**

Run: `claude plugin validate . 2>&1 | tail -20`
Expected: `✔ Validation passed`(警告付きで通る場合もある)。

`source` の値でエラーが出た場合は `"./"` を `"."` に変えて再実行する。それでも通らない場合はエラーメッセージの指示に従い、採用した形を `docs/superpowers/specs/2026-08-12-plugin-packaging-design.md` の「リポジトリ構成」節にも反映する。

`claude` コマンドが無い環境ではこの Step をスキップし、その旨をコミットメッセージに残さず、次タスクの担当者へ口頭で申し送ること。

- [ ] **Step 10: ローカルインストールで実際に読み込めることを確認する**

Claude Code のセッション内で実行:

```
/plugin marketplace add .
/plugin install feedback-harness@feedback-harness
```

その後:

Run: `claude plugin details feedback-harness 2>&1 | head -30`
Expected: Skills に `apply-feedback` / `capture-feedback` / `feedback-loop`、Agents に `feedback-curator` / `harness-qa`、Hooks に3件が並ぶ。

- [ ] **Step 11: 全テストと自己チェックを通す**

Run: `bash tests/run_tests.sh && bash scripts/check.sh .; echo "exit=$?"`
Expected: `exit=0`

- [ ] **Step 12: コミット**

```bash
git add .claude-plugin/ hooks/ skills/ agents/ .claude/settings.json tests/test_plugin_manifest.sh
git add -u .claude/
git commit -m "$(cat <<'EOF'
feat: リポジトリをプラグイン兼マーケットプレイスとして構成する

skills/ と agents/ をプラグインの規定位置(リポジトリルート)へ移し、
配布用の hooks/hooks.json を追加した。開発用 .claude/settings.json は
自己ドッグフーディングのために残し、両者が同じスクリプトを指すことを
テストで固定した。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: スキルとエージェントのコマンド表記をプラグイン対応にする

プラグインとして動くとき、スキル本文の `python3 scripts/feedback_log.py` は導入先に `scripts/` が無ければ解決できない。skill / agent 本文では `${CLAUDE_PLUGIN_ROOT}` が実パスへ展開されるため、これに置き換える。

`docs/pointer_agents.md`(Codex 向け)は placeholder が展開されないので**据え置く**。

**Files:**
- Modify: `skills/capture-feedback/SKILL.md:17`
- Modify: `skills/apply-feedback/SKILL.md:12`, `skills/apply-feedback/SKILL.md:22`
- Modify: `skills/feedback-loop/SKILL.md:40`
- Modify: `agents/feedback-curator.md:34`, `agents/feedback-curator.md:35`
- Test: `tests/test_skill_paths.sh`

**Interfaces:**
- Consumes: Task 5 の移動後のパス
- Produces: なし(内容の書き換えのみ)

- [ ] **Step 1: 失敗するテストを書く**

`tests/test_skill_paths.sh`:

```bash
#!/usr/bin/env bash
# test_skill_paths.sh — skill/agent 本文のコマンド表記がプラグイン対応であることを検証する。
#
# skills/ と agents/ の本文では ${CLAUDE_PLUGIN_ROOT} が実パスへ展開される。
# 一方 docs/pointer_agents.md は Codex 向けで展開されないため、
# リポジトリ相対のままであることを逆向きに固定する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

# 1: skills/ と agents/ に裸の "scripts/feedback_log.py" が残っていない
BARE="$(grep -rn 'scripts/feedback_log\.py' "$REPO/skills" "$REPO/agents" 2>/dev/null \
  | grep -v 'CLAUDE_PLUGIN_ROOT' || true)"
assert_eq "" "$BARE" "skills/agents に裸の scripts/ 参照が残っていない"

# 2: 置換後の表記が実際に使われている
HAS_PLUGIN_ROOT="$(grep -rl 'CLAUDE_PLUGIN_ROOT' "$REPO/skills" "$REPO/agents" | wc -l | tr -d ' ')"
if [[ "$HAS_PLUGIN_ROOT" -lt 3 ]]; then
  fail "CLAUDE_PLUGIN_ROOT を使うファイルが少なすぎる($HAS_PLUGIN_ROOT 件)"
fi

# 3: Codex 向けポインタは据え置き(placeholder を書いてはいけない)
POINTER="$(cat "$REPO/docs/pointer_agents.md")"
assert_contains "$POINTER" "scripts/feedback_log.py" "ポインタはリポジトリ相対のまま"
case "$POINTER" in
  *CLAUDE_PLUGIN_ROOT*) fail "pointer_agents.md に CLAUDE_PLUGIN_ROOT を書いてはいけない" ;;
esac

assert_summary
```

- [ ] **Step 2: 失敗することを確認する**

Run: `bash tests/test_skill_paths.sh`
Expected: FAIL。`skills/agents に裸の scripts/ 参照が残っていない` が該当行を列挙して失敗する。

- [ ] **Step 3: 置換を実行する**

対象6箇所を機械的に置換する。`python3` の引数として渡すためダブルクォートで囲む。

**置換文字列の `$` は必ず `\$` でエスケープすること。** perl は `s{}{}` の置換側を二重引用符文字列として扱うため、素の `${CLAUDE_PLUGIN_ROOT}` は perl 変数として空に展開されてしまう。

```bash
for f in skills/capture-feedback/SKILL.md skills/apply-feedback/SKILL.md \
         skills/feedback-loop/SKILL.md agents/feedback-curator.md; do
  perl -pi -e 's{(?<!\$\{CLAUDE_PLUGIN_ROOT\}/)scripts/feedback_log\.py}{"\$\{CLAUDE_PLUGIN_ROOT\}/scripts/feedback_log.py"}g' "$f"
done
```

置換が空文字になっていないことを即座に確認する:

```bash
grep -c 'CLAUDE_PLUGIN_ROOT' skills/capture-feedback/SKILL.md
```

Expected: 1以上。`0` なら perl のエスケープが効いておらず `""/scripts/...` のような壊れた出力になっているので、`git checkout -- skills/ agents/` で戻してから再実行する。

- [ ] **Step 4: 置換結果を目視で確認する**

Run: `grep -rn 'feedback_log\.py' skills/ agents/`
Expected: 全行が `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/feedback_log.py" ...` の形になっている。

`python3 ""${CLAUDE_PLUGIN_ROOT}/..."` のようにクォートが二重になっている行があれば手で直す。散文中(コード行以外)で `scripts/feedback_log.py` に言及している箇所は、クォートが不自然なら `` `${CLAUDE_PLUGIN_ROOT}/scripts/feedback_log.py` `` の形に手で整える。

- [ ] **Step 5: `skills/feedback-loop/SKILL.md:40` の `check.sh` 参照も確認する**

40行目付近の `対象プロジェクトで scripts/check.sh を1回実行して` は、導入先に `scripts/` が無い場合がある。次の文言に書き換える:

```markdown
3. 導入後、対象プロジェクトで `bash "${CLAUDE_PLUGIN_ROOT}/scripts/check.sh"` を1回実行してスタック検出を確認する
```

- [ ] **Step 6: テストが通ることを確認する**

Run: `bash tests/test_skill_paths.sh; echo "exit=$?"`
Expected: `exit=0`(無出力)

- [ ] **Step 7: 全テストと自己チェックを通す**

Run: `bash tests/run_tests.sh && bash scripts/check.sh .; echo "exit=$?"`
Expected: `exit=0`

- [ ] **Step 8: コミット**

```bash
git add skills/ agents/ tests/test_skill_paths.sh
git commit -m "$(cat <<'EOF'
fix: スキルとエージェントのコマンド表記を ${CLAUDE_PLUGIN_ROOT} 基準にする

プラグインのみで導入したプロジェクトには scripts/ が存在しないため、
リポジトリ相対の表記では feedback_log.py を解決できなかった。
Codex 向けの docs/pointer_agents.md は placeholder が展開されないため据え置き、
その差をテストで固定した。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `install.sh` を `scripts/init.sh` へ再構成する

`.claude/agents`、`.claude/skills`、`.claude/settings.json` のコピーはプラグインが担うので削除する。残るのは Codex 向けのベンダリングとポインタ追記。

**Files:**
- Move: `install.sh` → `scripts/init.sh`
- Modify: `scripts/init.sh`(全面的に整理)
- Create: `commands/init.md`
- Test: `tests/test_init_sh.sh`

**Interfaces:**
- Consumes: `docs/pointer_claude.md`、`docs/pointer_agents.md`、`.feedback/rules.template.md`
- Produces: `bash scripts/init.sh <対象パス>` — 冪等。対象に `scripts/`、`AGENTS.md`、`CLAUDE.md`、`.feedback/`、`.gitignore` を用意する。

- [ ] **Step 1: 失敗するテストを書く**

`tests/test_init_sh.sh`:

```bash
#!/usr/bin/env bash
# test_init_sh.sh — scripts/init.sh の展開内容と冪等性を検証する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

mkdir -p "$WORK/target"
( cd "$WORK/target" && git init -q . )

OUT="$(bash "$REPO/scripts/init.sh" "$WORK/target" 2>&1)"
assert_eq "0" "$?" "init.sh が成功する"

# Codex 向けにベンダリングされるもの
assert_file_exists "$WORK/target/scripts/check.sh" "check.sh"
assert_file_exists "$WORK/target/scripts/check_file.sh" "check_file.sh"
assert_file_exists "$WORK/target/scripts/lib.sh" "lib.sh"
assert_file_exists "$WORK/target/scripts/feedback_log.py" "feedback_log.py"
assert_file_exists "$WORK/target/AGENTS.md" "AGENTS.md"
assert_file_exists "$WORK/target/CLAUDE.md" "CLAUDE.md"
assert_file_exists "$WORK/target/.feedback/rules.md" "rules.md"

# プラグインが担う領域はコピーしない
assert_file_absent "$WORK/target/.claude/skills" ".claude/skills をコピーしない"
assert_file_absent "$WORK/target/.claude/agents" ".claude/agents をコピーしない"
assert_file_absent "$WORK/target/.claude/settings.json" ".claude/settings.json をコピーしない"
assert_file_absent "$WORK/target/scripts/hooks" "hooks ラッパーをコピーしない"

# 実行権限
if [[ -x "$WORK/target/scripts/check.sh" ]]; then :; else fail "check.sh に実行権限がない"; fi

# ベンダリングした check.sh が対象プロジェクトで動く
( cd "$WORK/target" && bash scripts/check.sh >/dev/null 2>&1 )
RC=$?
if [[ $RC -ne 0 && $RC -ne 1 ]]; then
  fail "ベンダリングした check.sh が異常終了した (exit=$RC)"
fi

# 冪等性: 2回目でポインタが重複しない
BEFORE_C="$(grep -c 'ハーネス: フィードバックループ' "$WORK/target/CLAUDE.md")"
BEFORE_A="$(grep -c 'フィードバックハーネス' "$WORK/target/AGENTS.md")"
bash "$REPO/scripts/init.sh" "$WORK/target" >/dev/null 2>&1
assert_eq "$BEFORE_C" "$(grep -c 'ハーネス: フィードバックループ' "$WORK/target/CLAUDE.md")" "CLAUDE.md のポインタが重複しない"
assert_eq "$BEFORE_A" "$(grep -c 'フィードバックハーネス' "$WORK/target/AGENTS.md")" "AGENTS.md のポインタが重複しない"

# 既存 rules.md を上書きしない
printf 'MY OWN RULES\n' > "$WORK/target/.feedback/rules.md"
bash "$REPO/scripts/init.sh" "$WORK/target" >/dev/null 2>&1
assert_eq "MY OWN RULES" "$(cat "$WORK/target/.feedback/rules.md")" "既存 rules.md を保護する"

# 自分自身への導入は拒否する
if bash "$REPO/scripts/init.sh" "$REPO" >/dev/null 2>&1; then
  fail "自分自身への導入が拒否されなかった"
fi

assert_summary
```

- [ ] **Step 2: 失敗することを確認する**

Run: `bash tests/test_init_sh.sh`
Expected: FAIL。`scripts/init.sh` が存在しないため全アサーションが失敗する。

- [ ] **Step 3: `install.sh` を移動する**

```bash
git mv install.sh scripts/init.sh
```

- [ ] **Step 4: `scripts/init.sh` を書き換える**

先頭のコメントと `SRC` の算出、`.claude/` 関連ブロックを次のとおり変更する。

冒頭(1〜11行目)を差し替える:

```bash
#!/usr/bin/env bash
# init.sh — フィードバックハーネスを任意のプロジェクトへ導入する。
#
# 使い方: bash scripts/init.sh <対象プロジェクトパス>
#
# Claude Code の skills / agents / hooks はプラグインが提供するので、ここでは
# 扱わない。このスクリプトが用意するのは、プラグインを持たない環境(Codex 等)が
# 必要とする実ファイルと、両環境で共有する状態だけである。
#
# 動作:
# - scripts/(check.sh / check_file.sh / lib.sh / feedback_log.py)をコピー
# - .feedback/ のシード(rules.template.md → rules.md)を作成(既存なら触らない)
# - CLAUDE.md / AGENTS.md へ docs/pointer_*.md の断片を追記(なければ新規作成)
# - .gitignore へ _workspace/ を追記
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
```

**注意:** `SRC` は `scripts/` の1階層上(リポジトリルート)を指す必要がある。移動前は `install.sh` がルートにあったため `dirname` のみだった。

`scripts/` コピーのブロック(旧23〜31行目)を差し替える。hooks ラッパーは Claude Code 専用なのでコピーしない:

```bash
# scripts/ — Codex 等がリポジトリ相対で叩くための実体
mkdir -p "$DEST/scripts"
cp "$SRC/scripts/check.sh" "$SRC/scripts/check_file.sh" "$SRC/scripts/lib.sh" \
   "$SRC/scripts/feedback_log.py" "$SRC/scripts/README.md" "$DEST/scripts/"
# 755(+x ではなく明示指定)。シェルスクリプトの実行には読み取り権限が必要で、
# 導入元が 711 の場合に +x だと所有者以外が実行できない権限のまま複製される
chmod 755 "$DEST/scripts/"*.sh "$DEST/scripts/feedback_log.py"
echo "  scripts/ ... OK"
```

`.claude/agents + skills` のブロック(旧33〜40行目)と `settings.json` のブロック(旧42〜49行目)を**丸ごと削除**し、代わりに案内を1行出す:

```bash
# Claude Code 向けの skills / agents / hooks はプラグインが提供する
echo "  .claude/ ... スキップ(Claude Code ではプラグインを使ってください)"
```

`.feedback/` のブロック(旧51〜58行目)はコメントを更新して維持する:

```bash
# .feedback/
# rules.md は導入元の promote 済みルール(と導入先に存在しない出典ID)を持ち込まないよう、
# ヘッダのみのテンプレートをシードにする。template 自体も feedback_log.py が
# rules.md 再生成時に参照するためコピーする。
mkdir -p "$DEST/.feedback/log"
cp "$SRC/.feedback/rules.template.md" "$DEST/.feedback/rules.template.md"
[[ -f "$DEST/.feedback/rules.md" ]] || cp "$SRC/.feedback/rules.template.md" "$DEST/.feedback/rules.md"
echo "  .feedback/ ... OK"
```

末尾のメッセージ(旧94〜95行目)を差し替える:

```bash
echo
echo "導入完了。動作確認: cd \"$DEST\" && bash scripts/check.sh"
echo "Claude Code を使う場合は、あわせてプラグインを導入してください:"
echo "  /plugin marketplace add JustinWangJP/feedback-harness"
echo "  /plugin install feedback-harness@feedback-harness"
```

その他(`DEST` の検証、`append_pointer`、`.gitignore` 追記)は現状のまま維持する。

- [ ] **Step 5: テストが通ることを確認する**

Run: `bash tests/test_init_sh.sh; echo "exit=$?"`
Expected: `exit=0`(無出力)

- [ ] **Step 6: `commands/init.md` を作る**

```markdown
---
description: このプロジェクトへフィードバックハーネスの Codex 向け資産(scripts/ と AGENTS.md)を展開する
---

# feedback-harness init

このプロジェクトで Codex や他の汎用エージェントも使う場合に実行する。Claude Code だけで使うなら実行不要(スキル・エージェント・Hooks はプラグインが提供し、`.feedback/` は SessionStart フックが用意する)。

## 手順

1. 次のコマンドを実行する:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" "${CLAUDE_PROJECT_DIR}"
```

2. 出力を読み、各項目が OK / 追記 / スキップのいずれかで完了していることを確認する。

3. 展開された `scripts/check.sh` が動くことを確認する:

```bash
cd "${CLAUDE_PROJECT_DIR}" && bash scripts/check.sh; echo "exit=$?"
```

`exit=0` でなければ、出力された FAIL の内容をユーザーに報告する。スタック未検出(`検出できたスタックがありません`)は失敗ではない。

4. 追加・変更されたファイルをユーザーに列挙して報告する。`git add` やコミットは行わない — 何を取り込むかはユーザーが決める。
```

- [ ] **Step 7: スラッシュコマンドが登録されることを確認する**

Run: `claude plugin details feedback-harness 2>&1 | grep -i init`
Expected: `init` を含む行が Skills グループに出る(`commands/` は Skills グループとして集計される)。

`claude` が無い環境ではこの Step をスキップする。

- [ ] **Step 8: 全テストと自己チェックを通す**

Run: `bash tests/run_tests.sh && bash scripts/check.sh .; echo "exit=$?"`
Expected: `exit=0`

- [ ] **Step 9: コミット**

```bash
git add scripts/init.sh commands/ tests/test_init_sh.sh
git add -u
git commit -m "$(cat <<'EOF'
refactor: install.sh を scripts/init.sh へ移し責務を Codex 向けに絞る

Claude Code の skills / agents / hooks はプラグインが提供するため、
コピー処理を削除した。残る責務は Codex 等が必要とする scripts/ の
ベンダリングと、両環境で共有する .feedback/ とポインタの用意。

/feedback-harness:init は init.sh を呼ぶだけのラッパーとし、
Claude Code を持たない利用者も同じ導入経路を使えるようにした。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: ドキュメントと QA エージェントの更新

**Files:**
- Modify: `README.md`(構成・導入手順の節)
- Modify: `CLAUDE.md`(変更履歴に1行追加)
- Modify: `docs/pointer_claude.md`(`extraKnownMarketplaces` の案内を追記)
- Modify: `agents/harness-qa.md`(検証項目を追加)
- Modify: `docs/superpowers/specs/2026-08-12-plugin-packaging-design.md`(実装で確定した点を反映)

**Interfaces:**
- Consumes: Task 1〜7 の成果すべて
- Produces: なし

- [ ] **Step 1: `README.md` の「構成」節を差し替える**

37行目までのツリーを次に置き換える:

```
.claude-plugin/
  plugin.json       # プラグイン定義
  marketplace.json  # カタログ(このリポジトリ自身を配布する)
skills/             # feedback-loop (オーケストレーター) / capture-feedback / apply-feedback
agents/             # feedback-curator (ルール昇華) / harness-qa (整合性検証)
commands/
  init.md           # /feedback-harness:init — Codex 向け資産の展開
hooks/
  hooks.json        # 配布用 Hooks 定義 (${CLAUDE_PLUGIN_ROOT} 基準)
scripts/
  check.sh          # スタック自動検出 (Python/Node/Go/Rust/Java/Shell/Make) → lint/test/build、要約出力
  check_file.sh     # 単一ファイルの高速チェック (拡張子ベース)
  lib.sh            # 共有ユーティリティ (has / SHELLCHECK_SEVERITY / harness_project_root)
  feedback_log.py   # フィードバック記録CLI (add / list / search / promote / rules)
  init.sh           # 導入スクリプト (Codex 向け資産の展開)
  hooks/            # Claude Code Hooks ラッパー (SessionStart / PostToolUse / Stop)
.feedback/
  rules.md          # 一般化された恒久ルール (エージェント必読)
  rules.template.md # rules.md のシード (導入時・再生成時に使う雛形)
  log/              # 生のフィードバックエントリ (frontmatter付きMarkdown)
tests/              # bash テスト (make check → check.sh から自動実行される)
docs/
  pointer_claude.md # 導入先の CLAUDE.md へ追記する断片
  pointer_agents.md # 導入先の AGENTS.md へ追記する断片
.claude/
  settings.json     # このリポジトリ自身の開発用 Hooks (配布対象外)
```

- [ ] **Step 2: `README.md` の「他プロジェクトへの導入」節を差し替える**

41〜48行目を次に置き換える:

````markdown
## 他プロジェクトへの導入

### Claude Code だけで使う場合

```
/plugin marketplace add JustinWangJP/feedback-harness
/plugin install feedback-harness@feedback-harness
```

導入先に置かれるのは `.feedback/`(蓄積データ)だけ。スクリプト・スキル・エージェント・Hooks はプラグイン側にあり、マーケットプレイスの自動更新で追従する。

チーム全員に配りたい場合は、導入先の `.claude/settings.json` に次を書いておくと、フォルダを信頼した時点でインストールを促される:

```json
{
  "extraKnownMarketplaces": {
    "feedback-harness": {
      "source": { "source": "github", "repo": "JustinWangJP/feedback-harness" }
    }
  }
}
```

### Codex や他の汎用エージェントも使う場合

Claude Code から:

```
/feedback-harness:init
```

Claude Code を使わない場合は直接:

```bash
git clone https://github.com/JustinWangJP/feedback-harness
bash feedback-harness/scripts/init.sh /path/to/your-project
cd /path/to/your-project && bash scripts/check.sh   # スタック検出の確認
```

`scripts/` と `AGENTS.md` が導入先に展開される。`CLAUDE.md` / `AGENTS.md` が既存なら `docs/pointer_*.md` の断片を追記する(重複追記はしない)。`.feedback/rules.md` は空のテンプレートから始まる。

### 更新

| 導入形態 | 更新方法 |
|---------|---------|
| プラグイン | 自動(Claude Code がマーケットプレイスを `git pull` する) |
| `init.sh` でベンダリングした `scripts/` | `init.sh` を再実行する(冪等) |
````

- [ ] **Step 3: `docs/pointer_claude.md` に更新手順の記述を追記する**

ファイル末尾に追記する:

```markdown
**ハーネス本体の更新:** Claude Code のスキル・エージェント・Hooks はプラグインが提供しており自動更新される。`scripts/` を `init.sh` でベンダリングしている場合のみ、更新には `init.sh` の再実行が必要。
```

- [ ] **Step 4: `CLAUDE.md` の変更履歴に1行追加する**

変更履歴テーブルの末尾に追加する:

```markdown
| 2026-08-12 | プラグイン化 | .claude-plugin / hooks / skills / agents / scripts / tests | 他リポジトリへ配布可能にし、コピー方式のドリフトを解消 |
```

- [ ] **Step 5: `agents/harness-qa.md` に検証項目を追加する**

16行目付近の検証項目リストに次を追加する:

```markdown
- `.claude-plugin/plugin.json` と `.claude-plugin/marketplace.json` の妥当性(`claude plugin validate .`)
- `hooks/hooks.json` の参照先スクリプトの実在 ↔ `scripts/hooks/` の中身
- 開発用 `.claude/settings.json` と配布用 `hooks/hooks.json` が同じスクリプトを指すこと(二重管理のドリフト検出)
- `skills/` と `agents/` の本文に裸の `scripts/` 相対参照が残っていないこと(プラグイン導入時に解決できない)
- `scripts/feedback_log.py` の状態書き込み先が実行スクリプトの位置に依存しないこと — **最も退行しやすい箇所**。プラグインキャッシュへ書くと蓄積がプラグイン更新で消える
- `bash tests/run_tests.sh` が PASS すること
```

- [ ] **Step 6: 仕様書を実装結果に合わせて更新する**

`docs/superpowers/specs/2026-08-12-plugin-packaging-design.md` の「リポジトリ構成」節に、実装で確定した2点を反映する:

1. `.claude/settings.json` は削除ではなく自己ドッグフーディング用に残したこと(および両者の同期をテストで固定したこと)
2. `tests/` と `Makefile` を追加し、`check.sh` の `make check` フォールバック経由で自動実行されるようにしたこと

Task 5 Step 9 で `source` の値を `"./"` から変更した場合は、その値も反映する。

- [ ] **Step 7: ドキュメントの記述が実態と合っているか確認する**

Run:

```bash
grep -n 'install\.sh' README.md CLAUDE.md AGENTS.md docs/*.md skills/*/SKILL.md agents/*.md
```

Expected: 出力なし(`install.sh` への参照が残っていない)。残っていれば `scripts/init.sh` に直す。

- [ ] **Step 8: 全テストと自己チェックを通す**

Run: `bash tests/run_tests.sh && bash scripts/check.sh .; echo "exit=$?"`
Expected: `exit=0`

- [ ] **Step 9: 3経路の導入をまとめて手動確認する**

Run:

```bash
WORK=$(mktemp -d)
mkdir -p "$WORK/codex-only" && (cd "$WORK/codex-only" && git init -q .)
bash scripts/init.sh "$WORK/codex-only" && ls -a "$WORK/codex-only"
echo "--- Claude Code のみを模した経路(SessionStart のみ) ---"
mkdir -p "$WORK/cc-only" && (cd "$WORK/cc-only" && git init -q .)
echo '{}' | CLAUDE_PROJECT_DIR="$WORK/cc-only" bash scripts/hooks/on_session_start.sh
ls -a "$WORK/cc-only" "$WORK/cc-only/.feedback"
rm -rf "$WORK"
```

Expected:
- `codex-only`: `scripts/`、`AGENTS.md`、`CLAUDE.md`、`.feedback/`、`.gitignore` がある。`.claude/` は無い
- `cc-only`: `.feedback/rules.md` と `.feedback/log/` **だけ**がある。`scripts/` も `AGENTS.md` も無い

- [ ] **Step 10: コミット**

```bash
git add README.md CLAUDE.md docs/ agents/harness-qa.md
git commit -m "$(cat <<'EOF'
docs: プラグイン配布に合わせて導入手順とQA項目を更新

README の導入手順を3経路(Claude Code のみ / 両対応 / Codex のみ)に整理し、
extraKnownMarketplaces によるチーム配布と、形態ごとの更新方法を追記した。
harness-qa には二重管理箇所とパス解決の退行検出を検証項目として追加した。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## 完了条件

すべてのタスク終了後、次がすべて満たされていること。

- [ ] `bash tests/run_tests.sh` が全件 PASS
- [ ] `bash scripts/check.sh .` が exit 0
- [ ] `claude plugin validate .` が passed(`claude` がある環境)
- [ ] `/plugin marketplace add .` → `/plugin install feedback-harness@feedback-harness` でローカルインストールでき、`claude plugin details feedback-harness` にスキル3件・エージェント2件・コマンド1件・フック3件が並ぶ
- [ ] 空の git リポジトリに対し、SessionStart フックだけで `.feedback/` が作られ、`scripts/` は作られない
- [ ] 空の git リポジトリに対し `bash scripts/init.sh` を2回実行してもポインタが重複しない
- [ ] `install.sh` への参照がリポジトリ内に残っていない
