---
name: feedback-loop
description: フィードバックハーネス全体のオーケストレーター。フィードバックの棚卸し・ルール昇華・ハーネス検証・別プロジェクトへの導入を統括する。「フィードバックを整理して」「ルール化して」「一般化して」「ハーネスを点検して」「ハーネスを検証して」「このハーネスを○○プロジェクトに導入して」「フィードバックループを回して」「再実行」「もう一度整理」「前回の結果を更新」「ルールを棚卸しして」「ルールを見直して」「定期審査」などの依頼で必ずこのスキルを使用すること。個別の指摘記録だけなら capture-feedback、作業前のルール適用だけなら apply-feedback を使う。
---

# Feedback Loop — オーケストレーター

**実行モード: サブエージェント。** 各Phaseは単一エージェントの逐次作業であり、チーム通信の利得がオーバーヘッドを上回らないため。Claude Code では `Agent`、Codex ではサブエージェント機能を使う。データ受け渡しは戻り値ベース(結果収集) + ファイルベース(`.feedback/`、`_workspace/`)。

プラグインルートは Codex の `PLUGIN_ROOT`、Claude Code の `CLAUDE_PLUGIN_ROOT` の順で解決する。以下のコマンドでスクリプトを呼ぶ場合は `${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}` を使用する。

## Phase 0: コンテキスト確認

1. `.feedback/log/` と `.feedback/rules.md` の現況を確認する
2. 実行モードを判定する:
   - openエントリあり + 整理・昇華の依頼 → **キュレーション実行** (Phase 1)
   - ハーネス構成の点検・検証の依頼 → **QA実行** (Phase 2)
   - 別プロジェクトへの導入依頼 → **導入実行** (Phase 3)
   - ルールの棚卸し・見直し・定期審査の依頼 → **棚卸し実行** (Phase 4)
   - 数字・レポートの依頼(「調子は」「初回通過率」「振り返りの議題」等) → **stats/report 実行**(`feedback_log.py stats` / `report --last`。振り返り実施後は `report --last --mark` で基点を更新する)
   - 脆弱性監査の依頼(「監査して」「脆弱性チェック」等)、または report で監査期限切れを指摘された → **監査実行**(`bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/scripts/audit.sh"`。ネットワークを使うため Stop フックでは走らない)
   - `_workspace/` に前回レポートあり + 部分修正依頼 → 該当Phaseのみ再実行

## Phase 1: キュレーション (フィードバック → ルール)

環境のサブエージェント機能で feedback-curator を呼び出す（定義: `agents/feedback-curator.md` — 定義ファイルの作業原則を prompt に含める）。Claude Code では `Agent` と `model: "opus"`、Codex では継承モデルを使う:

- 入力: openエントリ一覧 + 既存rules.md + ユーザーの直近指摘
- 期待出力: promote/merge/close の実行結果と判断の要約。rules.md 以外への反映提案(CLAUDE.md 追記案・lint/テスト追加案)があればその一覧
- 完了後、rules.mdの差分と反映提案をユーザーに提示する。提案の採否はユーザーが決める(curator は共有アーティファクトを直接編集しない)

## Phase 2: ハーネスQA

環境のサブエージェント機能で harness-qa を呼び出す（定義: `agents/harness-qa.md`）。Claude Code では `Agent` と `model: "opus"`、Codex では継承モデルを使う:

- 入力: 検証対象(直近の変更、または全体)
- 期待出力: 境界面クロス比較のPASS/FAIL/SKIPレポート + 修正案
- レポートは `_workspace/qa_report_{日付}.md` に保存する
- FAILがあれば修正し、修正部分のみ再QAする(漸進的QA)

## Phase 3: 別プロジェクトへの導入

1. `bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/scripts/init.sh" <対象プロジェクトパス>` を実行する(導入先にはまだ `scripts/` が無い — それを作るのが init.sh である)
2. 対象プロジェクトの既存 CLAUDE.md / AGENTS.md がある場合、init.shは追記モードで動く — 出力を確認し重複記載があれば整理する
3. 導入後、対象プロジェクトで `bash scripts/check.sh` を1回実行してスタック検出を確認する

## Phase 4: 棚卸し (ルールの定期審査)

更新されないルールは安定するのではなく負債になる。目安は四半期に1回、またはルールが実践と乖離したと感じたとき。

1. まず `python3 "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/scripts/feedback_log.py" stats` を実行する — 再発候補と open 滞留が機械的に出る。以下の調査はその裏取りとして行う
2. `.feedback/rules.md` の各ルールについて調べる:
   - 昇華日からの経過(出典の日付)と、現在のコード・運用との矛盾(陳腐化)
   - promote 後の同種指摘の再発(`.feedback/log/` を検索) — 再発があれば「ルールが効いていない」兆候。feedback-curator の再発原則(`merge --rule` での文言強化)を適用する
3. 各ルールを「**維持 / 文言強化 / 退役候補**」の3分類でレポートし、ユーザーに提示する
4. 退役はユーザーの裁定後にのみ実行する(rules.md の手編集はしない):

```bash
python3 "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/scripts/feedback_log.py" retire <出典id> --reason "<退役理由>"
```

rules.md からルールが撤去され、出典エントリ(merge済みの分も含む)が retired に更新され、理由が監査痕跡として残る。

## エラーハンドリング

- サブエージェント失敗時は1回リトライ。再失敗したらその結果なしで続行し、レポートに欠落を明記する
- rules.mdの矛盾は削除せず両論併記でユーザーに裁定を求める

## テストシナリオ

**正常フロー:** openエントリ2件がある状態で「フィードバックを整理して」→ Phase 0でキュレーション判定 → curatorが1件をpromote・1件をopen維持 → rules.md差分を提示。

**エラーフロー:** `init.sh` に渡した対象パスが存在しない → エラーを報告し、正しいパスをユーザーに確認する(勝手にディレクトリを作らない)。
