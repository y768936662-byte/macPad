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
echo "==> [4/5] 构建完整 .deb 包"
echo "    注：全量 package 允许非零返回，但关键组件会逐项硬校验（见下）"
# 这段必须彻底隔离：三件套此刻已经落盘，任何意外（未定义变量、子项目编译失败）
# 都不允许把整个运行拖成失败。set +u 也一并关掉，避免再犯 locale/变量名类问题。
set +eu
"$GMAKE" FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
    THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 package
PKG_RC=$?
set -eu
if [ "$PKG_RC" -ne 0 ]; then
    echo "    ⚠️  WARN: 全量 package 返回 ${PKG_RC}（逐项校验见下）"
fi
# 注意：变量引用后紧跟非 ASCII（中文）时必须写成 ${VAR}。
# CI 的 shell 常是 C/POSIX locale，多字节字符的首字节会被并进变量名，
# 触发 "PKG_RC?: unbound variable" 而让 set -u 直接终止脚本。
#
# MTLCompilerBypassOSCheck 必须产出：它承载 iPadOS 16.5.1 的
# libGPUCompilerImpl / libComposeFilters / libLLVM UUID 与指令签名适配
# （见 macPad-port/12_Phase2_UUID重算与补丁.md），缺了它 GPU 着色器编译
# 这一路不成立。历史上它曾因 CI 混入 iPhoneOS17.5 SDK 而编译失败
#   Tweak.x:21  error: conflicting types for 'xpc_data_create'
#   Tweak.x:848 / :893  implicit conversion of 'xpc_object_t' to 'void *'
# 当时被误判为"预期失败"而绕过，造成 CI 绿灯但产物残缺。现改为硬断言。
MTL_OBJ=""
for cand in "$PROJECT_DIR/.theos/obj/MTLCompilerBypassOSCheck.dylib" \
            "$PROJECT_DIR/.theos/obj/arm64/MTLCompilerBypassOSCheck.dylib" \
            "$PROJECT_DIR"/.theos/obj/*/MTLCompilerBypassOSCheck.dylib; do
    [ -f "$cand" ] && MTL_OBJ="$cand" && break
done
if [ -z "$MTL_OBJ" ]; then
    echo "ERROR: MTLCompilerBypassOSCheck.dylib 未产出" >&2
    echo "       该组件为 iPadOS 16.5.1 适配所必需，不允许缺失。" >&2
    echo "       首要排查：CI 是否只使用 iPhoneOS16.5.sdk（不能混入 17.x）。" >&2
    exit 1
fi
echo "    ✓ MTLCompilerBypassOSCheck.dylib $(wc -c < "$MTL_OBJ" | tr -d ' ') bytes"
echo "      path = $MTL_OBJ"
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
