#!/usr/bin/env bash
# Go stack runner. 共通coreはcheck.shから受け取る。

# shellcheck disable=SC2034 # source元のcheck.shがSTACK_FOUND等を集計する
run_go_checks() {
  if [[ -f go.mod ]]; then
    STACK_FOUND=1
    run_stage lint "go-vet" "go" "go: vet" go vet ./...
    run_stage build "go-build" "go" "go: build" go build ./...
    # -cover は標準機能で計装のみ(追加プロセス無し)。coverage の数値は
    # ステージログに現れる。閾値ゲートは持たない(go test のexitはテスト合否のみ)
    run_stage test "go-test" "go" "go: test" go test -cover ./...
    # go.sum のチェックサム検証(ネットワーク不使用)。依存の改竄・欠損を検出する
    if [[ -f go.sum ]]; then
      run_stage lint "go-mod-verify" "go" "go: mod verify" go mod verify
    fi

    # gofmt は言語標準であり「宣言しないと従わない」性質のものではないため、
    # 宣言ゲートを設けず常に FAIL とする(Goコミュニティの普遍的合意)
    GO_FILES=()
    while IFS= read -r f; do
      [[ -n "$f" && -f "$f" ]] && GO_FILES+=("$f")
    done < <(list_files '*.go')
    if [[ ${#GO_FILES[@]} -gt 0 ]] && has gofmt; then
      # gofmt -l は未整形ファイル名を「出力する」形式で、終了コードは 0 のまま。
      # 出力があれば未整形なので、非0に変換して run_stage に伝える
      run_stage format "gofmt" "-" "go: gofmt" \
        bash -c 'out="$(gofmt -l "$@")"; [[ -z "$out" ]] || { echo "未フォーマット:"; echo "$out"; exit 1; }' _ "${GO_FILES[@]}"
    fi
  fi

}
