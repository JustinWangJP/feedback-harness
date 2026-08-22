#!/usr/bin/env bash
# Java stack runner. 共通coreはcheck.shから受け取る。

# shellcheck disable=SC2034 # source元のcheck.shがSTACK_FOUND等を集計する
run_java_checks() {
  if [[ -f pom.xml ]]; then
    STACK_FOUND=1
    run_stage test "mvn" "mvn" "java: mvn verify" mvn -q verify
  elif [[ -f build.gradle || -f build.gradle.kts ]]; then
    STACK_FOUND=1
    if [[ -x ./gradlew ]]; then
      run_stage test "gradle" "-" "java: gradlew check" ./gradlew -q check
    else
      run_stage test "gradle" "gradle" "java: gradle check" gradle -q check
    fi
  fi

}
