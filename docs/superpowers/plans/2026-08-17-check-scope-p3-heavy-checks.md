# 適用範囲拡張 P3(重い検査群・2026-08-17 改訂版)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** カバレッジ計装を test ステージに相乗りさせ(M3)、API契約差分を宣言ゲートで載せ、脆弱性監査をオンデマンド経路(scripts/audit.sh + 最終監査日の可視化)に分離する。

**Architecture:** check.sh は引き続き**オフライン検査のみ**を載せる — カバレッジは既存 test コマンドへのフラグ追加(二重実行しない)、API契約は git ベースラインとの差分。ネットワークを使う脆弱性監査は `scripts/audit.sh` に分離し、実行の有無を `.feedback/.last-audit` スタンプで可視して `stats`/`report` に「最終監査日 + 期限切れ推奨」を出す(WARN 機構と同じ「ブロックせず、溜まったら見える」哲学)。**M2 遅延実行は廃止** — 重いオフライン検査は宣言ゲートで扱う。

**Tech Stack:** Bash(`set -u`、lib.sh 共有関数)、Python 3 標準ライブラリ、git(契約差分のベースライン)。外部ツールは**あれば使う**(pip-audit / npm audit / govulncheck / cargo audit / oasdiff / cargo-semver-checks / pytest-cov)。

**Spec:** [docs/superpowers/specs/2026-08-16-check-scope-expansion-design.md](../specs/2026-08-16-check-scope-expansion-design.md)(§2 M2廃止・§3.2 オンデマンド改訂・§3.5 M3・§3.7 宣言ゲート改訂を反映済み)

## Global Constraints

- **P-A(非交渉)**: ハーネスは決してツールを自動インストールしない。未導入は SKIP と理由表示に留める
- **check.sh はネットワークを使わない**(一貫原則)。ネットワーク検査(脆弱性監査)は `scripts/audit.sh` のみが担い、Stop フックからは呼ばれない
- **テストを2回走らせない**(M3 の趣旨): カバレッジは既存 test ステージのコマンドに計装フラグを足す形でのみ実現する
- 新規の実行時依存を足さない(bash / python3 標準ライブラリ / git)
- WARN は exit code を 0 のままにする。exit 1 は FAIL のみ
- テストは `tests/test_*.sh` + `tests/assert.sh` 規約。期待値はリテラル、判定は自前カウンタ + `assert_summary` の明示 exit
- 外部ツールはテストで **PATH に偽実行ファイル**で駆動する(既存の `make_fake` パターン)。Python モジュール検出は **PYTHONPATH スタブ**で偽装する(実測: `PYTHONPATH=<dir with pytest_cov.py>` で `import pytest_cov` が通る)
- **`ls` の複数引数ゲート禁止**(P2 の欠陥6の教訓): 複数候補のファイル検出は `for` + `[[ -f ]]` またはパターンごとの `compgen -G` で書く
- コメントは「なぜ」を書く。コミットメッセージは日本語 conventional commits
- 各タスクのコミット手順に列挙したファイルだけを `git add` する

## ファイル構成

| ファイル | 責務 | 変更 |
|---|---|---|
| `scripts/audit.sh` | オンデマンド脆弱性監査(唯一のネットワーク検査) | 新規 |
| `scripts/feedback_log.py` | stats/report に最終監査日を表示 | 変更 |
| `scripts/check.sh` | M3 カバレッジ相乗り・contract ステージ | 変更 |
| `.gitignore` | `.feedback/.last-audit` | 変更 |
| `tests/test_audit.sh` | audit.sh のテスト | 新規 |
| `tests/test_check_p3.sh` | check.sh 追加分のテスト | 新規 |
| `tests/test_stats.sh` / `tests/test_report.sh` | 最終監査日表示のテスト | 変更 |

---

### Task 1: `scripts/audit.sh` — オンデマンド脆弱性監査

**Files:**
- Create: `scripts/audit.sh`
- Test: `tests/test_audit.sh`(新規)

**Interfaces:**
- Consumes: `lib.sh` の `has` / `harness_project_root`
- Produces: `scripts/audit.sh [プロジェクトルート]` — スタック検出 → 監査実行 → 要約(exit 1 = 脆弱性あり)。**成功時のみ** `.feedback/.last-audit` に ISO 日付を書く。Task 2 の `feedback_log.py` がこのスタンプを読む

**設計の要点**: 失敗時にスタンプを書かない = 監査が赤い間は「期限切れ推奨」が消えず、修正を促し続ける。出力形式は check.sh と同じ `PASS/FAIL/SKIP` 形式(エージェントが読み慣れた形)。

- [ ] **Step 1: 失敗テストを書く**

`tests/test_audit.sh` を作成:

