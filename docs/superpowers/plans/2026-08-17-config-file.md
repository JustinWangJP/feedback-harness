# プロジェクト設定ファイル(config.yaml)Implementation Plan

> **履歴資料:** この計画は実施済みです。チェックボックスは実施当時の作業単位をそのまま保存したもので、未チェックのままでも未着手を意味しません。**この文書に従って作業しないこと。** 現在の設定方法は[設定ガイド](../../configuration.ja.md)を参照してください。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `.feedback/config.yaml` でハーネスの挙動をプロジェクトごとに調整できるようにする(3層 + 環境変数の優先順位、実効設定の表示つき)。

**Architecture:** パーサ・スキーマ・既定値・解決規則を `scripts/harness_config.py` 1本に集約する。bash 側は `eval` で受け取った**解決済みの値**を使うだけで、優先順位の判断ロジックを持たない。判定は「検査ID → (severity, 出所)」の1つのマップに集約し、3層(全体・スタック・検査)の解決はローダーが行う。

**Tech Stack:** Bash(`set -u`、`lib.sh` 共有関数)、Python 3 標準ライブラリのみ(**PyYAML を使わない**)。

**Spec:** [docs/superpowers/specs/2026-08-17-config-file-design.md](../specs/2026-08-17-config-file-design.md)

## Global Constraints

- **新しい実行時依存を足さない** — bash / python3 標準ライブラリ / git のみ。**PyYAML は使わない**(開発機にも入っておらず、必須にすると設定が黙って効かない環境が生まれる)
- **パーサとスキーマと既定値は `harness_config.py` の1箇所だけ** — bash 側に既定値を書かない(2箇所管理はドリフトする)
- 優先順位は **環境変数 > `checks.<id>` > `check.<stack>` > `check`(全体) > 既定値**
- **`eval` に渡す値は必ず `shlex.quote` で括る** — config はリポジトリ内のファイルであり、引用を怠るとファイルの中身がシェルコードとして実行される
- **壊れた config は FAIL を立てたうえで既定値のまま続行**する(黙って落とさない / 他の検査は止めない)
- **未知キー・型不一致・列挙外の値はエラー** — 打ち間違いを黙って無視しない
- `.claude-plugin/plugin.json` は **0.4.0 のまま**(公開前のため版を刻まない)
- **`ls` の複数引数ゲート禁止**(P2 の教訓): 複数候補は `for` + `[[ -f ]]` かパターンごとの `compgen -G`
- コメントは「なぜ」を書く。コミットメッセージは日本語 conventional commits
- 各タスクのコミット手順に列挙したファイルだけを `git add` する

## 設計書からの洗練(§4.2 の置き換え)

> **2026-08-22 追記:** この計画は実装時点の履歴である。現在の shell 契約は、区切り文字入りの単一マップではなく `HARNESS_CHECK_<正規化ID>_SEVERITY` / `HARNESS_CHECK_<正規化ID>_SOURCE` のフィールド別変数である。

設計書 §4.2 は全体/スタック層をステージ集合として、検査層を別マップとして bash へ渡す形だった。本計画では**判定を1つのマップに集約する**:

```
HARNESS_CHECK_SEVERITY='vulture:skip:checks.vulture pytest:warn:check.python.warn_on'
```

`harness_config.py` が検査ID → (スタック, ステージ) の対応表を持てば、`check.skip: [test]` を「test ステージの全IDが skip」へ展開でき、3層すべてをローダー側で解決しきれる。bash 側は ID を引くだけになり、設計書が求めた「解決規則を1箇所に置く」がより厳密に満たされる。副作用として `skipped()`(`FEEDBACK_CHECK_SKIP` の部分文字列一致)は不要になり、SKIP の理由に出所が出せるようになる。

## ファイル構成

| ファイル | 責務 | 変更 |
|---|---|---|
| `scripts/harness_config.py` | パーサ / スキーマ / 既定値 / 解決 / 出力整形 | 新規 |
| `scripts/lib.sh` | `harness_load_config` / `harness_check_severity` | 変更 |
| `scripts/check.sh` | 検査ID付与・判定解決・exclude・`--list-checks` | 変更 |
| `scripts/check_file.sh` | ルート解決 + config 読み込み | 変更 |
| `scripts/audit.sh` | `npm_audit_level` | 変更 |
| `scripts/feedback_log.py` | `interval_days` / `open_threshold` | 変更 |
| `scripts/init.sh` | 配布物追加 | 変更 |
| `.feedback/config.example.yaml` | 雛形 | 新規 |
| `docs/configuration.md` | 設定ガイド | 新規 |
| `tests/test_config.sh` | パーサ・スキーマ・解決 | 新規 |
| `tests/test_config_wiring.sh` | check.sh 経由の配線・`--list-checks` | 新規 |

---

### Task 1: YAML サブセットパーサ

**Files:**
- Create: `scripts/harness_config.py`
- Test: `tests/test_config.sh`(新規)

**Interfaces:**
- Produces: `parse_yaml(text: str, path: str) -> dict`、および `ConfigError(Exception)` — Task 2 以降が使う。エラーは `ConfigError(f"{path}:{lineno}: {理由}")` の形

- [ ] **Step 1: 失敗テストを書く**

`tests/test_config.sh` を作成:

```bash
#!/usr/bin/env bash
# test_config.sh — harness_config.py のパーサ・スキーマ検証・解決規則を検証する。
#
# YAML は PyYAML を使わず自前のサブセット実装で読む(PyYAML は任意依存で、
# 開発機にも入っていない)。サポート範囲の境界と、範囲外を「黙って無視せず
# 行番号付きで落とす」ことがこのテストの中心。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CFG="$REPO/scripts/harness_config.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

# parse <YAML本文> — パーサだけを叩き、結果を JSON で返す(非0なら stderr が出る)
parse() { printf '%s' "$1" > "$WORK/t.yaml"; python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import harness_config as hc
print(json.dumps(hc.parse_yaml(open(sys.argv[2]).read(), sys.argv[2]), sort_keys=True))
' "$REPO/scripts" "$WORK/t.yaml" 2>&1; }

# --- スカラー ---
assert_eq '{"a": 1}' "$(parse 'a: 1')" "整数"
assert_eq '{"a": "x"}' "$(parse 'a: x')" "裸文字列"
assert_eq '{"a": "x y"}' "$(parse 'a: "x y"')" "ダブルクォート"
assert_eq '{"a": true}' "$(parse 'a: true')" "真偽値"
assert_eq '{"a": null}' "$(parse 'a:')" "空は null"

# --- コメント ---
assert_eq '{"a": 1}' "$(parse '# 先頭コメント
a: 1  # 行末コメント')" "コメントは無視される"
assert_eq '{"a": "x#y"}' "$(parse 'a: "x#y"')" "クォート内の # はコメントではない"

# --- リスト ---
assert_eq '{"a": []}' "$(parse 'a: []')" "空のフローリスト"
assert_eq '{"a": ["x", "y"]}' "$(parse 'a: [x, y]')" "フローリスト"
assert_eq '{"a": ["x", "y"]}' "$(parse 'a:
  - x
  - y')" "ブロックリスト"

# --- 入れ子マップ ---
assert_eq '{"a": {"b": {"c": 1}}}' "$(parse 'a:
  b:
    c: 1')" "入れ子マップ"

# --- 未対応記法は行番号付きで落ちる ---
OUT="$(parse 'a: 1
b: &anchor x')"; RC=$?
assert_eq "1" "$RC" "アンカーは非0で落ちる"
assert_contains "$OUT" ":2:" "行番号が出る"
assert_contains "$OUT" "アンカー" "理由が出る"

OUT="$(parse 'a: |
  multi')"
assert_contains "$OUT" "複数行文字列" "複数行文字列を拒否する"

OUT="$(printf 'a:\n\tb: 1' > "$WORK/t.yaml"; python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import harness_config as hc
hc.parse_yaml(open(sys.argv[2]).read(), sys.argv[2])' "$REPO/scripts" "$WORK/t.yaml" 2>&1)"
assert_contains "$OUT" "タブ" "タブインデントを拒否する"

assert_summary
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_config.sh`
Expected: FAIL — `ModuleNotFoundError: No module named 'harness_config'`

- [ ] **Step 3: パーサを実装**

`scripts/harness_config.py` を作成:

```python
#!/usr/bin/env python3
"""harness_config.py — .feedback/config.yaml を読む唯一のパーサ。

bash(check.sh / check_file.sh / audit.sh)と Python(feedback_log.py)の
両方が同じ設定を読む。両者に別々のパーサを持たせると必ずドリフトするため
(has() で実際に起きた)、パーサ・スキーマ・既定値・解決規則はここだけに置く。

PyYAML は使わない。このハーネスは PyYAML を任意依存として扱っており
(未導入なら YAML 検査を SKIP する)、開発機にも入っていない。設定の読み込みを
PyYAML に依存させると「設定が黙って効かない」環境が生まれ、検査が SKIP される
より悪い失敗モードになる。代わりに config に必要な範囲だけを自前で解釈し、
範囲外は行番号付きで落とす。
"""

import re
import sys


class ConfigError(Exception):
    """設定ファイルの構文・スキーマの誤り。メッセージに path:lineno を含む。"""


def _die(path, lineno, reason):
    raise ConfigError(f"{path}:{lineno}: {reason}")


def _strip_comment(line):
    """クォートの外にある # 以降を落とす。"""
    out = []
    quote = None
    for ch in line:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
    return "".join(out).rstrip()


# 解釈しない記法。黙って無視すると「書いたのに効かない」最悪の状態になるため、
# 検出したら行番号付きで落とす
_UNSUPPORTED = [
    (re.compile(r"(?:^|[:\s])[&*][A-Za-z_]"), "アンカー/エイリアス(& *)は使えません"),
    (re.compile(r"^---\s*$"), "複数文書(---)は使えません"),
    (re.compile(r":\s*[|>][-+0-9]*\s*$"), "複数行文字列(| >)は使えません"),
]


def _reject_unsupported(body, path, lineno):
    for pattern, reason in _UNSUPPORTED:
        if pattern.search(body):
            _die(path, lineno, f"未対応の記法です({reason})")


def _scalar(s, path, lineno):
    if s == "":
        return None
    if s.startswith("[") and s.endswith("]"):
        inner = s[1:-1].strip()
        if not inner:
            return []
        return [_scalar(x.strip(), path, lineno) for x in inner.split(",")]
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        return s[1:-1]
    low = s.lower()
    if low in ("true", "false"):
        return low == "true"
    if low in ("null", "~"):
        return None
    if re.fullmatch(r"-?\d+", s):
        return int(s)
    return s


def parse_yaml(text, path):
    """YAML のサブセットを dict に変換する。

    解釈するのは入れ子マップ・リスト(ブロック/フロー)・スカラー・コメントのみ。
    インデントはスペースのみ(タブは落とす)。
    """
    root = {}
    # stack の各要素は (このコンテナの子が置かれるインデント, コンテナ)
    stack = [(0, root)]
    # 値が空のキー。子の行を見て「入れ子マップ」か「ブロックリスト」かが確定する
    pending = None

    def container_for(indent, lineno):
        while len(stack) > 1 and stack[-1][0] > indent:
            stack.pop()
        if stack[-1][0] != indent:
            _die(path, lineno, "インデントが親と揃っていません")
        return stack[-1][1]

    for lineno, raw in enumerate(text.splitlines(), 1):
        line = _strip_comment(raw)
        if not line.strip():
            continue
        lead = line[: len(line) - len(line.lstrip())]
        if "\t" in lead:
            _die(path, lineno, "タブでインデントできません(スペースを使ってください)")
        indent = len(lead)
        body = line.strip()
        _reject_unsupported(body, path, lineno)

        # pending の子でなければ、そのキーは値なし(null)で確定する
        if pending is not None and indent <= pending[0]:
            pending[1][pending[2]] = None
            pending = None

        if body.startswith("- "):
            if pending is not None:
                lst = []
                pending[1][pending[2]] = lst
                stack.append((indent, lst))
                pending = None
            cont = container_for(indent, lineno)
            if not isinstance(cont, list):
                _die(path, lineno, "リスト要素を書ける位置ではありません")
            item = _scalar(body[2:].strip(), path, lineno)
            if isinstance(item, (list, dict)):
                _die(path, lineno, "リストの入れ子は使えません")
            cont.append(item)
            continue

        if ":" not in body:
            _die(path, lineno, f"'キー: 値' の形式ではありません: {body}")

        if pending is not None:
            d = {}
            pending[1][pending[2]] = d
            stack.append((indent, d))
            pending = None

        cont = container_for(indent, lineno)
        if not isinstance(cont, dict):
            _die(path, lineno, "マップのキーを書ける位置ではありません")

        key, _, val = body.partition(":")
        key, val = key.strip(), val.strip()
        if not key:
            _die(path, lineno, "キーが空です")
        if val == "":
            pending = (indent, cont, key)
        else:
            cont[key] = _scalar(val, path, lineno)

    if pending is not None:
        pending[1][pending[2]] = None
    return root
```

- [ ] **Step 4: テストを実行して通ることを確認**

Run: `bash tests/test_config.sh`
Expected: PASS(exit 0・無出力)

- [ ] **Step 5: コミット**

```bash
git add scripts/harness_config.py tests/test_config.sh
git commit -m "feat: PyYAML に依存しない最小YAMLパーサを追加する"
```

---

### Task 2: スキーマ・既定値・妥当性検証

**Files:**
- Modify: `scripts/harness_config.py`
- Test: `tests/test_config.sh`(追記)

**Interfaces:**
- Consumes: Task 1 の `parse_yaml` / `ConfigError`
- Produces: `CHECKS: dict[str, tuple[str, str]]`(検査ID → (スタック/群, ステージ))、`STAGES` / `STACKS` / `SEVERITIES` / `CHECK_PARAMS` / `DEFAULTS`、`validate(cfg: dict, path: str) -> dict`

- [ ] **Step 1: 失敗テストを追記**

`tests/test_config.sh` の `assert_summary` の直前に追加:

```bash
# --- スキーマ検証 ---
# 検証は parse の後段。打ち間違いを黙って無視しない契約を固定する
val() { printf '%s' "$1" > "$WORK/v.yaml"; python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import harness_config as hc
p = sys.argv[2]
print(json.dumps(hc.validate(hc.parse_yaml(open(p).read(), p), p), sort_keys=True))
' "$REPO/scripts" "$WORK/v.yaml" 2>&1; }

OUT="$(val 'check:
  shelcheck_severity: warning')"
assert_contains "$OUT" "未知のキー" "打ち間違いのキーを拒否する"
assert_contains "$OUT" "shelcheck_severity" "問題のキー名を出す"

OUT="$(val 'check:
  skip: [lnit]')"
assert_contains "$OUT" "lnit" "未知のステージ名を拒否する"

OUT="$(val 'checks:
  vultrue:
    severity: skip')"
assert_contains "$OUT" "vultrue" "未知の検査IDを拒否する"

OUT="$(val 'checks:
  vulture:
    severity: hard')"
assert_contains "$OUT" "hard" "未知の severity を拒否する"

OUT="$(val 'audit:
  interval_days: seven')"
assert_contains "$OUT" "整数" "型不一致を拒否する"

OUT="$(val 'version: 2')"
assert_contains "$OUT" "version" "対応外のスキーマ版を拒否する"

OUT="$(val 'check:
  golang:
    skip: [test]')"
assert_contains "$OUT" "golang" "未知のスタック名を拒否する"

# 正しい設定は通る
assert_eq "0" "$(val 'check:
  skip: [test]
checks:
  vulture:
    severity: skip' >/dev/null 2>&1; echo $?)" "妥当な設定は検証を通る"

# 検査IDの一覧が取れる(check.sh との突き合わせに使う)
assert_contains "$(python3 "$CFG" --keys)" "vulture" "--keys が検査IDを出す"
assert_contains "$(python3 "$CFG" --keys)" "ruff-format" "--keys がハイフン付きIDを出す"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_config.sh`
Expected: FAIL — `module 'harness_config' has no attribute 'validate'`

- [ ] **Step 3: スキーマと検証を実装**

`harness_config.py` の末尾に追加:

