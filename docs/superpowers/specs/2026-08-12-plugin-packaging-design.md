# feedback-harness のパッケージ化設計

> **履歴資料:** パッケージ化は実装済みです。その後、開発用 `.claude/settings.json` に Hooks を複製する方式から、同ファイルでプラグインを有効化する方式へ移行しました。現在の構成は[プロジェクト概要](../../../README.md)を参照してください。

- 日付: 2026-08-12
- 状態: 実装済み（設計時点の記録として保存）

## 目的

feedback-harness を他の Git リポジトリへ配布可能な形にパッケージ化する。現行の `install.sh` によるファイル複製方式は、導入先に実体がコピーされるため、本体を修正しても導入先が追従しない(ドリフト)。これを解消しつつ、Claude Code と Codex / 汎用エージェントの両対応を維持する。

## 決定事項

| 項目 | 決定 |
|------|------|
| 配布方式 | Claude Code Plugin(このリポジトリ自体をマーケットプレイス兼プラグインにする) |
| 配布先 | GitHub パブリックリポジトリ `JustinWangJP/feedback-harness` |
| 対象環境 | Claude Code と Codex / 汎用エージェントの両対応を維持 |
| 導入ロジック | `scripts/init.sh` に一本化。`/feedback-harness:init` はその薄いラッパー |

### 採用しなかった案

- **Plugin 一本(init コマンドなし)**: Codex 側のセットアップが手動手順に退化し、「両対応維持」の決定と噛み合わない。
- **npx / uvx CLI 化(Plugin を使わない)**: 両環境が同一機構になる利点はあるが、コピー方式のドリフトが残る。今回最も解きたかった問題が未解決のまま。

## アーキテクチャ

### 実体の所在

コード(スクリプト・スキル・エージェント・Hooks)とデータ(`.feedback/`)を分離する。

| 種別 | 実体の置き場 | 更新経路 |
|------|------------|---------|
| skills / agents / hooks / scripts | プラグイン側のみ | marketplace の自動 `git pull` |
| `.feedback/` (rules.md, log/) | 導入先リポジトリ内・コミット対象 | 運用で育つ |
| Codex 用 `scripts/` + `AGENTS.md` | 導入先リポジトリ内(ベンダリング) | `init` 再実行 |

Claude Code は常にプラグイン側のスクリプトを実行し、Codex は導入先リポジトリ内のコピーを実行する。両者は同一の `.feedback/` を読み書きする。

**「導入先に scripts/ があればそちらを優先」という解決順は採用しない。** 古いベンダリングコピーが自動更新されたプラグインを打ち消し、更新の自動化という本設計の主目的を無効化するため。

### パス解決ルール(全スクリプト共通)

プロジェクトルートの解決順を統一する:

```
明示引数(あれば)  →  CLAUDE_PROJECT_DIR  →  git rev-parse --show-toplevel  →  cwd
```

明示引数を受け取るのは `check.sh` のみ(第1引数)。他のスクリプトは第2段以降から解決する。

`Path(__file__).parent.parent` を起点とする解決は廃止する。これにより「スクリプトがどこにあるか」と「どのプロジェクトのデータか」が完全に分離され、プラグイン経由・`init.sh` 経由・Codex からの直接実行のいずれでも同じ場所を指す。

### リポジトリ構成

```
feedback-harness/
  .claude-plugin/
    marketplace.json      # カタログ (このリポジトリ1件を指す)
    plugin.json           # name: feedback-harness
  skills/                 # .claude/skills/ から移設
    apply-feedback/SKILL.md
    capture-feedback/SKILL.md
    feedback-loop/SKILL.md
  agents/                 # .claude/agents/ から移設
    feedback-curator.md
    harness-qa.md
  commands/
    init.md               # scripts/init.sh を呼ぶ薄いラッパー
  hooks/
    hooks.json            # .claude/settings.json から移設
  scripts/
    check.sh  check_file.sh  lib.sh  feedback_log.py
    init.sh               # 旧 install.sh
    hooks/post_edit.sh  hooks/on_stop.sh  hooks/on_session_start.sh
  docs/
    pointer_claude.md  pointer_agents.md
  tests/                  # bash テスト。check.sh の make check フォールバック経由で自動実行される
  Makefile                # check: → tests/run_tests.sh
  .claude/
    settings.json         # このリポジトリの開発用設定（現在はプラグインを有効化。配布対象外）
  .feedback/              # このリポジトリ自身の蓄積(配布対象外)
```

