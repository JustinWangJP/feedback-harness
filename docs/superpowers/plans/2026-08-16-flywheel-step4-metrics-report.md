# Flywheel Step 4(signals・events/stats・report)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** フィードバックハーネスに信号種(`--signal`)・フック合否イベントログ(`events.jsonl`)・集計(`stats`)・期間レポート(`report`)を加え、「効いているか」を測定し朝会/振り返りの議題を供給できるようにする。

**Architecture:** 既存の3層(記録=feedback_log.py、昇華=curator、適用=apply-feedback)に対し、(1) frontmatter に `signal`/`status_changed` の2キーだけ追加しスキーマ拡張は最小に保つ、(2) hooks が合否をローカルの JSONL に追記し `stats`/`report` は読み取り専用で集計する、(3) rules.md は既存ファイルを遅延マイグレーションで失敗由来/成功由来の2セクションにする。

**Tech Stack:** Bash(`set -u`、lib.sh 共有関数)、Python 3 標準ライブラリのみ(argparse / json / re / datetime / pathlib)。新規依存なし。

**Spec:** [docs/superpowers/specs/2026-08-16-flywheel-step4-design.md](../specs/2026-08-16-flywheel-step4-design.md)

## Global Constraints

- 新規依存パッケージ禁止(bash / python3 標準ライブラリのみ)
- hooks の記録失敗がフック本体を壊してはならない(沈黙のフォールバック)。stats/report は読み取り専用で状態を書かない(`.last-retro` は `report --mark` のときだけ)
- `events.jsonl` と `.feedback/.last-retro` はローカル状態(gitignore 対象・共有しない)。`.feedback/log/` と `rules.md` は引き続き git で共有
- 既存エントリ(frontmatter に `signal` が無い)は書き換えず `unknown` 扱い(後方互換)
- テストは `tests/test_*.sh` + `tests/assert.sh` 規約。期待値はリテラルで書き、判定は自前カウンタ + `assert_summary` の明示 exit(**検証対象の機構をそのテスト自身の合否判定に使わない** — `.feedback/rules.md` の既存ルール)
- `harness_tree_changed` の `.feedback/` prune 前提を壊さない(events.jsonl 更新でフルチェックが再燃しないことをテストで固定する)
- コメントは「なぜ」を書く(リポジトリの既存文体)。コミットメッセージは日本語の conventional commits(`feat:` / `docs:` / `fix:`)
- `rules.md` / `log/*.md` を直接手編集するのはテストのフィクスチャだけ。実運用は CLI 経由

---

### Task 1: `add --signal` — 信号種スキーマと推論

**Files:**
- Modify: `scripts/feedback_log.py`(docstring 8–18行目、`cmd_add`、`cmd_list`、argparse `add`/`list`)
- Test: `tests/test_signal_inference.sh`(新規)

**Interfaces:**
- Consumes: なし(最初のタスク)
- Produces: 定数 `SIGNALS = ["context", "instruction", "workflow", "failure"]`、関数 `infer_signal(category: str, detail: str) -> str`、frontmatter キー `signal`、`list --signal <context|instruction|workflow|failure|unknown>` フィルタ。Task 2/5/6 がこの signal 値に依存する

- [ ] **Step 1: 失敗テストを書く**

`tests/test_signal_inference.sh` を作成:

```bash
#!/usr/bin/env bash
# test_signal_inference.sh — add --signal の推論規則・明示指定優先・
# 既存エントリ(signal無し)の unknown 扱いを検証する。
#
# signal は昇華先ルーティングの軸。推論を誤ると context 信号が rules.md に
# 昇華される(本来の行き先は CLAUDE.md)などの迷子になる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CLI="$REPO/scripts/feedback_log.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/project"
( cd "$WORK/project" && git init -q . )
export CLAUDE_PROJECT_DIR="$WORK/project"

fb() { python3 "$CLI" "$@"; }
extract_id() { sed -n 's/.*(id=\(.*\))$/\1/p'; }
entry_signal() { # entry_signal <id> — frontmatter の signal(無ければ unknown)
  local f
  f="$(grep -rl "^id: $1\$" "$WORK/project/.feedback/log")"
  if grep -q "^signal: " "$f"; then
    sed -n 's/^signal: //p' "$f" | head -1
  else
    echo "unknown"
  fi
}

# --- 推論規則(明示指定なし) ---
S1="$(fb add --category style --summary "文脈欠落の指摘" --detail "根因: 文脈欠落" | extract_id)"
assert_eq "context" "$(entry_signal "$S1")" "根因:文脈欠落 → context"

S2="$(fb add --category architecture --summary "指示欠陥の指摘" --detail "根因: 指示欠陥" | extract_id)"
assert_eq "failure" "$(entry_signal "$S2")" "根因:指示欠陥 → failure"

S3="$(fb add --category testing --summary "モデル限界の指摘" --detail "根因: モデル限界" | extract_id)"
assert_eq "failure" "$(entry_signal "$S3")" "根因:モデル限界 → failure"

S4="$(fb add --category workflow --summary "効いた進め方" --detail "設計を先に固めると良かった" | extract_id)"
assert_eq "workflow" "$(entry_signal "$S4")" "根因なし+category=workflow → workflow"

S5="$(fb add --category style --summary "効いた措辞" --detail "〜という言い方が効いた" | extract_id)"
assert_eq "instruction" "$(entry_signal "$S5")" "根因なし+その他カテゴリ → instruction"

# --- 明示指定が推論に勝る ---
S6="$(fb add --category style --summary "明示指定" --detail "根因: 指示欠陥" --signal workflow | extract_id)"
assert_eq "workflow" "$(entry_signal "$S6")" "明示指定が推論より優先"

# --- 既存エントリ(signal 無し)は unknown で絞り込める ---
cat > "$WORK/project/.feedback/log/20260101-000000-legacy.md" <<'EOF'
---
id: 20260101-000000
date: 2026-01-01
source: human
category: style
status: open
---

# 移行前のエントリ
EOF
assert_contains "$(fb list --status open --signal unknown)" "20260101-000000" "signal無しエントリは unknown で絞り込める"
assert_not_contains "$(fb list --status open --signal context)" "20260101-000000" "unknown は他の信号種に出ない"

assert_summary
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_signal_inference.sh`
Expected: FAIL — `--signal` が未実装のため `add` が argparse error(exit 2)で `extract_id` が空になり全 assert が失敗する

- [ ] **Step 3: 実装する**

`scripts/feedback_log.py` を修正:

(1) docstring の使い方ブロック(8–16行目)の `add` 行を差し替え:

```python
  feedback_log.py add --category <cat> --summary "<要約>" [--detail "<詳細>"] [--source human|hook|agent] \
      [--signal context|instruction|workflow|failure]
```

(2) `slugify` の直後に定数と推論関数を追加:

```python
SIGNALS = ["context", "instruction", "workflow", "failure"]


def infer_signal(category: str, detail: str) -> str:
    """--signal 省略時に detail/category から信号種を推論する。

    根因は failure のサブルーティング材料であり、signal はそれを置き換えない。
    「根因: 文脈欠落」の失敗は直す先がプライミング文書(context)なのに対し、
    「指示欠陥/モデル限界」は失敗信号(failure)として扱う。
    """
    if "根因" in detail and "文脈欠落" in detail:
        return "context"
    if "根因" in detail and ("指示欠陥" in detail or "モデル限界" in detail):
        return "failure"
    if category == "workflow":
        return "workflow"
    return "instruction"
```

(3) `cmd_add` — `entry_id = ...` の行の後に推論を追加し、frontmatter に `signal` 行を挿入:

```python
    entry_id = next_entry_id(now)
    signal = args.signal or infer_signal(args.category, args.detail)
```

frontmatter の `category: {args.category}` 行の次に `signal: {signal}` 行を追加:

```python
    path.write_text(
        f"""---
id: {entry_id}
date: {now.strftime('%Y-%m-%d')}
source: {args.source}
category: {args.category}
signal: {signal}
status: open
---

# {args.summary}

{args.detail or ''}
""",
        encoding="utf-8",
    )
```

(4) `cmd_list` — category フィルタの後に signal フィルタを追加:

```python
        if args.category and e.get("category") != args.category:
            continue
        if args.signal and (e.get("signal") or "unknown") != args.signal:
            continue
```

(5) argparse — `add` と `list` に引数を追加:

```python
    a.add_argument("--source", default="human", choices=["human", "hook", "agent"])
    a.add_argument("--signal", choices=SIGNALS,
                   help="信号種(省略時は detail/category から推論)")
```

