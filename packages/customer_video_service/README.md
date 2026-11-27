# customer_video_service

可复用的视频客服 Flutter 组件，宿主只依赖此包。底层 `customer_rtc` 自封装 Android、iOS、HarmonyOS 声网原生 SDK；Flutter 管理会话，独立原生页面可接管窗口呈现，视频帧留在原生侧。

当前为内部 path 依赖组件 0.3.0，两个包须同步升级。验证工具链为项目固定的 Flutter OHOS 3.27.5-ohos-1.0.8 / Dart 3.6.2；底层包含 OHOS 平台类型，**未声明标准 Flutter SDK 兼容**。复制或引用时须保留两个包的相对位置。原生实现只支持一个活动 FlutterEngine / 一个活动会话，不支持多 Engine 同时接入。

## 宿主接入

```yaml
dependencies:
  customer_video_service:
    path: ../rtc_demo/packages/customer_video_service
```

```dart
import 'package:customer_video_service/customer_video_service.dart';

// 在 App/FlutterEngine 生命周期创建一次，不能随业务页面反复创建。
final controller = VideoServiceController(
  lifecycleSource: CallLifecycleSource.nativeHost,
  mediaOptions: const CallMediaOptions(cameraFacing: CameraFacing.rear,
      videoQuality: VideoQuality.hd, primaryVideo: VideoRole.local),
  credentialsProvider: (context) async {
    // 由宿主的已登录服务获取短期参数；不要在 H5 或客户端生成 Token。
    return await credentialService.fetchCallCredentials(context);
  },
  tokenProvider: (context, identity) async {
    return await credentialService.refreshToken(context, identity);
  },
);
final bridge = CustomerH5Bridge(
  controller: controller,
  onOpenBusiness: () { navigatorKey.currentState!.push(businessRoute()); },
);

MaterialApp(
  navigatorKey: navigatorKey,
  builder: (_, child) => VideoServiceHost(
    controller: controller,
    options: const CallWindowOptions(miniSize: Size(190, 250)),
    child: child!,
  ),
  home: VideoServiceBackScope(controller: controller, child: HomePage()),
);
```

上例的凭据服务与路由由宿主实现，组件不包含业务后端。`CallCredentials` 包含 `appId/channel/uid/token`；`CallIdentity` 仅供宿主续期回调识别当前通话，不传给 H5。宿主负责原生摄像头/麦克风权限声明、用途说明和构建签名，参考根工程三端配置。只在根级挂载一个 `VideoServiceHost`，每个会收到返回操作的业务路由包裹 `VideoServiceBackScope`：全屏先缩小，小窗允许正常返回。

## 混合宿主接入 0.3.0

产品要求覆盖所有 App 业务页。宿主在 Flutter 根节点和独立原生导航容器的顶层各接一次，将当前可见容器交给同一组件。原生容器中的 H5 随其容器覆盖。另起 Activity、模态窗口或独立导航栈时，在宿主统一路由入口交接展示。普通页面无需维护白名单。宿主继续使用现有横竖屏策略。

| 当前顶层容器 | 接入方式 |
| --- | --- |
| Flutter 路由及其内嵌 WebView | 根节点挂载 `VideoServiceHost`，路由返回接 `VideoServiceBackScope`。 |
| Android 独立原生容器 | 挂载当前可见根布局并转发返回、App 前后台。[Android 接线示例](../customer_rtc/android/HOST.md) |
| iOS 原生导航及 WKWebView | 将呈现交给导航或模态容器，转发所属宿主前后台。[iOS 接线示例](../customer_rtc/ios/HOST.md) |
| 鸿蒙 ArkUI 及 ArkWeb | 顶层 Stack 挂载 CustomerRtcOverlay，注册应用前后台回调。[鸿蒙接线示例](../customer_rtc/ohos/HOST.md) |

全屏通话和等待接听时，背景铺到状态栏和底部导航区域后方，系统时间、信号和手势指示保持可见。缩小、清晰度菜单及底部操作按钮按当前窗口的安全区布局，键盘打开时控件随可用空间上移。缩小或挂断后，业务页重新使用自己的系统栏样式，小窗也会避开系统栏与键盘。Flutter 全屏通话暂时隔离业务页的输入焦点和读屏导航；缩小后可继续操作原页面。

