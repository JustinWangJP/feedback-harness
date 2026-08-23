#!/usr/bin/env bash
# Java stack runner. 共通coreはcheck.shから受け取る。

run_maven_project() { # run_maven_project <pom.xml path>
  local pom="$1"
  local pom_dir="${pom%/pom.xml}"
  local wrapper=""
  local label_suffix=""

  [[ "$pom_dir" == "$pom" ]] && pom_dir="."
  [[ "$pom" != "pom.xml" ]] && label_suffix=" ($pom)"

  # POM と同じプロジェクトの wrapper を最優先し、無ければ repo root の
  # wrapper を使う。-x ではなく -f で選ぶことで、実行権限の欠落を
  # グローバル Maven へ黙ってフォールバックせず SKIP として可視化する。
  if [[ -f "$pom_dir/mvnw" ]]; then
    wrapper="$pom_dir/mvnw"
  elif [[ -f ./mvnw ]]; then
    wrapper="./mvnw"
  fi

  if [[ -n "$wrapper" ]]; then
    if [[ "${LIST_MODE:-0}" == "1" && ! -x "$wrapper" ]]; then
      record_skip "mvn" test "java: mvnw verify${label_suffix}" "Maven wrapper 実行不可"
      return
    fi
    if [[ "$pom" == "pom.xml" ]]; then
      run_stage test "mvn" "-" "java: mvnw verify${label_suffix}" "$wrapper" -q verify
    else
      run_stage test "mvn" "-" "java: mvnw verify${label_suffix}" "$wrapper" -q -f "$pom" verify
    fi
  elif [[ "$pom" == "pom.xml" ]]; then
    run_stage test "mvn" "mvn" "java: mvn verify${label_suffix}" mvn -q verify
  else
    run_stage test "mvn" "mvn" "java: mvn verify${label_suffix}" mvn -q -f "$pom" verify
  fi
}

# shellcheck disable=SC2034 # source元のcheck.shがSTACK_FOUND等を集計する
run_java_checks() {
  local pom
  local -a maven_poms=()

  if [[ -f pom.xml ]]; then
    STACK_FOUND=1
    # ルート POM は reactor/aggregator の入口として一度だけ実行する。
    run_maven_project "pom.xml"
  else
    # ルート POM が無い monorepo では独立した Maven project をすべて検査する。
    # git ls-files の pathspec と find -name の差を吸収し、重複を除く。
    while IFS= read -r pom; do
      [[ -f "$pom" ]] && maven_poms+=("$pom")
    done < <({ list_files 'pom.xml'; list_files '*/pom.xml'; } | sort -u)

    if [[ ${#maven_poms[@]} -gt 0 ]]; then
      STACK_FOUND=1
      for pom in "${maven_poms[@]}"; do
        run_maven_project "$pom"
      done
    fi
  fi

  # Maven と Gradle が併存する構成でも、一方を理由に他方を省略しない。
  if [[ -f build.gradle || -f build.gradle.kts ]]; then
    STACK_FOUND=1
    if [[ -x ./gradlew ]]; then
      run_stage test "gradle" "-" "java: gradlew check" ./gradlew -q check
    else
      run_stage test "gradle" "gradle" "java: gradle check" gradle -q check
    fi
  fi

}
