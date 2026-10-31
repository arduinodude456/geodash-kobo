#!/usr/bin/env bash
# Builds the TIC-80 libretro core and our VNC front-end (geodash/gd_shim.cpp + geodash/gd_vnc.c).
#
#   scripts/03-geodash.sh            cross-build for the Kobo (needs 01 + 02 first)
#   NATIVE=1 scripts/03-geodash.sh   build for this machine (needs libvncserver-dev + cmake)
#
# TIC-80 itself is not modified. We build only its libretro core (no SDL, no player) and talk to it
# through the libretro API.
set -euo pipefail
source "$(dirname "$0")/env.sh"
JOBS="$(nproc)"
VNC_PORT=5963   # keep in sync with lua/appdock_geodash.lua
OUT="$BUILD/geodash"; mkdir -p "$OUT"

# ---- sources -----------------------------------------------------------------
T80="$BUILD/TIC-80"
if [ ! -d "$T80/.git" ]; then
  if ! git clone -q --depth 1 --branch "$TIC80_REF" "$TIC80_REPO" "$T80" 2>/dev/null; then
    echo "TIC-80 tag $TIC80_REF not found - using the default branch"
    rm -rf "$T80"
    git clone -q --depth 1 "$TIC80_REPO" "$T80"
  fi
  if [ -n "$TIC80_REV" ]; then
    git -C "$T80" fetch -q --depth 1 origin "$TIC80_REV"
    git -C "$T80" checkout -q "$TIC80_REV"
  fi
  git -C "$T80" submodule update -q --init --recursive --depth 1 \
    || git -C "$T80" submodule update -q --init --recursive
fi
echo "TIC-80 revision: $(git -C "$T80" rev-parse HEAD)"

# ---- toolchain ---------------------------------------------------------------
if [ "${NATIVE:-0}" = 1 ]; then
  CC=gcc; CXX=g++; PREFIX=""; TCFILE=""
  VNC_INC=""; VNC_LIB=""
else
  use_cross
  CC="$TRIPLE-gcc"; CXX="$TRIPLE-g++"; PREFIX="$DEPS"
  [ -f "$DEPS/include/rfb/rfb.h" ] || { echo "libvncserver missing - run scripts/02-deps.sh"; exit 1; }
  VNC_INC="-I$DEPS/include"; VNC_LIB="-L$DEPS/lib"
  TCFILE="$BUILD/geodash-toolchain.cmake"
  cat > "$TCFILE" <<CMK
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER $TRIPLE-gcc)
set(CMAKE_CXX_COMPILER $TRIPLE-g++)
set(CMAKE_AR $TRIPLE-ar)
set(CMAKE_RANLIB $TRIPLE-ranlib)
set(CMAKE_FIND_ROOT_PATH $DEPS $SYSROOT)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
CMK
fi

# ---- TIC-80 libretro core ------------------------------------------------------
TB="$BUILD/tic80-build"
# Base options taken from a known-good cross build of this very tag (imsys' Makefile for TrimUI aarch64):
# __LIBRETRO__ + BUILD_STATIC avoid the hard CURL dependency that stopped the first attempt.
BASE=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DBUILD_LIBRETRO=ON -D__LIBRETRO__=ON -DBUILD_PLAYER=OFF -DBUILD_PRO=OFF -DBUILD_SOKOL=OFF
  -DBUILD_TOOLS=OFF -DBUILD_TOUCH_INPUT=OFF -DBUILD_STATIC=ON -DBUILD_DEMO_CARTS=OFF)
# GCC >= 14 / C17: static_assert is only a macro from <assert.h>, which TIC-80's C sources never include
# ("expected declaration specifiers ... before 'sizeof'"). Pre-include it for all C files, and pin gnu11.
BASE+=("-DCMAKE_C_FLAGS=-std=gnu11 -include assert.h" -DCMAKE_C_STANDARD=11)
[ -z "$TCFILE" ] || BASE+=(-DCMAKE_TOOLCHAIN_FILE="$TCFILE")

