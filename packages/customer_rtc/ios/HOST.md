# iOS 混合宿主接入

宿主保留单个 FlutterEngine，使用 `GeneratedPluginRegistrant.register(with: engine)` 注册插件。Flutter 侧控制器选择 `CallLifecycleSource.nativeHost`。原生页面可以使用组件提供的导航控制器，并从同一个 Engine 取得已注册的插件实例。

```swift
import customer_rtc

let rtc = engine.valuePublished(byPlugin: "CustomerRtcPlugin") as? CustomerRtcPlugin
let nativeNavigationController = CustomerRtcNavigationController(rootViewController: businessPage)
nativeNavigationController.modalPresentationStyle = .fullScreen
present(nativeNavigationController, animated: true) { [weak nativeNavigationController] in
    guard let navigation = nativeNavigationController else { return }
    rtc?.attachPresentation(to: navigation.view) { [weak navigation] fullScreen in
        navigation?.showsFullScreenCall = fullScreen
    }
}
```

在宿主原生导航入口挂载一次。传入该导航栈最上层、随栈一起调整尺寸的容器，例如 UINavigationController.view。栈内 push 原生控制器和 WKWebView 时可以共用该窗口。若新模态页面位于这个容器之上，在宿主统一的模态切换处将展示移至模态容器；对应的回调使用原容器作为参数，不会移除后续接管的窗口。

视频和等待背景会铺满这个容器，顶部按钮、底部操作区及悬浮小窗按容器的安全区布局。全屏通话期间，`CustomerRtcNavigationController` 使用浅色状态栏图标，保持状态栏和 Home 指示条可见。缩小、结束或移除全屏通话后，控制器恢复宿主原有的外观策略。

已有导航控制器可以继续使用 `attachPresentation(to:onFullScreenChanged:)`，在回调里根据 `fullScreen` 更新自己的状态栏和 Home 指示条策略，并调用 `setNeedsStatusBarAppearanceUpdate()`、`setNeedsUpdateOfHomeIndicatorAutoHidden()`。回调会立即告知当前状态，随后在全屏状态改变时通知；闭包弱引用导航控制器即可。仅使用 `attachPresentation(to:)` 会沿用宿主当前的系统栏配置。

```swift
// 关闭覆盖 Flutter 的原生导航栈时
if rtc?.handlePresentationBack() == true { return }  // 全屏返回先缩小
rtc?.detachPresentation(from: nativeNavigationController.view)
nativeNavigationController.dismiss(animated: true)
```

所有这些 API 在主线程调用。窗口复用当前 SDK 会话和视频流，原生窗口内提供画面、弱网提示、缩放、拖动和挂断。真实通话全屏还支持静音、开关与切换摄像头、音频输出、标清/高清，并在画布失败时展示“恢复画面”。媒体就绪后由同一 Flutter 控制器执行这些操作，横屏或窄宽度可横向滚动控制栏。全屏时 VoiceOver 的导航范围限制在通话浮层内。小窗外的点击和读屏导航由业务页处理。宿主提供 tokenProvider 后，续期失败时可在原生全屏窗口点「重试通话授权」。移除原生窗口会将画布切回当前 Flutter PlatformView。Flutter 侧 `VideoServiceHost` 持续挂在根节点。

宿主判定整个 App 已进入后台时调用 `rtc?.hostDidEnterBackground()`，回到前台时调用 `rtc?.hostDidEnterForeground()`。单 Scene Demo 在对应 SceneDelegate 中调用。多 Scene 宿主先聚合可见 Scene。

系统来电响铃覆盖已建立的会话时，插件保留连接至用户接起系统电话或主动挂断。普通退后台时，插件释放当前 RTC 资源，并将通知关联到原 sessionId。如果 Flutter 此时尚未订阅，即使用户迅速回到前台，插件仍会在恢复订阅时补发一次。后台期间收到的会话快照也会触发相同处理。已跨后台的会话无法凭迟到的凭据或权限回调入房，原生 `join` 返回 `host_background`。用户回到前台后可以发起新会话。RTC 引擎在后台串行队列销毁，重复的挂断请求等待同一次销毁完成。退出账号或主动销毁 Engine 前，由 owner 等待 `controller.shutdown()`。插件同时注册 Engine 解绑回调以处理异常销毁。

原生侧在入房参数中关闭全部自动订阅；有 expectedPeerUid 时只订阅该 UID，无指定值时订阅首个选中成员。失败时回退订阅、报告会话错误并释放。SD 目标为 640×360、HD 为 1280×720，帧率均为 15 fps，实际传输与渲染受 SDK、网络及设备能力影响。画布绑定失败会上报角色与 SDK 数字错误码，宿主可调用控制器的重绑命令。

Demo 的原生入口和真实 Scene 回调见 完整 Demo 中的 `ios/Runner/AppDelegate.swift`。由 Flutter 发起探针或通话并缩小后，打开 Demo 原生页、进入原生 H5、返回，观察窗口状态及响应；真机媒体验收另核对声音、首帧、切页连续性和最终资源释放。
