#!/usr/bin/env bash
# Java/Maven runner の wrapper 選択・monorepo・失敗契約を実環境から分離して検証する。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$REPO/scripts/check.sh"
ORIGINAL_PATH="$PATH"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
FAKEBIN="$WORK/bin"
CALL_LOG="$WORK/maven-calls.log"
mkdir -p "$FAKEBIN"
: > "$CALL_LOG"

new_project() {
  local project="$WORK/$1"
  mkdir -p "$project/.feedback"
  (cd "$project" && git init -q .)
  printf '%s\n' "$project"
}

make_global_maven() {
  {
    echo '#!/usr/bin/env bash'
    echo '[[ "$*" == "--version" ]] && exit 0'
    echo 'printf "global|%s\n" "$*" >> "${MAVEN_CALLS:?}"'
    echo 'exit "${MAVEN_EXIT:-0}"'
  } > "$FAKEBIN/mvn"
  chmod +x "$FAKEBIN/mvn"
}

make_wrapper() { # make_wrapper <path> <tag> [executable]
  local path="$1" tag="$2" executable="${3:-yes}"
  mkdir -p "$(dirname "$path")"
  {
    echo '#!/usr/bin/env bash'
    printf 'printf "%%s|%%s\\n" "%s" "$*" >> "${MAVEN_CALLS:?}"\n' "$tag"
    echo 'exit "${MAVEN_EXIT:-0}"'
  } > "$path"
  [[ "$executable" == "yes" ]] && chmod +x "$path"
}

run_check() {
  PATH="$FAKEBIN:$ORIGINAL_PATH" \
    MAVEN_CALLS="$CALL_LOG" MAVEN_EXIT="${MAVEN_EXIT:-0}" \
    bash "$CHECK" "$@" 2>&1
}

# Wrapper がグローバル Maven より優先され、ルート POM では -f を重ねない。
P1="$(new_project wrapper_priority)"
printf '<project/>\n' > "$P1/pom.xml"
make_wrapper "$P1/mvnw" wrapper
make_global_maven
: > "$CALL_LOG"
OUT="$(run_check "$P1")"; RC=$?
assert_eq "0" "$RC" "Maven wrapper 成功時は exit 0"
assert_contains "$OUT" "PASS  java: mvnw verify" "wrapper の実行結果を表示する"
assert_eq "wrapper|-q verify" "$(cat "$CALL_LOG")" "wrapper を正しい引数で一度だけ呼ぶ"

# Wrapper が無い場合はグローバル Maven へフォールバックする。
P2="$(new_project global_fallback)"
printf '<project/>\n' > "$P2/pom.xml"
: > "$CALL_LOG"
OUT="$(run_check "$P2")"; RC=$?
assert_eq "0" "$RC" "グローバル Maven 成功時は exit 0"
assert_contains "$OUT" "PASS  java: mvn verify" "グローバル Maven の結果を表示する"
assert_eq "global|-q verify" "$(cat "$CALL_LOG")" "グローバル Maven を正しい引数で呼ぶ"

# ルート POM が無い monorepo は各 POM を検査し、POM 直下 wrapper を最優先する。
P3="$(new_project nested_projects)"
mkdir -p "$P3/services/a" "$P3/services/b"
printf '<project/>\n' > "$P3/services/a/pom.xml"
printf '<project/>\n' > "$P3/services/b/pom.xml"
make_wrapper "$P3/mvnw" root-wrapper
make_wrapper "$P3/services/a/mvnw" module-wrapper
: > "$CALL_LOG"
OUT="$(run_check "$P3")"; RC=$?
assert_eq "0" "$RC" "ネストした Maven project がすべて成功する"
assert_contains "$OUT" "PASS  java: mvnw verify (services/a/pom.xml)" "POM 直下 wrapper の結果を識別する"
assert_contains "$OUT" "PASS  java: mvnw verify (services/b/pom.xml)" "ルート wrapper fallback の結果を識別する"
EXPECTED_NESTED=$'module-wrapper|-q -f services/a/pom.xml verify\nroot-wrapper|-q -f services/b/pom.xml verify'
assert_eq "$EXPECTED_NESTED" "$(cat "$CALL_LOG")" "各 POM を対応する wrapper で一度ずつ実行する"

# ルート POM があれば reactor の入口だけを実行し、配下 POM を二重実行しない。
P4="$(new_project root_aggregator)"
mkdir -p "$P4/module"
printf '<project/>\n' > "$P4/pom.xml"
printf '<project/>\n' > "$P4/module/pom.xml"
make_wrapper "$P4/mvnw" aggregator
: > "$CALL_LOG"
OUT="$(run_check "$P4")"; RC=$?
assert_eq "0" "$RC" "ルート集約 POM が成功する"
assert_eq "aggregator|-q verify" "$(cat "$CALL_LOG")" "ルート集約 POM を一度だけ実行する"
assert_not_contains "$OUT" "module/pom.xml" "配下 POM を重複して実行しない"

