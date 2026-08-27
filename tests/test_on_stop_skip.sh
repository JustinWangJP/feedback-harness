#!/usr/bin/env bash
# test_on_stop_skip.sh — Stop フックが「必要なときだけ」フルチェックを走らせることを検証する。
#
# 無条件実行に戻ると、質問応答だけのターンでも導入先の重いビルドが毎回動く。
# 逆に飛ばしすぎると壊れたまま完了できてしまうため、境界の両側を固定する。
#
# mtime は秒精度のため sleep で差をつけたくなるが、テストが遅くなり
# (このスイート自体が毎ターン走る)判定も環境時刻に左右される。
# touch -t で明示的に時刻を与えて決定的にする。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
. "$REPO/scripts/lib.sh"

OLD=202601010000   # 基準より古い
MID=202601020000   # スタンプ
NEW=202601030000   # スタンプより新しい

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/proj/sub" "$WORK/proj/.feedback/log" "$WORK/proj/.git"
# ディレクトリも判定対象(削除検出のため)なので、mkdir 直後の現在時刻のまま
# だと初期状態が「変更あり」になる。ツリー全体を基準より古くしてから始める
touch -t "$OLD" "$WORK/proj/sub/code.py" "$WORK/proj/sub" "$WORK/proj"
STAMP="$WORK/proj/.feedback/.last-check"

changed() { # changed → "yes" / "no"
  if harness_tree_changed "$WORK/proj" "$STAMP"; then echo yes; else echo no; fi
}

# --- harness_tree_changed の境界 ---
assert_eq "yes" "$(changed)" "スタンプが無ければ検査する(初回・安全側)"

: > "$STAMP"; touch -t "$MID" "$STAMP"
assert_eq "no" "$(changed)" "スタンプ以降に変更が無ければ検査を飛ばす"

touch -t "$NEW" "$WORK/proj/sub/code.py"
assert_eq "yes" "$(changed)" "ファイルが変更されたら検査する"

# 除外対象(VCS・ハーネス状態)の更新だけでは検査を起こさない。
# .feedback は検査中に自身が書き換わるため、含めると毎回「変更あり」になる
touch -t "$OLD" "$WORK/proj/sub/code.py"
touch -t "$NEW" "$WORK/proj/.git/index" "$WORK/proj/.feedback/log/entry.md"
assert_eq "no" "$(changed)" ".git/.feedback の更新は検査を起こさない"

# ファイルの削除も検出する。消えたファイルには mtime が無いため、ファイルだけを
# 見ていると「ビルドを壊す削除」をしたまま検査が飛ばされる(親ディレクトリの
# mtime で拾う)
touch -t "$OLD" "$WORK/proj/sub/gone.py"
touch -t "$OLD" "$WORK/proj" "$WORK/proj/sub"
assert_eq "no" "$(changed)" "前提: 削除前は変更なし"
rm "$WORK/proj/sub/gone.py"
assert_eq "yes" "$(changed)" "ファイルの削除を検出する"
touch -t "$OLD" "$WORK/proj" "$WORK/proj/sub"

# --- on_stop.sh を偽の check.sh 付きで動かす ---
mkdir -p "$WORK/fake/hooks"
cp "$REPO/scripts/hooks/on_stop.sh" "$WORK/fake/hooks/"
cp "$REPO/scripts/lib.sh" "$WORK/fake/"
RAN="$WORK/ran.marker"
# 実行の有無はマーカーで見る。成功時のフックは check の出力を握って何も出さない
# (エージェントへ返すのは失敗時だけ)ので、出力の有無では実行を判定できない
fake_check() { # fake_check <exit code>
  { echo '#!/usr/bin/env bash'
    echo 'echo CHECK-WAS-RUN'
    echo "touch \"$RAN\""
    echo "exit $1"
  } > "$WORK/fake/check.sh"
  chmod +x "$WORK/fake/check.sh"
}
# 出力は $HOOK_OUT に置き、終了コードは返り値で返す。コマンド置換で呼ぶと
# フックの終了コードがサブシェルに閉じて親に伝わらない
HOOK_OUT=""
run_hook() { # run_hook <stop_hook_active> [HARNESS_PYTHON の値]
  local active="$1" py="${2:-}" rc
  rm -f "$RAN"
  if [[ -n "$py" ]]; then
    printf '{"stop_hook_active": %s}' "$active" \
      | CLAUDE_PROJECT_DIR="$WORK/proj" HARNESS_PYTHON="$py" \
        bash "$WORK/fake/hooks/on_stop.sh" >"$WORK/out.txt" 2>&1
  else
    printf '{"stop_hook_active": %s}' "$active" \
      | CLAUDE_PROJECT_DIR="$WORK/proj" bash "$WORK/fake/hooks/on_stop.sh" >"$WORK/out.txt" 2>&1
  fi
  rc=$?
  HOOK_OUT="$(cat "$WORK/out.txt")"
  return $rc
}

# 2周目に check.sh を再実行しても出力はエージェントに渡らず時間だけ失う。
# 「常に失敗する check.sh」でも即 exit 0・無出力なら、再実行していない証拠になる
rm -f "$STAMP"
fake_check 1
run_hook true; RC=$?
assert_eq "0" "$RC" "2周目はブロックしない"
assert_file_absent "$RAN" "2周目は check.sh を再実行しない"

# ループ防止が Python の可用性に依存しないこと。judge を Python だけに任せると、
# Python 3.10+ が無い環境で判定が空になり「アクティブでない」と読まれて再び
# ブロックする — check.sh は bash 主体で動くため、失敗が残る限りループが続く
run_hook true "/nonexistent/python"; RC=$?
assert_eq "0" "$RC" "Python が使えなくても2周目はブロックしない"
assert_file_absent "$RAN" "Python が使えなくても2周目は再実行しない"

# フォールバックが「常に素通し」になっていないこと(1周目は検査する)
run_hook false "/nonexistent/python"; RC=$?
assert_eq "2" "$RC" "Python が使えなくても1周目は検査してブロックする"
assert_file_exists "$RAN" "Python が使えなくても1周目は check.sh を実行する"

# 1周目: 変更があり検査が失敗したらブロックし、スタンプを進めない
run_hook false; RC=$?
assert_eq "2" "$RC" "検査が失敗したら exit 2 でブロックする"
assert_file_exists "$RAN" "変更があれば check.sh を実行する"
assert_contains "$HOOK_OUT" "CHECK-WAS-RUN" "失敗内容がエージェントに返る"
assert_file_absent "$STAMP" "失敗時はスタンプを進めない(次ターンで再検査させる)"

# 1周目: 検査が成功したらスタンプを作る
fake_check 0
run_hook false; RC=$?
assert_eq "0" "$RC" "検査が成功したらブロックしない"
assert_file_exists "$RAN" "スタンプが無いので検査は実行される"
assert_file_exists "$STAMP" "成功時はスタンプを作る"

# その直後、変更が無ければ検査しない(ツリーの全ファイルはスタンプより古い)
touch -t "$OLD" "$WORK/proj/sub/code.py"
run_hook false; RC=$?
assert_eq "0" "$RC" "変更が無ければブロックしない"
assert_file_absent "$RAN" "変更が無ければ次のターンで検査しない"

assert_summary