```bash
#!/usr/bin/env bash
# test_audit.sh — オンデマンド脆弱性監査 audit.sh を検証する。
#
# audit.sh は唯一ネットワークを使う検査(Stopフックからは呼ばれない)。
# 検証するのは配線の契約: スタック検出・ツール不在SKIP・exit code・
# スタンプが「成功時のみ」書かれること(失敗中は推奨が消えないため)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
AUDIT="$REPO/scripts/audit.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

new_project() { # new_project <名前>
  local d="$WORK/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
make_fake() { # make_fake <名前> <exit> [記録ファイル]
  { echo '#!/usr/bin/env bash'
    echo 'case "$*" in *--version*) exit 0 ;; esac'
    [[ -n "${3:-}" ]] && echo "echo \"\$@\" >> \"$3\""
    echo "exit $2"
  } > "$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}

# --- Python: ツールがあり検出したら FAIL + スタンプ無し ---
P1="$(new_project py_vuln)"
printf '[project]\nname = "t"\n' > "$P1/pyproject.toml"
ARGS="$WORK/pipaudit_args.txt"; : > "$ARGS"
make_fake pip-audit 1 "$ARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P1" 2>&1)"; RC=$?
assert_eq "1" "$RC" "脆弱性ありで exit 1"
assert_contains "$OUT" "FAIL  python: pip-audit" "FAILとして記録される"
assert_not_contains "$(cat "$ARGS")" "--no-install" "pip-audit は直接起動(npxを介さない)"
assert_file_absent "$P1/.feedback/.last-audit" "失敗時はスタンプを書かない"

# --- 成功時は exit 0 + スタンプに今日の日付 ---
P2="$(new_project py_ok)"
printf '[project]\nname = "t"\n' > "$P2/pyproject.toml"
make_fake pip-audit 0
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P2" 2>&1)"; RC=$?
assert_eq "0" "$RC" "脆弱性なしで exit 0"
assert_contains "$OUT" "PASS  python: pip-audit" "PASSとして記録される"
assert_file_exists "$P2/.feedback/.last-audit" "成功時にスタンプが作られる"
TODAY="$(python3 -c 'import datetime; print(datetime.date.today().isoformat())')"
assert_contains "$(cat "$P2/.feedback/.last-audit")" "$TODAY" "スタンプはISO日付1行"

# --- ツール不在は SKIP(FAILにしない) ---
P3="$(new_project py_notool)"
printf '[project]\nname = "t"\n' > "$P3/pyproject.toml"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P3" 2>&1)"; RC=$?
assert_eq "0" "$RC" "ツール不在で完了をブロックしない"
assert_contains "$OUT" "SKIP  python: pip-audit (pip-audit 未インストール)" "理由付きSKIP"

# --- Node: lockfile があるときだけ npm audit ---
P4="$(new_project node_vuln)"
printf '{"name":"t","private":true}\n' > "$P4/package.json"
printf '{}\n' > "$P4/package-lock.json"
NARGS="$WORK/npm_args.txt"; : > "$NARGS"
make_fake npm 1 "$NARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P4" 2>&1)"; RC=$?
assert_eq "1" "$RC" "npm audit の失敗は exit 1"
assert_contains "$OUT" "FAIL  node: npm audit" "FAILとして記録される"
assert_contains "$(cat "$NARGS")" "--audit-level=high" "高深刻度のみ失敗扱い"

# lockfile が無い package.json のみは対象外(監査不能なものを監査しない)
P5="$(new_project node_nolock)"
printf '{"name":"t","private":true}\n' > "$P5/package.json"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P5" 2>&1)"
assert_not_contains "$OUT" "npm audit" "lockfileが無ければステージを出さない"

# --- 依存ファイルが一切無いプロジェクト ---
P6="$(new_project nothing)"
printf 'hello\n' > "$P6/README.txt"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$AUDIT" "$P6" 2>&1)"; RC=$?
assert_eq "0" "$RC" "監査対象が無くても exit 0"
assert_contains "$OUT" "監査対象が見つかりません" "対象なしの旨を表示"
assert_file_absent "$P6/.feedback/.last-audit" "何も実行していない場合はスタンプを書かない"

assert_summary
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_audit.sh`
Expected: FAIL — `scripts/audit.sh: No such file or directory` により全チェックが失敗する

- [ ] **Step 3: `scripts/audit.sh` を実装**

