#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SAYSTUFF_BUILD_DIR:-$ROOT_DIR/.derivedData-dev}"
PRODUCTS="$BUILD_DIR/Build/Products/Release"
CHECKOUT="$BUILD_DIR/SourcePackages/checkouts/FluidAudio"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/saystuff-parakeet-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
  "$ROOT_DIR/tests/ParakeetLifecycleSmoke.swift" \
  "$ROOT_DIR/SayStuff/Services/ParakeetService.swift" \
  -o "$TEST_DIR/lifecycle" -module-cache-path "$TEST_DIR/modules" \
  -I "$PRODUCTS" -I "$PRODUCTS/include" \
  -I "$CHECKOUT/Sources/FastClusterWrapper/include" \
  -I "$CHECKOUT/Sources/MachTaskSelfWrapper/include" \
  "$PRODUCTS/FluidAudio.o" "$PRODUCTS/FastClusterWrapper.o" \
  "$PRODUCTS/MachTaskSelfWrapper.o" "$PRODUCTS/libtext_processing_rs.a" \
  -lc++ -framework Accelerate -framework CoreML -framework AVFoundation
"$TEST_DIR/lifecycle"
