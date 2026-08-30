# feature/enhance-fowler-feedback コードレビュー

> **履歴資料:** これは `feature/enhance-fowler-feedback` ブランチに対するレビュー記録です。指摘は対応済みで、ブランチは main へマージ済みです。本文の行番号・引用は当時のもので、現在の実装とは一致しません。現在の仕様は[プロジェクト概要](../README.md)と[スクリプト仕様](../scripts/README.md)を参照してください。

- 比較基準: `origin/main`
- merge base: `cb5ba2998722cf10dd7c84443269e1d5e02797b3`
- 対象ブランチ: `feature/enhance-fowler-feedback`
- 結果: 修正候補 4件

## Findings

### [P2] 単一ファイル検査でも実効判定を一貫させる

対象: `scripts/check_file.sh:20`

設定連携が一部の `skip` だけに留まり、`severity: warn` は最終的に exit 1、`node-lint` の skip や `bash-syntax` の skip も検査を止めない。

実際に、ruff の `severity: warn` と node-lint の `severity: skip` がともに `check_file.sh` で exit 1 になることを確認した。フルチェックでは WARN/SKIP になる一方、Claude Code の PostToolUse では編集のたびにブロックされる。

検査IDごとに実効判定を解決し、skip は実行せず、warn は指摘を表示しても非ブロッキングにする必要がある。

### [P2] 壊れた config を即時チェックで失敗させる

対象: `scripts/check_file.sh:76`

`harness_load_config` が設定エラーを `HARNESS_CONFIG_ERROR` に載せても、YAML分岐は一般的なYAML構文だけを検査し、そのエラーを無視する。

例えば `check.lnit` という未知キーを含む `.feedback/config.yaml` に対し、`check_file.sh` は出力なしの exit 0 になった。このリポジトリでは `AGENTS.md` §2 により、編集直後の必須ゲートとして `check_file.sh` を使うため、設定エラーもここで表示して非0にする必要がある。

### [P2] 閉じていないクォートを拒否する

対象: `scripts/harness_config.py:99`

先頭だけがクォートの値は裸文字列として通過する。

`checks.oasdiff.base: "main` がエラーなしで値 `"main` になり、`git merge-base` が失敗して HEAD フォールバックへ進むため、契約差分を事実上無効化できる。クォートやフローリストの開始・終了が不均衡なら、行番号付きの `ConfigError` にする必要がある。

### [P2] 整数設定の有効範囲を検証する

対象: `scripts/harness_config.py:288`

整数型であることしか確認しないため、雛形で 0–100 と定義されている `checks.vulture.min_confidence` に 101 を指定しても受理される。

最大信頼度を超える閾値は検出を黙って空にできるため、キー固有の範囲制約をスキーマに持たせて拒否する必要がある。

## Verification

リポジトリ指定のフルチェックを実行し、exit 0 を確認した。

```text
ALL PASS (1件WARN・2件SKIP — 未検証/未対応の項目があります)
exit=0
```

WARN は `scripts/feedback_log.py` と `scripts/harness_config.py` の ruff format、SKIP は PyYAML 未導入および secretlint 未設定によるもの。