```python
# ---------- スキーマ ----------

STAGES = ["lint", "typecheck", "test", "build", "format", "security", "docs", "contract"]
STACKS = ["python", "node", "go", "rust", "java", "shell"]
SEVERITIES = ["fail", "warn", "skip"]
SCHEMA_VERSION = 1

# 検査ID -> (スタック/群, ステージ)。
# 表示ラベルは ID に使えない — Node のラベルは "node: $PM run lint" のように
# パッケージマネージャで変動するため。スタック/群は check.<stack> の解決に、
# ステージは check.skip 等の解決に使う
CHECKS = {
    "ruff": ("python", "lint"),
    "ruff-format": ("python", "format"),
    "mypy": ("python", "typecheck"),
    "pytest": ("python", "test"),
    "deptry": ("python", "lint"),
    "vulture": ("python", "lint"),
    "import-linter": ("python", "lint"),
    "node-lint": ("node", "lint"),
    "node-typecheck": ("node", "typecheck"),
    "tsc": ("node", "typecheck"),
    "node-test": ("node", "test"),
    "node-test-coverage": ("node", "test"),
    "node-build": ("node", "build"),
    "npm-ls": ("node", "lint"),
    "prettier": ("node", "format"),
    "knip": ("node", "lint"),
    "go-vet": ("go", "lint"),
    "go-build": ("go", "build"),
    "go-test": ("go", "test"),
    "go-mod-verify": ("go", "lint"),
    "gofmt": ("go", "format"),
    "clippy": ("rust", "lint"),
    "cargo-check": ("rust", "build"),
    "cargo-test": ("rust", "test"),
    "cargo-metadata": ("rust", "lint"),
    "cargo-fmt": ("rust", "format"),
    "cargo-semver-checks": ("rust", "contract"),
    "mvn": ("java", "test"),
    "gradle": ("java", "test"),
    "bash-syntax": ("shell", "lint"),
    "shellcheck": ("shell", "lint"),
    "json-syntax": ("config", "lint"),
    "yaml-syntax": ("config", "lint"),
    "md-links": ("docs", "docs"),
    "secretlint": ("security", "security"),
    "gitleaks": ("security", "security"),
    "actionlint": ("ci", "lint"),
    "dockerfilelint": ("docker", "lint"),
    "hadolint": ("docker", "lint"),
    "oasdiff": ("contract", "contract"),
    "make-check": ("make", "test"),
}

# 検査固有パラメータ: 検査ID -> キー -> (型, 既定値, 許容値 or None)
CHECK_PARAMS = {
    "shellcheck": {
        "min_severity": ("enum", "warning", ["style", "info", "warning", "error"])
    },
    "vulture": {"min_confidence": ("int", 80, None)},
    "oasdiff": {"base": ("str", "main", None)},
}

# セクション -> キー -> (型, 既定値, 許容値 or None)
SECTIONS = {
    "check": {
        "skip": ("stages", [], None),
        "fail_on": ("stages", [], None),
        "warn_on": ("stages", [], None),
        "exclude": ("strlist", [], None),
        "log_tail_lines": ("int", 40, None),
    },
    "audit": {
        "interval_days": ("int", 7, None),
        "npm_audit_level": ("enum", "high", ["low", "moderate", "high", "critical"]),
    },
    "feedback": {"open_threshold": ("int", 3, None)},
}

# スタック層で使えるキー(全体層の一部)
STACK_KEYS = ["skip", "fail_on", "warn_on"]


def _check_type(kind, value, allowed, where, path):
    if kind == "int":
        if not isinstance(value, int) or isinstance(value, bool):
            raise ConfigError(f"{path}: {where} は整数で指定してください(実際: {value!r})")
    elif kind == "str":
        if not isinstance(value, str):
            raise ConfigError(f"{path}: {where} は文字列で指定してください(実際: {value!r})")
    elif kind == "enum":
        if value not in allowed:
            raise ConfigError(
                f"{path}: {where} に指定できるのは {' / '.join(allowed)} です(実際: {value!r})"
            )
    elif kind in ("stages", "strlist"):
        if not isinstance(value, list):
            raise ConfigError(f"{path}: {where} はリストで指定してください(実際: {value!r})")
        for item in value:
            if not isinstance(item, str):
                raise ConfigError(f"{path}: {where} の要素は文字列です(実際: {item!r})")
            if kind == "stages" and item not in STAGES:
                raise ConfigError(
                    f"{path}: {where} の {item!r} は未知のステージです。"
                    f"使えるのは {' / '.join(STAGES)}"
                )


def _unknown(where, key, known, path):
    raise ConfigError(
        f"{path}: {where} に未知のキー {key!r} があります。使えるのは {' / '.join(sorted(known))}"
    )


def validate(cfg, path):
    """パース済みの dict をスキーマで検証する。未知キー・型不一致・列挙外はエラー。

    打ち間違いを黙って無視すると「書いたのに効かない」状態になるため、
    既知の集合に無いキーは必ず落とす。
    """
    if cfg is None:
        return {}
    if not isinstance(cfg, dict):
        raise ConfigError(f"{path}: トップレベルはマップである必要があります")

    version = cfg.get("version", SCHEMA_VERSION)
    if not isinstance(version, int) or version > SCHEMA_VERSION:
        raise ConfigError(
            f"{path}: version {version!r} は未対応です(このハーネスは {SCHEMA_VERSION} まで)"
        )

    top_known = set(SECTIONS) | {"version", "checks"}
    for key in cfg:
        if key not in top_known:
            _unknown("トップレベル", key, top_known, path)

    for section, keys in SECTIONS.items():
        body = cfg.get(section) or {}
        if not isinstance(body, dict):
            raise ConfigError(f"{path}: {section} はマップである必要があります")
        known = set(keys) | (set(STACKS) if section == "check" else set())
        for key, value in body.items():
            if key in STACKS and section == "check":
                if not isinstance(value, dict):
                    raise ConfigError(f"{path}: check.{key} はマップである必要があります")
                for skey, sval in value.items():
                    if skey not in STACK_KEYS:
                        _unknown(f"check.{key}", skey, STACK_KEYS, path)
                    kind, _, allowed = keys[skey]
                    _check_type(kind, sval, allowed, f"check.{key}.{skey}", path)
                continue
            if key not in keys:
                _unknown(section, key, known, path)
            kind, _, allowed = keys[key]
            _check_type(kind, value, allowed, f"{section}.{key}", path)

    checks = cfg.get("checks") or {}
    if not isinstance(checks, dict):
        raise ConfigError(f"{path}: checks はマップである必要があります")
    for cid, body in checks.items():
        if cid not in CHECKS:
            raise ConfigError(
                f"{path}: {cid!r} は未知の検査IDです。"
                "`bash scripts/check.sh --list-checks` で一覧を確認してください"
            )
        if not isinstance(body, dict):
            raise ConfigError(f"{path}: checks.{cid} はマップである必要があります")
        params = CHECK_PARAMS.get(cid, {})
        known = set(params) | {"severity"}
        for key, value in body.items():
            if key == "severity":
                _check_type("enum", value, SEVERITIES, f"checks.{cid}.severity", path)
                continue
            if key not in params:
                _unknown(f"checks.{cid}", key, known, path)
            kind, _, allowed = params[key]
            _check_type(kind, value, allowed, f"checks.{cid}.{key}", path)

    return cfg


def _cmd_keys():
    """検査IDと既定値を出力する。雛形・ガイド・check.sh とのドリフト検出に使う。"""
    for cid in sorted(CHECKS):
        stack, stage = CHECKS[cid]
        print(f"check\t{cid}\t{stack}\t{stage}")
    for section, keys in sorted(SECTIONS.items()):
        for key, (kind, default, _) in sorted(keys.items()):
            print(f"key\t{section}.{key}\t{kind}\t{default}")
    for cid, params in sorted(CHECK_PARAMS.items()):
        for key, (kind, default, _) in sorted(params.items()):
            print(f"param\tchecks.{cid}.{key}\t{kind}\t{default}")


if __name__ == "__main__":
    if "--keys" in sys.argv:
        _cmd_keys()
        sys.exit(0)
    sys.exit("usage: harness_config.py --keys")
```

- [ ] **Step 4: テストを実行して通ることを確認**

Run: `bash tests/test_config.sh`
Expected: PASS

- [ ] **Step 5: 検査IDが実装と一致することを確認**

Run: `python3 scripts/harness_config.py --keys | grep -c '^check'`
Expected: `41`

- [ ] **Step 6: コミット**

```bash
git add scripts/harness_config.py tests/test_config.sh
git commit -m "feat: config のスキーマ検証を追加する(未知キーは明示エラー)"
```

---

### Task 3: 解決規則(レイヤ × 3層 × 環境変数)と `--json`

**Files:**
- Modify: `scripts/harness_config.py`
- Test: `tests/test_config.sh`(追記)

**Interfaces:**
- Consumes: Task 2 の `validate` / `CHECKS` / `SECTIONS` / `CHECK_PARAMS`
- Produces: `load(root: str) -> dict`(config を読んで検証)、`resolve(layers: list, env: dict) -> dict` — 戻り値は `{"severity": {id: (sev, source)}, "values": {"check.log_tail_lines": (値, 出所), ...}, "error": str|None}`

**設計の要点**: `resolve` は**設定レイヤの列**を受け取る。v1 ではレイヤは1つだが、個人設定レイヤ(`.feedback/local/config.yaml`)を後から足すときに解決関数を書き直さずに済む(設計書 §4.4.1)。

- [ ] **Step 1: 失敗テストを追記**

`tests/test_config.sh` の `assert_summary` の直前に追加:

```bash
# --- 解決規則(3層 + 環境変数)---
# 実効値は --json で確認する。出所(どの層で決まったか)も一緒に返る
mkdir -p "$WORK/proj/.feedback"
resolve_json() { # resolve_json [環境変数の代入...]
  env "$@" python3 "$CFG" --json "$WORK/proj"
}
get() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d, sort_keys=True))'; }

# config 不在 → 全て既定値
OUT="$(resolve_json | get)"
assert_contains "$OUT" '"log_tail_lines": [40, "既定"]' "config 不在で既定値になる"

cat > "$WORK/proj/.feedback/config.yaml" <<'EOF'
check:
  skip: [contract]
  log_tail_lines: 10
  python:
    warn_on: [test]
checks:
  vulture:
    severity: skip
    min_confidence: 60
EOF

OUT="$(resolve_json)"
assert_contains "$OUT" '"pytest": ["warn", "check.python.warn_on"]' "スタック層がステージを展開する"
assert_contains "$OUT" '"vulture": ["skip", "checks.vulture"]' "検査層が効く"
assert_contains "$OUT" '"oasdiff": ["skip", "check.skip"]' "全体層が contract ステージを展開する"
assert_contains "$OUT" '"log_tail_lines": [10, "check.log_tail_lines"]' "全体層の値が効く"
assert_contains "$OUT" '"min_confidence": [60, "checks.vulture.min_confidence"]' "検査固有パラメータが効く"

# スタック層は他スタックに漏れない
assert_not_contains "$OUT" '"go-test":' "Python の warn_on が Go に漏れない"

# 検査層 > スタック層 > 全体層
cat > "$WORK/proj/.feedback/config.yaml" <<'EOF'
check:
  skip: [test]
  python:
    warn_on: [test]
checks:
  pytest:
    severity: fail
EOF
OUT="$(resolve_json)"
assert_contains "$OUT" '"pytest": ["fail", "checks.pytest"]' "検査層がスタック層に勝つ"
assert_contains "$OUT" '"go-test": ["skip", "check.skip"]' "指定の無いスタックは全体層に従う"

# 環境変数が config に勝つ
OUT="$(resolve_json FEEDBACK_CHECK_SKIP=lint)"
assert_contains "$OUT" '"ruff": ["skip", "env.FEEDBACK_CHECK_SKIP"]' "環境変数が最優先"
assert_contains "$OUT" '"pytest": ["fail", "checks.pytest"]' "環境変数が触らない検査は config のまま"

OUT="$(resolve_json FEEDBACK_SHELLCHECK_SEVERITY=style)"
assert_contains "$OUT" '"min_severity": ["style", "env.FEEDBACK_SHELLCHECK_SEVERITY"]' "環境変数がパラメータにも効く"

# 壊れた config はエラーを返し、値は既定値のまま
printf 'check:\n  skip: [lnit]\n' > "$WORK/proj/.feedback/config.yaml"
OUT="$(resolve_json)"
assert_contains "$OUT" '"error"' "壊れた config はエラーを返す"
assert_contains "$OUT" "lnit" "エラーに原因が入る"
assert_contains "$OUT" '"log_tail_lines": [40, "既定"]' "壊れていても既定値で続行できる"
rm -f "$WORK/proj/.feedback/config.yaml"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_config.sh`
Expected: FAIL — `usage: harness_config.py --keys`(`--json` 未実装)