```python
    li.add_argument("--category")
    li.add_argument("--signal", choices=SIGNALS + ["unknown"])
```

- [ ] **Step 4: テストを実行して通ることを確認**

Run: `bash tests/test_signal_inference.sh`
Expected: PASS(失敗0件で exit 0)

- [ ] **Step 5: 既存テストの回帰確認**

Run: `bash tests/run_tests.sh`
Expected: 既存テスト全て PASS(既存エントリは `signal` が無いだけで `parse_entry` に影響しないため)

- [ ] **Step 6: コミット**

```bash
git add scripts/feedback_log.py tests/test_signal_inference.sh
git commit -m "feat: add に信号種(--signal)を追加し detail/category から推論可能にする"
```

---

### Task 2: rules.md の2セクション化(失敗由来/成功由来)

**Files:**
- Modify: `scripts/feedback_log.py`(`DEFAULT_RULES_HEADER`、`cmd_promote`)
- Modify: `.feedback/rules.template.md`
- Test: `tests/test_rules_sections.sh`(新規)

**Interfaces:**
- Consumes: Task 1 の frontmatter `signal` 値(`instruction`/`workflow` が成功セクション行きの判定に使う)
- Produces: 定数 `FAILURE_MARKER = "<!-- rules:failure -->"`、`SUCCESS_MARKER = "<!-- rules:success -->"`、関数 `ensure_sections(text: str) -> str`。promote の動作: signal が instruction/workflow → 成功セクション末尾、それ以外(failure/context/unknown) → 失敗セクション末尾(成功マーカー直前)。`cmd_promote` はステータス更新を `set_status(target, "promoted")` に統一(Task 6 がここに `status_changed` を追加する)

- [ ] **Step 1: 失敗テストを書く**

`tests/test_rules_sections.sh` を作成:

```bash
#!/usr/bin/env bash
# test_rules_sections.sh — rules.md の2セクション構造(失敗由来/成功由来)を検証する。
#
# - セクションマーカーが無い既存 rules.md への遅延マイグレーション
#   (既存ルールは失敗セクション側に入る)
# - promote のセクション選択(signal の instruction/workflow → 成功、他 → 失敗)
# - 成功セクションのルールも retire で撤去できる
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CLI="$REPO/scripts/feedback_log.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/project"
( cd "$WORK/project" && git init -q . )
export CLAUDE_PROJECT_DIR="$WORK/project"

fb() { python3 "$CLI" "$@"; }
extract_id() { sed -n 's/.*(id=\(.*\))$/\1/p'; }
line_of() { grep -n -F "$1" "$WORK/project/.feedback/rules.md" | head -1 | cut -d: -f1; }
lt() { [[ "$1" -lt "$2" ]] && echo 1 || echo 0; }

# --- 遅延マイグレーション: 古い形式(マーカー無し・ルールあり)から始める ---
mkdir -p "$WORK/project/.feedback"
cat > "$WORK/project/.feedback/rules.md" <<'EOF'
# フィードバック由来ルール

ヘッダ行。

- **[style]** 既存ルール  
  <sub>出典: 20260101-000000 (2026-01-01 昇華)</sub>
EOF

F1="$(fb add --category style --summary "失敗系の指摘" --detail "根因: 指示欠陥" | extract_id)"
I1="$(fb add --category workflow --summary "成功系の進め方" --detail "先に設計を固める" | extract_id)"
fb promote "$F1" --rule "失敗由来ルール" >/dev/null
fb promote "$I1" --rule "成功由来ルール" >/dev/null

RULES_FILE="$WORK/project/.feedback/rules.md"
RULES="$(cat "$RULES_FILE")"
assert_contains "$RULES" "<!-- rules:failure -->" "失敗セクションのマーカーが挿入される"
assert_contains "$RULES" "<!-- rules:success -->" "成功セクションのマーカーが挿入される"
assert_contains "$RULES" "既存ルール" "移行前の既存ルールが残る"

F_MARKER="$(line_of "<!-- rules:failure -->")"
S_MARKER="$(line_of "<!-- rules:success -->")"
assert_eq "1" "$(lt "$(line_of "既存ルール")" "$S_MARKER")" "既存ルールは失敗セクション内(successマーカーより前)"
assert_eq "1" "$(lt "$(line_of "失敗由来ルール")" "$S_MARKER")" "failure系のpromoteは失敗セクションに入る"
assert_eq "1" "$(lt "$S_MARKER" "$(line_of "成功由来ルール")")" "instruction/workflow系のpromoteは成功セクションに入る"
assert_eq "1" "$(lt "$F_MARKER" "$(line_of "既存ルール")")" "失敗マーカーは既存ルールより前(ヘッダ側)"

# --- 成功セクションのルールも retire で撤去できる ---
OUT="$(fb retire "$I1" --reason "プレイブック移行" 2>&1)"
assert_contains "$OUT" "retired:" "成功セクションのルールも retire できる"
assert_not_contains "$(cat "$RULES_FILE")" "成功由来ルール" "撤去後に本文が残らない"
assert_contains "$(cat "$RULES_FILE")" "<!-- rules:success -->" "撤去後もセクション構造は保たれる"
assert_contains "$(cat "$RULES_FILE")" "失敗由来ルール" "失敗セクションのルールは巻き添えにならない"

assert_summary
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_rules_sections.sh`
Expected: FAIL — `<!-- rules:failure -->` が挿入されず、マーカー系の assert が失敗する

- [ ] **Step 3: 実装する**

`scripts/feedback_log.py` を修正:

(1) `DEFAULT_RULES_HEADER` を差し替え(テンプレートと同一内容を保つ):

```python
DEFAULT_RULES_HEADER = """# フィードバック由来ルール

エージェントはセッション開始時に必ずこのファイルを読むこと。
各ルールは実際の人間の指摘から一般化されたもの(`scripts/feedback_log.py promote` で追加される)。

<!-- rules:failure -->
### 守るべき制約(失敗由来)

<!-- rules:success -->
### 再現すべき措辞・進め方(成功由来)
"""
```

(2) `cmd_promote` の直前にマーカー定数と `ensure_sections` を追加:

```python
FAILURE_MARKER = "<!-- rules:failure -->"
SUCCESS_MARKER = "<!-- rules:success -->"

FAILURE_SECTION = FAILURE_MARKER + "\n### 守るべき制約(失敗由来)\n"
SUCCESS_SECTION = SUCCESS_MARKER + "\n### 再現すべき措辞・進め方(成功由来)\n"


def ensure_sections(text: str) -> str:
    """rules.md に2セクション構造が無ければ挿入する(遅延マイグレーション)。

    既存の promote 済みルールはすべて失敗セクションに入れる。成功パターンの
    捕獲(--signal)が始まる以前のルールはすべて失敗由来のためである。
    """
    if FAILURE_MARKER in text and SUCCESS_MARKER in text:
        return text
    lines = text.rstrip("\n").splitlines()
    first_rule = next(
        (i for i, ln in enumerate(lines) if ln.startswith("- **[")), len(lines)
    )
    out = "\n".join(lines[:first_rule]).rstrip() + "\n\n"
    out += FAILURE_SECTION + "\n"
    if first_rule < len(lines):
        out += "\n".join(lines[first_rule:]).rstrip() + "\n\n"
    out += SUCCESS_SECTION
    return out
```

(3) `cmd_promote` を丸ごと差し替え:

```python
def cmd_promote(args):
    target = find_entry(args.entry_id)
    RULES.parent.mkdir(parents=True, exist_ok=True)
    if not RULES.exists():
        RULES.write_text(ensure_sections(rules_seed()), encoding="utf-8")
    text = ensure_sections(RULES.read_text(encoding="utf-8"))
    date = datetime.date.today().isoformat()
    rule_line = f"- **[{target.get('category','-')}]** {args.rule}  "
    source_line = f"  <sub>出典: {target.get('id')} ({date} 昇華)</sub>"
    # instruction/workflow(成功系)は成功セクションの末尾へ、それ以外
    # (failure/context/unknown)は失敗セクションの末尾(=成功マーカーの直前)へ
    if (target.get("signal") or "unknown") in ("instruction", "workflow"):
        RULES.write_text(
            text.rstrip("\n") + "\n\n" + rule_line + "\n" + source_line + "\n",
            encoding="utf-8",
        )
    else:
        lines = text.splitlines()
        j = lines.index(SUCCESS_MARKER)
        ins = [rule_line, source_line]
        if lines[j - 1].strip():
            ins.insert(0, "")
        lines[j:j] = ins
        RULES.write_text("\n".join(lines) + "\n", encoding="utf-8")
    set_status(target, "promoted")
    print(f"promoted: rules.md に追加し {target.get('id')} を promoted に更新")
```

