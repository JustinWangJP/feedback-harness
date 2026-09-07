## ハーネス: フィードバックループ

このプロジェクトにはフィードバックハーネスが導入されている。Claude Code プラグインの Hooks が有効なら、以下の変更時チェックと完了前チェックは自動実行される。`init.sh` だけで導入した場合、または Hooks が無効な場合は、この規約が自動フィードバックループの代わりとなる。**いずれの場合も完了条件として必ず従うこと。**

### 1. セッション開始時

導入先の利用者が正本として指定している共通規約と、今回の作業に必要な参照文書を読む。このポインタはハーネスの運用手順であり、導入先の文書構成や正本を指定するものではない。

`.feedback/rules.md` と、まだルール化されていない open エントリを確認し、今回の作業方針へ反映する。

```bash
bash scripts/feedback.sh rules
bash scripts/feedback.sh list --status open
```

open エントリと rules.md が食い違う場合は、検証済みの rules.md を優先する。

### 2. コード変更のたび

Hooks が有効なら `PostToolUse` が編集したファイルを即時チェックする。Hooks が無効なら次を手動実行する。

```bash
bash scripts/check_file.sh <編集したファイル>
```

問題が出力されたら修正してから次の作業に進む。

### 3. 作業完了の前

Hooks が有効なら `Stop` がフルチェックを実行する。Hooks が無効なら次を手動実行する。どちらの場合も **終了コード 0** を確認してから完了とする。

```bash
bash scripts/check.sh; echo "exit=$?"
```

FAIL（exit 1）がある状態で完了を報告してはならない。WARN は内容を確認して直せるものを直し、SKIP は未検証の理由を確認する。

同種の check 失敗がセッション内で繰り返された場合は、修正後に次節の手順で記録する（`--source hook`）。

チェックが通ったら、完了前に一度だけ振り返る。**このセッションで、共有成果物（`.feedback/rules.md`・CLAUDE.md / AGENTS.md・スキル）を変えるべき出来事はあったか？** あれば次節の手順で記録してから完了する。

### 4. 人間から指摘・修正を受けたら

再発しうる指摘と、次回も再現したい成功パターンをその場で記録する。そのタスク限りの指示は記録しない。

```bash
bash scripts/feedback.sh add --category <style|architecture|testing|naming|workflow|domain> \
  --summary "<1文要約>" --detail "<文脈>" --source human \
  [--signal <context|instruction|workflow|failure>]
```

signal と根因は別に判定する。誤った出力・行動は、原因にかかわらず `--signal failure` とする。失敗系は、次のいずれかを `--detail` に `根因: <分類>` として1行含める。

- `文脈欠落`: 判断に必要な情報が、判断時に読み込まれた文脈になかった。参照可能な情報を調べなかった、または提示済み情報を見落とした場合は含めない
- `指示欠陥`: 期待結果・制約・受け入れ条件・手順が欠落、曖昧、または矛盾していた。個別の禁止規則がなかったという理由だけで通常のバグを含めない
- `実行誤り`: 必要な文脈と十分に明確な指示があったのに、見落とし、指示違反、推論ミス、実装ミスが起きた
- `モデル限界`: 十分な文脈、明確な指示、利用可能なツール、妥当な再試行を与えても同種の失敗を安定して避けられない。単発の失敗だけでは選ばない
- `未判定`: 証拠不足、または複数の原因を切り分けられない

失敗を伴わない前提情報の追加は `context`、有効だった措辞は `instruction`、有効だった進め方は `workflow` とする。`--signal` を省略した場合、根因行があれば `failure`、根因行がなくカテゴリが workflow なら `workflow`、それ以外は `instruction` と推論される。

### 5. フィードバックの反映先

指摘を記録した後、その内容を共有文書へ反映するときは、導入先に存在する AGENTS.md / CLAUDE.md と、その文書が参照する共通規約・前提情報を読む。ファイル名だけで正本を決めず、利用者が指定した役割と参照関係から反映先を選ぶ。

| 導入先の状態 | 反映先の選び方 |
|---|---|
| 共通規約と参照文書が明示されている | 共通の行動制約は正本、前提知識・背景は役割に合う参照文書へ提案する。入口から読まれない場合は参照の追加も提案する |
| AGENTS.md または CLAUDE.md だけがある | 存在する文書と参照先を入口にする。もう一方の新設を前提にしない |
| 両方あるが正本が不明・矛盾している | 候補と確認事項を提示し、反映先の裁定を求める。同じ内容を両方へ追記しない |
| どちらもない | 既存の開発規約・参照資料を確認して候補を示す。固定名の文書を無断で作らない |

`context` と `failure / 文脈欠落` は前提情報の追記案を作る。参照可能な情報を調べなかった場合は文脈欠落ではなく実行誤りとして扱う。指摘を行動規則へ一般化する場合は、既存ルールを確認して `bash scripts/feedback.sh promote` / `merge` を使い、出典と状態を維持する。`.feedback/rules.md` を手編集で統合・削除せず、`retire` はユーザーの裁定後に行う。

自動チェックの追加案は `automation_candidates`、文書の追記案は `document_candidates` として次の項目を提示する。スキル・エージェント定義が配布されない `init.sh` 単独導入でも、この手順を使う。

```yaml
automation_candidates:
  - candidate: "機械的に検出したい失敗"
    evidence: "対象entry IDと再現・反復の証拠"
    recommended_check: "追加するlint・テスト・チェックの案"
    human_decision: pending
document_candidates:
  - target_path: "導入先ルートからの相対パス（未決定なら null）"
    section: "追記する節"
    proposed_text: "追加する文面"
    reason: "文書の役割に基づく選定理由"
    read_path: ["入口の指示文書", "対象の参照文書"]
    evidence: "対象entry IDと確認した文脈"
    human_decision: pending
```

候補がない種類も `automation_candidates: []` / `document_candidates: []` を提示する。反映先が未決定なら `target_path: null` とし、`reason` に候補と確認事項を示す。`.feedback/rules.md` 以外は具体的な提案を提示し、ユーザーの承認後に反映する。承認を推測して `human_decision` を変更しない。

### 6. ルールと指示が矛盾したら

今回の明示的な指示を優先し、矛盾があったことをユーザーに一言伝える。

**変更履歴:**
| 日付 | 変更内容 | 対象 | 理由 |
|------|----------|------|------|
| {{INSTALL_DATE}} | フィードバックハーネス導入 | 全体 | - |

**ハーネス本体の更新:** Claude Code のスキル・エージェント・Hooks はプラグインが提供する。第三者マーケットプレイスは自動更新が既定で無効なので、`/plugin` → `Marketplaces` → `feedback-harness` で `Enable auto-update` を選んだ場合にのみ起動時に自動更新される。無効のまま更新する場合は `/plugin marketplace update feedback-harness` の後に `/plugin update feedback-harness@feedback-harness` を実行し、必要に応じて `/reload-plugins` する。`scripts/` を `init.sh` でベンダリングしている場合は、`init.sh` を再実行すると管理マーカー内のポインタも最新版へ置換される。
