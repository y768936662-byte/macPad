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
echo
echo "==> [1b/5] 额外构建 5 个 macOS-SDK 工具（macwsdisplayd/inputd/interopd/workspacectl/neofetch）"
# 这些工具 Makefile 是 TARGET:=macosx（链 AppKit/QuickLookThumbnailing），设备 Theos 编不了，
# 所以在 macOS runner 上编好、落进 dist/macws-tools/，随本 artifact 的 dist/ 一起上传。
# 只依赖 macOS SDK，与下面的 dylib/.deb 主链无关；单个失败不影响主产物（set +e 包裹）。
set +e
if bash ci/build_macws_tools_macos.sh; then
    echo "    已产出 dist/macws-tools/"
else
    echo "    [WARN] 5 工具构建失败（非致命）。"
fi
set -e
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

# dyld_info -fixups 的真实列格式（macOS 14 / Xcode 15 实测）：
#     seg          sect        addr      type   target (div=0x… ad=1 key=DA)
#     __DATA_CONST __cfstring 0x0184C8  bind   CoreFoundation/___CFConstantStringClassReference (div=… ad=1 key=DA)
# 第 4 字段只有 bind / rebase，认证信息写在**行尾括号**里。
# 早期版本按 $4 == "auth-bind" 匹配，该字面量并不存在 → 恒为 0，
# 把一次完全合格的构建误判成失败（Run #1 的假失败）。
#
# 只对带认证语义的段做强校验，其余段的普通 bind（如 __got 里的
# _CGRectZero / __NSConcreteStackBlock，__objc_classrefs 里的
# _OBJC_CLASS_$_NSString）是 ld64 的正常输出，不能当失败。
n_bind=$(awk '$4 == "bind" { c++ } END { print c+0 }' "$FIXUPS")
n_rebase=$(awk '$4 == "rebase" { c++ } END { print c+0 }' "$FIXUPS")
cf_bind=$(awk '$2 == "__cfstring" && $4 == "bind" { c++ } END { print c+0 }' "$FIXUPS")
cf_auth=$(awk '$2 == "__cfstring" && $4 == "bind" && /ad=1/ && /key=DA/ { c++ } END { print c+0 }' "$FIXUPS")
cf_plain=$(awk '$2 == "__cfstring" && $4 == "bind" && !/ad=1/ { c++ } END { print c+0 }' "$FIXUPS")
ag_bind=$(awk '$2 == "__auth_got" && $4 == "bind" { c++ } END { print c+0 }' "$FIXUPS")
ag_auth=$(awk '$2 == "__auth_got" && $4 == "bind" && /ad=1/ { c++ } END { print c+0 }' "$FIXUPS")
other_plain=$(awk '$4 == "bind" && !/ad=1/ && $2 != "__cfstring" && $2 != "__auth_got" { c++ } END { print c+0 }' "$FIXUPS")
echo "    fixups 条目: bind=$n_bind rebase=$n_rebase"
echo "    __cfstring: bind=$cf_bind  ad=1/key=DA=$cf_auth  未认证=$cf_plain"
echo "    __auth_got: bind=$ag_bind  ad=1=$ag_auth"
echo "    其他段普通 bind（正常）: $other_plain"

if [ "$n_bind" -eq 0 ] && [ "$n_rebase" -eq 0 ]; then
    echo "    ⚠️  WARN: dyld_info 输出一个条目都没解析出来，格式可能与预期不同"
    echo "        → 跳过硬校验；原始输出已存为 dist/MacWSWindowing.fixups.txt"
    echo "        → 请在 iPad 侧用 misc/macws_artifact_contract.py verify 复核"
elif [ "$cf_bind" -ge 1 ] && [ "$cf_auth" -eq "$cf_bind" ] && \
     [ "$ag_bind" -ge 1 ] && [ "$ag_auth" -eq "$ag_bind" ]; then
    echo "    ✅ auth-fixup 不变量通过：__cfstring / __auth_got 全部为认证指针"
else
    echo "ERROR: Apple-ld64 auth-fixup 不变量未通过。" >&2
    echo "       __cfstring bind=$cf_bind 已认证=$cf_auth 未认证=$cf_plain" >&2
    echo "       __auth_got bind=$ag_bind 已认证=$ag_auth" >&2
    echo "       这意味着产出的 dylib 无法安全注入 SpringBoard。" >&2
    sed -n '1,40p' "$FIXUPS" >&2
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