(4) `.feedback/rules.template.md` を丸ごと差し替え:

```markdown
# フィードバック由来ルール

エージェントはセッション開始時に必ずこのファイルを読むこと。
各ルールは実際の人間の指摘から一般化されたもの(`scripts/feedback_log.py promote` で追加される)。

<!-- rules:failure -->
### 守るべき制約(失敗由来)

<!-- rules:success -->
### 再現すべき措辞・進め方(成功由来)
```

- [ ] **Step 4: テストを実行して通ることを確認**

Run: `bash tests/test_rules_sections.sh`
Expected: PASS

- [ ] **Step 5: 既存テストの回帰確認**

Run: `bash tests/run_tests.sh`
Expected: 全 PASS(retire/merge は行スキャン方式のためマーカー透過。`test_feedback_log_retire.sh` が通れば統合確認済み)

- [ ] **Step 6: 本リポジトリ自身の rules.md を移行しておく**

Run: `python3 scripts/feedback_log.py rules | head -20`
Expected: 既存4ルールはそのまま(マイグレーションは promote/retire 実行時の遅延適用のため、この時点では未挿入でもよい。確認するだけで編集しない — rules.md の手編集は禁止)

- [ ] **Step 7: コミット**

```bash
git add scripts/feedback_log.py .feedback/rules.template.md tests/test_rules_sections.sh
git commit -m "feat: rules.md を失敗由来/成功由来の2セクション構造にする(遅延マイグレーション)"
```

---

### Task 3: 信号種に関わる文言更新(curator・skills・規約)

**Files:**
- Modify: `agents/feedback-curator.md`(作業原則4のルーティング表)
- Modify: `skills/capture-feedback/SKILL.md`(手順に signal 追加)
- Modify: `skills/apply-feedback/SKILL.md`(手順1に2セクションの読み方)
- Modify: `AGENTS.md` と `docs/pointer_agents.md`(規約4のコマンド例 — 両者は同じ内容の断片)

**Interfaces:**
- Consumes: Task 1 の `--signal` 選択肢、Task 2 のルールセクション名(「失敗セクション」「成功セクション」)
- Produces: 文言(後続タスクなし。curator のルーティング判断根拠)

- [ ] **Step 1: `agents/feedback-curator.md` の作業原則4を差し替え**

既存の原則4(「**昇華先は根因で決める。**」で始まるブロック全体)を以下に差し替える。原則5以降と `rules.md 以外への反映は**提案止まり**とし…` の一文はそのまま残す:

```markdown
4. **昇華先は signal で決める。** エントリ frontmatter の `signal`(capture-feedback が記録。無ければ `根因:` 行と category から推論、それも無ければ unknown)を見て行き先を選ぶ:
   - `context`(知識の欠落)→ 導入先プロジェクトの CLAUDE.md への**追記案を提示**する。rules.md は行動規則の置き場であり、知識の欠落はプライミング文書側で埋める
   - `instruction`(効いた措辞)→ rules.md の**成功セクション**へ `promote`(再現すべき正例として)
   - `workflow`(効いた進め方・タスク分解)→ rules.md の**成功セクション**へ `promote`
   - `failure`(失敗。根因でサブルーティング)→ エントリ本文の `根因:` 行を見て:
     - `指示欠陥`(指示・スキルが要求していなかった)→ rules.md の**失敗セクション**へ `promote`(標準の出口)
     - lint・テストで機械的に検出できる失敗 → 導入先プロジェクトの lint 設定・テストへの**追加を提案**する。check.sh はプロジェクトの linter・テストを自動検出して実行するため、追加すればそのまま自動チェック化される。散文ルールより自動チェックの方が強い護欄になる
     - `モデル限界`(能力の境界)→ rules.md の**失敗セクション**に境界として `promote` する(「〜はAIに任せず人間が確認する」の形)
```

- [ ] **Step 2: `skills/capture-feedback/SKILL.md` の手順を差し替え**

既存の手順2(根因判定)の次に新しく手順を挿入し、以降の番号を1つずつ繰り下げる(旧3→4、旧4→5、旧5→6)。挿入する手順:

```markdown
3. signal を決める(省略時は CLI が detail/category から推論する): 失敗系は `failure`、知識の欠落(`根因: 文脈欠落`)は `context`、再現したい措辞は `instruction`、効いた進め方・タスク分解は `workflow`。`--signal <種>` で明示できる
```

- [ ] **Step 3: `skills/apply-feedback/SKILL.md` の手順1を拡張**

手順1「`.feedback/rules.md` を読む」を以下に差し替え:

```markdown
1. `.feedback/rules.md` を読む(なければ `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/feedback_log.py" rules` で確認)。rules.md は2セクション構造 — **守るべき制約(失敗由来)** は守るべき制約、**再現すべき措辞・進め方(成功由来)** は次回再現すべき正例として読む
```

- [ ] **Step 4: `AGENTS.md` と `docs/pointer_agents.md` の規約4を同一内容で差し替え**

両ファイルの「## 4. 人間から指摘・修正を受けたら」セクション全体を以下に差し替え:

```markdown
## 4. 人間から指摘・修正を受けたら

その場で記録する(次のセッションに引き継ぐ唯一の手段):

```bash
python3 scripts/feedback_log.py add --category <style|architecture|testing|naming|workflow|domain> \
  --summary "<1文要約>" --detail "<文脈>" --source human \
  [--signal <context|instruction|workflow|failure>]
```

再発しうる指摘は記録し、そのタスク限りの指示は記録しない。迷ったら記録する。次回も再現したい成功パターン(有効だった進め方・措辞)も同様に記録する。失敗系は根因(`文脈欠落` / `指示欠陥` / `モデル限界`)を `--detail` に1行含める。`--signal` は省略時に根因とカテゴリから推論される(知識の欠落=`context`、失敗=`failure`、効いた措辞=`instruction`、効いた進め方=`workflow`)。
```

- [ ] **Step 5: 検証(既存テスト + 文言整合の grep)**

Run: `bash tests/run_tests.sh && grep -c "signal" AGENTS.md docs/pointer_agents.md agents/feedback-curator.md skills/capture-feedback/SKILL.md`
Expected: テスト全 PASS(test_skill_paths.sh がパス整合を検証)。grep が各ファイル1以上(=反映漏れなし)

- [ ] **Step 6: コミット**

```bash
git add agents/feedback-curator.md skills/capture-feedback/SKILL.md skills/apply-feedback/SKILL.md AGENTS.md docs/pointer_agents.md
git commit -m "docs: 信号種(--signal)に合わせて curator の昇華先ルーティングと規約を更新"
```

---

### Task 4: フック合否のイベントログ(harness_log_event + hooks)

**Files:**
- Modify: `scripts/lib.sh`(`harness_log_event` 追加、`harness_tree_changed` のコメント1行)
- Modify: `scripts/hooks/post_edit.sh`(lib.sh source + 合否記録)
- Modify: `scripts/hooks/on_stop.sh`(check.sh 実行時に合否記録)
- Modify: `.gitignore`(`.feedback/events.jsonl`)
- Test: `tests/test_events_log.sh`(新規)

**Interfaces:**
- Consumes: なし(hooks は既存の `harness_project_root` を利用)
- Produces: lib.sh 関数 `harness_log_event <root> <hook> <result> [file]`(Task 5 の `load_events()` が読むファイル `.feedback/events.jsonl` の形式 `{ts, hook, file?, result}` をここで定義する)

- [ ] **Step 1: 失敗テストを書く**

`tests/test_events_log.sh` を作成:

```bash
#!/usr/bin/env bash
# test_events_log.sh — フックが合否を events.jsonl に記録する(成功も失敗も)ことと、
# .feedback/ 内の更新が木変更判定(harness_tree_changed)を起こさないことを検証する。
#
# 成功の記録が無いと初回通過率の分母が取れない。また events.jsonl が木変更判定に
# 波及すると、記録のたびにフルチェックが再燃する(2026-08-12 の過剰実行の再発)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
. "$REPO/scripts/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/proj/sub" "$WORK/proj/.feedback/log" "$WORK/proj/.git"
( cd "$WORK/proj" && git init -q . )
touch "$WORK/proj/sub/code.py"
touch -t 202601010000 "$WORK/proj/sub/code.py" "$WORK/proj/sub" "$WORK/proj"
STAMP="$WORK/proj/.feedback/.last-check"
: > "$STAMP"
touch -t 202601020000 "$STAMP"

