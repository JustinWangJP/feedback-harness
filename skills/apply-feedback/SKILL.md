---
name: apply-feedback
description: 蓄積された過去のフィードバックルールを現在の作業に反映するスキル。コード生成・編集・レビュー・設計などプロジェクト内の実装作業を開始する前に必ずこのスキルを使用すること。「過去の指摘を踏まえて」「前回のフィードバックを反映して」「ルールに従って」という依頼、および作業のやり直し・修正・改善の依頼でも使用する。
---

# Apply Feedback

過去に人間が与えた指摘から昇華されたルールを、これから行う作業に適用する。ルールは実際に起きた手戻りの記録であり、無視すれば同じ指摘が繰り返される。

## 手順

1. `.feedback/rules.md` を読む(なければ `python3 "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/scripts/feedback_log.py" rules` で確認)。rules.md は2セクション構造 — **守るべき制約(失敗由来)** は守るべき制約、**再現すべき措辞・進め方(成功由来)** は次回再現すべき正例として読む
2. 未昇華の open エントリも確認する: `python3 "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/scripts/feedback_log.py" list --status open` — 記録は昇華を待たず、その時点から次の作業に活かす（promote 待ちのまま放置しない）
3. 今回の作業に関係するルール・エントリを特定する — カテゴリ(`style`/`architecture`/`testing`/`naming`/`workflow`/`domain`)が作業タイプと一致するもの
4. 該当ルールを作業方針に組み込んでから実装を開始する。open エントリとルールが食い違う場合は、検証済みの rules.md を優先する
5. ルールと今回の指示が矛盾する場合は、**今回の明示的な指示を優先**し、矛盾があったことをユーザーに一言伝える(ルールの更新機会になる)

## 追加の文脈が必要なとき

ルールの意図が不明確なら、出典エントリを読む:

```bash
python3 "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/scripts/feedback_log.py" search <キーワード>
```

出典には指摘時の具体的文脈(どのファイルで何が起きたか)が残っている。