# wrapper の権限不備はグローバル Maven へ黙って逃がさず、環境 SKIP にする。
P5="$(new_project non_executable_wrapper)"
printf '<project/>\n' > "$P5/pom.xml"
make_wrapper "$P5/mvnw" non-executable no
: > "$CALL_LOG"
OUT="$(run_check "$P5")"; RC=$?
assert_eq "0" "$RC" "実行不可 wrapper はコード失敗にしない"
assert_contains "$OUT" "SKIP  java: mvnw verify (実行不可)" "wrapper の権限不備を可視化する"
assert_eq "" "$(cat "$CALL_LOG")" "権限不備時にグローバル Maven を実行しない"
: > "$CALL_LOG"
OUT="$(run_check "$P5" --list-checks)"; RC=$?
assert_eq "0" "$RC" "実行不可 wrapper の一覧表示は exit 0"
assert_contains "$OUT" "skip" "一覧でも wrapper の権限不備を SKIP にする"
assert_contains "$OUT" "Maven wrapper 実行不可" "一覧に wrapper の権限不備を表示する"
assert_eq "" "$(cat "$CALL_LOG")" "権限不備の一覧表示でも Maven を起動しない"

# Maven 自体が起動できない環境は明示的な SKIP にする。
P6="$(new_project missing_maven)"
printf '<project/>\n' > "$P6/pom.xml"
printf '#!/definitely/missing/interpreter\n' > "$FAKEBIN/mvn"
chmod +x "$FAKEBIN/mvn"
: > "$CALL_LOG"
OUT="$(run_check "$P6")"; RC=$?
assert_eq "0" "$RC" "Maven 起動不能は exit 0 の SKIP"
assert_contains "$OUT" "SKIP  java: mvn verify (mvn 起動不可" "Maven 起動不能の理由を表示する"

# Maven の verify 失敗は完了をブロックする。
make_global_maven
P7="$(new_project verify_failure)"
printf '<project/>\n' > "$P7/pom.xml"
: > "$CALL_LOG"
MAVEN_EXIT=3 OUT="$(run_check "$P7")"; RC=$?
assert_eq "1" "$RC" "mvn verify 失敗は exit 1"
assert_contains "$OUT" "FAIL  java: mvn verify" "mvn verify 失敗を FAIL として表示する"
assert_eq "global|-q verify" "$(cat "$CALL_LOG")" "失敗時も verify の呼び出しを記録できる"

# 一覧モードと config skip は Maven を実行しない。
P8="$(new_project list_and_config)"
printf '<project/>\n' > "$P8/pom.xml"
make_wrapper "$P8/mvnw" must-not-run
: > "$CALL_LOG"
OUT="$(run_check "$P8" --list-checks)"; RC=$?
assert_eq "0" "$RC" "Maven 一覧表示は exit 0"
assert_contains "$OUT" "mvn" "一覧に安定 ID mvn を表示する"
assert_contains "$OUT" "java: mvnw verify" "一覧に wrapper の表示名を出す"
assert_eq "" "$(cat "$CALL_LOG")" "一覧表示では wrapper を起動しない"

printf 'checks:\n  mvn:\n    severity: skip\n' > "$P8/.feedback/config.yaml"
: > "$CALL_LOG"
OUT="$(run_check "$P8")"; RC=$?
assert_eq "0" "$RC" "mvn の config skip は exit 0"
assert_contains "$OUT" "SKIP  java: mvnw verify (config: checks.mvn)" "mvn ID に config が配線される"
assert_eq "" "$(cat "$CALL_LOG")" "config skip では wrapper を起動しない"

# 利用者向け3言語文書にも wrapper と fallback の契約を同期する。
for doc in README.md README.ja.md README.zh-CN.md; do
  CONTENT="$(< "$REPO/$doc")"
  assert_contains "$CONTENT" './mvnw' "$doc に Maven wrapper を記載する"
  assert_contains "$CONTENT" 'mvn verify' "$doc にグローバル Maven fallback を記載する"
done
for doc in scripts/README.md scripts/README.ja.md scripts/README.zh-CN.md; do
  CONTENT="$(< "$REPO/$doc")"
  assert_contains "$CONTENT" './mvnw' "$doc に Maven wrapper 優先を記載する"
  assert_contains "$CONTENT" 'pom.xml' "$doc に Maven POM 検出を記載する"
  assert_contains "$CONTENT" '-f' "$doc に複数 POM の個別実行を記載する"
done

assert_summary