# 偽の check_file.sh / check.sh でフックを駆動する(実際のlinterに依存しない)
mkdir -p "$WORK/fake/hooks"
cp "$REPO/scripts/hooks/post_edit.sh" "$WORK/fake/hooks/"
cp "$REPO/scripts/hooks/on_stop.sh" "$WORK/fake/hooks/"
cp "$REPO/scripts/lib.sh" "$WORK/fake/"
fake_exit() { # fake_exit <exit-code>
  for name in check_file check; do
    { echo '#!/usr/bin/env bash'; echo "exit $1"; } > "$WORK/fake/$name.sh"
    chmod +x "$WORK/fake/$name.sh"
  done
}

EVENTS="$WORK/proj/.feedback/events.jsonl"
run_post_edit() { # run_post_edit <exit-code>
  fake_exit "$1"
  printf '{"tool_input": {"file_path": "%s"}}' "$WORK/proj/sub/code.py" \
    | CLAUDE_PROJECT_DIR="$WORK/proj" bash "$WORK/fake/hooks/post_edit.sh" >/dev/null 2>&1
}
run_stop() { # run_stop <exit-code>
  fake_exit "$1"
  rm -f "$STAMP"  # 「変更あり」を保証して check.sh が実行されるようにする
  printf '{"stop_hook_active": false}' \
    | CLAUDE_PROJECT_DIR="$WORK/proj" bash "$WORK/fake/hooks/on_stop.sh" >/dev/null 2>&1
}

# --- post_edit: 成功も失敗も記録される ---
run_post_edit 0
assert_contains "$(cat "$EVENTS")" '"hook":"post_edit"' "post_edit のイベントが記録される"
assert_contains "$(cat "$EVENTS")" '"result":"pass"' "成功も記録される(初回通過率の分母)"
assert_contains "$(cat "$EVENTS")" '"file":"sub/code.py"' "file はルート相対パスで記録される"
run_post_edit 1
assert_contains "$(tail -n 1 "$EVENTS")" '"result":"fail"' "失敗も記録される"

# file が解決できない入力は記録しない
BEFORE="$(wc -l <"$EVENTS" | tr -d ' ')"
printf '{"tool_input": {}}' \
  | CLAUDE_PROJECT_DIR="$WORK/proj" bash "$WORK/fake/hooks/post_edit.sh" >/dev/null 2>&1
AFTER="$(wc -l <"$EVENTS" | tr -d ' ')"
assert_eq "$BEFORE" "$AFTER" "file_path が無いときは記録しない"

# --- on_stop: check.sh を実行したときだけ記録される ---
run_stop 0
assert_contains "$(tail -n 1 "$EVENTS")" '"hook":"stop"' "stop のイベントが記録される"
run_stop 1
assert_contains "$(tail -n 1 "$EVENTS")" '"result":"fail"' "stop の失敗も記録される"

# --- ローテーション: 512KB 超で末尾2000行に切詰められる ---
yes '{"ts":"2026-01-01T00:00:00Z","hook":"stop","result":"pass"}' | head -n 15000 > "$EVENTS"
harness_log_event "$WORK/proj" stop pass
LINES="$(wc -l <"$EVENTS" | tr -d ' ')"
assert_eq "2001" "$LINES" "512KB超で末尾2000行+追記1行に切詰められる"

# --- 除外: events.jsonl の更新でフルチェックが再燃しない(prune 前提の固定) ---
touch -t 202601010000 "$WORK/proj/sub/code.py" "$WORK/proj/sub" "$WORK/proj"
touch -t 202601030000 "$EVENTS"
ASSERT_CHECKS=$((ASSERT_CHECKS + 1))
if harness_tree_changed "$WORK/proj" "$STAMP"; then
  fail "events.jsonl の更新でフルチェックが再燃した(.feedback prune前提が崩れた)"
fi

assert_summary
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_events_log.sh`
Expected: FAIL — `harness_log_event` 未定義のため post_edit/on_stop の記録系 assert が失敗する(除外とローテーションは既存実装由来で一部通る)

- [ ] **Step 3: lib.sh に `harness_log_event` を追加**

`scripts/lib.sh` の `harness_tree_changed` の後に追加:

```bash
# harness_log_event <ルート> <hook> <result> [ファイル] — フック合否を
# .feedback/events.jsonl に1行追記する(stats/report の原料。ローカル状態で共有しない)。
#
# 記録がフック本体を壊してはならないため、すべての失敗は黙って無視する。
# 無限増長を防ぐため 512KB を超えたら末尾2000行に切り詰める。
harness_log_event() {
  local root="$1" hook="$2" result="$3" file="${4:-}"
  local dir="$root/.feedback" ev="$dir/events.jsonl"
  mkdir -p "$dir" 2>/dev/null || return 0
  local ts rel=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 0
  if [[ -n "$file" ]]; then
    rel="${file#"$root"/}"
    printf '{"ts":"%s","hook":"%s","file":"%s","result":"%s"}\n' \
      "$ts" "$hook" "$rel" "$result" >>"$ev" 2>/dev/null || return 0
  else
    printf '{"ts":"%s","hook":"%s","result":"%s"}\n' \
      "$ts" "$hook" "$result" >>"$ev" 2>/dev/null || return 0
  fi
  local size
  size="$(wc -c <"$ev" 2>/dev/null | tr -d ' ')"
  if [[ "$size" =~ ^[0-9]+$ ]] && (( size > 524288 )); then
    tail -n 2000 "$ev" >"$ev.tmp" 2>/dev/null && mv "$ev.tmp" "$ev" 2>/dev/null \
      || rm -f "$ev.tmp" 2>/dev/null
  fi
  return 0
}
```

また `harness_tree_changed` の除外コメント(`# 除外はVCS・依存・キャッシュ・ハーネス状態のみに絞る。…` の行)の直後に1行追加:

```bash
  # (.feedback には events.jsonl 等のローカル状態も含まれ、記録のたびに
  #  フルチェックが再燃しないよう prune 対象である — test_events_log.sh が固定する)
```

- [ ] **Step 4: post_edit.sh を差し替え**

`scripts/hooks/post_edit.sh` を丸ごと差し替え:

```bash
#!/usr/bin/env bash
# post_edit.sh — Claude Code PostToolUse (Edit|Write) フック。
# 編集されたファイルを check_file.sh で即時チェックし、問題があれば
# exit 2 + stderr でエージェントに自動フィードバックする(自己修正ループ)。
# 合否は成功・失敗の両方を events.jsonl に記録する(stats の初回通過率の原料)。
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$DIR/../lib.sh"

FILE="$(python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("file_path", ""))
except Exception:
    pass
')"

if [[ -z "$FILE" ]]; then
  exit 0
fi

ROOT="$(harness_project_root)"

if OUT="$("$DIR/../check_file.sh" "$FILE" 2>&1)"; then
  harness_log_event "$ROOT" post_edit pass "$FILE"
  exit 0
fi

harness_log_event "$ROOT" post_edit fail "$FILE"
# exit 2: stderr が Claude にフィードバックされ、自動で修正が促される
echo "$OUT" >&2
echo "上記の問題を修正してから作業を続けること。" >&2
exit 2
```

- [ ] **Step 5: on_stop.sh の check.sh 実行部に記録を追加**

`scripts/hooks/on_stop.sh` の check.sh 実行ブロックを差し替え:

```bash
if OUT="$("$DIR/../check.sh" "$ROOT" 2>&1)"; then
  # 成功した時だけスタンプを更新する。失敗を記録すると、直さないまま次の
  # ターンで「変更なし」と判定され、壊れたまま完了できてしまう
  mkdir -p "$(dirname "$STAMP")" 2>/dev/null && : > "$STAMP" 2>/dev/null
  harness_log_event "$ROOT" stop pass
  exit 0
fi

harness_log_event "$ROOT" stop fail
echo "$OUT" >&2
# 反復する失敗はルール/自動チェック改善の材料(失敗シグナル)。単発の失敗は記録不要
echo "HINT: 同種の失敗がこのセッションで繰り返されている場合は、修正後に python3 \"$DIR/../feedback_log.py\" add --source hook で記録を検討すること" >&2
exit 2
```

(変更点は `harness_log_event "$ROOT" stop pass` / `harness_log_event "$ROOT" stop fail` の2行の追加のみ。スキップ時・2周目は無記録のまま)

- [ ] **Step 6: .gitignore に追記**

