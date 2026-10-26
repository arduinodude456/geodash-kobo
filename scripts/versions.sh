# Pinned upstream versions.
ZLIB_VER=1.3.1
LIBVNC_VER=0.9.14
# raylib 6.0 brings the software renderer (rlsw) and PLATFORM_MEMORY (no GPU, no window).
RAYLIB_VER=6.0
# GeometryRush (C++17 + raylib, procedural graphics, no image assets).
# Upstream has no license file as far as I could see: it is cloned at build time, never copied into this repo.
GEOMRUSH_REPO=https://github.com/volinskii1405-ui/GeometryRush
GEOMRUSH_BRANCH=claude/intelligent-gates-eshdw1
# Pin a commit here once you know a working one (the build prints the revision it used).
GEOMRUSH_REV=
