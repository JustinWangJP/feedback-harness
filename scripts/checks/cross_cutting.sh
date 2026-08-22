#!/usr/bin/env bash
# Stack非依存・contract・fallback runner。共通coreはcheck.shから受け取る。

# shellcheck disable=SC2034 # source元のcheck.shがSTACK_FOUNDを集計する
run_cross_cutting_checks() {
  # ---------- 横断チェック(スタック非依存) ----------
  # check_file.sh が JSON/YAML を検証できるのに check.sh 側に対応が無いと、
  # Bash 経由・外部エディタで壊された設定ファイルが完了前チェックをすり抜ける
  # (Shell ステージを追加したときと同じ非対称性)。
  # STACK_FOUND は立てない — 設定ファイルの存在は「スタックの検出」ではない。
  JSON_FILES=()
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] && JSON_FILES+=("$f")
  done < <(list_files '*.json')
  if [[ ${#JSON_FILES[@]} -gt 0 ]]; then
    run_stage lint "json-syntax" "-" "config: json 構文" harness_validate_json "${JSON_FILES[@]}"
  fi

  YAML_FILES=()
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] && YAML_FILES+=("$f")
  done < <(list_files '*.yaml')
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] && YAML_FILES+=("$f")
  done < <(list_files '*.yml')
  if [[ ${#YAML_FILES[@]} -gt 0 ]]; then
    if harness_has_pyyaml; then
      run_stage lint "yaml-syntax" "-" "config: yaml 構文" harness_validate_yaml "${YAML_FILES[@]}"
    else
      record_skip "yaml-syntax" lint "config: yaml 構文" "PyYAML 未インストール"
    fi
  fi

  # ドキュメントの内部リンク。外部URLは検証しない(ネットワークを使わない原則)。
  # リンク先が実在しないのは好みの問題ではなく事実誤りなので、常に FAIL とする
  MD_FILES=()
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] && MD_FILES+=("$f")
  done < <(list_files '*.md')
  if [[ ${#MD_FILES[@]} -gt 0 ]]; then
    run_stage docs "md-links" "-" "docs: 内部リンク" harness_check_md_links "${MD_FILES[@]}"
  fi

  # 検査対象を何か検出できたか。ここまでの全ステージの結果を見て判断する。
  # 何も検出できていないディレクトリに「設定すれば有効になる」と案内しても
  # 相手がいない上に、案内行が残ることで「スタック未検出」の報告を潰してしまう
  anything_detected() { [[ $STACK_FOUND -eq 1 || ${#RESULTS[@]} -gt 0 ]]; }

  # 秘密情報スキャン。secretlint は .secretlintrc.* が無いと exit 2 で実行できない
  # (実測)ため、設定の有無をゲートにする。設定を書いた=チームが検査を選んだ、
  # という宣言なので FAIL でよい。マスクは既定で有効 — 無効化する引数は渡さない
  # (失敗ログはエージェントのコンテキストに入るため、秘密の値を拡散させない)
  if ls .secretlintrc.* >/dev/null 2>&1; then
    # npx は「未インストール」も「秘密を検出」も exit 1 を返すので区別できない。
    # tsc と同じく --version で事前プローブし、未導入を誤FAILにしない
    if has npx && npx --no-install secretlint --version >/dev/null 2>&1; then
      run_stage security "secretlint" "-" "security: secretlint" npx --no-install secretlint "**/*"
    else
      record_skip "secretlint" security "security: secretlint" "secretlint 未インストール"
    fi
  elif anything_detected; then
    record_skip "secretlint" security "security: secretlint" ".secretlintrc.* が無い — 設定すると検査が有効になります"
  fi

  # gitleaks があれば併用する(OS固有バイナリのため任意扱い)。バージョン差が
  # 大きく v8.19 で detect が再編されたため、必要なフラグがヘルプに出ることを
  # 確認してから使う。--redact は省略不可(秘密の値を出力に出さない)。
  # PATH にあることはプロジェクトの宣言ではないので、検出対象があるときだけ走らせる
  if anything_detected && has gitleaks; then
    GL_HELP="$(gitleaks detect --help 2>&1)"
    if [[ "$GL_HELP" == *"--no-git"* && "$GL_HELP" == *"--redact"* ]]; then
      run_stage security "gitleaks" "-" "security: gitleaks" \
        gitleaks detect --no-git --redact --no-banner -s .
    else
      record_skip "gitleaks" security "security: gitleaks" "この版は detect --no-git/--redact に非対応"
    fi
  fi

  # GitHub Actions のワークフロー。YAML構文は上で検証済みなので、ここで見るのは
  # アクションの使い方(存在しない入力・シェルの誤り等)。actionlint は Go 製
  # バイナリのため任意扱い(あれば使う)
  if compgen -G ".github/workflows/*.y*ml" >/dev/null 2>&1; then
    if has actionlint; then
      run_stage lint "actionlint" "-" "ci: actionlint" actionlint
    else
      record_skip "actionlint" lint "ci: actionlint" "actionlint 未インストール"
    fi
  fi

  # Dockerfile。git pathspec の * は / を跨ぐため 'Dockerfile*' 単独では
  # ルート直下しか当たらない(*.py が全階層に当たるのとは非対称)
  DOCKER_FILES=()
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] && DOCKER_FILES+=("$f")
  done < <(list_files 'Dockerfile*'; list_files '*/Dockerfile*')
  # 上の2つのグロブは Dockerfile がリポジトリ直下にある場合に重複しない
  # (git pathspec の 'Dockerfile*' はルート直下のみ、'*/Dockerfile*' は1階層以上)。
  # 念のため防御的な重複排除を入れる(現状の経路では重複は生じない)
  if [[ ${#DOCKER_FILES[@]} -gt 1 ]]; then
    IFS=$'\n' read -r -d '' -a DOCKER_FILES < <(printf '%s\n' "${DOCKER_FILES[@]}" | sort -u && printf '\0')
  fi
  if [[ ${#DOCKER_FILES[@]} -gt 0 ]]; then
    if has npx && npx --no-install dockerfilelint --version >/dev/null 2>&1; then
      # dockerfilelint は問題があると exit 2 を返す(実測)。run_stage は非0を
      # FAIL とするため、そのまま扱える
      run_stage lint "dockerfilelint" "-" "docker: dockerfilelint" \
        npx --no-install dockerfilelint "${DOCKER_FILES[@]}"
    elif has hadolint; then
      run_stage lint "hadolint" "-" "docker: hadolint" hadolint "${DOCKER_FILES[@]}"
    else
      if [[ "$LIST_MODE" == "1" ]]; then
        record_skip "dockerfilelint" lint "docker: lint" "dockerfilelint / hadolint 未インストール"
        record_skip "hadolint" lint "docker: lint" "dockerfilelint / hadolint 未インストール"
      else
        RESULTS+=("SKIP  docker: lint (dockerfilelint / hadolint 未インストール)")
      fi
    fi
  fi

  # ---------- API契約・破壊的変更 ----------
  # ベースラインは git から取る(ネットワーク不要・自己完結)。merge-base が
  # 解決できなければ HEAD(=未コミット変更のみ)と比較する。spec ファイルの
  # 検出は for+[[ -f ]] で行う(ls の複数引数は1つでも欠けると全体が非0になる)
  OPENAPI_SPEC=""
  for f in openapi.yaml openapi.json api/openapi.yaml api/openapi.json; do
    if [[ -f "$f" ]]; then
      OPENAPI_SPEC="$f"
      break
    fi
  done
  if [[ -n "$OPENAPI_SPEC" ]] && has oasdiff; then
    BASE_SHA="$(git merge-base HEAD "$HARNESS_OASDIFF_BASE" 2>/dev/null \
      || git rev-parse HEAD 2>/dev/null)"
    TMP_BASE="$(mktemp)"
    if [[ -n "$BASE_SHA" ]] && git show "$BASE_SHA:$OPENAPI_SPEC" > "$TMP_BASE" 2>/dev/null; then
      run_stage contract "oasdiff" "-" "contract: oasdiff" oasdiff breaking "$TMP_BASE" "$OPENAPI_SPEC"
    else
      record_skip "oasdiff" contract "contract: oasdiff" "ベースライン取得不能 — $OPENAPI_SPEC がベースラインに無い"
    fi
    rm -f "$TMP_BASE"
  elif [[ -n "$OPENAPI_SPEC" ]]; then
    record_skip "oasdiff" contract "contract: oasdiff" "oasdiff 未インストール"
  fi

  # Rust ライブラリの破壊的変更。cargo-semver-checks の導入自体が宣言
  # (ビルドを伴い重いため、入れたプロジェクトだけがコストを払う)。
  # --baseline-rev を指定しない既定動作は crates.io レジストリから公開済みの
  # ベースラインを取得しにいく — check.sh の「ネットワーク不使用」原則(oasdiff
  # 等で繰り返し明記)に反するため、oasdiff と同じく git 由来のベースラインへ
  # 差し替える(merge-base が解決できなければベースライン無しとして SKIP)
  if [[ -f Cargo.toml ]] && has cargo \
     && cargo semver-checks --version >/dev/null 2>&1 \
     && grep -q "^\[lib\]" Cargo.toml; then
    RUST_BASE_SHA="$(git merge-base HEAD "$HARNESS_OASDIFF_BASE" 2>/dev/null \
      || git rev-parse HEAD 2>/dev/null)"
    if [[ -n "$RUST_BASE_SHA" ]]; then
      run_stage contract "cargo-semver-checks" "-" "contract: cargo semver-checks" \
        cargo semver-checks check-release --baseline-rev "$RUST_BASE_SHA"
    else
      record_skip "cargo-semver-checks" contract "contract: cargo semver-checks" \
        "ベースライン取得不能(git merge-base 解決不可)"
    fi
  fi

  # ---------- 汎用フォールバック ----------
  # 再帰ガード: make check のテストが check.sh を呼び返す循環を断つ。フック実行時は
  # CLAUDE_PROJECT_DIR が子孫まで伝播し、テスト内の check.sh がルートを本リポジトリに
  # 解決し直して make check がテストを再実行する — この無限再帰で Stop フックの
  # timeout を食い潰していた。ガードが拾うのは make フォールバックだけ。直接ステージ
  # (lint/test/build)はこの経路を通らないため必ず実行され、検証を抜けたまま完了しない。
  if [[ -f Makefile ]] && grep -qE "^check:" Makefile; then
    STACK_FOUND=1
    if [[ -n "${FEEDBACK_CHECK_RECURSION_GUARD:-}" ]]; then
      record_skip "make-check" test "make check" "再帰ガード — check.sh 起因のmake実行内のため"
    else
      # env 経由で make とその子孫にだけ伝える。check.sh 全体へ export すると
      # 直接ステージの子孫(テスト内で別プロジェクトを検証する等)まで誤スキップする
      run_stage test "make-check" "make" "make check" env FEEDBACK_CHECK_RECURSION_GUARD=1 make check
    fi
  fi

  if [[ "$LIST_MODE" == "1" ]]; then
    if [[ "$LIST_JSON" == "1" ]]; then
      python3 -c '
import json, sys
rows = []
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) == 5:
        rows.append(dict(zip(["id", "label", "stage", "severity", "source"], parts)))
print(json.dumps(rows, ensure_ascii=False, indent=2))
  ' < "$LOGDIR/list.txt"
    else
      python3 "$LIBDIR/harness_config.py" --format-table < "$LOGDIR/list.txt"
    fi
    # config が壊れていると一覧は「すべて既定」を並べる。これは事実だが、
    # 打ち間違いを調べようと --list-checks を叩いた利用者には最も知りたい情報が
    # 見えないまま「既定」とだけ映り、原因に辿り着けない。stdout ではなく stderr へ
    # 出すのは --json の出力をパイプで処理する経路を壊さないため
    if [[ -n "${HARNESS_CONFIG_ERROR:-}" ]]; then
      echo "" >&2
      echo "ERROR: .feedback/config.yaml を読めませんでした。以下はすべて既定値です。" >&2
      echo "$HARNESS_CONFIG_ERROR" >&2
      exit 1
    fi
    exit 0
  fi

}
