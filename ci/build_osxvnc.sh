#!/bin/bash
# build_osxvnc.sh — build a standalone arm64 `OSXvnc-server` on a macOS runner.
#
# Background: macPad runs VNC out of the iPad rootfs via /usr/local/bin/OSXvnc-server
# (launched by macos_gui.sh with -rfbnoauth). The rootfs currently has NO such binary,
# so the desktop cannot produce a visible framebuffer. This script produces the arm64
# binary from stweil/OSXvnc (the known-good upstream slice per macPad RE notes).
#
# Outputs:  $OUT/OSXvnc-server   (arm64 Mach-O, statically linked to jpeg/turbojpeg)
#           $OUT/OSXvnc-server.sha256
set -uo pipefail

OUT="${OUT:-$PWD/dist}"
SRC="${SRC:-$PWD/osxvnc-src}"
COMMIT="${OSXVNC_COMMIT:-}"
# CMake 4.x dropped support for CMakeLists with cmake_minimum_required < 3.5.
# The libjpeg-turbo submodule in stweil/OSXvnc is an older release -> need this override.
export CMAKE_POLICY_VERSION_MINIMUM=3.5

rm -rf "$OUT" "$SRC"; mkdir -p "$OUT"

echo "==> [1/6] clone stweil/OSXvnc (recursive for libjpeg-turbo)"
if [ -n "$COMMIT" ]; then
  git clone https://github.com/stweil/OSXvnc.git "$SRC"
  git -C "$SRC" submodule update --init --recursive || true
  git -C "$SRC" checkout "$COMMIT" 2>/dev/null || echo "  (commit pin not found, using default)"
else
  git clone --recursive --depth 1 https://github.com/stweil/OSXvnc.git "$SRC"
fi
cd "$SRC"
echo "  HEAD: $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "  submodule libjpeg-turbo: $(git -C libjpeg-turbo rev-parse --short HEAD 2>/dev/null || echo MISSING)"

echo "==> [2/6] build libjpeg-turbo (arm64 static)"
cd "$SRC/libjpeg-turbo" || { echo "FATAL: no libjpeg-turbo submodule (clone --recursive?)"; exit 1; }
rm -rf build-arm64 && mkdir build-arm64 && cd build-arm64
cmake .. -DCMAKE_BUILD_TYPE=Release \
     -DCMAKE_OSX_ARCHITECTURES=arm64 \
     -DBUILD_SHARED_LIBS=OFF \
     -DCMAKE_C_FLAGS="-mmacosx-version-min=13.0" > cmake.log 2>&1
if [ $? -ne 0 ]; then
  echo "---- cmake.log tail ----"; tail -50 cmake.log; echo "----"; echo "FATAL: cmake configure failed"; exit 1
fi
make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1
if [ $? -ne 0 ]; then
  echo "---- make.log tail ----"; tail -50 make.log; echo "----"; echo "FATAL: libjpeg-turbo build failed"; exit 1
fi
JPEGLIB_HDR="$(find "$SRC/libjpeg-turbo" -name jpeglib.h | head -1)"
JCONFIG_HDR="$(find "$SRC/libjpeg-turbo/build-arm64" -name jconfig.h | head -1)"
TURBO_HDR="$(find "$SRC/libjpeg-turbo" -name libturbojpeg.h | head -1)"
JPEGLIB_A="$(find "$SRC/libjpeg-turbo/build-arm64" -name 'libjpeg.a' | head -1)"
TURBO_A="$(find "$SRC/libjpeg-turbo/build-arm64" -name 'libturbojpeg.a' | head -1)"
echo "  jpeglib.h  = $JPEGLIB_HDR"
echo "  jconfig.h  = $JCONFIG_HDR"
echo "  libjpeg.a  = $JPEGLIB_A"
echo "  libturbojpeg.a = $TURBO_A"
[ -n "$JPEGLIB_HDR" ] && [ -n "$JPEGLIB_A" ] || { echo "FATAL: missing jpeg headers/lib"; exit 1; }

cd "$SRC/OSXvnc-server"

echo "==> [3/6] satisfy Makefile prerequisites (libvncauth / libjpeg / rdr)"
# libvncauth: upstream ships a prebuilt .a; here it's a no-op placeholder.
# All auth symbols actually come from auth.c (compiled above), so we just need
# a valid empty archive so `-lvncauth` (if kept) resolves. Build it robustly:
# compile a real object first, then archive it (never archive a .c source).
mkdir -p libvncauth
( cd libvncauth \
    && echo 'int __vncauth_stub;' > __stub.c \
    && cc -c __stub.c -o __stub.o \
    && rm -f libvncauth.a __stub.c \
    && ar rcs libvncauth.a __stub.o \
    && rm -f __stub.o )
mkdir -p libjpeg
cp -f "$JPEGLIB_A" libjpeg/libjpeg.a
[ -n "${TURBO_A:-}" ] && cp -f "$TURBO_A" libjpeg/libturbojpeg.a
( cd rdr && make librdr.a > /dev/null 2>&1 ) || ( cd rdr && make librdr.a )

