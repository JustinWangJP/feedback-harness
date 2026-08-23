---
id: 20260823-222836
date: 2026-08-23
source: human
category: testing
signal: failure
status: open
---

# Windows CIではUnicode出力を含むPython実行をUTF-8で検証する

Windows Git Bash対応のPR #13で、ローカルのフルチェック成功だけで完了とし、Windows runner固有のcp1252標準出力によるUnicodeEncodeErrorを事前に防げなかった。Windows上でUnicodeを出力するPythonジョブにはUTF-8の標準入出力設定を明示し、PR作成後は新設したプラットフォーム別CIの結果も確認する。
根因: 実行誤り
