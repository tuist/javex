#!/usr/bin/env bash
set -euo pipefail

# Install the pinned toolchain with mise first, plus clang/libclang for QuickJS.
# Javy is only needed when rebuilding the provider, not for library consumers.
root="$(cd "$(dirname "$0")/../.." && pwd)"
test "$(javy --version)" = "javy 8.1.1" || {
  echo "Rebuilding the provider requires Javy 8.1.1" >&2
  exit 1
}
# Normalize source paths embedded in panic diagnostics as well as the snapshot's
# initialization clocks/RNG. Runtime WASI imports still come from the host.
cargo_home="${CARGO_HOME:-$HOME/.cargo}"
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$root=/javex --remap-path-prefix=$cargo_home=/cargo"
export CFLAGS_wasm32_wasip1="${CFLAGS_wasm32_wasip1:-} -ffile-prefix-map=$root=/javex -ffile-prefix-map=$cargo_home=/cargo"
rustup target add wasm32-wasip1
cargo build --manifest-path "$root/native/javex_plugin/Cargo.toml" \
  --locked --release --target wasm32-wasip1
javy init-plugin --deterministic \
  "$root/native/javex_plugin/target/wasm32-wasip1/release/javex_plugin.wasm" \
  -o "$root/priv/javy_plugin.wasm"
shasum -a 256 "$root/priv/javy_plugin.wasm"
