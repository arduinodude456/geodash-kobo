# Sourced by all build scripts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
export TRIPLE=arm-kobo-linux-gnueabihf
export TC_ROOT="$HOME/x-tools/$TRIPLE"
export SYSROOT="$TC_ROOT/$TRIPLE/sysroot"
export PATH="$TC_ROOT/bin:$PATH"

export SRC="$ROOT/cache/src"      # downloaded tarballs
export BUILD="$ROOT/build"        # build dirs + logs
export DEPS="$ROOT/deps"          # target (ARM) install prefix
mkdir -p "$SRC" "$BUILD" "$DEPS"

# Install location on the device (the Lua side expects the same path).
export DEVICE_DIR=/mnt/onboard/.adds/geodash

# shellcheck disable=SC1091
source "$ROOT/scripts/versions.sh"

use_cross() {
  export CC="$TRIPLE-gcc" CXX="$TRIPLE-g++" AR="$TRIPLE-ar" RANLIB="$TRIPLE-ranlib"
  export STRIP="$TRIPLE-strip" LD="$TRIPLE-ld" NM="$TRIPLE-nm"
  export CFLAGS="-O2 -pipe -fPIC -I$DEPS/include"
  export CPPFLAGS="-I$DEPS/include"
  export LDFLAGS="-L$DEPS/lib"
  export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
  export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"
  export PKG_CONFIG="pkg-config --static"
}
use_host() {
  unset CC CXX AR RANLIB STRIP LD NM CFLAGS CPPFLAGS LDFLAGS PKG_CONFIG_LIBDIR PKG_CONFIG_PATH PKG_CONFIG
}
fetch() { # fetch <url> <file>
  [ -s "$SRC/$2" ] || curl -fL --retry 3 -o "$SRC/$2" "$1"
}
