# Q9 出帧 backing 链落地方案

## 结论

现有 `surface_copy` 端点只完成“两个 IOSurface 之间的 host Metal blit”；它不会自动知道 WS 的最终帧，也不会把结果发布给 VNC。最终帧的正确接线是：WS render/update 产生 `composite_destination`（它是 **source**），将该 IOSurface 的 mach send right 复制到 host XPC；host 将它 blit 到 displayd 预分配的 destination IOSurface；displayd 把 destination 作为 VNC framebuffer。`MacWSFinalCompositeReceiver` 当前只验证/接收 WS surface，不能替代这次 copy。

## 数据流

```text
SkyLight render_update (mac_hooks.m:5728-5834)
  -> WSCompositeDestinationCreateWithMetalTexture
  -> composite_destination IOSurface (WS-owned, SRC)
  -> METAL_HOST surface_copy request (Metal_hooks.x:11850-12150; new helper)
       source_port = composite_destination
       dest_port   = displayd IOSurface
  -> MTLSimDriverHost surface_copy_serve (main.x:49-89)
       iOS Metal blit + waitUntilCompleted
  -> destination IOSurface (displayd-owned, VNC SRC)
  -> OSXvnc-server / vncdo capture
```

`composite_destination` 是 source：CBZ 只是让失败路径离开 render_update 的断言块；它没有 backing，也不是 destination。若它为空，不能发 copy 请求，必须记录丢帧并等待下一次有效 composite。

## 必改文件

1. `libmachook/Metal_hooks.x`：在 METAL_HOST 区增加同步 `surface_copy` XPC helper，连接 `com.macwsguide.blur`，发送 source/dest IOSurface mach send rights，并检查 `result == ok`。在最终 composite 成功点调用 helper；dest 由 displayd 通过现有 final-composite accepted handler 提供。不得把 CBZ epilogue 当作成功帧。
2. `macwsdisplayd/MacWSFinalCompositeReceiver.m`：accepted handler 中把接收的 WS IOSurface 复制到 displayd 的持久 framebuffer IOSurface，再通知 VNC；保留 `MarkWindowServerGraphicsReady` 作为“source 已验证”标记，新增“copy 完成”标记。
3. `MTLSimDriverHost/main.x`：现有 `surface_copy_serve` 已足够；仅需把服务注册与 blur 共用 listener 的事实固定在部署配置中，不改 blit 逻辑。
4. `libmachook/mac_hooks.m`：把 CBZ 条件从 `#if 0` 改为 `#if defined(MACWS_ENABLE_RENDER_UPDATE_CBZ)`，并以 `-DMACWS_ENABLE_RENDER_UPDATE_CBZ=1` 重编。它只保证 WS 不因空 composite 崩溃，不制造 backing。

## XPC 双份部署

- iOS 外层：`/var/jb/usr/macOS/Frameworks/MTLSimDriver.framework` 的定制 XPC 继续服务 `com.macwsguide.blur`，供 blur；其 platform=2，不能放入 chroot。
- chroot：macOS 平台 host XPC 安装到 `/usr/local/Frameworks/MTLSimDriver.framework/...`（以及 `/System/Library/PrivateFrameworks/...` 按 CI 产物布局），同样由 WindowServer plist 的 `MachServices` 注册。两个服务不能同时以同一 bootstrap namespace 注册；因此 chroot 服务应使用独立名称 `com.macwsguide.surface-copy`，并把 helper 连接字符串改为该名称。若 CI 产物只能保留 `com.macwsguide.blur`，则 iOS blur 与 chroot copy 必须由同一个 host listener 分流，不能让两个 launchd job 抢同名服务。

## 部署与回滚

1. 备份 `libmachook.dylib`、WindowServer plist、四个 launchd plist，并记录 SHA256。
2. 先部署 macOS-platform MTLSimDriver/Implementation 与 host XPC；确认 `otool -l` platform=1。
3. 部署 libmachook（含 surface-copy 接线），再启用 plist `MACWS_METAL_HOST=1`、`MACWS_AGX_NATIVE=0`、`MACWS_AGX_REGISTER_CLASSES=0`。
4. 最后部署 `macwsdisplayd`，重载 launchd jobs；失败时按相反顺序恢复备份并卸载 jobs。

## 验收

`vncdo capture` 用 PIL 检查 alpha/RGB 至少一个非零像素；连续两帧 MD5 必须不同；移动窗口后第二帧差异像素数应大于 0；日志顺序应为 `WS_COMPOSITE_PRESENTED` → `surface_copy result=ok` → `VNC_FRAME_PRESENTED`。

## 对 macOS 平台宿主组件的依赖

这是硬依赖。未部署时，`MACWS_METAL_HOST` 的 `dlopen` 在 `Metal_hooks.x:~11900` 失败，WS 无 device；即使 CBZ 打开也只有“活着但无帧”。没有 macOS-platform host XPC 时 surface_copy 无法执行，displayd 只能收到 source、VNC 仍全零。可先部署 host/主 dylib，再部署接线；CBZ 编译宏是独立前置条件。

作者级改动：若苹果 SkyLight 没有可调用的最终 composite 回调，需要在现有 `MacWSFinalCompositeReceiver` accepted handler 处接线；不应修改 SkyLight 二进制或伪造 platform。
