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

# harness_python <args...> — Python 3.10+ を実行する。
#
# Unix では python3、Windows の Git Bash では python だけが PATH にある構成が
# 一般的なので、全入口で同じ順序で解決する。HARNESS_PYTHON には明示したい
# executable 名または Git Bash から実行できる path を指定できる。
#
# 出力の改行は呼び出し側から見て常に LF である。Windows の Python は
# sys.stdout へ CRLF を書き出す(2026-08-24 の Windows CI で実測。当初
# newline="\n" で書くと考えて capture 側の CR 除去を外したところ、
# tests/test_python_boundary.sh が実出力 "true\r\n" を捕まえた)。CR が
# 混ざると eval・文字列比較・行読みが静かに外れるため、経路ごとに落とすのでは
# なくこの境界で一度だけ正規化する — 経路ごとの防御は、足し忘れた経路だけが
# 壊れる形になる。
_harness_python_works() {
  # interpreter として掴んでよいのは実ファイルだけ。command -v は export された
  # shell function も解決するため、これが無いと同名の wrapper 関数が本番の
  # 解決経路を乗っ取る。実際 tests/assert.sh は python3 が無い環境で
  # `export -f python3` の shim を定義しており、その shim は cygpath 変換を
  # 独自に行うので、Windows 経路の検証テストが本番コードではなく shim を
  # 検査してしまっていた(PR #13 レビュー由来)。
  [[ "$(type -t "$1" 2>/dev/null)" == "file" ]] || return 1
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' \
    >/dev/null 2>&1
}

# 解決結果の process 内 cache。
#
# harness_python は PostToolUse フック(毎編集)から何度も呼ばれ、
# _harness_python_works は判定のたびに Python を追加起動する。Windows の
# Python 起動は 200-400ms あり、1編集あたり秒単位の遅延になるため一度だけ解決する。
# cache は HARNESS_PYTHON の値で key し、同一 process 内で指定が変わったら
# 解決し直す(テストが HARNESS_PYTHON を切り替えて検証するため)。
_HARNESS_PYTHON_RESOLVED=0
_HARNESS_PYTHON_CACHE_KEY=""
_HARNESS_PYTHON_CACHED=""

# _harness_python_resolve — 使用する実行可能名を $_HARNESS_PYTHON_CACHED に入れる。
# 見つからなければ非0。command substitution から呼ぶと subshell で cache が
# 捨てられるため、値は戻り値ではなく変数で返す。
_harness_python_resolve() {
  local key="${HARNESS_PYTHON:-}"
  if [[ "$_HARNESS_PYTHON_RESOLVED" != "1" || "$_HARNESS_PYTHON_CACHE_KEY" != "$key" ]]; then
    if [[ -n "$key" ]]; then
      if _harness_python_works "$key"; then
        _HARNESS_PYTHON_CACHED="$key"
      else
        _HARNESS_PYTHON_CACHED=""
      fi
    elif _harness_python_works python3; then
      _HARNESS_PYTHON_CACHED="python3"
    elif _harness_python_works python; then
      _HARNESS_PYTHON_CACHED="python"
    else
      _HARNESS_PYTHON_CACHED=""
    fi
    _HARNESS_PYTHON_RESOLVED=1
    _HARNESS_PYTHON_CACHE_KEY="$key"
  fi
  [[ -n "$_HARNESS_PYTHON_CACHED" ]]
}

