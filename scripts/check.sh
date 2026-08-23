#!/usr/bin/env bash
# check.sh — スタック自動検出 → lint / typecheck / test / build を実行し、
# エージェントが読みやすい要約を出力する。失敗があれば exit 1。
#
# 使い方:
#   scripts/check.sh [プロジェクトルート]   # 省略時はカレントディレクトリ
#   FEEDBACK_CHECK_SKIP="test build" scripts/check.sh   # 特定ステージをスキップ
#
# 設計方針:
# - 出力は「エージェントへのフィードバック」なので、成功時は1行、失敗時は
#   末尾に失敗コマンドのログ(tail)を出す。長大なログ全文は出さない。
# - ツールが未インストールのステージは SKIP とし、失敗扱いにしない。
set -u

LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$LIBDIR/lib.sh"

# --list-checks: 検査を実行せず、実効設定(判定と出所)を一覧する。
# 3層にした以上「なぜこの判定なのか」を見る手段が無いと調査不能になる。
# 出力の左端がそのまま config のキーになる
LIST_MODE=0
LIST_JSON=0
ARGS=()
usage() {
  cat <<'USAGE'
使い方: check.sh [プロジェクトルート] [--list-checks [--json]]

  (引数なし)      プロジェクトを自動検出してフル検査を実行する
  --list-checks   検査を実行せず、実効設定(判定と出所)を一覧する
  --json          --list-checks の出力を JSON にする(単独では使えない)
  -h, --help      この使い方を表示する

exit 0 = 全PASS(SKIP含む) / 1 = FAILあり / 2 = 引数・環境の誤り
USAGE
}
for arg in "$@"; do
  case "$arg" in
    --list-checks) LIST_MODE=1 ;;
    --json) LIST_JSON=1 ;;
    -h|--help) usage; exit 0 ;;
    # 未知のオプションはプロジェクトルートとして扱わない。打ち間違いが
    # 「ディレクトリが見つかりません」になると、原因が引数だと気づけない
    -*) echo "ERROR: 不明なオプション: $arg" >&2; usage >&2; exit 2 ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
# --json 単独は黙って無視してフル検査を走らせない。診断系のつもりで叩いた
# 引数がそのまま重い検査を起動するのは、--list-checks が避けた失敗の裏口になる
if [[ "$LIST_JSON" == "1" && "$LIST_MODE" == "0" ]]; then
  echo "ERROR: --json は --list-checks と組み合わせて使います" >&2
  exit 2
fi

ROOT="$(harness_project_root "${1:-}")" \
  || { echo "ERROR: ディレクトリが見つかりません: ${1:-}"; exit 2; }
cd "$ROOT" || { echo "ERROR: ディレクトリへ移動できません: $ROOT"; exit 2; }
harness_load_config "$ROOT"

RESULTS=()
FAILED=0
WARNED=0
SOFT_STAGE=0
STACK_FOUND=0   # マニフェストを検出したか。RESULTS の空判定とは分離する
                # (全ステージがSKIPでも「スタック未検出」とは報告しないため)
LOGDIR="$(mktemp -d)"
trap 'rm -rf "$LOGDIR"' EXIT
: > "$LOGDIR/list.txt"

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