実装で確定した点:

1. 実装当初は `.claude/settings.json` に開発用 Hooks を残し、配布用 `hooks/hooks.json` との一致をテストしていた。その後、Hooks の二重実行を避けるため、`.claude/settings.json` はプラグインの有効化だけを担い、Hooks はプラグイン側に一本化した。
2. `tests/`(bash テスト)と `Makefile` を新設した。`Makefile` の `check:` ターゲットが `tests/run_tests.sh` を呼び、`scripts/check.sh` は Python/Node 等のスタックが検出できない場合に `make check` の存在をフォールバックとして検出して実行する。これにより `bash scripts/check.sh .` からハーネス自身のテストが自動実行される。
3. `.claude-plugin/marketplace.json` の `plugins[0].source` は `"./"` で確定した(`claude plugin validate .` が受理する)。ただしローカルインストール時の CLI 引数としては `claude plugin marketplace add ./` の形が必要で、bare `.` は拒否される。
4. `hooks/hooks.json` には最終的に `SessionStart` / `PostToolUse` / `Stop` の3つが登録されている。`.feedback/` の自動シード(項番7)を担う `SessionStart` は設計の初期段階では未反映だったが、実装時に追加された。

## 修正が必要な既存コード

### 1. `scripts/feedback_log.py` — ROOT 解決

現状:

```python
ROOT = Path(__file__).resolve().parent.parent
LOG_DIR = ROOT / ".feedback" / "log"
```

プラグインキャッシュから実行されると、蓄積先が導入先ではなくプラグインキャッシュ内になる。公式ドキュメントは `${CLAUDE_PLUGIN_ROOT}` を「更新時に変わる。ephemeral として扱い、状態を書き込むな」と規定しており、この状態では**蓄積したルールがプラグイン更新で失われる**。

共通のパス解決ルールに置き換える。

### 2. `scripts/hooks/on_stop.sh:22` — ROOT フォールバック

現状:

```bash
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$DIR/../.." && pwd)}"
```

`CLAUDE_PROJECT_DIR` が無い経路でプラグインキャッシュを検査ツリーと誤認する。フォールバックを `git rev-parse --show-toplevel` に変更する。

### 3. `scripts/check.sh` — 引数省略時のルート

省略時に cwd を使う挙動は維持しつつ、共通の解決ルール(`CLAUDE_PROJECT_DIR` → `git rev-parse` → cwd)へ揃える。解決結果は `lib.sh` の共有関数として実装し、3スクリプトから参照する(ドリフト防止)。

### 4. SKILL.md / agent 内のコマンド表記

`python3 scripts/feedback_log.py ...` を `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/feedback_log.py" ...` に置換する。公式仕様上、skill / agent 本文中の placeholder は出現箇所を問わず実パスへ展開される。

`docs/pointer_agents.md`(AGENTS.md へ追記される断片)は Codex が placeholder を解釈できないため、リポジトリ相対の `scripts/feedback_log.py` のまま据え置く。この断片が使われるのは `init.sh` が `scripts/` をベンダリングした場合に限られるため、参照先は実在する。

### 5. `hooks/hooks.json`

