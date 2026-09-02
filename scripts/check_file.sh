#!/usr/bin/env bash
# check_file.sh — 編集された単一ファイルの高速チェック(Hooks / 変更直後用)。
# フルビルドはせず、数秒で終わる静的チェックのみ行う。
#
# 使い方: scripts/check_file.sh <ファイルパス>
# 出力: 問題があれば内容を表示して exit 1、なければ exit 0(無出力)。
set -u

usage() {
  cat <<'USAGE'
使い方: bash scripts/check_file.sh <ファイルパス>

  <ファイルパス>  検査する単一ファイル(PostToolUse フックが編集直後に渡す)
  -h, --help      この使い方を表示する

exit 0 = 問題なし(無出力)/ 1 = 問題あり(内容を表示)。
存在しないファイルは exit 0 で通す — 削除直後のファイルを渡されても
完了をブロックしないため。
USAGE
}
# --help だけを特別扱いし、他の "-" 始まりは従来どおりファイル名として扱う。
# 不明オプションを exit 2 にすると、post_edit.sh がファイル名を渡す経路で
# "-" 始まりのファイルが誤ブロックになる(このスクリプトの非0は
# PostToolUse の差し戻しに直結する)
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$LIBDIR/lib.sh"

# 単一ファイル検査でも shellcheck の重大度は config に従う。Python の起動は
# 実測 約26ms で、このスクリプトが起動する ruff / eslint(数百ms)に対して誤差
harness_load_config

# 設定エラー(壊れた .feedback/config.yaml)は check.sh では FAIL 行として
# 見えるが、check_file.sh は黙って exit 0 で通していた。AGENTS.md §2 により
# check_file.sh は編集直後の必須ゲートのため、ここでも表示して非0にする
# (壊れた設定を書いたまま気づかず作業を続けさせない)。
if [[ -n "${HARNESS_CONFIG_ERROR:-}" ]]; then
  echo "check_file: 設定エラーです:"
  echo "$HARNESS_CONFIG_ERROR"
  exit 1
fi

FILE="${1:-}"
[[ -z "$FILE" || ! -f "$FILE" ]] && exit 0

# HARNESS_CHECK_<id>_SEVERITY / HARNESS_EXCLUDE は config 由来。check.sh の全件走査
# だけでなく単発ファイル検査でも同じ判定(severity: skip / exclude)に従う
# (従わないと Stop フックでは SKIP と出るのに PostToolUse は差し戻す食い違いになる)。
ROOT="$(harness_project_root)"
if harness_excluded "$(harness_relpath "$FILE" "$ROOT")"; then
  exit 0
fi

# has() / SHELLCHECK_SEVERITY は lib.sh で定義(check.sh と共有)

# emit <検査ID既定severity取得済みの値> <出力> — severity: warn は指摘を
# 表示するだけで非ブロッキング(WARN_OUT)、それ以外(既定 fail を含む)は
# ブロッキング(OUT)に振り分ける。skip の呼び出し元では呼ばない。
OUT=""
WARN_OUT=""
emit() {
  local sev="$1" text="$2"
  [[ -z "$text" ]] && return
  if [[ "$sev" == "warn" ]]; then
    WARN_OUT="${WARN_OUT:+$WARN_OUT$'\n'}$text"
  else
    OUT="${OUT:+$OUT$'\n'}$text"
  fi
}

