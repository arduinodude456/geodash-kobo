#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
{
    date -u
    uname -a
    df -h "$BUILD"
    free -h
    docker version
    python3 --version
    git --version
} | tee "$BUILD/logs/preflight.log"
# Refuse to start a many-hour sync that the runner cannot finish. This is a
# minimum before sync, not a guarantee that all hosted runners are sufficient.
AVAILABLE="$(df -B1 --output=avail "$BUILD" | tail -1 | tr -d ' ')"
MINIMUM=$((60 * 1024 * 1024 * 1024))
if (( AVAILABLE < MINIMUM )); then
    echo "At least 60 GiB free required before sync; found $AVAILABLE bytes. Use a larger ephemeral runner." | tee -a "$BUILD/logs/preflight.log" >&2
    exit 1
fi
