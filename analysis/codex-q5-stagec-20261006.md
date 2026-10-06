
## Stage-C 实现追加段（2026-10-06，未连接设备）

### 1) deployment-target 最小补丁

【已证实：背景卡给定 runtime 证据】原报错：`'registryID' is only available on iOS 11.0 or newer … but the deployment target is iOS 9.0.0`。针对这批 iOS 11 availability 错误，`MTLSimDriverHost/Makefile` 第一行增加：

```make
TARGET := iphone:clang:latest:14.0
```

放在 `common.mk` 之前；14.0 满足 11+，且与本地 macwsallocd 一致。不加 `-Werror`、`-Wno-unguarded-availability` 或 `-mmacosx-version-min`。同时控制编译与链接的部署版本，不靠关闭诊断。

【本地源码核对，不冒充真机/RE证据】本 checkout 与背景卡的“三个都没 min-version”不同：`macwsallocd/Makefile:1` 已是 `iphone:clang:latest:14.0`；`macwsdisplayd/Makefile:1` 已是 `macosx:clang:latest:13.0`，`main.m:2` 导入 AppKit。这两个文件无需修改。三者是两个 iOS 原生目标加一个 macOS/chroot 目标，不能统一强制 iphone。未改运行时代码，失败返回 nil 的既有语义不变。

【需实测】该补丁针对卡中 17 个 iOS 11 availability 诊断；本 Windows 环境没有设备 Theos/SDK，未宣称全量编译成功。现有 XPC Resources/Info.plist 写着 MinimumOSVersion=16.5，部署命令保留已在位的 bundle 元数据，不把该模板覆盖到 iOS 16.3。如果后续整包替换，须单独对齐该元数据。

### 2) 绕开守卫，仅重编三个子项目

直接子目录 `clean` 然后 `all stage`，不调用 `build_on_ios.sh`、根聚合、`package` 或 postinst，不访问 MacWSWindowing 守卫，也不重写其 manifest/hash 基线。`stage` 仅生成安装树，避开 pkgbuild。以下保存为 `/tmp/stagec-build.sh`，用 `bash` 显式运行；在设备独占窗口由操作者执行。

**真实限制：macwsdisplayd 需要 macOS SDK 与可用的 macOS target 链接工具链。** 本地 `ci/build_macws_tools_macos.sh` 也按 macosx target 构建它。没有 Mac 机器不等于有可用交叉工具链；若设备没有这些，不能承诺三个目标全在设备编出。下面先检查 SDK，缺失即停止，不先编两个再误报全成功。可在已配置的非 Mac 交叉工具链上独立编 displayd，或取得相同源码版本的可信构建产物；不得把旧缓存称作全量重编。仅刷新 stale 基线无助于此。

```bash
set -euo pipefail
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
export THEOS=/var/jb/var/mobile/theos
P=/var/jb/var/mobile/MacWSBootingGuide
cd "$P"
# 不继承根构建目录或外部 TARGET，防止串产物。
unset THEOS_PROJECT_DIR THEOS_BUILD_DIR TARGET SDKROOT
python3 - "$THEOS" <<'PY'
import glob, os, sys
sdks=glob.glob(os.path.join(sys.argv[1], 'sdks', 'MacOSX*.sdk'))
assert any(os.path.isdir(os.path.join(s, 'System/Library/Frameworks/AppKit.framework')) for s in sdks), 'STOP: macwsdisplayd needs a macOS SDK/toolchain; an iPhoneOS SDK is insufficient'
PY
# 仅修三个子目录已有 .theos 属主；不递归 chown 项目、SDK 或 rootfs。
for t in MTLSimDriverHost macwsdisplayd macwsallocd; do
  if [ -d "$t/.theos" ]; then
    sudo chown -R "$(id -u):$(id -g)" "$P/$t/.theos"
  fi
done
for t in MTLSimDriverHost macwsdisplayd macwsallocd; do
  case "$t" in
    macwsdisplayd) target=macosx:clang:latest:13.0 ;;
    *) target=iphone:clang:latest:14.0 ;;
  esac
  make -C "$t" clean TARGET="$target" ARCHS=arm64 THEOS_PACKAGE_SCHEME=rootless
  make -C "$t" all stage TARGET="$target" ARCHS=arm64 \
    FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 THEOS_PACKAGE_SCHEME=rootless
 done
# 只从 freshly-cleaned stage 取文件，不使用 find .theos/obj | head，避免取 dSYM/旧 slice。
OUT="$P/dist/stagec-hostbuild"
mkdir -p "$OUT"
python3 - "$P" "$OUT" <<'PY'
import pathlib, shutil, sys, hashlib, json
p,out=map(pathlib.Path,sys.argv[1:])
manifest={}
for t in ('MTLSimDriverHost','macwsdisplayd','macwsallocd'):
    hits=[x for x in (p/t/'.theos'/'_').rglob(t) if x.is_file()]
    if len(hits)!=1:
        raise SystemExit(f'{t}: expected exactly one staged executable, found {hits}')
    shutil.copy2(hits[0],out/t)
    manifest[t]=hashlib.sha256((out/t).read_bytes()).hexdigest()
(out/'sha256.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
```