_harness_python_exec() {
  local executable="$1"
  shift
  local args=()
  local arg
  for arg in "$@"; do
    # Git Bash の /c/... や /tmp/... は Windows Python には存在しない。
    # MSYS の自動変換は Bash function/command形によって効かない場合があるため、
    # Pythonへ渡す独立した絶対path引数だけを境界で明示変換する。
    #
    # 「/ で始まる」だけを条件にすると、自由テキストを取る CLI
    # (feedback.sh add --summary "/docs 配下は…" 等)の引数まで書き換わり、
    # 記録内容が静かに壊れる。実在する path だけに限定する。
    if [[ -n "${MSYSTEM:-}" && "$arg" == /* && -e "$arg" ]] \
       && command -v cygpath >/dev/null 2>&1; then
      args+=("$(cygpath -w -- "$arg")")
    else
      args+=("$arg")
    fi
  done
  # ハーネスの出力・ログは日本語を含む。Windows の Python は stdout が
  # console/pipe のとき ANSI コードページ(cp932 / cp1252 等)で符号化するため、
  # 何も指定しないと feedback.sh list や --list-checks が UnicodeEncodeError で
  # 落ちる。CI の workflow ではなくここで固定する — workflow に置くと利用者の
  # 環境には届かず、CI だけが「誰も使っていない環境」を検証することになる。
  # 周囲の環境変数は尊重せず上書きする(ハーネスの入出力は常に UTF-8)。
  PYTHONUTF8=1 PYTHONIOENCODING=utf-8 "$executable" "${args[@]}"
}

harness_has_python() {
  _harness_python_resolve
}

harness_python() {
  _harness_python_resolve || return 127
  if [[ -z "${MSYSTEM:-}" ]]; then
    # Unix の Python は LF しか書かない。毎編集フックで走るため、
    # 不要な tr プロセスを挟まない
    _harness_python_exec "$_HARNESS_PYTHON_CACHED" "$@"
    return $?
  fi
  # PIPESTATUS を読むため local 宣言はパイプラインより前に置く
  # (local 自体が $? を潰すが PIPESTATUS はパイプラインが設定する)。
  # 正規化するのは stdout だけ。呼び出し側が 2>&1 で stderr を混ぜる場合は
  # その capture 側で落とす(check_file.sh の py_compile 経路が該当)。
  local status
  _harness_python_exec "$_HARNESS_PYTHON_CACHED" "$@" | tr -d '\r'
  status="${PIPESTATUS[0]}"
  return "$status"
}

# harness_bash_path <path> — Windows native pathをGit Bash pathへ正規化する。
harness_bash_path() {
  local path="$1"
  if [[ -n "${MSYSTEM:-}" && "$path" =~ ^[A-Za-z]:[\\/].* ]] \
     && command -v cygpath >/dev/null 2>&1; then
    cygpath -u -- "$path"
  else
    printf '%s\n' "$path"
  fi
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
# shellcheck disable=SC2120 # source先では引数あり・なしの両方で呼ばれる
harness_project_root() {
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then
    explicit="$(harness_bash_path "$explicit")"
    (cd "$explicit" 2>/dev/null && pwd) || return 1
    return 0
  fi
  local project_dir="${CLAUDE_PROJECT_DIR:-}"
  project_dir="$(harness_bash_path "$project_dir")"
  if [[ -n "$project_dir" && -d "$project_dir" ]]; then
    (cd "$project_dir" && pwd)
    return 0
  fi
  local top
  if top="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$top" ]]; then
    harness_bash_path "$top"
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
  if ! shell_out="$(harness_python "$libdir/harness_config.py" --shell "$root" 2>/dev/null)"; then
    # ローダー自体が起動できない(Python 3.10+ 不在等)。既定値で続行するが、
    # FEEDBACK_CHECK_SKIP 等の環境変数による上書きは失われるため、
    # 黙って挙動を変えず HARNESS_CONFIG_ERROR で可視化する(既存の
    # 「config壊れているがFAILを立てて続行する」経路に乗せる)
    HARNESS_CONFIG_ERROR="設定ローダー(harness_config.py)を起動できませんでした(Python 3.10+ を確認してください)。既定値で続行します — FEEDBACK_CHECK_SKIP 等の環境変数による上書きは適用されません。"
    HARNESS_EXCLUDE=""
    HARNESS_LOG_TAIL_LINES=40
    HARNESS_SHELLCHECK_MIN_SEVERITY=warning
    HARNESS_VULTURE_MIN_CONFIDENCE=80
    HARNESS_OASDIFF_BASE=main
    HARNESS_AUDIT_INTERVAL_DAYS=7
    HARNESS_AUDIT_NPM_LEVEL=high
    HARNESS_FEEDBACK_OPEN_THRESHOLD=3
    HARNESS_FEEDBACK_LOCK_TIMEOUT_SECONDS=10
  else
    eval "$shell_out"
  fi
  SHELLCHECK_SEVERITY="$HARNESS_SHELLCHECK_MIN_SEVERITY"
}

# harness_check_severity <検査ID> <呼び出し側の既定> — 実効判定(fail/warn/skip)。
# config が触っていない検査は、呼び出し側が宣言ゲートで決めた既定をそのまま返す。
harness_check_severity() {
  local id="$1" default="$2" key value
  key="HARNESS_CHECK_${id//-/_}_SEVERITY"
  value="${!key:-}"
  printf '%s\n' "${value:-$default}"
}

# harness_check_source <検査ID> — 判定がどこで決まったか(--list-checks 用)。
harness_check_source() {
  local id="$1" key value
  key="HARNESS_CHECK_${id//-/_}_SOURCE"
  value="${!key:-}"
  printf '%s\n' "${value:-既定}"
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

# harness_node_pm — カレントディレクトリの lockfile から Node のパッケージ
# マネージャ名(npm / pnpm / yarn)を1つ返す。
#
# 判定をスクリプト毎に書くと、同じプロジェクトに対して check.sh と audit.sh が
# 別の PM だと判断する。実際、移行中などで package-lock.json と pnpm-lock.yaml が
# 併存すると、テストは pnpm で走るのに監査は npm audit が動き、実際の依存解決
# (pnpm-lock.yaml)と違うツリーを監査する状態になっていた(出典 20260817-142537)。
#
# npm 以外の lockfile があれば npm ではないと判定する(併存時は npm 以外を優先)。
# npm 系コマンド(npm ls --all / npm audit)は他 PM の lockfile を読めず ENOLOCK で
# 落ちるため、呼び出し側はこの戻り値が npm のときだけ実行し、他は理由付き SKIP とする。
harness_node_pm() {
  if [[ -f yarn.lock ]]; then
    printf 'yarn\n'
  elif [[ -f pnpm-lock.yaml ]]; then
    printf 'pnpm\n'
  else
    printf 'npm\n'
  fi
}

# harness_relpath <パス> <ルート> — ルート相対パスへ正規化(先頭の ./ や / を除く)。
# check.sh の list_files は git ls-files / find 由来で自然にこの形になるが、
# check_file.sh が受け取るのは Hooks からの絶対パスなので、harness_excluded に
# 渡す前に同じ形へ揃える必要がある。
harness_relpath() {
  local path="$1" root="$2" abs
  path="$(harness_bash_path "$path")"
  root="$(harness_bash_path "$root")"
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

# _harness_append_event <ルート> <event JSON> — events.jsonl へ1行足す。
#
# 通常経路は feedback_store.py — repository lock の中で追記し、必要なら
# rotation する。ただし失敗を握り潰すと、Python 不在やロック競合
# (feedback_log.py はコマンド全体の間 lock を保持する。既定 timeout 10秒)で
# イベントが黙って消え、stats/report の初回通過率が過少計上される。
# 「記録が減る」ではなく「合格率が上がったように見える」形で壊れるため、
# 追記に失敗したら shell から直接足して計測を守る(rotation は次の成功時に働く)。
# 記録がフック本体を壊してはならないので、どちらも失敗は無視して 0 を返す。
_harness_append_event() {
  local root="$1" event_json="$2"
  local libdir="${BASH_SOURCE[0]%/*}"
  if ! harness_python "$libdir/feedback_store.py" append-event "$root" "$event_json" \
      --lock-timeout "${HARNESS_FEEDBACK_LOCK_TIMEOUT_SECONDS:-10}" >/dev/null 2>&1; then
    printf '%s\n' "$event_json" >> "$root/.feedback/events.jsonl" 2>/dev/null || true
  fi
  return 0
}

# harness_log_event <ルート> <hook> <result> [ファイル] — フック合否を
# .feedback/events.jsonl に1行追記する(stats/report の原料。ローカル状態で共有しない)。
#
# 記録がフック本体を壊してはならないため、失敗してもフックは止めない。
# 追記経路と欠落時の扱いは _harness_append_event を参照。
# 無限増長を防ぐため 512KB を超えたら末尾2000行に切り詰める。
harness_log_event() {
  local root="$1" hook="$2" result="$3" file="${4:-}"
  # 同一 local 文で直前の変数を参照すると未定義になる(set -u で落ちる)ため分けて宣言する
  local dir="$root/.feedback"
  mkdir -p "$dir" 2>/dev/null || return 0
  local ts
  local rel
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 0
  local event_json
  if [[ -n "$file" ]]; then
    rel="${file#"$root"/}"
    event_json="$(printf '{"ts":"%s","hook":"%s","file":"%s","result":"%s"}' \
      "$ts" "$hook" "$(harness_json_escape "$rel")" "$result")" || return 0
  else
    event_json="$(printf '{"ts":"%s","hook":"%s","result":"%s"}' \
      "$ts" "$hook" "$result")" || return 0
  fi
  _harness_append_event "$root" "$event_json"
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
  mkdir -p "$dir" 2>/dev/null || return 0
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 0
  local event_json
  event_json="$(printf '{"ts":"%s","hook":"stop","result":"warn","check":"%s"}' \
    "$ts" "$(harness_json_escape "$label")")" || return 0
  _harness_append_event "$root" "$event_json"
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
  harness_has_python && harness_python -c "import yaml" >/dev/null 2>&1
}

# harness_validate_json <file...> — JSON 構文を検証する。
# 壊れていれば "path: 理由" を出力して非0。Python 不在時は検証せず成功。
harness_validate_json() {
  harness_has_python || return 0
  local targets=()
  local f
  for f in "$@"; do
    harness_is_jsonc "$f" || targets+=("$f")
  done
  [[ ${#targets[@]} -eq 0 ]] && return 0
  harness_python -c '
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
  # PyYAML 検出のため Python を起動するのは無駄(フックは毎編集で走る)
  [[ $# -eq 0 ]] && return 0
  harness_has_pyyaml || return 0
  harness_python -c '
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
  harness_has_python || return 0
  [[ $# -eq 0 ]] && return 0
  harness_python -c '
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
