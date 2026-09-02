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
# フックが渡す上限秒の既定。config が明示していればそちらが優先される
# (利用者の指定が、呼び出し側の都合より強い)
STAGE_TIMEOUT_FALLBACK=0
ARGS=()
usage() {
  cat <<'USAGE'
使い方: check.sh [プロジェクトルート] [--list-checks [--json]] [--stage-timeout=<秒>]

  (引数なし)          プロジェクトを自動検出してフル検査を実行する
  --list-checks       検査を実行せず、実効設定(判定と出所)を一覧する
  --json              --list-checks の出力を JSON にする(単独では使えない)
  --stage-timeout=<秒> config が指定していないときに使う1ステージの上限秒。
                      Stop フックがフック制限より短い値を渡すために使う
                      (config の check.stage_timeout_seconds が優先)
  -h, --help          この使い方を表示する

exit 0 = 全PASS(SKIP含む) / 1 = FAIL・TIMEOUTあり / 2 = 引数・環境の誤り
USAGE
}
for arg in "$@"; do
  case "$arg" in
    --list-checks) LIST_MODE=1 ;;
    --json) LIST_JSON=1 ;;
    --stage-timeout=*)
      STAGE_TIMEOUT_FALLBACK="${arg#*=}"
      if [[ ! "$STAGE_TIMEOUT_FALLBACK" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --stage-timeout には0以上の整数を指定します: ${arg#*=}" >&2
        exit 2
      fi
      ;;
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

# ステージの上限秒。config が 0(=ハーネスに任せる)なら呼び出し側の既定を使う。
# timeout(1) が無い環境では打ち切らない — 打ち切れないことを黙って
# 「打ち切った」ように見せないため、その旨は使う直前で判定する
STAGE_TIMEOUT="$HARNESS_STAGE_TIMEOUT_SECONDS"
[[ "$STAGE_TIMEOUT" -eq 0 ]] && STAGE_TIMEOUT="$STAGE_TIMEOUT_FALLBACK"
HAS_TIMEOUT_CMD=0
if [[ "$STAGE_TIMEOUT" -gt 0 ]] && has timeout; then
  # 存在だけでは使えない。BusyBox(Alpine)の timeout は --kill-after を持たず、
  # Windows の System32\timeout.exe は同名の別ツールである。渡せないフラグを
  # 渡すと使用法エラー(非0)が「ステージの失敗」として報告される — 環境の
  # 問題をユーザーのコードの失敗にしないという check.sh の契約に反する。
  # gitleaks と同じく、必要なフラグがヘルプに出ることを確認してから使う
  if timeout --help 2>&1 | grep -q -- "--kill-after"; then
    HAS_TIMEOUT_CMD=1
  fi
fi

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
  RESULTS+=("FAIL  config: 設定エラー")
  {
    echo "----- FAIL: config: 設定エラー -----"
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
  local rc timed_out=0
  # 包めるのは外部コマンドだけ。timeout(1) は別プロセスを exec するため、
  # shell 関数(harness_validate_json / harness_validate_yaml /
  # harness_check_md_links)を渡すと "No such file or directory" で 127 になり、
  # run_stage の 126/127 判定によって検査が黙って SKIP へ落ちる — 打ち切りを
  # 足したせいで検査が消える、という最悪の壊れ方になる。関数側はいずれも
  # 短時間の Python 呼び出しで、時間切れの対象は導入先のビルドツールである
  if [[ "$HAS_TIMEOUT_CMD" -eq 1 && "$(type -t "$1")" == "file" ]]; then
    # --kill-after: TERM を無視するビルドツール(gradle daemon 等)を確実に止める。
    # 打ち切りは 124(TERM で止まった)か 137(KILL まで要した)で戻る。137 は
    # OOM kill でも起きるため、包んだ実行に限って打ち切り扱いとする — どちらも
    # 完了をブロックする結果で、判断材料のログ末尾も同じように出す
    timeout --kill-after=10 "$STAGE_TIMEOUT" "$@" >"$log" 2>&1
    rc=$?
    [[ $rc -eq 124 || $rc -eq 137 ]] && timed_out=1
  else
    "$@" >"$log" 2>&1
    rc=$?
  fi
  if [[ $rc -eq 0 ]]; then
    RESULTS+=("PASS  $label")
  elif [[ $timed_out -eq 1 ]]; then
    # 打ち切りを FAIL と同じ見た目にしない。「テストが落ちた」と
    # 「時間内に終わらなかった」は次にやることが違う(前者は修正、
    # 後者は分割・除外・上限の見直し)。判定は severity に従う
    if [[ "$sev" == "warn" ]]; then
      WARNED=1
      RESULTS+=("WARN  $label (${STAGE_TIMEOUT}秒で打ち切り)")
      {
        echo "----- TIMEOUT: $label ($*) — ${STAGE_TIMEOUT}秒で打ち切り・末尾${HARNESS_LOG_TAIL_LINES}行 -----"
        tail -n "$HARNESS_LOG_TAIL_LINES" "$log"
      } >> "$LOGDIR/warnings.txt"
    else
      FAILED=1
      RESULTS+=("TIMEOUT  $label (${STAGE_TIMEOUT}秒)")
      {
        echo "----- TIMEOUT: $label ($*) — ${STAGE_TIMEOUT}秒で打ち切り・末尾${HARNESS_LOG_TAIL_LINES}行 -----"
        tail -n "$HARNESS_LOG_TAIL_LINES" "$log"
        echo "(この上限は check.stage_timeout_seconds で変更できます)"
      } >> "$LOGDIR/failures.txt"
    fi
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
# スタック未検出の案内。SKIP しか無いときにも出す必要があるため関数にする —
# 「対象が JSONC だけ」等で SKIP 行が1本立つと RESULTS が空でなくなり、
# 条件を ${#RESULTS[@]} だけに置くと案内が黙って消える(実際に消えた)
no_stack_hint() {
  echo "検出できたスタックがありません (pyproject.toml / package.json / go.mod / Cargo.toml / pom.xml / *.sh / Makefile:check を確認)"
}
echo "=== feedback-harness check ==="
if [[ $STACK_FOUND -eq 0 && ${#RESULTS[@]} -eq 0 ]]; then
  no_stack_hint
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
  echo "以下の失敗(TIMEOUT を含む)を修正してから完了とすること:"
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
  # 全SKIPかつスタック未検出なら、SKIP の理由より先に「どこを見ればよいか」が要る
  [[ $STACK_FOUND -eq 0 ]] && no_stack_hint
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