lang_opts() { # lang_opts <languages...>   (later -D wins, so: everything off, then the wanted ones on)
  local l
  for l in LUA MOON FENNEL WREN SQUIRREL JS SCHEME JANET WASM RUBY MRUBY PYTHON; do printf -- '-DBUILD_WITH_%s=OFF\n' "$l"; done
  for l in "$@"; do printf -- '-DBUILD_WITH_%s=ON\n' "$(echo "$l" | tr a-z A-Z)"; done
}
try_configure() { # try_configure <description> <extra cmake options...>
  local what="$1"; shift
  rm -rf "$TB"
  echo "== configuring TIC-80 libretro core: $what"
  cmake -S "$T80" -B "$TB" "${BASE[@]}" "$@"
}
mapfile -t LOPTS < <(lang_opts $TIC80_LANGS)
mapfile -t LUAONLY < <(lang_opts lua)

ok=0
if   try_configure "no SDL, languages: $TIC80_LANGS" -DBUILD_SDL=OFF -DBUILD_WITH_ALL=OFF "${LOPTS[@]}"; then ok=1
elif try_configure "SDL on, languages: $TIC80_LANGS" -DBUILD_WITH_ALL=OFF "${LOPTS[@]}"; then ok=1
elif try_configure "SDL on, Lua only" -DBUILD_WITH_ALL=OFF "${LUAONLY[@]}"; then ok=1
elif try_configure "all languages (exactly as in the known-good recipe)" -DBUILD_WITH_ALL=ON; then ok=1
fi
[ "$ok" = 1 ] || { echo "TIC-80: cmake configure failed"; exit 1; }
cmake --build "$TB" --target tic80_libretro -j"$JOBS" || cmake --build "$TB" -j"$JOBS"

# Find what the build produced: normally lib/tic80_libretro.so.
mapfile -t FOUND_SO < <(find "$TB" \( -name 'tic80_libretro*.so' -o -name 'libtic80_libretro*.so' \))
CORE_SO="${FOUND_SO[0]:-}"
STATIC_CORE=0
if [ -n "$CORE_SO" ]; then
  cp -L "$CORE_SO" "$OUT/tic80_libretro.so"
  echo "core: $CORE_SO"
else
  echo "no tic80_libretro .so found - looking for static libraries"
  mapfile -t ALIBS < <(find "$TB" -name '*.a' -not -path '*/CMakeFiles/*')
  [ "${#ALIBS[@]}" -gt 0 ] || { echo "TIC-80: no core library produced"; find "$TB" -maxdepth 3 | head -50; exit 1; }
  STATIC_CORE=1
  printf '%s\n' "${ALIBS[@]}"
fi

# ---- front-end ---------------------------------------------------------------
OBJ="$OUT/obj"; rm -rf "$OBJ"; mkdir -p "$OBJ"
CXXFLAGS_ALL="-std=c++17 -O2 -pipe -w -ffunction-sections -fdata-sections -DGD_VNC_PORT=$VNC_PORT"
[ "$STATIC_CORE" = 0 ] || CXXFLAGS_ALL="$CXXFLAGS_ALL -DGD_STATIC_CORE"
$CXX $CXXFLAGS_ALL -c "$ROOT/geodash/gd_shim.cpp" -o "$OBJ/gd_shim.o"
$CC -O2 -pipe -w -ffunction-sections -fdata-sections $VNC_INC -c "$ROOT/geodash/gd_vnc.c" -o "$OBJ/gd_vnc.o"

CORE_LIBS=()
[ "$STATIC_CORE" = 0 ] || CORE_LIBS=(-Wl,--start-group "${ALIBS[@]}" -Wl,--end-group)
# libstdc++/libgcc static: the toolchain's copies do not exist on the e-reader.
$CXX -O2 -static-libstdc++ -static-libgcc -Wl,--gc-sections "$OBJ"/gd_shim.o "$OBJ"/gd_vnc.o -o "$OUT/geodash" \
  "${CORE_LIBS[@]}" $VNC_LIB -Wl,--start-group -lvncserver -lz -lpthread -lrt -lm -ldl -Wl,--end-group
[ -x "$OUT/geodash" ] || { echo "link failed"; exit 1; }
ls -l "$OUT/geodash" "$OUT"/tic80_libretro.so 2>/dev/null || true
echo "== tic80 ok =="
