# customer_rtc

Android Kotlin / iOS Swift / HarmonyOS ArkTS 自封装声网原生 SDK、原生视频视图与本地 HTML WebView。视频帧不经 Dart 通道传输，不依赖 agora_rtc_engine。

| 平台 | 固定依赖 |
| --- | --- |
| Android | full-rtc-basic 4.6.0，aosl 1.3.0 |
| iOS | AgoraRtcEngine_iOS 4.5.3，AgoraInfra 1.3.7 |
| HarmonyOS | @shengwang/rtc-full 4.4.2，HAR SHA-256 由包内 ohos/tool/setup_sdk.sh 校验 |

普通宿主依赖上层 [customer_video_service](../customer_video_service/README.md)，由其管理会话、窗口和协议。NativeRtcClient/RtcTransport 是底层适配接口；NativeWebClient 仅处理 typed Web 事件和定向回复，共用同一原生 EventChannel 订阅。原生视图销毁只解绑视频，不拥有通话生命周期。仅支持一个活动 FlutterEngine / 一个活动会话。

0.3.0 增加独立原生页面的窗口挂载、前后台通知和媒体操作。各端接入根容器、返回键、后台事件及卸载的方式见 [Android](android/HOST.md)、[iOS](ios/HOST.md)、[HarmonyOS](ohos/HOST.md)。启用宿主模式时，Flutter 会话控制器将同一通话的安全快照发给当前原生窗口。独立使用鸿蒙包时先运行 `./ohos/tool/setup_sdk.sh` 取得固定校验值的 HAR。

内部包 0.2.0 将 `RtcTransport.invoke` 返回类型改为 `Future<Object?>`。leave 成功返回 `{releaseStatus: released|releasedWithWarnings}`，后者表示部分停止/解绑/离房步骤失败但 SDK 最终销毁已完成。销毁失败仍抛 cleanup_failed，保留所有权并阻止新入房；上层兼容旧适配器的 null 为 released，非法结果视为未确认。iOS destroy 为 void，以同步返回作为完成边界。SDK 版本不变，SDK 异步 error 目前仍由上层保守挂断，未按错误码细分。

使用根工程固定 Flutter OHOS SDK。包含 OHOS 平台类型，标准 Flutter SDK 兼容性未验证。原生通道契约见 [native-plugin.md](../../docs/contracts/native-plugin.md)。本地权限、签名配置及构建入口见根 README；不将凭据或证书放在插件。

```sh
# 仓库根
./tool/flutterw --plugin pub get
./tool/flutterw --plugin analyze
./tool/flutterw --plugin test
```
