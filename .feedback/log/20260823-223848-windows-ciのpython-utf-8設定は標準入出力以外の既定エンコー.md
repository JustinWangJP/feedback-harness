---
id: 20260823-223848
date: 2026-08-23
source: hook
category: testing
signal: failure
status: closed
status_changed: 2026-08-23
---

# Windows CIのPython UTF-8設定は標準入出力以外の既定エンコーディングも対象にする

PR #13のWindows CIでPYTHONIOENCODINGによりargparse出力は直ったが、pathlib.read_text・json.load(open(...))・subprocess(text=True)はcp1252のままでUnicodeDecodeErrorが再発した。WindowsジョブではPYTHONUTF8=1も設定し、既定のファイル・subprocessテキストエンコーディングまでUTF-8 modeで統一する。
根因: 実行誤り

---
close理由: 同上。PYTHONUTF8はWindowsジョブのenvではなく _harness_python_exec が command 上で指定する。後継: 20260823-235856
