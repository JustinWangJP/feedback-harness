#!/usr/bin/env bash
# lib.sh — check.sh / check_file.sh が共有するユーティリティ。
#
# 両スクリプトで同じ判定を独立に持つと、片方だけ直して他方が古いまま残る
# (実際に has() でそれが起きた)。共有が必要なものはここに置く。
#
# 使い方: . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# has: コマンドが存在し、かつ実際に起動できるか。
# command -v はファイルの存在と実行ビットしか見ないため、shebang切れのvenv等を
# 「インストール済み」と誤判定し、環境障害がユーザーのコードの失敗として報告される。
# --version を試行し、126(実行不可) / 127(未検出) のときだけ未インストール扱いにする。
# --version を持たないコマンドは別のexit code(1/2等)を返すので影響を受けない。
has() {
  command -v "$1" >/dev/null 2>&1 || return 1
  local rc
  "$1" --version >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 126 || $rc -eq 127 ]] && return 1
  return 0
}

# 重大度しきい値(shellcheck の -S に渡す)。既定は warning。
# style/info まで拾うと、導入初日のプロジェクトが既存コードのSC2086等で
# 完了をブロックされ続けるため、既定では拾わない。
#
# harness_load_config を呼ぶ全ての入口(check.sh / check_file.sh / audit.sh)は
# ロード時に config 値でこの変数を上書きする。よってこの行は「lib.sh を読むが
# harness_load_config を呼ばない」利用者(テストの一部など)向けの後方互換の
# 既定値であり、config の実効値には影響しない。
# shellcheck disable=SC2034  # 読み込み側(check.sh)で使う
SHELLCHECK_SEVERITY="${FEEDBACK_SHELLCHECK_SEVERITY:-warning}"

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

