#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
OUT="$BUILD/geodash"
T80="$BUILD/TIC-80"
PKG="$ROOT/dist/pkg"; rm -rf "$ROOT/dist"
D="$PKG/.adds/geodash"; mkdir -p "$D/bin" "$D/lib" "$D/home/carts" "$PKG/lua"

cp "$OUT/geodash" "$D/bin/geodash"
"$TRIPLE-strip" "$D/bin/geodash"
file "$D/bin/geodash"
FILES=("$D/bin/geodash")
if [ -f "$OUT/tic80_libretro.so" ]; then
  cp "$OUT/tic80_libretro.so" "$D/lib/tic80_libretro.so"
  "$TRIPLE-strip" --strip-unneeded "$D/lib/tic80_libretro.so" || true
  file "$D/lib/tic80_libretro.so"
  FILES+=("$D/lib/tic80_libretro.so")
fi

# Runtime libraries from the toolchain do not exist on the e-reader: ship what is not part of libc.
for f in "${FILES[@]}"; do
  "$TRIPLE-readelf" -d "$f" | grep NEEDED || true
  for n in $("$TRIPLE-readelf" -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
    case "$n" in libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|ld-linux*|tic80_libretro*) continue ;; esac
    [ -f "$D/lib/$n" ] && continue
    p="$("$TRIPLE-gcc" -print-file-name="$n")"
    if [ -f "$p" ]; then cp -L "$p" "$D/lib/$n"; echo "bundled $n"
    else echo "WARNING: $n is needed but was not found in the toolchain"; fi
  done
done

# Carts: any .tic files that ship with the TIC-80 sources (if there are none, put your own in home/carts/).
n=0
while IFS= read -r c; do cp "$c" "$D/home/carts/"; n=$((n+1)); done < <(find "$T80" -name '*.tic' -not -path '*/.git/*' 2>/dev/null | head -n 20)
echo "carts bundled: $n"
cat > "$D/home/carts/PUT-YOUR-CARTS-HERE.txt" <<'TXT'
Put TIC-80 cart files (*.tic) in this folder, e.g. from https://tic80.com/ (open a game, "Download .tic").
Only carts written in the scripting languages built into the core will run (see TIC80_LANGS in scripts/versions.sh).
Each cart has its own licence: use them privately unless the author says otherwise.
TXT

echo "$(git -C "$T80" rev-parse HEAD)" > "$D/TIC80-REVISION.txt"
[ -f "$T80/LICENSE" ] && cp "$T80/LICENSE" "$D/LICENSE-TIC80.txt" || true

cp "$ROOT"/lua/*.lua "$PKG/lua/"
cp "$ROOT/README.md" "$PKG/README.md"
( cd "$PKG" && zip -qr "$ROOT/dist/geodash-kobo.zip" . )
ls -lh "$ROOT/dist/geodash-kobo.zip"
