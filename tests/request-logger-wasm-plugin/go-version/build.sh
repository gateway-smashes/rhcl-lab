#!/bin/bash
set -e

echo "Building request-logger policy as WASM (Proxy-Wasm Go, wasip1)..."

GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o request_logger.wasm .

echo "Build complete! WASM module is at: request_logger.wasm"
