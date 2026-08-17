# 適用範囲拡張 P2(速い検査群)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ネットワークを使わず数秒で終わる検査を7系統追加し、秘密情報・設計制約・依存整合性・フォーマット・デッドコード・ドキュメント整合性を自動フィードバックの対象にする。

**Architecture:** P1 で作った `run_stage`(FAIL)/ `run_stage_soft`(WARN)の二本立てに新しい検査を載せる。判定強度は**宣言ゲート**で決める — プロジェクトが設定ファイルで意図を宣言していれば FAIL、していなければ WARN または SKIP。ツールは一切自動インストールせず、未導入は理由付き SKIP。内部リンク検証だけは外部依存ゼロの自前実装(`lib.sh`)とする。

**Tech Stack:** Bash(`set -u`、lib.sh 共有関数)、Python 3 標準ライブラリ。外部ツールは**あれば使う**(secretlint / dockerfilelint / knip / prettier / actionlint / hadolint / import-linter / deptry / vulture)。

**Spec:** [docs/superpowers/specs/2026-08-16-check-scope-expansion-design.md](../specs/2026-08-16-check-scope-expansion-design.md)

## Global Constraints

- **P-A(非交渉)**: ハーネスは決してツールを自動インストールしない。未導入は SKIP と理由表示に留める
- **P-B**: OS依存の導入手段を前提にしない。npm ツールは `npx --no-install` で解決し、**ネットワークから取得させない**
- 新規の実行時依存を足さない(bash / python3 標準ライブラリのみ。外部ツールは任意)
- **秘密の値を出力に出さない**: secretlint は既定でマスクする — `--no-maskSecrets` を**渡してはならない**。gitleaks は `--redact` を省略不可(spec §8.3 実測)
- WARN は exit code を 0 のままにする。exit 1 は FAIL のみ
- 宣言ゲート: 設定ファイルがある → FAIL / 無い → WARN か SKIP(検査ごとに spec §3 の表で決まっている)
- テストは `tests/test_*.sh` + `tests/assert.sh` 規約。期待値はリテラル、判定は自前カウンタ + `assert_summary` の明示 exit
- 外部ツールはテストで **PATH に偽実行ファイルを置いて**駆動する(`tests/test_on_stop_skip.sh` が確立した手法)
- コメントは「なぜ」を書く。コミットメッセージは日本語 conventional commits
- 未関係の未コミット削除(`docs/superpowers/` 配下の 2026-08-12-plugin-packaging*)を**コミットに含めない** — 各タスクのコミット手順に列挙したファイルだけを `git add` する

## ファイル構成

| ファイル | 責務 | 変更 |
|---|---|---|
| `scripts/lib.sh` | 共有判定ロジック | 内部リンク検証 `harness_check_md_links` を追加 |
| `scripts/check.sh` | フルチェックと結果集計 | 横断チェック節に docs/security を追加、各スタック節に検査を追加 |
| `scripts/README.md` | スクリプト仕様 | 検査一覧・ステージ・必要ツール |
| `tests/test_md_links.sh` | 内部リンク検証のテスト | 新規 |
| `tests/test_check_p2.sh` | 外部ツール呼び出し契約のテスト | 新規 |

---

### Task 1: 内部リンク検証(自前実装・外部依存ゼロ)

**Files:**
- Modify: `scripts/lib.sh`(末尾に追加)
- Test: `tests/test_md_links.sh`(新規)

**Interfaces:**
- Consumes: 既存の `has()`
- Produces: `harness_check_md_links <file...>` — リンク切れがあれば `path: リンク先が見つかりません: <target>` を stdout に出し非0。python3 不在時は検証せず成功。Task 2 が `check.sh` から呼ぶ

- [ ] **Step 1: 失敗テストを書く**

`tests/test_md_links.sh` を作成:

```bash
#!/usr/bin/env bash
# test_md_links.sh — Markdown の内部リンク切れ検出を検証する。
#
# 「READMEに書いたパスが実在しない」「ファイルを移動してリンクが腐る」は
# 実際に頻出する欠陥だが、外部ツール無しで捕まえられる。
# 誤検出は正当な文書で完了をブロックするため、除外側の固定を厚くする:
# コードブロック内・コードスパン内の "[text](path)" 風の記述は対象外。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
. "$REPO/scripts/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/docs/sub"

ok() { # ok <ファイル> <ラベル> — 検証が成功(exit 0)することを期待
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  local out
  if ! out="$(harness_check_md_links "$1" 2>&1)"; then
    fail "$2: 誤検出した (出力: $out)"
  fi
}
ng() { # ng <ファイル> <ラベル> — 検証が失敗(非0)することを期待
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  if harness_check_md_links "$1" >/dev/null 2>&1; then
    fail "$2: 壊れたリンクを検出しなかった"
  fi
}

# --- 実在するリンクは通す ---
printf 'target\n' > "$WORK/docs/target.md"
printf 'see [t](target.md)\n' > "$WORK/docs/good.md"
ok "$WORK/docs/good.md" "実在する相対リンクを通す"

# --- 壊れたリンクを検出する ---
printf 'see [x](missing.md)\n' > "$WORK/docs/broken.md"
ng "$WORK/docs/broken.md" "存在しない相対リンクを検出する"

# 出力に対象ファイルとリンク先が含まれる(何を直せばよいか分かる)
DIAG="$(harness_check_md_links "$WORK/docs/broken.md" 2>/dev/null || true)"
assert_contains "$DIAG" "broken.md" "診断に対象ファイル名が出る"
assert_contains "$DIAG" "missing.md" "診断にリンク先が出る"

# --- 相対解決は「そのファイルの位置」を基準にする ---
printf 'up [t](../target.md)\n' > "$WORK/docs/sub/rel.md"
ok "$WORK/docs/sub/rel.md" "親ディレクトリへの相対リンクを解決する"

# --- 検証対象外(ネットワーク・アンカー・絶対パス) ---
printf '[a](https://example.com) [b](http://example.com) [c](mailto:x@example.com)\n' > "$WORK/docs/ext.md"
ok "$WORK/docs/ext.md" "外部URL・mailtoは検証しない"
printf '[a](#section)\n' > "$WORK/docs/anchor.md"
ok "$WORK/docs/anchor.md" "アンカーのみのリンクは検証しない"
printf '[a](/abs/path.md)\n' > "$WORK/docs/abs.md"
ok "$WORK/docs/abs.md" "絶対パスは検証しない(サイト設計依存)"

# --- アンカー付きは「ファイル部分だけ」を見る ---
printf 'see [t](target.md#heading)\n' > "$WORK/docs/frag.md"
ok "$WORK/docs/frag.md" "アンカー付きリンクはファイル部分で判定する"
printf 'see [x](missing.md#heading)\n' > "$WORK/docs/fragbad.md"
ng "$WORK/docs/fragbad.md" "アンカー付きでも実体が無ければ検出する"

# --- 画像も対象 ---
printf '![img](missing.png)\n' > "$WORK/docs/img.md"
ng "$WORK/docs/img.md" "画像リンクも検証する"

# --- 誤検出しないこと(ここが本丸) ---
# コードブロック内の記述は説明用であって実リンクではない
{ printf 'text\n\n'; printf '```markdown\n'; printf '[example](does-not-exist.md)\n'; printf '```\n'; } \
  > "$WORK/docs/fence.md"
ok "$WORK/docs/fence.md" "コードブロック内のリンク風記述は検証しない"

# コードスパン内も同様
printf 'write `[text](path)` like this\n' > "$WORK/docs/span.md"
ok "$WORK/docs/span.md" "コードスパン内のリンク風記述は検証しない"

# タイトル付きリンク [text](path "title")
printf 'see [t](target.md "タイトル")\n' > "$WORK/docs/title.md"
ok "$WORK/docs/title.md" "タイトル付きリンクを正しく解釈する"

# --- 複数ファイル指定: 1件でも壊れていれば非0 ---
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
if harness_check_md_links "$WORK/docs/good.md" "$WORK/docs/broken.md" >/dev/null 2>&1; then
  fail "複数ファイル指定で壊れたリンクを見逃した"
fi

# --- 引数ゼロは成功 ---
ok_zero() {
  ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
  harness_check_md_links >/dev/null 2>&1 || fail "引数ゼロで失敗した"
}
ok_zero

assert_summary
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_md_links.sh`
Expected: FAIL — `harness_check_md_links: command not found` により全チェックが失敗する