请将 `VideoServiceHost` 放在 `MaterialApp.builder` 的根级，业务页的 `SafeArea` 放在它内部。独立原生宿主需提供覆盖完整窗口的容器。Android 宿主保留业务根节点原有的 Insets 处理；iOS 原生导航使用全屏状态回调切换系统栏外观；鸿蒙的 FlutterPage 入口按通话状态扩展系统安全区。对应接线见上表。

上例启用 `nativeHost`，适用于以上混合宿主。切换容器只交接画布，真实 App 进入后台由宿主上报。纯 Flutter 宿主可沿用默认 `CallLifecycleSource.flutter`。必须在后台结束策略的对应平台接线完成后启用原生模式。

### 系统电话和视频客服

`startCall` 在取凭据前查询系统电话状态，原生端在启动音视频前复查。已知占线时抛出 `CallErrorCode.systemCallBusy`，组件提示「当前正在通话，请结束后再试」。H5 错误响应同时包含稳定的 `error` 代码与可展示的 `message`。Android 在首次需要时申请可选的 `READ_PHONE_STATE` 权限；用户拒绝或系统不能读取状态时继续按音视频权限发起，电话冲突识别能力受限。

宿主处理新的来电邀请时可以先 `await controller.checkSystemCallAvailable()`，对已有组件会话的本地接听使用 `await controller.acceptCall(sessionId: id)`，成功后再通知业务端接听。远端坐席的既有接听信令继续使用 `updateBusinessState`。占线时由宿主向业务服务回忙。

已建立的会话遇到响铃时，宿主通过 `state.systemCallRinging` 观察临时中断。拒接或未接保留会话，组件恢复此前的麦克风和输出设置。用户接起系统电话时，组件释放音视频；宿主从 `ended` 获取 `CallEndReason.systemCall` 并同步坐席。该原因也可出现在入房前被拦截的摘要中，此时 `error.code` 为 `systemCallBusy`。应用自身普通退后台仍按 `background` 结束；鸿蒙宿主在所属 Ability 销毁时调用 `CustomerRtcHost.shared.destroy()`。

`CallMediaOptions` 可独立配置主画面、初始摄像头与清晰度。上例按本 Demo 选择本地主画面、后摄、高清。省略时，组件沿用远端主画面及 SDK 采集和编码默认值。标清目标 640×360，高清目标 1280×720，均为 15 fps。

由服务端确定坐席 UID 时，由凭据 provider 填入 `CallCredentials.expectedPeerUid`。三个原生插件都关闭自动音视频订阅，只订阅指定成员；未指定时选取第一个对端。频道准入和坐席身份仍由宿主服务提供。

`state.media.controlsReady` 表示原生已接受入房、可执行媒体命令。等待授权或凭据期间，控件禁用。用 `setVideoQuality` 切换编码目标，画布故障可调用 `retryVideoBinding()`。释放结果要求重启时由窗口提示用户重启 App。Flutter 控制区和提示区分别可由 `CallWindowOptions.controlsBuilder`、`noticeBuilder` 扩展，builder 收到控制器及默认控件。独立原生页面由各端原生窗口渲染。

`media.audioRoute` 是实际观察到的输出，`speaker` 是最后一次成功的扬声器设置。自定义切换按钮可直接调用 `toggleSpeaker()`，并用 `speakerActive` 显示实际外放状态。`media.trackStates` 保存 SDK 的本端录音、主相机、当前对端视频状态和数字原因；尚无对应回调时该键缺省。远端停止/失败会清除可见视频状态。弱网提示分别读取 `media.localWeak` 和 `remoteWeak`，任一收发质量等级为 3–6 时提示。宿主可按需监听 `controller.diagnostics`，获取原会话、阶段、单调耗时、画布角色或 SDK 数字码，适合定位取凭据、入房、首帧、重绑、续期和释放。

## 控制和生命周期

