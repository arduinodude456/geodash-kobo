#!/usr/bin/env bash
# Builds raylib 6.0 (software renderer, PLATFORM_MEMORY), GeometryRush and our VNC shim.
#
#   scripts/03-geodash.sh            cross-build for the Kobo (needs 01 + 02 first)
#   NATIVE=1 scripts/03-geodash.sh   build for this machine (needs libvncserver-dev + cmake)
#
# The game's own code is NOT modified. Its window/input calls are redirected to
# doom-style VNC glue with the linker's --wrap option (see geodash/gd_shim.cpp).
set -euo pipefail
source "$(dirname "$0")/env.sh"
JOBS="$(nproc)"
VNC_PORT=5963   # keep in sync with lua/appdock_geodash.lua
OUT="$BUILD/geodash"; mkdir -p "$OUT"

# ---- sources -----------------------------------------------------------------
RL="$BUILD/raylib"
if [ ! -d "$RL/.git" ]; then
  git clone -q --depth 1 --branch "$RAYLIB_VER" https://github.com/raysan5/raylib "$RL"
fi
GR="$BUILD/GeometryRush"
if [ ! -d "$GR/.git" ]; then
  git clone -q --branch "$GEOMRUSH_BRANCH" "$GEOMRUSH_REPO" "$GR"
  [ -z "$GEOMRUSH_REV" ] || git -C "$GR" checkout -q "$GEOMRUSH_REV"
fi
echo "GeometryRush revision: $(git -C "$GR" rev-parse HEAD)"
[ -f "$GR/src/main.cpp" ] || { echo "GeometryRush layout changed (src/main.cpp missing)"; exit 1; }

# ---- toolchain ---------------------------------------------------------------
if [ "${NATIVE:-0}" = 1 ]; then
  CC=gcc; CXX=g++; PREFIX="$BUILD/native-prefix"; mkdir -p "$PREFIX"
  TCFILE=""
else
  use_cross
  CC="$TRIPLE-gcc"; CXX="$TRIPLE-g++"; PREFIX="$DEPS"
  [ -f "$DEPS/include/rfb/rfb.h" ] || { echo "libvncserver missing - run scripts/02-deps.sh"; exit 1; }
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

# ---- raylib 6.0, software renderer, memory platform ----------------------------
RLB="$BUILD/raylib-build"; rm -rf "$RLB"
CMAKE_COMMON=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_EXAMPLES=OFF
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_POSITION_INDEPENDENT_CODE=ON)
[ -z "$TCFILE" ] || CMAKE_COMMON+=(-DCMAKE_TOOLCHAIN_FILE="$TCFILE")
# The option names come from the raylib 6.0 docs/bindings (PLATFORM=Memory, OPENGL_VERSION=Software);
# if one spelling is rejected we try the next one.
ok=0
for plat in Memory MEMORY PLATFORM_MEMORY; do
  rm -rf "$RLB"
  if cmake -S "$RL" -B "$RLB" "${CMAKE_COMMON[@]}" -DPLATFORM="$plat" -DOPENGL_VERSION=Software; then ok=1; break; fi
done
[ "$ok" = 1 ] || { echo "raylib: cmake configure failed for every PLATFORM spelling"; exit 1; }
cmake --build "$RLB" -j"$JOBS"
cmake --install "$RLB"
[ -f "$PREFIX/lib/libraylib.a" ] || { echo "libraylib.a missing"; exit 1; }
[ -f "$PREFIX/include/raylib.h" ] || { echo "raylib.h missing"; exit 1; }

# ---- game + shim ---------------------------------------------------------------
OBJ="$OUT/obj"; rm -rf "$OBJ"; mkdir -p "$OBJ"
CXXFLAGS_ALL="-std=c++17 -O2 -pipe -w -ffunction-sections -fdata-sections -I$GR/src -I$PREFIX/include"
for s in main Game IconRenderer Menu UI Settings Editor Level Collision Player; do
  [ -f "$GR/src/$s.cpp" ] || { echo "missing $GR/src/$s.cpp"; exit 1; }
  $CXX $CXXFLAGS_ALL -c "$GR/src/$s.cpp" -o "$OBJ/$s.o" &
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 0.1; done
done
$CXX $CXXFLAGS_ALL -DGD_VNC_PORT=$VNC_PORT -c "$ROOT/geodash/gd_shim.cpp" -o "$OBJ/gd_shim.o" &
$CC -O2 -pipe -w -ffunction-sections -fdata-sections -I"$PREFIX/include" -c "$ROOT/geodash/gd_vnc.c" -o "$OBJ/gd_vnc.o" &
wait
for o in main Game IconRenderer Menu UI Settings Editor Level Collision Player gd_shim gd_vnc; do
  [ -f "$OBJ/$o.o" ] || { echo "compile failed: $o"; exit 1; }
done

WRAPS=""
for f in InitWindow SetTargetFPS EndDrawing WindowShouldClose \
         IsKeyPressed IsKeyPressedRepeat IsKeyDown IsKeyReleased IsKeyUp GetKeyPressed GetCharPressed \
         IsMouseButtonPressed IsMouseButtonDown IsMouseButtonReleased IsMouseButtonUp \
         GetMouseX GetMouseY GetMousePosition GetMouseDelta GetMouseWheelMove; do
  WRAPS="$WRAPS -Wl,--wrap=$f"
done
# libstdc++/libgcc static: the toolchain's copies do not exist on the e-reader.
$CXX -O2 -static-libstdc++ -static-libgcc -Wl,--gc-sections $WRAPS "$OBJ"/*.o -o "$OUT/geodash" \
  -L"$PREFIX/lib" -Wl,--start-group -lraylib -lvncserver -lz -lpthread -lrt -lm -ldl -Wl,--end-group
[ -x "$OUT/geodash" ] || { echo "link failed"; exit 1; }
ls -l "$OUT/geodash"
echo "== geodash ok =="