- [ ] **Step 3: `scripts/lib.sh` の末尾に実装を追加**

```bash
# harness_check_md_links <file...> — Markdown の内部リンク切れを検出する。
#
# 外部URLは検証しない(ネットワークを使わない原則)。検証するのは相対パスだけで、
# 「READMEに書いたパスが実在しない」「移動でリンクが腐った」を外部依存ゼロで捕まえる。
#
# 誤検出を出すと正当な文書で完了がブロックされるため、除外を厚くする:
# コードブロック(``` / ~~~)とコードスパン(`...`)の中はリンクとして扱わない
# (文書がリンク記法そのものを説明している箇所を拾わないため)。
harness_check_md_links() {
  has python3 || return 0
  [[ $# -eq 0 ]] && return 0
  python3 -c '
import re, sys
from pathlib import Path

FENCE = re.compile(r"^\s*(```|~~~)")
# [text](path) と ![alt](path)。パスに空白は含めず、後続の "title" は捨てる
LINK = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
SPAN = re.compile(r"`[^`]*`")

bad = 0
for p in sys.argv[1:]:
    path = Path(p)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        print(f"{p}: {e}")
        bad = 1
        continue
    in_fence = False
    for line in text.splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in LINK.finditer(SPAN.sub("", line)):
            target = m.group(1)
            # 外部URL・アンカーのみ・絶対パスは対象外
            if target.startswith(("http://", "https://", "mailto:", "#", "/")):
                continue
            # アンカー付きはファイル部分だけを見る(見出しの正規化はツール依存のため踏み込まない)
            target = target.split("#")[0]
            if not target:
                continue
            if not (path.parent / target).exists():
                print(f"{p}: リンク先が見つかりません: {target}")
                bad = 1
sys.exit(bad)
' "$@"
}
```

- [ ] **Step 4: テストを実行して通ることを確認**

Run: `bash tests/test_md_links.sh`
Expected: PASS(exit 0・無出力)

- [ ] **Step 5: 実データで誤検出が無いことを確認**

Run: `bash -c '. scripts/lib.sh; harness_check_md_links $(git ls-files "*.md" | tr "\n" " ") ; echo "exit=$?"'`
Expected: `exit=0`(このリポジトリの30個のMarkdownに実リンク6件があり、いずれも有効。**日本語ファイル名を含むため、引数展開の失敗が出たら Task 2 のファイル収集方法で対処する**)

- [ ] **Step 6: 既存テストの回帰確認**

Run: `bash tests/run_tests.sh`
Expected: 全 PASS(lib.sh への追加のみ)

- [ ] **Step 7: コミット**

```bash
git add scripts/lib.sh tests/test_md_links.sh
git commit -m "feat: Markdown の内部リンク切れ検出を共有関数に追加"
```

---

### Task 2: `check.sh` に docs ステージを追加

**Files:**
- Modify: `scripts/check.sh`(横断チェック節)
- Test: `tests/test_check_p2.sh`(新規)

**Interfaces:**
- Consumes: Task 1 の `harness_check_md_links`、既存の `list_files` / `run_stage`
- Produces: 結果行 `PASS/FAIL  docs: 内部リンク`、ステージ名 `docs`。Task 3 以降が同じ横断節に追記する

**重要な前提(実測済み)**: `git ls-files` は非ASCIIファイル名を**引用符付き8進エスケープ**で出力する。このリポジトリは日本語ファイル名(`.feedback/log/*.md`)を持つため、既存の `list_files` の出力をそのまま Python に渡すと `FileNotFoundError` になる。`core.quotePath=false` を指定して生のパスを出させる。

- [ ] **Step 1: 失敗テストを書く**

`tests/test_check_p2.sh` を作成:

```bash
#!/usr/bin/env bash
# test_check_p2.sh — P2 で追加した検査(docs / security / 依存整合性 / 各種lint)が
# check.sh に正しく配線されているかを検証する。
#
# 外部ツールは PATH に偽実行ファイルを置いて駆動する。検証するのはツールの
# 検出精度ではなく「検出条件・引数・終了コードの写像」という配線の契約である。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$REPO/scripts/check.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

new_project() { # new_project <名前> — 空のgitプロジェクトを作りパスを返す
  local d="$WORK/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}

# --- docs: 内部リンク ---
P1="$(new_project docs_broken)"
printf 'see [x](missing.md)\n' > "$P1/README.md"
OUT="$(bash "$CHECK" "$P1" 2>&1)"; RC=$?
assert_eq "1" "$RC" "リンク切れで exit 1 になる"
assert_contains "$OUT" "docs: 内部リンク" "docs ステージが結果に出る"
assert_contains "$OUT" "missing.md" "失敗ログにリンク先が出る"

P2="$(new_project docs_ok)"
printf 'target\n' > "$P2/target.md"
printf 'see [t](target.md)\n' > "$P2/README.md"
OUT="$(bash "$CHECK" "$P2" 2>&1)"; RC=$?
assert_eq "0" "$RC" "リンクが有効なら exit 0"
assert_contains "$OUT" "PASS  docs: 内部リンク" "PASSとして記録される"

# --- Markdown が無ければステージ自体を出さない ---
P3="$(new_project no_md)"
printf 'hello\n' > "$P3/note.txt"
OUT="$(bash "$CHECK" "$P3" 2>&1)"
assert_not_contains "$OUT" "docs: 内部リンク" "対象が無ければステージを出さない"

# --- 非ASCIIファイル名でも落ちない(git ls-files のエスケープ対策の回帰) ---
P4="$(new_project nonascii)"
printf 'target\n' > "$P4/対象.md"
printf 'see [t](対象.md)\n' > "$P4/日本語ファイル名.md"
OUT="$(bash "$CHECK" "$P4" 2>&1)"; RC=$?
assert_eq "0" "$RC" "日本語ファイル名でも誤検出しない"
assert_contains "$OUT" "PASS  docs: 内部リンク" "日本語ファイル名を検証対象にできる"

assert_summary
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_check_p2.sh`
Expected: FAIL — `リンク切れで exit 1 になる: expected [1] but got [0]`(docs ステージが未実装のため)

- [ ] **Step 3: `list_files` を非ASCII対応にする**

`scripts/check.sh` の `list_files` の `git ls-files` 行を差し替える:

```bash
    # -c core.quotePath=false: 非ASCIIファイル名を8進エスケープ("\350\250...")で
    # 出さず生のパスで出す。日本語ファイル名を持つプロジェクトで、受け取り側が
    # ファイルを開けなくなる(実測: .feedback/log/*.md で FileNotFoundError)
    git -c core.quotePath=false ls-files --cached --others --exclude-standard "$1"
```

- [ ] **Step 4: 横断チェック節に docs ステージを追加**

`scripts/check.sh` の横断チェック節の末尾(YAML のブロックの後、`# ---------- 汎用フォールバック ----------` の直前)に追加:

```bash
# ドキュメントの内部リンク。外部URLは検証しない(ネットワークを使わない原則)。
# リンク先が実在しないのは好みの問題ではなく事実誤りなので、常に FAIL とする
MD_FILES=()
while IFS= read -r f; do
  [[ -n "$f" ]] && MD_FILES+=("$f")
done < <(list_files '*.md')
if [[ ${#MD_FILES[@]} -gt 0 ]]; then
  run_stage docs "-" "docs: 内部リンク" harness_check_md_links "${MD_FILES[@]}"
fi
```

- [ ] **Step 5: テストを実行して通ることを確認**

Run: `bash tests/test_check_p2.sh`
Expected: PASS

- [ ] **Step 6: 既存テストの回帰確認と自己適用**

Run: `bash tests/run_tests.sh && bash scripts/check.sh 2>&1 | grep -E "docs:|ALL PASS"`
Expected: テスト全 PASS。`PASS  docs: 内部リンク` が出て、最終行は `ALL PASS (1件WARN — 未対応の指摘があります)`(既存の ruff format WARN のみ)

- [ ] **Step 7: コミット**

```bash
git add scripts/check.sh tests/test_check_p2.sh
git commit -m "feat: check.sh に内部リンク検証(docsステージ)を追加し非ASCIIパスに対応"
```

---

### Task 3: 秘密情報スキャン(security ステージ)

**Files:**
- Modify: `scripts/check.sh`(横断チェック節)
- Test: `tests/test_check_p2.sh`(追記)

**Interfaces:**
- Consumes: Task 2 が作った横断チェック節の構造
- Produces: 結果行 `PASS/FAIL/SKIP  security: secretlint` と `security: gitleaks`、ステージ名 `security`

**実測に基づく設計(spec §8.3)**:
- secretlint は `.secretlintrc.*` が**無いと exit 2 で実行不能**。よって「設定あり → 実行(FAIL判定)/ 無し → SKIP」とする(WARN にはできない)
- マスクは**既定で有効**。`--no-maskSecrets` を渡してはならない(`--maskSecrets` というオプションは存在しない)
- gitleaks はバージョン差が大きいため、`--no-git` と `--redact` の両方がヘルプに出ることをプローブしてから使う

- [ ] **Step 1: 失敗テストを追記**

`tests/test_check_p2.sh` の `assert_summary` の直前に追加:

```bash
# --- security: secretlint(設定ゲート) ---
# 偽ツールを PATH に置く。検証するのは検出精度ではなく配線の契約
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
make_fake() { # make_fake <名前> <exit> [記録ファイル]
  { echo '#!/usr/bin/env bash'
    [[ -n "${3:-}" ]] && echo "echo \"\$@\" >> \"$3\""
    echo "exit $2"
  } > "$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}

# 設定が無ければ実行しない(secretlint は設定なしでは exit 2 で落ちるため)
P5="$(new_project sl_nocfg)"
printf 'x\n' > "$P5/a.txt"
make_fake npx 1
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P5" 2>&1)"; RC=$?
assert_eq "0" "$RC" "secretlint 設定が無ければ完了をブロックしない"
assert_contains "$OUT" "SKIP  security: secretlint" "設定が無ければ理由付きSKIP"
assert_contains "$OUT" ".secretlintrc" "SKIP理由に設定ファイル名が出る"

# 設定があれば実行し、失敗は FAIL になる
P6="$(new_project sl_cfg)"
printf 'x\n' > "$P6/a.txt"
printf '{"rules":[]}' > "$P6/.secretlintrc.json"
ARGS="$WORK/npx_args.txt"; : > "$ARGS"
make_fake npx 1 "$ARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P6" 2>&1)"; RC=$?
assert_eq "1" "$RC" "設定があり検出されたら exit 1"
assert_contains "$OUT" "FAIL  security: secretlint" "FAILとして記録される"
# 秘密の値を出さない契約: マスク無効化オプションを渡していないこと
assert_not_contains "$(cat "$ARGS")" "--no-maskSecrets" "マスクを無効化する引数を渡さない"
assert_contains "$(cat "$ARGS")" "secretlint" "secretlint を呼んでいる"

# 設定があり問題が無ければ PASS
P7="$(new_project sl_pass)"
printf 'x\n' > "$P7/a.txt"
printf '{"rules":[]}' > "$P7/.secretlintrc.json"
make_fake npx 0
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P7" 2>&1)"; RC=$?
assert_eq "0" "$RC" "問題が無ければ exit 0"
assert_contains "$OUT" "PASS  security: secretlint" "PASSとして記録される"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_check_p2.sh`
Expected: FAIL — `設定が無ければ理由付きSKIP: [SKIP  security: secretlint] が出力に含まれない`

- [ ] **Step 3: 横断チェック節に secretlint を追加**

`scripts/check.sh` の横断チェック節の docs ブロックの後に追加:

```bash
# 秘密情報スキャン。secretlint は .secretlintrc.* が無いと exit 2 で実行できない
# (実測)ため、設定の有無をゲートにする。設定を書いた=チームが検査を選んだ、
# という宣言なので FAIL でよい。マスクは既定で有効 — 無効化する引数は渡さない
# (失敗ログはエージェントのコンテキストに入るため、秘密の値を拡散させない)
if ls .secretlintrc.* >/dev/null 2>&1; then
  if has npx && npx --no-install secretlint --version >/dev/null 2>&1; then
    run_stage security "-" "security: secretlint" npx --no-install secretlint "**/*"
  else
    RESULTS+=("SKIP  security: secretlint (secretlint 未インストール)")
  fi
else
  RESULTS+=("SKIP  security: secretlint (.secretlintrc.* が無い — 設定すると検査が有効になります)")
fi
```

- [ ] **Step 4: テストを実行して通ることを確認**

Run: `bash tests/test_check_p2.sh`
Expected: PASS

- [ ] **Step 5: gitleaks を追加(代替手段・任意)**

同じブロックの直後に追加:

```bash
# gitleaks があれば併用する(OS固有バイナリのため任意扱い)。バージョン差が
# 大きく v8.19 で detect が再編されたため、必要なフラグがヘルプに出ることを
# 確認してから使う。--redact は省略不可(秘密の値を出力に出さない)
if has gitleaks; then
  GL_HELP="$(gitleaks detect --help 2>&1)"
  if [[ "$GL_HELP" == *"--no-git"* && "$GL_HELP" == *"--redact"* ]]; then
    run_stage security "-" "security: gitleaks" \
      gitleaks detect --no-git --redact --no-banner -s .
  else
    RESULTS+=("SKIP  security: gitleaks (この版は detect --no-git/--redact に非対応)")
  fi
fi
```

- [ ] **Step 6: gitleaks のテストを追記**

`tests/test_check_p2.sh` の `assert_summary` の直前に追加:

```bash
# --- security: gitleaks(フラグ対応のプローブ) ---
# 対応版: ヘルプに両フラグが出る → 実行される
P8="$(new_project gl_ok)"
printf 'x\n' > "$P8/a.txt"
GLARGS="$WORK/gl_args.txt"; : > "$GLARGS"
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in'
  echo '  *--help*) echo "  --no-git  scan without git"; echo "  --redact  redact secrets"; exit 0 ;;'
  echo '  --version) exit 0 ;;'
  echo 'esac'
  echo "echo \"\$@\" >> \"$GLARGS\""
  echo 'exit 1'
} > "$FAKEBIN/gitleaks"
chmod +x "$FAKEBIN/gitleaks"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P8" 2>&1)"; RC=$?
assert_eq "1" "$RC" "gitleaks が検出したら exit 1"
assert_contains "$OUT" "FAIL  security: gitleaks" "FAILとして記録される"
assert_contains "$(cat "$GLARGS")" "--redact" "秘密を伏せる --redact を必ず渡す"

# 非対応版: ヘルプにフラグが無い → 誤検出を避けて SKIP
P9="$(new_project gl_old)"
printf 'x\n' > "$P9/a.txt"
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--help*) echo "  usage: gitleaks"; exit 0 ;; --version) exit 0 ;; esac'
  echo 'exit 1'
} > "$FAKEBIN/gitleaks"
chmod +x "$FAKEBIN/gitleaks"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P9" 2>&1)"; RC=$?
assert_eq "0" "$RC" "非対応版では完了をブロックしない"
assert_contains "$OUT" "SKIP  security: gitleaks" "非対応版は理由付きSKIP"
rm -f "$FAKEBIN/gitleaks"
```

- [ ] **Step 7: テストと回帰を確認**

Run: `bash tests/test_check_p2.sh && bash tests/run_tests.sh`
Expected: 両方 PASS

- [ ] **Step 8: コミット**

```bash
git add scripts/check.sh tests/test_check_p2.sh
git commit -m "feat: 秘密情報スキャン(securityステージ)を設定ゲート付きで追加"
```

---

### Task 4: CI設定・Dockerfile lint

**Files:**
- Modify: `scripts/check.sh`(横断チェック節)
- Test: `tests/test_check_p2.sh`(追記)

**Interfaces:**
- Consumes: Task 2/3 の横断チェック節
- Produces: 結果行 `lint` ステージの `ci: actionlint` と `docker: dockerfilelint` / `docker: hadolint`

**実測(spec §8.3)**: dockerfilelint は問題あり **exit 2** / 問題なし exit 0。`run_stage` は非0を FAIL とするため、そのまま扱える。

- [ ] **Step 1: 失敗テストを追記**

`tests/test_check_p2.sh` の `assert_summary` の直前に追加:

```bash
# --- ci: actionlint(ワークフローがある時だけ) ---
P10="$(new_project ci_ws)"
mkdir -p "$P10/.github/workflows"
printf 'name: t\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' \
  > "$P10/.github/workflows/ci.yml"
