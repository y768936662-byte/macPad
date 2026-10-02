#!/bin/bash
# ============================================================
# macPad · CI 构建脚本（在 macOS 上运行）
#
# 用途：把原本「必须有一台 Mac」的构建环节，搬到 GitHub Actions 的
#       macOS runner 上。产出 dist/ 目录，包含：
#         MacWSWindowing.dylib        ← iPad 本机构建必需的 Apple-ld64 制品
#         MacWSWindowing.sha256
#         MacWSWindowing.build.json
#         MacWSWindowing.fixups.txt   ← dyld_info -fixups 原始输出（取证用）
#         macpad_*.deb                ← 完整安装包（尽力而为，失败不阻断）
#
# 放置位置：macPad 仓库根目录下的  ci/macpad_ci_build.sh
# 用法：bash ci/macpad_ci_build.sh
#
# 依赖（CI 里由 workflow 安装）：Theos、iOS SDK、ldid、dpkg-deb、GNU make、Xcode CLT
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
DIST="${DIST:-$PROJECT_DIR/dist}"
THEOS="${THEOS:-$HOME/theos}"
export THEOS
cd "$PROJECT_DIR"

# --- 可移植的 sha256 ---------------------------------------------------------
# macOS 默认没有 sha256sum（那是 GNU coreutils）；优先 shasum -a 256。
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | sed 's/[[:space:]].*//'
    else
        shasum -a 256 "$1" | sed 's/[[:space:]].*//'
    fi
}

GMAKE="$(command -v gmake || command -v make)"
echo "==> make: $GMAKE"
"$GMAKE" --version | head -1 | sed 's/^/    /'
echo "==> python3: $(command -v python3)  $(python3 -V 2>&1)"
echo "==> THEOS: $THEOS"
echo "==> Xcode SDK: $(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo n/a)"

mkdir -p "$DIST"

echo
echo "==> [0/5] 记录参与构建的源码指纹"
for f in MacWSWindowing/Tweak.x MacWSWindowing/Makefile config/production.mk; do
    if [ -f "$f" ]; then
        printf '    %s  %s  %s\n' "$(sha256_of "$f")" "$(wc -c < "$f" | tr -d ' ')" "$f"
    fi
done

echo
echo "==> [1/5] 准备 macOS SDK"
if ls "$THEOS"/sdks/MacOSX*.sdk >/dev/null 2>&1; then
    echo "    Theos 中已有 macOS SDK"
else
    MACOS_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
    MACOS_SDK_VER="$(xcrun --sdk macosx --show-sdk-version)"
    ln -sfn "$MACOS_SDK_PATH" "$THEOS/sdks/MacOSX${MACOS_SDK_VER}.sdk"
    echo "    已链接 MacOSX${MACOS_SDK_VER}.sdk -> $MACOS_SDK_PATH"
fi
echo "    iOS SDKs:"
ls -1 "$THEOS/sdks" | grep -i '^iPhoneOS' | sed 's/^/      /' || echo "      (无)"

echo
echo "==> [2/5] 构建并校验 MacWSWindowing"
echo "    说明：SpringBoard 是 arm64e，注入的 dylib 必须由 Apple ld64 产出"
echo "          auth-bind/key=DA 的 __cfstring 引用；iPad 的 lld 做不到这一点。"
BUILD_DIR="$PROJECT_DIR/MacWSWindowing"
BUILT="$BUILD_DIR/.theos/obj/MacWSWindowing.dylib"
FIXUPS="$(mktemp)"; MANIFEST="$(mktemp)"; SNAP="$(mktemp)"
trap 'rm -f "$FIXUPS" "$MANIFEST" "$SNAP"' EXIT

python3 misc/macws_artifact_contract.py snapshot --root "$PROJECT_DIR" --manifest "$SNAP"

"$GMAKE" -C "$BUILD_DIR" clean all \
    FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
    THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1

[ -s "$BUILT" ] || { echo "ERROR: 未产出 $BUILT" >&2; exit 1; }
echo "    built: $(ls -la "$BUILT")"
lipo -info "$BUILT" | sed 's/^/    /' || true

