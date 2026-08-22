#!/usr/bin/env python3
# ruff: noqa -- ハーネス配布ファイル(導入元で管理・検査済み。導入先の ruff 設定の対象外)
# fmt: off
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


def _split_flow_list(inner):
    """フローリストの内側を , で分割する。クォート内の , では割らない。

    素朴な str.split(",") は "vendor dir, extra/**" のようなクォート付き
    要素の中のカンマまで区切ってしまい、要素が静かに壊れる(_strip_comment と
    同じクォート追跡ロジックをここでも使う)。
    """
    items = []
    cur = []
    quote = None
    for ch in inner:
        if quote:
            cur.append(ch)
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
            cur.append(ch)
        elif ch == ",":
            items.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    items.append("".join(cur).strip())
    return items


def _scalar(s, path, lineno):
    if s == "":
        return None
    if s[0] == "[":
        # 閉じ括弧が無いまま裸文字列として通すと「書いたのに効かない」の
        # 典型(クォート未対応と同じ壊れ方)になるため、行番号付きで落とす
        if s[-1] != "]":
            _die(path, lineno, f"フローリストが閉じていません( ] がありません): {s}")
        inner = s[1:-1].strip()
        if not inner:
            return []
        items = _split_flow_list(inner)
        for x in items:
            _reject_map_item(x, path, lineno)
        return [_scalar(x, path, lineno) for x in items]
    if s[0] in "\"'":
        # 先頭だけクォートで終端が対応していない値("main など)は、そのまま
        # 「クォート込みの裸文字列」として通ってしまうと git merge-base 等の
        # 下流処理が静かに壊れる(実例: checks.oasdiff.base: "main)
        if len(s) < 2 or s[-1] != s[0]:
            _die(path, lineno, f"クォートが閉じていません: {s}")
        return s[1:-1]
    low = s.lower()
    if low in ("true", "false"):
        return low == "true"
    if low in ("null", "~"):
        return None
    if re.fullmatch(r"-?\d+", s):
        return int(s)
    # 小数だけ文字列のまま返すと、PyYAML がある環境と無い環境で同じ config が
    # 別の型になる。整数キーに 7.5 と書いた場合のエラーも「実際: '7.5'」という
    # クォート付きの紛らわしい表示になるため、ここで数値へ寄せる
    if re.fullmatch(r"-?\d+\.\d+", s):
        return float(s)
    return s


def _reject_map_item(s, path, lineno):
    """リスト要素として書かれた「キー: 値」形式を落とす(設計書 §5.2)。

    マップのリストは未対応だが、黙って文字列として受け入れると exclude 等に
    「何にも一致しない glob」が静かに入り、書いたのに効かない状態になる。
    クォートされた文字列("x: y")はマップではないため素通しする。
    """
    if s[:1] in ("\"", "'"):
        return
    m = re.match(r"^(\S+):(\s|$)", s)
    if m:
        _die(path, lineno, f"リストの要素にマップは書けません({m.group(1)}: …)。マップのリストは未対応です")


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
            item_text = body[2:].strip()
            _reject_map_item(item_text, path, lineno)
            item = _scalar(item_text, path, lineno)
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
    "vulture": {"min_confidence": ("int", 80, (0, 100))},
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
    "feedback": {
        "open_threshold": ("int", 3, None),
        "stale_days": ("int", 7, None),
    },
}

# スタック層で使えるキー(全体層の一部)
STACK_KEYS = ["skip", "fail_on", "warn_on"]


def _check_type(kind, value, allowed, where, path):
    if kind == "int":
        if not isinstance(value, int) or isinstance(value, bool):
            raise ConfigError(f"{path}: {where} は整数で指定してください(実際: {value!r})")
        # int の allowed は (最小, 最大) の範囲(閉区間)。範囲制約が無いキーは None のまま
        if allowed is not None:
            lo, hi = allowed
            if not (lo <= value <= hi):
                raise ConfigError(
                    f"{path}: {where} は {lo}〜{hi} の範囲で指定してください(実際: {value!r})"
                )
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

    同じステージが複数のキーに書かれた場合は fail_on > warn_on > skip の順で
    強い判定が勝つ(安全側)。後段の代入が前段を上書きするので、最も安全側
    (fail)にしたいキーを最後に処理する — skip を最後に処理すると、
    fail_on と skip の両方に同じステージがあるとき skip が黙って勝ってしまう
    (「書いたのに効かない」の中でも最悪の、判定そのものが消える壊れ方)。
    """
    for key, sev in (("skip", "skip"), ("warn_on", "warn"), ("fail_on", "fail")):
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
    # values はフルパス "section.key" / "checks.<id>.key" を1本のキーとして持つ
    # フラットな dict(例: values["check.log_tail_lines"], values["checks.vulture.min_confidence"])。
    # Task 4(シェル配線)・Task 8(feedback_log.py 配線)がこのフルパスキーで直接引くため、
    # ここをネストした dict に変えると両タスクの消費コードが壊れる。
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
    if "--shell" in args:
        rest = [a for a in args if not a.startswith("--")]
        _cmd_shell(rest[0] if rest else os.getcwd(), os.environ)
        sys.exit(0)
    if "--format-table" in args:
        _cmd_format_table(sys.stdin)
        sys.exit(0)
    if "--json" in args:
        rest = [a for a in args if not a.startswith("--")]
        root = rest[0] if rest else os.getcwd()
        print(json.dumps(effective(root, os.environ), ensure_ascii=False, sort_keys=True))
        sys.exit(0)
    sys.exit(
        "usage: harness_config.py "
        "[--keys | --json [root] | --shell [root] | --format-table]"
    )
# fmt: on