- [ ] **Step 3: 解決を実装**

`harness_config.py` の `_cmd_keys` の前に追加:

```python
# ---------- 解決 ----------

CONFIG_RELPATH = ".feedback/config.yaml"

# 環境変数 -> 何を上書きするか
ENV_STAGE_SKIP = "FEEDBACK_CHECK_SKIP"
ENV_PARAM_OVERRIDES = {
    "FEEDBACK_SHELLCHECK_SEVERITY": ("shellcheck", "min_severity"),
    "FEEDBACK_CONTRACT_BASE": ("oasdiff", "base"),
}


def load(root):
    """<root>/.feedback/config.yaml を読んで検証する。

    戻り値は (cfg, error)。ファイルが無ければ ({}, None)。
    壊れていれば ({}, メッセージ) — 呼び出し側が FAIL を立てたうえで
    既定値のまま続行できるようにするため、例外を投げない。
    """
    import os

    path = os.path.join(root, CONFIG_RELPATH)
    if not os.path.isfile(path):
        return {}, None
    try:
        with open(path, encoding="utf-8") as fh:
            return validate(parse_yaml(fh.read(), CONFIG_RELPATH), CONFIG_RELPATH), None
    except ConfigError as exc:
        return {}, str(exc)
    except OSError as exc:
        return {}, f"{CONFIG_RELPATH}: 読み取れません({exc})"


def _stage_verdicts(scope, body, prefix, out, only_stack=None):
    """skip/fail_on/warn_on のステージ集合を、検査ID単位の判定へ展開する。

    fail_on と warn_on の両方に同じステージがある場合は fail_on を優先する(安全側)。
    """
    for key, sev in (("warn_on", "warn"), ("fail_on", "fail"), ("skip", "skip")):
        for stage in body.get(key) or []:
            for cid, (stack, cstage) in CHECKS.items():
                if cstage != stage:
                    continue
                if only_stack is not None and stack != only_stack:
                    continue
                out[cid] = (sev, f"{prefix}.{key}")
    _ = scope


def resolve(layers, env):
    """設定レイヤの列と環境変数から、実効値と出所を決める。

    レイヤは「先に来たものが勝つ」。v1 ではレイヤは1つだが、個人設定
    (.feedback/local/config.yaml)を後から足すときに、この関数を書き直さず
    呼び出し側の1行で済ませられるよう最初から列で受ける。
    レイヤ内の優先は 検査 > スタック > 全体。環境変数はすべてに優先する。
    """
    severity = {}
    values = {}

    # 既定値
    for section, keys in SECTIONS.items():
        for key, (_, default, _allowed) in keys.items():
            values[f"{section}.{key}"] = (default, "既定")
    for cid, params in CHECK_PARAMS.items():
        for key, (_, default, _allowed) in params.items():
            values[f"checks.{cid}.{key}"] = (default, "既定")

    # レイヤは後ろから適用する(先頭のレイヤが最後に上書きして勝つ)
    for layer in reversed(layers):
        check = layer.get("check") or {}
        _stage_verdicts("global", check, "check", severity)
        for stack in STACKS:
            body = check.get(stack) or {}
            if body:
                _stage_verdicts(stack, body, f"check.{stack}", severity, only_stack=stack)
        for cid, body in (layer.get("checks") or {}).items():
            if "severity" in body:
                severity[cid] = (body["severity"], f"checks.{cid}")
            for key, val in body.items():
                if key != "severity":
                    values[f"checks.{cid}.{key}"] = (val, f"checks.{cid}.{key}")
        for section, keys in SECTIONS.items():
            body = layer.get(section) or {}
            for key in keys:
                if key in body:
                    values[f"{section}.{key}"] = (body[key], f"{section}.{key}")

    # 環境変数(最優先)
    raw = env.get(ENV_STAGE_SKIP, "").strip()
    if raw:
        for stage in raw.split():
            for cid, (_stack, cstage) in CHECKS.items():
                if cstage == stage:
                    severity[cid] = ("skip", f"env.{ENV_STAGE_SKIP}")
    for var, (cid, key) in ENV_PARAM_OVERRIDES.items():
        if env.get(var):
            values[f"checks.{cid}.{key}"] = (env[var], f"env.{var}")

    return {"severity": severity, "values": values}


def effective(root, env):
    """load + resolve をまとめた入口。error は呼び出し側が FAIL に使う。"""
    cfg, error = load(root)
    out = resolve([cfg] if cfg else [], env)
    out["error"] = error
    return out
```

`__main__` を差し替え:

```python
if __name__ == "__main__":
    import json
    import os

    args = sys.argv[1:]
    if "--keys" in args:
        _cmd_keys()
        sys.exit(0)
    if "--json" in args:
        rest = [a for a in args if not a.startswith("--")]
        root = rest[0] if rest else os.getcwd()
        print(json.dumps(effective(root, os.environ), ensure_ascii=False, sort_keys=True))
        sys.exit(0)
    sys.exit("usage: harness_config.py [--keys | --json [root]]")
```

- [ ] **Step 4: テストを実行して通ることを確認**

Run: `bash tests/test_config.sh`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add scripts/harness_config.py tests/test_config.sh
git commit -m "feat: config の3層解決と出所の記録を追加する"
```

---

### Task 4: シェルへの受け渡しと `lib.sh` / `check_file.sh` / `audit.sh` の配線

**Files:**
- Modify: `scripts/harness_config.py`(`--shell`)
- Modify: `scripts/lib.sh`
- Modify: `scripts/check_file.sh`
- Modify: `scripts/audit.sh`
- Test: `tests/test_config.sh`(追記)

**Interfaces:**
- Consumes: Task 3 の `effective`
- Produces: `harness_load_config [root]`(lib.sh)が以下を export する — `HARNESS_CONFIG_ERROR` / `HARNESS_CHECK_SEVERITY`(`id:sev:出所` の空白区切り)/ `HARNESS_EXCLUDE`(改行区切り)/ `HARNESS_LOG_TAIL_LINES` / `HARNESS_SHELLCHECK_MIN_SEVERITY` / `HARNESS_VULTURE_MIN_CONFIDENCE` / `HARNESS_OASDIFF_BASE` / `HARNESS_AUDIT_INTERVAL_DAYS` / `HARNESS_AUDIT_NPM_LEVEL` / `HARNESS_FEEDBACK_OPEN_THRESHOLD`。および `harness_check_severity <id> <既定>` が実効判定を、`harness_check_source <id>` が出所を返す

- [ ] **Step 1: 失敗テストを追記**

`tests/test_config.sh` の `assert_summary` の直前に追加:

```bash
# --- シェルへの受け渡し ---
# eval に渡る以上、引用の回帰は致命的。値にシェルメタ文字を入れて確認する
cat > "$WORK/proj/.feedback/config.yaml" <<'EOF'
check:
  exclude:
    - "vendor dir/**"
    - "$(touch /tmp/harness_pwned); echo x"
EOF
eval "$(python3 "$CFG" --shell "$WORK/proj")"
assert_file_absent "/tmp/harness_pwned" "config の値がシェルコードとして実行されない"
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
[[ "$(printf '%s' "$HARNESS_EXCLUDE" | wc -l | tr -d ' ')" == "1" ]] \
  || fail "exclude は改行区切りで2件になる(実際: [$HARNESS_EXCLUDE])"
assert_contains "$HARNESS_EXCLUDE" "vendor dir/**" "空白を含む glob が割れない"

# --- 判定の参照 ---
cat > "$WORK/proj/.feedback/config.yaml" <<'EOF'
checks:
  vulture:
    severity: skip
