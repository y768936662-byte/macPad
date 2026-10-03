#!/bin/bash
# build_osxvnc.sh — build a standalone arm64 `OSXvnc-server` on a macOS runner.
#
# Background: macPad runs VNC out of the iPad rootfs via /usr/local/bin/OSXvnc-server
# (launched by macos_gui.sh with -rfbnoauth). The rootfs currently has NO such binary,
# so the desktop cannot produce a visible framebuffer. This script produces the arm64
# binary from stweil/OSXvnc (the known-good upstream slice per macPad RE notes).
#
# Outputs:  $OUT/OSXvnc-server   (arm64 Mach-O)
#           $OUT/OSXvnc-server.sha256
set -uo pipefail

OUT="${OUT:-$PWD/osxvnc-dist}"
SRC="${SRC:-$PWD/osxvnc-src}"
COMMIT="${OSXVNC_COMMIT:-}"           # optional pin
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

echo "==> [2/6] build libjpeg-turbo (arm64 static)"
cd "$SRC/libjpeg-turbo" || { echo "FATAL: no libjpeg-turbo submodule (clone --recursive?)"; exit 1; }
rm -rf build-arm64 && mkdir build-arm64 && cd build-arm64
cmake .. -DCMAKE_BUILD_TYPE=Release \
     -DCMAKE_OSX_ARCHITECTURES=arm64 \
     -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
     -DCMAKE_C_FLAGS="-mmacosx-version-min=13.0" > /dev/null 2>&1
make -j"$(sysctl -n hw.ncpu)" > build.log 2>&1 || { tail -40 build.log; echo "FATAL: libjpeg-turbo build failed"; exit 1; }
# locate headers + static libs (defensive)
JPEGLIB_HDR="$(find "$SRC/libjpeg-turbo" -name jpeglib.h | head -1)"
JCONFIG_HDR="$(find "$SRC/libjpeg-turbo" -name jconfig.h | head -1)"
TURBO_HDR="$(find "$SRC/libjpeg-turbo" -name libturbojpeg.h | head -1)"
JPEGLIB_A="$(find "$SRC/libjpeg-turbo/build-arm64" -name 'libjpeg*.a' | head -1)"
TURBO_A="$(find "$SRC/libjpeg-turbo/build-arm64" -name 'libturbojpeg.a' | head -1)"
echo "  jpeglib.h  = $JPEGLIB_HDR"
echo "  jconfig.h  = $JCONFIG_HDR"
echo "  libjpeg.a  = $JPEGLIB_A"
echo "  libturbojpeg.a = $TURBO_A"
[ -n "$JPEGLIB_HDR" ] && [ -n "$JPEGLIB_A" ] || { echo "FATAL: missing jpeg headers/lib"; exit 1; }

cd "$SRC/OSXvnc-server"

echo "==> [3/6] satisfy Makefile prerequisites (libvncauth / libjpeg / rdr)"
# libvncauth: Makefile is a no-op; auth symbols come from auth.c compiled into the main
# binary. Provide an empty archive so `-lvncauth` resolves.
mkdir -p libvncauth
( cd libvncauth && rm -f libvncauth.a && ar rcs libvncauth.a )
# libjpeg: no Makefile in-tree; alias the built API-compat libjpeg.a into the expected path
mkdir -p libjpeg
cp -f "$JPEGLIB_A" libjpeg/libjpeg.a
# rdr: real sub-makefile
make -C rdr librdr.a > /dev/null 2>&1 || ( cd rdr && make librdr.a )

echo "==> [4/6] build OSXvnc-server (arm64, min macOS 13.0)"
# Defensive: copy turbojpeg lib + ensure jconfig.h reachable, then override INCLUDES/SUPPORTLIB.
[ -n "${TURBO_A:-}" ] && cp -f "$TURBO_A" libjpeg/libturbojpeg.a
HDR_DIR="$(dirname "$JPEGLIB_HDR")"
CFLAGS_ALL="-O2 -mmacosx-version-min=13.0 -marm64"
make OSXvnc-server \
   CFLAGS="$CFLAGS_ALL" \
   CXXFLAGS="$CFLAGS_ALL" \
   INCLUDES="-Ilibvncauth -Iinclude -Iinclude/X11 -Iinclude/Xserver -I\"$HDR_DIR\" -I\"$(dirname "$JCONFIG_HDR")\" -I\"$(dirname "$TURBO_HDR")\" -I\"$SRC/OSXvnc-server\"" \
   SUPPORTLIB="-L./libjpeg -lturbojpeg -ljpeg -lz" \
   2>&1 | tail -40
[ -f OSXvnc-server ] || { echo "FATAL: OSXvnc-server not produced"; ls -la; exit 1; }

echo "==> [5/6] verify architecture"
vtool -show-build OSXvnc-server 2>/dev/null | grep -E "platform|arch|minOS" || true
lipo -archs OSXvnc-server 2>/dev/null || file OSXvnc-server
codesign -d - -v OSXvnc-server >/dev/null 2>&1 && echo "  codesign: signed(presigned?)" || echo "  codesign: adhoc/unsigned (will be re-signed on device)"

echo "==> [6/6] stage to dist"
cp -f OSXvnc-server "$OUT/OSXvnc-server"
cp -f storepasswd "$OUT/storepasswd" 2>/dev/null || true
shasum -a 256 "$OUT/OSXvnc-server" | sed 's/[[:space:]].*//' > "$OUT/OSXvnc-server.sha256"
ls -la "$OUT"
echo "==> DONE: $OUT/OSXvnc-server  sha256=$(cat "$OUT/OSXvnc-server.sha256")"