```bash
#!/usr/bin/env bash
# audit.sh — オンデマンド脆弱性監査。check.sh と異なり**ネットワークを使う**ため、
# Stop フックからは呼ばれない(feedback-loop スキル等からの明示実行専用)。
#
# 使い方: scripts/audit.sh [プロジェクトルート]
# exit 0 = 脆弱性なし(または全SKIP) / 1 = 脆弱性あり
# 成功時のみ .feedback/.last-audit に ISO 日付を書く(stats/report が表示する)。
# 失敗時にスタンプを書かない = 監査が赤い間は「監査を推奨」表示が消えず、
# 修正を促し続ける。
#
# 設計は check.sh と同じ契約に合わせる: ツール不在は SKIP(環境の問題を
# ユーザーのコードの失敗として報告しない)、出力は PASS/FAIL/SKIP の要約。
set -u

LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$LIBDIR/lib.sh"

ROOT="$(harness_project_root "${1:-}")" \
  || { echo "ERROR: ディレクトリが見つかりません: ${1:-}"; exit 2; }
cd "$ROOT" || { echo "ERROR: ディレクトリへ移動できません: $ROOT"; exit 2; }

RESULTS=()
FAILED=0
PASSED=0

run_audit() { # run_audit <ツール> <ラベル> <cmd...>
  local tool="$1" label="$2"; shift 2
  if ! has "$tool"; then
    RESULTS+=("SKIP  $label ($tool 未インストール)")
    return
  fi
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    PASSED=$((PASSED + 1))
    RESULTS+=("PASS  $label")
  else
    FAILED=1
    RESULTS+=("FAIL  $label")
    echo "----- FAIL: $label ($*) -----"
    # 監査出力は長いので末尾20行に絞る(check.sh の末尾40行より短く:
    # 対応表形式の出力が多く、対象の把握には十分なため)
    printf '%s\n' "$out" | tail -n 20
  fi
}

# ---------- Python ----------
if [[ -f pyproject.toml || -f requirements.txt || -f requirements-dev.txt \
      || -f poetry.lock || -f uv.lock ]]; then
  run_audit "pip-audit" "python: pip-audit" pip-audit
fi

# ---------- Node ----------
# lockfile が無いと npm audit は依存解決からやり直す(ネットワーク+時間)。
# lockfile の存在 = 監査可能な状態が固定されている、という前提を置く
if [[ -f package-lock.json || -f pnpm-lock.yaml || -f yarn.lock ]]; then
  run_audit "npm" "node: npm audit" npm audit --audit-level=high
fi

# ---------- Go ----------
if [[ -f go.sum ]]; then
  run_audit "govulncheck" "go: govulncheck" govulncheck ./...
fi

# ---------- Rust ----------
if [[ -f Cargo.lock ]]; then
  run_audit "cargo" "rust: cargo audit" cargo audit
fi

echo "=== feedback-harness audit ==="
printf '%s\n' "${RESULTS[@]}"
if [[ $FAILED -eq 1 ]]; then
  echo "脆弱性が検出されました。修正してから再実行すること。"
  # spec §3.2: 監査の失敗はフィードバックループに載せる(失敗シグナル)。
  # Stop フックの HINT と同じ形で、記録を促すのみ(自動記録はしない)
  echo "HINT: 修正後、python3 \"$LIBDIR/feedback_log.py\" add --source hook --category security での記録を検討すること"
  exit 1
fi
if [[ $PASSED -eq 0 ]]; then
  echo "監査対象が見つかりません(依存マニフェスト/lockfile が無い、またはツール未導入)"
  exit 0
fi
mkdir -p "$ROOT/.feedback" 2>/dev/null \
  && date +%F > "$ROOT/.feedback/.last-audit" 2>/dev/null
echo "ALL PASS (監査OK — .feedback/.last-audit を更新)"
exit 0
```

作成後、実行ビットを付ける: `chmod +x scripts/audit.sh`

- [ ] **Step 4: テストを実行して通ることを確認**

Run: `bash tests/test_audit.sh`
Expected: PASS(exit 0・無出力)

- [ ] **Step 5: 既存テストの回帰確認**

Run: `bash tests/run_tests.sh`
Expected: 全 PASS(test_audit.sh が自動拾取され 21件)

- [ ] **Step 6: コミット**

```bash
git add scripts/audit.sh tests/test_audit.sh
git commit -m "feat: オンデマンド脆弱性監査 audit.sh を追加(成功時のみスタンプ)"
```

---

### Task 2: `stats` / `report` に最終監査日を表示

**Files:**
- Modify: `scripts/feedback_log.py`(stats・report)
- Modify: `.gitignore`
- Test: `tests/test_stats.sh`(追記)

**Interfaces:**
- Consumes: Task 1 が書く `.feedback/.last-audit`(ISO 日付1行)
- Produces: stats の `[監査]` 行と report の `## 監査` 節 — `最終監査: YYYY-MM-DD (N日前)` 形式。**7日超過または未実行で推奨行**を出す

- [ ] **Step 1: 失敗テストを追記**

`tests/test_stats.sh` の `assert_summary` の直前に追加:

```bash
# --- 最終監査日(.last-audit)の表示と期限切れ推奨 ---
mkdir -p "$WORK/project/.feedback"
printf '2026-01-01\n' > "$WORK/project/.feedback/.last-audit"
OUT="$(fb stats)"
assert_contains "$OUT" "最終監査: 2026-01-01 (" "最終監査日が表示される"
assert_contains "$OUT" "日前)" "経過日数が表示される"
assert_contains "$OUT" "監査を推奨" "7日超過なら推奨行が出る"

printf '%s\n' "$(python3 -c 'import datetime; print(datetime.date.today().isoformat())')" \
  > "$WORK/project/.feedback/.last-audit"
OUT="$(fb stats)"
assert_contains "$OUT" "最終監査:" "当日でも表示される"
assert_not_contains "$OUT" "監査を推奨" "期限内なら推奨は出ない"

rm -f "$WORK/project/.feedback/.last-audit"
OUT="$(fb stats)"
assert_contains "$OUT" "最終監査: 未実行" "スタンプ無しは未実行表示"
assert_contains "$OUT" "scripts/audit.sh" "未実行なら実行方法を案内する"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_stats.sh`
Expected: FAIL — `最終監査日が表示される: [最終監査: 2026-01-01 (] が出力に含まれない`

- [ ] **Step 3: `feedback_log.py` に共通ヘルパーと stats 表示を追加**

`LAST_RETRO = ...` の定義行の後に追加:

```python
LAST_AUDIT = ROOT / ".feedback" / ".last-audit"
AUDIT_INTERVAL_DAYS = 7


def audit_status_lines() -> list:
    """最終監査日と期限切れ推奨の行を返す(report と stats で共有)。

    audit.sh は成功時のみスタンプを書くため、脆弱性が残っている間は
    「未実行/期限切れ」表示が消えず修正を促し続ける。
    """
    if not LAST_AUDIT.exists():
        return ["最終監査: 未実行 — bash scripts/audit.sh の実行を推奨"]
    raw = LAST_AUDIT.read_text(encoding="utf-8").strip()
    try:
        d = datetime.date.fromisoformat(raw)
    except ValueError:
        return [f"最終監査: {raw} (日付不明)"]
    days = (datetime.date.today() - d).days
    line = f"最終監査: {raw} ({days}日前)"
    if days > AUDIT_INTERVAL_DAYS:
        line += " — 7日超過、監査を推奨(bash scripts/audit.sh)"
    return [line]
```

`cmd_stats` の `[再発候補]` ブロックの直前に挿入:

```python
    print()
    print("[監査]")
    for line in audit_status_lines():
        print(line)
```

- [ ] **Step 4: `cmd_report` に監査節を追加**

`cmd_report` の `## WARN` ブロックの直前に挿入:

```python
    print()
    print("## 監査")
    for line in audit_status_lines():
        print(line)
```

- [ ] **Step 5: `.gitignore` に追記**

`.feedback/.last-retro` ブロックの後に追加:

```
# 脆弱性監査の最終実行日(audit.sh が成功時に書く。マシンローカル)
.feedback/.last-audit
```

- [ ] **Step 6: テストと回帰を確認**

Run: `bash tests/test_stats.sh && bash tests/test_report.sh && bash tests/run_tests.sh`
Expected: すべて PASS(test_report.sh の既存アサートは監査節の追加で影響を受けない — 部分一致のため)

- [ ] **Step 7: コミット**

```bash
git add scripts/feedback_log.py .gitignore tests/test_stats.sh
git commit -m "feat: stats/report に最終監査日と期限切れ推奨を表示する"
```

---

### Task 3: M3 カバレッジ相乗り(test ステージへの計装)

**Files:**
- Modify: `scripts/check.sh`(Python 節 / Go 節 / Node 節)
- Test: `tests/test_check_p3.sh`(新規)

**Interfaces:**
- Consumes: 既存の `run_stage` / `npm_script_exists`
- Produces: Python は pytest-cov 検出時に `--cov` 系フラグを追加、Go は `go test -cover`、Node は `test:coverage` スクリプト存在時に別ステージ。**テストの二重実行はしない**

**計画の裁定(spec §3.5 からの調整 — Task 5 で spec に反映)**: 「閾値なし→数値を WARN で報告」は実装しない。数値の抽出には (a) テストの2回実行(M3 違反)か (b) run_stage 内部ログの解析(実装詳細への結合)が必要で、どちらも割に合わない。計装と閾値ゲート(pytest-cov が `--cov-fail-under` 宣言を exit code で強制)のみを実装し、数値はステージログに現れる。**spec 側も Task 5 でこの旨を改訂する。**

- [ ] **Step 1: 失敗テストを書く**

`tests/test_check_p3.sh` を作成:

```bash
#!/usr/bin/env bash
# test_check_p3.sh — P3 で追加する検査(カバレッジ相乗り・contract)の配線を検証する。
# 外部ツールは偽実行ファイル、Python モジュール検出は PYTHONPATH スタブで駆動する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$REPO/scripts/check.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

new_project() { # new_project <名前>
  local d="$WORK/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
make_fake() { # make_fake <名前> <exit> [記録ファイル]
  { echo '#!/usr/bin/env bash'
    echo 'case "$*" in *--version*) exit 0 ;; esac'
    [[ -n "${3:-}" ]] && echo "echo \"\$@\" >> \"$3\""
    echo "exit $2"
  } > "$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}

# --- Python: pytest-cov があるときだけ --cov が渡る ---
P1="$(new_project cov_on)"
printf '[project]\nname = "t"\n' > "$P1/pyproject.toml"
mkdir -p "$P1/tests" "$P1/covstub"
printf 'def test_x():\n    assert True\n' > "$P1/tests/test_x.py"
printf '' > "$P1/covstub/pytest_cov.py"   # import pytest_cov を通すスタブ
PARGS="$WORK/pytest_args.txt"; : > "$PARGS"
make_fake pytest 0 "$PARGS"
make_fake ruff 0
OUT="$(PATH="$FAKEBIN:$PATH" PYTHONPATH="$P1/covstub" bash "$CHECK" "$P1" 2>&1)"; RC=$?
assert_eq "0" "$RC" "pytest が成功すれば exit 0"
assert_contains "$(cat "$PARGS")" "--cov" "pytest-cov 検出時に --cov が渡る"
assert_contains "$(cat "$PARGS")" "--cov-report=term-missing" "行欠損レポートが渡る"

# pytest-cov が無い環境では従来どおりフラグ無し
P2="$(new_project cov_off)"
printf '[project]\nname = "t"\n' > "$P2/pyproject.toml"
mkdir -p "$P2/tests"
printf 'def test_x():\n    assert True\n' > "$P2/tests/test_x.py"
: > "$PARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P2" 2>&1)"; RC=$?
assert_eq "0" "$RC" "pytest-cov 無しでも exit 0"
assert_not_contains "$(cat "$PARGS")" "--cov" "未導入なら --cov を渡さない"

# --- Go: test ステージが -cover に置き換わる ---
P3="$(new_project cov_go)"
printf 'module t\n\ngo 1.21\n' > "$P3/go.mod"
GARGS="$WORK/go_args.txt"; : > "$GARGS"
{ echo '#!/usr/bin/env bash'
  echo 'case "$1" in version|--version) exit 0 ;; esac'
  echo "echo \"\$@\" >> \"$GARGS\""
  echo 'exit 0'
} > "$FAKEBIN/go"
chmod +x "$FAKEBIN/go"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P3" 2>&1)"; RC=$?
assert_eq "0" "$RC" "go test 成功で exit 0"
assert_contains "$(cat "$GARGS")" "test -cover" "go test に -cover が渡る(二重実行しない)"
rm -f "$FAKEBIN/go" "$FAKEBIN/pytest" "$FAKEBIN/ruff"

# --- Node: test:coverage スクリプトがあるときだけ別ステージ ---
P4="$(new_project cov_node)"
printf '{"name":"t","private":true,"scripts":{"test":"exit 0","test:coverage":"exit 0"}}\n' \
  > "$P4/package.json"
NARGS="$WORK/npm_args.txt"; : > "$NARGS"
make_fake npm 0 "$NARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P4" 2>&1)"; RC=$?
assert_eq "0" "$RC" "test:coverage が成功すれば exit 0"
assert_contains "$OUT" "node: npm run test:coverage" "test:coverage ステージが出る"
assert_contains "$(cat "$NARGS")" "run test:coverage" "スクリプトを呼んでいる"

P5="$(new_project cov_node_none)"
printf '{"name":"t","private":true,"scripts":{"test":"exit 0"}}\n' > "$P5/package.json"
: > "$NARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P5" 2>&1)"
assert_not_contains "$OUT" "test:coverage" "スクリプトが無ければステージを出さない"

assert_summary
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_check_p3.sh`
Expected: FAIL — `pytest-cov 検出時に --cov が渡る`(現行はフラグなしのため)

- [ ] **Step 3: Python 節の test ステージを差し替え**

現行のブロック(`if [[ -d tests ]] || ls ./test_*.py ./*_test.py ...` から `fi` まで)を、フラグ構築と `compgen` 条件に差し替え。`ls` の複数引数は1つでも欠けると全体が非0になるため、P2 の教訓に従いパターンごとに `compgen -G` で判定する:

```bash
  # カバレッジ相乗り(M3): テストを2回走らせず、計装フラグを足すだけ。
  # pytest-cov は設定の --cov-fail-under を exit code で強制するため、
  # 閾値宣言があるプロジェクトは自動的に FAIL ゲートになる
  PYTEST_ARGS=(-q -x)
  if python3 -c "import pytest_cov" >/dev/null 2>&1; then
    PYTEST_ARGS+=(--cov --cov-report=term-missing)
  fi
  if [[ -d tests ]] || compgen -G "test_*.py" >/dev/null 2>&1 \
     || compgen -G "*_test.py" >/dev/null 2>&1; then
    run_stage test "pytest" "python: pytest" pytest "${PYTEST_ARGS[@]}"
  fi
```

- [ ] **Step 4: Go 節の test ステージを差し替え**

`run_stage test  "go" "go: test"  go test ./...` を差し替え:

```bash
  # -cover は標準機能で計装のみ(追加プロセス無し)。coverage の数値は
  # ステージログに現れる。閾値ゲートは持たない(go test のexitはテスト合否のみ)
  run_stage test "go" "go: test" go test -cover ./...
```

- [ ] **Step 5: Node 節に test:coverage ステージを追加**

`npm_script_exists test && run_stage test ...` の行の直後に追加:

```bash
    # カバレッジ相乗り: test:coverage スクリプトを書いた=計装を宣言した。
    # 通常の test ステージはそのまま残す(両方走るのではなく coverage 側に統合したい
    # プロジェクトは test スクリプトを省けばよい)
    npm_script_exists test:coverage \
      && run_stage test "$PM" "node: $PM run test:coverage" "$PM" run test:coverage
```

- [ ] **Step 6: テストと回帰を確認**

Run: `bash tests/test_check_p3.sh && bash tests/run_tests.sh`
Expected: すべて PASS

- [ ] **Step 7: コミット**

```bash
git add scripts/check.sh tests/test_check_p3.sh
git commit -m "feat: カバレッジ計装をtestステージに相乗りさせる(二重実行なし)"
```

---

### Task 4: contract ステージ(API契約・破壊的変更)

**Files:**
- Modify: `scripts/check.sh`(横断チェック節の末尾に contract 節)
- Test: `tests/test_check_p3.sh`(追記)

**Interfaces:**
- Consumes: 既存の `run_stage`、git(`merge-base` / `show` でベースライン取得)
- Produces: 結果行 `contract: oasdiff` / `contract: cargo semver-checks`、ステージ名 `contract`。ベースライン規定ブランチは環境変数 `FEEDBACK_CONTRACT_BASE`(既定 `main`)

**設計の要点**: ベースラインは git から取る(ネットワーク不要・自己完結)。`merge-base HEAD <base>` が解決できなければ `HEAD`(=作業ツリーの未コミット変更のみ)を使う。spec §3.7 の検出条件に従い、spec ファイルは**ルートまたは api/ 直下の openapi.yaml/json**(複数候補は `for`+`[[ -f ]]` で最初に見つかった1つ — P2 の ls 複数引数の教訓)。

- [ ] **Step 1: 失敗テストを追記**

`tests/test_check_p3.sh` の `assert_summary` の直前に追加:

```bash
# --- contract: oasdiff(git ベースラインとの破壊的変更差分) ---
P6="$(new_project oas)"
( cd "$P6" && git checkout -q -b main )
printf 'openapi: 3.0.0\ninfo:\n  title: t\n  version: 1.0.0\n' > "$P6/openapi.yaml"
( cd "$P6" && git add openapi.yaml \
  && git -c user.email=t@t -c user.name=t commit -qm v1 )
# 破壊的変更(フィールド削除)を作業ツリーに載せる
printf 'openapi: 3.0.0\ninfo:\n  title: t\n' > "$P6/openapi.yaml"
OARGS="$WORK/oasdiff_args.txt"; : > "$OARGS"
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo "echo \"\$@\" >> \"$OARGS\""
  echo 'exit 1'
} > "$FAKEBIN/oasdiff"
chmod +x "$FAKEBIN/oasdiff"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P6" 2>&1)"; RC=$?
assert_eq "1" "$RC" "破壊的変更の検出で exit 1"
assert_contains "$OUT" "FAIL  contract: oasdiff" "FAILとして記録される"
# ベースラインと現行の2ファイルを渡していること
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
[[ "$(wc -w <"$OARGS" | tr -d ' ')" == "3" ]] || fail "oasdiff に breaking <base> <current> の3語が渡る(実際: $(cat "$OARGS"))"
assert_contains "$(cat "$OARGS")" "breaking" "breaking サブコマンドを使う"

# spec ファイルが無ければステージを出さない
P7="$(new_project oas_none)"
printf 'x\n' > "$P7/a.txt"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P7" 2>&1)"
assert_not_contains "$OUT" "contract: oasdiff" "specが無ければステージを出さない"

# 未コミットの新規 spec はベースラインが取れない → SKIP(FAILにしない)
P8="$(new_project oas_new)"
printf 'openapi: 3.0.0\n' > "$P8/openapi.yaml"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P8" 2>&1)"; RC=$?
assert_eq "0" "$RC" "ベースライン取得不能はブロックしない"
assert_contains "$OUT" "SKIP  contract: oasdiff" "理由付きSKIPになる"
rm -f "$FAKEBIN/oasdiff"

# --- contract: cargo semver-checks ---
P9="$(new_project semver)"
printf '[package]\nname = "t"\nversion = "0.1.0"\n\n[lib]\npath = "src/lib.rs"\n' > "$P9/Cargo.toml"
SARGS="$WORK/semver_args.txt"; : > "$SARGS"
# 偽 cargo: 通常サブコマンド(clippy/test等)は成功させ、semver-checks だけ失敗させる
# (全部落とすと rust: clippy 等もFAILになり、contract の配線検証が曖昧になるため)
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in'
  echo '  *--version*) exit 0 ;;'
  echo '  *"semver-checks check-release"*) echo "$@" >> "'"$SARGS"'"; exit 1 ;;'
  echo 'esac'
  echo "echo \"\$@\" >> \"$SARGS\""
  echo 'exit 0'
} > "$FAKEBIN/cargo"
chmod +x "$FAKEBIN/cargo"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P9" 2>&1)"; RC=$?
assert_eq "1" "$RC" "破壊的変更の検出で exit 1"
assert_contains "$OUT" "FAIL  contract: cargo semver-checks" "FAILとして記録される"
assert_contains "$(cat "$SARGS")" "check-release" "check-release を呼んでいる"

# [lib] が無い crate(バイナリのみ)は対象外
P10="$(new_project semver_bin)"
printf '[package]\nname = "t"\nversion = "0.1.0"\n' > "$P10/Cargo.toml"
: > "$SARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P10" 2>&1)"
assert_not_contains "$OUT" "cargo semver-checks" "[lib]が無ければステージを出さない"
rm -f "$FAKEBIN/cargo"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_check_p3.sh`
Expected: FAIL — `破壊的変更の検出で exit 1: expected [1] but got [0]`

- [ ] **Step 3: 横断チェック節の末尾(docs ブロックの後)に contract 節を追加**

```bash
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
  BASE_SHA="$(git merge-base HEAD "${FEEDBACK_CONTRACT_BASE:-main}" 2>/dev/null \
    || git rev-parse HEAD 2>/dev/null)"
  TMP_BASE="$(mktemp)"
  if [[ -n "$BASE_SHA" ]] && git show "$BASE_SHA:$OPENAPI_SPEC" > "$TMP_BASE" 2>/dev/null; then
    run_stage contract "-" "contract: oasdiff" oasdiff breaking "$TMP_BASE" "$OPENAPI_SPEC"
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
  run_stage contract "-" "contract: cargo semver-checks" cargo semver-checks check-release
fi
```

注意: `has cargo` は `cargo --version` を走らせる。偽 cargo の `--version` は exit 0 なのでこのテストでは通るが、本物の cargo 無し環境では `has cargo` が先に弾く(実害なし)。

- [ ] **Step 4: テストと回帰を確認**

Run: `bash tests/test_check_p3.sh && bash tests/run_tests.sh`
Expected: すべて PASS

- [ ] **Step 5: コミット**

```bash
git add scripts/check.sh tests/test_check_p3.sh
git commit -m "feat: API契約・破壊的変更検査(contractステージ)を追加"
```

---

### Task 5: 文書・spec 改訂注記・バージョン

**Files:**
- Modify: `docs/superpowers/specs/2026-08-16-check-scope-expansion-design.md`(§3.5 カバレッジの裁定反映)
- Modify: `scripts/README.md`(audit.sh・contract・coverage の記載)
- Modify: `README.md`(監査の案内)
- Modify: `skills/feedback-loop/SKILL.md`(監査のルーティング)
- Modify: `CLAUDE.md`(変更履歴)
- Modify: `.claude-plugin/plugin.json`(0.5.0 → 0.6.0)

**Interfaces:**
- Consumes: Task 1〜4 のすべての動作
- Produces: なし(リリース整備)

- [ ] **Step 1: spec §3.5 に裁定を反映**

§3.5 の表の後に以下を追記:

```markdown
**2026-08-17 の実装調整**: 「閾値なし → 数値を WARN で報告」は実装しない。数値の抽出にはテストの2回実行(M3 違反)か run_stage 内部ログの解析(実装詳細への結合)が必要で、割に合わないため。計装(pytest-cov 検出時の `--cov`、Go の `-cover`、Node の `test:coverage` スクリプト)と閾値ゲート(pytest-cov が `--cov-fail-under` を exit code で強制)のみを実装し、数値はステージログに現れる。
```

