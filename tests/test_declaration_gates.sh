#!/usr/bin/env bash
# test_declaration_gates.sh — 「設定で宣言されているときだけ走らせる」検査ゲートが、
# 宣言ではない位置(説明文・コメント・文字列値)の文言に反応しないことを検証する。
#
# 宣言ゲートは pyproject.toml を grep して判定する。パターンから行頭アンカーや
# ドットのエスケープが抜けると、[project] の description に `[tool.mypy]` と
# 書いただけで「宣言あり」と判定される。mypy には他の宣言ゲート(ruff-format /
# deptry / vulture)のような WARN フォールバック(run_stage_soft)が無く、
# 検出がそのまま FAIL 段階の run_stage 呼び出しになるため、誤検出は
# 「書いていない設定のせいで完了できない」という形で出る。
#
# 判定には --list-checks を使う。ツールを起動せずゲートの結果(行の有無)だけを
# 見られるので、mypy が入っていない環境でも同じ検証ができる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$REPO/scripts/check.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"

new_project() { # new_project <名前>
  local d="$WORK/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}

check_ids() { # check_ids <プロジェクト> — --list-checks を実行し検査ID列を IDS へ入れる
  # 標準出力で返さない。`IDS="$(check_ids …)"` の形にすると、失敗時の fail が
  # command substitution の subshell で起き、ASSERT_FAILURES の加算ごと捨てられる
  # (護欄が自力で落ちられなくなる)。呼び出し側は直接呼んで $IDS を読む。
  # 出力を見る前に終了コードを見る — 落ちると ID 列は空になり、
  # 「mypy が含まれないこと」を確かめる否定形のアサーションが素通しで成立する
  local out rc
  out="$(bash "$CHECK" "$1" --list-checks 2>&1)"; rc=$?
  assert_eq "0" "$rc" "--list-checks が成功する($1): $out"
  IDS="$(printf '%s\n' "$out" | awk '{print $1}')"
}

# --- 宣言ではない位置の文言でゲートが成立しない ---
P1="$(new_project mypy_incidental)"
cat > "$P1/pyproject.toml" <<'TOML'
[project]
name = "demo"
description = "Type-checked with [tool.mypy] settings inherited from the base config"

[tool.ruff]
line-length = 100
TOML
check_ids "$P1"
assert_contains "$IDS" "ruff" "前提: 実在する宣言([tool.ruff])は検出される: $IDS"
assert_not_contains "$IDS" "mypy" "説明文中の [tool.mypy] では mypy を走らせない: $IDS"

# 行頭にあってもコメントなら宣言ではない
P2="$(new_project mypy_comment)"
cat > "$P2/pyproject.toml" <<'TOML'
[project]
name = "demo"
# [tool.mypy] はまだ有効にしていない
TOML
check_ids "$P2"
# 否定形だけだと、--list-checks が何も出さなくなった場合に素通しで成立する。
# 同じ出力に必ず現れるものを対にして、走っていること自体を確かめる
assert_contains "$IDS" "ruff" "前提: pyproject.toml があるので ruff は列挙される: $IDS"
assert_not_contains "$IDS" "mypy" "コメント行の [tool.mypy] では mypy を走らせない: $IDS"

# --- 実在する宣言は従来どおり検出する(検出しない側への退行防止) ---
P3="$(new_project mypy_declared)"
cat > "$P3/pyproject.toml" <<'TOML'
[project]
name = "demo"

[tool.mypy]
strict = false
TOML
check_ids "$P3"
assert_contains "$IDS" "mypy" "[tool.mypy] セクションがあれば mypy を走らせる: $IDS"

# サブテーブルも前方一致で検出する(ruff / deptry / vulture と同じ形)。
# なお `[[tool.mypy.overrides]]`(配列テーブル)は行頭が `[[` のため
# この前方一致には掛からない。ruff 等の既存ゲートも同じ挙動で、mypy は
# `[tool.mypy]` を書くのが前提のため、ここは意図した境界として据え置く。
P4="$(new_project mypy_subtable)"
cat > "$P4/pyproject.toml" <<'TOML'
[project]
name = "demo"

[tool.mypy.plugins]
foo = "bar"
TOML
check_ids "$P4"
assert_contains "$IDS" "mypy" "[tool.mypy.*] のサブテーブルでも mypy を走らせる: $IDS"

# TOML は見出しの前の空白を許す。行頭アンカーだけだとインデントされた見出しを
# 取りこぼし、宣言しているのに検査が走らない(mypy は WARN フォールバックが
# 無いため、取りこぼしはそのまま「型検査ゼロ」になる)
P5="$(new_project mypy_indented)"
cat > "$P5/pyproject.toml" <<'TOML'
[project]
name = "demo"

  [tool.mypy]
  strict = false
TOML
check_ids "$P5"
assert_contains "$IDS" "mypy" "インデントされた見出しでも宣言として扱う: $IDS"

# --- 走査: pyproject.toml を見る宣言ゲートはすべて行頭アンカーを持つ ---
# 個別ケースだけを直すと、同じ抜けが隣のゲートへ再発する(実際 mypy だけが
# ruff / deptry / vulture と違う書き方のまま残っていた)。パターンの形を走査で固定する。
# 走査の形。フラグは固定列挙にしない — `-q` / `-qE` / `-qF` だけを受ける正規表現に
# したところ、`grep -qs`・`grep -q --`・`grep "pat" file >/dev/null` がすべて素通りした
# (2026-09-03 のレビューで実測)。「設定ファイル名を固定列挙しない」と同じ誤りを
# 護欄側で繰り返していたので、フラグ列は任意個の `-...` として受ける。
# パターンはクォート両種類と裸の3形を受ける。
GATE_CALL='grep +(-[^ ]+ +)*("[^"]*"|'"'"'[^'"'"']*'"'"'|[^ ]+) +(pyproject\.toml|setup\.cfg)'
# アンカー済み = フラグ列の直後に来るパターンが(クォートの有無を問わず)^ で始まる
GATE_ANCHORED='grep +(-[^ ]+ +)*["'"'"']?\^'

declaration_gates() { # declaration_gates <ディレクトリ> — 宣言ゲートの grep 呼び出しを全件列挙
  local root="$1" file
  for file in "$root"/*.sh; do
    [[ -f "$file" ]] || continue
    # 行ではなく**一致した grep 呼び出しごと**に取り出して判定する(-o)。
    # 行単位でフィルタすると、1行にアンカー済みと未アンカーの grep が並んだとき
    # 「アンカーを含む行」として丸ごと見逃す
    grep -noE "$GATE_CALL" "$file" | sed "s#^#$(basename "$file"):#"
  done
  return 0
}

unanchored_gates() { # unanchored_gates <ディレクトリ> — うちアンカー無しのものだけ
  declaration_gates "$1" | grep -vE "$GATE_ANCHORED"
  return 0
}

# 走査が実物のゲートに触れていることを先に固定する。これが無いと、
# scripts/checks が移動・改名されただけで対象が0件になり、
# `assert_eq "" "$UNANCHORED"` が「1件も見ていないから空」で成立してしまう
# (否定形のアサーションだけを置いたときの典型的な素通し)。
ALL_GATES="$(declaration_gates "$REPO/scripts/checks")"
assert_contains "$ALL_GATES" "python.sh:" "走査が実際の宣言ゲートを見ている: $ALL_GATES"
for gate in "tool\.ruff" "tool\.mypy" "tool\.deptry" "tool\.vulture" "importlinter"; do
  assert_contains "$ALL_GATES" "$gate" "既知の宣言ゲート($gate)が走査に含まれる: $ALL_GATES"
done

UNANCHORED="$(unanchored_gates "$REPO/scripts/checks")"
assert_eq "" "$UNANCHORED" "宣言ゲートの grep は行頭アンカー(^)を持つ"

# 護欄自身の変異テスト。実リポジトリが偶然きれいなだけでは保証にならない
FIXTURE="$WORK/gate-guard"
mkdir -p "$FIXTURE"
# 再注入は1つの形だけではない。走査が「たまたま見つけられる書き方」しか
# 拾わないと、別の書き方で戻したときに緑のまま通る(2026-09-02 のレビューで
# 実際にこの穴を指摘された)。想定される4形をすべて fixture にする
cat > "$FIXTURE/python.sh" <<'SH'
if grep -q "\[tool.mypy\]" pyproject.toml 2>/dev/null; then
  run_stage typecheck "mypy" "mypy" "python: mypy" mypy .
fi
SH
cat > "$FIXTURE/single_quote.sh" <<'SH'
if grep -q '\[tool.mypy\]' pyproject.toml 2>/dev/null; then :; fi
SH
cat > "$FIXTURE/extended.sh" <<'SH'
if grep -qE "\[tool.mypy\]" pyproject.toml 2>/dev/null; then :; fi
SH
cat > "$FIXTURE/mixed_line.sh" <<'SH'
if grep -q "^\[tool\.ruff" pyproject.toml || grep -q "\[tool.mypy\]" pyproject.toml; then :; fi
SH
# 以下3形は、フラグを -q/-qE/-qF に固定列挙していた旧走査がすべて取りこぼしていた
cat > "$FIXTURE/combined_flag.sh" <<'SH'
if grep -qs "\[tool.mypy\]" pyproject.toml; then :; fi
SH
cat > "$FIXTURE/dash_dash.sh" <<'SH'
if grep -q -- "\[tool.mypy\]" pyproject.toml; then :; fi
SH
cat > "$FIXTURE/redirect.sh" <<'SH'
if grep "\[tool.mypy\]" pyproject.toml >/dev/null 2>&1; then :; fi
SH
cat > "$FIXTURE/ok.sh" <<'SH'
if grep -q "^\[tool\.ruff" pyproject.toml 2>/dev/null; then
  run_stage format "ruff-format" "ruff" "python: ruff format" ruff format --check .
fi
SH
# アンカー済みの別表記は誤検出しない(走査を広げた副作用で真のゲートを弾かないこと)
cat > "$FIXTURE/ok_variants.sh" <<'SH'
if grep -qs "^\[tool\.mypy" pyproject.toml; then :; fi
if grep -q -- "^\[tool\.deptry" pyproject.toml; then :; fi
if grep "^\[importlinter\]" setup.cfg >/dev/null 2>&1; then :; fi
SH
MUTATIONS="$(unanchored_gates "$FIXTURE")"
assert_contains "$MUTATIONS" "python.sh:1" "アンカー無しの宣言ゲートを検出する"
assert_contains "$MUTATIONS" "single_quote.sh:1" "シングルクォートの再注入も検出する"
assert_contains "$MUTATIONS" "extended.sh:1" "grep -qE での再注入も検出する"
assert_contains "$MUTATIONS" "mixed_line.sh:1" \
  "アンカー済みと同じ行に並べた再注入も検出する: $MUTATIONS"
assert_contains "$MUTATIONS" "combined_flag.sh:1" \
  "結合フラグ(-qs)での再注入も検出する: $MUTATIONS"
assert_contains "$MUTATIONS" "dash_dash.sh:1" \
  "-- 区切りを挟んだ再注入も検出する: $MUTATIONS"
assert_contains "$MUTATIONS" "redirect.sh:1" \
  "-q を使わず >/dev/null で黙らせた再注入も検出する: $MUTATIONS"
assert_not_contains "$MUTATIONS" "ok.sh" "アンカー済みのゲートは誤検出しない"
assert_not_contains "$MUTATIONS" "ok_variants.sh" \
  "アンカー済みなら別表記(-qs / -- / リダイレクト)も誤検出しない: $MUTATIONS"

assert_summary
