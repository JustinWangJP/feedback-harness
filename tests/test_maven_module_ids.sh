#!/usr/bin/env bash
# test_maven_module_ids.sh — monorepo の Maven モジュールがそれぞれ独立した
# 検査IDを持ち、判定を base(mvn)から継ぐことを検証する。
#
# 全モジュールを同じ `mvn` で記録すると --list-checks に同じIDの行が並び、
# `checks.mvn.severity` ではモジュールを区別できない。重いモジュールを1つ
# 外すために Maven 検査を丸ごと切るしかなくなる。
# 逆に継承が無いと `check.skip: [test]` がモジュール側に届かず、
# 「ステージごと止めたのに動き続ける」という気づきにくい壊れ方になる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PROJECT="$WORK/proj"
# ルート POM を置かない monorepo。services/api と services-api は slug が
# 衝突する組み合わせ(どちらも services-api)で、連番の付与まで確かめる
mkdir -p "$PROJECT/services/api" "$PROJECT/services-api" "$PROJECT/tools/cli"
( cd "$PROJECT" && git init -q . )
for m in services/api services-api tools/cli; do
  cat > "$PROJECT/$m/pom.xml" <<'XML'
<project><modelVersion>4.0.0</modelVersion></project>
XML
done
( cd "$PROJECT" && git add -A >/dev/null 2>&1 )

list_checks() { # list_checks [追加の環境変数...]
  ( cd "$PROJECT" && env "$@" CLAUDE_PROJECT_DIR="$PROJECT" \
      bash "$REPO/scripts/check.sh" --list-checks 2>&1 )
}

OUT="$(list_checks)"
assert_contains "$OUT" "mvn-services-api" "モジュールごとの検査IDが出る: $OUT"
assert_contains "$OUT" "mvn-tools-cli" "別モジュールも独立したIDを持つ: $OUT"

# slug が衝突する2モジュールが同じIDに潰れていないこと
DUP="$(printf '%s\n' "$OUT" | awk '{print $1}' | grep -c '^mvn-services-api$')"
assert_eq "1" "$DUP" "衝突する slug が同じIDへ潰れない: $OUT"
assert_contains "$OUT" "mvn-services-api-2" "衝突したIDに連番が付く: $OUT"

# 検査IDの行が重複していないこと(同じIDが複数行に出ない)
IDS="$(printf '%s\n' "$OUT" | awk '/^mvn/ {print $1}')"
UNIQ="$(printf '%s\n' "$IDS" | sort -u | wc -l | tr -d ' ')"
TOTAL="$(printf '%s\n' "$IDS" | wc -l | tr -d ' ')"
assert_eq "$TOTAL" "$UNIQ" "--list-checks に同じIDの行が並ばない: $IDS"

# --- base からの継承 -----------------------------------------------------
# ステージ単位の停止がモジュールへ届くこと
OUT="$(list_checks FEEDBACK_CHECK_SKIP=test)"
SKIPPED="$(printf '%s\n' "$OUT" | awk '/^mvn/ && /skip/' | wc -l | tr -d ' ')"
assert_eq "$TOTAL" "$SKIPPED" "ステージ停止が全モジュールへ届く: $OUT"
assert_contains "$OUT" "env.FEEDBACK_CHECK_SKIP" "出所が base の設定として出る: $OUT"

# --- モジュール単位の上書き ---------------------------------------------
mkdir -p "$PROJECT/.feedback"
cat > "$PROJECT/.feedback/config.yaml" <<'YAML'
checks:
  mvn-tools-cli:
    severity: skip
YAML
OUT="$(list_checks)"
assert_contains "$OUT" "checks.mvn-tools-cli" "モジュール単位の設定が実効値になる: $OUT"
OTHERS="$(printf '%s\n' "$OUT" | awk '/^mvn-services/ && /skip/' | wc -l | tr -d ' ')"
assert_eq "0" "$OTHERS" "1モジュールの停止が他モジュールへ波及しない: $OUT"

# 未知のモジュールIDは打ち間違いとして弾く(任意のIDを通すと設定が黙って効かない)
cat > "$PROJECT/.feedback/config.yaml" <<'YAML'
checks:
  mvnn-typo:
    severity: skip
YAML
OUT="$(list_checks)"
assert_contains "$OUT" "未知の検査ID" "派生に見えないIDの打ち間違いは弾く: $OUT"

# --- 文書との同期 --------------------------------------------------------
# 派生検査IDは共有語彙。base を1つ足したのに文書が追いつかないと、利用者は
# 「--list-checks に出るこのIDは何なのか」を調べる先が無い。期待値は
# harness_config.py の DERIVABLE_CHECKS から導出する。
BASES="$(sed -nE 's/^DERIVABLE_CHECKS = \((.*)\)$/\1/p' "$REPO/scripts/harness_config.py" \
  | tr -d '", ' | tr ',' ' ')"
assert_contains "$BASES" "mvn" "DERIVABLE_CHECKS を読み取れている: $BASES"
for doc in docs/configuration.md scripts/README.md scripts/README.ja.md scripts/README.zh-CN.md; do
  for base in $BASES; do
    assert_contains "$(cat "$REPO/$doc")" "$base-" \
      "$doc が派生検査ID($base-<module>)を説明している"
  done
done

assert_summary