make_fake actionlint 1
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P10" 2>&1)"; RC=$?
assert_eq "1" "$RC" "actionlint の失敗は exit 1"
assert_contains "$OUT" "FAIL  ci: actionlint" "FAILとして記録される"

# ワークフローが無ければ何も出さない
P11="$(new_project ci_none)"
printf 'x\n' > "$P11/a.txt"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P11" 2>&1)"
assert_not_contains "$OUT" "ci: actionlint" "ワークフローが無ければステージを出さない"
rm -f "$FAKEBIN/actionlint"

# --- docker: dockerfilelint(exit 2 を FAIL として扱う) ---
P12="$(new_project df)"
printf 'FROM node:latest\n' > "$P12/Dockerfile"
DFARGS="$WORK/df_args.txt"; : > "$DFARGS"
make_fake npx 2 "$DFARGS"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P12" 2>&1)"; RC=$?
assert_eq "1" "$RC" "dockerfilelint の exit 2 を FAIL として扱う"
assert_contains "$OUT" "FAIL  docker: dockerfilelint" "FAILとして記録される"
assert_contains "$(cat "$DFARGS")" "Dockerfile" "対象ファイルを渡している"

# サブディレクトリの Dockerfile も拾う
P13="$(new_project df_sub)"
mkdir -p "$P13/docker"
printf 'FROM node:20-alpine\n' > "$P13/docker/Dockerfile"
make_fake npx 0
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P13" 2>&1)"; RC=$?
assert_eq "0" "$RC" "問題が無ければ exit 0"
assert_contains "$OUT" "PASS  docker: dockerfilelint" "サブディレクトリの Dockerfile も検査する"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_check_p2.sh`
Expected: FAIL — `actionlint の失敗は exit 1: expected [1] but got [0]`

- [ ] **Step 3: 横断チェック節に追加**

`scripts/check.sh` の横断チェック節の secretlint/gitleaks ブロックの後に追加:

```bash
# GitHub Actions のワークフロー。YAML構文は上で検証済みなので、ここで見るのは
# アクションの使い方(存在しない入力・シェルの誤り等)。actionlint は Go 製
# バイナリのため任意扱い(あれば使う)
if compgen -G ".github/workflows/*.y*ml" >/dev/null 2>&1; then
  if has actionlint; then
    run_stage lint "-" "ci: actionlint" actionlint
  else
    RESULTS+=("SKIP  ci: actionlint (actionlint 未インストール)")
  fi
