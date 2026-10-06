#!/bin/bash
# ============================================================
# 在 macOS runner（或任意 Mac）上产出 chroot 侧需要的 macOS 平台宿主组件：
#
#   1) MTLSimDriverHost.xpc —— 仓库自建（含 surface_copy 端点），
#      TARGET=macosx:clang 编出 LC_BUILD_VERSION platform=1 (macOS)。
#      设备 Theos 无 macOS SDK 编不了 → 必须在这里编好推设备。
#   2) （可选，参数 --extract-cache）从苹果原生 macOS 13.4 IPSW 的
#      dyld_shared_cache_arm64e 里抽出 MTLSimDriver / MTLSimImplementation
#      主 dylib（macOS 平台，供 chroot dlopen；铁证 G/H/I：iOS-sim 版进
#      chroot 会被 dyld 拒载或崩 WSInitialize）。
#
# 用法（macos runner / Mac，THEOS 已装）：
#   export THEOS=$HOME/theos
#   bash ci/build_mtl_host_macos.sh [--extract-cache /path/to/macOS/rootfs/or/cryptex_tar]
#
# 产物：dist/mtl-host-macos/
#   MTLSimDriverHost            ← macOS 平台 XPC 可执行（arm64 fat 可选）
#   Info.plist                  ← XPC bundle 描述
#   mtl-host-macos.build.json   ← sha256 manifest
#   MTLSimDriver                ← （--extract-cache 时）macOS 平台主 shim dylib
#   MTLSimImplementation        ← （--extract-cache 时）同上
#   install_mtl_host_on_ipad.sh ← 推设备+部署 chroot 的脚本
# ============================================================
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
THEOS="${THEOS:-$HOME/theos}"
export THEOS
DIST="$PROJECT_DIR/dist/mtl-host-macos"
mkdir -p "$DIST"
cd "$PROJECT_DIR"

EXTRACT_CACHE=0
CACHE_SRC=""
for a in "$@"; do
  case "$a" in
    --extract-cache) EXTRACT_CACHE=1 ;;
    --extract-cache=*) EXTRACT_CACHE=1; CACHE_SRC="${a#--extract-cache=}" ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

GMAKE="$(command -v gmake || command -v make)"
ENT="$PROJECT_DIR/layout/usr/macOS/bin/entitlements.plist"

echo "==> [1/4] 准备 macOS SDK 符号链接（给 Theos）"
if ! ls "$THEOS"/sdks/MacOSX*.sdk >/dev/null 2>&1; then
  P="$(xcrun --sdk macosx --show-sdk-path)"; V="$(xcrun --sdk macosx --show-sdk-version)"
  ln -sfn "$P" "$THEOS/sdks/MacOSX${V}.sdk"; echo "    已链接 MacOSX${V}.sdk"
fi
# theos vendor/include 的 iOS 向 IOKit 头会与 macOS SDK 的 IOKit clang module
# 打架（IOVirtualRange/IOPhysicalRange 重定义 → Foundation/CoreGraphics module
# 构建失败）。macosx 构建一律用 SDK 自带的 IOKit，把 theos 的移走。
if [ -d "$THEOS/vendor/include/IOKit" ]; then
  mv "$THEOS/vendor/include/IOKit" "$THEOS/vendor/include/IOKit.iosbak"
  echo "    已移走 theos vendor IOKit 头（macosx 构建用 SDK 版）"
fi

echo "==> [2/4] 编 MTLSimDriverHost（macosx:clang → platform=1 macOS）"
# TARGET 传给 make 覆盖 Makefile 默认值（?=），出 macOS 平台二进制。
# 注意不要过滤输出——错误详情要进 CI 日志。
set +e
"$GMAKE" -C MTLSimDriverHost clean all \
    TARGET=macosx:clang FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
    GO_EASY_ON_ME=1 ARCHS=arm64
RC=$?
set -e
if [ "$RC" != "0" ]; then
  echo "ERROR: make rc=$RC —— 上面是完整编译输出" >&2
  exit 1
fi

# Theos bundle 产物（flat xpc layout）：二进制在
#   <dir>/.theos/obj/macosx/arm64/MTLSimDriverHost.xpc/Contents/MacOS/MTLSimDriverHost
# 或打包后 <dir>/.theos/obj/macosx/MTLSimDriverHost.xpc/... —— find 兜底。
CAND1=$(find MTLSimDriverHost/.theos/obj -type f -name MTLSimDriverHost -path "*MacOS*" 2>/dev/null | head -1)
OUT_BIN="${CAND1:-MTLSimDriverHost/.theos/obj/macosx/MTLSimDriverHost}"
[ -f "$OUT_BIN" ] || { echo "ERROR: 未产出 $OUT_BIN" >&2; find MTLSimDriverHost/.theos -type f 2>/dev/null | head -20; exit 1; }
echo "    产物: $OUT_BIN"
# 同 bundle 的 Info.plist 一起带走（flat 布局）
OUT_PLIST=$(dirname "$OUT_BIN")/../../Info.plist
[ -f "$OUT_PLIST" ] || OUT_PLIST=$(find MTLSimDriverHost/.theos/obj -name "Info.plist" -path "*MTLSimDriverHost.xpc*" 2>/dev/null | head -1)