- `controller.state` 为不可变快照；通过 `addListener` / `AnimatedBuilder` 观察。`phase` 保留兼容的窗口展示投影；`connectionState` 独立表达 RTC 连接，`businessState` 独立表达业务呼叫，`media` 表达媒体状态。
- `startCall(request: const CallRequest(...))` 返回 `CallStartResult(sessionId, status)`。`accepted` 仅表示 SDK 接受入房请求，**不表示业务接听或已收到媒体**；`cancelled` 表示该次发起已取消。结果始终携带原始 sessionId，即使等待期间已结束并重拨。异常仍为 `CallException`。
- `CallRequest` 的可选 `businessId/scene` 必须非空且至多 128 字符。取凭据前生成 `CallContext(sessionId, request, startedAt)`，同一对象传给凭据与续期 provider；业务元数据不自动传入原生或 H5。
- 宿主信令通过 `updateBusinessState(sessionId: ..., state: ...)` 推进 ringing/accepted，允许跳过 ringing，重复同状态幂等，拒绝倒退或旧会话。RTC 加入、首帧和恢复不会推断业务接听。`endCall(sessionId: ..., reason: ...)` 校验会话身份，同一会话释放未确认时可安全重试；结束原因新增 remote/rejected/noAnswer。`hangup()` 保留当前会话操作。
- `controller.ended` 在每次确认释放后发送一次 `CallSummary`；重试、重复挂断不会重复通知。`state.lastSummary` 保留最近摘要供重新订阅查询。摘要包含 context、acceptedAt、endedAt、reason、releaseStatus、error；duration 在未业务接听时为 null，已接听时用单调计时计算。清理未确认时不发送结束摘要，保留会话并阻止新呼叫。
- 单活动会话。等待 credentialsProvider 时已经占有会话；重复发起返回 `busy`。取消、关闭后的迟到参数不会入房。
- 默认凭据等待 30 秒；原生命令等待 45 秒；命令成功后的实际入房等待默认 45 秒，可通过 `credentialsTimeout/joinTimeout` 配置对应阶段。
- `hangup()`、`minimize()`、`restore()`、`setMuted()`、`setCameraEnabled()`、`setSpeaker()`、`switchCamera()` 提供宿主控制。异步失败为 `CallException`，提供安全 code、operation、vendorCode、recovery，不携带原始平台错误文本。`sdk_<number>` 和 `agora_<number>` 统一为 sdkError。
- 本批保留 SDK 异步 error 的保守挂断策略；尚未按三端 SDK 错误表区分可恢复和致命事件。单次控制命令失败可报告给宿主，不等同于 SDK 异步 error 事件。
- Token 事件自动调用 tokenProvider；同一会话并发续期合并，迟到结果不会续到下一通话。失败后暂停自动重试。有 tokenProvider 的 Flutter 和独立原生通话页会显示「重试通话授权」，自定义控件可根据 `canRefreshToken` 调用 `refreshToken()`。无 tokenProvider 时由宿主观察 needsToken。
- 默认 Flutter 生命周期模式在 paused/detached 时挂断，inactive 继续保持；混合模式使用原生宿主通知。系统中断和媒体连续性仍需真机验收。
- 退出登录或销毁 FlutterEngine **先 `await controller.shutdown()`**，成功后 `bridge.dispose()`、`controller.dispose()`。shutdown 后 controller 不再接受新通话，重新接入需新建实例。清理失败保留 ending 状态且抛错，可重试 shutdown；不得在失败时销毁唯一控制器。SDK 销毁失败可能需要重启 App。
- Widget.dispose 不能等待异步清理，controller.dispose 只提供尽力释放；不替代上述显式 shutdown 流程。
- 无媒体模式默认禁用。只有预研宿主设置 `allowProbe: true` 才允许 startProbe；探针不表示真实音视频。

## 从业务排队到 RTC 入房

宿主调用业务接口，将返回结果转成组件数据。使用同一控制器管理等待窗口、全屏通话和小窗。保留每个业务请求对应的本地会话 ID，异步回调使用该 ID，防止旧回调影响下一通。

```dart
// 建立等待窗口，此时不取 RTC 凭据、不开摄，不计入凭据或入房超时。
final id = await controller.beginWaiting(
  request: CallRequest(businessId: orderId, localAvatarPath: avatarFilePath),
);
controller.updateQueue(sessionId: id, peopleAhead: 2);

// 业务允许入房后，将服务器返回值转换为 CallCredentials。
await controller.admit(sessionId: id, credentials: credentials);
// 两端宿主传入同一次业务接听的 UTC 时间，接听与准入可以分别到达。
controller.updateBusinessState(
  sessionId: id, state: CallBusinessState.accepted, acceptedAt: answeredAt,
);
// 收到业务结束事件时释放本地资源。
await controller.endCall(sessionId: id, reason: CallEndReason.remote);
```

