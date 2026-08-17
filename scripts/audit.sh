#!/usr/bin/env bash
# audit.sh — オンデマンド脆弱性監査。check.sh と異なり**ネットワークを使う**ため、
# Stop フックからは呼ばれない(feedback-loop スキル等からの明示実行専用)。
#
# 使い方: scripts/audit.sh [プロジェクトルート]
# exit 0 = 脆弱性なし(または全SKIP) / 1 = 脆弱性あり
# 成功時のみ .feedback/.last-audit に ISO 日付を書く(stats/report が表示する)。
# 失敗時にスタンプを書かない = 監査が赤い間は「監査を推奨」表示が消えず、
# 修正を促し続ける。
#
# 設計は check.sh と同じ契約に合わせる: ツール不在は SKIP(環境の問題を
# ユーザーのコードの失敗として報告しない)、出力は PASS/FAIL/SKIP の要約。
set -u

LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$LIBDIR/lib.sh"

ROOT="$(harness_project_root "${1:-}")" \
  || { echo "ERROR: ディレクトリが見つかりません: ${1:-}"; exit 2; }
cd "$ROOT" || { echo "ERROR: ディレクトリへ移動できません: $ROOT"; exit 2; }

RESULTS=()
FAILED=0
PASSED=0

run_audit() { # run_audit <ツール> <ラベル> <cmd...>
  local tool="$1" label="$2"; shift 2
  if ! has "$tool"; then
    RESULTS+=("SKIP  $label ($tool 未インストール)")
    return
  fi
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    PASSED=$((PASSED + 1))
    RESULTS+=("PASS  $label")
  else
    FAILED=1
    RESULTS+=("FAIL  $label")
    echo "----- FAIL: $label ($*) -----"
    # 監査出力は長いので末尾20行に絞る(check.sh の末尾40行より短く:
    # 対応表形式の出力が多く、対象の把握には十分なため)
    printf '%s\n' "$out" | tail -n 20
  fi
}

# ---------- Python ----------
if [[ -f pyproject.toml || -f requirements.txt || -f requirements-dev.txt \
      || -f poetry.lock || -f uv.lock ]]; then
  run_audit "pip-audit" "python: pip-audit" pip-audit
fi

# ---------- Node ----------
# lockfile が無いと npm audit は依存解決からやり直す(ネットワーク+時間)。
# lockfile の存在 = 監査可能な状態が固定されている、という前提を置く
if [[ -f package-lock.json || -f pnpm-lock.yaml || -f yarn.lock ]]; then
  run_audit "npm" "node: npm audit" npm audit --audit-level=high
fi

# ---------- Go ----------
if [[ -f go.sum ]]; then
  run_audit "govulncheck" "go: govulncheck" govulncheck ./...
fi

# ---------- Rust ----------
if [[ -f Cargo.lock ]]; then
  # cargo audit は cargo 内蔵ではなく cargo-audit クレート由来。cargo だけある
  # 環境で `cargo audit` は exit 101 になるため、probe は cargo-audit バイナリに対して行う
  # (cargo-audit 導入時に PATH に置かれる)
  run_audit "cargo-audit" "rust: cargo audit" cargo audit
fi

echo "=== feedback-harness audit ==="
if [[ ${#RESULTS[@]} -gt 0 ]]; then
  printf '%s\n' "${RESULTS[@]}"
fi
if [[ $FAILED -eq 1 ]]; then
  echo "脆弱性が検出されました。修正してから再実行すること。"
  # spec §3.2: 監査の失敗はフィードバックループに載せる(失敗シグナル)。
  # Stop フックの HINT と同じ形で、記録を促すのみ(自動記録はしない)
  echo "HINT: 修正後、python3 \"$LIBDIR/feedback_log.py\" add --source hook --category security での記録を検討すること"
  exit 1
fi
if [[ $PASSED -eq 0 ]]; then
  echo "監査対象が見つかりません(依存マニフェスト/lockfile が無い、またはツール未導入)"
  exit 0
fi
mkdir -p "$ROOT/.feedback" 2>/dev/null \
  && date +%F > "$ROOT/.feedback/.last-audit" 2>/dev/null
echo "ALL PASS (監査OK — .feedback/.last-audit を更新)"
exit 0
