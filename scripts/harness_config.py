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
    # Python では bool は int のサブクラス(True == 1)なので、isinstance(value, int) だけでは
    # version: true をすり抜けてしまう。_check_type の int 分岐と同じくここでも明示的に除外する
    if (
        not isinstance(version, int)
        or isinstance(version, bool)
        or version > SCHEMA_VERSION
    ):
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
    # values は "section.key" / "checks.<id>.key" のパスをネストした dict として持つ
    # (values["check"]["log_tail_lines"], values["checks"]["vulture"]["min_confidence"])。
    # 出所(source)は変わらずフルパスの文字列(例: "checks.vulture.min_confidence")。
    values = {"checks": {}}

    # 既定値
    for section, keys in SECTIONS.items():
        values[section] = {}
        for key, (_, default, _allowed) in keys.items():
            values[section][key] = (default, "既定")
    for cid, params in CHECK_PARAMS.items():
        values["checks"][cid] = {}
        for key, (_, default, _allowed) in params.items():
            values["checks"][cid][key] = (default, "既定")

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
                    values["checks"].setdefault(cid, {})[key] = (val, f"checks.{cid}.{key}")
        for section, keys in SECTIONS.items():
            body = layer.get(section) or {}
            for key in keys:
                if key in body:
                    values[section][key] = (body[key], f"{section}.{key}")

    # 環境変数(最優先)
    raw = env.get(ENV_STAGE_SKIP, "").strip()
    if raw:
        for stage in raw.split():
            for cid, (_stack, cstage) in CHECKS.items():
                if cstage == stage:
                    severity[cid] = ("skip", f"env.{ENV_STAGE_SKIP}")
    for var, (cid, key) in ENV_PARAM_OVERRIDES.items():
        if env.get(var):
            values["checks"].setdefault(cid, {})[key] = (env[var], f"env.{var}")

    return {"severity": severity, "values": values}


def effective(root, env):
    """load + resolve をまとめた入口。error は呼び出し側が FAIL に使う。"""
    cfg, error = load(root)
    out = resolve([cfg] if cfg else [], env)
    out["error"] = error
    return out


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