执行：`bash /tmp/stagec-build.sh`。独立编译不需 `GO_EASY_ON_ME=1` 来掩盖 availability。若 macOS 工具链报错，停止在构建阶段；此时没有满足“三个新产物”的部署前提。

### 3) 安装、签名、trustcache、重载与判据

【路径依据】采用背景卡 §二；另据本地 postinst:949，iOS XPC 为**扁平** bundle：`.../MTLSimDriverHost.xpc/MTLSimDriverHost`，不是 `.../Contents/MacOS/`。chroot 那份按卡内嵌套路径更新。displayd 同时更新在位与 chroot；allocd 只更新 iOS 在位路径。下面只替换可执行文件，保留在位 bundle 信息和 launchd 配置，避免引入不同 run 的 dylib/manifest。

以下保存为 `/tmp/stagec-deploy.sh`，在获得独占窗口且三个产物都成功后运行 `sudo bash /tmp/stagec-deploy.sh`。不 source 全量 postinst（它有其它安装副作用）。`add_all_trustcache` 在这里是自包含同义实现：实际存在的所有 slice 均提取最终 CDHash 后注册；本构建明确只产生 arm64，因此逐片签就是签这一片，不假设有 arm64e/x86_64。

```bash
set -euo pipefail
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
[ "$(id -u)" = 0 ]
P=/var/jb/var/mobile/MacWSBootingGuide
OUT="$P/dist/stagec-hostbuild"
ENT=/var/jb/usr/macOS/bin/entitlements.plist
LDID=/var/jb/usr/bin/ldid
JBCTL=/var/jb/usr/bin/jbctl
X=/var/jb/usr/macOS/Frameworks/MTLSimDriver.framework/XPCServices/MTLSimDriverHost.xpc
CX=/var/mnt/rootfs/System/Library/PrivateFrameworks/MTLSimDriver.framework/Versions/A/XPCServices/MTLSimDriverHost.xpc
D=/var/jb/usr/macOS/LaunchDaemons/com.macwsguide.display.plist
A=/var/jb/Library/LaunchDaemons/com.macwsguide.alloc.plist
W=/var/jb/usr/macOS/LaunchDaemons/com.apple.WindowServer.plist
for f in "$ENT" "$X/Info.plist" "$CX/Contents/Info.plist" "$D" "$A" "$W"; do
  [ -s "$f" ] || { echo "STOP: missing $f" >&2; exit 1; }
done
python3 - "$OUT" <<'PY'
import pathlib,json,hashlib,sys,struct
p=pathlib.Path(sys.argv[1]); m=json.loads((p/'sha256.json').read_text())
for t in ('MTLSimDriverHost','macwsdisplayd','macwsallocd'):
    b=(p/t).read_bytes()
    assert hashlib.sha256(b).hexdigest()==m[t], t+' hash mismatch'
    assert struct.unpack_from('<II',b)==(0xfeedfacf,0x100000c), t+' must be thin arm64 Mach-O'
    assert struct.unpack_from('<I',b,12)[0]==2, t+' must be MH_EXECUTE, not dSYM'
PY
label() { python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["Label"])' "$1"; }
DL=$(label "$D"); AL=$(label "$A"); WL=$(label "$W")
# 所有前置检查在停服务之前；已注册的 job 才卸载，卸载失败立即停止。
for pair in "$WL|$W" "$DL|$D" "$AL|$A"; do
  lab=${pair%%|*}; plist=${pair#*|}
  if launchctl print "system/$lab" >/dev/null 2>&1; then
    launchctl bootout system "$plist"
  fi
done
# XPC 按需拉起，没有凭空假造一个 MTLSimDriverHost LaunchDaemon。
# 终止旧实例，下一次客户端连接才会执行新文件。
if pgrep -x MTLSimDriverHost >/dev/null; then pkill -TERM -x MTLSimDriverHost; fi
for n in 1 2 3 4 5; do
  if ! pgrep -x MTLSimDriverHost >/dev/null; then break; fi
  sleep 1
done
if pgrep -x MTLSimDriverHost >/dev/null; then
  echo 'STOP: old MTLSimDriverHost still running; keep jobs stopped' >&2; exit 1
fi
add_all_trustcache() {
  local file=$1 arch h count=0
  for arch in arm64 arm64e x86_64; do
    h=$("$LDID" -arch "$arch" -h "$file" 2>/dev/null | awk -F= '/^CDHash=/{print $2}' || true)
    [ -n "$h" ] || continue
    "$JBCTL" trustcache add "$h"
    count=$((count+1))
  done
  [ "$count" -gt 0 ] || { echo "No CDHash: $file" >&2; return 1; }
}
install_signed() {
  local src=$1 dst=$2 tmp
  tmp="${dst}.stagec-new"
  [ -d "$(dirname "$dst")" ]
  # cp 写入独立新 inode；避免截断正在使用或 bind-mounted 的旧可执行文件。
  [ ! -e "$tmp" ] || { echo "STOP: leftover $tmp" >&2; return 1; }
  cp "$src" "$tmp"
  chmod 0755 "$tmp"; chown 0:0 "$tmp"
  # 产物已校验为单片 arm64；签最终副本，然后提取其最终 CDHash。
  "$LDID" -S"$ENT" -M "$tmp"
  "$LDID" -S"$ENT" -M "$tmp"
  add_all_trustcache "$tmp"
  if [ -e "$dst" ]; then cp -p "$dst" "${dst}.stagec-backup-$(date +%Y%m%d%H%M%S)"; fi
  mv -f "$tmp" "$dst"
}
install_signed "$OUT/MTLSimDriverHost" "$X/MTLSimDriverHost"
install_signed "$OUT/MTLSimDriverHost" "$CX/Contents/MacOS/MTLSimDriverHost"
install_signed "$OUT/macwsdisplayd" /var/jb/usr/macOS/bin/macwsdisplayd
install_signed "$OUT/macwsdisplayd" /var/mnt/rootfs/usr/local/bin/macwsdisplayd
install_signed "$OUT/macwsallocd" /var/jb/usr/macOS/bin/macwsallocd
launchctl bootstrap system "$A"
launchctl bootstrap system "$D"
launchctl bootstrap system "$W"
launchctl print "system/$AL"
launchctl print "system/$DL"
launchctl print "system/$WL"
pgrep -f WindowServer
```