EOF
. "$REPO/scripts/lib.sh"
harness_load_config "$WORK/proj"
assert_eq "skip" "$(harness_check_severity vulture warn)" "config の判定が返る"
assert_eq "checks.vulture" "$(harness_check_source vulture)" "出所が返る"
assert_eq "fail" "$(harness_check_severity ruff fail)" "指定の無い検査は呼び出し側の既定"
assert_eq "既定" "$(harness_check_source ruff)" "指定が無ければ出所は既定"
rm -f "$WORK/proj/.feedback/config.yaml"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_config.sh`
Expected: FAIL — `usage: harness_config.py [--keys | --json [root]]`

- [ ] **Step 3: `--shell` 出力を実装**

`harness_config.py` の `_cmd_keys` の前に追加:

```python
def _cmd_shell(root, env):
    """bash が eval する KEY=VALUE を出力する。

    値は必ず shlex.quote で括る。config はリポジトリ内のファイルであり、
    その中身が eval に渡る以上、引用を怠るとファイルがシェルコードとして
    実行される。quote は改行を含む値も安全に括るため exclude もこの形で渡せる。
    """
    import shlex

    eff = effective(root, env)
    out = []

    def emit(name, value):
        out.append(f"{name}={shlex.quote(str(value))}")

    emit("HARNESS_CONFIG_ERROR", eff["error"] or "")
    # 判定は「id:severity:出所」の空白区切り。検査IDと severity と出所は
    # いずれも空白を含まないため、この形で安全に1変数へ収まる
    emit(
        "HARNESS_CHECK_SEVERITY",
        " ".join(f"{cid}:{sev}:{src}" for cid, (sev, src) in sorted(eff["severity"].items())),
    )
    # exclude だけは改行区切り。ユーザーが書く glob には空白を含むパスがありえ、
    # 空白区切りだと "vendor dir/**" が2件に割れる
    emit("HARNESS_EXCLUDE", "\n".join(eff["values"]["check.exclude"][0]))
    emit("HARNESS_LOG_TAIL_LINES", eff["values"]["check.log_tail_lines"][0])
    emit("HARNESS_SHELLCHECK_MIN_SEVERITY", eff["values"]["checks.shellcheck.min_severity"][0])
    emit("HARNESS_VULTURE_MIN_CONFIDENCE", eff["values"]["checks.vulture.min_confidence"][0])
    emit("HARNESS_OASDIFF_BASE", eff["values"]["checks.oasdiff.base"][0])
    emit("HARNESS_AUDIT_INTERVAL_DAYS", eff["values"]["audit.interval_days"][0])
    emit("HARNESS_AUDIT_NPM_LEVEL", eff["values"]["audit.npm_audit_level"][0])
    emit("HARNESS_FEEDBACK_OPEN_THRESHOLD", eff["values"]["feedback.open_threshold"][0])
    print("\n".join(out))
```

`__main__` の `--json` 分岐の前に追加:

```python
    if "--shell" in args:
        rest = [a for a in args if not a.startswith("--")]
        _cmd_shell(rest[0] if rest else os.getcwd(), os.environ)
        sys.exit(0)
```

- [ ] **Step 4: `lib.sh` に読み込みと参照を追加**

`lib.sh` の `SHELLCHECK_SEVERITY=` の行を削除し、`harness_project_root` の定義の後に追加:

```bash
# harness_load_config [ルート] — .feedback/config.yaml を読み、解決済みの値を
# 環境へ載せる。優先順位(環境変数 > 検査 > スタック > 全体 > 既定値)の判断は
# すべて harness_config.py が行い、ここは受け取るだけ。bash 側に既定値を
# 置くと2箇所管理になりドリフトするため、既定値もローダーの出力に含まれる。
harness_load_config() {
  local root="${1:-}"
  [[ -n "$root" ]] || root="$(harness_project_root)"
  local libdir="${BASH_SOURCE[0]%/*}"
  local shell_out
  if ! shell_out="$(python3 "$libdir/harness_config.py" --shell "$root" 2>/dev/null)"; then
    # ローダー自体が起動できない(python3 不在等)。設定なしと同じ扱いで続行する
    HARNESS_CONFIG_ERROR=""
    HARNESS_CHECK_SEVERITY=""
    HARNESS_EXCLUDE=""
    HARNESS_LOG_TAIL_LINES=40
    HARNESS_SHELLCHECK_MIN_SEVERITY=warning
    HARNESS_VULTURE_MIN_CONFIDENCE=80
    HARNESS_OASDIFF_BASE=main
    HARNESS_AUDIT_INTERVAL_DAYS=7
    HARNESS_AUDIT_NPM_LEVEL=high
    HARNESS_FEEDBACK_OPEN_THRESHOLD=3
  else
    eval "$shell_out"
  fi
  SHELLCHECK_SEVERITY="$HARNESS_SHELLCHECK_MIN_SEVERITY"
}

# harness_check_severity <検査ID> <呼び出し側の既定> — 実効判定(fail/warn/skip)。
# config が触っていない検査は、呼び出し側が宣言ゲートで決めた既定をそのまま返す。
harness_check_severity() {
  local id="$1" default="$2" entry
  for entry in ${HARNESS_CHECK_SEVERITY:-}; do
    if [[ "${entry%%:*}" == "$id" ]]; then
      entry="${entry#*:}"
      printf '%s\n' "${entry%%:*}"
      return
    fi
  done
  printf '%s\n' "$default"
}

# harness_check_source <検査ID> — 判定がどこで決まったか(--list-checks 用)。
harness_check_source() {
  local id="$1" entry
  for entry in ${HARNESS_CHECK_SEVERITY:-}; do
    if [[ "${entry%%:*}" == "$id" ]]; then
      printf '%s\n' "${entry##*:}"
      return
    fi
  done
  printf '%s\n' "既定"
}
```

- [ ] **Step 5: `check_file.sh` と `audit.sh` を配線**

`check_file.sh` の `. "$LIBDIR/lib.sh"` の直後に追加(このスクリプトはルートを解決していないため、ここで解決する):

```bash
# 単一ファイル検査でも shellcheck の重大度は config に従う。python3 の起動は
# 実測 約26ms で、このスクリプトが起動する ruff / eslint(数百ms)に対して誤差
harness_load_config
```

`audit.sh` の `cd "$ROOT"` の直後に追加:

```bash
harness_load_config "$ROOT"
```

`audit.sh` の npm 監査行を差し替え:

```bash
  run_audit "npm" "node: npm audit" npm audit "--audit-level=$HARNESS_AUDIT_NPM_LEVEL"
```

- [ ] **Step 6: テストと回帰を確認**

Run: `bash tests/test_config.sh && bash tests/run_tests.sh`
Expected: すべて PASS

- [ ] **Step 7: コミット**

```bash
git add scripts/harness_config.py scripts/lib.sh scripts/check_file.sh scripts/audit.sh tests/test_config.sh
git commit -m "feat: 解決済み設定をシェルへ渡し check_file/audit を配線する"
```

---

### Task 5: `check.sh` — 検査ID付与と判定解決

**Files:**
- Modify: `scripts/check.sh`
- Test: `tests/test_config_wiring.sh`(新規)

**Interfaces:**
- Consumes: Task 4 の `harness_load_config` / `harness_check_severity`
- Produces: `run_stage <stage> <id> <tool> <label> <cmd...>` — 第2引数に検査IDが入る新しい並び。`run_stage_soft` も同じ並び

**注意**: `run_stage` の引数が1つ増える。**46箇所すべてを漏れなく直す**こと。ID の一覧は `python3 scripts/harness_config.py --keys | grep '^check'` で確認できる。

- [ ] **Step 1: 失敗テストを書く**

`tests/test_config_wiring.sh` を作成:

```bash
#!/usr/bin/env bash
# test_config_wiring.sh — config が check.sh の実挙動に効くことを検証する。
#
# パーサ単体のテスト(test_config.sh)では配線を検証できない。ここでは
# 偽の検査ツールを PATH に置き、config の指定で exit code と出力が
# 変わることを確かめる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$REPO/scripts/check.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"

make_fake() { # make_fake <名前> <exit>
  { echo '#!/usr/bin/env bash'
    echo 'case "$*" in *--version*) exit 0 ;; esac'
    echo "exit $2"
  } > "$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}
new_project() { local d="$WORK/$1"; mkdir -p "$d/.feedback"; ( cd "$d" && git init -q . ); printf '%s\n' "$d"; }
run_check() { PATH="$FAKEBIN:$PATH" bash "$CHECK" "$1" 2>&1; }

# --- 検査単位の skip ---
P1="$(new_project skip_one)"
printf '[project]\nname = "t"\n' > "$P1/pyproject.toml"
make_fake ruff 1          # ruff は失敗する
OUT="$(run_check "$P1")"; RC=$?
assert_eq "1" "$RC" "config 無しでは ruff の失敗で exit 1"

printf 'checks:\n  ruff:\n    severity: skip\n' > "$P1/.feedback/config.yaml"
OUT="$(run_check "$P1")"; RC=$?
assert_eq "0" "$RC" "checks.ruff.severity=skip で完了をブロックしない"
assert_contains "$OUT" "SKIP  python: ruff (config: checks.ruff)" "SKIP に出所が出る"

# --- 検査単位で WARN に落とす ---
printf 'checks:\n  ruff:\n    severity: warn\n' > "$P1/.feedback/config.yaml"
OUT="$(run_check "$P1")"; RC=$?
assert_eq "0" "$RC" "severity=warn なら exit 0"
assert_contains "$OUT" "WARN  python: ruff" "WARN として記録される"

# --- 宣言が無くても FAIL に上げる ---
P2="$(new_project fail_on)"
printf '[project]\nname = "t"\n' > "$P2/pyproject.toml"   # [tool.ruff] は書かない
make_fake ruff 0
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; *format*) exit 1 ;; esac'
  echo 'exit 0'
} > "$FAKEBIN/ruff"; chmod +x "$FAKEBIN/ruff"
OUT="$(run_check "$P2")"; RC=$?
assert_eq "0" "$RC" "宣言が無ければ ruff format は WARN(exit 0)"
printf 'checks:\n  ruff-format:\n    severity: fail\n' > "$P2/.feedback/config.yaml"
OUT="$(run_check "$P2")"; RC=$?
assert_eq "1" "$RC" "severity=fail で完了をブロックする"
rm -f "$FAKEBIN/ruff"

