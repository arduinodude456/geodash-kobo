#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/versions.sh"
BUILD="${BUILD:-$ROOT/build}"
AOSP_DIR="${AOSP_DIR:-$BUILD/aosp}"
DIST="${DIST:-$ROOT/dist}"
JOBS="${JOBS:-2}"
[[ "$JOBS" =~ ^[12]$ ]] || { echo 'JOBS must be 1 or 2' >&2; exit 1; }
PRODUCT=kobo_libra_colour
PRODUCT_OUT="$AOSP_DIR/out/target/product/libra_colour"
BUILD_IMAGE=kobo-kitkat-build:local
export ROOT BUILD AOSP_DIR DIST JOBS PRODUCT PRODUCT_OUT BUILD_IMAGE
mkdir -p "$BUILD/logs" "$DIST"
