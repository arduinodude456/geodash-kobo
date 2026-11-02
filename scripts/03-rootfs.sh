#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
STAGE="$BUILD/rootfs-stage"
sudo python3 "$ROOT/scripts/rootfs.py" prepare --product "$PRODUCT_OUT" --stage "$STAGE"
# Output belongs to the invoking CI user; only reading the stage needs root.
# shellcheck disable=SC2024
sudo python3 "$ROOT/scripts/rootfs.py" list --stage "$STAGE" > "$BUILD/rootfs-files.txt"
# The old fs_config binary and its libraries execute inside their old-glibc
# build environment, not on the modern host. -C includes Linux capabilities.
docker run --rm -i --user "$(id -u):$(id -g)" -v "$AOSP_DIR:/aosp:ro" \
    "$BUILD_IMAGE" /aosp/out/host/linux-x86/bin/fs_config -C \
    < "$BUILD/rootfs-files.txt" > "$BUILD/rootfs-fs-config.txt"
sudo python3 "$ROOT/scripts/rootfs.py" apply-config --stage "$STAGE" --config "$BUILD/rootfs-fs-config.txt"
sudo python3 "$ROOT/scripts/rootfs.py" image --stage "$STAGE" \
    --output "$BUILD/rootfs.img" --size-mib "${ROOTFS_SIZE_MIB:-768}"
# gzip -n omits timestamps; a sparse ext4 file compresses to its populated data.
gzip -n -1 -c "$BUILD/rootfs.img" > "$BUILD/rootfs.img.gz"
stat -c '%s' "$BUILD/rootfs.img" > "$BUILD/rootfs.size"
(cd "$BUILD" && sha256sum rootfs.img.gz > rootfs.img.gz.sha256)
sudo dumpe2fs -h "$BUILD/rootfs.img" 2>&1 | tee "$BUILD/logs/rootfs-ext4.log"