`.gitignore` の `.feedback/.last-check` ブロックの後に追加:

```
# フック合否のイベントログ(stats用。マシン固有のノイズが混ざるため共有しない)
.feedback/events.jsonl
```

- [ ] **Step 7: テストを実行して通ることを確認**

Run: `bash tests/test_events_log.sh && bash tests/run_tests.sh`
Expected: 両方 PASS(test_on_stop_skip.sh は偽checkで駆動するためロギング追加の影響を受けない)

- [ ] **Step 8: コミット**

```bash
git add scripts/lib.sh scripts/hooks/post_edit.sh scripts/hooks/on_stop.sh .gitignore tests/test_events_log.sh
git commit -m "feat: フック合否を events.jsonl に記録し木変更判定と分離する"
```

---

### Task 5: `stats` サブコマンド — 初回通過率・再発候補

**Files:**
- Modify: `scripts/feedback_log.py`(docstring、ヘルパー群、`cmd_stats`、argparse)
- Test: `tests/test_stats.sh`(新規)

**Interfaces:**
- Consumes: Task 4 が定義した `.feedback/events.jsonl` の形式(`{ts, hook, file?, result}`)、Task 1 の frontmatter `signal`
- Produces: `EVENTS_FILE: Path`、`load_events() -> list[dict]`(不正JSON行は読み飛ばし)、`post_edit_first_pass(evs, date_from: str, date_to: str) -> tuple[int, int, dict]`((初回pass数, ファイル数, ファイル別fail数))、`root_cause(entry: dict) -> str`、`rule_sources() -> list[dict]`(`{sources: [id], category, date}`)、`recurrence_candidates() -> list[dict]`(`rule_sources` + `recurrences: [id]`)、`resolve_since(args) -> str`。Task 6 の `report` はこれらを再利用する

- [ ] **Step 1: 失敗テストを書く**

`tests/test_stats.sh` を作成:

```bash
#!/usr/bin/env bash
# test_stats.sh — stats の数値(初回通過率・再チェック回数・再発候補)を
# 既知の数値を持つフィクスチャに対して検証する。
#
# 期待値はリテラルで書く(検証対象の集計機構自身で期待値を算出しない)。
# 不正 JSON 行があっても集計が続くことも確認する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CLI="$REPO/scripts/feedback_log.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/project/.feedback/log"
export CLAUDE_PROJECT_DIR="$WORK/project"

fb() { python3 "$CLI" "$@"; }

# --- events フィクスチャ(数値既知。末尾に不正JSON行を混ぜる) ---
# post_edit: a.py は初回fail→pass、b.py は初回pass、c.py は fail,fail,pass
# → 全期間の初回通過率 1/3(33%)。fail総数4/ファイル数3 = 平均1.33
# stop: pass, fail, pass → 2/3(67%)
cat > "$WORK/project/.feedback/events.jsonl" <<'EOF'
{"ts":"2026-08-10T01:00:00Z","hook":"post_edit","file":"src/a.py","result":"fail"}
{"ts":"2026-08-10T01:01:00Z","hook":"post_edit","file":"src/a.py","result":"pass"}
{"ts":"2026-08-11T02:00:00Z","hook":"post_edit","file":"src/b.py","result":"pass"}
{"ts":"2026-08-12T03:00:00Z","hook":"post_edit","file":"src/c.py","result":"fail"}
{"ts":"2026-08-12T03:01:00Z","hook":"post_edit","file":"src/c.py","result":"fail"}
{"ts":"2026-08-12T03:02:00Z","hook":"post_edit","file":"src/c.py","result":"pass"}
{"ts":"2026-08-13T04:00:00Z","hook":"stop","result":"pass"}
{"ts":"2026-08-13T05:00:00Z","hook":"stop","result":"fail"}
{"ts":"2026-08-13T06:00:00Z","hook":"stop","result":"pass"}
this is not json
EOF

# --- log フィクスチャ(手書き — 期日を固定するためCLI経由にしない) ---
cat > "$WORK/project/.feedback/log/20260701-000001-rule-src.md" <<'EOF'
---
id: 20260701-000001
date: 2026-07-01
source: human
category: style
status: promoted
---

# 元の指摘

根因: 指示欠陥
EOF
cat > "$WORK/project/.feedback/log/20260715-000001-recurrence.md" <<'EOF'
---
id: 20260715-000001
date: 2026-07-15
source: human
category: style
status: open
---

# 再発した同種の指摘

根因: 指示欠陥
EOF
cat > "$WORK/project/.feedback/log/20260716-000001-unrelated.md" <<'EOF'
---
id: 20260716-000001
date: 2026-07-16
source: agent
category: testing
status: open
---

# 別カテゴリのエントリ
EOF
cat > "$WORK/project/.feedback/rules.md" <<'EOF'
# フィードバック由来ルール

<!-- rules:failure -->
### 守るべき制約(失敗由来)

- **[style]** テスト用ルール本文  
  <sub>出典: 20260701-000001 (2026-07-01 昇華)</sub>

<!-- rules:success -->
### 再現すべき措辞・進め方(成功由来)
EOF

OUT="$(fb stats --since 2026-08-10)"

# --- フック系(不正JSON行は読み飛ばされて数値が崩れない) ---
assert_contains "$OUT" "PostToolUse 初回通過率: 1/3 (33%)" "初回通過率(a=fail,b=pass,c=fail → 1/3)"
assert_contains "$OUT" "1ファイルあたりの平均再チェック回数: 1.33" "平均再チェック回数(fail4/3ファイル)"
assert_contains "$OUT" "Stop フルチェック初回通過率: 2/3 (67%)" "stop の pass 率"
assert_contains "$OUT" "失敗上位: src/c.py(3), src/a.py(1)" "失敗上位(件数降順・ファイル名昇順)"

# --- 期間指定(a.py の2026-08-10を除外 → b,c の2ファイル) ---
OUT2="$(fb stats --since 2026-08-11)"
assert_contains "$OUT2" "PostToolUse 初回通過率: 1/2 (50%)" "期間フィルタが効く"

# --- ログ系(signal 無しは unknown、根因は本文から抽出) ---
assert_contains "$OUT" "signal:" "signal 集計行がある"
assert_contains "$OUT" "unknown 3" "signal無しエントリ3件は unknown に数えられる"
assert_contains "$OUT" "根因:" "根因集計行がある"
assert_contains "$OUT" "指示欠陥 2" "根因は本文の「根因:」行から数えられる"
assert_contains "$OUT" "category: style 2 / testing 1" "category 別件数"

# --- 再発候補(同カテゴリの失敗系のみ。別カテゴリは候補に出ない) ---
assert_contains "$OUT" "20260701-000001 (2026-07-01 昇華)" "再発候補に出典ルールが出る"
assert_contains "$OUT" "以降の同カテゴリ: 20260715-000001" "昇華日以降の同カテゴリ指摘が列挙される"
assert_not_contains "$OUT" "以降の同カテゴリ: 20260716-000001" "別カテゴリは再発候補に出ない"

# --- events が無いプロジェクトでも死なない ---
rm "$WORK/project/.feedback/events.jsonl"
OUT3="$(fb stats)"
assert_contains "$OUT3" "イベント記録が無い" "events.jsonl 不在でもログ集計を続ける"
assert_contains "$OUT3" "再発候補" "再発候補セクションは出る"

assert_summary
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_stats.sh`
Expected: FAIL — `stats` サブコマンドが未実装のため argparse error(exit 2)で全 assert が失敗する

- [ ] **Step 3: 実装する**

`scripts/feedback_log.py` を修正:

(1) import に `json` を追加(アルファベット順で `import datetime` と `import os` の間):

```python
import datetime
import json
import os
```

(2) モジュール定数 `RULES_TEMPLATE = ...` の行の後に追加:

```python
EVENTS_FILE = ROOT / ".feedback" / "events.jsonl"
```

(3) docstring の使い方ブロックに `rules` 行の次を追加:

```python
  feedback_log.py stats [--since YYYY-MM-DD] [--days N]   # 初回通過率・再発候補など
```

(4) `parse_entry` の前にヘルパー群を追加:

