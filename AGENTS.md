# feedback-harness — エージェント作業規約 (Codex / 汎用エージェント向け)

このプロジェクトにはフィードバックハーネスが導入されている。Hooksを持たない環境(Codex等)では、以下の規約が自動フィードバックループの代替となる。**必ず従うこと。**

## 1. セッション開始時

`.feedback/rules.md` を読み、蓄積されたルールを作業方針に反映する。ルールは過去に実際に起きた手戻りの記録である。

```bash
python3 scripts/feedback_log.py rules
```

## 2. コード変更のたび

編集したファイルを即時チェックする:

```bash
bash scripts/check_file.sh <編集したファイル>
```

問題が出力されたら修正してから次の作業に進む。

## 3. 作業完了の前

必ずフルチェックを実行し、ALL PASS を確認してから完了とする:

```bash
bash scripts/check.sh
```

FAILがある状態で「完了しました」と報告してはならない。失敗ログは末尾に要約されるので、それを読んで修正 → 再実行を繰り返す。

## 4. 人間から指摘・修正を受けたら

その場で記録する(次のセッションに引き継ぐ唯一の手段):

```bash
python3 scripts/feedback_log.py add --category <style|architecture|testing|naming|workflow|domain> \
  --summary "<1文要約>" --detail "<文脈>" --source human
```

再発しうる指摘は記録し、そのタスク限りの指示は記録しない。迷ったら記録する。

## 5. ルールと指示が矛盾したら

今回の明示的な指示を優先し、矛盾があったことをユーザーに一言伝える。
