#!/usr/bin/env bash
# Shell stack runner. 共通coreはcheck.shから受け取る。

# shellcheck disable=SC2034 # source元のcheck.shがSTACK_FOUND等を集計する
run_shell_checks() {
  # check_file.sh が .sh を扱えるのに check.sh 側に対応ステージがないと、
  # シェルスクリプト主体のプロジェクト(ハーネス自身を含む)が一切検査されない。
  SH_FILES=()
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] && SH_FILES+=("$f")
  done < <(list_files '*.sh')
  if [[ ${#SH_FILES[@]} -gt 0 ]]; then
    STACK_FOUND=1
    # shellcheck disable=SC2016  # $@ は内側の bash -c で展開させるため単一引用符が正しい
    run_stage lint "bash-syntax" "-" "shell: bash -n" \
      bash -c 'for f in "$@"; do bash -n "$f" || exit 1; done' _ "${SH_FILES[@]}"
    run_stage lint "shellcheck" "shellcheck" "shell: shellcheck" \
      shellcheck -x -S "$SHELLCHECK_SEVERITY" "${SH_FILES[@]}"
  fi

}
