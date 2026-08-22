#!/usr/bin/env bash
# Rust stack runner. 共通coreはcheck.shから受け取る。

# shellcheck disable=SC2034 # source元のcheck.shがSTACK_FOUND等を集計する
run_rust_checks() {
  if [[ -f Cargo.toml ]]; then
    STACK_FOUND=1
    if ! has cargo; then
      # --list-checks では対象IDごとに記録する(通常実行は1行にまとめたまま)
      if [[ "$LIST_MODE" == "1" ]]; then
        for _id_stage in clippy:lint cargo-check:build cargo-test:test \
                         cargo-metadata:lint cargo-fmt:format cargo-semver-checks:contract; do
          record_skip "${_id_stage%%:*}" "${_id_stage##*:}" "rust: 全ステージ" "cargo 未インストール"
        done
      else
        RESULTS+=("SKIP  rust: 全ステージ (cargo 未インストール)")
      fi
    else
      if cargo clippy --version >/dev/null 2>&1; then
        run_stage lint "clippy" "-" "rust: clippy" cargo clippy --quiet -- -D warnings
      else
        run_stage build "cargo-check" "-" "rust: check" cargo check --quiet
      fi
      run_stage test "cargo-test" "-" "rust: test" cargo test --quiet
      # Cargo.lock と実体の整合(--offline でネットワークを使わない)
      if [[ -f Cargo.lock ]]; then
        run_stage lint "cargo-metadata" "-" "rust: metadata" \
          cargo metadata --offline --format-version 1
      fi
  
      # rustfmt.toml があれば FAIL、無ければ WARN(既定スタイルの押し付けを避ける)
      if [[ -f rustfmt.toml || -f .rustfmt.toml ]]; then
        run_stage format "cargo-fmt" "-" "rust: cargo fmt" cargo fmt --check
      else
        run_stage_soft format "cargo-fmt" "-" "rust: cargo fmt" cargo fmt --check
      fi
    fi
  fi
  
}
