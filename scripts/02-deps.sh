#!/usr/bin/env bash
# Cross-builds the only two libraries Doom needs: zlib and libvncserver.
set -euo pipefail
source "$(dirname "$0")/env.sh"
use_cross
JOBS="$(nproc)"

untar() { # untar <file> <dir>
  rm -rf "$BUILD/$2"; tar -xf "$SRC/$1" -C "$BUILD"
}

# ---------- zlib ----------
fetch "https://zlib.net/fossils/zlib-$ZLIB_VER.tar.gz" "zlib-$ZLIB_VER.tar.gz"
untar "zlib-$ZLIB_VER.tar.gz" "zlib-$ZLIB_VER"
( cd "$BUILD/zlib-$ZLIB_VER" && ./configure --prefix="$DEPS" --static && make -j"$JOBS" && make install )

# ---------- libvncserver (VNC server that carries Doom's picture to KOReader) ----------
fetch "https://github.com/LibVNC/libvncserver/archive/refs/tags/LibVNCServer-$LIBVNC_VER.tar.gz" "libvncserver-$LIBVNC_VER.tar.gz"
untar "libvncserver-$LIBVNC_VER.tar.gz" "libvncserver-LibVNCServer-$LIBVNC_VER"
cat > "$BUILD/toolchain.cmake" <<CMK
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER $TRIPLE-gcc)
set(CMAKE_AR $TRIPLE-ar)
set(CMAKE_RANLIB $TRIPLE-ranlib)
set(CMAKE_FIND_ROOT_PATH $DEPS $SYSROOT)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
CMK
cmake -S "$BUILD/libvncserver-LibVNCServer-$LIBVNC_VER" -B "$BUILD/libvnc-build" \
  -DCMAKE_TOOLCHAIN_FILE="$BUILD/toolchain.cmake" -DCMAKE_INSTALL_PREFIX="$DEPS" \
  -DCMAKE_PREFIX_PATH="$DEPS" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF -DWITH_SYSTEMD=OFF -DWITH_GCRYPT=OFF \
  -DWITH_GNUTLS=OFF -DWITH_OPENSSL=OFF -DWITH_JPEG=OFF -DWITH_PNG=OFF -DWITH_LZO=OFF \
  -DWITH_SASL=OFF -DWITH_WEBSOCKETS=OFF -DWITH_IPv6=OFF -DWITH_TIGHTVNC_FILETRANSFER=OFF \
  -DWITH_THREADS=ON -DWITH_ZLIB=ON
cmake --build "$BUILD/libvnc-build" -j"$JOBS"
cmake --install "$BUILD/libvnc-build"

# ---------- libcurl (TIC-80's CMake insists on finding it; no TLS, HTTP only, static, PIC) ----------
fetch "https://github.com/curl/curl/releases/download/curl-${CURL_VER//./_}/curl-$CURL_VER.tar.gz" "curl-$CURL_VER.tar.gz"
untar "curl-$CURL_VER.tar.gz" "curl-$CURL_VER"
rm -rf "$BUILD/curl-build"
cmake -S "$BUILD/curl-$CURL_VER" -B "$BUILD/curl-build" \
  -DCMAKE_TOOLCHAIN_FILE="$BUILD/toolchain.cmake" -DCMAKE_INSTALL_PREFIX="$DEPS" \
  -DCMAKE_PREFIX_PATH="$DEPS" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DHTTP_ONLY=ON \
  -DCURL_ENABLE_SSL=OFF -DCURL_USE_OPENSSL=OFF -DCMAKE_USE_OPENSSL=OFF \
  -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBSSH=OFF -DCMAKE_USE_LIBSSH2=OFF \
  -DUSE_LIBIDN2=OFF -DUSE_NGHTTP2=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DCURL_ZLIB=OFF \
  -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON -DENABLE_CURL_MANUAL=OFF -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF
cmake --build "$BUILD/curl-build" -j"$JOBS"
cmake --install "$BUILD/curl-build"
[ -f "$DEPS/lib/libcurl.a" ] || { echo "libcurl.a missing after install"; exit 1; }

echo "== deps ok =="; ls "$DEPS/lib"; ls "$DEPS/include/rfb" | head -5