- 注册 `controller.userActions` 可即时收到用户的取消或挂断，使用 `event.sessionId` 和 `event.kind` 调用对应业务接口。重复按键、重试释放和宿主调用 `endCall` 不会再次产生用户操作。`controller.ended` 在组件确认释放资源后发送结束摘要。两个订阅都由宿主管理。
- 等待支持缩小、恢复和取消。重复准入只发起一次入房，取消后的旧 ID 无法重新开摄。已有直连入口可继续使用 `startCall()`。
- 宿主收到坐席接听后，将业务侧确定的接听时刻传给 `updateBusinessState`。`acceptCall` 处理本地接听时也支持 `acceptedAt`。两端系统时钟同步时，即使事件送达时间不同，也会显示同一通话时长。未传有效时间时按本机收到接听的时间起算，首个有效时间可以补正。随后由单调时钟推进，重复通知不会重启计时。活动会话和结束摘要均可读取 `acceptedAt`。
- `state.queue` 和 H5 快照的 `queue` 区分人数未知（unknown）、无需排队（none）与正在排队（queued）。人数大于零且未传预计时长时按每人 5 分钟估算。H5 通过 `estimatedWaitMs` 读取毫秒数；接听后队列清空。
- 每次呼叫可通过 `CallRequest.mediaOptions` 覆盖初始镜头、清晰度及主画面。`localAvatarPath` 接收宿主已缓存的本机绝对文件路径。用户关摄在副画面显示个人头像，缺失或加载失败使用默认人像；客服关摄在主画面显示客服头像。重新开摄后恢复之前的主副画面选择。头像路径不会进入 H5 快照。

## 视频客服界面

全屏等待页显示客服头像、等待文案及「取消」。默认由业务接听信令决定何时展示通话操作并开始计时。直连声网调试可显式设置 `mediaOnlyPreview: true`，让对端入房触发预览。分步排队始终按业务接听信令展示。排队或振铃期间继续展示等待页。

