# Android 单 Engine 混合宿主

Flutter 根级挂载一个 VideoServiceHost，启用宿主前后台与原生窗口同步模式。业务 App 只需已有的一个 FlutterEngine。在该 Engine 完成插件注册后取得实例：

```kotlin
val rtc = engine.plugins.get(CustomerRtcPlugin::class.java) as CustomerRtcPlugin
```

在统一路由或 Application.ActivityLifecycleCallbacks 中，当独立原生 Activity、原生 WebView 或原生 Fragment 显示于 Flutter 之上，将当前 Activity 的内容根（`activity.findViewById<FrameLayout>(android.R.id.content)`）传给插件。所有方法从主线程调用。

```kotlin
rtc.attachNativeHost(contentRoot)
```

使用 Activity 内容根时，组件在同一 Window 的装饰视图上呈现通话。全屏视频和等待背景延伸到可见的状态栏与导航栏下；控件和小窗避让系统栏、屏幕开孔和键盘。宿主可继续为业务内容分发或消费 Insets。全屏期间组件临时设置系统栏透明、使用浅色图标，缩小、结束或移交时恢复原窗口配置。

也可传入宿主自定义的顶层 FrameLayout，通话覆盖范围跟随该容器。要铺满屏幕，请提供覆盖整个 Window、没有安全区 padding 的独立显示层，将业务安全区应用到其下的页面内容。若呈现在 Dialog 自己的 Window，使用 `rtc.attachNativeHost(dialogContentRoot, dialog.window)`，让系统栏配置跟随实际显示窗口。

小窗可拖动、吸边和恢复，在窗口以外仍可操作宿主页面。恢复全屏仍使用当前通话的原生画布。全屏媒体区提供静音、摄像头、音频路由、清晰度和画面恢复。实际音频路由由系统及声网决定。

页面退出时调用 `rtc.detachNativeHost(contentRoot)`。旧页面的延迟解绑会核对容器身份。不同 Activity 之间交接时可直接 attach 新根，最后一个新根取得呈现权。在 Flutter 页面返回时，目标会自动切回 Flutter 的原生视频视图。对另起 Window 的 Dialog/多窗口界面，宿主应把呈现交给实际前台 Window 的内容根。全屏收到系统返回时先调用 `rtc.handleHostBack()`；返回 true 表示已申请缩小，false 时继续宿主导航。

首个 Activity 开始显示时调用 `rtc.notifyHostForeground()`，整个 App 进入后台时调用 `rtc.notifyHostBackground()`。应由宿主识别没有任何业务 Activity 可见的时机，排除配置重建，覆盖切到独立原生 Activity 和原生 WebView 的情况。普通退后台时，插件记录 sessionId 并释放原生引擎。系统来电覆盖当前已建立会话时保留连接，拒接或漏接后恢复音频，接起系统电话则结束视频客服。事件通道暂时无订阅时，重新订阅会补发原 sessionId，Flutter 可以取得同一次 leave 的释放结果。回到前台后，旧入房请求及跨前后台的旧权限结果均不能创建引擎，新会话可正常发起。退出登录或销毁 Engine 前应 await controller.shutdown()。Activity 解绑保留已建立的 RTC 会话；若永久移除的 Activity 上还挂着首次授权请求，只结束该次未完成的授权。引擎销毁仍触发最终清理。

仓内 Demo 的 DemoApplication、MainActivity 和 NativePageActivity 展示了完整接线。首页启动“直接测试原生窗口（无媒体）”，缩小后打开原生页面，进入原生 WebView，拖动、返回、恢复，再按 Home 验证后台结束。使用独立测试频道和短期凭据可另行验证设备的真实媒体与释放。

## 原生媒体策略

Android 插件固定使用 Agora 4.6.0。所有入房均关闭音视频自动订阅。配置可信 expectedPeerUid 后只订阅该 UID；未配置时采用第一个对端并只订阅该对端。服务端负责频道准入。两轨中任一订阅失败会终止本次通话。前后摄使用 SDK 采集配置，SD 为 640×360/15fps，HD 为 1280×720/15fps，方向自适应。上报的本端/所选对端网络质量、音频路由和画布结果带会话标识。重新绑定画布使用现有引擎。

插件取得进程内 RTC 所有权后才创建声网引擎，并在旧引擎的 destroy 完成后放行下一实例。Engine 销毁与重建交错时，新的入房可能短暂返回 busy；销毁未确认会在当前进程内保留 restartRequired。权限取消发生在创建步骤之前，不占用进程级引擎。

已安装本 Demo 的 Android 模拟器可从 Demo 根目录运行 `python3 android/tests/mixed_window.py emulator-5554`。使用 `--adb <路径> --port <端口>` 可选择隔离的 ADB。脚本通过真实 UI 节点在 Flutter、原生 Activity、原生 WebView 间操作，检查小窗、拖动、返回和 Home 后空闲。它会重新启动测试包，不请求相机或麦克风。
