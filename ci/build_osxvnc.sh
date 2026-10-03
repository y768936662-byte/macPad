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

echo "==> [2b/6] build libjpeg-turbo fat (arm64;arm64e) for the arm64e binary"
cd "$SRC/libjpeg-turbo"
rm -rf build-fat && mkdir build-fat && cd build-fat
cmake .. -DCMAKE_BUILD_TYPE=Release \
     "-DCMAKE_OSX_ARCHITECTURES=arm64;arm64e" \
     -DBUILD_SHARED_LIBS=OFF \
     -DCMAKE_C_FLAGS="-mmacosx-version-min=13.0" > cmake.log 2>&1
if [ $? -ne 0 ]; then
  echo "---- cmake.log tail ----"; tail -40 cmake.log; echo "----"
  echo "WARN: fat libjpeg cmake failed; arm64e build will be skipped"
  FAT_OK=0
else
  make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1
  if [ $? -ne 0 ]; then
    echo "---- make.log tail ----"; tail -40 make.log; echo "----"
    echo "WARN: fat libjpeg make failed; arm64e build will be skipped"
    FAT_OK=0
  else
    FAT_OK=1
  fi
fi
cd "$SRC"
FAT_JPEGLIB_A=""; FAT_TURBO_A=""
[ "$FAT_OK" = "1" ] && FAT_JPEGLIB_A="$(find "$SRC/libjpeg-turbo/build-fat" -name 'libjpeg.a' | head -1)"
[ "$FAT_OK" = "1" ] && FAT_TURBO_A="$(find "$SRC/libjpeg-turbo/build-fat" -name 'libturbojpeg.a' | head -1)"
echo "  fat libjpeg.a = ${FAT_JPEGLIB_A:-n/a}  fat libturbojpeg.a = ${FAT_TURBO_A:-n/a}"

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
# fat C++ archive for the arm64e binary (rdr is C++; plain -arch arm64e needs it)
if [ -d rdr ]; then
  cp -R rdr rdr_e 2>/dev/null || true
  if [ -d rdr_e ]; then
    ( cd rdr_e && make clean > /dev/null 2>&1; make librdr_e.a CXXFLAGS="-O2 -arch arm64e -mmacosx-version-min=13.0" > /dev/null 2>&1 ) || \
      ( cd rdr_e && make librdr.a CXXFLAGS="-O2 -arch arm64e -mmacosx-version-min=13.0" > /dev/null 2>&1 )
    ls rdr_e/librdr_e.a rdr_e/librdr.a 2>/dev/null
  fi
fi

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

C_SRCS="main rfbserver miregion kbdptr auth sockets xalloc stats corre hextile rre translate cutpaste dimming tight zlib zlibhex mousecursor getMACAddress vncauth d3des"
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

echo "==> [4b/6] build arm64e slice (needs fat jpeg + allow-arm64e entitlement)"
# arm64e requires the entitlement com.apple.security.cs.allow-arm64e on the
# executable; libjpeg-turbo is built fat in [2b]; rdr needs an arm64e archive.
if [ "$FAT_OK" = "1" ] && [ -n "$FAT_JPEGLIB_A" ]; then
  ENT_AE=$(mktemp /tmp/ent_arm64e.XXXXXX)
  cat > "$ENT_AE" <<'EPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-arm64e</key>
    <true/>