```python
ROOT_CAUSE_RE = re.compile(r"根因:\s*(文脈欠落|指示欠陥|モデル限界)")
RULE_DATE_RE = re.compile(r"\((\d{4}-\d{2}-\d{2}) 昇華\)")


def load_events() -> list:
    """events.jsonl を読む。不正な JSON 行は読み飛ばす(壊れた記録が集計を殺さない)。"""
    if not EVENTS_FILE.exists():
        return []
    out = []
    for line in EVENTS_FILE.read_text(encoding="utf-8").splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if isinstance(ev, dict) and "ts" in ev and "result" in ev:
            out.append(ev)
    return out


def resolve_since(args) -> str:
    """--since(優先)または --days(既定30)から集計開始日を返す。"""
    if getattr(args, "since", None):
        return args.since
    days = getattr(args, "days", 30)
    return (datetime.date.today() - datetime.timedelta(days=days)).isoformat()


def post_edit_first_pass(evs, date_from: str, date_to: str):
    """期間内の post_edit イベントから(初回pass数, ファイル数, ファイル別fail数)を返す。

    「初回」= 期間内でそのファイルに最初に現れたイベント。期間を跨ぐ再登場は
    リセットされる(日次/指定期間のスナップショットとして測る)。
    """
    first, fails = {}, {}
    for e in evs:
        if e.get("hook") != "post_edit":
            continue
        d = str(e.get("ts", ""))[:10]
        if not (date_from <= d <= date_to):
            continue
        f = str(e.get("file", ""))
        if e.get("result") == "fail":
            fails[f] = fails.get(f, 0) + 1
        if f not in first:
            first[f] = e.get("result") == "pass"
    return (sum(first.values()), len(first), fails)


def root_cause(entry: dict) -> str:
    """エントリ本文の「根因:」行から根因を返す(無ければ "-")。"""
    m = ROOT_CAUSE_RE.search(entry.get("body", ""))
    return m.group(1) if m else "-"


def rule_sources() -> list:
    """rules.md の各ルールから {sources, category, date} を返す(date は昇華日)。"""
    if not RULES.exists():
        return []
    out = []
    lines = RULES.read_text(encoding="utf-8").splitlines()
    for i, ln in enumerate(lines):
        m = RULE_SOURCE_RE.match(ln)
        if not m or i == 0:
            continue
        cat_m = re.match(r"\s*- \*\*\[([^\]]+)\]\*\*", lines[i - 1])
        dm = RULE_DATE_RE.search(ln)
        out.append({
            "sources": [s.strip() for s in m.group(2).split(",")],
            "category": cat_m.group(1) if cat_m else "-",
            "date": dm.group(1) if dm else "",
        })
    return out


def recurrence_candidates() -> list:
    """昇華日以降に同カテゴリの失敗系エントリが出たルールを列挙する。

    curator 原則5(再発=ルールが効いていない兆候)と棚卸しPhase4手順1の
    手動検索を機械化したもの。成功系(instruction/workflow)の再記録は
    再発ではないため対象外。
    """
    out = []
    for rule in rule_sources():
        if not rule["date"]:
            continue
        hits = [
            e for e in entries()
            if e.get("category") == rule["category"]
            and (e.get("date") or "") > rule["date"]
            and e.get("id") not in rule["sources"]
            and (e.get("signal") or "unknown") in ("failure", "context", "unknown")
        ]
        if hits:
            out.append({**rule, "recurrences": [h.get("id", "?") for h in hits]})
    return out
```

(5) `cmd_rules` の前に `cmd_stats` を追加:

```python
def cmd_stats(args):
    since = resolve_since(args)
    today = datetime.date.today().isoformat()
    print(f"# feedback stats(イベント集計: {since} 以降 / ログ集計: 全期間)")
    evs = load_events()

    print()
    print("[フック]")
    if not evs:
        print("(イベント記録が無い — hooks が .feedback/events.jsonl に蓄積する)")
    else:
        npass, total, fails = post_edit_first_pass(evs, since, "9999-12-31")
        if total:
            print(f"PostToolUse 初回通過率: {npass}/{total} ({npass * 100 // total}%)")
            print(f"1ファイルあたりの平均再チェック回数: {sum(fails.values()) / total:.2f}")
        else:
            print("(期間内の post_edit イベントが無い)")
        stops = [e for e in evs if e.get("hook") == "stop" and str(e.get("ts", ""))[:10] >= since]
        if stops:
            spass = sum(1 for e in stops if e.get("result") == "pass")
            print(f"Stop フルチェック初回通過率: {spass}/{len(stops)} ({spass * 100 // len(stops)}%)")
        top = sorted(fails.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
        if top:
            print("失敗上位: " + ", ".join(f"{f}({n})" for f, n in top))

    print()
    print("[ログ]")
    es = entries()
    sig = {s: 0 for s in SIGNALS}
    sig["unknown"] = 0
    for e in es:
        sig[e.get("signal") or "unknown"] += 1
    print("signal: " + " / ".join(f"{k} {v}" for k, v in sig.items()))
    cats, causes, srcs, st = {}, {}, {}, {}
    for e in es:
        cats[e.get("category", "-")] = cats.get(e.get("category", "-"), 0) + 1
        rc = root_cause(e)
        causes[rc] = causes.get(rc, 0) + 1
        srcs[e.get("source", "-")] = srcs.get(e.get("source", "-"), 0) + 1
        st[e.get("status", "-")] = st.get(e.get("status", "-"), 0) + 1
    print("category: " + " / ".join(f"{k} {v}" for k, v in sorted(cats.items())))
    print("根因: " + " / ".join(f"{k} {v}" for k, v in sorted(causes.items())))
    print("source: " + " / ".join(f"{k} {v}" for k, v in sorted(srcs.items())))
    print("status: " + " / ".join(f"{k} {v}" for k, v in sorted(st.items())))
    opens = [e for e in es if e.get("status") == "open"]
    if opens:
        oldest = max(opens, key=lambda e: e.get("date") or "")
        if oldest.get("date"):
            days = (datetime.date.today() - datetime.date.fromisoformat(oldest["date"])).days
            print(f"open: {len(opens)}件(最古 {oldest.get('id')} から {days}日経過)")
        else:
            print(f"open: {len(opens)}件")
        if len(opens) >= 3:
            print("NOTE: openが3件以上 — promote/close を検討してください")

    print()
    print("[再発候補] 昇華後に同カテゴリの失敗系エントリが再記録されたルール")
    cands = recurrence_candidates()
    if not cands:
        print("(なし)")
    for c in cands:
        print(f"- [{c['category']}] {', '.join(c['sources'])} ({c['date']} 昇華) ← 以降の同カテゴリ: {', '.join(c['recurrences'])}")
```

(6) argparse — `rules` サブコマンドの前に追加:

```python
    stt = sub.add_parser("stats", help="フック合否とログの集計(初回通過率・再発候補)")
    stt.add_argument("--since", help="イベント集計の開始日 YYYY-MM-DD(既定: --days 日前から)")
    stt.add_argument("--days", type=int, default=30, help="イベント集計の期間日数(既定30)")
    stt.set_defaults(func=cmd_stats)
```

- [ ] **Step 4: テストを実行して通ることを確認**

Run: `bash tests/test_stats.sh`
Expected: PASS

- [ ] **Step 5: 既存テストの回帰確認**

Run: `bash tests/run_tests.sh`
Expected: 全 PASS

- [ ] **Step 6: コミット**

```bash
git add scripts/feedback_log.py tests/test_stats.sh
git commit -m "feat: stats サブコマンドで初回通過率・平均再チェック回数・再発候補を集計する"
```

---

### Task 6: `status_changed` + `report` サブコマンド

**Files:**
- Modify: `scripts/feedback_log.py`(`set_status`、`cmd_report`、argparse、docstring)
- Modify: `.gitignore`(`.feedback/.last-retro`)
- Test: `tests/test_report.sh`(新規)

**Interfaces:**
- Consumes: Task 5 の `load_events()` / `post_edit_first_pass()` / `rule_sources()` / `recurrence_candidates()`、Task 2 の `set_status` 呼び出し(promote/merge/close/retire すべてが経由する)
- Produces: `set_status` が frontmatter に `status_changed: YYYY-MM-DD` を書く(1キー・上書き)。`LAST_RETRO: Path`、`resolve_report_since(args) -> str`、コマンド `report [--since <日付|yesterday>|--last] [--mark]`

- [ ] **Step 1: 失敗テストを書く**

`tests/test_report.sh` を作成:

```bash
#!/usr/bin/env bash
# test_report.sh — report の期間集計(新規/昇華/close・retire/open/再発候補/数字)、
# status_changed の記録、--last/--mark の基点スタンプを検証する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
CLI="$REPO/scripts/feedback_log.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$WORK/project/.feedback/log" "$WORK/project2"
( cd "$WORK/project" && git init -q . ) >/dev/null 2>&1
export CLAUDE_PROJECT_DIR="$WORK/project"

fb() { python3 "$CLI" "$@"; }
extract_id() { sed -n 's/.*(id=\(.*\))$/\1/p'; }

# --- フィクスチャ(期日固定のため log/rules は手書き) ---
cat > "$WORK/project/.feedback/log/20260701-000001-rule-src.md" <<'EOF'
---
id: 20260701-000001
date: 2026-07-01
source: human
category: style
status: promoted
status_changed: 2026-07-01
---

# 元の指摘

根因: 指示欠陥
EOF
cat > "$WORK/project/.feedback/log/20260715-000001-recurrence.md" <<'EOF'
---
id: 20260715-000001
date: 2026-07-15
source: human
category: style
status: open
---

# 再発した同種の指摘

根因: 指示欠陥
EOF
cat > "$WORK/project/.feedback/log/20260720-000001-closed.md" <<'EOF'
---
id: 20260720-000001
date: 2026-07-20
source: human
category: naming
status: closed
status_changed: 2026-07-21
---

# 一回限りの指摘
EOF
cat > "$WORK/project/.feedback/rules.md" <<'EOF'
# フィードバック由来ルール

<!-- rules:failure -->
### 守るべき制約(失敗由来)

- **[style]** テスト用ルール本文  
  <sub>出典: 20260701-000001 (2026-07-01 昇華)</sub>

<!-- rules:success -->
### 再現すべき措辞・進め方(成功由来)
EOF
cat > "$WORK/project/.feedback/events.jsonl" <<'EOF'
{"ts":"2026-08-10T01:00:00Z","hook":"post_edit","file":"src/a.py","result":"fail"}
{"ts":"2026-08-10T01:01:00Z","hook":"post_edit","file":"src/a.py","result":"pass"}
{"ts":"2026-08-14T02:00:00Z","hook":"post_edit","file":"src/b.py","result":"pass"}
EOF

OUT="$(fb report --since 2026-07-10)"

# --- セクション構造と期間フィルタ ---
assert_contains "$OUT" "フィードバックレポート(2026-07-10 以降" "ヘッダに期間が出る"
assert_contains "$OUT" "## 新規エントリ" "新規エントリセクションがある"
assert_contains "$OUT" "20260715-000001" "期間内の新規エントリが出る"
assert_contains "$OUT" "20260720-000001" "期間内のもう1件も出る"
assert_not_contains "$OUT" "20260701-000001)" "期間前のエントリは新規に出ない(id括弧付きで照合)"
assert_contains "$OUT" "## close・retire" "close・retire セクションがある"
assert_contains "$OUT" "[closed] 20260720-000001 (2026-07-21)" "status_changed 日付で close が出る"
assert_contains "$OUT" "## 再発候補" "再発候補セクションがある"
assert_contains "$OUT" "以降の同カテゴリ: 20260715-000001" "再発候補の本文"
# 昇華セクション: 期間前の昇華(2026-07-01)は出ない(「出典 」プレフィックスは
# 昇華セクションだけで、再発候補行はプレフィックス無し — こちらで区別して照合する)
assert_not_contains "$OUT" "出典 20260701-000001" "期間前の昇華は載らない"
# 数字セクション: events があるので初回通過率が出る
assert_contains "$OUT" "PostToolUse 初回通過率:" "イベント数字が出る"

# --- status_changed が CLI 経由で書かれる ---
CID="$(fb add --category style --summary "close確認用" --detail "" | extract_id)"
fb close "$CID" --reason "テスト" >/dev/null
CLOSED_FILE="$(grep -rl "^id: ${CID}\$" "$WORK/project/.feedback/log")"
assert_contains "$(cat "$CLOSED_FILE")" "status_changed:" "close が status_changed を書く"

# --- --mark で基点スタンプが更新され、--last で読める ---
TODAY="$(python3 -c 'import datetime; print(datetime.date.today().isoformat())')"
fb report --since 2026-07-10 --mark >/dev/null
assert_file_exists "$WORK/project/.feedback/.last-retro" "--mark で .last-retro が作られる"
assert_contains "$(cat "$WORK/project/.feedback/.last-retro")" "$TODAY" "スタンプには今日の日付が入る"
assert_contains "$(fb report --last)" "フィードバックレポート" "--last でスタンプ基点のレポートが出る"

# --- yesterday ショートカット ---
YESTERDAY="$(python3 -c 'import datetime; print((datetime.date.today()-datetime.timedelta(days=1)).isoformat())')"
assert_contains "$(fb report --since yesterday)" "$YESTERDAY 以降" "--since yesterday が解決される"

# --- スタンプが無い状態での --last は明示的エラー ---
ERR="$(cd "$WORK/project2" && CLAUDE_PROJECT_DIR="$WORK/project2" python3 "$CLI" report --last 2>&1 || true)"
assert_contains "$ERR" ".last-retro がありません" "スタンプ不在の --last はエラーメッセージを出す"

assert_summary
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_report.sh`
Expected: FAIL — `report` サブコマンド未実装のため argparse error で全 assert が失敗する

- [ ] **Step 3: `set_status` に `status_changed` を追加**

`scripts/feedback_log.py` の `set_status` を差し替え:

```python
def set_status(target: dict, new_status: str) -> None:
    today = datetime.date.today().isoformat()
    text = target["path"].read_text(encoding="utf-8")
    text = text.replace(f"status: {target.get('status')}", f"status: {new_status}", 1)
    if "status_changed:" in text:
        # 1キー・上書き(report の期間集計は「最後の状態変化」を基準にする)
        text = re.sub(r"status_changed: \d{4}-\d{2}-\d{2}", f"status_changed: {today}", text, count=1)
    else:
        text = text.replace(
            f"status: {new_status}", f"status: {new_status}\nstatus_changed: {today}", 1
        )
    target["path"].write_text(text, encoding="utf-8")
```

(既存エントリは `status_changed` を持たない → report では期間外扱い。promote の日付は rules.md 出典行が真実源のため二重管理しない)

- [ ] **Step 4: `cmd_report` と argparse を実装**

`EVENTS_FILE` 定数の後に追加:

```python
LAST_RETRO = ROOT / ".feedback" / ".last-retro"
```

docstring の使い方ブロックに `stats` 行の次を追加:

```python
  feedback_log.py report --since <日付|yesterday> [--mark]  # 期間ダイジェスト(朝会・振り返りの議題)
  feedback_log.py report --last [--mark]                    # 前回の振り返り以降
```

`cmd_stats` の後に追加:

```python
def resolve_report_since(args) -> str:
    if args.last:
        if not LAST_RETRO.exists():
            sys.exit("ERROR: .feedback/.last-retro がありません。--since <日付> を指定するか、初回は --mark で基点を作ってください")
        return LAST_RETRO.read_text(encoding="utf-8").strip()
    if not args.since:
        sys.exit("ERROR: --since <日付|yesterday> か --last を指定してください")
    if args.since == "yesterday":
        return (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
    return args.since


def cmd_report(args):
    since = resolve_report_since(args)
    today = datetime.date.today().isoformat()
    print(f"# フィードバックレポート({since} 以降 {today} まで)")
    es = entries()

    print()
    print("## 新規エントリ")
    new = [e for e in es if (e.get("date") or "") >= since]
    if not new:
        print("(なし)")
    for e in sorted(new, key=lambda e: (e.get("signal") or "unknown", e.get("category", ""))):
        title = next((ln[2:] for ln in e["body"].splitlines() if ln.startswith("# ")), "")
        print(f"- [{e.get('signal') or 'unknown'}/{e.get('category','-')}] {title} ({e.get('id')})")

    print()
    print("## 昇華・統合(rules.md)")
    promoted_rules = [r for r in rule_sources() if r["date"] and r["date"] >= since]
    if not promoted_rules:
        print("(なし)")
    for r in promoted_rules:
        print(f"- [{r['category']}] 出典 {', '.join(r['sources'])} ({r['date']} 昇華)")

    print()
    print("## close・retire")
    handled = [
        e for e in es
        if (e.get("status_changed") or "") >= since
        and e.get("status") in ("closed", "retired")
    ]
    if not handled:
        print("(なし)")
    for e in sorted(handled, key=lambda e: e.get("status_changed") or ""):
        print(f"- [{e.get('status')}] {e.get('id')} ({e.get('status_changed')})")

    print()
    print("## open 棚卸し")
    opens = [e for e in es if e.get("status") == "open"]
    if not opens:
        print("(open なし)")
    else:
        for e in sorted(opens, key=lambda e: e.get("date") or ""):
            print(f"- {e.get('id')} ({e.get('date', '?')}) [{e.get('signal') or 'unknown'}/{e.get('category','-')}]")
        if len(opens) >= 3:
            print(f"NOTE: open が{len(opens)}件 — promote/close を検討してください")

    print()
    print("## 再発候補")
    cands = recurrence_candidates()
    if not cands:
        print("(なし)")
    for c in cands:
        print(f"- [{c['category']}] {', '.join(c['sources'])} ({c['date']} 昇華) ← 以降の同カテゴリ: {', '.join(c['recurrences'])}")

    print()
    print("## 数字")
    evs = load_events()
    if not evs:
        print("(イベント記録が無い)")
    else:
        cur = post_edit_first_pass(evs, since, "9999-12-31")
        if not cur[1]:
            print("(期間内の post_edit イベントが無い)")
        else:
            line = f"PostToolUse 初回通過率: 当期間 {cur[0]}/{cur[1]}"
            span = (datetime.date.fromisoformat(since) - datetime.date.today()).days
            span = abs(span) or 1
            prev_to = (datetime.date.fromisoformat(since) - datetime.timedelta(days=1)).isoformat()
            prev_from = (datetime.date.fromisoformat(since) - datetime.timedelta(days=span)).isoformat()
            prev = post_edit_first_pass(evs, prev_from, prev_to)
            if prev[1]:
                line += f"(前期間 {prev[0]}/{prev[1]})"
            print(line)

    if args.mark:
        LAST_RETRO.parent.mkdir(parents=True, exist_ok=True)
        LAST_RETRO.write_text(today, encoding="utf-8")
        print()
        print(f"(基点を更新しました: .feedback/.last-retro = {today})")
```

