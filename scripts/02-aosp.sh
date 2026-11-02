#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
[[ -f "$AOSP_DIR/build/envsetup.sh" ]] || { echo 'Run 01-source.sh first' >&2; exit 1; }
DEVICE="$AOSP_DIR/device/kobo/libra_colour"
mkdir -p "$DEVICE/native" "$DEVICE/runtime"
cp -a "$ROOT/android/device/kobo/libra_colour/." "$DEVICE/"
cp -a "$ROOT/native/." "$DEVICE/native/"
cp "$ROOT/runtime/kobo-container.c" "$DEVICE/runtime/"
python3 "$ROOT/scripts/patch_aosp.py" "$AOSP_DIR" --record "$BUILD/patches.json"
docker build --build-arg "LEGACY_IMAGE=$LEGACY_IMAGE" -t "$BUILD_IMAGE" -f "$ROOT/android/Dockerfile" "$ROOT/android"
docker image inspect "$BUILD_IMAGE" > "$BUILD/build-container.json"
# Source and output have the same path in every container. Root is unnecessary
# for compilation; the host uid keeps the checkout and build output manageable.
docker run --rm --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e USER=builder -e LOGNAME=builder -e JOBS="$JOBS" \
    -e BUILD_NUMBER="kobo-$AOSP_TAG" -e BUILD_USERNAME=builder -e BUILD_HOSTNAME=legacy-container \
    -e JAVA_TOOL_OPTIONS=-Xmx1536m -e USE_CCACHE=0 \
    -v "$AOSP_DIR:/aosp" -v "$ROOT:/project:ro" "$BUILD_IMAGE" \
    bash /project/scripts/container-build.sh
# These helpers run on Kobo outside the Android chroot: reject dynamic binaries.
for helper in kobo-vnc kobo-container; do
    readelf -h "$PRODUCT_OUT/system/bin/$helper" | grep -q 'Machine:.*ARM'
    if readelf -l "$PRODUCT_OUT/system/bin/$helper" | grep -q INTERP; then
        echo "$helper must be completely static" >&2; exit 1
    fi
done
df -h "$AOSP_DIR" | tee "$BUILD/logs/disk-after-build.log"
