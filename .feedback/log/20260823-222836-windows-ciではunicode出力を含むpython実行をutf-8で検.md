---
id: 20260823-222836
date: 2026-08-23
source: human
category: testing
signal: failure
status: closed
status_changed: 2026-08-23
---

# Windows CIではUnicode出力を含むPython実行をUTF-8で検証する

Windows Git Bash対応のPR #13で、ローカルのフルチェック成功だけで完了とし、Windows runner固有のcp1252標準出力によるUnicodeEncodeErrorを事前に防げなかった。Windows上でUnicodeを出力するPythonジョブにはUTF-8の標準入出力設定を明示し、PR作成後は新設したプラットフォーム別CIの結果も確認する。
根因: 実行誤り

---
close理由: PR #13レビューで方針が置き換わった。UTF-8はCIのjob envではなく _harness_python_exec が指定し、CIは非設定のまま検証する。後継: 20260823-235856
