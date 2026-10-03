#!/bin/bash
# ============================================================
# 在一台 Mac（或 macos-14 GitHub runner）上补齐 5 个 macOS-SDK 工具：
#   macwsdisplayd  macwsinputd  macwsinteropd  macwsworkspacectl  macwsneofetch
# 它们 Makefile 是 TARGET:=macosx（链 AppKit/QuickLookThumbnailing），
# 设备 Theos 没有 macOS SDK，编不了 → 必须 Mac 编好再缓存到设备。
#
# 用法（在 Mac 上，THEOS 已装、macosx SDK 可用时）：
#   export THEOS=$HOME/theos
#   export PROJECT_DIR=/path/to/macPad   # 含 misc/macws_artifact_contract.py
#   bash ci/build_macws_tools_macos.sh
# 产物：$PROJECT_DIR/dist/macws-tools/
#   - 5 个二进制（fat: arm64+arm64e）
#   - macws-tools.build.json（每个二进制的 sha256 + 源指纹）
#   - install_macws_tools_on_ipad.sh（推到设备并安装+信任的脚本）
# ============================================================
set -eu

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
THEOS="${THEOS:-$HOME/theos}"
export THEOS
DIST="$PROJECT_DIR/dist/macws-tools"
mkdir -p "$DIST"
cd "$PROJECT_DIR"

TOOLS="macwsdisplayd macwsinputd macwsinteropd macwsworkspacectl macwsneofetch"
# 产物二进制名与子项目目录名不同（neofetch 的 Makefile 把可执行文件编成 macws-neofetch，带连字符）
tool_binname() { case "$1" in macwsneofetch) echo "macws-neofetch";; *) echo "$1";; esac; }
GMAKE="$(command -v gmake || command -v make)"
ENT="$PROJECT_DIR/layout/usr/macOS/bin/entitlements.plist"

echo "==> [1/4] 准备 macOS SDK 符号链接（给 Theos）"
if ! ls "$THEOS"/sdks/MacOSX*.sdk >/dev/null 2>&1; then
  P="$(xcrun --sdk macosx --show-sdk-path)"; V="$(xcrun --sdk macosx --show-sdk-version)"
  ln -sfn "$P" "$THEOS/sdks/MacOSX${V}.sdk"; echo "    已链接 MacOSX${V}.sdk"
fi

echo "==> [2/4] 逐个构建 5 个工具（macosx:clang，fat arm64+arm64e）"
for t in $TOOLS; do
  echo "---- $t ----"
  if [ ! -d "$PROJECT_DIR/$t" ]; then echo "    跳过：缺 $t/ 目录"; continue; fi
  "$GMAKE" -C "$t" clean all \
      FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
      THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 ARCHS="arm64 arm64e" 2>&1 | tail -3
  BINNAME=$(tool_binname "$t")
  # 产物选择：优先 Theos 合并出的顶层 fat 产物 <dir>/.theos/obj/<BINNAME>；
  # 若它是 thin（只有单架构），则用 lipo -create 把各架构对象合并成 fat。
  # 这样 5 个工具产物都是 fat（x86_64/arm64 + arm64e），设备 ldid 才签得动。
  TOP="$t/.theos/obj/$BINNAME"
  archs_present="$(lipo -info "$TOP" 2>/dev/null | grep -oE 'x86_64|arm64|arm64e' | sort -u | tr '\n' ' ')"
  if [ -f "$TOP" ] && echo "$archs_present" | grep -q "arm64e" && [ "$(echo $archs_present | wc -w)" -ge 2 ]; then
    BUILT="$TOP"
  else
    # 合并所有 per-arch 对象成 fat
    SLICES=$(find "$t/.theos/obj" -name "$BINNAME" -type f 2>/dev/null)
    [ -n "$SLICES" ] || { echo "    未产出 $t（binname=$BINNAME）"; continue; }
    echo "    合并 fat：$(echo "$SLICES" | tr '\n' ' ')"
    lipo -create $(echo "$SLICES" | tr '\n' ' ') -output "$DIST/$BINNAME.tmp" 2>/dev/null || { echo "    lipo 合并失败 $t"; continue; }
    BUILT="$DIST/$BINNAME.tmp"
    rm -f "$DIST/$BINNAME.tmp" 2>/dev/null || true
    # 合并结果放到 DIST 供 ldid/manifest 用
    cp -f "$BUILT" "$DIST/$BINNAME" 2>/dev/null || true
    BUILT="$DIST/$BINNAME"
    echo "    已合成 fat $t -> $(lipo -info "$BUILT" 2>/dev/null | grep -oE 'arm64e?|x86_64' | tr '\n' ' ')"
  fi
  ldid -S "$ENT" -M "$BUILT" 2>/dev/null || true
  # 产物以 BINNAME 命名（neofetch 带连字符 macws-neofetch，与设备端 postinst/configure_terminal_cli 约定一致）
  cp -f "$BUILT" "$DIST/$BINNAME"
  echo "    -> $BINNAME  ($(lipo -info "$DIST/$BINNAME" 2>/dev/null | grep -oE 'arm64e?|x86_64' | sort -u | tr '\n' ' '))"
done

echo "==> [3/4] 生成 manifest"
python3 - "$DIST" <<'PY'
import hashlib, json, os, sys, glob
d = sys.argv[1]
man = {"tools": {}}
for f in sorted(os.listdir(d)):
    if not os.path.isfile(os.path.join(d, f)) or f.endswith((".json", ".sh")):
        continue
    p = os.path.join(d, f)
    man["tools"][f] = {"sha256": hashlib.sha256(open(p, "rb").read()).hexdigest(),
                       "bytes": os.path.getsize(p)}
json.dump(man, open(os.path.join(d, "macws-tools.build.json"), "w"), indent=2, sort_keys=True)
print("    manifest:", [k for k in man["tools"]])
PY

echo "==> [4/4] 产出设备安装脚本"
cp "$PROJECT_DIR/ci/install_macws_tools_on_ipad.sh" "$DIST/install_macws_tools_on_ipad.sh" 2>/dev/null || true
ls -la "$DIST" | sed 's/^/    /'
echo "完成。把 $DIST/ 推到 iPad 后跑 install_macws_tools_on_ipad.sh。"