echo "==> [3/4] 验证 platform（macOS）+ 签名"
# LC_BUILD_VERSION platform 必须是 macOS。vtool 输出两种格式：
#   新版：platform MACOS     旧版：platform 1
# 铁证 H：iOS/IOSSIMULATOR 平台进 chroot 被 dyld 拒载。
PLAT=$(vtool -show-build "$OUT_BIN" 2>/dev/null | awk '/platform/ {print $2; exit}')
echo "    platform = ${PLAT:-unknown}"
case "$PLAT" in
  1|MACOS|MACOSX) : ;;
  *) echo "ERROR: platform=$PLAT 不是 macOS，拒绝发布" >&2; exit 1 ;;
esac
codesign -f -s - "$OUT_BIN"
PLAT2=$(vtool -show-build "$OUT_BIN" 2>/dev/null | awk '/platform/ {print $2; exit}')
case "$PLAT2" in
  1|MACOS|MACOSX) : ;;
  *) echo "ERROR: 签名后 platform 变了 ($PLAT2)" >&2; exit 1 ;;
esac

cp -f "$OUT_BIN" "$DIST/MTLSimDriverHost"
if [ -n "${OUT_PLIST:-}" ] && [ -f "$OUT_PLIST" ]; then
  cp -f "$OUT_PLIST" "$DIST/Info.plist"
  echo "    Info.plist: $OUT_PLIST"
else
  echo "    （未找到 bundle Info.plist，设备侧用部署器内嵌的 plist）"
fi

echo "==> [4/4] manifest"
python3 - "$DIST" <<'PY'
import hashlib, json, os, sys
d = sys.argv[1]
man = {"mtl_host_macos": {}}
for f in sorted(os.listdir(d)):
    p = os.path.join(d, f)
    if os.path.isfile(p):
        man["mtl_host_macos"][f] = {"sha256": hashlib.sha256(open(p, "rb").read()).hexdigest(),
                                    "bytes": os.path.getsize(p)}
json.dump(man, open(os.path.join(d, "mtl-host-macos.build.json"), "w"), indent=2, sort_keys=True)
print("    manifest:", list(man["mtl_host_macos"]))
PY

# ---------- 可选：抽 dyld shared cache ----------
if [ "$EXTRACT_CACHE" = "1" ]; then
  echo "==> [extra] 从 dyld shared cache 抽 macOS 平台主 dylib"
  # CI 上 macOS rootfs/cryptex tar 通过 workflow 的 artifact / 挂载传入（CACHE_SRC）。
  # 抽取工具：macOS runner 自带 dyld_shared_cache_util。
  if [ -z "$CACHE_SRC" ]; then
    echo "    --extract-cache 需要路径参数（rootfs 目录或 cryptex tar）" >&2; exit 2
  fi
  CACHE_DIR=""
  if [ -d "$CACHE_SRC" ]; then
    CACHE_DIR="$CACHE_SRC"
  elif [ -f "$CACHE_SRC" ]; then
    CACHE_DIR="$RUNNER_TEMP/cache_root"
    mkdir -p "$CACHE_DIR"
    tar -xf "$CACHE_SRC" -C "$CACHE_DIR" --wildcards \
      'System/Library/dyld/dyld_shared_cache_arm64e*' || true
  fi
  CACHE_FILE="$CACHE_DIR/System/Library/dyld/dyld_shared_cache_arm64e"
  [ -f "$CACHE_FILE" ] || { echo "ERROR: 找不到 dyld_shared_cache_arm64e" >&2; exit 1; }
  OUT_X="$RUNNER_TEMP/extracted_mtl"
  mkdir -p "$OUT_X"
  dyld_shared_cache_util -extract "$CACHE_FILE" \
    '/System/Library/PrivateFrameworks/MTLSimDriver.framework/Versions/A/MTLSimDriver' "$OUT_X" || true
  dyld_shared_cache_util -extract "$CACHE_FILE" \
    '/System/Library/PrivateFrameworks/MTLSimImplementation.framework/Versions/A/MTLSimImplementation' "$OUT_X" || true
  for n in MTLSimDriver MTLSimImplementation; do
    SRC_BIN="$OUT_X/System/Library/PrivateFrameworks/$n.framework/Versions/A/$n"
    [ -f "$SRC_BIN" ] || { echo "ERROR: 未抽出 $n" >&2; exit 1; }
    PLAT=$(vtool -show-build "$SRC_BIN" 2>/dev/null | awk '/platform/ {print $2; exit}')
    echo "    $n platform=$PLAT"
    cp -f "$SRC_BIN" "$DIST/$n"
  done
fi

ls -la "$DIST" | sed 's/^/    /'
echo "完成：dist/mtl-host-macos/ → 推 iPad 后跑 install_mtl_host_on_ipad.sh（随产物附带）。"
