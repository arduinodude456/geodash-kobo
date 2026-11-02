#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$AOSP_DIR" "$BUILD/tools"
# Pin the launcher itself as well as repo's self-managed implementation.
if [[ ! -d "$BUILD/tools/git-repo/.git" ]]; then
    git init "$BUILD/tools/git-repo"
    git -C "$BUILD/tools/git-repo" remote add origin "$REPO_URL"
fi
git -C "$BUILD/tools/git-repo" fetch --depth=1 origin "$REPO_REV"
git -C "$BUILD/tools/git-repo" checkout --detach "$REPO_REV"
REPO="$BUILD/tools/git-repo/repo"
export REPO_ALLOW_SHALLOW=1
cd "$AOSP_DIR"
python3 "$REPO" init --no-clone-bundle --depth=1 \
    --repo-url="$REPO_URL" --repo-rev="$REPO_REV" \
    -u "$AOSP_MANIFEST_URL" -b "refs/tags/$AOSP_TAG"
# Fetch the pinned release only, not every project's history and branches.
python3 "$REPO" sync -c --no-clone-bundle --no-tags --fail-fast -j"$JOBS"
python3 "$REPO" manifest -r -o "$BUILD/source-manifest.xml"
printf '%s\n' "$AOSP_TAG" > "$BUILD/AOSP-RELEASE.txt"
printf '%s\n' "$REPO_REV" > "$BUILD/REPO-REVISION.txt"
df -h "$AOSP_DIR" | tee "$BUILD/logs/disk-after-sync.log"