fi

# Dockerfile。git pathspec の * は / を跨ぐため 'Dockerfile*' 単独では
# ルート直下しか当たらない(*.py が全階層に当たるのとは非対称)
DOCKER_FILES=()
while IFS= read -r f; do
  [[ -n "$f" ]] && DOCKER_FILES+=("$f")
done < <(list_files 'Dockerfile*'; list_files '*/Dockerfile*')
# 上の2つのグロブは Dockerfile がリポジトリ直下にある場合に重複しない
# (git pathspec の 'Dockerfile*' はルート直下のみ、'*/Dockerfile*' は1階層以上)。
# ただし git 外(find フォールバック)では両方が同じファイルを拾うため重複排除する
if [[ ${#DOCKER_FILES[@]} -gt 1 ]]; then
  IFS=$'\n' read -r -d '' -a DOCKER_FILES < <(printf '%s\n' "${DOCKER_FILES[@]}" | sort -u && printf '\0')
fi
if [[ ${#DOCKER_FILES[@]} -gt 0 ]]; then
  if has npx && npx --no-install dockerfilelint --version >/dev/null 2>&1; then
    # dockerfilelint は問題があると exit 2 を返す(実測)。run_stage は非0を
    # FAIL とするため、そのまま扱える
    run_stage lint "-" "docker: dockerfilelint" \
      npx --no-install dockerfilelint "${DOCKER_FILES[@]}"
  elif has hadolint; then
    run_stage lint "-" "docker: hadolint" hadolint "${DOCKER_FILES[@]}"
  else
    RESULTS+=("SKIP  docker: lint (dockerfilelint / hadolint 未インストール)")
  fi
fi
```

- [ ] **Step 4: テストを実行して通ることを確認**

Run: `bash tests/test_check_p2.sh && bash tests/run_tests.sh`
Expected: 両方 PASS

- [ ] **Step 5: コミット**

```bash
git add scripts/check.sh tests/test_check_p2.sh
git commit -m "feat: CI設定(actionlint)と Dockerfile lint を追加"
```

---

### Task 5: 依存の実在性・整合性(オフライン)

**Files:**
- Modify: `scripts/check.sh`(Node 節 / Python 節 / Go 節 / Rust 節)
- Test: `tests/test_check_p2.sh`(追記)

**Interfaces:**
- Consumes: 各スタック節の既存構造
- Produces: 結果行 `lint` ステージの `node: npm ls` / `python: deptry` / `go: mod verify` / `rust: metadata`

**設計の要点**: これは脆弱性監査(P3)とは別物で、**ネットワークを使わない**。「AIが存在しないパッケージ名を書く」「宣言と実体がずれる」を検出する。`node_modules` が無い場合は SKIP — 未インストールを欠陥と呼ばない。

- [ ] **Step 1: 失敗テストを追記**

`tests/test_check_p2.sh` の `assert_summary` の直前に追加:

```bash
# --- 依存の実在性: node_modules があるときだけ npm ls を走らせる ---
P14="$(new_project dep_node)"
printf '{"name":"t","version":"1.0.0","private":true}\n' > "$P14/package.json"
mkdir -p "$P14/node_modules"
NPMARGS="$WORK/npm_args.txt"; : > "$NPMARGS"
{ echo '#!/usr/bin/env bash'
  echo 'case "$1" in --version) exit 0 ;; esac'
  echo "echo \"\$@\" >> \"$NPMARGS\""
  echo 'case "$1" in ls) exit 1 ;; esac'
  echo 'exit 0'
} > "$FAKEBIN/npm"
chmod +x "$FAKEBIN/npm"
{ echo '#!/usr/bin/env bash'; echo 'exit 0'; } > "$FAKEBIN/node"
chmod +x "$FAKEBIN/node"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P14" 2>&1)"; RC=$?
assert_eq "1" "$RC" "npm ls の失敗は exit 1"
assert_contains "$OUT" "FAIL  node: npm ls" "宣言と実体の不一致をFAILにする"

# node_modules が無ければ SKIP(未インストールを欠陥と呼ばない)
P15="$(new_project dep_node_noinstall)"
printf '{"name":"t","version":"1.0.0","private":true}\n' > "$P15/package.json"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P15" 2>&1)"; RC=$?
assert_eq "0" "$RC" "node_modules 不在で完了をブロックしない"
assert_contains "$OUT" "SKIP  node: npm ls" "node_modules 不在は理由付きSKIP"
rm -f "$FAKEBIN/npm" "$FAKEBIN/node"

# --- Go: go.sum があれば go mod verify ---
P16="$(new_project dep_go)"
printf 'module t\n\ngo 1.21\n' > "$P16/go.mod"
printf 'x\n' > "$P16/go.sum"
GOARGS="$WORK/go_args.txt"; : > "$GOARGS"
{ echo '#!/usr/bin/env bash'
  echo 'case "$1" in version|--version) exit 0 ;; esac'
  echo "echo \"\$@\" >> \"$GOARGS\""
  echo 'case "$*" in "mod verify") exit 1 ;; esac'
  echo 'exit 0'
} > "$FAKEBIN/go"
chmod +x "$FAKEBIN/go"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P16" 2>&1)"; RC=$?
assert_eq "1" "$RC" "go mod verify の失敗は exit 1"
assert_contains "$OUT" "FAIL  go: mod verify" "FAILとして記録される"
assert_contains "$(cat "$GOARGS")" "mod verify" "go mod verify を呼んでいる"
rm -f "$FAKEBIN/go"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_check_p2.sh`
Expected: FAIL — `npm ls の失敗は exit 1: expected [1] but got [0]`

- [ ] **Step 3: Node 節に依存整合性を追加**

`scripts/check.sh` の Node 節、`npm_script_exists build && ...` の行の直後に追加:

```bash
    # 依存の実在性・整合性(ネットワーク不使用)。宣言と実体のずれ・欠損を
    # 検出する — AIが存在しないパッケージ名を書く欠陥はここで捕まる。
    # node_modules が無いのは「未インストール」であって欠陥ではないので SKIP
    if [[ -d node_modules ]]; then
      run_stage lint "$PM" "node: npm ls" "$PM" ls --all
    else
      RESULTS+=("SKIP  node: npm ls (node_modules 未インストール)")
    fi
```

- [ ] **Step 4: Python 節に deptry を追加**

Python 節のマニフェスト分岐、`run_stage test "pytest" ...` の行の直後に追加:

```bash
  # 宣言に無い import・未使用依存の検出(ネットワーク不使用)。
  # 誤検出の可能性があるため、設定の宣言があるときだけ FAIL にする
  if has deptry; then
    if grep -q "^\[tool\.deptry" pyproject.toml 2>/dev/null; then
      run_stage lint "deptry" "python: deptry" deptry .
    else
      run_stage_soft lint "deptry" "python: deptry" deptry .
    fi
  fi
```

- [ ] **Step 5: Go 節と Rust 節に追加**

Go 節の `run_stage test "go" "go: test" go test ./...` の直後に追加:

```bash
  # go.sum のチェックサム検証(ネットワーク不使用)。依存の改竄・欠損を検出する
  if [[ -f go.sum ]]; then
    run_stage lint "go" "go: mod verify" go mod verify
  fi
```

Rust 節の `run_stage test "-" "rust: test" cargo test --quiet` の直後に追加:

```bash
    # Cargo.lock と実体の整合(--offline でネットワークを使わない)
    if [[ -f Cargo.lock ]]; then
      run_stage lint "-" "rust: metadata" \
        cargo metadata --offline --format-version 1
    fi
```

- [ ] **Step 6: テストを実行して通ることを確認**

Run: `bash tests/test_check_p2.sh && bash tests/run_tests.sh`
Expected: 両方 PASS

- [ ] **Step 7: 自己適用の確認(このリポジトリは package.json と node_modules を持つ)**

Run: `bash scripts/check.sh 2>&1 | grep -E "node:|ALL PASS"`
Expected: `PASS  node: npm ls`(P2 で導入した devDependencies は実体があるため通る)

- [ ] **Step 8: コミット**

```bash
git add scripts/check.sh tests/test_check_p2.sh
git commit -m "feat: 依存の実在性・整合性検査をオフラインで追加"
```

---

### Task 6: フォーマットとデッドコード(宣言ゲート)

**Files:**
- Modify: `scripts/check.sh`(Node 節 / Python 節 / Go 節 / Rust 節)
- Test: `tests/test_check_p2.sh`(追記)

**Interfaces:**
- Consumes: P1 の `run_stage_soft`、各スタック節
- Produces: 結果行 `format` ステージの `node: prettier` / `go: gofmt` / `rust: cargo fmt`、`lint` ステージの `python: vulture` / `node: knip`

**実測に基づく設計(spec §8.3)**:
- prettier は設定なしでも動くが、既定スタイルの押し付けになるため**設定なしは SKIP**
- knip は設定なしだと**ハーネス自身の devDependencies を「未使用」と報告する**(実測)。**設定なしは SKIP**
- Go の gofmt だけは常に FAIL — 言語標準であり「宣言しないと従わない」性質ではない

- [ ] **Step 1: 失敗テストを追記**

`tests/test_check_p2.sh` の `assert_summary` の直前に追加:

```bash
# --- format: prettier(設定ゲート。設定が無ければ走らせない) ---
P17="$(new_project fmt_nocfg)"
printf '{"name":"t","version":"1.0.0","private":true}\n' > "$P17/package.json"
mkdir -p "$P17/node_modules"
{ echo '#!/usr/bin/env bash'; echo 'exit 0'; } > "$FAKEBIN/node"
{ echo '#!/usr/bin/env bash'; echo 'case "$1" in --version) exit 0 ;; esac'; echo 'exit 0'; } > "$FAKEBIN/npm"
make_fake npx 1
chmod +x "$FAKEBIN/node" "$FAKEBIN/npm"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P17" 2>&1)"; RC=$?
assert_eq "0" "$RC" "prettier 設定が無ければ完了をブロックしない"
assert_not_contains "$OUT" "FAIL  node: prettier" "設定が無ければ prettier を FAIL にしない"

# 設定があれば FAIL になる
P18="$(new_project fmt_cfg)"
printf '{"name":"t","version":"1.0.0","private":true}\n' > "$P18/package.json"
printf '{}' > "$P18/.prettierrc"
mkdir -p "$P18/node_modules"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P18" 2>&1)"; RC=$?
assert_eq "1" "$RC" "prettier 設定があり未整形なら exit 1"
assert_contains "$OUT" "FAIL  node: prettier" "設定があれば FAIL になる"

# --- knip: 設定が無ければ走らせない(実測: 設定なしは誤検出が多い) ---
assert_not_contains "$OUT" "node: knip" "knip 設定が無ければステージを出さない"

P19="$(new_project knip_cfg)"
printf '{"name":"t","version":"1.0.0","private":true}\n' > "$P19/package.json"
printf '{}' > "$P19/knip.json"
mkdir -p "$P19/node_modules"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P19" 2>&1)"; RC=$?
assert_eq "1" "$RC" "knip 設定があり検出されたら exit 1"
assert_contains "$OUT" "FAIL  node: knip" "設定があれば FAIL になる"
rm -f "$FAKEBIN/npx" "$FAKEBIN/npm" "$FAKEBIN/node"

# --- format: gofmt は宣言不要で常に FAIL(言語標準のため) ---
P20="$(new_project fmt_go)"
printf 'module t\n\ngo 1.21\n' > "$P20/go.mod"
printf 'package main\n' > "$P20/main.go"
{ echo '#!/usr/bin/env bash'
  echo 'case "$1" in version|--version) exit 0 ;; esac'
  echo 'exit 0'
} > "$FAKEBIN/go"
# gofmt -l は「未整形ファイル名を出力する」形式。出力があれば未整形
{ echo '#!/usr/bin/env bash'
  echo 'case "$1" in --version) exit 0 ;; esac'
  echo 'echo main.go'
  echo 'exit 0'
} > "$FAKEBIN/gofmt"
chmod +x "$FAKEBIN/go" "$FAKEBIN/gofmt"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P20" 2>&1)"; RC=$?
assert_eq "1" "$RC" "gofmt は宣言が無くても未整形を FAIL にする"
assert_contains "$OUT" "FAIL  go: gofmt" "gofmt の FAIL が記録される"
rm -f "$FAKEBIN/go" "$FAKEBIN/gofmt"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_check_p2.sh`
Expected: FAIL — `prettier 設定があり未整形なら exit 1: expected [1] but got [0]`

- [ ] **Step 3: Node 節に prettier と knip を追加**

`scripts/check.sh` の Node 節、Task 5 で追加した `node: npm ls` ブロックの直後に追加:

```bash
    # フォーマット。設定が無い prettier は既定スタイルの押し付けになるため
    # 走らせない(WARN でもノイズになる)
    # 設定ファイル名は prettier が探索する主要な形を網羅する(.prettierrc / .prettierrc.*
    # / prettier.config.*)。ls のグロブで一括判定し、列挙漏れを避ける
    if [[ -f .prettierrc ]] || ls .prettierrc.* prettier.config.* >/dev/null 2>&1 \
       || node -e "process.exit(require('./package.json').prettier ? 0 : 1)" 2>/dev/null; then
      if npx --no-install prettier --version >/dev/null 2>&1; then
        run_stage format "-" "node: prettier" npx --no-install prettier --check .
      else
        RESULTS+=("SKIP  node: prettier (prettier 未インストール)")
      fi
    fi

    # デッドコード。設定なしの knip はエントリポイント推定を誤り、実測では
    # 検査ツールとして入れた devDependencies まで「未使用」と報告する。
    # 設定を書いた=対象を宣言した、というときだけ走らせる
    if ls knip.json knip.jsonc knip.config.* >/dev/null 2>&1 \
       || node -e "process.exit(require('./package.json').knip ? 0 : 1)" 2>/dev/null; then
      if npx --no-install knip --version >/dev/null 2>&1; then
        run_stage lint "-" "node: knip" npx --no-install knip
      else
        RESULTS+=("SKIP  node: knip (knip 未インストール)")
      fi
    fi
```

- [ ] **Step 4: Python 節に vulture を追加**

Python 節のマニフェスト分岐、Task 5 で追加した deptry ブロックの直後に追加:

```bash
  # デッドコード。動的呼び出し・フレームワークのフックを誤検出しやすいため
  # 確信度80%以上に絞り、宣言があるときだけ FAIL にする
  if has vulture; then
    if [[ -f .vulture ]] || grep -q "^\[tool\.vulture" pyproject.toml 2>/dev/null; then
      run_stage lint "vulture" "python: vulture" vulture . --min-confidence 80
    else
      run_stage_soft lint "vulture" "python: vulture" vulture . --min-confidence 80
    fi
  fi
```

- [ ] **Step 5: Go 節と Rust 節にフォーマットを追加**

Go 節の Task 5 で追加した `go: mod verify` ブロックの直後に追加:

```bash
  # gofmt は言語標準であり「宣言しないと従わない」性質のものではないため、
  # 宣言ゲートを設けず常に FAIL とする(Goコミュニティの普遍的合意)
  GO_FILES=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && GO_FILES+=("$f")
  done < <(list_files '*.go')
  if [[ ${#GO_FILES[@]} -gt 0 ]] && has gofmt; then
    # gofmt -l は未整形ファイル名を「出力する」形式で、終了コードは 0 のまま。
    # 出力があれば未整形なので、非0に変換して run_stage に伝える
    run_stage format "-" "go: gofmt" \
      bash -c 'out="$(gofmt -l "$@")"; [[ -z "$out" ]] || { echo "未フォーマット:"; echo "$out"; exit 1; }' _ "${GO_FILES[@]}"
  fi
```

Rust 節の Task 5 で追加した `rust: metadata` ブロックの直後に追加:

```bash
    # rustfmt.toml があれば FAIL、無ければ WARN(既定スタイルの押し付けを避ける)
    if [[ -f rustfmt.toml || -f .rustfmt.toml ]]; then
      run_stage format "-" "rust: cargo fmt" cargo fmt --check
    else
      run_stage_soft format "-" "rust: cargo fmt" cargo fmt --check
    fi
```

- [ ] **Step 6: テストを実行して通ることを確認**

Run: `bash tests/test_check_p2.sh && bash tests/run_tests.sh`
Expected: 両方 PASS

- [ ] **Step 7: 自己適用の確認**

Run: `bash scripts/check.sh 2>&1 | tail -6; echo "exit=${PIPESTATUS[0]}"`
Expected: exit 0。このリポジトリは `.prettierrc` も `knip.json` も持たないため prettier/knip のステージは出ず、既存の `WARN python: ruff format` のみが残る

- [ ] **Step 8: コミット**

```bash
git add scripts/check.sh tests/test_check_p2.sh
git commit -m "feat: フォーマットとデッドコード検査を宣言ゲート付きで追加"
```

---

### Task 7: アーキテクチャ制約(import-linter)

**Files:**
- Modify: `scripts/check.sh`(Python 節)
- Test: `tests/test_check_p2.sh`(追記)

**Interfaces:**
- Consumes: Python 節の既存構造
- Produces: 結果行 `lint  python: import-linter`

**設計の要点**: 設定がある時のみ実行するのは mypy と同じ既存パターン。設定を書いた=意図的に層の制約を宣言したということなので、**誤検出は原理的に起きない**。よって常に FAIL でよい。

- [ ] **Step 1: 失敗テストを追記**

`tests/test_check_p2.sh` の `assert_summary` の直前に追加:

```bash
# --- アーキ制約: import-linter(設定がある時だけ実行) ---
P21="$(new_project arch)"
printf '[importlinter]\nroot_package = t\n' > "$P21/.importlinter"
printf '[project]\nname = "t"\n' > "$P21/pyproject.toml"
printf 'x = 1\n' > "$P21/mod.py"
make_fake lint-imports 1
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P21" 2>&1)"; RC=$?
assert_eq "1" "$RC" "層の制約違反は exit 1"
assert_contains "$OUT" "FAIL  python: import-linter" "FAILとして記録される"

# 設定が無ければステージ自体を出さない
P22="$(new_project arch_none)"
printf '[project]\nname = "t"\n' > "$P22/pyproject.toml"
printf 'x = 1\n' > "$P22/mod.py"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" "$P22" 2>&1)"
assert_not_contains "$OUT" "python: import-linter" "設定が無ければステージを出さない"
rm -f "$FAKEBIN/lint-imports"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_check_p2.sh`
Expected: FAIL — `層の制約違反は exit 1: expected [1] but got [0]`

- [ ] **Step 3: Python 節に import-linter を追加**

Python 節のマニフェスト分岐、Task 6 で追加した vulture ブロックの直後に追加:

```bash
  # 層の制約(アーキテクチャ)。設定を書いた=意図的に制約を宣言したという
  # ことなので、誤検出は原理的に起きない。mypy と同じ「設定がある時だけ」パターン
  if [[ -f .importlinter ]] \
     || grep -q "^\[importlinter\]" setup.cfg 2>/dev/null \
     || grep -q "^\[tool\.importlinter" pyproject.toml 2>/dev/null; then
    if has lint-imports; then
      run_stage lint "-" "python: import-linter" lint-imports
    else
      RESULTS+=("SKIP  python: import-linter (import-linter 未インストール)")
    fi
  fi
```

- [ ] **Step 4: テストを実行して通ることを確認**

Run: `bash tests/test_check_p2.sh && bash tests/run_tests.sh`
Expected: 両方 PASS

- [ ] **Step 5: コミット**

```bash
git add scripts/check.sh tests/test_check_p2.sh
git commit -m "feat: アーキテクチャ制約(import-linter)を設定ゲート付きで追加"
```

---

### Task 8: ドキュメント・バージョン・全体チェック

**Files:**
- Modify: `scripts/README.md`
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `.claude-plugin/plugin.json`(0.4.0 → 0.5.0)

**Interfaces:**
- Consumes: Task 1〜7 のすべての動作
- Produces: なし(リリース整備)

- [ ] **Step 1: `scripts/README.md` の check.sh 節を更新**

「**動作:**」の行を差し替える:

```markdown
**動作:** 検出したスタックごとに `lint` / `typecheck` / `test` / `build` / `format` を走らせ、スタック非依存の横断チェック(設定ファイルの構文・内部リンク・秘密情報・CI設定・Dockerfile)も実行して、`PASS`/`FAIL`/`WARN`/`SKIP` の要約を出す。
```

「**横断チェック(スタック非依存)**」の箇条書きの直後に追加:

```markdown
- **ドキュメント整合性**: Markdown の内部リンク切れを検出する(`docs` ステージ)。外部URL・`mailto:`・アンカーのみ・絶対パスは対象外(ネットワークを使わない原則)。コードブロック・コードスパン内のリンク風記述は検証しない
- **秘密情報**(`security` ステージ): `.secretlintrc.*` があれば `secretlint` を実行する。**設定が無ければ SKIP** — secretlint は設定なしでは起動できないため。値は既定でマスクされ、失敗ログに秘密が出ることはない。`gitleaks` が PATH にあれば併用する(`--no-git --redact` に対応する版のみ)
- **CI設定・Dockerfile**: `.github/workflows/*.y*ml` があれば `actionlint`、`Dockerfile*` があれば `dockerfilelint`(無ければ `hadolint`)を実行する。いずれも未導入なら SKIP
- **依存の実在性**(ネットワーク不使用): Node は `npm ls --all`(`node_modules` があるときのみ)、Go は `go mod verify`、Rust は `cargo metadata --offline`、Python は `deptry`。「存在しないパッケージ名」「宣言と実体のずれ」を検出する
```

「**ステージスキップ**」の行を差し替える:

```markdown
- **ステージスキップ**: `FEEDBACK_CHECK_SKIP` に指定できるステージ名は `lint` / `typecheck` / `test` / `build` / `format` / `security` / `docs`。空白区切りで複数指定できる
```

「**WARN**」の箇条書きを差し替える:

```markdown
- **WARN**: 完了をブロックしない指摘。exit code は `0` のまま。最終行に件数が付く(`ALL PASS (1件WARN — 未対応の指摘があります)`)。産出源は宣言(設定ファイル)が無い検査 — `python: ruff format`(`[tool.ruff` があれば FAIL)、`python: deptry` / `python: vulture`(`[tool.deptry` / `[tool.vulture` があれば FAIL)、`rust: cargo fmt`(`rustfmt.toml` があれば FAIL)
```

- [ ] **Step 2: `README.md` の「仕組み」表を更新**

Claude Code 行の「自動チェック」セルの末尾(`events.jsonl` に記録される の後)に追記:

```markdown
。秘密情報・内部リンク・依存整合性・CI設定も検査する(ツール未導入は SKIP。ハーネスがツールを勝手に導入することはない)
```

- [ ] **Step 3: `CLAUDE.md` の変更履歴に1行追加**

変更履歴テーブルの最終行の後に追加:

```markdown
| 2026-08-17 | 適用範囲拡張 P2(速い検査群) | check.sh / lib.sh / tests / package.json | 秘密情報・内部リンク・依存整合性・CI設定・Dockerfile・フォーマット・デッドコード・アーキ制約を追加。実測に基づき secretlint と knip は設定ゲート(設定なしは SKIP) |
```

- [ ] **Step 4: バージョンを 0.5.0 に上げる**

`.claude-plugin/plugin.json` の `"version": "0.4.0",` を `"version": "0.5.0",` に変更。

- [ ] **Step 5: 全体チェック**

Run: `bash scripts/check.sh; echo "exit=$?"`
Expected: `exit=0`。このリポジトリでは `PASS docs: 内部リンク` と `PASS node: npm ls` が加わり、`WARN python: ruff format` は残る。`.secretlintrc.*` を持たないため `SKIP security: secretlint` が出る

- [ ] **Step 6: コミット**

```bash
git add scripts/README.md README.md CLAUDE.md .claude-plugin/plugin.json
git commit -m "docs: P2(速い検査群)の文書を整え v0.5.0 に上げる"
```

---

## 完了後の自省(実行エージェント向け)

計画全体を終えたら、このセッションで共有アーティファクト(CLAUDE.md・`docs/`・スキル)を変えるべき出来事があったかを1問自省する(CLAUDE.md のトリガーに従う)。実装中に設計と実際が食い違った場合は、設計書(spec)側も更新してから完了すること。

P2 完了後の次段階は **P3(重い検査群)** — M2 遅延実行機構・脆弱性監査・M3 カバレッジ相乗り・API契約差分。P3 は**ネットワークを使う検査**を含むため、着手前に実行方針(Stopフックで走らせるか、オンデマンドに限るか)をユーザーに確認すること。
