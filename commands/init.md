---
description: このプロジェクトへフィードバックハーネスの Codex 向け資産(scripts/ と AGENTS.md)を展開する
---

# feedback-harness init

このプロジェクトで Codex や他の汎用エージェントも使う場合に実行する。Claude Code だけで使うなら実行不要(スキル・エージェント・Hooks はプラグインが提供し、`.feedback/` は SessionStart フックが用意する)。

## 手順

1. 次のコマンドを実行する:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" "${CLAUDE_PROJECT_DIR}"
```

2. 出力を読み、各項目が OK / 追記 / スキップのいずれかで完了していることを確認する。

3. 展開された `scripts/check.sh` が動くことを確認する:

```bash
cd "${CLAUDE_PROJECT_DIR}" && bash scripts/check.sh; echo "exit=$?"
```

`exit=0` でなければ、出力された FAIL の内容をユーザーに報告する。スタック未検出(`検出できたスタックがありません`)は失敗ではない。

4. 追加・変更されたファイルをユーザーに列挙して報告する。`git add` やコミットは行わない — 何を取り込むかはユーザーが決める。
