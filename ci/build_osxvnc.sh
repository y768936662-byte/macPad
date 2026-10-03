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
mkdir -p libvncauth
( cd libvncauth && rm -f libvncauth.a && ar rcs libvncauth.a )
mkdir -p libjpeg
cp -f "$JPEGLIB_A" libjpeg/libjpeg.a
[ -n "${TURBO_A:-}" ] && cp -f "$TURBO_A" libjpeg/libturbojpeg.a
( cd rdr && make librdr.a > /dev/null 2>&1 ) || ( cd rdr && make librdr.a )

echo "==> [4/6] build OSXvnc-server (arm64, min macOS 13.0)"
HDR_DIR="$(dirname "$JPEGLIB_HDR")"
JCFG_DIR="$(dirname "$JCONFIG_HDR")"
TFH_DIR="$(dirname "$TURBO_HDR")"
CFLAGS_ALL="-O2 -mmacosx-version-min=13.0 -marm64"
make OSXvnc-server \
   CFLAGS="$CFLAGS_ALL" CXXFLAGS="$CFLAGS_ALL" \
   INCLUDES="-Ilibvncauth -Iinclude -Iinclude/X11 -Iinclude/Xserver -I\"$HDR_DIR\" -I\"$JCFG_DIR\" -I\"$TFH_DIR\"" \
   SUPPORTLIB="-L./libjpeg -lturbojpeg -ljpeg -lz" \
   > make_osxvnc.log 2>&1
RC=$?
if [ $RC -ne 0 ] || [ ! -f OSXvnc-server ]; then
  echo "---- make_osxvnc.log tail ----"; tail -60 make_osxvnc.log; echo "----"
  echo "FATAL: OSXvnc-server not produced (rc=$RC)"; exit 1
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