</dict>
</plist>
EPLIST
  # fat stub libvncauth (arm64+arm64e)
  ( cd libvncauth && rm -f libvncauth.a __stub64e.c __stub64e.o \
      && printf 'int __vncauth_stub64e;' > __stub64e.c \
      && cc -arch arm64 -arch arm64e -c __stub64e.c -o __stub64e.o \
      && ar rcs libvncauth.a __stub64e.o \
      && rm -f __stub64e.c __stub64e.o )
  # fat jpeg libs override the arm64-only copies for the arm64e link
  cp -f "$FAT_JPEGLIB_A" libjpeg/libjpeg.a
  [ -n "${FAT_TURBO_A:-}" ] && cp -f "$FAT_TURBO_A" libjpeg/libturbojpeg.a || true
  AE_OK=1
  for f in $C_SRCS; do
    if clang -x c -O2 -arch arm64e -mmacosx-version-min=13.0 "${INCFLAGS[@]}" -c "$f.c" -o "${f}_ae.o" >>build_ae.log 2>&1; then
      :
    elif clang -x objective-c -O2 -arch arm64e -mmacosx-version-min=13.0 "${INCFLAGS[@]}" -c "$f.c" -o "${f}_ae.o" >>build_ae.log 2>&1; then
      :
    else
      echo "  WARN: $f.c fails as arm64e (both C and ObjC); arm64e slice skipped"
      AE_OK=0; break
    fi
  done
  if [ "$AE_OK" = "1" ]; then
    clang++ -x c++ -O2 -arch arm64e -mmacosx-version-min=13.0 "${INCFLAGS[@]}" -c zrle.cc -o zrle_ae.o >>build_ae.log 2>&1 || { AE_OK=0; }
    clang -x objective-c -O2 -arch arm64e -mmacosx-version-min=13.0 "${INCFLAGS[@]}" -c VNCServer.m -o VNCServer_ae.o >>build_ae.log 2>&1 || { AE_OK=0; }
  fi
  if [ "$AE_OK" = "1" ]; then
    AE_OBJS=""; for f in $C_SRCS; do AE_OBJS="$AE_OBJS ${f}_ae.o"; done
    AE_RDR="rdr_e/librdr.a"; [ -f "$AE_RDR" ] || AE_RDR="rdr/librdr.a"
    clang++ -o OSXvnc-server.ae $AE_OBJS zrle_ae.o VNCServer_ae.o \
      -Llibvncauth -lvncauth -Llibjpeg -ljpeg -lturbojpeg -L"$AE_RDR" -lrdr -lz \
      -O2 -arch arm64e -mmacosx-version-min=13.0 \
      -sectcreate __TEXT __entitlements "$ENT_AE" \
      -framework Carbon -framework IOKit -framework Cocoa \
      >>build_ae.log 2>&1
    if [ $? -eq 0 ] && [ -f OSXvnc-server.ae ]; then
      echo "  arm64e slice built (OSXvnc-server.ae, allow-arm64e embedded)"
      lipo -archs OSXvnc-server.ae 2>/dev/null || file OSXvnc-server.ae
    else
      echo "---- build_ae.log tail ----"; tail -40 build_ae.log; echo "----"
      echo "  WARN: arm64e link failed; continuing with arm64 only"
      AE_OK=0
    fi
  fi
  rm -f "$ENT_AE"
else
  echo "  WARN: fat libjpeg unavailable; arm64e slice skipped (arm64 only)"
fi

echo "==> [5/6] verify architecture"
vtool -show-build OSXvnc-server 2>/dev/null | grep -E "platform|arch|minOS" || true
lipo -archs OSXvnc-server 2>/dev/null || file OSXvnc-server
echo "  linked jpeg libs:"; otool -L OSXvnc-server 2>/dev/null | grep -iE "turbojpeg|jpeg|libc\+\+|stdc" || true

echo "==> [6/6] stage to dist"
cp -f OSXvnc-server "$OUT/OSXvnc-server"
cp -f storepasswd "$OUT/storepasswd" 2>/dev/null || true
shasum -a 256 "$OUT/OSXvnc-server" | sed 's/[[:space:]].*//' > "$OUT/OSXvnc-server.sha256"
if [ -f OSXvnc-server.ae ]; then
  cp -f OSXvnc-server.ae "$OUT/OSXvnc-server.ae"
  shasum -a 256 "$OUT/OSXvnc-server.ae" | sed 's/[[:space:]].*//' > "$OUT/OSXvnc-server.ae.sha256"
fi
ls -la "$OUT"
echo "==> DONE: $OUT/OSXvnc-server  sha256=$(cat "$OUT/OSXvnc-server.sha256")"
[ -f "$OUT/OSXvnc-server.ae" ] && echo "==> arm64e: $OUT/OSXvnc-server.ae sha256=$(cat "$OUT/OSXvnc-server.ae.sha256")" || echo "==> (no arm64e slice this run)"
