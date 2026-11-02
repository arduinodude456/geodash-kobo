#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
python3 "$ROOT/scripts/package.py" --root "$ROOT" --build "$BUILD" \
    --product-out "$PRODUCT_OUT" --dist "$DIST"
ls -lh "$DIST/android-kobo.zip" "$DIST/android-kobo.zip.sha256" \
    "$DIST/kobo-android-kitkat.tar.gz" "$DIST/kobo-android-kitkat.tar.gz.sha256"