- [ ] **Step 2: `scripts/README.md` を更新**

(1) 構成ツリーの `feedback_log.py` 行の後に追加:

```text
├── audit.sh          # オンデマンド脆弱性監査(唯一のネットワーク検査。Stopフックからは呼ばれない)
```

(2) `check.sh` 節の「横断チェック」箇条書きの末尾に追加:

```markdown
- **API契約・破壊的変更**(`contract` ステージ): `openapi.yaml`/`openapi.json`(ルートまたは `api/`)があれば `oasdiff breaking` をベースライン(`git merge-base HEAD <FEEDBACK_CONTRACT_BASE:-main>`、解決不能なら `HEAD`)との差分で実行する。Rust は `[lib]` を持つ crate で `cargo semver-checks check-release`。いずれもオフラインで完結する
- **カバレッジ相乗り**: テストを2回走らせず計装フラグを足すだけ — Python は pytest-cov 検出時に `--cov --cov-report=term-missing`(設定の `--cov-fail-under` が自動的に FAIL ゲートになる)、Go は `go test -cover`、Node は `test:coverage` スクリプトがあるときだけ別ステージ
```

(3) 「ステージスキップ」のステージ名列挙に `contract` を追加:

```markdown
- **ステージスキップ**: `FEEDBACK_CHECK_SKIP` に指定できるステージ名は `lint` / `typecheck` / `test` / `build` / `format` / `security` / `docs` / `contract`。空白区切りで複数指定できる
```

(4) `feedback_log.py` 節の後に `audit.sh` 節を新設:

```markdown
### `audit.sh` — オンデマンド脆弱性監査(明示実行専用)

```bash
bash scripts/audit.sh [プロジェクトルート]
```

`check.sh` と異なり**ネットワークを使う**(pip-audit / npm audit --audit-level=high / govulncheck / cargo audit)。Stop フックからは呼ばれず、`feedback-loop` スキル等からの明示実行専用。成功時のみ `.feedback/.last-audit` に日付を書き、`stats` / `report` が「最終監査日」を表示する — **7日を超過するか未実行なら推奨行が出る**(WARN と同じ「ブロックせず、溜まったら見える」哲学)。失敗時にスタンプを書かないため、脆弱性が残っている間は推奨が消えない。
```

- [ ] **Step 3: `README.md` と `skills/feedback-loop/SKILL.md` を更新**

README の運用フロー図の `[報告]` 行の後に追加:

```
[監査]  bash scripts/audit.sh          — 脆弱性監査(オンデマンド・ネットワーク使用)
                                          成功時のみ .last-audit を更新 → report が期限を見る
```

feedback-loop の Phase 0 モード判定リストに1行追加(`_workspace/` 行の前):

```markdown
   - 脆弱性監査の依頼(「監査して」「脆弱性チェック」等)、または report で監査期限切れを指摘された → **監査実行**(`bash "${CLAUDE_PLUGIN_ROOT}/scripts/audit.sh"`。ネットワークを使うため Stop フックでは走らない)
```

- [ ] **Step 4: `CLAUDE.md` の変更履歴に1行追加**

```markdown
| 2026-08-17 | 適用範囲拡張 P3(重い検査群) | audit.sh / check.sh / feedback_log.py / tests | カバレッジ計装の相乗り、API契約差分(contract)、オンデマンド脆弱性監査と最終監査日の可視化。M2遅延実行は廃止し監査は Stop フックの外へ |
```

- [ ] **Step 5: バージョンを 0.6.0 に上げ、全体チェック**

`.claude-plugin/plugin.json` の `"version": "0.5.0",` を `"0.6.0",` に変更。

Run: `bash scripts/check.sh; echo "exit=$?"` と `bash tests/run_tests.sh 2>&1 | tail -2`
Expected: check.sh は exit 0(このリポジトリは openapi/cargo を持たないため contract は出ず、既存の WARN 1件のみ)。テスト全 PASS

- [ ] **Step 6: コミット**

```bash
git add docs/superpowers/specs/2026-08-16-check-scope-expansion-design.md scripts/README.md README.md skills/feedback-loop/SKILL.md CLAUDE.md .claude-plugin/plugin.json
git commit -m "docs: P3(重い検査群)の文書を整え v0.6.0 に上げる"
```

---

## 完了後の自省(実行エージェント向け)

計画全体を終えたら、このセッションで共有アーティファクトを変えるべき出来事があったかを1問自省する(CLAUDE.md のトリガーに従う)。実装中に設計と実際が食い違った場合は spec 側も更新してから完了する。

P1〜P3 の全フェーズ完了後、設計書 §3 の検査カタログがすべて実装済みになる。残る未実装は設計書が明示的に見送ったもの(tflint / kubeconform / 依存監査のStopフック載せ等)のみ。