# run_stage <stage> <id> <tool> <label> <cmd...>
# <id> は config が参照する安定した検査ID(harness_config.py の CHECKS と一致させる)。
# 表示ラベルは Node で $PM により変動するため ID には使えない。
# <tool> にコマンド名を渡すと未インストール時に SKIP を記録する(失敗扱いにしない)。
# ツール判定が不要なステージは "-" を渡す。
run_stage() {
  local stage="$1" id="$2" tool="$3" label="$4"; shift 4
  if [[ "$LIST_MODE" == "1" ]]; then
    # 検査コマンドは実行しない。ツール存在確認だけは通常経路と同じに保ち、
    # 未導入・起動不能が skip として現れるようにする。command -v だけでは
    # PATH 上にあるが起動できない(shebang切れのvenv等)ツールを見逃し、
    # 「環境が壊れた」まさにその場面で --list-checks を叩く利用者に誤答する
    local lsev lsrc
    lsev="$(harness_check_severity "$id" "$([[ "$SOFT_STAGE" == "1" ]] && echo warn || echo fail)")"
    lsrc="$(harness_check_source "$id")"
    if [[ "$tool" != "-" ]]; then
      if ! command -v "$tool" >/dev/null 2>&1; then
        lsev="skip"; lsrc="$tool 未インストール"
      elif ! has "$tool"; then
        lsev="skip"; lsrc="$tool 起動不可 — 環境を確認してください"
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "$stage" "$lsev" "$lsrc" >> "$LOGDIR/list.txt"
    return
  fi
  local sev src
  sev="$(harness_check_severity "$id" "$([[ "$SOFT_STAGE" == "1" ]] && echo warn || echo fail)")"
  if [[ "$sev" == "skip" ]]; then
    src="$(harness_check_source "$id")"
    if [[ "$src" == "既定" ]]; then
      RESULTS+=("SKIP  $label")
    elif [[ "$src" == env.* ]]; then
      RESULTS+=("SKIP  $label (${src})")
    elif [[ "$src" == local.* ]]; then
      # 個人設定は .gitignore 済みで他の人からは見えない。共有設定と同じ
      # "config:" で出すと、チーム設定を読んでも理由が見つからず混乱するため区別する
      RESULTS+=("SKIP  $label (個人設定: ${src#local.})")
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

# run_stage_soft — 失敗しても完了をブロックせず WARN として記録する。
# プロジェクトが設定で宣言していない検査(ハーネスの推測)に使う。
run_stage_soft() {
  SOFT_STAGE=1
  run_stage "$@"
  SOFT_STAGE=0
}

# record_skip <id> <stage> <label> <理由> — run_stage を経由しない SKIP を記録する。
# ツール未インストール・宣言なし等、コマンドを起動する前に判定できる SKIP は
# run_stage を呼ばずに直接記録してきたが、--list-checks は run_stage が書く
# list.txt だけを見るため、その経路が丸ごと一覧から消えていた(実際に起きた欠陥)。
# run_stage と同じ出口(list.txt / RESULTS)を通すことで一覧・通常実行の両方に載せる。
record_skip() {
  local id="$1" stage="$2" label="$3" reason="$4"
  if [[ "$LIST_MODE" == "1" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "$stage" "skip" "$reason" >> "$LOGDIR/list.txt"
  else
    RESULTS+=("SKIP  $label${reason:+ ($reason)}")
  fi
}

npm_script_exists() { # package.json に scripts.<name> があるか
  node -e "process.exit(require('./package.json').scripts?.['$1'] ? 0 : 1)" 2>/dev/null
}

# harness_excluded は lib.sh で定義(check_file.sh と共有)。

# 注意: git ls-files は「追跡済みだが作業ツリーから削除された」ファイルも列挙する。
# それらを検査ツールに渡すと読み取りエラーで完了をブロックしてしまう(実測: リンク
# 検査の [Errno 2]、bash -n の非ゼロ終了)。呼び出し側は必ず -f で実在を確認すること
list_files() { # list_files <glob> — 検査対象のファイルを1行1件で出力
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    # find 側は "./foo.sh" 形式で返すため先頭の ./ を落とし、git ls-files 由来の
    # リポジトリ相対パスへ揃える。揃えないと同じ exclude パターンが git 管理下か
    # 否かで効いたり効かなかったりする(利用者には見分けが付かない)。
    # lib.sh の harness_is_jsonc も「先頭に ./ も / も付かない」形を前提にしている
    f="${f#./}"
    harness_excluded "$f" || printf '%s\n' "$f"
  done < <(
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      # --others を含めないと、まだコミットしていない新規ファイルが検査対象外になり、
      # 壊れた新規ファイルがあっても ALL PASS になる。--exclude-standard で
      # .gitignore 済み(ビルド成果物・依存ディレクトリ)は従来どおり除外する
      # -c core.quotePath=false: 非ASCIIファイル名を8進エスケープ("\350\250...")で
      # 出さず生のパスで出す。日本語ファイル名を持つプロジェクトで、受け取り側が
      # ファイルを開けなくなる(実測: .feedback/log/*.md で FileNotFoundError)
      git -c core.quotePath=false ls-files --cached --others --exclude-standard "$1"
    else
      find . -name "$1" -not -path './.git/*' -not -path './node_modules/*' -not -path './.venv/*'
    fi
  )
}

# ---------- Python ----------
# shellcheck source=checks/python.sh
. "$LIBDIR/checks/python.sh"
run_python_checks

# ---------- stack runners ----------
for runner in node go rust java shell; do
  # shellcheck source=/dev/null # runner名は固定リストで、init.shも全ファイルを配布する
  . "$LIBDIR/checks/$runner.sh"
  "run_${runner}_checks"
done
# ---------- cross-cutting / contract / fallback ----------
# shellcheck source=checks/cross_cutting.sh
. "$LIBDIR/checks/cross_cutting.sh"
run_cross_cutting_checks
# ---------- 結果出力 ----------
echo "=== feedback-harness check ==="
if [[ $STACK_FOUND -eq 0 && ${#RESULTS[@]} -eq 0 ]]; then
  echo "検出できたスタックがありません (pyproject.toml / package.json / go.mod / Cargo.toml / pom.xml / *.sh / Makefile:check を確認)"
  exit 0
fi
if [[ ${#RESULTS[@]} -eq 0 ]]; then
  echo "スタックは検出しましたが、実行できるステージがありません"
  exit 0
fi
printf '%s\n' "${RESULTS[@]}"

if [[ $WARNED -eq 1 ]]; then
  echo
  echo "以下は完了をブロックしませんが、確認してください:"
  cat "$LOGDIR/warnings.txt"
fi

if [[ $FAILED -eq 1 ]]; then
  echo
  echo "以下の失敗を修正してから完了とすること:"
  cat "$LOGDIR/failures.txt"
  exit 1
fi

# 全ステージSKIPで "ALL PASS" と出すと、実際には何も検証していないのに
# 検証済みだとエージェントに誤解させる。部分SKIPも件数を添えて明示する
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
