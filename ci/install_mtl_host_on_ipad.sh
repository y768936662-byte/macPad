#!/bin/bash
# ============================================================
# 把 CI 产物（dist/mtl-host-macos/）部署到 iPad chroot 的 macOS 平台宿主组件。
# 在 PC 上跑：bash install_mtl_host_on_ipad.sh [--ssh user@host]
#
# 前置：dist/mtl-host-macos/ 下有 CI 下载的 MTLSimDriverHost（macOS 平台）。
# 部署位置（Q7 §C:203 + 设备实测确认）：
#   chroot: /var/mnt/rootfs/System/Library/PrivateFrameworks/MTLSimDriver.framework/Versions/A/XPCServices/MTLSimDriverHost.xpc/Contents/MacOS/MTLSimDriverHost
#   （外层 /var/jb/... iOS 版不动，blur 服务继续由外层提供）
#
# mach service：com.macwsguide.blur 由 WS plist MachServices 发布，
# chroot 侧 launchd 从 §C:203 解析 → 无需额外注册。
#
# 每步备份，可整体回滚（回滚 = 恢复 .bak 或删新文件）。
# 红线：不动外层 iOS 版；不碰内核/AMFI；trustcache 只 add 不 clear。
# ============================================================
set -euo pipefail

SSH_TARGET="${SSH_TARGET:-mobile@100.120.14.103}"
SSH_KEY="${SSH_KEY:-$(cd "$(dirname "$0")/../.." && pwd)/.workbuddy/keys/ipad_ed25519}"
DIST="$(cd "$(dirname "$0")" && pwd)"
CHROOT_XPC_DIR="/var/mnt/rootfs/System/Library/PrivateFrameworks/MTLSimDriver.framework/Versions/A/XPCServices/MTLSimDriverHost.xpc/Contents/MacOS"
STAMP="$(date +%Y%m%d_%H%M%S)"

[ -f "$DIST/MTLSimDriverHost" ] || { echo "缺 $DIST/MTLSimDriverHost（先从 CI artifact 下载）" >&2; exit 1; }

ssh_cmd() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$SSH_TARGET" "$@"
}

echo "==> [0/5] 门禁检查（GUI=0 / BUILD=0 才动设备）"
GATE=$(ssh_cmd 'ps aux | grep -c "[m]acos_gui.sh\|[b]uild_on_ios" || true')
echo "    gui/build procs = $GATE"
[ "$GATE" = "0" ] || { echo "    设备被占用，退让。稍后再试。" >&2; exit 2; }

echo "==> [1/5] 上传 macOS 平台 XPC（base64 通道，iOS 无 sftp）"
B64=$(base64 -w0 "$DIST/MTLSimDriverHost")
sha_src=$(sha256sum "$DIST/MTLSimDriverHost" | cut -c1-8)
ssh_cmd "echo $B64 | base64 -d > /tmp/mtlhost.macos.$STAMP"
sha_dst=$(ssh_cmd "sha256sum /tmp/mtlhost.macos.$STAMP | cut -c1-8")
[ "$sha_src" = "$sha_dst" ] || { echo "    SHA 不匹配 $sha_src vs $sha_dst" >&2; exit 1; }
echo "    上传 OK sha8=$sha_dst"

echo "==> [2/5] 备份 chroot 在位 XPC（若有）"
ssh_cmd "
  echo q | sudo -S sh -c '
    if [ -f \"$CHROOT_XPC_DIR/MTLSimDriverHost\" ]; then
      cp -p \"$CHROOT_XPC_DIR/MTLSimDriverHost\" \"/tmp/mtlhost.chroot.bak.$STAMP\"
      echo \"    已备份 -> /tmp/mtlhost.chroot.bak.$STAMP\"
    else
      echo \"    在位无文件（首次部署）\"
    fi
  '
"

echo "==> [3/5] 部署到 chroot §C:203 + 属主/权限"
ssh_cmd "
  echo q | sudo -S sh -c '
    mkdir -p \"$CHROOT_XPC_DIR\"
    cp /tmp/mtlhost.macos.$STAMP \"$CHROOT_XPC_DIR/MTLSimDriverHost\"
    chown root:wheel \"$CHROOT_XPC_DIR/MTLSimDriverHost\"
    chmod 755 \"$CHROOT_XPC_DIR/MTLSimDriverHost\"
    ldid -S /var/jb/usr/macOS/bin/entitlements.plist \"$CHROOT_XPC_DIR/MTLSimDriverHost\" 2>/dev/null || ldid -S \"$CHROOT_XPC_DIR/MTLSimDriverHost\"
    otool -l \"$CHROOT_XPC_DIR/MTLSimDriverHost\" | grep -A2 LC_BUILD_VERSION | head -4
  '
"

echo "==> [4/5] trustcache add（只加不清）"
ssh_cmd "echo q | sudo -S /var/jb/usr/bin/jbctl trustcache add \"$CHROOT_XPC_DIR/MTLSimDriverHost\" 2>&1 | tail -2"

echo "==> [5/5] 清理临时文件"
ssh_cmd "rm -f /tmp/mtlhost.macos.$STAMP"

echo "完成。验收（下轮 GUI 起）：vncdo capture + PIL nonblack + 移动窗口二帧差异。"
echo "回滚：sudo cp /tmp/mtlhost.chroot.bak.$STAMP $CHROOT_XPC_DIR/MTLSimDriverHost && jbctl trustcache add <同路径>"
