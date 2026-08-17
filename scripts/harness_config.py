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
import sys  # noqa: F401 — 後続タスク(CLI化)で sys.argv/stderr を使うためのプレースホルダ


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