# --- スタック単位 ---
P3="$(new_project per_stack)"
printf '[project]\nname = "t"\n' > "$P3/pyproject.toml"
printf 'module t\n\ngo 1.21\n' > "$P3/go.mod"
mkdir -p "$P3/tests"; printf 'def test_x():\n    assert True\n' > "$P3/tests/test_x.py"
make_fake pytest 1
make_fake ruff 0
{ echo '#!/usr/bin/env bash'
  echo 'case "$1" in version|--version) exit 0 ;; esac'
  echo 'exit 0'
} > "$FAKEBIN/go"; chmod +x "$FAKEBIN/go"
printf 'check:\n  python:\n    skip: [test]\n' > "$P3/.feedback/config.yaml"
OUT="$(run_check "$P3")"; RC=$?
assert_eq "0" "$RC" "Python の test だけ外して exit 0"
assert_contains "$OUT" "SKIP  python: pytest (config: check.python.skip)" "スタック層の出所が出る"
assert_contains "$OUT" "PASS  go: test" "他スタックの test は残る"
rm -f "$FAKEBIN/pytest" "$FAKEBIN/ruff" "$FAKEBIN/go"

# --- 環境変数が config に勝つ ---
P4="$(new_project env_wins)"
printf '[project]\nname = "t"\n' > "$P4/pyproject.toml"
make_fake ruff 1
printf 'checks:\n  ruff:\n    severity: fail\n' > "$P4/.feedback/config.yaml"
OUT="$(PATH="$FAKEBIN:$PATH" FEEDBACK_CHECK_SKIP=lint bash "$CHECK" "$P4" 2>&1)"; RC=$?
assert_eq "0" "$RC" "環境変数の skip が config の fail に勝つ"
assert_contains "$OUT" "env.FEEDBACK_CHECK_SKIP" "出所が環境変数になる"
rm -f "$FAKEBIN/ruff"

# --- 壊れた config は FAIL を立てつつ他の検査を続ける ---
P5="$(new_project broken)"
printf '[project]\nname = "t"\n' > "$P5/pyproject.toml"
make_fake ruff 0
printf 'check:\n  skip: [lnit]\n' > "$P5/.feedback/config.yaml"
OUT="$(run_check "$P5")"; RC=$?
assert_eq "1" "$RC" "壊れた config は完了をブロックする"
assert_contains "$OUT" "FAIL  config: .feedback/config.yaml" "config 自体の FAIL が出る"
assert_contains "$OUT" "PASS  python: ruff" "他の検査は既定値で続行する"
rm -f "$FAKEBIN/ruff"

assert_summary
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_config_wiring.sh`
Expected: FAIL — `config 無しでは ruff の失敗で exit 1` は通るが、`checks.ruff.severity=skip` 以降が失敗する

- [ ] **Step 3: `run_stage` を検査ID対応にする**

`check.sh` の `skipped()` 定義を削除し、`run_stage` を差し替え:

```bash
# run_stage <stage> <id> <tool> <label> <cmd...>
# <id> は config が参照する安定した検査ID(harness_config.py の CHECKS と一致させる)。
# 表示ラベルは Node で $PM により変動するため ID には使えない。
# <tool> にコマンド名を渡すと未インストール時に SKIP を記録する(失敗扱いにしない)。
# ツール判定が不要なステージは "-" を渡す。
run_stage() {
  local stage="$1" id="$2" tool="$3" label="$4"; shift 4
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
```

- [ ] **Step 4: config の読み込みと壊れた config の FAIL を追加**

`check.sh` の `cd "$ROOT"` の直後、`SKIP=` の行を削除して追加:

```bash
harness_load_config "$ROOT"
```

`RESULTS=()` 等の初期化の後に追加:

```bash
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
```

- [ ] **Step 5: 46箇所の呼び出しに検査IDを追加**

各呼び出しの `run_stage <stage>` の直後に ID を挿入する。対応は以下(左が現行の label、右が ID):

```
python: ruff → ruff              python: ruff format → ruff-format
python: mypy → mypy              python: pytest → pytest
python: deptry → deptry          python: vulture → vulture
python: import-linter → import-linter
node: $PM run lint → node-lint   node: $PM run typecheck → node-typecheck
node: tsc --noEmit → tsc         node: $PM test → node-test
node: $PM run test:coverage → node-test-coverage
node: $PM run build → node-build node: npm ls → npm-ls
node: prettier → prettier        node: knip → knip
go: vet → go-vet                 go: build → go-build
go: test → go-test               go: mod verify → go-mod-verify
go: gofmt → gofmt
rust: clippy → clippy            rust: check → cargo-check
rust: test → cargo-test          rust: metadata → cargo-metadata
rust: cargo fmt → cargo-fmt
java: mvn verify → mvn           java: gradlew check → gradle
java: gradle check → gradle
shell: bash -n → bash-syntax     shell: shellcheck → shellcheck
config: json 構文 → json-syntax  config: yaml 構文 → yaml-syntax
docs: 内部リンク → md-links      security: secretlint → secretlint
security: gitleaks → gitleaks    ci: actionlint → actionlint
docker: dockerfilelint → dockerfilelint
docker: hadolint → hadolint      contract: oasdiff → oasdiff
contract: cargo semver-checks → cargo-semver-checks
make check → make-check
```

例(Python 節の先頭):

```bash
  run_stage lint "ruff" "ruff" "python: ruff" ruff check .
  if grep -q "^\[tool\.ruff" pyproject.toml 2>/dev/null; then
    run_stage format "ruff-format" "ruff" "python: ruff format" ruff format --check .
  else
    run_stage_soft format "ruff-format" "ruff" "python: ruff format" ruff format --check .
  fi
```

あわせてツール固有パラメータを反映:

```bash
    run_stage lint "vulture" "vulture" "python: vulture" \
      vulture . --min-confidence "$HARNESS_VULTURE_MIN_CONFIDENCE"
```

```bash
  run_stage lint "shellcheck" "shellcheck" "shell: shellcheck" \
    shellcheck -x -S "$SHELLCHECK_SEVERITY" "${SH_FILES[@]}"
```

```bash
  BASE_SHA="$(git merge-base HEAD "$HARNESS_OASDIFF_BASE" 2>/dev/null \
    || git rev-parse HEAD 2>/dev/null)"
```

**`skipped()` の残り1箇所を忘れないこと。** `skipped()` は `run_stage` の他に Node の tsc プローブでも使われている(現行 193 行目)。関数を消すとここが `command not found` で壊れる。判定の参照に置き換える:

```bash
      # typecheck が既に skip なら、未導入プローブに時間をかけない
      if [[ "$(harness_check_severity tsc fail)" == "skip" ]] \
         || npx --no-install tsc --version >/dev/null 2>&1; then
        run_stage typecheck "tsc" "-" "node: tsc --noEmit" npx --no-install tsc --noEmit
      else
        RESULTS+=("SKIP  node: tsc --noEmit (typescript 未インストール)")
      fi
```

置き換え漏れが無いことを確認する:

```bash
grep -n 'skipped' scripts/check.sh    # 何も出なければ OK
```

- [ ] **Step 6: 呼び出しの漏れを確認**

Run: `grep -cE '^\s*run_stage(_soft)? ' scripts/check.sh`
Expected: `46`

Run: `grep -oE '^\s*run_stage(_soft)? [a-z]+ "[a-z-]+"' scripts/check.sh | grep -oE '"[a-z-]+"$' | tr -d '"' | sort -u | wc -l`
Expected: `41`(`--keys` の検査ID数と一致)

- [ ] **Step 7: テストと回帰を確認**

Run: `bash tests/test_config_wiring.sh && bash tests/run_tests.sh`
Expected: すべて PASS

- [ ] **Step 8: コミット**

```bash
git add scripts/check.sh tests/test_config_wiring.sh
git commit -m "feat: check.sh に検査IDを付与し config の3層判定を反映する"
```

---

### Task 6: `exclude` によるファイル列挙の絞り込み

**Files:**
- Modify: `scripts/check.sh`(`list_files`)
- Test: `tests/test_config_wiring.sh`(追記)

**Interfaces:**
- Consumes: Task 4 の `HARNESS_EXCLUDE`(改行区切り)
- Produces: `list_files <glob>` が `exclude` に一致するパスを出力しない

- [ ] **Step 1: 失敗テストを追記**

`tests/test_config_wiring.sh` の `assert_summary` の直前に追加:

```bash
# --- exclude が検査対象を減らす ---
# 効くのはハーネス自身がファイルを列挙する検査だけ(ruff や pytest のように
# 自分でツリーを歩くツールは各自の無視設定に従う)。ここでは shell 検査で確認する
P6="$(new_project excl)"
mkdir -p "$P6/vendor dir"
printf 'if [ ; then\n' > "$P6/vendor dir/broken.sh"    # 構文エラー
printf 'echo ok\n' > "$P6/good.sh"
OUT="$(run_check "$P6")"; RC=$?
assert_eq "1" "$RC" "exclude 無しでは壊れた .sh で exit 1"

# 空白を含むパスが割れないことも同時に確認する
printf 'check:\n  exclude:\n    - "vendor dir/**"\n' > "$P6/.feedback/config.yaml"
OUT="$(run_check "$P6")"; RC=$?
assert_eq "0" "$RC" "exclude で対象から外れ exit 0"
assert_contains "$OUT" "PASS  shell: bash -n" "残ったファイルは検査される"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_config_wiring.sh`
Expected: FAIL — `exclude で対象から外れ exit 0: expected [0] but got [1]`

- [ ] **Step 3: `list_files` に除外を実装**

`check.sh` の `list_files` を差し替え:

```bash
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
      # -c core.quotePath=false: 非ASCIIファイル名を8進エスケープで出さない
      git -c core.quotePath=false ls-files --cached --others --exclude-standard "$1"
    else
      find . -name "$1" -not -path './.git/*' -not -path './node_modules/*' -not -path './.venv/*'
    fi
  )
}
```

- [ ] **Step 4: テストと回帰を確認**

Run: `bash tests/test_config_wiring.sh && bash tests/run_tests.sh`
Expected: すべて PASS

- [ ] **Step 5: コミット**

```bash
git add scripts/check.sh tests/test_config_wiring.sh
git commit -m "feat: config の exclude で検査対象ファイルを絞り込む"
```

---

### Task 7: `--list-checks`(実効設定の表示)

**Files:**
- Modify: `scripts/check.sh`
- Modify: `scripts/harness_config.py`(`--format-table`)
- Test: `tests/test_config_wiring.sh`(追記)

**Interfaces:**
- Consumes: Task 5 の検査ID、Task 4 の `harness_check_severity` / `harness_check_source`
- Produces: `bash scripts/check.sh --list-checks [root]` が表を出す。`--list-checks --json` で機械可読形

- [ ] **Step 1: 失敗テストを追記**

`tests/test_config_wiring.sh` の `assert_summary` の直前に追加:

```bash
# --- --list-checks ---
P7="$(new_project listing)"
printf '[project]\nname = "t"\n' > "$P7/pyproject.toml"
make_fake ruff 0
printf 'checks:\n  vulture:\n    severity: skip\n' > "$P7/.feedback/config.yaml"

OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" --list-checks "$P7" 2>&1)"; RC=$?
assert_eq "0" "$RC" "--list-checks は exit 0"
assert_contains "$OUT" "検査ID" "見出しが出る"
assert_contains "$OUT" "ruff" "対象の検査が並ぶ"
assert_contains "$OUT" "既定" "config が触っていない検査の出所は既定"
assert_not_contains "$OUT" "cargo-fmt" "対象外スタックの検査は並ばない"

# 検査コマンドを実行しない(一覧表示で pytest や mvn が走ると使い物にならない)
mkdir -p "$P7/tests"; printf 'def test_x():\n    assert True\n' > "$P7/tests/test_x.py"
: > "$WORK/pytest_ran.txt"
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo "echo ran >> \"$WORK/pytest_ran.txt\""
  echo 'exit 0'
} > "$FAKEBIN/pytest"; chmod +x "$FAKEBIN/pytest"
PATH="$FAKEBIN:$PATH" bash "$CHECK" --list-checks "$P7" >/dev/null 2>&1
assert_eq "" "$(cat "$WORK/pytest_ran.txt")" "一覧表示で検査コマンドを実行しない"

# JSON 形式で出所を確認する
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CHECK" --list-checks --json "$P7" 2>&1)"
assert_contains "$OUT" '"id": "vulture"' "JSON に検査IDが出る"
assert_contains "$OUT" '"source": "checks.vulture"' "JSON に出所が出る"
rm -f "$FAKEBIN/ruff" "$FAKEBIN/pytest"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_config_wiring.sh`
Expected: FAIL — `--list-checks は exit 0: expected [0] but got [2]`(引数がディレクトリとして解決できない)

- [ ] **Step 3: 表の整形を実装**

`harness_config.py` の `_cmd_keys` の前に追加:

```python
def _display_width(s):
    """端末上の表示幅。日本語ラベル(config: json 構文 等)は1文字2桁を占める。

    bash の printf %-20s はバイト数で数えるため、日本語を含む列は必ずずれる。
    整形を Python 側に置くのはこのため。
    """
    import unicodedata

    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in s)


def _cmd_format_table(stream):
    """タブ区切りの行を読み、表示幅を揃えて出力する。"""
    header = ["検査ID", "ラベル", "ステージ", "判定", "出所"]
    rows = [line.rstrip("\n").split("\t") for line in stream if line.strip()]
    rows = [r for r in rows if len(r) == len(header)]
    widths = [
        max(_display_width(cell) for cell in [header[i]] + [r[i] for r in rows])
        for i in range(len(header))
    ]

    def fmt(cells):
        out = []
        for i, cell in enumerate(cells):
            pad = widths[i] - _display_width(cell)
            out.append(cell + " " * (pad + 2 if i < len(cells) - 1 else 0))
        return "".join(out).rstrip()

    print(fmt(header))
    for row in rows:
        print(fmt(row))
```

`__main__` に分岐を追加(`--json` の分岐の前):

```python
    if "--format-table" in args:
        _cmd_format_table(sys.stdin)
        sys.exit(0)
```

- [ ] **Step 4: `check.sh` に `--list-checks` を実装**

`check.sh` の `ROOT=` を解決している箇所の直前に引数処理を追加:

```bash
# --list-checks: 検査を実行せず、実効設定(判定と出所)を一覧する。
# 3層にした以上「なぜこの判定なのか」を見る手段が無いと調査不能になる。
# 出力の左端がそのまま config のキーになる
LIST_MODE=0
LIST_JSON=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --list-checks) LIST_MODE=1 ;;
    --json) LIST_JSON=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
```

`run_stage` の冒頭に一覧モードの分岐を追加(`local stage=...` の直後):

```bash
  if [[ "$LIST_MODE" == "1" ]]; then
    # 検査コマンドは実行しない。ツール存在確認だけは通常経路と同じに保ち、
    # 未導入が skip として現れるようにする
    local lsev lsrc
    lsev="$(harness_check_severity "$id" "$([[ "$SOFT_STAGE" == "1" ]] && echo warn || echo fail)")"
    lsrc="$(harness_check_source "$id")"
    if [[ "$tool" != "-" ]] && ! command -v "$tool" >/dev/null 2>&1; then
      lsev="skip"; lsrc="$tool 未インストール"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "$stage" "$lsev" "$lsrc" >> "$LOGDIR/list.txt"
    return
  fi
```

結果出力の直前(`echo "=== feedback-harness check ==="` の前)に追加:

```bash
if [[ "$LIST_MODE" == "1" ]]; then
  if [[ "$LIST_JSON" == "1" ]]; then
    python3 -c '
import json, sys
rows = []
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) == 5:
        rows.append(dict(zip(["id", "label", "stage", "severity", "source"], parts)))
print(json.dumps(rows, ensure_ascii=False, indent=2))
' < "$LOGDIR/list.txt"
  else
    python3 "$LIBDIR/harness_config.py" --format-table < "$LOGDIR/list.txt"
  fi
  exit 0
fi
```

`LOGDIR` の作成直後に一覧ファイルを初期化:

```bash
: > "$LOGDIR/list.txt"
```

- [ ] **Step 5: テストと回帰を確認**

Run: `bash tests/test_config_wiring.sh && bash tests/run_tests.sh`
Expected: すべて PASS

- [ ] **Step 6: 実際の出力を目視確認**

Run: `bash scripts/check.sh --list-checks`
Expected: 検査ID・ラベル・ステージ・判定・出所の5列が桁揃えされて出る(日本語ラベルを含む行もずれない)

- [ ] **Step 7: コミット**

```bash
git add scripts/check.sh scripts/harness_config.py tests/test_config_wiring.sh
git commit -m "feat: --list-checks で実効設定と出所を表示する"
```

---

### Task 8: `feedback_log.py` の配線

**Files:**
- Modify: `scripts/feedback_log.py`
- Test: `tests/test_config.sh`(追記)

**Interfaces:**
- Consumes: Task 3 の `effective`
- Produces: `AUDIT_INTERVAL_DAYS` / open 件数のしきい値が config に従う

- [ ] **Step 1: 失敗テストを追記**

`tests/test_config.sh` の `assert_summary` の直前に追加:

```bash
# --- feedback_log.py が config に従う ---
FB="$REPO/scripts/feedback_log.py"
mkdir -p "$WORK/proj/.feedback/log"
printf '2026-01-01\n' > "$WORK/proj/.feedback/.last-audit"

OUT="$(CLAUDE_PROJECT_DIR="$WORK/proj" python3 "$FB" stats)"
assert_contains "$OUT" "監査を推奨" "既定(7日)では推奨が出る"

printf 'audit:\n  interval_days: 99999\n' > "$WORK/proj/.feedback/config.yaml"
OUT="$(CLAUDE_PROJECT_DIR="$WORK/proj" python3 "$FB" stats)"
assert_not_contains "$OUT" "監査を推奨" "config で間隔を延ばすと推奨が消える"
rm -f "$WORK/proj/.feedback/config.yaml" "$WORK/proj/.feedback/.last-audit"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_config.sh`
Expected: FAIL — `config で間隔を延ばすと推奨が消える: [監査を推奨] が出力に含まれてはいけない`

- [ ] **Step 3: `feedback_log.py` を配線**

`AUDIT_INTERVAL_DAYS = 7` の定義を削除し、`LAST_AUDIT = ...` の後に追加:

```python
# 設定は harness_config が解決する(bash 側と同じ解決規則を使うため、
# ここで環境変数や既定値を独自に読み直さない)
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import harness_config as _hc

    _CFG = _hc.effective(str(ROOT), os.environ)
    if _CFG.get("error"):
        print(f"WARNING: {_CFG['error']}", file=sys.stderr)