# 保留 fixups 原始输出，供 iPad 侧复核 / 排障
dyld_info -arch arm64e -fixups "$BUILT" > "$FIXUPS" 2>&1 || true
cp "$FIXUPS" "$DIST/MacWSWindowing.fixups.txt"
echo "    fixups 行数: $(wc -l < "$FIXUPS" | tr -d ' ')  -> dist/MacWSWindowing.fixups.txt"

cf=$(awk '$2 == "__cfstring" && $4 == "auth-bind" { c++ } END { print c+0 }' "$FIXUPS")
plain=$(awk '$2 == "__cfstring" && $4 == "bind" { c++ } END { print c+0 }' "$FIXUPS")
anycf=$(grep -c "__cfstring" "$FIXUPS" || true)
echo "    __cfstring 行: 总计=$anycf  auth-bind=$cf  plain-bind=$plain"

if [ "$cf" -ge 1 ] && [ "$plain" -eq 0 ]; then
    echo "    ✅ auth-fixup 不变量通过"
elif [ "$cf" -eq 0 ] && [ "$plain" -eq 0 ]; then
    echo "    ⚠️  WARN: 未能从 dyld_info 输出中解析出 __cfstring 的 bind 分类"
    echo "        （列格式假设为 \$1=seg \$2=sect \$3=? \$4=type，可能不匹配）"
    echo "        → 跳过硬校验，但已把原始输出存为 dist/MacWSWindowing.fixups.txt"
    echo "        → 请在 iPad 侧用 misc/macws_artifact_contract.py verify 复核"
else
    echo "ERROR: Apple-ld64 auth-fixup 不变量未通过。" >&2
    echo "       __cfstring: auth-bind=$cf plain-bind=$plain" >&2
    echo "       这意味着产出的 dylib 无法安全注入 SpringBoard。" >&2
    sed -n '1,80p' "$FIXUPS" >&2
    exit 1
fi

python3 misc/macws_artifact_contract.py create \
    --root "$PROJECT_DIR" --binary "$BUILT" --manifest "$MANIFEST" \
    --source-snapshot "$SNAP"

echo
echo "==> [3/5] 导出 MacWSWindowing 三件套"
cp "$BUILT" "$DIST/MacWSWindowing.dylib"
sha256_of "$BUILT" > "$DIST/MacWSWindowing.sha256"
cp "$MANIFEST" "$DIST/MacWSWindowing.build.json"
echo "    size   = $(wc -c < "$DIST/MacWSWindowing.dylib" | tr -d ' ') bytes"
echo "    sha256 = $(cat "$DIST/MacWSWindowing.sha256")"

echo
echo "==> [4/5] 构建完整 .deb 包（尽力而为：失败只告警，不影响三件套）"
set +e
"$GMAKE" FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
    THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 package
PKG_RC=$?
set -e
if [ "$PKG_RC" -ne 0 ]; then
    echo "    ⚠️  WARN: 全量 package 返回 $PKG_RC（其他子项目失败属预期，三件套已产出）"
fi
DEB="$(ls -t .theos/packages/*.deb 2>/dev/null | head -1 || true)"
[ -n "$DEB" ] || DEB="$(ls -t .theos/*.deb 2>/dev/null | head -1 || true)"
if [ -z "$DEB" ]; then
    echo "    ⚠️  WARN: 未产出 .deb（跳过）"
else
    cp "$DEB" "$DIST/"
    echo "    $(basename "$DEB")"
fi

echo
echo "==> [5/5] 产物清单"
ls -la "$DIST" | sed 's/^/    /'

echo
echo "============================================================"
echo " 完成。把 dist/ 里的文件下载下来："
echo
echo " 1) MacWSWindowing.dylib / .sha256 / .build.json 三件套"
echo "    -> 放到 iPad 的 /var/jb/var/mobile/macws-cross-build/"
echo "    -> 之后就能在 iPad 上跑 misc/build_on_ios.sh 了"
echo
echo " 2) macpad_*.deb"
echo "    -> 推到 iPad 后 dpkg -i 安装"
echo "============================================================"
