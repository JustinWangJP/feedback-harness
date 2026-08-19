---
description: このプロジェクトへフィードバックハーネスの Hooks 非対応環境向け資産(scripts/ と AGENTS.md)を展開する
---

# feedback-harness init

このプロジェクトで Codex IDE 拡張や他の汎用エージェントも使う場合に実行する。Claude Code または Codex app / CLI のプラグインだけで使うなら実行不要（スキルと Hooks はプラグインが提供し、`.feedback/` は SessionStart フックが用意する）。

## 手順

1. 次のコマンドを実行する:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" "${CLAUDE_PROJECT_DIR}"
```

2. 出力を読み、各項目が OK / 新規作成 / 追記 / 更新 / 移行 / スキップのいずれかで完了していることを確認する。

   既存の CLAUDE.md / AGENTS.md は `feedback-harness:pointer` 管理マーカー内だけが最新版へ置換され、マーカー外の記述は保持される。旧版のマーカーなしポインタは、既知の見出しと末尾を特定できる場合に管理ブロックへ移行する。安全に末尾を特定できない場合は処理を止め、手動で旧ポインタを削除して再実行するよう案内する。

3. 展開された `scripts/check.sh` が動くことを確認する:

```bash
cd "${CLAUDE_PROJECT_DIR}" && bash scripts/check.sh; echo "exit=$?"
```

`exit=0` でなければ、出力された FAIL の内容をユーザーに報告する。スタック未検出(`検出できたスタックがありません`)は失敗ではない。

4. 追加・変更されたファイルをユーザーに列挙して報告する。`git add` やコミットは行わない — 何を取り込むかはユーザーが決める。
