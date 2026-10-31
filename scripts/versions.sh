# Pinned upstream versions.
ZLIB_VER=1.3.1
LIBVNC_VER=0.9.14
# libcurl: TIC-80's CMake refuses to configure without it (we build it without TLS, the core never goes online).
CURL_VER=8.11.1

# TIC-80 fantasy computer (MIT), built as its libretro core and driven by geodash/gd_shim.cpp.
TIC80_REPO=https://github.com/nesbox/TIC-80
# Release tag; if it does not exist the build falls back to the default branch.
TIC80_REF=v1.1.2837
# Pin a commit here once you know a working one (the build prints the revision it used).
TIC80_REV=
# Scripting languages compiled into the core (a cart written in a language that is not built in
# will not run). "lua" is the most common one; "js" is cheap. If the configure step fails with
# this list, the build retries with Lua only.
TIC80_LANGS="lua js"