等待时缩小窗口，右上角会显示客服头像和「等待接听」。点按卡片恢复全屏，拖动卡片可以换边。坐席接听后，卡片保持原来的位置和大小，底栏从接听时刻开始计时，一小时内显示 MM:SS，达到一小时显示 HH:MM:SS。收到坐席视频首帧后显示实时画面，坐席关闭摄像头或尚未出画时显示青绿色背景和客服头像。点按卡片恢复全屏后可以挂断。真实双端 RTC 调试从对端入房开始单独计算卡片时长，业务状态和结束摘要仍由宿主信令决定。通话小窗与全屏的对端副画面使用同样的样式。弱网或重连时保留卡片和时长。全屏和小窗均会短暂提示本端、对端或双方弱网；同一状态不重复提示，恢复后清除。无媒体演练显示「无媒体测试」。[MasterGo 画板 60](https://mastergo.com/file/202970414230903?page_id=436%3A13556&layer_id=526%3A20332)

```dart
// 从业务回调取本次呼叫绑定的 sessionId。两个排队字段均可省略。
controller.updateQueue(sessionId: sessionId, peopleAhead: peopleAhead,
    estimatedWait: estimatedWait);
controller.updateBusinessState(sessionId: sessionId, state: CallBusinessState.accepted);
```

`peopleAhead` 为前方人数，`estimatedWait` 为预计等待时长（Duration）。两者都省略时回到普通等待文案。确认接听后自动清除排队提示。全屏通话页显示主副画面、通话时长、清晰度菜单和媒体开关。标清/高清使用现有编码能力；副画面等待坐席视频时显示头像。横竖屏按钮在当前窗口内旋转通话界面，缩小后恢复宿主方向。结束操作在接听前显示「取消」，接听后显示「挂断」。[MasterGo 设计稿](https://mastergo.com/file/202970414230903?page_id=436%3A13556&shareId=202970414230903)

在 Flutter、独立原生页及其承载的 H5 上恢复全屏后，点右上角清晰度会展开同款白色圆角菜单。当前档位用青绿色加粗标出。选择另一档会更新本机上行视频的编码目标。点击空白处或当前档位均可收起菜单，缩小窗口后再次恢复全屏时菜单保持收起。

全屏通话时，点右上角副画面可交换自己和对方的画面，再点一次即可换回。缩小窗口后始终显示对方，恢复全屏会沿用本次通话选择的布局。每次新通话都从调用方配置的 `CallMediaOptions.primaryVideo` 开始。

## H5 容器

默认本地 HTML 容器：

```dart
CustomerServiceWebView(bridge: bridge, html: trustedLocalHtml,
  requestForCall: () => CallRequest(businessId: currentOrder.id, scene: 'support'),
)
```

更换 html 会立即作废旧页面绑定；相同 HTML 重载需更换 Widget Key。页面销毁/重载不挂断会话，新文档 ready 后收到当前快照。默认容器限制为本地受信 HTML，不提供远程 URL 加载接口。

宿主已有 WebView 时只使用协议层：

```dart
final binding = bridge.attach(requestForCall: () => CallRequest(businessId: currentOrder.id),
  send: (message) async {
  // 用宿主容器安全的 JSON 序列化调用 window.onNativeMessage(message)。
  await hostWebView.sendJson(message);
});
// 确认受信主文档加载完成、接收函数安装后：
await binding.ready();
// 仅转发当前受信主文档发出的字符串消息：
await binding.receive(messageFromJavaScript);
// 导航/重载开始和容器销毁时立即作废；新文档使用新 binding。
binding.dispose();
```

requestForCall 在当前受信文档发起 beginWaiting 或 startRtc 时读取宿主上下文；示例页等待超时先查询状态，避免重复发起。协议层不持有 URL。外部容器必须校验主框架/来源、限制导航、清理 JS 回调，不能将任意 iframe 或网页消息转发进来。每个绑定拥有独立请求去重缓存，旧绑定的消息和迟到响应被忽略。

H5 发送 v1 JSON：`{version:1,requestId:"唯一ID",action:"startRtc",params:{}}`。支持 beginWaiting/startRtc/startProbe/getState/hangup/minimize/restore/openBusiness；hangup/minimize/restore 需 `params.sessionId` 匹配当前会话。响应为 `{kind:"response",requestId,ok,result|error}`，状态推送为 `{kind:"state",state}`。原有字段与动作保持兼容。

startRtc 的成功响应额外包含顶层 `startResult:{sessionId,status:"accepted"|"cancelled"}`，`result` 仍为响应时最新快照；客户端应按 `startResult.sessionId` 关联原始请求，不能用最新快照判断旧请求的结果。startProbe 响应不新增 startResult。

快照新增 connectionState/businessState/lastSummary。H5 摘要仅包含 sessionId、startedAt、acceptedAt、endedAt、reason、durationMs、releaseStatus、errorCode，不输出 context、businessId、scene、App ID、频道、Token 或原始异常。H5 的 startRtc 参数不能注入业务元数据，H5 不提供声明业务接听或业务结束原因的接口。业务导航仅通过宿主注入 onOpenBusiness。

## 从 0.1 迁移到 0.2

1. 同步引用两个 0.2.0 内部包，将 `credentialsProvider: ()` 改为 `(context)`，`tokenProvider: (identity)` 改为 `(context, identity)`。参数服务可以按 context.sessionId 和 context.request 关联宿主业务请求。
2. 将依赖 `Future<void>` 的 startCall 调用改为接收 `Future<CallStartResult>`。成功后检查 status；需要仅等待的调用可继续 `await controller.startCall()`。不能把 accepted 当作坐席接听。
3. 通过宿主真实信令推进业务状态和调用 endCall；没有业务信令的调试端通话保持 requested，即使已收到双向媒体。结束订阅和页面恢复分别读取 ended、state.lastSummary。
4. 自定义 `RtcTransport.invoke` 返回类型升级为 `Future<Object?>`。leave 返回 `{releaseStatus:"released"|"releasedWithWarnings"}`；兼容旧适配器返回 null 为 released，其他格式按释放未确认处理。其他操作保留原返回值。

releasedWithWarnings 表示停止/解绑/离房步骤有警告但最终 SDK 销毁已完成，可以释放会话所有权；销毁未完成或失败返回 cleanupFailed 并阻止重拨。iOS destroy 为 void，以同步 API 返回作为销毁完成边界。此次未升级原生 SDK、增加远程 URL 权限或增加多 Engine 支持。

## 验证入口

从仓库根运行 `./tool/flutterw --service analyze` 和 `./tool/flutterw --service test`。根 Demo、最小宿主都只 import 公共入口；内部 src 不属于稳定 API。参见 [最小宿主](../../examples/minimal_host/README.md) 的使用说明。
