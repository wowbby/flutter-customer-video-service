# Flutter 视频客服组件

为 Android、iOS 和鸿蒙宿主提供视频客服会话、全屏通话和跨页面小窗。宿主继续使用自己的 WebView、JSBridge 和业务接口，将排队、准入、接听和结束事件交给同一个 `VideoServiceController`。组件管理窗口和通话状态，底层 `customer_rtc` 插件通过各平台的声网原生 SDK 处理音视频。

## 接入 v0.4.0

在宿主的 `pubspec.yaml` 中添加以下依赖。已验证的工具链为 Flutter OHOS `3.27.5-ohos-1.0.8` 和 Dart `3.6.2`。

```yaml
dependencies:
  customer_video_service:
    git:
      url: https://github.com/wowbby/flutter-customer-video-service.git
      ref: v0.4.0
      path: packages/customer_video_service
```

在 Flutter 根节点挂载 `VideoServiceHost`。宿主收到发起请求时可调用 `beginWaiting()` 打开等待窗口，业务准入成功时调用 `admit()`，收到接听信令时调用 `updateBusinessState()`。独立原生页面的窗口挂载方式和三端配置见接入指南。

鸿蒙首次构建前，在实际参与构建的组件源码目录运行 `packages/customer_rtc/ohos/tool/setup_sdk.sh`，下载并校验声网 4.4.2 HAR。

## 从 v0.3.0 升级

v0.4.0 移除了 `CustomerServiceWebView`、`CustomerH5Bridge` 和 `H5Binding`。曾经依赖这些类的宿主需要将页面加载和消息收发迁到自己的 WebView 和 JSBridge。纯 Flutter 宿主可以直接调用控制器，最小宿主示例演示了从等待、缩小、跨页面到结束的流程。

v0.4.0 的两个组件包和最小宿主取自源码提交 `985d0874856b131985103cf1f3e4fef61a42305d`。

[组件接入与迁移指南](packages/customer_video_service/README.md) · [最小宿主示例](examples/minimal_host/README.md) · [原生插件接口](docs/contracts/native-plugin.md)