echo "==> [4/6] build OSXvnc-server (arm64, min macOS 13.0)"
# The upstream Makefile compiles main.c with plain `cc` (C mode), but main.c
# includes <Cocoa/Cocoa.h> -> NSString/Protocol undefined in C. Build each
# object explicitly with the correct language, bypassing the fragile Makefile.
HDR_DIR="$(dirname "$JPEGLIB_HDR")"
JCFG_DIR="$(dirname "$JCONFIG_HDR")"
TFH_DIR="$(dirname "$TURBO_HDR")"
ARCHFLAGS=(-O2 -arch arm64 -mmacosx-version-min=13.0)
# -I. so <rfbproto.h> / <vncauth.h> (same dir as rfb.h) resolve; plus libjpeg dirs.
INCFLAGS=(-I. -Ilibvncauth -Iinclude -Iinclude/X11 -Iinclude/Xserver)
[ -n "$HDR_DIR" ]  && INCFLAGS+=(-I"$HDR_DIR")
[ -n "$JCFG_DIR" ] && INCFLAGS+=(-I"$JCFG_DIR")
[ -n "$TFH_DIR" ]  && INCFLAGS+=(-I"$TFH_DIR")

C_SRCS="main rfbserver miregion kbdptr auth sockets xalloc stats corre hextile rre translate cutpaste dimming tight zlib zlibhex mousecursor"
# Some .c transitively pull in Cocoa/Carbon/Foundation (via rfb.h) and must be
# built as Objective-C; others (sockets.c) clash with objc.h's `bool` and must
# stay plain C. We don't know each one up-front, so per-file: try C first,
# fall back to Objective-C on failure. This converges in a single run.
echo "  compiling per-file (C, fallback Objective-C) + zrle.cc(C++) + VNCServer.m ..."
rm -f *.o OSXvnc-server storepasswd build_all.log
comp_ok=0
for f in $C_SRCS; do
  if clang -x c "${ARCHFLAGS[@]}" "${INCFLAGS[@]}" -c "$f.c" -o "$f.o" >>build_all.log 2>&1; then
    echo "  [c]  $f.c"
    comp_ok=1
  elif clang -x objective-c "${ARCHFLAGS[@]}" "${INCFLAGS[@]}" -c "$f.c" -o "$f.o" >>build_all.log 2>&1; then
    echo "  [objc] $f.c"
    comp_ok=1
  else
    echo "  FATAL: $f.c fails as both C and Objective-C"
    tail -40 build_all.log; exit 1
  fi
done
[ "$comp_ok" = "1" ] || { echo "FATAL: nothing compiled"; tail -40 build_all.log; exit 1; }
clang++ -x c++ "${ARCHFLAGS[@]}" "${INCFLAGS[@]}" -c zrle.cc -o zrle.o >>build_all.log 2>&1 \
  || { echo "  FATAL: compile zrle.cc"; tail -40 build_all.log; exit 1; }
clang -x objective-c "${ARCHFLAGS[@]}" "${INCFLAGS[@]}" -c VNCServer.m -o VNCServer.o >>build_all.log 2>&1 \
  || { echo "  FATAL: compile VNCServer.m"; tail -40 build_all.log; exit 1; }

echo "  linking (clang++ driver -> auto C++ runtime) ..."
LINK_OBJS=""
for f in $C_SRCS; do LINK_OBJS="$LINK_OBJS $f.o"; done
clang++ -o OSXvnc-server $LINK_OBJS zrle.o VNCServer.o \
  -Llibvncauth -lvncauth -Llibjpeg -ljpeg -lturbojpeg -Lrdr -lrdr -lz \
  "${ARCHFLAGS[@]}" \
  -framework Carbon -framework IOKit -framework Cocoa \
  >>build_all.log 2>&1
if [ $? -ne 0 ] || [ ! -f OSXvnc-server ]; then
  echo "---- build_all.log tail ----"; tail -60 build_all.log; echo "----"
  echo "FATAL: link failed"; exit 1
fi

echo "==> [5/6] verify architecture"
vtool -show-build OSXvnc-server 2>/dev/null | grep -E "platform|arch|minOS" || true
lipo -archs OSXvnc-server 2>/dev/null || file OSXvnc-server
echo "  linked jpeg libs:"; otool -L OSXvnc-server 2>/dev/null | grep -iE "turbojpeg|jpeg|libc\+\+|stdc" || true

echo "==> [6/6] stage to dist"
cp -f OSXvnc-server "$OUT/OSXvnc-server"
cp -f storepasswd "$OUT/storepasswd" 2>/dev/null || true
shasum -a 256 "$OUT/OSXvnc-server" | sed 's/[[:space:]].*//' > "$OUT/OSXvnc-server.sha256"
ls -la "$OUT"
echo "==> DONE: $OUT/OSXvnc-server  sha256=$(cat "$OUT/OSXvnc-server.sha256")"