case "$FILE" in
  *.py)
    sev="$(harness_check_severity ruff fail)"
    if [[ "$sev" != "skip" ]]; then
      cur=""
      if has ruff; then
        # exit code で判定する(ruffは成功時も "All checks passed!" を出力するため)
        cur="$(ruff check --output-format=concise "$FILE" 2>&1)" && cur=""
      elif harness_has_python; then
        cur="$(harness_python -m py_compile "$FILE" 2>&1)" && cur=""
        # harness_python の CR 正規化は stdout だけを通す。ここは 2>&1 で
        # stderr(py_compile の SyntaxError 本文)を取り込むため、この経路の
        # CR は capture 側で落とす
        cur="${cur//$'\r'/}"
      fi
      emit "$sev" "$cur"
    fi
    ;;
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs)
    sev="$(harness_check_severity node-lint fail)"
    if [[ "$sev" != "skip" ]]; then
      cur=""
      # npx --no-install は「未インストール」も「lint 違反」も非0で返すため、
      # 設定ファイルの有無だけをゲートにすると eslint 未導入のプロジェクトで
      # npm の内部エラー(missing packages)がそのまま差し戻される。check.sh の
      # prettier / knip / secretlint と同じく --version で事前プローブし、
      # 未導入は検査せず素通しする(単一ファイル検査に SKIP の出口は無いため)
      # 設定ファイル名は固定列挙にしない。ESLint は eslintrc 系(.eslintrc /
      # .eslintrc.{js,cjs,mjs,json,yml,yaml})とフラット系(eslint.config.{js,mjs,
      # cjs,ts,mts,cts})を探索するため、4種だけを列挙すると .eslintrc.cjs
      # (package.json が "type": "module" のときの定番)や eslint.config.cjs を
      # 使うプロジェクトで検査が丸ごと飛ぶ。Stop 側(checks/node.sh)は
      # `$PM run lint` を実行するため設定形式に依存せず動くので、
      # PostToolUse だけが見逃して Stop で初めて出る食い違いになっていた。
      # check.sh の prettier / knip と同じく compgen のグロブで列挙漏れを避ける
      # (2026-09-02 の全体レビュー由来)
      # ESLint が判定を返したか。返していない(起動できない・致命的エラー)
      # ときは構文検査へ倒す — 「lint を試みた」ことを理由に検査ゼロで
      # 素通しすると、壊れた設定のプロジェクトだけ PostToolUse が無検査になる
      eslint_verdict=0
      if has npx && harness_has_eslint_config \
         && npx --no-install eslint --version >/dev/null 2>&1; then
        # formatter は指定しない。`--format unix` / `compact` は ESLint 10 で
        # core から外れ、指定すると "The unix formatter is no longer part of
        # core ESLint" というツール自身のエラーが**ユーザーのファイルの問題**
        # として差し戻される(実測: eslint 10.1.0)。既定の stylish は core に
        # 残り続けている唯一の選択肢で、1件1行+位置つきでエージェントにも読める。
        # 環境の問題をユーザーのコードの失敗として報告しない、という check の契約側を優先する
        cur="$(npx --no-install eslint "$FILE" 2>&1)"
        eslint_rc=$?
        # ESLint の終了コードは 0=指摘なし / 1=lint 違反 / 2=致命的エラー
        # (設定が見つからない・プラグイン解決失敗など)。「非0なら違反」と
        # 扱うと、eslintrc しか持たないプロジェクト(ESLint 9 以降は読まない)で
        # 「eslint.config.js が見つからない」というツール側の都合が、
        # 編集のたびにユーザーのファイルの問題として差し戻される(実測 10.1.0)
        case "$eslint_rc" in
          0) eslint_verdict=1; cur="" ;;
          1) eslint_verdict=1 ;;
          *)
            # 判定は得られていない。差し戻しはしないが、黙って捨てると
            # 「lint されているつもりで一度も lint されない」状態が続くため、
            # 非ブロッキングの WARN として設定の破綻だけは見せる
            # 全文は出さない。この WARN は編集のたびに出るため、原因の行だけに絞る
            # (ESLint の致命的エラーは冒頭数行に理由が出る)
            emit warn "check_file: ESLint を実行できませんでした(exit ${eslint_rc})。設定を確認してください:
$(printf '%s\n' "$cur" | grep -v '^[[:space:]]*$' | head -n 3)"
            cur=""
            ;;
        esac
      fi
      if [[ "$eslint_verdict" -eq 0 ]] && has node \
         && [[ "$FILE" == *.js || "$FILE" == *.mjs || "$FILE" == *.cjs ]]; then
        cur="$(node --check "$FILE" 2>&1)" && cur=""
      fi
      emit "$sev" "$cur"
    fi
    ;;
  *.go)
    sev="$(harness_check_severity gofmt fail)"
    if [[ "$sev" != "skip" ]] && has gofmt; then
      UNFMT="$(gofmt -l "$FILE" 2>&1)"
      [[ -n "$UNFMT" ]] && emit "$sev" "gofmt: 未フォーマット: $UNFMT (gofmt -w を実行せよ)"
    fi
    ;;
  *.rs)
    sev="$(harness_check_severity cargo-fmt fail)"
    if [[ "$sev" != "skip" ]] && has rustfmt; then
      rustfmt --check "$FILE" >/dev/null 2>&1 || emit "$sev" "rustfmt: 未フォーマット: $FILE"
    fi
    ;;
  *.sh)
    bsev="$(harness_check_severity bash-syntax fail)"
    if [[ "$bsev" != "skip" ]]; then
      cur="$(bash -n "$FILE" 2>&1)" || true
      emit "$bsev" "$cur"
    fi
    scsev="$(harness_check_severity shellcheck fail)"
    if [[ "$scsev" != "skip" ]] && has shellcheck; then
      # -S: style/info まで拾うと導入初日のプロジェクトが既存コードで詰まる
      # -x: source 先を追う(追えないだけの SC1091 を問題として報告しない)
      SC="$(shellcheck -x -S "$SHELLCHECK_SEVERITY" -f gcc "$FILE" 2>&1)" || true
      emit "$scsev" "$SC"
    fi
    ;;
  *.json)
    # 検証ロジックは lib.sh に集約(check.sh と同じ判定を保つため)
    sev="$(harness_check_severity json-syntax fail)"
    if [[ "$sev" != "skip" ]]; then
      cur="$(harness_validate_json "$FILE" 2>&1)" && cur=""
      emit "$sev" "$cur"
    fi
    ;;
  *.yaml|*.yml)
    sev="$(harness_check_severity yaml-syntax fail)"
    if [[ "$sev" != "skip" ]]; then
      cur="$(harness_validate_yaml "$FILE" 2>&1)" && cur=""
      emit "$sev" "$cur"
    fi
    ;;
esac

if [[ -n "${OUT// /}" ]]; then
  echo "check_file: $FILE に問題があります:"
  echo "$OUT"
  if [[ -n "${WARN_OUT// /}" ]]; then
    echo
    echo "--- 以下は非ブロッキング(WARN) ---"
    echo "$WARN_OUT"
  fi
  exit 1
fi
if [[ -n "${WARN_OUT// /}" ]]; then
  echo "check_file: $FILE に注意点があります(非ブロッキング):"
  echo "$WARN_OUT"
fi
exit 0
