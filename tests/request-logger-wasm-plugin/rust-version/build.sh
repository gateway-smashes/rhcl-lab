#!/bin/bash
set -e

echo "Building request-logger policy as WASM (Proxy-Wasm)..."

rustup target add wasm32-unknown-unknown

export RUSTC=$(rustup which rustc)
export CARGO_TARGET_DIR=target

cargo build --target wasm32-unknown-unknown --release

echo "Build complete! WASM module is at: target/wasm32-unknown-unknown/release/request_logger.wasm"
