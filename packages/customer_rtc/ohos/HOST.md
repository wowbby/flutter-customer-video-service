# 鸿蒙 App 内跨页面通话窗

同一进程、同一 FlutterEngine 和同一个 customer_rtc 插件管理本次通话。在宿主的原生导航顶层挂载 CustomerRtcOverlay，将 Flutter 控制器的生命周期来源设为原生宿主。Flutter 页面继续使用 VideoServiceHost。原生业务页或内含 ArkWeb 的页面复用同一个通话引擎。挂载的 XComponent 准备就绪后会接管对应画布，移除后会恢复 Flutter 画布。SDK、UI、真实媒体分别验收。

```ts
import { CustomerRtcHost, CustomerRtcOverlay } from 'customer_rtc';

@Entry
@Component
struct BusinessRoot {
  onBackPress(): boolean { return CustomerRtcHost.shared.back(); }
  build() {
    Stack() {
      // 在此放置宿主原生导航容器，含 WebView 的业务页也放入同一容器。
      Column() { Text('业务首页') }.width('100%').height('100%')
      CustomerRtcOverlay()
    }.width('100%').height('100%')
  }
}
```

通话全屏时，等待背景和视频延伸到系统栏下方。ArkUI 通话控件按当前窗口的系统栏、挖孔和键盘避让区布局。状态栏和系统导航保持可见。切为小窗、结束通话或解绑 Ability 时，插件恢复进入全屏前的窗口布局与系统栏样式。宿主应保留系统状态栏和导航指示器，并将原生浮层放在可覆盖至窗口边缘的顶层 Stack。给业务内容单独设置所需的安全边距；如果父容器已经裁剪到安全区，浮层无法延伸到屏幕边缘。

使用 FlutterPage 的宿主（含纯 Flutter、Flutter 内嵌 H5 和混合导航）应将通话全屏状态传给 FlutterPage 及其顶层容器。以下示例适用于默认按系统安全区布局的页面。已有自定义安全区配置的宿主，在小窗和空闲状态使用原页面的配置。Flutter 引擎通过 MediaQuery 上报物理安全区和键盘高度。

```ts
import { window } from '@kit.ArkUI';
import { FlutterPage } from '@ohos/flutter_ohos';
import { CustomerRtcHost } from 'customer_rtc';

// Flutter 宿主页面的成员；viewId 沿用宿主现有的 Flutter 视图 ID。
@State private callFull: boolean = false;
private stopObserving?: () => void;
aboutToAppear(): void {
  this.stopObserving = CustomerRtcHost.shared.observeFullscreen((full: boolean, nativeWindow?: window.Window) => {
    this.callFull = full && !nativeWindow;
  });
}
aboutToDisappear(): void { this.stopObserving?.(); }
build() {
  Column() {
    FlutterPage({ viewId: this.viewId,
      safeAreaTypes: this.callFull ? [SafeAreaType.SYSTEM, SafeAreaType.CUTOUT] : [],
      safeAreaEdges: this.callFull ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END] : []
    })
  }.width('100%').height('100%').expandSafeArea(
    this.callFull ? [SafeAreaType.SYSTEM, SafeAreaType.CUTOUT] : [],
    this.callFull ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END] : [])
}
```

主窗口负责系统栏配色，实际承载全屏通话的窗口负责布局。组件通过自身 UIContext 定位所属窗口。将 CustomerRtcOverlay 放在独立子窗中时，组件记录并恢复子窗原有的全屏布局，将系统栏配色的保存与恢复交给主窗。

前台只挂载一个原生呈现入口。多窗口或多个独立原生容器的宿主，在当前可见的顶层容器挂载，切回 Flutter 后卸载。组件按会话和宿主实例过滤过期的动作与画布回调。挂载范围决定覆盖范围。小窗保留窗口外的页面点击、滚动和输入。

进程前后台回调应在宿主初始化时注册一次，在对应宿主销毁时解除。Demo 的 EntryAbility 含可编译示例。普通退后台时，插件取消当前原生入房或释放引擎，并通知 Flutter 挂断。系统来电覆盖已建立会话时保留连接；拒接或漏接后恢复音频，接起系统电话时立即挂断客服。所属宿主 Ability 永久销毁时调用 `CustomerRtcHost.shared.destroy()` 清理。等待凭据、授权中和无媒体探针也按当前会话标识处理。事件监听晚于后台通知时，插件在监听建立后补发；同一后台周期和会话只投递一次。进入后台后，即使用户很快返回，原授权回调也无法重新入房。Ability 解绑时保留已创建的 RTC 引擎，作废尚在授权的入房请求。Engine 销毁时释放底层资源。进程级租约会持续到异步销毁完成，销毁失败后组件提示重启 App。

```ts
import { ApplicationStateChangeCallback } from '@kit.AbilityKit';
import { CustomerRtcHost } from 'customer_rtc';

// 放入宿主 Ability 的成员定义。初始化和销毁时分别订阅和退订。
private appLifecycle: ApplicationStateChangeCallback = {
  onApplicationForeground: () => CustomerRtcHost.shared.foreground(),
  onApplicationBackground: () => CustomerRtcHost.shared.background()
};
// this.context.getApplicationContext().on('applicationStateChange', this.appLifecycle);
// this.context.getApplicationContext().off('applicationStateChange', this.appLifecycle);
```

原生窗可拖动、小窗吸边、切换全屏、挂断，显示本端和对端弱网。全屏时可静音、开关/翻转摄像头、切换扬声器、标清和高清。画布绑定异常可重绑。等待凭据或原生命令进行中时控件根据可用状态禁用。需重启时显示相应指引。原生音视频初始关闭自动订阅，只订阅首个符合 expectedPeerUid 条件的成员。业务凭据明确坐席身份时应提供该 UID。所选成员离开时分别取消其音视频订阅并解除旧画布绑定。部分订阅失败会立即结束本次通话。主相机、本地录音与选中对端视频的轨道状态来自 SDK。4.4.2 HAR 没有暴露路由变化委托，插件在 RTC 统计回调中查询系统通信音频输出设备；无法区分时回传 other。

在引用本目录的宿主或 CI 中执行 `./tool/setup_sdk.sh`（从本目录运行）。脚本安装并校验固定版本 4.4.2 HAR。然后使用宿主现有签名流程构建。包版本 0.3.0。

验证命令为 `node tests/cleanup_policy_test.cjs` 和 `node tests/plugin_contract_test.cjs`，前者校验异步销毁，后者运行实际插件控制流程并替换平台与声网边界。混合宿主 Demo 的 `rtc_demo/mixed_host` 频道提供 `openNativePage`，可从 Flutter 切换到独立 ArkUI 页与其内的本地 WebView，再返回 Flutter。实际画面连续性、音频路由以及系统相机释放需在已签名设备上验证。

指定初始镜头时，鸿蒙组件在启用摄像头前请求 1280 × 720、15 fps 的采集格式。固定版声网 SDK 4.4.2 要求在开启本地视频前配置采集。通话中标清使用 640 × 360 编码，高清使用 1280 × 720 编码，切换时沿用当前镜头和采集会话。标清模式也请求 720p 采集，实际画面取决于设备、SDK 和网络。省略初始镜头时沿用 SDK 的自动采集配置。
