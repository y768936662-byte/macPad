#!/bin/bash
# 在 iPad 上运行：把 Mac/CI 编好的 5 个 macws 工具装入 /var/jb/usr/macOS/bin/
# 并拷进 chroot、重签、trustcache，然后（可选）拉起桌面。
# 前提：与本脚本同目录放着 5 个工具 + macws-tools.build.json（Mac 侧 build 产物）。
# 用法（iPad 上，root）：
#   sudo bash install_macws_tools_on_ipad.sh [pkg_dir]
#   之后：sudo bash /var/jb/usr/macOS/bin/macos_gui.sh production
set -u
PKG_DIR="${1:-$(cd "$(dirname "$0")" && pwd)}"
JB=/var/jb/usr/macOS/bin
ROOTFS=/var/mnt/rootfs
ENT="$JB/entitlements.plist"
# 注意：设备端 postinst/configure_terminal_cli 用连字符名 macws-neofetch（装 /usr/local/bin/macws-neofetch），
# 其余 4 个不带连字符。与 CI 产物名一致。
TOOLS="macwsdisplayd macwsinputd macwsinteropd macwsworkspacectl macws-neofetch"
MAN="$PKG_DIR/macws-tools.build.json"

say(){ printf '%s\n' "$*"; }
fail(){ say "ERROR: $*"; exit 1; }

[ "$(id -u)" = 0 ] || { say "必须 root（sudo）运行"; exit 1; }

# 校验（若提供 manifest）
if [ -f "$MAN" ]; then
  say "==> 校验 5 个工具哈希（manifest: $MAN）"
  ok=1
  for t in $TOOLS; do
    exp=$(/var/jb/usr/bin/python3 -c "import json,sys;d=json.load(open('$MAN'));print(d['tools'].get('$t',{}).get('sha256',''))" 2>/dev/null)
    [ -n "$exp" ] || { say "  manifest 缺 $t，跳过校验"; continue; }
    f="$PKG_DIR/$t"; [ -f "$f" ] || { say "  缺文件 $t"; ok=0; continue; }
    act=$(/var/jb/usr/bin/python3 -c "import hashlib;print(hashlib.sha256(open('$f','rb').read()).hexdigest())")
    [ "$exp" = "$act" ] && say "  OK  $t" || { say "  HASH MISMATCH $t（期望 ${exp:0:12} 实际 ${act:0:12}）"; ok=0; }
  done
  [ "$ok" = 1 ] || fail "哈希校验未通过，中止（不装坏件）"
fi

say "==> 装入 $JB/ + 拷进 chroot + 重签 + trustcache"
for t in $TOOLS; do
  f="$PKG_DIR/$t"; [ -f "$f" ] || { say "  跳过（缺）$t"; continue; }
  # 新鲜 inode（避免 AMFI 陈旧 vnode 签名）
  rm -f "$JB/$t"
  install -m 0755 "$f" "$JB/$t"
  ldid -S "$ENT" -M "$JB/$t" 2>/dev/null || ldid -S "$JB/$t" 2>/dev/null || true
  # 两架构 cdhash 进 trustcache
  for a in arm64 arm64e; do
    H=$(/var/jb/usr/bin/ldid -arch $a -h "$JB/$t" 2>/dev/null | grep -oE 'CDHash=[0-9a-f]+' | cut -d= -f2)
    [ -n "$H" ] && /var/jb/usr/bin/jbctl trustcache add "$H" >/dev/null 2>&1
  done
  # 拷进 chroot 的 /usr/local/bin（postinst 的 bridge copy 模型）
  rm -f "$ROOTFS/usr/local/bin/$t"
  cp -f "$JB/$t" "$ROOTFS/usr/local/bin/$t" 2>/dev/null || true
  chmod 0755 "$ROOTFS/usr/local/bin/$t" 2>/dev/null || true
  for a in arm64 arm64e; do
    H=$(/var/jb/usr/bin/ldid -arch $a -h "$ROOTFS/usr/local/bin/$t" 2>/dev/null | grep -oE 'CDHash=[0-9a-f]+' | cut -d= -f2)
    [ -n "$H" ] && /var/jb/usr/bin/jbctl trustcache add "$H" >/dev/null 2>&1
  done
  say "  installed $t"
done

say "==> 完成。现在验证并点亮桌面："
say "   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh production"
say "   （若 macOS 进程仍因 dyld 共享缓存平台门槛起不来，见 18_进度与交接 的阻塞②）"