【需实测】任一步失败不继续启动，不宣称“接上”。安装过程中失败会留下已停的 job 和部分新副本，保留备份后排查，不自动恢复运行。若实际路径是文件级 bind mount 导致 rename 失败，同样停止，不能改用强行覆盖正在映射的 inode。这段没有执行在设备上。

前置探针按需求保留 `launchctl print system/com.macwsguide.macwsdisplayd`；但本地 `com.macwsguide.display.plist` 的 Label 是 `UIKitApplication:com.macwsguide.display`，因此还须执行 `launchctl print 'system/UIKitApplication:com.macwsguide.display'` 或以上读取在位 plist 的 `$DL`。文件名、MachService 名、Label 不等价，前一个探针单独失败不能证明服务没注册。

“宿主 XPC 真正接上”需运行中的新 MTLSimDriverHost、成功的客户端请求/回复及 frame/IOSurface 序号持续推进；进程在册、WS PID 非空只是前置条件。以同一轮 VNC 抓帧确认不是全零像素，并在窗口变化后连续帧内容发生相应变化、GlassDemo 标题栏/控件实际可见，才判 SIM 降级出画面；blur 缺失是卡中已知降级，不算完整 AGX/blur 成功。不把重编三个目标本身说成已解决所有出图阻塞。

落盘位置说明：指定的 ../macPad-port 超出本会话可写根，禁止提权；本追加段与 diff 暂存当前仓库 analysis。由外层可写终端执行以下 PowerShell 完成指定落点（追加，不覆盖旧报告）：

```powershell
Get-Content -Raw -Encoding UTF8 .\analysis\codex-q5-stagec-20261006.md | Add-Content -Encoding UTF8 ..\macPad-port\analysis\codex-q5-stagec-20261006.md
Copy-Item .\analysis\codex-stagec-hostbuild.diff ..\macPad-port\analysis\codex-stagec-hostbuild.diff
```

①编译命令(3宿主target)：`bash /tmp/stagec-build.sh`；DriverHost/allocd=iOS14，displayd=macOS13，缺 macOS SDK/工具链则停止，不能声称全量重编成功。
②部署+签+trust步骤：`sudo bash /tmp/stagec-deploy.sh`；停相关 job/旧 XPC→五个路径安装→arm64 ldid→add_all_trustcache→bootstrap alloc/display/WS。
③“宿主XPC接上+出SIM降级画面”判据：`launchctl print system/com.macwsguide.macwsdisplayd`（兼查在位真实 Label）在册＋`pgrep -f WindowServer`非空＋XPC成功往返/帧序号推进＋VNC非全零且随窗口更新；blur无=已知降级。
