#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
OUT="$BUILD/geodash"
GR="$BUILD/GeometryRush"
PKG="$ROOT/dist/pkg"; rm -rf "$ROOT/dist"
D="$PKG/.adds/geodash"; mkdir -p "$D/bin" "$D/lib" "$D/home" "$PKG/lua"

cp "$OUT/geodash" "$D/bin/geodash"
"$TRIPLE-strip" "$D/bin/geodash"
file "$D/bin/geodash"

# Runtime libraries from the toolchain do not exist on the e-reader: ship what is not part of libc.
"$TRIPLE-readelf" -d "$D/bin/geodash" | grep NEEDED || true
for n in $("$TRIPLE-readelf" -d "$D/bin/geodash" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
  case "$n" in libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|ld-linux*) continue ;; esac
  p="$("$TRIPLE-gcc" -print-file-name="$n")"
  if [ -f "$p" ]; then cp -L "$p" "$D/lib/$n"; echo "bundled $n"
  else echo "WARNING: $n is needed but was not found in the toolchain"; fi
done

# The game reads levels/ from its working directory (home/) - and, to be safe, from next to the binary.
cp -r "$GR/levels" "$D/home/levels"
cp -r "$GR/levels" "$D/bin/levels"
echo "$(git -C "$GR" rev-parse HEAD)" > "$D/GEOMETRYRUSH-REVISION.txt"

cp "$ROOT"/lua/*.lua "$PKG/lua/"
cp "$ROOT/README.md" "$PKG/README.md"
( cd "$PKG" && zip -qr "$ROOT/dist/geodash-kobo.zip" . )
ls -lh "$ROOT/dist/geodash-kobo.zip"
