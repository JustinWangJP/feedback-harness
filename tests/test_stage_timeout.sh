#!/usr/bin/env bash
# test_stage_timeout.sh — ステージ単位の打ち切りを検証する。
#
# フック側の上限(hooks.json の Stop timeout)に当たるとプロセスごと落とされ、
# 失敗内容もタイムアウトの事実もエージェントへ渡らない。ステージ単位でそれより
# 先に打ち切ることで「どのステージが終わらなかったか」が返る。
#
# 判定は実時間の長さではなく「打ち切りが起きたか」を見る。上限は1秒に固定し、
# 対象は sleep 30 の偽ツール — 遅い実行環境でも早い実行環境でも結果は同じになる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$REPO/scripts/check.sh"

if ! command -v timeout >/dev/null 2>&1; then
  echo "    SKIP: timeout(1) が無い環境(打ち切りは無効・従来動作)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"

# 終わらない ruff。--version には即答するので「未インストール」にはならない
{ echo '#!/usr/bin/env bash'
  echo 'case "$*" in *--version*) exit 0 ;; esac'
  echo 'sleep 30'
} > "$FAKEBIN/ruff"
chmod +x "$FAKEBIN/ruff"

PROJ="$WORK/proj"
mkdir -p "$PROJ/.feedback"
( cd "$PROJ" && git init -q . )
printf '[project]\nname = "t"\n' > "$PROJ/pyproject.toml"

run_check() { PATH="$FAKEBIN:$PATH" bash "$CHECK" "$PROJ" "$@" 2>&1; }

# --- 上限を渡さなければ打ち切らない(CLI / CI の従来動作) ---
# 終わらないツールを待たせるわけにはいかないので、ここでは「打ち切りの既定が
# 0 であること」を --list-checks 相当の速い経路ではなく設定の実効値で確認する
EFF="$(bash -c '. "$1/lib.sh"; harness_load_config "$2"; echo "$HARNESS_STAGE_TIMEOUT_SECONDS"' \
  _ "$REPO/scripts" "$PROJ")"
assert_eq "0" "$EFF" "既定は 0(ハーネスに任せる)"

# --- 呼び出し側の既定(フックが渡す値)で打ち切る ---
OUT="$(run_check --stage-timeout=1)"; RC=$?
assert_eq "1" "$RC" "打ち切りは完了をブロックする"
assert_contains "$OUT" "TIMEOUT  python: ruff" "打ち切りは FAIL ではなく TIMEOUT として出る"
assert_contains "$OUT" "1秒" "上限値が結果に出る"
assert_contains "$OUT" "check.stage_timeout_seconds" "上限の変え方を案内する"

# --- config が呼び出し側の既定に優先する ---
printf 'check:\n  stage_timeout_seconds: 1\n' > "$PROJ/.feedback/config.yaml"
OUT="$(run_check)"; RC=$?
assert_eq "1" "$RC" "config だけでも打ち切る(フック以外の経路にも効く)"
assert_contains "$OUT" "TIMEOUT  python: ruff" "config 指定の打ち切りが TIMEOUT になる"

# --- severity: warn なら打ち切っても完了をブロックしない ---
printf 'check:\n  stage_timeout_seconds: 1\nchecks:\n  ruff:\n    severity: warn\n' \
  > "$PROJ/.feedback/config.yaml"
OUT="$(run_check)"; RC=$?
assert_eq "0" "$RC" "warn なら打ち切りでもブロックしない: $OUT"
assert_contains "$OUT" "WARN  python: ruff (1秒で打ち切り)" "warn では打ち切りが WARN として出る"

# ここから先は打ち切り以外の挙動を見るので、即座に終わる ruff へ差し替える
{ echo '#!/usr/bin/env bash'
  echo 'exit 0'
} > "$FAKEBIN/ruff"
chmod +x "$FAKEBIN/ruff"

# --- 上限が効いている状態でも、shell 関数のステージが消えない ---
# timeout(1) は別プロセスを exec するため、shell 関数(harness_validate_json 等)を
# 渡すと 127 になり、run_stage の「実行不可」判定で検査が黙って SKIP へ落ちる。
# Stop フックは常に上限を渡すので、これを取りこぼすと横断検査が全部消える
printf '{"a": 1}\n' > "$PROJ/data.json"
printf 'a: 1\n' > "$PROJ/data.yaml"
printf '# doc\n' > "$PROJ/doc.md"
rm -f "$PROJ/.feedback/config.yaml"
OUT="$(run_check --stage-timeout=30)"; RC=$?
assert_contains "$OUT" "PASS  config: json 構文" "上限つきでも json 構文検査は実行される"
assert_not_contains "$OUT" "SKIP  config: json 構文 (実行不可)" "関数のステージが実行不可へ落ちない"
assert_contains "$OUT" "PASS  docs: 内部リンク" "上限つきでも内部リンク検査は実行される"
rm -f "$PROJ/data.json" "$PROJ/data.yaml" "$PROJ/doc.md"

# --- 上限内に終わるステージは従来どおり ---
printf 'check:\n  stage_timeout_seconds: 30\n' > "$PROJ/.feedback/config.yaml"
OUT="$(run_check)"; RC=$?
assert_eq "0" "$RC" "上限内に終われば PASS: $OUT"
assert_contains "$OUT" "PASS  python: ruff" "打ち切りが無ければ従来どおり PASS"
assert_not_contains "$OUT" "TIMEOUT" "成功したステージを TIMEOUT にしない"

# --- 不正な --stage-timeout は引数の誤りとして落とす ---
OUT="$(run_check --stage-timeout=abc)"; RC=$?
assert_eq "2" "$RC" "--stage-timeout の不正値は exit 2: $OUT"
assert_contains "$OUT" "--stage-timeout" "どの引数が誤りか出る"

assert_summary