except Exception:  # ローダーが壊れていても記録・集計は止めない
    _CFG = {"values": {}}


def _cfg(key, default):
    entry = _CFG.get("values", {}).get(key)
    return entry[0] if entry else default


AUDIT_INTERVAL_DAYS = _cfg("audit.interval_days", 7)
OPEN_THRESHOLD = _cfg("feedback.open_threshold", 3)
```

`open_count >= 3` / `len(opens) >= 3` の3箇所を `>= OPEN_THRESHOLD` に置き換え、メッセージの `3件以上` を `{OPEN_THRESHOLD}件以上` にする。

`audit_status_lines` の `" — 7日超過、監査を推奨"` を `f" — {AUDIT_INTERVAL_DAYS}日超過、監査を推奨"` にする。

- [ ] **Step 4: テストと回帰を確認**

Run: `bash tests/test_config.sh && bash tests/test_stats.sh && bash tests/test_report.sh && bash tests/run_tests.sh`
Expected: すべて PASS

- [ ] **Step 5: コミット**

```bash
git add scripts/feedback_log.py tests/test_config.sh
git commit -m "feat: feedback_log.py の監査間隔と open しきい値を config 化する"
```

---

### Task 9: 雛形・設定ガイド・配布・ドリフト検出

**Files:**
- Create: `.feedback/config.example.yaml`
- Create: `docs/configuration.md`
- Modify: `scripts/init.sh`
- Modify: `README.md` / `scripts/README.md`
- Modify: `CLAUDE.md`
- Test: `tests/test_config.sh`(追記)

**Interfaces:**
- Consumes: Task 2 の `--keys`
- Produces: なし(リリース整備)

- [ ] **Step 1: ドリフト検出テストを追記**

`tests/test_config.sh` の `assert_summary` の直前に追加:

```bash
# --- 雛形とガイドがスキーマと一致する ---
# 設定項目は harness_config.py / config.example.yaml / docs/configuration.md の
# 3箇所に現れる。文書が古いまま残るのを機械的に防ぐ
EXAMPLE="$REPO/.feedback/config.example.yaml"
GUIDE="$REPO/docs/configuration.md"
assert_file_exists "$EXAMPLE" "雛形が存在する"
assert_file_exists "$GUIDE" "設定ガイドが存在する"

MISSING=""
while IFS=$'\t' read -r kind name _ _; do
  case "$kind" in
    key|param) grep -q "${name##*.}" "$EXAMPLE" || MISSING="$MISSING $name(雛形)" ;;
  esac
done < <(python3 "$CFG" --keys)
assert_eq "" "$MISSING" "全設定キーが雛形に載っている"

MISSING=""
while IFS=$'\t' read -r kind name _ _; do
  [[ "$kind" == "check" ]] || continue
  grep -q "\`$name\`" "$GUIDE" || MISSING="$MISSING $name"
done < <(python3 "$CFG" --keys)
assert_eq "" "$MISSING" "全検査IDが設定ガイドに載っている"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_config.sh`
Expected: FAIL — `雛形が存在する: 存在しない`

- [ ] **Step 3: 雛形を作成**

`.feedback/config.example.yaml`:

```yaml
# feedback-harness 設定の雛形
#
# 使い方: このファイルを config.yaml にコピーし、変えたい行だけを残す。
#   cp .feedback/config.example.yaml .feedback/config.yaml
#
# 書かなかった項目はすべて既定値。全部書く必要はない。
# 現在の実効値は `bash scripts/check.sh --list-checks` で確認できる。
# 優先順位: 環境変数 > checks.<検査> > check.<スタック> > check(全体) > 既定値
version: 1

check:
  # 実行しないステージ(全スタック)
  # lint / typecheck / test / build / format / security / docs / contract
  skip: []

  # 宣言が無くても FAIL にするステージ
  fail_on: []

  # FAIL を WARN に落とすステージ(検査はするが完了をブロックしない)
  warn_on: []

  # 検査対象から外すパス glob
  # 注意: 効くのはハーネスがファイルを列挙する検査だけ。ruff や pytest のように
  # 自分でツリーを歩くツールは、それぞれの無視設定に従う
  exclude: []

  # FAIL / WARN 時に出すログの行数
  log_tail_lines: 40

  # スタック単位(python / node / go / rust / java / shell)
  # 全体より優先される
  # python:
  #   skip: [test]
  #   warn_on: [lint]

# 検査単位。最も優先される。検査IDは --list-checks の左端の列
# checks:
#   vulture:
#     severity: skip          # fail | warn | skip
#     min_confidence: 80      # 0-100。下げると検出が増える
#   shellcheck:
#     min_severity: warning   # style | info | warning | error
#   oasdiff:
#     base: main              # API契約差分のベースラインブランチ

audit:
  # 「監査を推奨」を出すまでの経過日数
  interval_days: 7
  # npm audit --audit-level に渡す値: low | moderate | high | critical
  npm_audit_level: high

feedback:
  # promote を促す open エントリ件数
  open_threshold: 3
```

- [ ] **Step 4: 設定ガイドを作成**

`docs/configuration.md` を作成する。構成は設計書 §9 に従い、**動機から引ける形**にする:

1. `## 3分で始める` — `--list-checks` で現状を見る → 雛形をコピー → 1項目変える → もう一度 `--list-checks` で `出所` が変わったことを確認、までを実際のコマンドと出力で示す
2. `## 困りごとから引く` — 以下6つを「症状 / 書く YAML / 出力がどう変わるか」の3点セットで書く: 導入初日に大量 FAIL(`warn_on`)/ 誤検出を止める(`checks.<id>.severity: skip`)/ モノレポで言語別(`check.<stack>`)/ 生成物を除く(`exclude` と効かない範囲)/ CI だけ厳しく(環境変数で被せる)/ 特定ツールを絶対に止める(`severity: fail`)
3. `## 優先順位` — 環境変数 > 検査 > スタック > 全体 > 既定値。「commit したい設定は config、その場限りは環境変数」
4. `## 項目リファレンス` — 設計書 §3.2 の表をそのまま持ち込み、**全41検査IDを一覧**する(バッククォート囲みで書く — Step 1 のドリフト検出テストが `` `<id>` `` を探す)
5. `## 効かないとき` — `--list-checks` で `出所` を見る手順を最初に置く
6. `## YAML の書ける記法・書けない記法` — 設計書 §5.1 / §5.2

冒頭に運用の流れ(導入 → 調整 → 確認 → 共有 → 返済)を置き、**config の差分が負債返済の記録になる**ことを書く。

- [ ] **Step 5: 配布物に追加**

`init.sh` のコピー行に `harness_config.py` を追加:

```bash
cp "$SRC/scripts/check.sh" "$SRC/scripts/check_file.sh" "$SRC/scripts/lib.sh" \
   "$SRC/scripts/audit.sh" "$SRC/scripts/harness_config.py" \
   "$SRC/scripts/feedback_log.py" "$SRC/scripts/README.md" \
   "$DEST/scripts/"
```

`.feedback/` のシード処理に雛形のコピーを追加(`rules.template.md` のコピーの後):

```bash
cp "$SRC/.feedback/config.example.yaml" "$DEST/.feedback/config.example.yaml"
```

`tests/test_init_sh.sh` に追記:

```bash
assert_file_exists "$WORK/target/scripts/harness_config.py" "harness_config.py"
assert_file_exists "$WORK/target/.feedback/config.example.yaml" "config.example.yaml"
```

- [ ] **Step 6: 文書を更新**

`README.md` の環境変数の表の後に設定ファイルの節を追加し、設定ガイドへのリンク `[設定ガイド](docs/configuration.md)` を張る(README はリポジトリ直下にあるためこの相対パスで正しい)。構成ツリーの `.feedback/` に `config.yaml` / `config.example.yaml` を追加する。

`scripts/README.md` の `check.sh` 節に `--list-checks` の使い方を追加し、環境変数の説明に「config より優先される」旨を書く。構成ツリーに `harness_config.py` を追加する。

`CLAUDE.md` の変更履歴に1行追加:

```markdown
| 2026-08-17 | プロジェクト設定ファイル(config.yaml) | harness_config.py / check.sh / lib.sh / docs | 環境変数3つしか可変点が無くチームで共有できない問題。3層(全体・スタック・検査)+ 環境変数の優先順位、--list-checks で実効値と出所を可視化 |
```

- [ ] **Step 7: 全体チェック**

Run: `bash tests/run_tests.sh && bash scripts/check.sh; echo "exit=$?"`
Expected: テスト全 PASS。`check.sh` は exit 0

Run: `bash scripts/check.sh --list-checks`
Expected: このリポジトリの検査が桁揃えされて並ぶ

- [ ] **Step 8: コミット**

```bash
git add .feedback/config.example.yaml docs/configuration.md scripts/init.sh \
        tests/test_init_sh.sh tests/test_config.sh README.md scripts/README.md CLAUDE.md
git commit -m "docs: 設定ガイドと雛形を追加し config を配布物に載せる"
```

---

## 完了後の自省(実行エージェント向け)

計画全体を終えたら、このセッションで共有アーティファクトを変えるべき出来事があったかを1問自省する(CLAUDE.md のトリガーに従う)。実装中に設計と実際が食い違った場合は設計書側も更新してから完了する。

設計書 §11 に繰り越した2件(溜まった負債が行動につながらない / チーム共有と個人環境の feedback が混在)は本計画の対象外。次の設計で扱う。