`.claude/settings.json` の hooks 定義を移設し、コマンドを `${CLAUDE_PLUGIN_ROOT}` 基準に書き換える。シェル形式では変数をダブルクォートで囲む:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}\"/scripts/hooks/post_edit.sh", "timeout": 60 }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}\"/scripts/hooks/on_stop.sh", "timeout": 300 }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}\"/scripts/hooks/on_session_start.sh", "timeout": 30 }
        ]
      }
    ]
  }
}
```

### 6. `install.sh` → `scripts/init.sh`

`.claude/agents`、`.claude/skills`、`.claude/settings.json` のコピー処理を削除する(プラグインが担うため)。残す責務:

- `scripts/` のベンダリング(Codex 用)
- `.feedback/` のシード作成
- `CLAUDE.md` / `AGENTS.md` へのポインタ追記
- `.gitignore` への `_workspace/` 追記

### 7. `.feedback/` の自動シード

Claude Code のみのプロジェクトでは `init.sh` が実行されない。新規スクリプト `scripts/hooks/on_session_start.sh` を SessionStart Hook として追加し、導入先に `.feedback/` が無ければ `rules.template.md` からシードする。既存の `.feedback/` には一切触れない。シードに失敗しても常に exit 0 とし、セッション開始をブロックしない。

## 導入手順(利用者視点)

| 利用者 | 手順 | 導入先に置かれるもの |
|--------|------|-------------------|
| Claude Code のみ | `/plugin marketplace add JustinWangJP/feedback-harness` → `/plugin install feedback-harness@feedback-harness` | `.feedback/` のみ |
| Claude Code + Codex | 上記 + `/feedback-harness:init` | `.feedback/`、`scripts/`、`AGENTS.md`、`CLAUDE.md` |
| Codex のみ | `git clone` → `bash scripts/init.sh <target>` | `.feedback/`、`scripts/`、`AGENTS.md`、`CLAUDE.md` |

導入先の `.claude/settings.json` に `extraKnownMarketplaces` を書いておけば、チームメンバーがフォルダを信頼した時点でインストールを促される。この設定断片は `docs/pointer_claude.md` と併せて案内する。

## エラーハンドリング

| 状況 | 挙動 |
|------|------|
| `CLAUDE_PROJECT_DIR` 未設定かつ git 管理外 | cwd をルートとして使う。`check.sh` は現行どおりスタック未検出なら exit 0 で `検出できたスタックがありません` を出す |
| プラグイン経由と `init.sh` 経由の scripts が両方存在 | Claude Code はプラグイン側、Codex は repo 側を実行する。同一の `.feedback/` を共有するため競合しない |
| `init.sh` の再実行 | 冪等。ポインタは marker 検出でスキップ、`.feedback/rules.md` は既存なら触らない(現行 `install.sh` の挙動を維持) |
| プラグイン更新中の Hook 実行 | 公式仕様上、セッション中の更新では旧バージョンのパスを使い続ける。状態は `.feedback/`(導入先)にあるため影響しない |

## テスト方針

`harness-qa` エージェントの検証項目を、プラグイン構成に合わせて拡張する。

1. **マニフェスト検証**: `claude plugin validate .` が通ること
2. **パス解決の検証**: プラグインキャッシュを模したディレクトリから `feedback_log.py add` を実行し、`.feedback/` が**導入先**に作られることを確認する(退行しやすい最重要ポイント)
3. **3経路の導入テスト**: 空のリポジトリに対し Claude Code のみ / 両対応 / Codex のみの3手順をそれぞれ実行し、想定どおりのファイル構成になることを確認する
4. **冪等性**: `init.sh` を2回実行してもポインタが重複追記されないこと
5. **自己適用**: このリポジトリ自身に対する `check.sh` が引き続き PASS すること

## スコープ外

- npm / PyPI への公開(Plugin マーケットプレイスが配布経路のため不要)
- 既存の導入先プロジェクトからの自動マイグレーション(該当があれば手動で `init.sh` 再実行 + 旧 `.claude/` 資産の削除を案内する)
- プラグインのバージョニング運用ルール(初版は `0.1.0` 固定とし、運用開始後に定める)