argparse — `stats` の後に追加:

```python
    rp = sub.add_parser("report", help="期間ダイジェスト(朝会・振り返りの議題)")
    rp.add_argument("--since", default="", help="開始日 YYYY-MM-DD または yesterday")
    rp.add_argument("--last", action="store_true", help=".last-retro 基点で期間を切る")
    rp.add_argument("--mark", action="store_true", help="実行後に .last-retro を今日で更新する")
    rp.set_defaults(func=cmd_report)
```

- [ ] **Step 5: .gitignore に追記**

`.gitignore` の `events.jsonl` ブロックの後に追加:

```
# レポートの基点スタンプ(振り返り実施日。個人の運用リズムなので共有しない)
.feedback/.last-retro
```

- [ ] **Step 6: テストを実行して通ることを確認**

Run: `bash tests/test_report.sh && bash tests/run_tests.sh`
Expected: 両方 PASS(status_changed 追加により既存の promote/merge/close/retire テストへの影響がないことも確認)

- [ ] **Step 7: コミット**

```bash
git add scripts/feedback_log.py .gitignore tests/test_report.sh
git commit -m "feat: report サブコマンドで期間ダイジェストを生成し status_changed を記録する"
```

---

### Task 7: ドキュメント・変更履歴・バージョン上げ

**Files:**
- Modify: `README.md`(運用フロー・構成)
- Modify: `scripts/README.md`(CLI表・hooks仕様)
- Modify: `skills/feedback-loop/SKILL.md`(Phase 0 ルーティング・Phase 4 前処理)
- Modify: `CLAUDE.md`(変更履歴表に1行)
- Modify: `.claude-plugin/plugin.json`(0.2.0 → 0.3.0)

**Interfaces:**
- Consumes: Task 1–6 のすべての動作するコマンド
- Produces: なし(リリース整備)

- [ ] **Step 1: README.md を更新**

(1) 「フィードバック運用フロー」のフロー図コードブロックで2箇所変更:
- `[記録]` ブロックの「失敗系は根因を --detail に1行」の行の後に1行追加(スペック§3.5「運用フロー図に signal を反映」):

```
             signal(--signal)も添える: 省略時は根因と category から推論される
```

- 最後の行(`[棚卸]` の行)の後に2行追加:

```
[測定]  feedback_log.py stats            — 初回通過率・再発候補(要求時のみ・テキスト出力)
[報告]  feedback_log.py report --last → 朝会/振り返りの5分議題(実施後に --mark で基点更新)
```

(2) 同セクション末尾(Feedback Flywheel 参照の段落の後)に1段落追加:

```markdown
測定は Flywheel の「衡量变化」に相当する。ダッシュボードは作らない — `stats` は要求時のテキスト出力で、数字は `report` の「数字」セクションにだけ現れる。`events.jsonl`(フック合否)と `.last-retro`(振り返り基点)はマシンローカルの状態であり、git で共有しない。
```

(3) 「構成」ツリーの `.feedback/` ブロック(`.last-check` の行)の後に1行追加:

```
  events.jsonl     # フック合否のイベントログ(stats用のローカル状態・gitignore対象)
```

- [ ] **Step 2: scripts/README.md を更新**

(1) `feedback_log.py` のコマンド表に2行追加(`rules` 行の後):

```markdown
| `stats` | `[--since <日付>]` `[--days <N>]` | フック合否とログの集計。PostToolUse 初回通過率・平均再チェック回数・Stop 初回通過率・失敗上位・signal/根因別件数・**再発候補**(昇華後に同カテゴリの失敗系が再記録されたルール) |
| `report` | `--since <日付\|yesterday>` または `--last`、`[--mark]` | 期間ダイジェスト(新規エントリ/昇華/close・retire/open 棚卸し/再発候補/数字)。`--last` は `.feedback/.last-retro` 基点。`--mark` で実施後に基点を更新 |
```

(2) `add` 行の引数列に `[--signal <context\|instruction\|workflow\|failure>]` を追記し、説明列の末尾に「信号種(省略時は detail/category から推論。昇華先ルーティングの軸)」を追記。

(3) `hooks/` 仕様の `post_edit.sh` 箇条書きの末尾に追記:

```markdown
  - 合否(成功・失敗の両方)を `.feedback/events.jsonl` に1行追記する(`stats` の初回通過率の原料。ローカル状態で共有しない)
```

`on_stop.sh` の「検査の実行条件」箇条書きの末尾に追記:

```markdown
  - `check.sh` を実行したときだけ合否を `events.jsonl` に記録する(スキップ時は無記録)
```

- [ ] **Step 3: skills/feedback-loop/SKILL.md を更新**

(1) Phase 0 のモード判定リスト(`_workspace/` の行の前)に1行追加:

```markdown
   - 数字・レポートの依頼(「調子は」「初回通過率」「振り返りの議題」等) → **stats/report 実行**(`feedback_log.py stats` / `report --last`。振り返り実施後は `report --last --mark` で基点を更新する)
```

(2) Phase 4 の手順リストの先頭に新しい手順1を挿入し、既存の手順1・2を2・3に繰り下げる:

```markdown
1. まず `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/feedback_log.py" stats` を実行する — 再発候補と open 滞留が機械的に出る。以下の調査はその裏取りとして行う
```

(挿入後、旧手順1「`.feedback/rules.md` の各ルールについて調べる:」は手順2、旧手順2「各ルールを3分類でレポート」は手順3になる)

- [ ] **Step 4: CLAUDE.md の変更履歴に1行追加**

変更履歴テーブルの最終行の後に追加:

```markdown
| 2026-08-16 | Flywheel Step 4(信号種・測定・報告) | feedback_log.py / hooks / lib.sh / rules.template / skills / tests | 信号4分類のデータ化、フック合否からの初回通過率測定、朝会・振り返り議題の report、再発候補の機械化 |
```

- [ ] **Step 5: バージョンを 0.3.0 に上げる**

`.claude-plugin/plugin.json` の `"version": "0.2.0",` を `"version": "0.3.0",` に変更。

- [ ] **Step 6: 全体チェック**

Run: `bash scripts/check.sh`
Expected: `ALL PASS`(shellcheck: 新規シェルコードは `-S warning` 基準を満たす。Python: ruff。tests: 全 PASS)

- [ ] **Step 7: コミット**

```bash
git add README.md scripts/README.md skills/feedback-loop/SKILL.md CLAUDE.md .claude-plugin/plugin.json
git commit -m "docs: Step4(signals/stats/report)の文書を整え v0.3.0 に上げる"
```

---

## 完了後の自省(実行エージェント向け)

計画全体を終えたら、このセッションで共有アーティファクト(CLAUDE.md・`docs/`・スキル)を変えるべき出来事があったかを1問自省する(CLAUDE.md のトリガーに従う)。実装中に設計と実際が食い違った場合は、設計書(spec)側も更新してから完了すること。