# harness_load_config [ルート] — .feedback/config.yaml を読み、解決済みの値を
# 環境へ載せる。優先順位(環境変数 > 検査 > スタック > 全体 > 既定値)の判断は
# すべて harness_config.py が行い、ここは受け取るだけ。bash 側に既定値を
# 置くと2箇所管理になりドリフトするため、既定値もローダーの出力に含まれる。
# shellcheck disable=SC2034  # 読み込み側(check.sh / check_file.sh / audit.sh)で使う
harness_load_config() {
  local root="${1:-}"
  [[ -n "$root" ]] || root="$(harness_project_root)"
  local libdir="${BASH_SOURCE[0]%/*}"
  local shell_out
  if ! shell_out="$(python3 "$libdir/harness_config.py" --shell "$root" 2>/dev/null)"; then
    # ローダー自体が起動できない(python3 不在等)。既定値で続行するが、
    # FEEDBACK_CHECK_SKIP 等の環境変数による上書きは失われるため、
    # 黙って挙動を変えず HARNESS_CONFIG_ERROR で可視化する(既存の
    # 「config壊れているがFAILを立てて続行する」経路に乗せる)
    HARNESS_CONFIG_ERROR="設定ローダー(harness_config.py)を起動できませんでした(python3 を確認してください)。既定値で続行します — FEEDBACK_CHECK_SKIP 等の環境変数による上書きは適用されません。"
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

# harness_excluded <パス> — config の exclude に一致するか。
# glob の照合は bash の == を使う(**/ を含むパターンも extglob 無しで
# 前方一致的に効かせるため、* が / を跨ぐ bash の既定挙動をそのまま利用する)
#
# check.sh(全件走査)と check_file.sh(単発ファイル)の両方が同じ exclude
# 判定を必要とするため、ここに集約する(片方だけ直して他方が古いまま残る
# ドリフトを避ける — ファイル冒頭のコメント参照)。
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

# harness_relpath <パス> <ルート> — ルート相対パスへ正規化(先頭の ./ や / を除く)。
# check.sh の list_files は git ls-files / find 由来で自然にこの形になるが、
# check_file.sh が受け取るのは Hooks からの絶対パスなので、harness_excluded に
# 渡す前に同じ形へ揃える必要がある。
harness_relpath() {
  local path="$1" root="$2" abs
  case "$path" in
    /*) abs="$path" ;;
    *) abs="$PWD/$path" ;;
  esac
  case "$abs" in
    "$root"/*) printf '%s\n' "${abs#"$root"/}" ;;
    *) printf '%s\n' "${path#./}" ;;
  esac
}

# harness_tree_changed <ルート> <スタンプファイル> — 前回の成功検査以降に
# 作業ツリーが変更されたか。変更あり(=検査が必要)なら 0 を返す。
#
# 応答完了のたびに無条件でフルチェックを走らせると、ファイルを1つも編集
# しない質問応答のターンでも導入先の重いビルド(mvn verify / npm run build 等)
# が毎回動く。mtime で判定するのは、Edit/Write だけでなく Bash 経由の編集や
# 外部エディタの変更も拾うため(ツール種別で判定すると取りこぼす)。
#
# 判定できないときは必ず「変更あり」に倒す。検査を飛ばす方向の誤りは
# 壊れたまま完了できてしまうため、安全側は常に「走らせる」側である。
harness_tree_changed() {
  local root="$1" stamp="$2"
  [[ -f "$stamp" ]] || return 0
  local found
  # ディレクトリも対象に含める。ファイルの mtime だけを見るとファイルの削除を
  # 検出できず(消えたファイルには mtime が無い)、ビルドを壊す削除をしたまま
  # 「変更なし」と判定されてしまう。削除・作成・改名は親ディレクトリの mtime に出る。
  #
  # 除外はVCS・依存・キャッシュ・ハーネス状態のみに絞る。
  # (.feedback には events.jsonl 等のローカル状態も含まれ、記録のたびに
  #  フルチェックが再燃しないよう prune 対象である — test_events_log.sh が固定する)
  # dist/build/target を
  # 一律に除外するとソースを置くプロジェクトで変更を取りこぼすため含めない
  # (検査中に書かれる生成物はスタンプより古くなるので誤検出にはならない)。
  found="$(find "$root" \
    \( -name .git -o -name .feedback -o -name _workspace -o -name node_modules \
       -o -name .venv -o -name venv -o -name __pycache__ -o -name '.*_cache' \) -prune -o \
    -newer "$stamp" -print -quit 2>/dev/null)" || return 0
  [[ -n "$found" ]]
}

# harness_json_escape <文字列> — JSON文字列リテラルの中身として安全な形にする。
# バックスラッシュ・二重引用符・改行/タブだけを潰す最小実装(events.jsonl に
# 載る値はファイルパスと固定ラベルのみのため、この範囲で足りる)。
# エスケープを怠ると、該当行を load_events() が JSON として読めず黙って
# 捨てる(パスに引用符やバックスラッシュを含むだけで計測から消える)。
harness_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# harness_log_event <ルート> <hook> <result> [ファイル] — フック合否を
# .feedback/events.jsonl に1行追記する(stats/report の原料。ローカル状態で共有しない)。
#
# 記録がフック本体を壊してはならないため、すべての失敗は黙って無視する。
# 無限増長を防ぐため 512KB を超えたら末尾2000行に切り詰める。
harness_log_event() {
  local root="$1" hook="$2" result="$3" file="${4:-}"
  # 同一 local 文で直前の変数を参照すると未定義になる(set -u で落ちる)ため分けて宣言する
  local dir="$root/.feedback"
  local ev="$dir/events.jsonl"
  mkdir -p "$dir" 2>/dev/null || return 0
  local ts
  local rel
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 0
  if [[ -n "$file" ]]; then
    rel="${file#"$root"/}"
    printf '{"ts":"%s","hook":"%s","file":"%s","result":"%s"}\n' \
      "$ts" "$hook" "$(harness_json_escape "$rel")" "$result" >>"$ev" 2>/dev/null || return 0
  else
    printf '{"ts":"%s","hook":"%s","result":"%s"}\n' \
      "$ts" "$hook" "$result" >>"$ev" 2>/dev/null || return 0
  fi
  local size
  size="$(wc -c <"$ev" 2>/dev/null | tr -d ' ')"
  if [[ "$size" =~ ^[0-9]+$ ]] && (( size > 524288 )); then
    tail -n 2000 "$ev" >"$ev.tmp" 2>/dev/null && mv "$ev.tmp" "$ev" 2>/dev/null \
      || rm -f "$ev.tmp" 2>/dev/null
  fi
  return 0
}

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
    "$ts" "$(harness_json_escape "$label")" >>"$ev" 2>/dev/null || return 0
  return 0
}

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
  # 先頭に / を足してから照合する。check.sh の list_files は git ls-files 由来の
  # リポジトリ相対パス(例: .vscode/settings.json)を返し、これは */.vscode/* に
  # マッチしない。正規化しないと最も一般的なJSONCであるトップレベルの
  # .vscode/settings.json が厳密なJSONとして検証され、完了をブロックする
  case "/$1" in
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
  # 引数ゼロの判定を先に済ませる。検証すべきファイルが無いのに
  # PyYAML 検出のため python3 を起動するのは無駄(フックは毎編集で走る)
  [[ $# -eq 0 ]] && return 0
  harness_has_pyyaml || return 0
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
